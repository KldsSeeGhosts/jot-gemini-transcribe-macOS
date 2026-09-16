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

/// The OpenAI Realtime socket. The user's key is sent in the Authorization
/// header and never appears in the URL or logs.
public final class WebSocketTransport: LiveTransport, @unchecked Sendable {

    public static let endpoint = "wss://api.openai.com/v1/realtime?intent=transcription"

    private let authHeaders: @Sendable () async throws -> [String: String]
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()

    public init(
        authHeaders: @escaping @Sendable () async throws -> [String: String]
    ) {
        self.authHeaders = authHeaders
        let config = URLSessionConfiguration.ephemeral
        // Fail fast rather than parking. `waitsForConnectivity` would leave an
        // offline dictation holding an unresolved connection for its whole
        // duration while the ring quietly fills and drops — the batch fallback
        // can only run once this admits defeat. Matches GeminiClient.
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    public func connect() async throws {
        var request = URLRequest(url: URL(string: Self.endpoint)!)
        for (name, value) in try await authHeaders() {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let task = session.webSocketTask(with: request)
        withTask { $0 = task }
        task.resume()
    }

    public func send(_ data: Data) async throws {
        let task = withTask { $0 }
        guard let task else { throw LiveError.setupTimedOut }
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    public func receive() async throws -> Data {
        let task = withTask { $0 }
        guard let task else { throw LiveError.setupTimedOut }
        switch try await task.receive() {
        case .data(let data):
            return data
        case .string(let text):
            return Data(text.utf8)
        @unknown default:
            return Data()
        }
    }

    public func close() {
        let task = withTask { task -> URLSessionWebSocketTask? in
            let current = task
            task = nil
            return current
        }
        task?.cancel(with: .goingAway, reason: nil)
    }

    private func withTask<T>(
        _ body: (inout URLSessionWebSocketTask?) -> T
    ) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&task)
    }
}
