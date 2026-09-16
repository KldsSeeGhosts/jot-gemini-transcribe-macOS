// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0

import XCTest
@testable import JotCore

final class OpenAIRealtimeProtocolTests: XCTestCase {
    func testRealtimeSetupUsesDocumentedAudioFormatAndManualTurns() throws {
        let data = LiveProtocol.setupFrame(
            LiveSetup(
                model: "gpt-transcribe",
                prompt: "Transcribe faithfully.",
                customVocabulary: ["Caelestia"]
            )
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
        XCTAssertEqual(transcription["model"] as? String, "gpt-transcribe")
        XCTAssertEqual(transcription["prompt"] as? String, "Transcribe faithfully.")
        XCTAssertEqual(transcription["keywords"] as? [String], ["Caelestia"])
        XCTAssertNil(transcription["delay"])
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
