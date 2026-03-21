import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController {

    static let shared = PreferencesWindowController()

    /// Shared settings instance — owned here for the app's lifetime.
    let settings = TabletSettings()

    private init() {
        let tabVC = NSTabViewController()
        tabVC.tabStyle = .toolbar   // icon + label toolbar, like Fork / System Preferences

        let window = NSWindow(contentViewController: tabVC)
        window.title = "MockTab"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        // setFrameAutosaveName after center() so a saved position overrides the default.
        window.setFrameAutosaveName("PreferencesWindow")
        super.init(window: window)

        let s = settings   // capture for closures below
        add(tabVC, label: "Tablet Area",  symbol: "rectangle.dashed")  { TabletAreaView(settings: s) }
        add(tabVC, label: "Pressure",     symbol: "waveform.path")      { PressureCurveView(settings: s) }
        add(tabVC, label: "Buttons",      symbol: "hand.point.up.left") { ButtonMappingView(settings: s) }
        add(tabVC, label: "Display",      symbol: "display")            { DisplayMappingView(settings: s) }
        add(tabVC, label: "Scratchpad",   symbol: "scribble")           { ScratchpadView() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public

    func show() {
        TabletManager.shared.settings = settings
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Private

    private func add<Content: View>(
        _ tabVC: NSTabViewController,
        label: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) {
        let hosting = NSHostingController(rootView: content())
        hosting.preferredContentSize = NSSize(width: 500, height: 560)
        let item = NSTabViewItem(viewController: hosting)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        tabVC.addTabViewItem(item)
    }
}
