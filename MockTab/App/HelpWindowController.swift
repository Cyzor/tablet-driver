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

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.sectionKey)
        selectedSection = saved.flatMap(HelpSection.init(rawValue:)) ?? .tabletArea

        let savedStep = UserDefaults.standard.integer(forKey: Self.sizeStepKey)
        fontSizeStep = max(Self.fontSizeStepRange.lowerBound,
                           min(Self.fontSizeStepRange.upperBound, savedStep))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "MockTab Help", comment: "Help window title")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 380)

        super.init(window: window)

        let view = HelpPanelView(controller: self)
        window.contentViewController = NSHostingController(rootView: view.withAppearance())

        // Restore saved frame, or center on first launch.
        if let frameString = UserDefaults.standard.string(forKey: Self.frameKey) {
            window.setFrame(NSRectFromString(frameString), display: false)
        } else {
            window.center()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Opens the help window, optionally jumping to `section`.
    func show(section: HelpSection? = nil) {
        if let section { selectedSection = section }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Reopens the window if it was open when the app last quit.
    func restoreIfWasOpen() {
        if UserDefaults.standard.bool(forKey: Self.openKey) {
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
