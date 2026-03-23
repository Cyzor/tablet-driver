import AppKit
import SwiftUI

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// NSWindow subclass that enforces resizability and correct zoom behaviour.
///
/// Key problems prevented here:
///   • NSTabViewController strips .resizable from styleMask during setup.
///   • NSTabViewController adds a required-priority height constraint via
///     NSHostingController.preferredContentSize — overriding maxSize alone
///     is insufficient because Auto Layout re-applies the constraint every
///     layout pass.  The height problem is solved separately by
///     ResizableTabViewController (see below).
///   • The green zoom button calls toggleFullScreen: by default on macOS 13+
///     regardless of collectionBehavior; we suppress it here.
final class ResizableWindow: NSWindow {

    @objc dynamic override var styleMask: NSWindow.StyleMask {
        get { super.styleMask }
        set { super.styleMask = newValue.union(.resizable) }
    }

    @objc dynamic override var maxSize: NSSize {
        get { NSSize(width: super.maxSize.width, height: .greatestFiniteMagnitude) }
        set { super.maxSize = NSSize(width: newValue.width, height: .greatestFiniteMagnitude) }
    }

    /// Redirect fullscreen button to zoom instead of entering fullscreen.
    override func toggleFullScreen(_ sender: Any?) { zoom(sender) }

    /// Green-button zoom: maximise to the screen's full visible height,
    /// or restore the previous frame if already maximised.
    override func zoom(_ sender: Any?) {
        guard let screen = screen ?? NSScreen.main else { super.zoom(sender); return }
        let visible = screen.visibleFrame
        let alreadyMaximised = abs(frame.height - visible.height) < 2
                            && abs(frame.minY   - visible.minY)   < 2
        if alreadyMaximised {
            super.zoom(sender)
        } else {
            setFrame(NSRect(x: frame.minX, y: visible.minY,
                            width: frame.width, height: visible.height),
                     display: true, animate: true)
        }
    }
}

/// NSTabViewController subclass that owns all window sizing.
///
/// NSHostingController.preferredContentSize creates a required-priority
/// Auto Layout height constraint that makes windows non-resizable.  We
/// avoid this entirely by passing height = 0 to NSHostingController
/// (so NSTabViewController never sees a height to constrain), storing
/// the desired sizes ourselves, and calling window.setContentSize directly
/// on tab selection.
final class ResizableTabViewController: NSTabViewController {

    private var tabSizes: [String: NSSize] = [:]

    func register(size: NSSize, forTabLabeled label: String) {
        tabSizes[label] = size
    }

    // Called on every tab switch — directly set the window content size
    // instead of letting Auto Layout enforce preferredContentSize.
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        applySize(for: tabViewItem)
    }

    // Called on first appearance — size the window for the initially selected tab.
    override func viewDidAppear() {
        super.viewDidAppear()
        applySize(for: tabViewItems[safe: selectedTabViewItemIndex])
    }

    private func applySize(for item: NSTabViewItem?) {
        guard let label = item?.label,
              let size  = tabSizes[label],
              let w     = view.window else { return }
        w.setContentSize(size)
    }
}

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
    private let tabVC = ResizableTabViewController()

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

        // Use the designated initialiser — the ObjC convenience
        // init(contentViewController:) allocates NSWindow directly, bypassing
        // our ResizableWindow subclass.
        let window = ResizableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = tabVC
        window.title = "MockTab"
        window.isReleasedWhenClosed = false
        // Prevent fullscreen — green button calls zoom(_:) instead.
        window.collectionBehavior = [.managed]
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
            TabletAreaView(settings: s, tabletManager: tm, registry: dr,
                           onDeviceSelected: onDevice, boundProductID: productID)
        }
        addTab(label: "Pressure",     symbol: "scribble.variable",       height: 480) { PressureCurveView(settings: s, tool: s.activeTool, tabletManager: tm, registry: dr) }
        addTab(label: "Buttons",      symbol: "hand.point.up.left",      height: 575) { ButtonMappingView(settings: s, tool: s.activeTool, tabletManager: tm, registry: dr) }
        addTab(label: "Display",      symbol: "display",                 height: 370) { DisplayMappingView(settings: s, tabletManager: tm, registry: dr) }
        addTab(label: "Devices",      symbol: "rectangle.on.rectangle",  height: 480, width: 620) { DevicesView(tabletManager: tm, registry: dr) }
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
        width: CGFloat = 500,
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
        // Pass height=0 so NSTabViewController never sees a height to constrain.
        // ResizableTabViewController calls window.setContentSize directly instead.
        hosting.preferredContentSize = NSSize(width: width, height: 0)
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
        }
        tabVC.register(size: NSSize(width: width, height: height), forTabLabeled: label)

        let item = NSTabViewItem(viewController: hosting)
        item.label = label   // toolbar button text stays short
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        tabVC.addTabViewItem(item)

        nextTabIndex += 1
    }
}
