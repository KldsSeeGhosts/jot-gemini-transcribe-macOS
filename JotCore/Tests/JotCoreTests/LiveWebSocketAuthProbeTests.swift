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
import XCTest
@testable import JotCore

/// Opt-in probe for the exact WebSocket authentication and setup used by Jot.
///
/// JOT_LIVE_PROBE=1 swift test
///   --filter LiveWebSocketAuthProbeTests
final class LiveWebSocketAuthProbeTests: XCTestCase {
    func testOpenAIRealtimeAcceptsLocalOAuthAndSetup() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["JOT_LIVE_PROBE"] == "1", "live probe not opted in")

        let oauth = OpenAIOAuthStore()
        let transport = WebSocketTransport(authHeaders: {
            try await oauth.authorizationHeaders()
        })
        defer { transport.close() }
        try await transport.connect()
        try await transport.send(LiveProtocol.setupFrame(LiveSetup()))

        let event = try await withThrowingTaskGroup(of: LiveEvent.self) { group in
            group.addTask {
                while true {
                    let data = try await transport.receive()
                    if let event = LiveProtocol.decode(data) { return event }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        XCTAssertEqual(event, .setupComplete)
    }
}
