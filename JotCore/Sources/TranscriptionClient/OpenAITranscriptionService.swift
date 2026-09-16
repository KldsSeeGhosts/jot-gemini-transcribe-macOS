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

/// OpenAI transcription with Jot's existing recovery and guarded formatting
/// behavior. Recorded audio uses the file endpoint; live sessions use the same
/// cleanup method after their final transcript arrives.
public struct OpenAITranscriptionService: TranscriptionServicing {
    private let client: OpenAIClient
    private let settings: SettingsStore
    static let cleanupDeadline: TimeInterval = 2.5

    public init(client: OpenAIClient, settings: SettingsStore = SettingsStore()) {
        self.client = client
        self.settings = settings
    }

    public func transcribe(
        audioURL: URL,
        durationSeconds: Double,
        context: DictationContext
    ) async throws -> TranscriptionResult {
        let config = settings.openAIConfig
        let m4aURL = audioURL.deletingLastPathComponent().appendingPathComponent("audio.m4a")
        let encoded = try M4AEncoder.encode(cafURL: audioURL, m4aURL: m4aURL)
        Log.transcription.info(
            "M4A \(encoded.byteCount) bytes in \(Int(encoded.encodeSeconds * 1000))ms"
        )
        defer { try? FileManager.default.removeItem(at: encoded.url) }
        let audioData = try Data(contentsOf: encoded.url)

        let vocabulary = DictionaryStore().sanitizedVocabulary()
        let deadline = TimeoutPolicy.overallDeadline(audioDuration: durationSeconds)
        var raw = try await transcribeWithRetry(
            audioData: audioData,
            config: config,
            vocabulary: vocabulary,
            deadline: deadline
        )
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, durationSeconds >= 0.6 {
            raw = (try? await sendTranscribe(
                audioData: audioData,
                config: config,
                vocabulary: vocabulary,
                deadline: deadline
            )) ?? ""
            trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { throw TranscriptionError.emptyTranscript }

        let cleaned = await clean(raw: trimmed, context: context)
        let usesCleanup = settings.smartTranscriptionEnabled
            || settings.smartCleanupPassEnabled
        return TranscriptionResult(
            rawTranscript: trimmed,
            cleanedTranscript: cleaned,
            modelID: usesCleanup
                ? "\(config.transcribeModel)+\(config.cleanupModel)"
                : config.transcribeModel
        )
    }

    /// Shared by recorded and live transcription so enabling live mode does not
    /// change Jot's formatting or dictionary behavior.
    public func clean(raw: String, context: DictationContext) async -> String {
        let dictionary = DictionaryStore()
        let wantsSmart = settings.smartTranscriptionEnabled
        let wantsTone = settings.smartCleanupPassEnabled
        guard wantsSmart || wantsTone else {
            return ReplacementEngine.apply(dictionary.replacementRules(), to: raw)
        }

        let tone = wantsTone
            ? PromptV1.toneCategory(forBundleID: context.targetAppBundleID)
            : .neutral
        let prompt = PromptV1.cleanupPrompt(
            raw: raw,
            tone: tone,
            vocabulary: dictionary.sanitizedVocabulary(),
            spellings: dictionary.spellings()
        )
        do {
            let config = settings.openAIConfig
            let response = try await client.cleanup(
                prompt: prompt,
                model: config.cleanupModel,
                endpoint: config.endpoint,
                deadline: Self.cleanupDeadline
            )
            let cleaned = ValidationGate.stripArtifacts(response)
            let verdict = ValidationGate.validate(raw: raw, cleaned: cleaned)
            guard verdict.accepted else {
                let trips = settings.recordGateTrip()
                Log.transcription.warning(
                    "cleanup gate rejected (\(verdict.reason ?? "?", privacy: .public), trip #\(trips) in 24h), inserting raw"
                )
                autoDegradeIfNeeded(trips: trips)
                return ReplacementEngine.apply(dictionary.replacementRules(), to: raw)
            }
            return ReplacementEngine.apply(dictionary.replacementRules(), to: cleaned)
        } catch {
            Log.transcription.info(
                "cleanup unavailable (\(String(describing: error), privacy: .public)), inserting raw"
            )
            return ReplacementEngine.apply(dictionary.replacementRules(), to: raw)
        }
    }

    private func sendTranscribe(
        audioData: Data,
        config: OpenAIConfig,
        vocabulary: [String],
        deadline: TimeInterval
    ) async throws -> String {
        let prompt = vocabulary.isEmpty
            ? nil
            : "Expected names and technical terms: \(vocabulary.joined(separator: ", "))."
        return try await client.transcribe(
            audioData: audioData,
            model: config.transcribeModel,
            endpoint: config.endpoint,
            deadline: deadline,
            prompt: prompt,
            keywords: vocabulary
        )
    }

    private func transcribeWithRetry(
        audioData: Data,
        config: OpenAIConfig,
        vocabulary: [String],
        deadline: TimeInterval
    ) async throws -> String {
        do {
            return try await sendTranscribe(
                audioData: audioData,
                config: config,
                vocabulary: vocabulary,
                deadline: deadline
            )
        } catch let error as TranscriptionError {
            switch error {
            case .network, .timeout, .rateLimitedTransient:
                try await Task.sleep(nanoseconds: 500_000_000)
                return try await sendTranscribe(
                    audioData: audioData,
                    config: config,
                    vocabulary: vocabulary,
                    deadline: deadline
                )
            default:
                throw error
            }
        }
    }

    private func autoDegradeIfNeeded(trips: Int) {
        guard trips >= 3 else { return }
        if settings.smartCleanupPassEnabled {
            settings.setSmartCleanupPass(false)
        } else if settings.smartTranscriptionEnabled {
            settings.setSmartTranscription(false)
        }
        NotificationCenter.default.post(
            name: .gtSmartFormattingAutoDegraded,
            object: nil
        )
        Log.transcription.warning(
            "cleanup unreliable after 3 gate trips in 24h, smart formatting disabled"
        )
    }
}
