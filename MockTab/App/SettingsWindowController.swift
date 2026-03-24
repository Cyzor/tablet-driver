import AppKit
import SwiftUI

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - ResizableWindow

final class ResizableWindow: NSWindow {

    @objc dynamic override var styleMask: NSWindow.StyleMask {
        get { super.styleMask }
        set { super.styleMask = newValue.union(.resizable) }
    }

    @objc dynamic override var maxSize: NSSize {
        get { NSSize(width: super.maxSize.width, height: .greatestFiniteMagnitude) }
        set { super.maxSize = NSSize(width: newValue.width, height: .greatestFiniteMagnitude) }
    }

    override func toggleFullScreen(_ sender: Any?) { zoom(sender) }

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

// MARK: - ResizableTabViewController

final class ResizableTabViewController: NSTabViewController {

    private var defaultTabSizes: [String: NSSize] = [:]
    private var lastUserSizes:   [String: NSSize] = [:]

    /// Called when the active tab changes — used to notify TabletManager
    /// whether the Info tab is currently visible.
    var onTabSelected: ((String?) -> Void)?

    // Debounce timer — coalesces rapid resize drag events into a single write.
    private var saveDebounceTimer: Timer?

    func register(defaultSize: NSSize, forTabLabeled label: String) {
        defaultTabSizes[label] = defaultSize
    }

    func loadSavedUserSizes() {
        guard let dict = UserDefaults.standard.dictionary(
            forKey: "MockTab_PerTabUserSizes") as? [String: [String: CGFloat]]
        else { return }
        for (label, sizeDict) in dict {
            if let w = sizeDict["w"], let h = sizeDict["h"] {
                lastUserSizes[label] = NSSize(width: w, height: h)
            }
        }
    }

    private func saveUserSizesToDefaults() {
        let dict = lastUserSizes.mapValues { ["w": $0.width, "h": $0.height] }
        UserDefaults.standard.set(dict, forKey: "MockTab_PerTabUserSizes")
    }

    /// Schedules a save 0.5 s after the last resize event.
    /// Cancels and reschedules on every intermediate event so only one
    /// write reaches UserDefaults per drag gesture.
    private func scheduleSave() {
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5,
                                                repeats: false) { [weak self] _ in
            self?.saveUserSizesToDefaults()
        }
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        applySize(for: tabViewItem)
        onTabSelected?(tabViewItem?.label)
        updateWindowTitle(for: tabViewItem)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applySize(for: tabViewItems[safe: selectedTabViewItemIndex])
        onTabSelected?(tabViewItems[safe: selectedTabViewItemIndex]?.label)
        updateWindowTitle(for: tabViewItems[safe: selectedTabViewItemIndex])
    }

    private func updateWindowTitle(for item: NSTabViewItem?) {
        guard let window = view.window else { return }
        // hosting.title was set to "Label — DeviceName" for device-specific tabs
        // and plain "Label" for shared tabs in SettingsWindowController.addTab.
        if let title = item?.viewController?.title, !title.isEmpty {
            window.title = title
        }
    }

    private func applySize(for item: NSTabViewItem?) {
        guard let label = item?.label,
              let window = view.window else { return }
        let sizeToUse = lastUserSizes[label] ?? defaultTabSizes[label]
        guard let size = sizeToUse else { return }
        if abs(window.frame.width - size.width) > 2
            || abs(window.frame.height - size.height) > 2 {
            window.setContentSize(size)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: nil)
        // Save immediately on close — catches the case where the user
        // resizes and then closes the window within the debounce window.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil)
    }

    @objc private func windowDidResize(_ notification: Notification) {
        guard let resizedWindow = notification.object as? NSWindow,
              resizedWindow === view.window,
              let currentLabel = tabViewItems[safe: selectedTabViewItemIndex]?.label
        else { return }
        lastUserSizes[currentLabel] = resizedWindow.frame.size
        scheduleSave()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === view.window
        else { return }
        // Cancel any pending debounce and write synchronously on close.
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = nil
        saveUserSizesToDefaults()
    }

    // deinit save intentionally removed.
    // isReleasedWhenClosed = false means this object lives for the entire
    // app session — deinit only fires at process exit, when UserDefaults
    // plist flushing is unreliable.  windowWillClose and the debounced
    // windowDidResize handle all persistence needs instead.
}

// MARK: - SettingsWindowController

@MainActor
final class SettingsWindowController: NSWindowController {

    let settings:    TabletSettings
    let deviceLabel: String
    let productID:   Int?

    private let tabVC = ResizableTabViewController()

    static let tabLabels = [
        "Tablet Area", "Pressure", "Buttons", "Display",
        "Devices", "Presets", "Scratchpad", "Info"
    ]

    private static let deviceSpecificTabIndices: Set<Int> = [0, 1, 2, 3]

    init(settings: TabletSettings, deviceLabel: String, productID: Int?) {
        self.settings    = settings
        self.deviceLabel = deviceLabel
        self.productID   = productID

        tabVC.tabStyle = .toolbar

        let window = ResizableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = tabVC
        window.title = "MockTab"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed]
        window.setFrameAutosaveName("MockTabSettingsWindow")

        super.init(window: window)

        // Wire up the Info-tab visibility flag so TabletManager can skip
        // @Published UI writes when nobody is looking at the live data panel.
        tabVC.onTabSelected = { label in
            TabletManager.shared.infoViewVisible = (label == "Info")
        }

        // Clear the flag when the window closes.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window, queue: .main
        ) { _ in TabletManager.shared.infoViewVisible = false }

        let s  = settings
        let tm = TabletManager.shared
        let dr = DeviceRegistry.shared
        let onDevice: (Int) -> Void = { [weak self] pid in
            guard let self else { return }
            PreferencesWindowController.shared.replaceWindow(self, withDeviceID: pid)
        }

        addTab(label: "Tablet Area", symbol: "rectangle.dashed",       height: 420) {
            TabletAreaView(settings: s, tabletManager: tm, registry: dr,
                           onDeviceSelected: onDevice, boundProductID: productID)
        }
        addTab(label: "Pressure",   symbol: "scribble.variable",       height: 480) {
            PressureCurveView(settings: s, tool: s.activeTool, tabletManager: tm, registry: dr)
        }
        addTab(label: "Buttons",    symbol: "hand.point.up.left",      height: 575) {
            ButtonMappingView(settings: s, tool: s.activeTool, tabletManager: tm, registry: dr)
        }
        addTab(label: "Display",    symbol: "display",                 height: 370) {
            DisplayMappingView(settings: s, tabletManager: tm, registry: dr)
        }
        addTab(label: "Devices",    symbol: "rectangle.on.rectangle",  height: 480, width: 620) {
            DevicesView(tabletManager: tm, registry: dr)
        }
        addTab(label: "Presets",    symbol: "star.circle",             height: 450) {
            PresetsView(settings: s)
        }
        addTab(label: "Scratchpad", symbol: "pencil.and.outline",      height: 360) {
            ScratchpadView(settings: s)
        }
        addTab(label: "Info",       symbol: "info.circle",             height: 430) {
            InfoView(tabletManager: tm, settings: s)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public

    func show() {
        tabVC.loadSavedUserSizes()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Sync the Info-tab visibility flag for whichever tab is already selected.
        let label = tabVC.tabViewItems[safe: tabVC.selectedTabViewItemIndex]?.label
        TabletManager.shared.infoViewVisible = (label == "Info")
    }

    func showTab(at index: Int) {
        tabVC.loadSavedUserSizes()
        show()
        guard index >= 0, index < tabVC.tabViewItems.count else { return }
        tabVC.selectedTabViewItemIndex = index
    }

    func showTab(named name: String) {
        tabVC.loadSavedUserSizes()
        let idx = tabVC.tabViewItems.firstIndex(where: { $0.label == name })
        showTab(at: idx ?? 0)
    }

    var selectedTabIndex: Int { tabVC.selectedTabViewItemIndex }

    // MARK: - Private

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

        let isDeviceTab = Self.deviceSpecificTabIndices.contains(nextTabIndex)
        hosting.title = isDeviceTab ? "\(label) — \(deviceLabel)" : label

        hosting.preferredContentSize = NSSize(width: width, height: 0)
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
        }

        tabVC.register(defaultSize: NSSize(width: width, height: height),
                       forTabLabeled: label)

        let item   = NSTabViewItem(viewController: hosting)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        tabVC.addTabViewItem(item)

        nextTabIndex += 1
    }
}
