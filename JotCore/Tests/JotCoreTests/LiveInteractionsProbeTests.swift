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
/// JOT_LIVE_PROBE=1 JOT_PROBE_AUDIO=/path/to/24khz-mono-int16.caf \
///   ./scripts/test.sh --filter LiveInteractionsProbeTests
final class LiveInteractionsProbeTests: XCTestCase {
    private func requireOptIn() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["JOT_LIVE_PROBE"] == "1", "live probe not opted in")
        let path = try XCTUnwrap(env["JOT_PROBE_AUDIO"])
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: path),
            "JOT_PROBE_AUDIO does not exist: \(path)"
        )
        return URL(fileURLWithPath: path)
    }

    func testSavedAudioTranscribesThroughOAuthRealtime() async throws {
        let audioURL = try requireOptIn()
        let service = OpenAITranscriptionService()
        let result = try await service.transcribe(
            audioURL: audioURL,
            durationSeconds: 3,
            context: DictationContext()
        )
        XCTAssertFalse(
            result.cleanedTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
        print("TRANSCRIPT: \(result.cleanedTranscript)")
    }

    func testLocalOAuthSessionResolvesHeaders() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["JOT_LIVE_PROBE"] == "1", "live probe not opted in")
        let headers = try await OpenAIOAuthStore().authorizationHeaders()
        XCTAssertTrue(headers["Authorization"]?.hasPrefix("Bearer ") == true)
        XCTAssertFalse(headers["chatgpt-account-id"]?.isEmpty ?? true)
    }
}
