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

import AVFoundation
import Foundation

/// Converts Jot's crash-safe CAF recording to a compact M4A accepted by
/// OpenAI's file-transcription endpoint. At 64 kbps, the ten-minute recording
/// cap stays well below the endpoint's 25 MB upload limit.
public enum M4AEncoder {
    public struct Output: Sendable {
        public let url: URL
        public let byteCount: Int
        public let encodeSeconds: Double
    }

    public enum EncodeError: Error {
        case readFailed(String)
        case writeFailed(String)
    }

    public static func encode(cafURL: URL, m4aURL: URL) throws -> Output {
        let started = Date()
        try? FileManager.default.removeItem(at: m4aURL)

        let reader: AVAudioFile
        do {
            reader = try AVAudioFile(
                forReading: cafURL,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw EncodeError.readFailed(String(describing: error))
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: reader.processingFormat.sampleRate,
            AVNumberOfChannelsKey: reader.processingFormat.channelCount,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let writer = try AVAudioFile(
                forWriting: m4aURL,
                settings: settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            let chunk = AVAudioPCMBuffer(
                pcmFormat: reader.processingFormat,
                frameCapacity: 65_536
            )!
            while reader.framePosition < reader.length {
                try reader.read(into: chunk)
                if chunk.frameLength == 0 { break }
                try writer.write(from: chunk)
            }
        } catch {
            throw EncodeError.writeFailed(String(describing: error))
        }

        let bytes = ((try? FileManager.default.attributesOfItem(
            atPath: m4aURL.path
        ))?[.size] as? Int) ?? 0
        return Output(
            url: m4aURL,
            byteCount: bytes,
            encodeSeconds: Date().timeIntervalSince(started)
        )
    }
}
