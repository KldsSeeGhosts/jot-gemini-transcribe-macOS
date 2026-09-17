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

/// The socket, behind a protocol so every failure mode in this file can be
/// exercised against a scripted fake with no network: setup timeout, mid-stream
/// drop, clean finish, server goAway, double-abort.
public protocol LiveTransport: AnyObject, Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    /// Protocol-level keepalive. Throws on a dead socket; never consumes a
    /// frame destined for the session the way a liveness receive() would.
    func ping() async throws
    func close()
}

/// How a live session ended. Only `.completed` may replace the real transcript,
/// and even then only after the caller has reconciled the byte count.
public enum LiveOutcome: Equatable, Sendable {
    /// Clean: setup completed, nothing dropped, activityEnd acknowledged, a final
    /// transcript arrived before the deadline.
    case completed(String)
    /// Anything else. The batch path over the CAF takes over; the words are on
    /// disk regardless. The string is for the log, never for the user.
    case unusable(String)
}

/// One live transcription session over one WebSocket.
///
/// The shape is dictated by two hard constraints:
///
/// 1. **The audio write queue must never wait for this.** `enqueue` is
///    `nonisolated`, takes no lock the socket holds, and cannot await. It appends
///    to a ring and signals; that is all.
///
/// 2. **`activityEnd` must never overtake the audio in front of it.** The server
///    finalizes on what it has received, so an end signal that jumps the queue
///    silently truncates the user's last words — precisely the tail that
///    `awaitTailBuffer` exists to rescue. Control items therefore travel *in
///    band*, through the same channel as the audio wakeups, and the send loop
///    drains the ring completely before it acts on one.
public actor LiveTranscriptionSession {

    private enum Command: Sendable {
        case pcmAvailable
        case endActivity
    }

    /// The live socket. Starts as the session's own cold transport; resume()
    /// swaps in a warm one. `coldTransport` keeps the original so a failed
    /// adoption can hand the session its fallback back.
    private var transport: LiveTransport
    private let coldTransport: LiveTransport
    private let setup: LiveSetup
    public let ring: PCMRing

    private let commands: AsyncStream<Command>
    private let commandSink: AsyncStream<Command>.Continuation

    private var sendLoop: Task<Void, Never>?
    private var receiveLoop: Task<Void, Never>?

    private var finals: [String] = []
    private var latestPartial: String = ""
    private var failure: String?
    private var didSetup = false
    private var activityEndFlushed = false
    private var closed = false
    private var flushContinuation: CheckedContinuation<Void, Never>?
    private var finalContinuation: CheckedContinuation<Void, Never>?
    private var flushTimeoutTask: Task<Void, Never>?
    private var finalTimeoutTask: Task<Void, Never>?

    /// Partials for the HUD. Separate from the outcome on purpose — nothing that
    /// arrives here is allowed to become the transcript.
    public let partials: AsyncStream<String>
    private let partialSink: AsyncStream<String>.Continuation

    public init(transport: LiveTransport, setup: LiveSetup, ring: PCMRing = PCMRing()) {
        self.transport = transport
        self.coldTransport = transport
        self.setup = setup
        self.ring = ring
        // Control items must never be dropped, so this stream is unbounded — it
        // carries at most a handful of wakeups, not audio. The audio is in the
        // ring, which is the only thing with a drop policy.
        (self.commands, self.commandSink) = AsyncStream<Command>.makeStream(bufferingPolicy: .unbounded)
        (self.partials, self.partialSink) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Called from the audio write queue. Must not block, must not await.
    public nonisolated func enqueue(_ pcm: Data) {
        ring.append(pcm)
        commandSink.yield(.pcmAvailable)
    }

    /// Connects, handshakes, and opens the pumps. Throws if the socket or the
    /// credential is refused — the caller falls back to the batch path.
    public func start(setupTimeout: TimeInterval = 5.0) async throws {
        try await transport.connect()
        try await transport.send(LiveProtocol.setupFrame(setup))
        try await awaitSetup(setupTimeout)
        startPumps()
    }

    /// Adopts a socket the WarmSocketPool already connected, so a key press
    /// pays no TCP+TLS connect or auth round-trip — only the in-band
    /// session.update this dictation's own prompt needs. Returns false when the
    /// session is already past the point where a socket could be attached; the
    /// caller then cold-starts on its own transport instead.
    ///
    /// The warm socket is connected but deliberately NOT configured: the pool
    /// knows no session's prompt or dictionary, so reconfiguration happens here,
    /// where the real LiveSetup exists. Audio queued before this call is already
    /// in the ring, so nothing is lost by the handoff.
    public func resume(warmTransport: LiveTransport, setupTimeout: TimeInterval = 5.0) async throws -> Bool {
        guard !didSetup, !closed else { return false }
        transport = warmTransport
        try await transport.send(LiveProtocol.setupFrame(setup))
        try await awaitSetup(setupTimeout)
        startPumps()
        return true
    }

    /// Hands the session its own cold transport back after a warm adoption
    /// failed. The warm socket may have set failure or left didSetup true with
    /// nothing behind it; both are cleared so a subsequent start() is a genuine
    /// cold start, not a retry on a corpse. Audio already in the ring is kept —
    /// it is the user's words, and the cold path still needs it.
    public func resetToColdStart() {
        guard !closed, sendLoop == nil else { return }
        transport = coldTransport
        failure = nil
        didSetup = false
    }

    /// The bounded wait for session.updated, shared by cold start and by the
    /// pool's warm build. Audio arriving meanwhile is already accumulating in
    /// the ring, so nothing is lost by waiting. The bound is on the wait itself
    /// — a socket that connects then stalls must not park the batch fallback.
    private func awaitSetup(_ setupTimeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(setupTimeout)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let frame = try await Self.receive(from: transport, within: remaining)
            guard let event = LiveProtocol.decode(frame) else { continue }
            switch event {
            case .setupComplete:
                didSetup = true
            case .failed(let why):
                throw LiveError.refused(why)
            default:
                continue
            }
            break
        }
        guard didSetup else { throw LiveError.setupTimedOut }
    }

    /// Races a receive against a deadline. Returns the frame, or throws
    /// `LiveError.setupTimedOut` — either way it returns *promptly*, which is the
    /// whole point: the caller's fallback cannot start until this does.
    private static func receive(from transport: LiveTransport, within seconds: TimeInterval) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await transport.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw LiveError.setupTimedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw LiveError.setupTimedOut }
            return first
        }
    }

    private func startPumps() {
        receiveLoop = Task { [weak self] in await self?.runReceiveLoop() }
        sendLoop = Task { [weak self] in await self?.runSendLoop() }
    }

    private func runSendLoop() async {
        for await command in commands {
            if closed { return }
            // Drain the ring FIRST, on every command. This is what keeps
            // activityEnd behind the audio it must not overtake.
            for chunk in ring.drain() {
                do {
                    try await transport.send(LiveProtocol.audioFrame(chunk))
                    ring.markAccepted(chunk.count)
                } catch {
                    recordFailure("send failed: \(error)")
                    return
                }
            }
            if case .endActivity = command {
                do {
                    try await transport.send(LiveProtocol.activityEndFrame())
                } catch {
                    recordFailure("activityEnd failed: \(error)")
                }
                activityEndFlushed = true
                resumeFlush()
                return
            }
        }
    }

    private func runReceiveLoop() async {
        while !closed {
            do {
                let frame = try await transport.receive()
                guard let event = LiveProtocol.decode(frame) else { continue }
                switch event {
                case .partial(let text):
                    latestPartial += text
                    partialSink.yield(latestPartial)
                case .final(let text):
                    finals.append(text)
                    latestPartial = ""
                    resumeFinal()
                case .goAway:
                    recordFailure("server sent goAway")
                    return
                case .failed(let why):
                    recordFailure(why)
                    return
                case .setupComplete:
                    continue
                }
            } catch {
                if !closed { recordFailure("receive failed: \(error)") }
                return
            }
        }
    }

    private func recordFailure(_ why: String) {
        if failure == nil { failure = why }
        resumeFlush()
        resumeFinal()
    }

    private func resumeFlush() {
        flushTimeoutTask?.cancel()
        flushTimeoutTask = nil
        flushContinuation?.resume()
        flushContinuation = nil
    }

    private func resumeFinal() {
        finalTimeoutTask?.cancel()
        finalTimeoutTask = nil
        finalContinuation?.resume()
        finalContinuation = nil
    }

    private func waitForFlush(timeout: TimeInterval) async {
        guard !activityEndFlushed, failure == nil, !closed else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.flushContinuation = continuation
            self.flushTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                await self?.flushTimedOut()
            }
        }
    }

    private func flushTimedOut() {
        guard !Task.isCancelled else { return }
        resumeFlush()
    }

    private func waitForFinal(timeout: TimeInterval) async {
        guard finals.isEmpty, failure == nil, !closed else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.finalContinuation = continuation
            self.finalTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                await self?.finalTimedOut()
            }
        }
    }

    private func finalTimedOut() {
        guard !Task.isCancelled else { return }
        resumeFinal()
    }

    /// Ends the turn and waits for the server's last word.
    ///
    /// Called only after `AudioCaptureEngine.stop()` has returned, because audio
    /// keeps arriving through the tail drain and the trailing-capture window —
    /// key-up is not the end of speech.
    public func finish(deadline: TimeInterval = 6.0) async -> LiveOutcome {
        guard didSetup else { return .unusable("setup never completed") }
        if let failure { close(); return .unusable(failure) }

        commandSink.yield(.endActivity)
        commandSink.finish()

        // Wait for the send loop to actually flush activityEnd before starting
        // the clock on the final transcript.
        await waitForFlush(timeout: 2.0)
        if let failure { close(); return .unusable(failure) }
        guard activityEndFlushed else { close(); return .unusable("activityEnd never flushed") }

        // A final may already have arrived. Otherwise wait, briefly.
        await waitForFinal(timeout: deadline)
        close()

        if let failure { return .unusable(failure) }
        guard !finals.isEmpty else { return .unusable("no final transcript before deadline") }
        if ring.didDrop { return .unusable("dropped \(ring.droppedChunks) chunks — stream is truncated") }

        let joined = finals.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return .unusable("final transcript was empty") }
        return .completed(joined)
    }

    /// Tear down without waiting. Idempotent — every path that abandons a session
    /// calls this, including several that run before `start` ever completed.
    public func abort() {
        close()
    }

    private func close() {
        guard !closed else { return }
        closed = true
        sendLoop?.cancel()
        receiveLoop?.cancel()
        commandSink.finish()
        partialSink.finish()
        transport.close()
        resumeFlush()
        resumeFinal()
    }

    /// Bytes the socket accepted, for reconciliation against `framesWritten * 2`.
    public var acceptedBytes: Int64 { ring.acceptedBytes }
}

public enum LiveError: Error, Equatable {
    case refused(String)
    case setupTimedOut
}
