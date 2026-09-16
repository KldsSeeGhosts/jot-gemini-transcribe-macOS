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

/// Clears provider-specific values left by a Gemini build while preserving the
/// user's hotkey, history, dictionary, retention, and UI preferences.
public enum OpenAIProviderMigration {
    private static let flag = "didMigrateToOpenAIProvider"

    public static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }

        if let endpoint = defaults.string(forKey: "endpointOverride"),
           endpoint.localizedCaseInsensitiveContains("google") {
            defaults.removeObject(forKey: "endpointOverride")
        }
        if let model = defaults.string(forKey: "transcribeModelOverride"),
           model.localizedCaseInsensitiveContains("gemini") {
            defaults.removeObject(forKey: "transcribeModelOverride")
        }
        if let model = defaults.string(forKey: "liveModelOverride"),
           model.localizedCaseInsensitiveContains("gemini") {
            defaults.removeObject(forKey: "liveModelOverride")
        }
        if let model = defaults.string(forKey: "cleanupModelOverride"),
           model.localizedCaseInsensitiveContains("gemini") {
            defaults.removeObject(forKey: "cleanupModelOverride")
        }
        defaults.removeObject(forKey: "legacyTranscribeEndpoint")

        if KeychainStore.loadAPIKey() == nil {
            defaults.set(false, forKey: "hasCompletedOnboarding")
        }
        defaults.set(true, forKey: flag)
        Log.session.info("OpenAIProviderMigration: provider-specific settings reset")
    }
}
