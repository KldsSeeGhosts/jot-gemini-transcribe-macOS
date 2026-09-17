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

import XCTest
@testable import JotCore

/// Every way a live session can end, driven against a scripted socket so the
/// failure modes that matter are exercised on every build rather than only when
/// someone's wifi drops mid-sentence.
final class LiveTranscriptionSessionTests: XCTestCase {

    /// A socket that says what the test tells it to say.
    final class FakeTransport: LiveTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var inbox: [Data]
        private(set) var sent: [Data] = []
        var connectError: Error?
        var sendErrorAfter: Int?
        var receiveHangs = false
        /// Simulates a socket that never completes a send — the freeze case.
        var hangSend = false
        private(set) var closeCount = 0

        init(script: [Data]) { self.inbox = script }

        private(set) var connectCount = 0
        func connect() async throws {
            lock.lock(); connectCount += 1; lock.unlock()
            if let connectError { throw connectError }
        }

        func send(_ data: Data) async throws {
            if hangSend {
                // Long enough to prove begin() would hang without a bound —
                // short enough to keep the suite fast. A real socket parks here
                // forever; the fake just proves the path returns.
                try await Task.sleep(nanoseconds: 6_000_000_000)
                throw URLError(.timedOut)
            }
            lock.lock()
            let count = sent.count
            let limit = sendErrorAfter
            lock.unlock()
            if let limit, count >= limit {
                throw URLError(.networkConnectionLost)
            }
            lock.lock(); sent.append(data); lock.unlock()
        }

        func receive() async throws -> Data {
            if receiveHangs {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw URLError(.timedOut)
            }
            lock.lock()
            let next = inbox.isEmpty ? nil : inbox.removeFirst()
            lock.unlock()
            if let next { return next }
            // Nothing left to say: park rather than spinning, like a real socket
            // waiting on a server that has gone quiet.
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw URLError(.timedOut)
        }

        func close() { lock.lock(); closeCount += 1; lock.unlock() }

        var pingError: Error?
        func ping() async throws { if let pingError { throw pingError } }

        /// What was actually put on the wire, in order, as decoded JSON keys.
        var sentKinds: [String] {
            lock.lock(); defer { lock.unlock() }
            return sent.compactMap { data in
                guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
                switch root["type"] as? String {
                case "session.update": return "setup"
                case "input_audio_buffer.append": return "audio"
                case "input_audio_buffer.commit": return "commit"
                default: break
                }
                return nil
            }
        }
    }

    private func frame(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func setupCompleteFrame() -> Data { frame(["type": "session.updated"]) }
    private func finalFrame(_ text: String) -> Data {
        frame([
            "type": "conversation.item.input_audio_transcription.completed",
            "transcript": text,
        ])
    }
    private func partialFrame(_ text: String) -> Data {
        frame([
            "type": "conversation.item.input_audio_transcription.delta",
            "delta": text,
        ])
    }

    private func makeSession(_ transport: FakeTransport, ring: PCMRing = PCMRing()) -> LiveTranscriptionSession {
        LiveTranscriptionSession(transport: transport, setup: LiveSetup(), ring: ring)
    }

    // MARK: - The happy path

    func testCleanSessionCompletesWithFinalText() async throws {
        let transport = FakeTransport(script: [setupCompleteFrame(), finalFrame("Ship it on Friday.")])
        let session = makeSession(transport)
        try await session.start()
        session.enqueue(Data(repeating: 0x01, count: 3_328))
        try await Task.sleep(nanoseconds: 120_000_000)
        let outcome = await session.finish(deadline: 2.0)
        XCTAssertEqual(outcome, .completed("Ship it on Friday."))
    }

    /// The ordering guarantee that stops the user's last words being cut off:
    /// commit must reach the wire AFTER every audio chunk queued before it.
    func testActivityEndNeverOvertakesQueuedAudio() async throws {
        let transport = FakeTransport(script: [setupCompleteFrame(), finalFrame("done")])
        let session = makeSession(transport)
        try await session.start()
        for _ in 0..<12 { session.enqueue(Data(repeating: 0x02, count: 3_328)) }
        _ = await session.finish(deadline: 2.0)

        let kinds = transport.sentKinds
        let endIndex = try XCTUnwrap(kinds.firstIndex(of: "commit"))
        let audioIndices = kinds.enumerated().filter { $0.element == "audio" }.map(\.offset)
        XCTAssertFalse(audioIndices.isEmpty, "audio must actually have been sent")
        XCTAssertTrue(audioIndices.allSatisfy { $0 < endIndex },
                      "every audio chunk must precede commit because the server finalizes on what it has")
    }

    func testSetupIsTheFirstFrame() async throws {
        let transport = FakeTransport(script: [setupCompleteFrame(), finalFrame("x")])
        let session = makeSession(transport)
        try await session.start()
        _ = await session.finish(deadline: 1.0)
        let kinds = transport.sentKinds
        XCTAssertEqual(kinds.first, "setup")
    }

    // MARK: - Everything that must fall back

    /// The failure the whole design is arranged around: dropped audio yields a
    /// fluent-but-truncated transcript. It must NEVER be promoted.
    func testDroppedAudioDisqualifiesTheSession() async throws {
        // A ring so small that streaming more than a second guarantees eviction.
        let ring = PCMRing(seconds: 1.0)
        let transport = FakeTransport(script: [setupCompleteFrame(), finalFrame("…by Friday.")])
        let session = LiveTranscriptionSession(transport: transport, setup: LiveSetup(), ring: ring)
        // Fill before start so nothing can drain it: the socket is not pumping yet.
        for _ in 0..<40 { ring.append(Data(repeating: 0x03, count: 3_328)) }
        XCTAssertTrue(ring.didDrop, "precondition: the ring must have evicted")

        try await session.start()
        let outcome = await session.finish(deadline: 1.0)
        guard case .unusable(let why) = outcome else {
            return XCTFail("a truncated stream must be unusable, got \(outcome)")
        }
        XCTAssertTrue(why.contains("truncated"), "the reason should name truncation, got: \(why)")
    }

    func testSetupTimeoutIsThrownNotSwallowed() async {
        let transport = FakeTransport(script: [])
        transport.receiveHangs = true
        let session = makeSession(transport)
        do {
            try await session.start(setupTimeout: 0.2)
            XCTFail("start must throw when setup never completes")
        } catch {
            // Any throw is correct — the caller falls back to batch either way.
        }
    }

    func testConnectFailureThrows() async {
        let transport = FakeTransport(script: [])
        transport.connectError = URLError(.notConnectedToInternet)
        let session = makeSession(transport)
        do {
            try await session.start(setupTimeout: 0.5)
            XCTFail("start must throw when the socket cannot connect")
        } catch {}
    }

    func testServerErrorEnvelopeIsRefused() async {
        let transport = FakeTransport(script: [frame(["error": ["message": "API key not valid"]])])
        let session = makeSession(transport)
        do {
            try await session.start(setupTimeout: 1.0)
            XCTFail("an error envelope during setup must throw")
        } catch {
            XCTAssertEqual(error as? LiveError, .refused("API key not valid"))
        }
    }

    func testNoFinalBeforeDeadlineIsUnusable() async throws {
        // Setup succeeds, then the server says nothing more.
        let transport = FakeTransport(script: [setupCompleteFrame()])
        let session = makeSession(transport)
        try await session.start()
        session.enqueue(Data(repeating: 0x04, count: 1_024))
        let outcome = await session.finish(deadline: 0.4)
        guard case .unusable = outcome else {
            return XCTFail("no final transcript must be unusable, got \(outcome)")
        }
    }

    func testGoAwayMakesTheSessionUnusable() async throws {
        let transport = FakeTransport(script: [setupCompleteFrame(), frame(["type": "session.closed"])])
        let session = makeSession(transport)
        try await session.start()
        try await Task.sleep(nanoseconds: 120_000_000)
        let outcome = await session.finish(deadline: 0.5)
        guard case .unusable = outcome else {
            return XCTFail("goAway must be unusable, got \(outcome)")
        }
    }

    func testSendFailureMidStreamIsUnusable() async throws {
        let transport = FakeTransport(script: [setupCompleteFrame(), finalFrame("partial words")])
        let session = makeSession(transport)
        try await session.start()
        // setup is already sent; fail on the next write.
        transport.sendErrorAfter = 1
        for _ in 0..<4 { session.enqueue(Data(repeating: 0x05, count: 3_328)) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let outcome = await session.finish(deadline: 0.5)
        guard case .unusable = outcome else {
            return XCTFail("a mid-stream send failure must be unusable, got \(outcome)")
        }
    }

    // MARK: - Partials must never become the transcript

    func testPartialsAreNeverPromotedToTheOutcome() async throws {
        let transport = FakeTransport(script: [
            setupCompleteFrame(),
            partialFrame("ship it on "),
            partialFrame("friday"),
            finalFrame("Ship it on Friday."),
        ])
        let session = makeSession(transport)
        try await session.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        let outcome = await session.finish(deadline: 1.5)
        XCTAssertEqual(outcome, .completed("Ship it on Friday."),
                       "the outcome must be the FINAL text, never the last interim")
    }

    func testPartialOnlySessionIsUnusable() async throws {
        let transport = FakeTransport(script: [setupCompleteFrame(), partialFrame("half a thought")])
        let session = makeSession(transport)
        try await session.start()
        try await Task.sleep(nanoseconds: 120_000_000)
        let outcome = await session.finish(deadline: 0.4)
        guard case .unusable = outcome else {
            return XCTFail("interim text alone must never be usable, got \(outcome)")
        }
    }

    // MARK: - Lifecycle

    func testAbortIsIdempotent() async throws {
        let transport = FakeTransport(script: [setupCompleteFrame(), finalFrame("x")])
        let session = makeSession(transport)
        try await session.start()
        await session.abort()
        await session.abort()
        await session.abort()
        XCTAssertEqual(transport.closeCount, 1, "close must happen exactly once however many aborts arrive")
    }

    func testFinishBeforeStartIsUnusableNotACrash() async {
        let transport = FakeTransport(script: [])
        let session = makeSession(transport)
        let outcome = await session.finish(deadline: 0.2)
        guard case .unusable = outcome else {
            return XCTFail("finishing a session that never started must be unusable")
        }
    }

    func testEmptyFinalIsUnusable() async throws {
        let transport = FakeTransport(script: [setupCompleteFrame(), finalFrame("   ")])
        let session = makeSession(transport)
        try await session.start()
        try await Task.sleep(nanoseconds: 120_000_000)
        let outcome = await session.finish(deadline: 0.5)
        guard case .unusable = outcome else {
            return XCTFail("whitespace-only text must not be inserted, got \(outcome)")
        }
    }

    // MARK: - Adopting a warm socket

    /// The whole point of the pool: a resumed session never connects or sends
    /// setup again — it goes straight to audio.
    func testResumeSkipsConnectAndSetup() async throws {
        // The cold transport is deliberately unusable; if resume leaked a
        // connect to it the session would die. Only the warm transport's frames
        // are scripted, because only it should ever be touched.
        let cold = FakeTransport(script: [])
        cold.connectError = URLError(.cannotConnectToHost)
        let warm = FakeTransport(script: [setupCompleteFrame(), finalFrame("warm words")])
        let session = makeSession(cold)

        let adopted = try await session.resume(warmTransport: warm)
        XCTAssertTrue(adopted, "a fresh session must adopt a warm socket")
        session.enqueue(Data(repeating: 0x07, count: 3_328))
        try await Task.sleep(nanoseconds: 150_000_000)
        let outcome = await session.finish(deadline: 1.0)

        XCTAssertEqual(outcome, .completed("warm words"))
        XCTAssertEqual(warm.connectCount, 0, "warm socket must not be reconnected")
        XCTAssertEqual(cold.connectCount, 0, "cold transport must never be touched after adoption")
        // The warm socket is connected only — this session still sends its own
        // session.update (prompt, dictionary), just without the TCP/TLS cost.
        XCTAssertEqual(warm.sentKinds.first, "setup", "resume still configures the adopted socket in-band")
    }

    /// Audio queued before adoption is buffered in the ring, not lost — the
    /// send loop must still see it once the pumps open on the warm socket.
    func testAudioQueuedBeforeResumeStillStreams() async throws {
        let cold = FakeTransport(script: [])
        let warm = FakeTransport(script: [setupCompleteFrame(), finalFrame("early audio")])
        let session = makeSession(cold)
        session.enqueue(Data(repeating: 0x08, count: 3_328))
        _ = try await session.resume(warmTransport: warm)
        try await Task.sleep(nanoseconds: 150_000_000)
        _ = await session.finish(deadline: 1.0)
        XCTAssertEqual(warm.sentKinds.filter { $0 == "audio" }.count, 1)
    }

    /// Once a session has cold-started it must not silently swap sockets —
    /// the second connect attempt is refused and the caller cold-starts a
    /// different session instead.
    func testResumeRefusedAfterStart() async throws {
        let cold = FakeTransport(script: [setupCompleteFrame(), finalFrame("cold")])
        let warm = FakeTransport(script: [])
        let session = makeSession(cold)
        try await session.start()
        let adopted = try await session.resume(warmTransport: warm)
        XCTAssertFalse(adopted, "a started session must refuse a socket swap")
    }
}
