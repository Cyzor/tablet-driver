// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
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
        guard let screen = screen ?? NSScreen.main else {
            super.zoom(sender)
            return
        }
        let visible = screen.visibleFrame
        let alreadyMaximised =
            abs(frame.height - visible.height) < 2
            && abs(frame.minY - visible.minY) < 2
        if alreadyMaximised {
            super.zoom(sender)
        } else {
            setFrame(
                NSRect(
                    x: frame.minX, y: visible.minY,
                    width: frame.width, height: visible.height),
                display: true, animate: true)
        }
    }
}

// MARK: - ResizableTabViewController

final class ResizableTabViewController: NSTabViewController {

    private var defaultTabSizes: [String: NSSize] = [:]

    /// Set to true the first time the user manually resizes the window.
    /// Once set, tab switches no longer resize the window — the user's
    /// chosen size is used for all tabs.
    private var userHasResized = false

    /// Called when the active tab changes — used to notify TabletManager
    /// whether the Info tab is currently visible.
    var onTabSelected: ((String?) -> Void)?

    func register(defaultSize: NSSize, forTabLabeled label: String) {
        defaultTabSizes[label] = defaultSize
    }

    /// Suppress auto-sizing on tab switches — call this when restoring a
    /// window whose size was explicitly saved by the user.
    func suppressAutoResize() {
        userHasResized = true
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        applyDefaultSize(for: tabViewItem)
        onTabSelected?(tabViewItem?.label)
        updateWindowTitle(for: tabViewItem)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        onTabSelected?(tabViewItems[safe: selectedTabViewItemIndex]?.label)
        updateWindowTitle(for: tabViewItems[safe: selectedTabViewItemIndex])

        // Begin tracking resize events now that the window exists.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: view.window)

        // Minimum width varies by locale (tab labels differ in length).
        // The value lives in Localizable.xcstrings so it stays co-located
        // with translations and needs no code changes when labels are updated.
        if let window = view.window {
            let minWidth = CGFloat(
                Double(String(localized: "settings-window-min-width",
                              comment: "Minimum window width (pts) that keeps all toolbar tabs visible without overflow. Update this when translations change significantly."))
                ?? 560)
            window.minSize = NSSize(width: minWidth, height: 500)
        }
    }

    @objc private func windowDidResize(_ notification: Notification) {
        userHasResized = true
    }

    private func applyDefaultSize(for item: NSTabViewItem?) {
        guard !userHasResized,
            let label = item?.label,
            let size = defaultTabSizes[label],
            let window = view.window
        else { return }
        if abs(window.frame.width - size.width) > 2
            || abs(window.frame.height - size.height) > 2
        {
            window.setContentSize(size)
        }
    }

    private func updateWindowTitle(for item: NSTabViewItem?) {
        guard let window = view.window else { return }
        // hosting.title was set to "Label — DeviceName" for all tabs in addTab.
        if let title = item?.viewController?.title, !title.isEmpty {
            window.title = title
        }
    }
}

// MARK: - LiveResizeFreezeView / LiveResizeFreezeViewController

/// Container NSView that pins its content at its current size when live resize
/// starts — the content is clipped to the shrinking window and shows empty space
/// when the window grows — then snaps to the final size on mouse release.
private final class LiveResizeFreezeView: NSView {
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        subviews.first?.autoresizingMask = [.minYMargin, .maxXMargin]   // freeze size, anchor top-left
        wantsLayer = true
        layer?.masksToBounds = true             // clip overflow when window shrinks
    }

    override func viewDidEndLiveResize() {
        if let content = subviews.first {
            content.autoresizingMask = [.width, .height]
            content.frame = bounds              // snap to final size
        }
        layer?.masksToBounds = false
        super.viewDidEndLiveResize()
    }
}

/// Thin NSViewController that hosts the pane's NSHostingController inside a
/// LiveResizeFreezeView and forwards the properties NSTabViewController reads.
private final class LiveResizeFreezeViewController: NSViewController {
    private let inner: NSViewController

    override var preferredContentSize: NSSize {
        get { inner.preferredContentSize }
        set { inner.preferredContentSize = newValue }
    }

    init(wrapping inner: NSViewController) {
        self.inner = inner
        super.init(nibName: nil, bundle: nil)
        addChild(inner)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = LiveResizeFreezeView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        inner.view.autoresizingMask = [.width, .height]
        inner.view.frame = view.bounds
        view.addSubview(inner.view)
    }
}

// MARK: - SettingsWindowController

@MainActor
final class SettingsWindowController: NSWindowController {

    let settings: TabletSettings
    let deviceLabel: String
    let productID: Int?
    let docUndoManager = UndoManager()

    /// Expose docUndoManager through the NSResponder chain so AppKit's standard
    /// Cmd+Z / Cmd+Shift+Z handling reaches it when this window is key.
    override var undoManager: UndoManager? { docUndoManager }

    /// Alias for PreferencesWindowController access (kept for source compatibility).
    var settingsUndoManager: UndoManager? { docUndoManager }

    private let tabVC = ResizableTabViewController()

    enum Tab: Int {
        case tabletArea = 0, penFeel, buttons, display, devices, profiles, scratchpad, info
    }

    static let tabLabels = [
        String(localized: "Tablet Area", comment: "Tab name: tablet active area configuration"),
        String(
            localized: "Pen Feel",
            comment: "Tab name: pen pressure, smoothing, double-click settings"),
        String(localized: "Buttons", comment: "Tab name: button and key mapping"),
        String(localized: "Display", comment: "Tab name: display mapping and preview"),
        String(localized: "Devices", comment: "Tab name: tablet and tool registry"),
        String(localized: "Profiles", comment: "Tab name: profile management"),
        String(localized: "Scratchpad", comment: "Tab name: test area for pen input"),
        String(localized: "Info", comment: "Tab name: live pen coordinates and device info"),
    ]

    private static let deviceSpecificTabIndices: Set<Int> = [0, 1, 2, 3, 4, 5, 6, 7]

    init(settings: TabletSettings, deviceLabel: String, productID: Int?) {
        self.settings = settings
        self.deviceLabel = deviceLabel
        self.productID = productID

        tabVC.tabStyle = .toolbar

        let window = ResizableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 790),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = tabVC
        window.title = "MockTab"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .fullScreenAllowsTiling]
        window.tabbingMode = .automatic
        // Don't auto-save frame for device-specific windows — PreferencesWindowController
        // handles manual persistence to support per-device window positions.
        if productID == nil {
            window.setFrameAutosaveName("PreferencesWindow")
        }

        super.init(window: window)

        // Set up undo manager for settings layer
        // Note: NSWindow.undoManager is read-only, so we can't wire Cmd+Z through the window
        // Instead, we rely on the Edit menu items being enabled via canUndo/canRedo
        settings.undoManager = docUndoManager
        settings.activeTool.undoManager = docUndoManager

        // Wire up the live-state visibility flag so TabletManager can skip
        // @Published UI writes when nobody is looking at live data.
        // Both "Info" (pen coordinates/pressure) and "Buttons" (live indicators)
        // consume livePoint/liveButtons, so either tab enables the updates.
        // Also check window focus: only update when this window is key (active).
        let updateVisibility = { [weak self, weak window] in
            guard let self else { return }
            let label =
                self.tabVC.tabViewItems[safe: self.tabVC.selectedTabViewItemIndex]?.label ?? ""
            // Use tabLabels indices to match localized strings regardless of locale:
            // [2] = Buttons, [7] = Info
            let isInfoTab = (label == Self.tabLabels[Tab.info.rawValue] || label == Self.tabLabels[Tab.buttons.rawValue])
            let isKeyWindow = window?.isKeyWindow ?? false
            Task { @MainActor in
                TabletManager.shared.infoViewVisible = isInfoTab && isKeyWindow
            }
        }

        tabVC.onTabSelected = { [weak self] _ in
            guard self != nil else { return }
            updateVisibility()
        }

        // Update when window gains/loses focus.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            guard self != nil else { return }
            updateVisibility()
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main
        ) { _ in
            Task { @MainActor in
                TabletManager.shared.infoViewVisible = false
            }
        }

        // Clear the flag when the window closes.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window, queue: .main
        ) { _ in MainActor.assumeIsolated { TabletManager.shared.infoViewVisible = false } }

        let s = settings
        let tm = TabletManager.shared
        let dr = DeviceRegistry.shared
        let um = docUndoManager
        let onDevice: (Int) -> Void = { [weak self] pid in
            guard let self else { return }
            PreferencesWindowController.shared.replaceWindow(self, withDeviceID: pid)
        }

        addTab(label: Self.tabLabels[0], symbol: "rectangle.dashed", height: 790) {
            TabletAreaView(
                settings: s, tabletManager: tm, registry: dr,
                onDeviceSelected: onDevice, boundProductID: productID)
        }
        addTab(label: Self.tabLabels[1], symbol: "scribble.variable", height: 480, freezeOnResize: true) {
            PenFeelView(settings: s, tabletManager: tm, registry: dr, productID: productID)
        }
        addTab(label: Self.tabLabels[2], symbol: "square.grid.2x2.fill", height: 575, freezeOnResize: true) {
            ButtonMappingView(
                settings: s, tabletManager: tm, registry: dr,
                productID: productID)
        }
        addTab(label: Self.tabLabels[3], symbol: "display", height: 370) {
            DisplayMappingView(settings: s, tabletManager: tm, registry: dr, productID: productID)
        }
        addTab(label: Self.tabLabels[4], symbol: "rectangle.on.rectangle", height: 480, width: 620)
        {
            DevicesView(settings: s, tabletManager: tm, registry: dr, productID: productID, undoManager: um)
        }
        addTab(label: Self.tabLabels[5], symbol: "star.circle", height: 450) {
            ProfilesView(settings: s, tabletManager: tm, registry: dr, productID: productID)
        }
        addTab(label: Self.tabLabels[6], symbol: "pencil.and.outline", height: 360) {
            ScratchpadView(settings: s, tabletManager: tm, registry: dr, productID: productID)
        }
        addTab(label: Self.tabLabels[7], symbol: "info.circle", height: 430) {
            InfoView(tabletManager: tm, settings: s, productID: productID)
        }

    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public

    /// Call after setting an explicit window frame from saved state so that
    /// tab switches don't override the restored size with per-tab defaults.
    func suppressAutoResize() {
        tabVC.suppressAutoResize()
    }

    func show() {
        showWindow(nil)
        // Only activate if not already active to avoid focus cycling
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        // Sync the Info-tab visibility flag for whichever tab is already selected.
        // Only set true if the window is key (in focus) and tab is Info or Buttons.
        let label = tabVC.tabViewItems[safe: tabVC.selectedTabViewItemIndex]?.label
        TabletManager.shared.infoViewVisible =
            (label == Self.tabLabels[Tab.info.rawValue] || label == Self.tabLabels[Tab.buttons.rawValue])
            && window?.isKeyWindow == true
    }

    func showTab(at index: Int) {
        show()
        guard index >= 0, index < tabVC.tabViewItems.count else { return }
        tabVC.selectedTabViewItemIndex = index
    }

    func showTab(_ tab: Tab) {
        showTab(at: tab.rawValue)
    }
    //
    var selectedTabIndex: Int { tabVC.selectedTabViewItemIndex }

    // MARK: - Private

    private var nextTabIndex = 0

    private func addTab<Content: View>(
        label: String,
        symbol: String,
        height: CGFloat,
        width: CGFloat = 500,
        freezeOnResize: Bool = false,
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

        tabVC.register(
            defaultSize: NSSize(width: width, height: height),
            forTabLabeled: label)

        let vc: NSViewController
        if freezeOnResize {
            let frozen = LiveResizeFreezeViewController(wrapping: hosting)
            frozen.title = hosting.title
            vc = frozen
        } else {
            vc = hosting
        }
        let item = NSTabViewItem(viewController: vc)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        tabVC.addTabViewItem(item)

        nextTabIndex += 1
    }
}
