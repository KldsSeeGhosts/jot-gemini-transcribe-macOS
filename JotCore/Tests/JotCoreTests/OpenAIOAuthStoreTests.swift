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

    func testNewestIssuedWinsAcrossSources() throws {
        // A signed-out Pi session keeps a parseable file whose token is OLDER
        // than Codex's; the newer-issued credential must be the one used.
        let older = jwt(accountID: "acct_pi", expires: 2_000_000_000, iat: 1_000)
        let newer = jwt(accountID: "acct_codex", expires: 2_000_000_000, iat: 2_000)
        let piLogin = try XCTUnwrap(OpenAIOAuthStore.parse(
            root: ["openai-codex": ["access": older, "refresh": "r", "expires": 2_000_000_000_000, "type": "oauth"]],
            source: .pi, path: URL(fileURLWithPath: "/tmp/pi.json")))
        let codexLogin = try XCTUnwrap(OpenAIOAuthStore.parse(
            root: ["tokens": ["access_token": newer, "refresh_token": "r"]],
            source: .codex, path: URL(fileURLWithPath: "/tmp/codex.json")))
        XCTAssertTrue(codexLogin.newerIssued(than: piLogin))
        XCTAssertFalse(piLogin.newerIssued(than: codexLogin))
    }

    func testStaleTokenNeedsRefreshBeforeExpiry() throws {
        // iat 51 min ago but exp far in the future: stale by age, must refresh.
        let now = Int(Date().timeIntervalSince1970)
        let stale = jwt(accountID: "a", expires: now + 3600, iat: now - 51 * 60)
        let login = try XCTUnwrap(OpenAIOAuthStore.parse(
            root: ["tokens": ["access_token": stale, "refresh_token": "r"]],
            source: .codex, path: URL(fileURLWithPath: "/tmp/x.json")))
        XCTAssertTrue(OpenAIOAuthStore.needsRefresh(login))

        let fresh = jwt(accountID: "a", expires: now + 3600, iat: now - 60)
        let freshLogin = try XCTUnwrap(OpenAIOAuthStore.parse(
            root: ["tokens": ["access_token": fresh, "refresh_token": "r"]],
            source: .codex, path: URL(fileURLWithPath: "/tmp/y.json")))
        XCTAssertFalse(OpenAIOAuthStore.needsRefresh(freshLogin))
    }

    private func jwt(accountID: String, expires: Int, iat: Int? = nil) -> String {
        var payload: [String: Any] = [
            "exp": expires,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": accountID,
            ],
        ]
        if let iat { payload["iat"] = iat }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }
}
