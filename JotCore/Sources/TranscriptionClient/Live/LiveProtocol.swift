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

/// What the server said. Deliberately small: everything the Live API sends that
/// Jot does not act on becomes `nil` rather than a case, so an API that grows new
/// message types does not start throwing in the middle of someone's dictation.
public enum LiveEvent: Equatable, Sendable {
    /// The credential was accepted and the session is configured. Audio sent
    /// before this arrives is buffered, not lost.
    case setupComplete
    /// A transcript delta. The session accumulates these for display only.
    /// This must never reach the cursor, History, or `rawTranscript`.
    case partial(String)
    /// Authoritative text for the committed audio turn.
    case final(String)
    /// The server is closing the session — the 10-minute cap, or its own reasons.
    case goAway
    /// An error envelope. Terminal for the session.
    case failed(String)
}

/// Everything that varies per session.
public struct LiveSetup: Equatable, Sendable {
    public var model: String
    public var prompt: String?
    public var customVocabulary: [String]

    public init(model: String = "gpt-transcribe",
                prompt: String? = nil,
                customVocabulary: [String] = []) {
        self.model = model
        self.prompt = prompt
        self.customVocabulary = customVocabulary
    }
}

/// Frame construction and decoding for OpenAI Realtime, as pure functions
/// over `Data` so every one of them is testable without a socket.
public enum LiveProtocol {

    public static let sampleRate = 24_000

    /// The ONLY place a live setup frame is constructed.
    public static func setupFrame(_ setup: LiveSetup) -> Data {
        var transcription: [String: Any] = ["model": setup.model]
        if let prompt = setup.prompt, !prompt.isEmpty {
            transcription["prompt"] = prompt
        }
        if !setup.customVocabulary.isEmpty {
            transcription["keywords"] = setup.customVocabulary
        }
        let frame: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": sampleRate,
                        ],
                        "noise_reduction": ["type": "near_field"],
                        "transcription": transcription,
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: frame)) ?? Data()
    }

    private static let audioFramePrefix = Data("{\"type\":\"input_audio_buffer.append\",\"audio\":\"".utf8)
    private static let audioFrameSuffix = Data("\"}".utf8)

    public static func audioFrame(_ pcm: Data) -> Data {
        let base64 = pcm.base64EncodedData()
        var frame = Data()
        frame.reserveCapacity(audioFramePrefix.count + base64.count + audioFrameSuffix.count)
        frame.append(audioFramePrefix)
        frame.append(base64)
        frame.append(audioFrameSuffix)
        return frame
    }

    public static func activityStartFrame() -> Data {
        Data()
    }

    public static func activityEndFrame() -> Data {
        (try? JSONSerialization.data(withJSONObject: [
            "type": "input_audio_buffer.commit",
        ])) ?? Data()
    }

    /// Decodes one server frame.
    ///
    /// Returns nil for anything unrecognised. That is deliberate: an unknown
    /// message is not a reason to tear down a session that is otherwise
    /// transcribing someone's sentence, and the fallback to the batch path is
    /// reserved for failures that actually cost words.
    ///
    /// Order matters. `interimInputTranscription` is checked before
    /// `inputTranscription` because a single frame may carry both, and treating
    /// an interim as final is the one mistake in this file that puts speculative
    /// text on the user's cursor.
    public static func decode(_ data: Data) -> LiveEvent? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let type = root["type"] as? String
        if type == "session.updated" || type == "transcription_session.updated" {
            return .setupComplete
        }
        if let error = root["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown live error"
            return .failed(message)
        }
        if type == "conversation.item.input_audio_transcription.delta",
           let delta = root["delta"] as? String,
           !delta.isEmpty {
            return .partial(delta)
        }
        if type == "conversation.item.input_audio_transcription.completed"
            || type == "input_audio_transcription.completed",
           let transcript = root["transcript"] as? String {
            return .final(transcript)
        }
        if type == "session.closed" || type == "connection.closed" {
            return .goAway
        }
        return nil
    }
}
