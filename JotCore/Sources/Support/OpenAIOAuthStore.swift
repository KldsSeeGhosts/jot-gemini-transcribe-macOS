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
        /// JWT `iat`, when the token is a JWT. Used to treat a credential that
        /// has simply been alive too long as suspect even before `expiresAt`.
        let issuedAt: Date?

        /// True when this credential was issued more recently than `other`.
        /// A nil `issuedAt` sorts oldest so an undated token never wins.
        func newerIssued(than other: Login?) -> Bool {
            guard let other else { return true }
            return (issuedAt ?? .distantPast) > (other.issuedAt ?? .distantPast)
        }
    }

    public enum OAuthError: Error, Equatable, Sendable {
        case loginMissing
        case invalidLogin
        case refreshFailed(String)
    }

    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let minimumValidity: TimeInterval = 5 * 60
    /// A token older than this is refreshed even before it expires. Mirrors the
    /// reference daemon's `authExpires` (50 min): a credential alive this long
    /// is often already invalidated server-side, so pre-emptive refresh keeps
    /// the warm socket from ever carrying a corpse token.
    private static let maximumAge: TimeInterval = 50 * 60

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
        let login = try await usableLogin()
        return headers(for: login)
    }

    /// Force a refresh round-trip regardless of the stored expiry. The server
    /// can invalidate an access token while the local `expires` still says
    /// fresh (a revoked or signed-out session), so a `token_invalidated`
    /// rejection must be retried against a NEW token, not the same cached one.
    /// If that source's refresh token is also dead, falls through to the next
    /// credential location instead of failing the dictation.
    public func forceAuthorizationHeaders() async throws -> [String: String] {
        let login = try await usableLogin(forceRefresh: true)
        return headers(for: login)
    }

    private func headers(for login: Login) -> [String: String] {
        return [
            "Authorization": "Bearer \(login.accessToken)",
            "chatgpt-account-id": login.accountID,
            "originator": "jot-openai-transcribe-macos",
            "x-session-id": UUID().uuidString,
            "user-agent": "jot-openai-transcribe-macos/0.4",
        ]
    }

    /// Resolve a login, refreshing when expired (or always, when forced).
    /// `forceRefresh` additionally retries other credential sources when the
    /// first one's refresh token has been invalidated — a dead Pi session
    /// should not keep a working Codex login from being used.
    private func usableLogin(forceRefresh: Bool = false) async throws -> Login {
        var login = try loadLogin()
        if forceRefresh || Self.needsRefresh(login) {
            do {
                login = try await refresh(login)
            } catch {
                if let fallback = try nextLogin(excludingPath: login.path) {
                    login = fallback
                    if forceRefresh || Self.needsRefresh(login) {
                        login = try await refresh(login)
                    }
                } else {
                    throw error
                }
            }
        }
        return login
    }

    /// The parseable credentials EXCLUDING the one at `excludingPath`, picking
    /// the most recently issued. Lets an invalidated Pi session drop through to
    /// Codex without a re-login.
    private func nextLogin(excludingPath: URL) throws -> Login? {
        var best: Login?
        for (candidate, url) in Self.credentialLocations() {
            guard url.standardizedFileURL != excludingPath.standardizedFileURL else { continue }
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let login = Self.parse(root: root, source: candidate, path: url)
            else { continue }
            if login.newerIssued(than: best) { best = login }
        }
        return best
    }

    /// True when the token is at/past expiry OR has simply been alive too
    /// long. The age check is what catches a token invalidated server-side
    /// while its stored `expires` still reads fresh.
    static func needsRefresh(_ login: Login) -> Bool {
        if login.expiresAt.timeIntervalSinceNow < minimumValidity { return true }
        if let issued = login.issuedAt,
           Date().timeIntervalSince(issued) >= maximumAge { return true }
        return false
    }

    public func activeSource() throws -> Source {
        try loadLogin().source
    }

    private func loadLogin() throws -> Login {
        var foundFile = false
        var best: Login?
        for (source, url) in Self.credentialLocations() {
            guard let data = try? Data(contentsOf: url) else { continue }
            foundFile = true
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let login = Self.parse(root: root, source: source, path: url)
            else { continue }
            // Prefer the most recently ISSUED credential, not the first file.
            // A signed-out Pi session keeps a parseable file with a dead
            // refresh token; Codex's newer login must win so the warm socket
            // and the batch path both reach a live token. `iat` order is the
            // same order OpenAI's own CLIs use to pick the active credential.
            if login.newerIssued(than: best) { best = login }
        }
        if let best { return best }
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
            expiresAt: expiration ?? .distantPast,
            issuedAt: issuedAtFromJWT(access)
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
            expiresAt: Date().addingTimeInterval(expiresIn),
            issuedAt: Self.issuedAtFromJWT(access)
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

    static func issuedAtFromJWT(_ token: String) -> Date? {
        guard let payload = jwtPayload(token) else { return nil }
        if let value = payload["iat"] as? Double {
            return Date(timeIntervalSince1970: value)
        }
        if let value = payload["iat"] as? Int {
            return Date(timeIntervalSince1970: Double(value))
        }
        return nil
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
