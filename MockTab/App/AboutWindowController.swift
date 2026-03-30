import AppKit
import SwiftUI

@MainActor
final class AboutWindowController {

    static let shared = AboutWindowController()
    private var window: NSWindow?

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
        win.title = "About MockTab"
        win.isReleasedWhenClosed = false
        win.center()
        win.contentView = NSHostingView(rootView: AboutView())
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
