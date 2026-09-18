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

public struct CleanupConfig: Sendable, Equatable {
    public var endpoint: URL
    public var apiKey: String
    public var model: String
    public var reasoningEffort: String
    public var timeout: TimeInterval

    public init(
        endpoint: URL = URL(string: "https://serverseesghosts.tail74ed91.ts.net:8443/v1")!,
        apiKey: String = "0be77f19167c458f0e71f4a97ae4a0ad881bb387a199e7129658c5b9ddff5b18",
        model: String = "gemini-3.1-flash-lite",
        reasoningEffort: String = "",
        timeout: TimeInterval = 8.0
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.timeout = timeout
    }
}

public actor CPACleanupClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func cleanup(prompt: String, config: CleanupConfig) async throws -> String {
        let endpointString = config.endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(endpointString)/chat/completions") else {
            throw TranscriptionError.badRequest("Invalid cleanup endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("jot", forHTTPHeaderField: "User-Agent")
        request.setValue("jot", forHTTPHeaderField: "originator")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0
        ]

        let trimmedEffort = config.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmedEffort.isEmpty && trimmedEffort != "none" && trimmedEffort != "off" {
            body["reasoning_effort"] = trimmedEffort
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .timedOut { throw TranscriptionError.timeout }
            throw TranscriptionError.network(error.localizedDescription)
        } catch {
            throw TranscriptionError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.network("Non-HTTP response")
        }

        switch http.statusCode {
        case 200:
            return try Self.extractText(from: data)
        case 401:
            throw TranscriptionError.auth
        case 403, 404:
            let detail = Self.extractErrorMessage(from: data)
            throw TranscriptionError.modelUnavailable(model: config.model, detail: detail)
        case 429:
            throw TranscriptionError.rateLimitedTransient
        case 400:
            let detail = Self.extractErrorMessage(from: data) ?? "Bad request"
            throw TranscriptionError.badRequest(detail)
        default:
            let detail = Self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw TranscriptionError.network(detail)
        }
    }

    private static func extractText(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranscriptionError.network("Malformed cleanup response JSON")
        }
        return content
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }
        if let errorObj = json["error"] as? [String: Any], let msg = errorObj["message"] as? String {
            return msg
        }
        if let errorStr = json["error"] as? String {
            return errorStr
        }
        return nil
    }
}
