// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

extension View {
    /// Keeps `isDown` in step with the Option key while the view is shown.
    /// `watchKeys: false` skips the key monitor and only re-reads the key
    /// when a menu closes or MockTab becomes active.
    func tracksOptionKey(_ isDown: Binding<Bool>, watchKeys: Bool = true) -> some View {
        modifier(OptionKeyTracking(isDown: isDown, watchKeys: watchKeys))
    }
}

private struct OptionKeyTracking: ViewModifier {
    @Binding var isDown: Bool
    let watchKeys: Bool
    @State private var monitor: Any?

    private func read() { isDown = NSEvent.modifierFlags.contains(.option) }

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard watchKeys else { return }
                read()
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    isDown = event.modifierFlags.contains(.option)
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                isDown = false
            }
            // An open menu, or another app, swallows Option's release, so
            // look again once either hands the keyboard back.
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in read() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in read() }
    }
}
