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

import SwiftUI

/// The accent gradient sweeping once across text, then settling into ink.
///
/// This is the moment the live transcript stops being a guess: the interim text
/// the model was revising is replaced by its finished, formatted answer, and the
/// sweep is what says "that just changed, and something did it on purpose"
/// without a spinner or a label.
///
/// Ported from the landing page, deliberately to the same numbers so the site and
/// the app describe the same product: a 100° four-stop gradient at 260% width,
/// swept from 140% to -20% over 1.5s on cubic-bezier(.3,.5,.2,1), then cleared.
///
/// This is the only place the accent gradient appears. It reads as a signal
/// because nothing else uses it.
struct ModelSweep: ViewModifier {

    /// Changing this value runs the sweep once.
    let trigger: String

    /// The four stops from the site, in order, with blue repeated so the sweep
    /// enters and leaves on the same colour and has no visible seam.
    private static let stops: [Color] = [
        Color(red: 0x42 / 255, green: 0x85 / 255, blue: 0xF4 / 255),  // #4285F4
        Color(red: 0x9B / 255, green: 0x72 / 255, blue: 0xCB / 255),  // #9B72CB
        Color(red: 0xD9 / 255, green: 0x65 / 255, blue: 0x70 / 255),  // #D96570
        Color(red: 0x42 / 255, green: 0x85 / 255, blue: 0xF4 / 255),  // #4285F4
    ]

    private static let duration: TimeInterval = 1.5

    @State private var phase: CGFloat = 1.4      // background-position: 140%
    @State private var sweeping = false
    /// The pending "settle into ink" step. A re-run cancels it so the first
    /// sweep's cleanup can never fire mid-second-sweep and park the gradient
    /// over the text — the frozen-rainbow bug. Task cancellation is the guard
    /// the old asyncAfter+token stack was approximating.
    @State private var settleTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay {
                if sweeping {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: Self.stops,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        // 260% of the text's width, so only part of the gradient
                        // is over the glyphs at any instant — that is what makes
                        // it read as a sweep rather than a colour change.
                        .frame(width: proxy.size.width * 2.6)
                        .offset(x: phase * proxy.size.width)
                        .mask(content)
                    }
                    .allowsHitTesting(false)
                }
            }
            .onChange(of: trigger) { _, newValue in
                // Empty means the session ended and the pill moved on — the
                // overlay must die with the text it was sweeping, not linger
                // parked over whatever renders next.
                guard !newValue.isEmpty else {
                    settleTask?.cancel()
                    sweeping = false
                    return
                }
                run()
            }
            .onAppear {
                if !trigger.isEmpty { run() }
            }
            // The view being torn down mid-sweep leaves @State behind, but the
            // pending task is still owned by it — cancel on disappear so a dead
            // view's timer cannot write into a recycled identity.
            .onDisappear {
                settleTask?.cancel()
                settleTask = nil
            }
    }

    private func run() {
        // Respect the system setting, exactly as the site respects
        // prefers-reduced-motion: the correction still lands, it just does not
        // travel.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            sweeping = false
            return
        }
        settleTask?.cancel()
        phase = 1.4
        sweeping = true
        withAnimation(.timingCurve(0.3, 0.5, 0.2, 1.0, duration: Self.duration)) {
            phase = -0.2                          // background-position: -20%
        }
        // Then it settles into ink — the site removes the class rather than
        // leaving the gradient parked over the text. Kept on a Task so a re-run
        // cancels the stale settle instead of stacking it.
        settleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            sweeping = false
        }
    }
}

extension View {
    /// Sweeps the accent gradient across this view once whenever `trigger`
    /// changes to a non-empty value.
    func modelSweep(trigger: String) -> some View {
        modifier(ModelSweep(trigger: trigger))
    }
}
