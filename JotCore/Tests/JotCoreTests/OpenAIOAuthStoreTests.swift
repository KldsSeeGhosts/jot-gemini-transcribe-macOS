// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0

import XCTest
@testable import JotCore

final class OpenAIOAuthStoreTests: XCTestCase {
    func testParsesPiOAuthShape() throws {
        let access = jwt(accountID: "acct_pi", expires: 2_000_000_000)
        let root: [String: Any] = [
            "openai-codex": [
                "access": access,
                "refresh": "refresh",
                "expires": 2_000_000_000_000,
                "accountId": "acct_pi",
                "type": "oauth",
            ],
        ]
        let login = try XCTUnwrap(OpenAIOAuthStore.parse(
            root: root,
            source: .pi,
            path: URL(fileURLWithPath: "/tmp/auth.json")
        ))
        XCTAssertEqual(login.source, .pi)
        XCTAssertEqual(login.accountID, "acct_pi")
    }

    func testParsesCodexOAuthShapeAndJWTAccount() throws {
        let access = jwt(accountID: "acct_codex", expires: 2_000_000_000)
        let root: [String: Any] = [
            "tokens": [
                "access_token": access,
                "refresh_token": "refresh",
            ],
        ]
        let login = try XCTUnwrap(OpenAIOAuthStore.parse(
            root: root,
            source: .codex,
            path: URL(fileURLWithPath: "/tmp/auth.json")
        ))
        XCTAssertEqual(login.source, .codex)
        XCTAssertEqual(login.accountID, "acct_codex")
        XCTAssertEqual(
            Int(login.expiresAt.timeIntervalSince1970),
            2_000_000_000
        )
    }

    private func jwt(accountID: String, expires: Int) -> String {
        let payload: [String: Any] = [
            "exp": expires,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": accountID,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }
}
