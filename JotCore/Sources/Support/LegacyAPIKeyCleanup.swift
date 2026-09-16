// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0

import Foundation
import Security

/// Deletes credentials written by the short-lived API-key build. Jot's shipping
/// OpenAI path uses the user's existing Codex OAuth session only.
enum LegacyAPIKeyCleanup {
    static func run() {
        for account in ["openai-api-key", "gemini-api-key"] {
            for dataProtection in [true, false] {
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: "com.ammaar.jot",
                    kSecAttrAccount as String: account,
                ]
                if dataProtection {
                    query[kSecUseDataProtectionKeychain as String] = true
                }
                SecItemDelete(query as CFDictionary)
            }
        }
        NotificationCenter.default.post(
            name: .gtSettingDidChange,
            object: "oauth"
        )
    }
}
