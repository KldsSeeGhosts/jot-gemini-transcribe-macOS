// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// One authenticated Realtime socket held open across dictations, so a key
/// press pays no connect + session handshake.
///
/// This is the same trick `WarmEnginePool` plays for the capture graph, and the
/// same one the Linux reference daemon plays: the socket is opened at launch and
/// after every teardown, kept alive with pings, and handed to the next session
/// only if it is still open when that session starts. A socket that died since
/// the last ping is simply rebuilt — the session's own ring holds the audio
/// either way, so nothing is ever lost waiting on this.
///
/// The warm socket is connected but NOT configured: session.update carries the
/// per-dictation prompt and dictionary, which only the session knows, so that
/// handshake is the one thing deferred to resume().
///
/// Lifecycle: `acquire()` hands the live transport to a session (or nil, which
/// means "cold path, connect yourself"). The session adopts the socket, so the
/// pool immediately forgets it — ownership moves with the dictation — and the
/// pool kicks off building the NEXT spare in the background. `release()` is the
/// signal that a session ended and its socket went away, so the pool knows to
/// start warming a replacement. Prewarming is deliberately lazy: an app that
/// never dictates never opens a socket.
public actor WarmSocketPool {

    /// Everything the pool needs to mint a socket, captured once. The auth
    /// headers are a closure because the OAuth token rotates — every connect
    /// resolves a fresh one, which is also what lets a token refresh mid-app-life
    /// not strand every subsequent socket.
    public struct Configuration: Sendable {
        public var makeTransport: @Sendable () -> LiveTransport
        /// Pings below this interval keep the NAT and the server interested.
        /// Long enough to be invisible, short enough that a dead socket is
        /// discovered before the user presses the key, not during the dictation.
        public var keepaliveInterval: TimeInterval

        public init(
            makeTransport: @escaping @Sendable () -> LiveTransport,
            keepaliveInterval: TimeInterval = 20.0
        ) {
            self.makeTransport = makeTransport
            self.keepaliveInterval = keepaliveInterval
        }
    }

    /// The socket's life is one async task: connect, send setup, await
    /// session.updated, then ping until released or it dies. Because a session
    /// may `acquire` in the middle of any of those, the task's own state is the
    /// only thing worth tracking — the transport reference is deliberately NOT
    /// shared until it is handed over.
    private enum Slot {
        case empty
        case warming(Task<LiveTransport?, Never>)
        case warm(LiveTransport)
    }

    private var config: Configuration?
    private var slot: Slot = .empty
    private var keepaliveTask: Task<Void, Never>?

    /// The warm transport behind a lock so the main-actor session factory can
    /// take it synchronously without awaiting the actor. Actor state (`slot`)
    /// tracks the build; the box is the one piece a synchronous caller reaches
    /// into, and all it does is take-and-clear — the same transition acquire()
    /// performs. The class box is what lets `acquireNow` be `nonisolated`.
    private final class WarmBox: @unchecked Sendable {
        private let lock = NSLock()
        private var transport: LiveTransport?

        func store(_ t: LiveTransport?) {
            lock.lock(); transport = t; lock.unlock()
        }
        /// Take-and-clear: returns the transport and removes it atomically, so
        /// two callers can never both receive the same socket.
        func take() -> LiveTransport? {
            lock.lock(); defer { lock.unlock() }
            let t = transport; transport = nil; return t
        }
        func peek() -> LiveTransport? {
            lock.lock(); defer { lock.unlock() }; return transport
        }
        func isHeld(_ t: LiveTransport) -> Bool { peek() === t }
    }
    private let warmBox = WarmBox()

    public init() {}

    /// Point the pool at a socket recipe. Called once the app knows live mode is
    /// on and credentials exist; a nil config turns warming off entirely.
    public func configure(_ config: Configuration?) {
        self.config = config
        if config == nil {
            // Live mode was switched off: drop whatever is being held so a
            // stale socket can't be handed to the next session.
            discardWarm()
        }
    }

    /// Build a socket now, in the background. Safe to call repeatedly — it
    /// never duplicates work already in flight.
    public func prewarm() {
        guard config != nil else { return }
        if case .empty = slot {
            startWarm()
        }
    }

    /// Hand the warm socket to a session about to start.
    ///
    /// Returns nil in every case where the socket cannot be used RIGHT NOW —
    /// never configured, nothing warm, still handshaking. The caller's own
    /// transport path covers all of those; this method never makes a session
    /// wait on a socket that is not ready.
    public func acquire() -> LiveTransport? {
        guard case .warm(let transport) = slot else { return nil }
        slot = .empty
        stopKeepalive()
        warmBox.store(nil)
        return transport
    }

    /// Synchronous take of the warm socket, for the main-actor factory which
    /// cannot await the pool. Take-and-clear under the lock, then tell the actor
    /// to mirror the state change and top itself back up — that bookkeeping can
    /// lag the handoff by a turn without hurting anything.
    public nonisolated func acquireNow() -> LiveTransport? {
        guard let transport = warmBox.take() else { return nil }
        Task { await self.didAcquireNow(transport) }
        return transport
    }

    private func didAcquireNow(_ transport: LiveTransport) {
        // Only clear slot if it still names this transport — a newer spare may
        // already have arrived, and clobbering it would orphan a live socket.
        if case .warm(let current) = slot, current === transport {
            slot = .empty
            stopKeepalive()
        }
        prewarm()
    }

    /// A session ended (or abandoned) its socket. If the slot is empty — the
    /// normal case, since acquire emptied it — begin warming the replacement so
    /// back-to-back dictations stay warm. If a spare is already on its way this
    /// is a no-op.
    public func release() {
        prewarm()
    }

    /// Stop the spare-build + keepalive for good (app teardown / sign-out).
    public func invalidate() {
        config = nil
        discardWarm()
    }

    // MARK: - Internals

    private func startWarm() {
        guard let config else { return }
        let task = Task<LiveTransport?, Never> { [config] in
            let transport = config.makeTransport()
            do {
                try await transport.connect()
                guard !Task.isCancelled else { transport.close(); return nil }
                return transport
            } catch {
                transport.close()
                return nil
            }
        }
        // session.update is deliberately NOT sent here: the pool knows no
        // session's prompt or dictionary, so the warm socket is connected only.
        // The session that adopts it sends its own session.update at resume —
        // an in-band frame, still no TCP/TLS connect in the hot path.
        slot = .warming(task)

        Task { [weak self] in
            let transport = await task.value
            await self?.finishWarm(transport)
        }
    }

    private func finishWarm(_ transport: LiveTransport?) {
        if let transport {
            slot = .warm(transport)
            warmBox.store(transport)
            startKeepalive(on: transport)
        } else {
            // The build failed or was cancelled — leave the slot empty. The next
            // acquire() sees .empty, returns nil, and the session cold-connects,
            // which is the correct and cheapest failure mode here.
            slot = .empty
        }
    }

    private func startKeepalive(on transport: LiveTransport) {
        stopKeepalive()
        let interval = config?.keepaliveInterval ?? 20
        keepaliveTask = Task { [weak self, weak transport] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self, let transport else { return }
                // sendPing, not receive: a liveness receive would steal a frame
                // destined for the session. A dead socket throws promptly, which
                // is exactly what we are listening for.
                do {
                    try await transport.ping()
                } catch is CancellationError {
                    return
                } catch {
                    // Socket died on its own: drop it and rebuild so the next
                    // dictation does not inherit a corpse.
                    await self.socketDied(transport)
                    return
                }
            }
        }
    }

    private func socketDied(_ transport: LiveTransport) {
        // Only act while the socket is still pool-owned: once acquired the lock
        // copy is cleared, so this check fails and a stale keepalive callback
        // cannot kill a socket that is now mid-dictation.
        guard warmBox.isHeld(transport) else { return }
        if case .warm(let current) = slot, current === transport {
            slot = .empty
        }
        warmBox.store(nil)
        stopKeepalive()
        transport.close()
        startWarm()
    }

    private func discardWarm() {
        let built: LiveTransport?
        switch slot {
        case .warm(let transport): built = transport
        case .warming(let task):
            task.cancel()
            built = nil
        case .empty:
            built = nil
        }
        slot = .empty
        stopKeepalive()
        built?.close()
        warmBox.take()?.close()
    }

    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

}
