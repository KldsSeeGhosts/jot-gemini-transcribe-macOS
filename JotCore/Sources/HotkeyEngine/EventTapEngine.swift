// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation

/// Owns one input tap per start/stop lifetime. The event callback never waits on
/// an app lock, calls client code, or immediately revives a timed-out tap.
public final class EventTapEngine {
    public enum State: Equatable {
        case stopped
        case permissionDenied
        case running
    }

    private let lock = NSLock()
    private let deliveryQueue = DispatchQueue(label: "com.ammaar.jot.hotkey.delivery")
    private var session: HotkeyTapSession?
    private var generation = UUID()
    private var key: HotkeyKey
    private var doubleTapEnabled = false
    private var externalSessionActive = false
    private var intentHandler: ((HotkeyIntent) -> Void)?
    private var revivedHandler: (() -> Void)?

    public var state: State { lock.withLock { session?.state ?? .stopped } }

    /// Delivered in order on a separate serial queue, never on the input thread.
    public var onIntent: ((HotkeyIntent) -> Void)? {
        get { lock.withLock { intentHandler } }
        set { lock.withLock { intentHandler = newValue } }
    }
    public var onTapRevived: (() -> Void)? {
        get { lock.withLock { revivedHandler } }
        set { lock.withLock { revivedHandler = newValue } }
    }

    public init(key: HotkeyKey = .fn) { self.key = key }
    deinit { stop() }

    public func setKey(_ newKey: HotkeyKey) {
        lock.withLock {
            key = newKey
            session?.perform { $0.setKey(newKey) }
        }
    }

    public func setDoubleTapLockEnabled(_ enabled: Bool) {
        lock.withLock {
            doubleTapEnabled = enabled
            session?.perform { $0.processor.doubleTapLockEnabled = enabled }
        }
    }

    public func resetGrammar() {
        lock.withLock { session?.perform { $0.resetGrammar() } }
    }

    public func setExternalSessionActive(_ active: Bool) {
        lock.withLock {
            externalSessionActive = active
            session?.perform { $0.externalSessionActive = active }
        }
    }

    @discardableResult
    public func start() -> Bool {
        lock.withLock {
            if session?.state == .running { return true }
            session?.stop()
            generation = UUID()
            let id = generation
            let next = HotkeyTapSession(
                key: key, doubleTapEnabled: doubleTapEnabled,
                externalSessionActive: externalSessionActive,
                deliveryQueue: deliveryQueue,
                onIntent: { [weak self] intent in
                    guard let self else { return }
                    let handler = self.lock.withLock {
                        self.generation == id ? self.intentHandler : nil
                    }
                    handler?(intent)
                },
                onRevived: { [weak self] in
                    guard let self else { return }
                    let handler = self.lock.withLock {
                        self.generation == id ? self.revivedHandler : nil
                    }
                    handler?()
                }
            )
            session = next
            return next.start()
        }
    }

    public func stop() {
        lock.withLock {
            // Invalidate queued deliveries before tearing down the old tap.
            generation = UUID()
            session?.stop()
            session = nil
            externalSessionActive = false
        }
    }
}

/// Grammar and its timers are confined to the tap's run loop. A separate lock
/// protects installation/teardown only; handle() never acquires that lock.
/// The thread retains this session, not EventTapEngine, so dropping an engine
/// really does call deinit and remove its tap.
final class HotkeyTapSession {
    private let resourceLock = NSLock()
    private var stopped = false
    private var currentState: EventTapEngine.State = .stopped
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private let deliveryQueue: DispatchQueue
    private let onIntent: (HotkeyIntent) -> Void
    private let onRevived: () -> Void

    private var key: HotkeyKey
    var processor = HotkeyProcessor()
    var externalSessionActive: Bool
    private var keyIsDown = false
    private var consumedKeys: Set<Int64> = []
    private var doubleTapTimer: CFRunLoopTimer?
    private var timerGeneration = 0
    private var recovery = EventTapRecoveryPolicy()

    var state: EventTapEngine.State { resourceLock.withLock { currentState } }

    init(key: HotkeyKey, doubleTapEnabled: Bool, externalSessionActive: Bool,
         deliveryQueue: DispatchQueue, onIntent: @escaping (HotkeyIntent) -> Void,
         onRevived: @escaping () -> Void) {
        self.key = key
        processor.doubleTapLockEnabled = doubleTapEnabled
        self.externalSessionActive = externalSessionActive
        self.deliveryQueue = deliveryQueue
        self.onIntent = onIntent
        self.onRevived = onRevived
    }

    func start() -> Bool {
        let thread = Thread { self.threadMain() }
        thread.name = "com.ammaar.jot.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        guard ready.wait(timeout: .now() + 2) == .success else {
            // A late tapCreate result may not install a zombie tap after timeout.
            stop()
            return false
        }
        return state == .running
    }

    func stop() {
        resourceLock.withLock {
            stopped = true
            currentState = .stopped
            if let port {
                CGEvent.tapEnable(tap: port, enable: false)
                CFMachPortInvalidate(port)
            }
            if let runLoop {
                CFRunLoopStop(runLoop)
                CFRunLoopWakeUp(runLoop)
            }
        }
    }

    func perform(_ action: @escaping (HotkeyTapSession) -> Void) {
        resourceLock.withLock {
            guard !stopped, let runLoop else { return }
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
                guard let self else { return }
                action(self)
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func threadMain() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<HotkeyTapSession>.fromOpaque(context)
                    .takeUnretainedValue().handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            resourceLock.withLock { if !stopped { currentState = .permissionDenied } }
            ready.signal()
            Log.hotkey.error("EventTapEngine: tap creation failed")
            return
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            ready.signal()
            return
        }
        let loop = CFRunLoopGetCurrent()!
        let installed = resourceLock.withLock { () -> Bool in
            guard !stopped else { return false }
            port = tap
            runLoop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            currentState = .running
            return true
        }
        guard installed else {
            CFMachPortInvalidate(tap)
            CFRunLoopSourceInvalidate(source)
            ready.signal()
            return
        }
        let health = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1, 1, 0, 0
        ) { [weak self] _ in self?.checkHealth() }!
        CFRunLoopAddTimer(loop, health, .commonModes)
        ready.signal()
        defer {
            CFRunLoopTimerInvalidate(health)
            disarmTimer()
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFRunLoopSourceInvalidate(source)
            resourceLock.withLock {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
                port = nil
                runLoop = nil
                currentState = .stopped
            }
        }
        // stop() can race with entering the run loop. An invalidated port never
        // blocks input, and the bounded run avoids retaining a stopped session.
        while !resourceLock.withLock({ stopped }) {
            if CFRunLoopRunInMode(.defaultMode, 1, true) == .finished { break }
        }
    }

    func setKey(_ newKey: HotkeyKey) {
        guard key != newKey else { return } // preserve an in-flight key-up
        finishInterruptedHold()
        key = newKey
    }

    func resetGrammar() {
        processor.reset()
        disarmTimer()
        // Keep the physical edge and consumed key pairs until their release.
    }

    private func finishInterruptedHold() {
        let active = processor.isSessionActive || externalSessionActive
        resetGrammar()
        keyIsDown = false
        consumedKeys.removeAll()
        // Finalize rather than cancel: captured words must remain recoverable.
        if active { emit(.finalize) }
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let now = ProcessInfo.processInfo.systemUptime
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            finishInterruptedHold()
            recovery.failed(at: now)
            return pass // Never re-enable or call app code from this callback.
        }
        guard event.getIntegerValueField(.eventSourceUserData) != SyntheticEventTag.magic else {
            return pass
        }
        recovery.receivedEvent(at: now)
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .flagsChanged:
            guard code == key.keyCode else { return pass }
            let down = key.isDown(in: event.flags)
            guard down != keyIsDown else { return pass }
            keyIsDown = down
            apply(processor.handle(down ? .hotkeyDown : .hotkeyUp, at: now))
            return nil
        case .keyUp:
            return consumedKeys.remove(code) != nil ? nil : pass
        case .keyDown:
            // Swallow the ENTIRE gesture, including autorepeat and its key-up.
            if consumedKeys.contains(code) { return nil }
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return pass }
            if code == 49, processor.isKeyHeld {
                consumedKeys.insert(code)
                apply(processor.handle(.spaceLock, at: now))
                return nil
            }
            if code == 53, processor.isSessionActive || externalSessionActive {
                consumedKeys.insert(code)
                if processor.isSessionActive {
                    apply(processor.handle(.escDown, at: now))
                } else {
                    emit(.cancel)
                }
                return nil
            }
            if processor.isSessionActive {
                apply(processor.handle(.otherKeyDown, at: now))
            }
            return pass
        default:
            return pass
        }
    }

    private func emit(_ intent: HotkeyIntent) {
        deliveryQueue.async { [onIntent] in onIntent(intent) }
    }

    private func disarmTimer() {
        timerGeneration &+= 1
        if let doubleTapTimer { CFRunLoopTimerInvalidate(doubleTapTimer) }
        doubleTapTimer = nil
    }

    private func apply(_ effects: HotkeyProcessor.Effects) {
        if effects.disarmTimer || effects.armTimer != nil {
            disarmTimer()
            if let delay = effects.armTimer {
                let id = timerGeneration
                let timer = CFRunLoopTimerCreateWithHandler(
                    kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0
                ) { [weak self] _ in
                    guard let self, self.timerGeneration == id else { return }
                    self.apply(self.processor.handle(.doubleTapTimeout,
                        at: ProcessInfo.processInfo.systemUptime))
                }!
                doubleTapTimer = timer
                CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
            }
        }
        effects.intents.forEach(emit)
    }

    private func checkHealth() {
        // This timer is on the grammar's run loop, but outside the input callback.
        // Serialize enable with stop: once invalidated, a tap can never be revived.
        resourceLock.withLock {
            guard !stopped, let port, CFMachPortIsValid(port),
                  !CGEvent.tapIsEnabled(tap: port) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if recovery.retryAt == nil {
                finishInterruptedHold()
                recovery.failed(at: now)
            } else if recovery.mayRetry(at: now) {
                CGEvent.tapEnable(tap: port, enable: true)
                recovery.didRetry()
                deliveryQueue.async { [onRevived] in onRevived() }
            }
        }
    }
}
