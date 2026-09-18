// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Combine
import SwiftUI
import JotCore

/// The visual stage stays fixed-size for animation, but the window itself must
/// ignore clicks outside interactive pill content. View hitTest alone cannot
/// forward an event to another application's window.
@MainActor
final class PillHUDController {
    let model = PillModel()
    private let panel: NSPanel
    private let hostingView: PillHostingView<PillRootView>
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var stateObservation: AnyCancellable?
    private var interactive = false

    init() {
        panel = PillPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 96),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true // Fail open before the first layout.
        let hosting = PillHostingView(rootView: PillRootView(model: model))
        hostingView = hosting
        panel.contentView = hosting
        hosting.rootView.onPillFrameChange = { [weak self] frame in
            self?.hostingView.pillFrame = frame
            self?.updateMouseRouting()
        }
        stateObservation = model.$state.sink { [weak self] state in
            guard let self else { return }
            switch state {
            case .idleDot, .listening(locked: true): self.interactive = true
            default: self.interactive = false
            }
            self.updateMouseRouting()
        }
        reposition()
    }

    deinit {
        // Monitors do not retain the controller. Remove their registrations too.
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    func show() {
        reposition()
        startPointerMonitoring()
        panel.orderFrontRegardless()
        updateMouseRouting()
    }

    func repositionToActiveScreen() { reposition() }

    func hide() {
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func startPointerMonitoring() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseUp, .rightMouseUp, .otherMouseUp
        ]
        // These are passive AppKit monitors, not another filtering event tap.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.updateMouseRouting(afterMouseUp: Self.isMouseUp(event))
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.updateMouseRouting(afterMouseUp: Self.isMouseUp(event))
            return event
        }
    }

    private static func isMouseUp(_ event: NSEvent) -> Bool {
        [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type)
    }

    private func updateMouseRouting(afterMouseUp: Bool = false) {
        guard panel.isVisible, interactive else {
            panel.ignoresMouseEvents = true
            return
        }
        // Do not steal a drag entering from another app, or drop our own
        // mouse-up when a button press travels beyond the pill's bounds.
        guard afterMouseUp || NSEvent.pressedMouseButtons == 0 else { return }
        let point = hostingView.convert(
            panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil
        )
        panel.ignoresMouseEvents = !hostingView.containsPill(point)
    }

    private func reposition() {
        let screen = Self.screenOfFocusedWindow()
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2, y: frame.minY + 16
        ))
        updateMouseRouting()
    }

    private static func screenOfFocusedWindow() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        guard let info = windows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
                && (($0[kCGWindowLayer as String] as? Int) ?? 1) == 0
        }), let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
            return nil
        }
        let midX = (bounds["X"] ?? 0) + (bounds["Width"] ?? 0) / 2
        let midY = (bounds["Y"] ?? 0) + (bounds["Height"] ?? 0) / 2
        guard let primary = NSScreen.screens.first else { return nil }
        let cocoaPoint = NSPoint(x: midX, y: primary.frame.maxY - midY)
        return NSScreen.screens.first(where: { $0.frame.contains(cocoaPoint) })
    }
}

/// Clicking Dictate/Stop must not steal keyboard focus from the target app.
private final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PillHostingView<Content: View>: NSHostingView<Content> {
    var pillFrame: CGRect?
    private let slop: CGFloat = 6

    func containsPill(_ point: NSPoint) -> Bool {
        guard let pillFrame, !pillFrame.isEmpty else { return false }
        return pillFrame.insetBy(dx: -slop, dy: -slop).contains(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard containsPill(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

private struct PillRootView: View {
    @ObservedObject var model: PillModel
    var onPillFrameChange: (CGRect) -> Void = { _ in }

    private struct PillFrameKey: PreferenceKey {
        static var defaultValue: CGRect = .zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            PillView(model: model)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: PillFrameKey.self, value: geo.frame(in: .named("hudStage"))
                        )
                    }
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 8)
        .coordinateSpace(name: "hudStage")
        .onPreferenceChange(PillFrameKey.self) { onPillFrameChange($0) }
    }
}
