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

public struct OpenAIConfig: Sendable, Equatable {
    public var endpoint: URL
    public var transcribeModel: String
    public var liveModel: String
    public var cleanupModel: String

    public init(
        endpoint: URL = URL(string: "https://api.openai.com")!,
        transcribeModel: String = "gpt-transcribe",
        liveModel: String = "gpt-live-transcribe",
        cleanupModel: String = "gpt-5-mini"
    ) {
        self.endpoint = endpoint
        self.transcribeModel = transcribeModel
        self.liveModel = liveModel
        self.cleanupModel = cleanupModel
    }
}

/// The two OpenAI HTTP calls used outside the live socket: recorded-audio
/// transcription and the optional guarded cleanup pass.
public actor OpenAIClient {
    public enum KeyCheck: Equatable, Sendable {
        case valid
        case rejected(String?)
        case unreachable
    }

    private let session: URLSession
    private let apiKey: @Sendable () -> String?

    public init(apiKey: @escaping @Sendable () -> String?) {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
        self.apiKey = apiKey
    }

    public func transcribe(
        audioData: Data,
        model: String,
        endpoint: URL,
        deadline: TimeInterval,
        prompt: String?,
        keywords: [String]
    ) async throws -> String {
        let boundary = "Jot-\(UUID().uuidString)"
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }

        appendField("model", model)
        if let prompt, !prompt.isEmpty { appendField("prompt", prompt) }
        for keyword in keywords {
            appendField("keywords[]", keyword)
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".utf8
        ))
        body.append(Data("Content-Type: audio/mp4\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let data = try await post(
            path: "v1/audio/transcriptions",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            endpoint: endpoint,
            deadline: deadline,
            model: model
        )
        return try Self.extractTranscript(from: data)
    }

    public func cleanup(
        prompt: String,
        model: String,
        endpoint: URL,
        deadline: TimeInterval
    ) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": prompt,
            "max_output_tokens": 4_096,
        ])
        let data = try await post(
            path: "v1/responses",
            body: body,
            contentType: "application/json",
            endpoint: endpoint,
            deadline: deadline,
            model: model
        )
        return try Self.extractResponseText(from: data)
    }

    public func validateKey(endpoint: URL) async -> KeyCheck {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/models"))
        request.timeoutInterval = 10
        applyAuth(&request)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .unreachable
        }
        switch http.statusCode {
        case 200:
            return .valid
        case 401, 403:
            return .rejected(Self.errorMessage(from: data))
        case 500...599:
            return .unreachable
        default:
            return .rejected(Self.errorMessage(from: data))
        }
    }

    public func resolveAvailableModel(from candidates: [String], endpoint: URL) async -> String? {
        for model in candidates {
            var request = URLRequest(url: endpoint.appendingPathComponent("v1/models/\(model)"))
            request.timeoutInterval = 8
            applyAuth(&request)
            guard let (_, response) = try? await session.data(for: request) else { continue }
            if (response as? HTTPURLResponse)?.statusCode == 200 { return model }
        }
        return nil
    }

    private func post(
        path: String,
        body: Data,
        contentType: String,
        endpoint: URL,
        deadline: TimeInterval,
        model: String
    ) async throws -> Data {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = deadline
        request.httpBody = body
        applyAuth(&request)
        let finalRequest = request

        let result: (Data, URLResponse)
        do {
            result = try await Self.withDeadline(seconds: deadline) {
                try await self.session.data(for: finalRequest)
            }
        } catch is DeadlineExceeded {
            throw TranscriptionError.timeout
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed:
                throw TranscriptionError.network(error.localizedDescription)
            case .timedOut:
                throw TranscriptionError.timeout
            default:
                throw TranscriptionError.network(error.localizedDescription)
            }
        }

        let (data, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.network("invalid_response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = Self.errorMessage(from: data)
            Log.transcription.error(
                "OpenAIClient: \(http.statusCode) on \(path, privacy: .public) (\(model, privacy: .public)): \(detail ?? "no detail", privacy: .private)"
            )
            switch http.statusCode {
            case 400:
                throw TranscriptionError.badRequest(detail ?? "invalid_request")
            case 401:
                throw TranscriptionError.auth
            case 403, 404:
                throw TranscriptionError.modelUnavailable(model: model, detail: detail)
            case 429:
                let code = Self.errorCode(from: data)?.lowercased() ?? ""
                if code.contains("insufficient_quota") || code.contains("billing") {
                    throw TranscriptionError.rateLimitedDaily
                }
                throw TranscriptionError.rateLimitedTransient
            case 500...599:
                throw TranscriptionError.network("http_\(http.statusCode)")
            default:
                throw TranscriptionError.network("http_\(http.statusCode)")
            }
        }
        return data
    }

    private func applyAuth(_ request: inout URLRequest) {
        if let key = apiKey(), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    static func extractTranscript(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = root["text"] as? String else {
            throw TranscriptionError.network("unparseable_transcription_response")
        }
        return text
    }

    static func extractResponseText(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.network("unparseable_cleanup_response")
        }
        if let direct = root["output_text"] as? String, !direct.isEmpty {
            return direct
        }
        let output = root["output"] as? [[String: Any]] ?? []
        return output
            .filter { ($0["type"] as? String) == "message" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .compactMap { item -> String? in
                guard (item["type"] as? String) == "output_text" else { return nil }
                return item["text"] as? String
            }
            .joined()
    }

    static func errorMessage(from data: Data) -> String? {
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = root?["error"] as? [String: Any]
        return error?["message"] as? String
    }

    static func errorCode(from data: Data) -> String? {
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let error = root?["error"] as? [String: Any]
        return error?["code"] as? String ?? error?["type"] as? String
    }

    struct DeadlineExceeded: Error {}

    static func withDeadline<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)
                )
                throw DeadlineExceeded()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw DeadlineExceeded() }
            return first
        }
    }

    deinit {
        session.invalidateAndCancel()
    }
}
