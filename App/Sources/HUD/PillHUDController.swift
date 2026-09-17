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

import AppKit
import SwiftUI
import JotCore

/// Owns the non-activating NSPanel that hosts the pill. Fixed-size panel; the pill
/// animates its own bounds inside (avoids NSWindow frame-animation jank).
/// The panel never becomes key except transiently for the locked-state stop button.
@MainActor
final class PillHUDController {
    let model = PillModel()
    private let panel: NSPanel
    private let hostingView: PillHostingView<PillRootView>

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 96),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        let hosting = PillHostingView(rootView: PillRootView(model: model))
        // The pill reports where it actually is inside the 600×96 stage; the
        // hosting view only accepts events there (see PillHostingView.hitTest).
        hosting.rootView.onPillFrameChange = { [weak hosting] frame in
            hosting?.pillFrame = frame
        }
        hostingView = hosting
        panel.contentView = hosting
        reposition()
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
    }

    /// Called at each session start so the pill follows the display the user is
    /// actually dictating on (audit L14 — it used to stick to the launch screen).
    func repositionToActiveScreen() {
        reposition()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Bottom-center of the screen hosting the FOCUSED window — where the text
    /// will actually land. Mouse position is only a fallback: keyboard-first
    /// users routinely dictate on one display with the pointer parked on
    /// another (production pass 2). Doesn't jump mid-session (spec §1.1).
    private func reposition() {
        let screen = Self.screenOfFocusedWindow()
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 16
        ))
    }

    /// Screen hosting the frontmost app's front window, via the window list —
    /// a local syscall, never an AX round-trip into the target app. The AX
    /// version could block ~100ms per attribute on a busy app, and this runs
    /// on the key-press path where the pill must appear instantly (dogfood).
    private static func screenOfFocusedWindow() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // The list is front-to-back; the first normal-layer window owned by the
        // frontmost app is its focused/front window.
        guard let info = windows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
                && (($0[kCGWindowLayer as String] as? Int) ?? 1) == 0
        }), let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
            return nil
        }
        let midX = (bounds["X"] ?? 0) + (bounds["Width"] ?? 0) / 2
        let midY = (bounds["Y"] ?? 0) + (bounds["Height"] ?? 0) / 2
        // Window-list coords are top-left-origin global; flip into Cocoa space.
        guard let primary = NSScreen.screens.first else { return nil }
        let cocoaPoint = NSPoint(x: midX, y: primary.frame.maxY - midY)
        return NSScreen.screens.first(where: { $0.frame.contains(cocoaPoint) })
    }
}

/// NSHostingView that only accepts events where the pill actually is.
///
/// AppKit delivers clicks to a window's whole FRAME — transparency does not
/// make a clear panel click-through, and NSHostingView consumes whatever it is
/// given. Unchecked, this panel's fixed 600×96 stage (bottom-center of the
/// screen, joined to every space, at screenSaver level — and visible whenever
/// the resting dot is on, which is the default) swallowed every click aimed at
/// anything underneath: a strip of "dead" UI with no visual explanation.
/// The pill reports its live bounds via preference; outside them, hitTest
/// returns nil and the event passes through to whatever the user clicked.
private final class PillHostingView<Content: View>: NSHostingView<Content> {
    /// The pill's bounds in this view's coordinate space (top-left origin:
    /// SwiftUI named spaces and this flipped view agree). nil/empty = the pill
    /// isn't showing anything interactive — pass everything through.
    var pillFrame: CGRect?
    /// Edges are hard to hit exactly; a few points of grace keeps the dot's
    /// generous hover target feeling continuous with its contentShape.
    private let slop: CGFloat = 6

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let pillFrame, !pillFrame.isEmpty,
              pillFrame.insetBy(dx: -slop, dy: -slop).contains(point) else { return nil }
        return super.hitTest(point)
    }
}

private struct PillRootView: View {
    @ObservedObject var model: PillModel
    var onPillFrameChange: (CGRect) -> Void = { _ in }

    private struct PillFrameKey: PreferenceKey {
        static var defaultValue: CGRect = .zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            value = nextValue()
        }
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            PillView(model: model)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: PillFrameKey.self,
                            value: geo.frame(in: .named("hudStage"))
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
