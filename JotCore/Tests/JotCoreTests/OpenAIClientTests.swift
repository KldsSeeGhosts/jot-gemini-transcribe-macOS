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

import XCTest
@testable import JotCore

final class OpenAIClientTests: XCTestCase {
    func testExtractsFileTranscript() throws {
        let data = Data(#"{"text":"Ship it Friday.","languages":[{"code":"en"}]}"#.utf8)
        XCTAssertEqual(
            try OpenAIClient.extractTranscript(from: data),
            "Ship it Friday."
        )
    }

    func testExtractsResponsesOutputText() throws {
        let data = Data("""
        {
          "output": [{
            "type": "message",
            "content": [
              {"type": "output_text", "text": "Let's meet at 3."}
            ]
          }]
        }
        """.utf8)
        XCTAssertEqual(
            try OpenAIClient.extractResponseText(from: data),
            "Let's meet at 3."
        )
    }

    func testExtractsOpenAIErrorEnvelope() {
        let data = Data("""
        {"error":{"message":"Incorrect API key provided","type":"invalid_request_error","code":"invalid_api_key"}}
        """.utf8)
        XCTAssertEqual(
            OpenAIClient.errorMessage(from: data),
            "Incorrect API key provided"
        )
        XCTAssertEqual(OpenAIClient.errorCode(from: data), "invalid_api_key")
    }

    func testRealtimeSetupUsesDocumentedAudioFormatAndManualTurns() throws {
        let data = LiveProtocol.setupFrame(
            LiveSetup(model: "gpt-live-transcribe", customVocabulary: ["Caelestia"])
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["type"] as? String, "session.update")
        let session = try XCTUnwrap(root["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000)
        XCTAssertTrue(input["turn_detection"] is NSNull)
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-live-transcribe")
        XCTAssertEqual(transcription["keywords"] as? [String], ["Caelestia"])
    }

    func testRealtimeDecoderHandlesDeltaAndFinal() {
        let delta = Data("""
        {"type":"conversation.item.input_audio_transcription.delta","delta":"Hello"}
        """.utf8)
        let final = Data("""
        {"type":"conversation.item.input_audio_transcription.completed","transcript":"Hello there."}
        """.utf8)
        XCTAssertEqual(LiveProtocol.decode(delta), .partial("Hello"))
        XCTAssertEqual(LiveProtocol.decode(final), .final("Hello there."))
    }
}
