import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController {

    static let shared = PreferencesWindowController()

    /// Shared settings instance — owned here for the app's lifetime.
    let settings = TabletSettings()

    /// The tab view controller — stored so `showTab` can switch tabs programmatically.
    private let tabVC = NSTabViewController()

    /// Ordered tab labels, parallel to the tabs added in init.
    static let tabLabels = [
        "Tablet Area", "Pressure", "Buttons", "Display", "Devices", "Presets", "Scratchpad", "Info"
    ]

    private init() {
        tabVC.tabStyle = .toolbar   // icon + label toolbar; window auto-resizes per tab

        let window = NSWindow(contentViewController: tabVC)
        window.title = "MockTab"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        // setFrameAutosaveName after center() so a saved position overrides the default.
        window.setFrameAutosaveName("PreferencesWindow")
        super.init(window: window)

        let s = settings
        add(tabVC, label: "Tablet Area",  symbol: "rectangle.dashed",  height: 420) { TabletAreaView(settings: s, tabletManager: TabletManager.shared) }
        add(tabVC, label: "Pressure",     symbol: "waveform.path",      height: 480) { PressureCurveView(settings: s) }
        add(tabVC, label: "Buttons",      symbol: "hand.point.up.left", height: 575) { ButtonMappingView(settings: s) }
        add(tabVC, label: "Display",      symbol: "display",            height: 370) { DisplayMappingView(settings: s) }
        add(tabVC, label: "Devices",      symbol: "externaldrive",      height: 480) { DevicesView(tabletManager: TabletManager.shared, registry: DeviceRegistry.shared) }
        add(tabVC, label: "Presets",      symbol: "star.circle",        height: 450) { PresetsView(settings: s) }
        add(tabVC, label: "Scratchpad",   symbol: "scribble",           height: 360) { ScratchpadView(settings: s) }
        add(tabVC, label: "Info",         symbol: "info.circle",        height: 430) { InfoView(tabletManager: TabletManager.shared, settings: s) }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public

    func show() {
        TabletManager.shared.settings = settings
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Shows the window and switches to the tab at `index` (0-based).
    func showTab(at index: Int) {
        show()
        guard index >= 0, index < tabVC.tabViewItems.count else { return }
        tabVC.selectedTabViewItemIndex = index
    }

    /// Shows the window and switches to the first tab whose label matches `name`.
    func showTab(named name: String) {
        let idx = tabVC.tabViewItems.firstIndex(where: { $0.label == name })
        showTab(at: idx ?? 0)
    }

    // MARK: - Private

    private func add<Content: View>(
        _ tabVC: NSTabViewController,
        label: String,
        symbol: String,
        height: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        // Top-align content so shorter views don't float in the middle of the area.
        let aligned = content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        let hosting = NSHostingController(rootView: aligned)
        hosting.title = label                          // shown in the title bar for this tab
        hosting.preferredContentSize = NSSize(width: 500, height: height)

        let item = NSTabViewItem(viewController: hosting)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        tabVC.addTabViewItem(item)
    }
}
