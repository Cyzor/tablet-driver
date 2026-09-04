// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Manages the singleton help window.
///
/// Call `show(section:)` from the Help menu command or from any `?` button
/// in the UI to open (or bring forward) the window, optionally jumping to
/// a specific section.
@MainActor
final class HelpWindowController: NSWindowController, ObservableObject {

    static let shared = HelpWindowController()

    private static let sectionKey  = "HelpWindowSelectedSection"
    private static let openKey     = "HelpWindowWasOpen"
    private static let frameKey    = "HelpWindowFrame"
    private static let sizeStepKey = "HelpWindowFontSizeStep"

    static let fontSizeStepRange = -3 ... 5

    @Published var selectedSection: HelpSection {
        didSet {
            UserDefaults.standard.set(selectedSection.rawValue, forKey: Self.sectionKey)
        }
    }

    @Published var fontSizeStep: Int {
        didSet {
            UserDefaults.standard.set(fontSizeStep, forKey: Self.sizeStepKey)
        }
    }

    private var closeToken: NSObjectProtocol?

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.sectionKey)
        selectedSection = saved.flatMap(HelpSection.init(rawValue:)) ?? .tabletArea

        let savedStep = UserDefaults.standard.integer(forKey: Self.sizeStepKey)
        fontSizeStep = max(Self.fontSizeStepRange.lowerBound,
                           min(Self.fontSizeStepRange.upperBound, savedStep))

        // Window is built on demand in ensureWindow() and released on close,
        // so merely touching `shared` (app launch does, via
        // restoreIfWasOpen) costs nothing, and closing Help returns its
        // SwiftUI content instead of retaining it for the process lifetime.
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func ensureWindow() {
        guard window == nil else { return }

        // Full-size content with a transparent titlebar, the way Apple's own
        // Help Viewer is built: the sidebar then runs the full height of the
        // window rather than starting below a band that spans both panes.
        //
        // This is also what makes the split view's panes agree. Without it the
        // detail pane is handed a top safe-area inset of zero while the sidebar
        // is inset by the system, so the two sides disagree by the toolbar's
        // height and any correction is a guess; with it the detail pane gets a
        // real inset (measured: the toolbar's exact height) and both panes are
        // placed by the same mechanism.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.title = String(localized: "MockTab Help", comment: "Help window title")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 380)

        let view = HelpPanelView(controller: self)
        window.contentViewController = NSHostingController(rootView: view.withAppearance())

        // Restore saved frame, or center on first open.
        if let frameString = UserDefaults.standard.string(forKey: Self.frameKey) {
            window.setFrame(NSRectFromString(frameString), display: false)
        } else {
            window.center()
        }

        closeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowDidClose() }
        }

        self.window = window
    }

    /// Persist the frame, then drop the window and its hosting controller so
    /// the whole Help view tree deallocates. Rebuilt fresh on next show().
    private func windowDidClose() {
        if let frame = window?.frame {
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameKey)
        }
        if let closeToken { NotificationCenter.default.removeObserver(closeToken) }
        closeToken = nil
        window?.contentViewController = nil
        window = nil
    }

    /// Opens the help window, optionally jumping to `section`.
    func show(section: HelpSection? = nil) {
        if let section { selectedSection = section }
        ensureWindow()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Reopens the window if it was open when the app last quit.
    func restoreIfWasOpen() {
        if UserDefaults.standard.bool(forKey: Self.openKey) {
            ensureWindow()
            showWindow(nil)
        }
    }

    /// Persists open state and frame. Call from applicationWillTerminate.
    func saveState() {
        let visible = window?.isVisible == true
        UserDefaults.standard.set(visible, forKey: Self.openKey)
        if let frame = window?.frame {
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameKey)
        }
    }
}
