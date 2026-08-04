// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Zero-size NSViewRepresentable that bridges NSView live-resize callbacks into
/// SwiftUI @State. Scoped to the view's own window — fires only when that window
/// is being resized, not when any other window resizes.
struct LiveResizeDetector: NSViewRepresentable {
    @Binding var isResizing: Bool

    func makeNSView(context: Context) -> TrackingView { TrackingView(binding: $isResizing) }
    func updateNSView(_ nsView: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        var binding: Binding<Bool>
        init(binding: Binding<Bool>) {
            self.binding = binding
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewWillStartLiveResize() {
            super.viewWillStartLiveResize()
            DispatchQueue.main.async { self.binding.wrappedValue = true }
        }
        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            DispatchQueue.main.async { self.binding.wrappedValue = false }
        }
    }
}
