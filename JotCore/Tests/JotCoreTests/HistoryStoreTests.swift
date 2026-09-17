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

final class HistoryStoreTests: XCTestCase {
    private var root: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("recordings", isDirectory: true),
            withIntermediateDirectories: true
        )
        store = try HistoryStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession(status: SessionMeta.Status, transcript: String?, onDisk: Bool) throws -> SessionMeta {
        var meta = SessionMeta(id: UUID(), startedAt: Date(), status: status)
        meta.rawTranscript = transcript
        let folder = root
            .appendingPathComponent("recordings", isDirectory: true)
            .appendingPathComponent(meta.id.uuidString, isDirectory: true)
        if onDisk {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            meta.write(to: folder)
        }
        store.upsert(meta: meta, folder: folder)
        return meta
    }

    /// Rows whose folders vanished must be pruned even when the visibility
    /// filter hides them (silent / short-cancelled) — otherwise they linger as
    /// invisible ghosts forever and the DB stops mirroring the disk.
    func testReindexPrunesInvisibleOrphans() throws {
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        _ = try makeSession(status: .silent, transcript: nil, onDisk: false)
        _ = try makeSession(status: .cancelled, transcript: nil, onDisk: false)
        let keptVisible = try makeSession(status: .inserted, transcript: "hello there", onDisk: true)
        let keptInvisible = try makeSession(status: .silent, transcript: nil, onDisk: true)

        store.reindex(recordingsRoot: recordings)

        let remaining = Set(store.allIDsForTesting())
        XCTAssertEqual(remaining, [keptVisible.id.uuidString, keptInvisible.id.uuidString])
    }

    func testReindexKeepsRowsWithFolders() throws {
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        let kept = try makeSession(status: .inserted, transcript: "still here", onDisk: true)
        store.reindex(recordingsRoot: recordings)
        XCTAssertEqual(store.allIDsForTesting(), [kept.id.uuidString])
    }

    func testMigrationV3WordCountAndStats() throws {
        var meta1 = SessionMeta(id: UUID(), startedAt: Date(), status: .inserted)
        meta1.cleanedTranscript = "One two three four"
        meta1.audioDurationSeconds = 12.0
        let folder1 = root.appendingPathComponent("recordings/\(meta1.id.uuidString)")
        store.upsert(meta: meta1, folder: folder1)

        let record1 = store.records().first { $0.id == meta1.id.uuidString }
        XCTAssertEqual(record1?.wordCount, 4)

        var meta2 = SessionMeta(id: UUID(), startedAt: Date(), status: .inserted)
        meta2.cleanedTranscript = "Five six seven"
        meta2.audioDurationSeconds = 8.0
        let folder2 = root.appendingPathComponent("recordings/\(meta2.id.uuidString)")
        store.upsert(meta: meta2, folder: folder2)

        let stats = store.stats()
        XCTAssertEqual(stats.totalDictations, 2)
        XCTAssertEqual(stats.totalWords, 7)
        // 7 words over 20 seconds = 7 / (20/60) = 21 WPM
        XCTAssertEqual(stats.averageWPM, 21)
    }

    func testReindexBatchesNotification() throws {
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        for i in 0..<5 {
            var meta = SessionMeta(id: UUID(), startedAt: Date(), status: .inserted)
            meta.cleanedTranscript = "Session \(i)"
            let folder = recordings.appendingPathComponent(meta.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            meta.write(to: folder)
        }

        var notificationCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .gtHistoryDidChange,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        store.reindex(recordingsRoot: recordings)
        XCTAssertEqual(notificationCount, 1, "reindex should post exactly one change notification for all folders")
    }
}
