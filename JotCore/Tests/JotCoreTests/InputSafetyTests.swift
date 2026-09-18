// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import XCTest
@testable import JotCore

final class InputSafetyTests: XCTestCase {
    private func session(onIntent: @escaping (HotkeyIntent) -> Void = { _ in }) -> HotkeyTapSession {
        HotkeyTapSession(key: .fn, doubleTapEnabled: false, externalSessionActive: false,
                         deliveryQueue: DispatchQueue(label: "test.hotkey.delivery"),
                         onIntent: onIntent, onRevived: {})
    }

    private func event(code: Int64, flags: CGEventFlags = [], repeatKey: Bool = false,
                       synthetic: Bool = false) -> CGEvent {
        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(code),
            keyDown: true
        )!
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        if synthetic { event.setIntegerValueField(.eventSourceUserData, value: SyntheticEventTag.magic) }
        return event
    }

    private func passes(_ tap: HotkeyTapSession, type: CGEventType, event: CGEvent) -> Bool {
        tap.handle(type: type, event: event) != nil
    }

    func testRecoveryBacksOffAndCapsDelay() {
        var policy = EventTapRecoveryPolicy()
        for delay in [1.0, 2, 4, 8, 16, 32, 60, 60] {
            policy.failed(at: 100)
            XCTAssertEqual(policy.retryAt, 100 + delay)
            XCTAssertFalse(policy.mayRetry(at: 100 + delay - 0.01))
            XCTAssertTrue(policy.mayRetry(at: 100 + delay))
            policy.didRetry()
            XCTAssertFalse(policy.mayRetry(at: 200))
        }
    }

    func testEnableAttemptDoesNotResetFailureStreak() {
        var policy = EventTapRecoveryPolicy()
        policy.failed(at: 0)
        policy.didRetry()
        policy.receivedEvent(at: 2)
        policy.failed(at: 3)
        XCTAssertEqual(policy.retryAt, 5)
    }

    func testHealthyInputResetsBackoffButCooldownDoesNot() {
        var policy = EventTapRecoveryPolicy()
        policy.failed(at: 0)
        policy.receivedEvent(at: 100)
        XCTAssertEqual(policy.failures, 1)
        policy.didRetry()
        policy.receivedEvent(at: 100)
        XCTAssertEqual(policy.failures, 0)
        policy.failed(at: 101)
        XCTAssertEqual(policy.retryAt, 102)
    }

    func testOrdinaryKeyboardAndMouseEventsPassThrough() {
        let tap = session()
        for type in [CGEventType.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .mouseMoved] {
            XCTAssertTrue(passes(tap, type: type, event: event(code: 0)))
        }
        XCTAssertTrue(passes(tap, type: .flagsChanged, event: event(code: 56, flags: .maskShift)))
    }

    func testSyntheticModifierDoesNotStartDictation() {
        let tap = session()
        XCTAssertTrue(passes(tap, type: .flagsChanged,
                             event: event(code: 63, flags: .maskSecondaryFn, synthetic: true)))
        XCTAssertEqual(tap.processor.phase, .idle)
    }

    func testSpaceGestureConsumesRepeatsAndMatchingReleaseOnly() {
        let tap = session()
        XCTAssertNil(tap.handle(type: .flagsChanged, event: event(code: 63, flags: .maskSecondaryFn)))
        XCTAssertNil(tap.handle(type: .keyDown, event: event(code: 49)))
        XCTAssertEqual(tap.processor.phase, .locked)
        XCTAssertNil(tap.handle(type: .keyDown, event: event(code: 49, repeatKey: true)))
        XCTAssertNil(tap.handle(type: .keyUp, event: event(code: 49)))
        XCTAssertTrue(passes(tap, type: .keyDown, event: event(code: 49)))
        XCTAssertTrue(passes(tap, type: .keyUp, event: event(code: 49)))
    }

    func testEscapeConsumesItsWholeGestureThenPassesOrdinaryEscape() {
        let tap = session()
        _ = tap.handle(type: .flagsChanged, event: event(code: 63, flags: .maskSecondaryFn))
        XCTAssertNil(tap.handle(type: .keyDown, event: event(code: 53)))
        XCTAssertNil(tap.handle(type: .keyDown, event: event(code: 53, repeatKey: true)))
        XCTAssertNil(tap.handle(type: .keyUp, event: event(code: 53)))
        XCTAssertTrue(passes(tap, type: .keyDown, event: event(code: 53)))
    }

    func testSameKeyConfigurationPreservesReleaseEdge() {
        let tap = session()
        _ = tap.handle(type: .flagsChanged, event: event(code: 63, flags: .maskSecondaryFn))
        tap.setKey(.fn)
        XCTAssertNil(tap.handle(type: .flagsChanged, event: event(code: 63)))
        XCTAssertEqual(tap.processor.phase, .idle)
    }

    func testTimeoutFinalizesInsteadOfDiscardingCapturedWords() {
        let finalized = expectation(description: "interrupted recording finalized")
        let tap = session { if $0 == .finalize { finalized.fulfill() } }
        _ = tap.handle(type: .flagsChanged, event: event(code: 63, flags: .maskSecondaryFn))
        XCTAssertTrue(passes(tap, type: .tapDisabledByTimeout, event: event(code: 0)))
        XCTAssertEqual(tap.processor.phase, .idle)
        wait(for: [finalized], timeout: 2)
    }

    func testClientCallbackCannotBlockTheInputCallback() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let returned = expectation(description: "input callback returned")
        let tap = session { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        let keyDown = event(code: 63, flags: .maskSecondaryFn)
        defer { release.signal() }
        DispatchQueue.global().async {
            _ = tap.handle(type: .flagsChanged, event: keyDown)
            returned.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        wait(for: [returned], timeout: 1)
    }
}
