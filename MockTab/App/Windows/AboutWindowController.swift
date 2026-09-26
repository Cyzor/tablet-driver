// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

@MainActor
final class AboutWindowController {

    static let shared = AboutWindowController()
    private var window: NSWindow?
    private var closeToken: NSObjectProtocol?

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        win.title = String(localized: "About MockTab", comment: "Window title: about view")
        win.isReleasedWhenClosed = false
        win.center()
        win.contentView = NSHostingView(rootView: AboutView().withAppearance())
        window = win
        // Release the window and its SwiftUI content on close instead of
        // retaining them for the process lifetime; rebuilt on next show().
        closeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let closeToken = self.closeToken {
                    NotificationCenter.default.removeObserver(closeToken)
                }
                self.closeToken = nil
                self.window?.contentView = nil
                self.window = nil
            }
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
