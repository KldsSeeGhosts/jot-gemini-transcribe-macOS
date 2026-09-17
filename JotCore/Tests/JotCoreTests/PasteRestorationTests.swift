// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

import AppKit
import XCTest
@testable import JotCore

final class PasteRestorationTests: XCTestCase {
    @MainActor
    private func waitForRestore() async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    @MainActor
    func testRapidPastesRestoreOriginalClipboardIncludingRichData() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let original = NSPasteboardItem()
        original.setString("original", forType: .string)
        let rich = Data([1, 2, 3, 4])
        original.setData(rich, forType: .rtf)
        board.writeObjects([original])
        let inserter = PasteInserter(pasteboard: board, restoreDelay: 0.05, postPaste: { true })
        let first = await inserter.paste("first")
        let second = await inserter.paste("second")
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(board.string(forType: .string), "second")
        try await waitForRestore()
        XCTAssertEqual(board.string(forType: .string), "original")
        XCTAssertEqual(board.data(forType: .rtf), rich)
    }

    @MainActor
    func testUserCopyWinsOverScheduledRestore() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let inserter = PasteInserter(pasteboard: board, restoreDelay: 0.05, postPaste: { true })
        _ = await inserter.paste("dictation")
        board.clearContents()
        board.setString("new user copy", forType: .string)
        try await waitForRestore()
        XCTAssertEqual(board.string(forType: .string), "new user copy")
    }

    @MainActor
    func testCopyOnlySupersedesPendingRestore() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let inserter = PasteInserter(pasteboard: board, restoreDelay: 0.05, postPaste: { true })
        _ = await inserter.paste("dictation")
        inserter.copyOnly("manual fallback")
        try await waitForRestore()
        XCTAssertEqual(board.string(forType: .string), "manual fallback")
    }

    @MainActor
    func testFailedPostKeepsTranscriptForManualPaste() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let inserter = PasteInserter(pasteboard: board, restoreDelay: 0.01, postPaste: { false })
        let posted = await inserter.paste("recoverable words")
        XCTAssertFalse(posted)
        try await waitForRestore()
        XCTAssertEqual(board.string(forType: .string), "recoverable words")
    }

    @MainActor
    func testUserCopyBetweenRapidPastesBecomesTheNewSnapshot() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let inserter = PasteInserter(pasteboard: board, restoreDelay: 0.05, postPaste: { true })
        _ = await inserter.paste("first")
        board.clearContents()
        board.setString("new copy", forType: .string)
        _ = await inserter.paste("second")
        try await waitForRestore()
        XCTAssertEqual(board.string(forType: .string), "new copy")
    }
}
