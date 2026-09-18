// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A disabled input tap must stay disabled for a while. Immediately re-enabling
/// it from the timeout callback can repeatedly stall the system's input stream.
/// Only actual healthy input, not an enable attempt, clears the failure streak.
struct EventTapRecoveryPolicy {
    private(set) var failures = 0
    private(set) var retryAt: TimeInterval?
    private var lastFailureAt: TimeInterval?

    mutating func failed(at now: TimeInterval) {
        failures = min(failures + 1, 7)
        lastFailureAt = now
        retryAt = now + min(pow(2.0, Double(failures - 1)), 60)
    }

    func mayRetry(at now: TimeInterval) -> Bool {
        guard let retryAt else { return false }
        return now >= retryAt
    }

    mutating func didRetry() {
        retryAt = nil
    }

    mutating func receivedEvent(at now: TimeInterval) {
        guard retryAt == nil, let lastFailureAt, now - lastFailureAt >= 60 else { return }
        self = Self()
    }
}
