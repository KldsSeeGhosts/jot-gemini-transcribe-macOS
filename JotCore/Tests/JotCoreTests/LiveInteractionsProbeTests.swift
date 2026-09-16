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

/// Opt-in checks against the OpenAI API.
///
/// JOT_LIVE_PROBE=1 OPENAI_API_KEY=... JOT_PROBE_AUDIO=/path/to/clip.m4a \
///   ./scripts/test.sh --filter LiveInteractionsProbeTests
final class LiveInteractionsProbeTests: XCTestCase {
    private func requireOptIn() throws -> (OpenAIClient, Data, OpenAIConfig) {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["JOT_LIVE_PROBE"] == "1", "live probe not opted in")
        let key = try XCTUnwrap(env["OPENAI_API_KEY"])
        let path = try XCTUnwrap(env["JOT_PROBE_AUDIO"])
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: path),
            "JOT_PROBE_AUDIO does not exist: \(path)"
        )
        return (
            OpenAIClient(apiKey: { key }),
            try Data(contentsOf: URL(fileURLWithPath: path)),
            OpenAIConfig()
        )
    }

    func testRecordedAudioTranscribesThroughShippingClient() async throws {
        let (client, audio, config) = try requireOptIn()
        let text = try await client.transcribe(
            audioData: audio,
            model: config.transcribeModel,
            endpoint: config.endpoint,
            deadline: 60,
            prompt: nil,
            keywords: []
        )
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("TRANSCRIPT: \(text)")
    }

    func testBadKeyIsRejected() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JOT_LIVE_PROBE"] == "1",
            "live probe not opted in"
        )
        let client = OpenAIClient(apiKey: { "definitely-not-a-real-key" })
        let check = await client.validateKey(endpoint: OpenAIConfig().endpoint)
        guard case .rejected = check else {
            return XCTFail("a rejected key must not be classified as unreachable")
        }
    }

    func testRealKeyValidates() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["JOT_LIVE_PROBE"] == "1", "live probe not opted in")
        let key = try XCTUnwrap(env["OPENAI_API_KEY"])
        let client = OpenAIClient(apiKey: { key })
        XCTAssertEqual(
            await client.validateKey(endpoint: OpenAIConfig().endpoint),
            .valid
        )
    }
}
