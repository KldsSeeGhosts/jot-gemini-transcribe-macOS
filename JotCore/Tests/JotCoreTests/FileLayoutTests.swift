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

final class FileLayoutTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        FileLayout.overrideRoot = tempDir
    }

    override func tearDown() {
        FileLayout.overrideRoot = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    func testMakeSessionFolderCreatesDirectoryWithTimestampFormat() throws {
        let id = UUID()
        // Use fixed epoch date: 2026-09-16 12:34:56 UTC
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 16
        components.hour = 12
        components.minute = 34
        components.second = 56
        components.timeZone = TimeZone.current
        let date = try XCTUnwrap(Calendar.current.date(from: components))

        let folder = try FileLayout.makeSessionFolder(id: id, now: date)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(folder.lastPathComponent.contains("20260916-123456"))
        XCTAssertTrue(folder.lastPathComponent.hasSuffix(String(id.uuidString.prefix(8))))
    }
}
