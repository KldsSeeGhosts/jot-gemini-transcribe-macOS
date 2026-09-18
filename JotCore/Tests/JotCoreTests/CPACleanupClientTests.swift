// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0

import XCTest
@testable import JotCore

final class CPACleanupClientTests: XCTestCase {
    final class MockURLProtocol: URLProtocol {
        static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = MockURLProtocol.requestHandler else {
                XCTFail("No requestHandler set")
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeClient() -> (CPACleanupClient, CleanupConfig) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = CPACleanupClient(session: session)
        let cleanupConfig = CleanupConfig(
            endpoint: URL(string: "https://test.local/v1")!,
            apiKey: "test-key",
            model: "gemini-3.1-flash-lite",
            reasoningEffort: "",
            timeout: 5.0
        )
        return (client, cleanupConfig)
    }

    func testCleanupSuccess() async throws {
        let (client, config) = makeClient()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")

            let responseJSON = """
            {
                "id": "resp-123",
                "object": "chat.completion",
                "choices": [{
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": "Cleaned sentence."
                    }
                }]
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseJSON.data(using: .utf8)!)
        }

        let cleaned = try await client.cleanup(prompt: "RAW: messy speech\\nCLEAN:", config: config)
        XCTAssertEqual(cleaned, "Cleaned sentence.")
    }

    func testCleanupAuthError() async throws {
        let (client, config) = makeClient()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await client.cleanup(prompt: "text", config: config)
            XCTFail("Expected auth error")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .auth)
        }
    }

    func testCleanupModelUnavailable() async throws {
        let (client, config) = makeClient()
        MockURLProtocol.requestHandler = { request in
            let responseJSON = """
            {"error": {"message": "Model not found"}}
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseJSON.data(using: .utf8)!)
        }

        do {
            _ = try await client.cleanup(prompt: "text", config: config)
            XCTFail("Expected modelUnavailable error")
        } catch let error as TranscriptionError {
            if case .modelUnavailable(let model, let detail) = error {
                XCTAssertEqual(model, "gemini-3.1-flash-lite")
                XCTAssertEqual(detail, "Model not found")
            } else {
                XCTFail("Wrong error: \(error)")
            }
        }
    }
}
