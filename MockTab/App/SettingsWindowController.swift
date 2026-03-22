import AppKit
import SwiftUI

/// A single settings window bound to one TabletSettings instance.
///
/// Each window has its own NSTabViewController with the full 8-tab layout.
/// The `deviceLabel` is baked into the window title of device-specific tabs
/// (Tablet Area, Pressure, Buttons, Display) at creation time, so
/// NSTabViewController's built-in title management does the right thing
/// automatically.  Global tabs (Devices, Presets, Scratchpad, Info) show
/// only the tab name.
///
/// When the user selects a different tablet from the Tablet Area picker,
/// the window asks `PreferencesWindowController` to replace it with a new
/// window bound to the selected device.
@MainActor
final class SettingsWindowController: NSWindowController {

    let settings: TabletSettings
    let deviceLabel: String

    /// The product ID this window is configured for, or `nil` for
    /// a generic / default window.
    let productID: Int?

    /// The tab view controller — stored so `showTab` can switch tabs.
    private let tabVC = NSTabViewController()

    /// Ordered tab labels, parallel to the tabs added in init.
    static let tabLabels = [
        "Tablet Area", "Pressure", "Buttons", "Display", "Devices", "Presets", "Scratchpad", "Info"
    ]

    /// Tabs at these indices describe per-device properties and get the
    /// device label appended to the window title.  Indices 4+ (Devices,
    /// Presets, Scratchpad, Info) are global and show only the tab name.
    private static let deviceSpecificTabIndices: Set<Int> = [0, 1, 2, 3]

    init(settings: TabletSettings, deviceLabel: String, productID: Int?) {
        self.settings = settings
        self.deviceLabel = deviceLabel
        self.productID = productID

        tabVC.tabStyle = .toolbar

        let window = NSWindow(contentViewController: tabVC)
        window.title = "MockTab"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        let s = settings
        let tm = TabletManager.shared
        let dr = DeviceRegistry.shared
        let onDevice: (Int) -> Void = { [weak self] pid in
            guard let self else { return }
            PreferencesWindowController.shared.replaceWindow(self, withDeviceID: pid)
        }
        addTab(label: "Tablet Area", symbol: "rectangle.dashed", height: 420) {
            TabletAreaView(settings: s, tabletManager: tm,
                           onDeviceSelected: onDevice, boundProductID: productID)
        }
        addTab(label: "Pressure",     symbol: "scribble.variable",       height: 480) { PressureCurveView(settings: s, tabletManager: tm, registry: dr) }
        addTab(label: "Buttons",      symbol: "hand.point.up.left",      height: 575) { ButtonMappingView(settings: s, tabletManager: tm, registry: dr) }
        addTab(label: "Display",      symbol: "display",                 height: 370) { DisplayMappingView(settings: s, tabletManager: tm, registry: dr) }
        addTab(label: "Devices",      symbol: "rectangle.on.rectangle",  height: 480) { DevicesView(tabletManager: tm, registry: dr) }
        addTab(label: "Presets",      symbol: "star.circle",             height: 450) { PresetsView(settings: s) }
        addTab(label: "Scratchpad",   symbol: "pencil.and.outline",      height: 360) { ScratchpadView(settings: s) }
        addTab(label: "Info",         symbol: "info.circle",             height: 430) { InfoView(tabletManager: tm, settings: s) }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public

    func show() {
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

    /// The currently selected tab index.
    var selectedTabIndex: Int { tabVC.selectedTabViewItemIndex }

    // MARK: - Private

    /// The index of the tab currently being added — incremented by `addTab`.
    private var nextTabIndex = 0

    private func addTab<Content: View>(
        label: String,
        symbol: String,
        height: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        let aligned = content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        let hosting = NSHostingController(rootView: aligned)

        // NSTabViewController uses `viewController.title` for `window.title`
        // and `item.label` for the toolbar button text.  By setting the
        // hosting controller's title to include the device label on
        // device-specific tabs, the window title updates automatically and
        // correctly on every tab switch — no delegate override needed.
        let isDeviceTab = Self.deviceSpecificTabIndices.contains(nextTabIndex)
        if isDeviceTab {
            hosting.title = "\(label) — \(deviceLabel)"
        } else {
            hosting.title = label
        }
        hosting.preferredContentSize = NSSize(width: 500, height: height)

        let item = NSTabViewItem(viewController: hosting)
        item.label = label   // toolbar button text stays short
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        tabVC.addTabViewItem(item)

        nextTabIndex += 1
    }
}
