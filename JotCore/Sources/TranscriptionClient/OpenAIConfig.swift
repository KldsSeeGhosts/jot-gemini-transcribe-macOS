// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0

import Foundation

public struct OpenAIConfig: Sendable, Equatable {
    /// Retained for preferences compatibility. OAuth transcription always uses
    /// the fixed OpenAI Realtime WebSocket endpoint.
    public var endpoint: URL
    public var transcribeModel: String
    public var liveModel: String
    /// Retained so older preferences and downstream code continue to decode.
    /// The OAuth build performs formatting in the transcription prompt.
    public var cleanupModel: String

    public init(
        endpoint: URL = URL(string: "https://api.openai.com")!,
        transcribeModel: String = "gpt-transcribe",
        liveModel: String = "gpt-transcribe",
        cleanupModel: String = "gpt-5-mini"
    ) {
        self.endpoint = endpoint
        self.transcribeModel = transcribeModel
        self.liveModel = liveModel
        self.cleanupModel = cleanupModel
    }
}
