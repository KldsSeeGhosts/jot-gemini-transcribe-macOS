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

import Darwin
import Foundation

/// Reuses the local OpenAI Codex OAuth login created by Pi or Codex.
///
/// Pi is checked first because Jot's Linux reference implementation uses the
/// same file and lock convention. Tokens never enter UserDefaults or Jot's
/// Keychain. A refresh updates the source file atomically so Pi can reuse it.
public actor OpenAIOAuthStore {
    public enum Source: String, Equatable, Sendable {
        case pi = "Pi"
        case codex = "Codex"
    }

    public struct Login: Sendable {
        public let source: Source
        public let path: URL
        let accessToken: String
        let refreshToken: String
        let accountID: String
        let expiresAt: Date
    }

    public enum OAuthError: Error, Equatable, Sendable {
        case loginMissing
        case invalidLogin
        case refreshFailed(String)
    }

    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let minimumValidity: TimeInterval = 5 * 60

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: configuration)
    }

    public nonisolated static func credentialLocations() -> [(Source, URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var locations: [(Source, URL)] = []
        if let override = ProcessInfo.processInfo.environment["OPENAI_DICTATION_AUTH"],
           !override.isEmpty {
            locations.append((.pi, URL(fileURLWithPath: override)))
        }
        locations.append((
            .pi,
            home.appendingPathComponent(".pi/agent/auth.json")
        ))
        locations.append((
            .codex,
            home.appendingPathComponent(".codex/auth.json")
        ))
        return locations
    }

    public nonisolated static func localLoginSource() -> Source? {
        for (source, url) in credentialLocations() {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  parse(root: root, source: source, path: url) != nil
            else { continue }
            return source
        }
        return nil
    }

    public nonisolated static func hasLocalLogin() -> Bool {
        localLoginSource() != nil
    }

    public func authorizationHeaders() async throws -> [String: String] {
        var login = try loadLogin()
        if login.expiresAt.timeIntervalSinceNow < Self.minimumValidity {
            login = try await refresh(login)
        }
        return [
            "Authorization": "Bearer \(login.accessToken)",
            "chatgpt-account-id": login.accountID,
            "originator": "jot-openai-transcribe-macos",
            "x-session-id": UUID().uuidString,
            "user-agent": "jot-openai-transcribe-macos/0.4",
        ]
    }

    public func activeSource() throws -> Source {
        try loadLogin().source
    }

    private func loadLogin() throws -> Login {
        var foundFile = false
        for (source, url) in Self.credentialLocations() {
            guard let data = try? Data(contentsOf: url) else { continue }
            foundFile = true
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let login = Self.parse(root: root, source: source, path: url)
            else { continue }
            return login
        }
        throw foundFile ? OAuthError.invalidLogin : OAuthError.loginMissing
    }

    static func parse(root: [String: Any], source: Source, path: URL) -> Login? {
        let node: [String: Any]
        let access: String?
        let refresh: String?
        let accountID: String?
        let expiration: Date?

        switch source {
        case .pi:
            guard let credentials = root["openai-codex"] as? [String: Any],
                  credentials["type"] as? String == "oauth" else { return nil }
            node = credentials
            access = node["access"] as? String
            refresh = node["refresh"] as? String
            accountID = node["accountId"] as? String
                ?? access.flatMap(accountIDFromJWT)
            if let milliseconds = node["expires"] as? Double {
                expiration = Date(timeIntervalSince1970: milliseconds / 1_000)
            } else if let milliseconds = node["expires"] as? Int {
                expiration = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            } else {
                expiration = access.flatMap(expirationFromJWT)
            }
        case .codex:
            guard let credentials = root["tokens"] as? [String: Any] else { return nil }
            node = credentials
            access = node["access_token"] as? String
            refresh = node["refresh_token"] as? String
            accountID = node["account_id"] as? String
                ?? access.flatMap(accountIDFromJWT)
            expiration = access.flatMap(expirationFromJWT)
        }

        guard let access, !access.isEmpty,
              let refresh, !refresh.isEmpty,
              let accountID, !accountID.isEmpty
        else { return nil }
        return Login(
            source: source,
            path: path,
            accessToken: access,
            refreshToken: refresh,
            accountID: accountID,
            expiresAt: expiration ?? .distantPast
        )
    }

    private func refresh(_ login: Login) async throws -> Login {
        let lockURL = URL(fileURLWithPath: login.path.path + ".lock", isDirectory: true)
        try await acquireLock(at: lockURL)
        defer { try? FileManager.default.removeItem(at: lockURL) }

        // Another process may have refreshed while this process waited.
        if let data = try? Data(contentsOf: login.path),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let current = Self.parse(
               root: root,
               source: login.source,
               path: login.path
           ),
           current.expiresAt.timeIntervalSinceNow >= Self.minimumValidity {
            return current
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: login.refreshToken),
            URLQueryItem(name: "client_id", value: Self.clientID),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OAuthError.refreshFailed("network")
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = payload["access_token"] as? String,
              let refresh = payload["refresh_token"] as? String,
              let expiresIn = payload["expires_in"] as? Double ?? (payload["expires_in"] as? Int).map(Double.init),
              let accountID = Self.accountIDFromJWT(access)
        else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OAuthError.refreshFailed("http_\(status)")
        }

        let refreshed = Login(
            source: login.source,
            path: login.path,
            accessToken: access,
            refreshToken: refresh,
            accountID: accountID,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
        try write(refreshed)
        return refreshed
    }

    private func write(_ login: Login) throws {
        let data = try Data(contentsOf: login.path)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw OAuthError.invalidLogin }

        switch login.source {
        case .pi:
            var node = root["openai-codex"] as? [String: Any] ?? [:]
            node["access"] = login.accessToken
            node["refresh"] = login.refreshToken
            node["expires"] = Int(login.expiresAt.timeIntervalSince1970 * 1_000)
            node["accountId"] = login.accountID
            node["type"] = "oauth"
            root["openai-codex"] = node
        case .codex:
            var node = root["tokens"] as? [String: Any] ?? [:]
            node["access_token"] = login.accessToken
            node["refresh_token"] = login.refreshToken
            node["account_id"] = login.accountID
            root["tokens"] = node
            root["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        }

        let output = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        let temporary = login.path.deletingLastPathComponent()
            .appendingPathComponent(".\(login.path.lastPathComponent).jot-\(UUID().uuidString)")
        try output.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporary.path
        )
        guard Darwin.rename(temporary.path, login.path.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: login.path.path
        )
    }

    private func acquireLock(at url: URL) async throws {
        for _ in 0..<20 {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return
            } catch {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let modified = attributes[.modificationDate] as? Date,
                   Date().timeIntervalSince(modified) > 30 {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw OAuthError.refreshFailed("credential_lock_busy")
    }

    static func accountIDFromJWT(_ token: String) -> String? {
        guard let payload = jwtPayload(token),
              let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        else { return nil }
        return auth["chatgpt_account_id"] as? String
    }

    static func expirationFromJWT(_ token: String) -> Date? {
        guard let payload = jwtPayload(token) else { return nil }
        if let value = payload["exp"] as? Double {
            return Date(timeIntervalSince1970: value)
        }
        if let value = payload["exp"] as? Int {
            return Date(timeIntervalSince1970: Double(value))
        }
        return nil
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    deinit {
        session.invalidateAndCancel()
    }
}
