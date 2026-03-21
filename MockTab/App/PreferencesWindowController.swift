import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController {

    static let shared = PreferencesWindowController()

    private init() {
        let hosting = NSHostingController(rootView: PreferencesView())
        let window  = NSWindow(contentViewController: hosting)
        window.title = "MockTab"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
