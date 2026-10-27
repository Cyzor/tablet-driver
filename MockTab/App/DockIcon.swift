// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Whether MockTab shows in the Dock and the app switcher. Shown unless the
/// user hid it.
@MainActor
enum DockIcon {
    static let defaultsKey = "showInDock"

    static func show() {
        UserDefaults.standard.set(true, forKey: defaultsKey)
        NSApp.setActivationPolicy(.regular)
    }

    /// Asks first: hiding also takes away the menu bar, and the alert says
    /// how to get both back.
    static func confirmHide() {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Hide MockTab's Dock Icon?",
            comment: "Alert title: hide Dock icon confirmation")
        alert.informativeText = String(
            localized: "MockTab stays in the menu bar. Show the Dock icon again from the Info pane or the menu bar icon.",
            comment: "Alert body: explaining consequences of hiding Dock icon")
        alert.alertStyle = .informational
        let hideButton = alert.addButton(
            withTitle: String(localized: "Hide Dock Icon", comment: "Button label: confirm hide Dock icon"))
        alert.addButton(
            withTitle: String(localized: "Cancel", comment: "Button label: cancel hide Dock icon"))
        hideButton.keyEquivalent = "\r"

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(false, forKey: defaultsKey)
        NSApp.setActivationPolicy(.accessory)
    }
}
