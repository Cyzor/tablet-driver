// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import TabletKit

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

    /// Guards the toolbar-based minSize computation so we only apply it on the
    /// first appearance, not on every subsequent show (where window.frame.width
    /// could reflect a user-chosen large size and produce an inflated floor).
    private var hasAppliedMinSize = false

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

        // Derive minimum width from the toolbar's actual laid-out item frames.
        // Deferred by one main-queue cycle: viewDidAppear fires before the toolbar
        // finishes its own layout pass, so item frames can still be zero at this
        // point. Applied once; subsequent shows leave the measured value in place.
        if !hasAppliedMinSize, let window = view.window {
            hasAppliedMinSize = true
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                window.minSize = NSSize(width: self.toolbarMinWidth(in: window), height: 500)
            }
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

    /// Returns the minimum window width needed to show all toolbar tab items
    /// without overflow, measured from the actual laid-out views.
    ///
    /// `NSTabViewController(.toolbar)` items use standard (non-custom-view) toolbar
    /// items, so `NSToolbarItem.view` is nil and cannot be measured directly.
    /// Instead this locates the toolbar container in the window frame hierarchy
    /// and reads item positions from it. Falls back to a per-tab formula —
    /// independent of current window width, so it stays correct even when a
    /// previously-saved narrow frame is restored before this runs.
    private func toolbarMinWidth(in window: NSWindow) -> CGFloat {
        // Fast path: custom-view toolbar items (not the NSTabViewController case,
        // but included for completeness/future-proofing).
        if let toolbar = window.toolbar {
            let widths = toolbar.items.compactMap { $0.view?.frame.width }.filter { $0 > 8 }
            if !widths.isEmpty {
                return widths.reduce(0, +) + 32
            }
        }

        // Locate the toolbar container: it sits above the content view as a
        // sibling inside the window frame view, spanning most of the window width.
        let expectedCount = tabViewItems.count
        if let contentView = window.contentView,
           let frameView = contentView.superview
        {
            let contentTop = contentView.frame.maxY
            for candidate in frameView.subviews where candidate !== contentView {
                guard candidate.frame.minY >= contentTop - 2,
                      candidate.frame.width > window.frame.width * 0.5
                else { continue }
                // Sort children left-to-right; skip hairlines and zero-size views.
                let items = candidate.subviews
                    .filter { $0.frame.width > 20 }
                    .sorted { $0.frame.minX < $1.frame.minX }
                // Require all tab items to be visible. Fewer means the toolbar is
                // already in overflow (window too narrow) or this is the wrong view.
                guard items.count >= expectedCount else { continue }
                // The rightmost item edge plus a small trailing margin gives the
                // minimum window width. Item x-coordinates already account for the
                // window chrome on the left, so no additional chrome offset is needed.
                return (items.last?.frame.maxX ?? 0) + 8
            }
        }

        // Formula fallback: ~70 pt per tab item (icon + truncated label + spacing,
        // empirically stable across locales) plus ~80 pt for window chrome and
        // margins. Derived from tab count, so it adapts to Touch being present
        // or absent and does not depend on the current window width.
        return CGFloat(expectedCount) * 70 + 80
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

    private let tabVC = ResizableTabViewController()

    enum Tab: Int {
        case tabletArea = 0, penFeel, buttons, touch, display, devices, profiles, scratchpad, info
    }

    static let tabLabels = [
        String(localized: "Tablet Area", comment: "Tab name: tablet active area configuration"),
        String(
            localized: "Pen Feel",
            comment: "Tab name: pen pressure, smoothing, double-click settings"),
        String(localized: "Buttons", comment: "Tab name: button and key mapping"),
        String(localized: "Touch", comment: "Tab name: capacitive finger-touch settings"),
        String(localized: "Display", comment: "Tab name: display mapping and preview"),
        String(localized: "Devices", comment: "Tab name: tablet and tool registry"),
        String(localized: "Profiles", comment: "Tab name: profile management"),
        String(localized: "Scratchpad", comment: "Tab name: test area for pen input"),
        String(localized: "Info", comment: "Tab name: live pen coordinates and device info"),
    ]

    private static let deviceSpecificTabIndices: Set<Int> = [0, 1, 2, 3, 4, 5, 6, 7, 8]

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
        window.tabbingIdentifier = "MockTabSettings"

        // Set a conservative minimum width before autosave frame restoration so a
        // previously-saved narrow frame cannot be applied. Tab count is computable
        // from the registry at this point; formula: ~70 pt per tab + ~80 pt chrome.
        // The deferred measurement in viewDidAppear will refine this once the
        // toolbar is fully laid out.
        let hasTouchTab = productID.flatMap { WacomDeviceRegistry.spec(for: $0) }?.hasFingerTouch == true
        window.minSize = NSSize(width: CGFloat(hasTouchTab ? 9 : 8) * 70 + 80, height: 500)

        // Don't auto-save frame for device-specific windows — PreferencesWindowController
        // handles manual persistence to support per-device window positions.
        if productID == nil {
            window.setFrameAutosaveName("PreferencesWindow")
        }

        super.init(window: window)

        // Vend docUndoManager through NSWindow.undoManager (which consults
        // windowWillReturnUndoManager before creating its own), so the nil-target
        // undo:/redo: menu items validate, retitle, and fire against it.
        window.delegate = self
        settings.undoManager = docUndoManager
        settings.activeTool.undoManager = docUndoManager

        // Wire up the live-state visibility flag so TabletManager can skip
        // @Published UI writes when nobody is looking at live data.
        // "Info" (pen coordinates/pressure), "Buttons" (live indicators), and
        // "Scratchpad" (tilt visualizer) all consume livePoint/liveButtons, so
        // any of those tabs enables the updates.
        // Also check window focus: only update when this window is key (active).
        let updateVisibility = { [weak self, weak window] in
            guard let self else { return }
            let label =
                self.tabVC.tabViewItems[safe: self.tabVC.selectedTabViewItemIndex]?.label ?? ""
            // Use tabLabels indices via the Tab enum so adding/reordering tabs
            // doesn't break the visibility gate.
            let isInfoTab = (label == Self.tabLabels[Tab.info.rawValue] || label == Self.tabLabels[Tab.buttons.rawValue] || label == Self.tabLabels[Tab.scratchpad.rawValue])
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

        addTab(label: Self.tabLabels[Tab.tabletArea.rawValue], symbol: "rectangle.dashed", height: 790) {
            TabletAreaView(
                settings: s, tabletManager: tm, registry: dr,
                onDeviceSelected: onDevice, boundProductID: productID)
        }
        addTab(label: Self.tabLabels[Tab.penFeel.rawValue], symbol: "scribble.variable", height: 480, freezeOnResize: true) {
            PenFeelView(settings: s, tabletManager: tm, registry: dr, productID: productID)
        }
        addTab(label: Self.tabLabels[Tab.buttons.rawValue], symbol: "square.grid.2x2.fill", height: 575, freezeOnResize: true) {
            ButtonMappingView(
                settings: s, tabletManager: tm, registry: dr,
                productID: productID)
        }
        // Touch tab is only registered for devices whose spec declares finger touch.
        // The pane itself also guards against being shown for a non-touch device
        // (defence-in-depth in case the spec lookup changes).
        let touchSpec = productID.flatMap { WacomDeviceRegistry.spec(for: $0) }
        if touchSpec?.hasFingerTouch == true {
            addTab(label: Self.tabLabels[Tab.touch.rawValue], symbol: "hand.point.up.left", height: 480) {
                TouchView(settings: s, tabletManager: tm, registry: dr, productID: productID)
            }
        }
        addTab(label: Self.tabLabels[Tab.display.rawValue], symbol: "display", height: 370) {
            DisplayMappingView(settings: s, tabletManager: tm, registry: dr, productID: productID)
        }
        addTab(label: Self.tabLabels[Tab.devices.rawValue], symbol: "rectangle.on.rectangle", height: 480, width: 620)
        {
            DevicesView(settings: s, tabletManager: tm, registry: dr, productID: productID, undoManager: um)
        }
        addTab(label: Self.tabLabels[Tab.profiles.rawValue], symbol: "star.circle", height: 450) {
            ProfilesView(settings: s, tabletManager: tm, registry: dr, productID: productID)
        }
        addTab(label: Self.tabLabels[Tab.scratchpad.rawValue], symbol: "pencil.and.outline", height: 360) {
            ScratchpadView(settings: s, tabletManager: tm, registry: dr, productID: productID, undoManager: um)
        }
        addTab(label: Self.tabLabels[Tab.info.rawValue], symbol: "info.circle", height: 430) {
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
            (label == Self.tabLabels[Tab.info.rawValue] || label == Self.tabLabels[Tab.buttons.rawValue] || label == Self.tabLabels[Tab.scratchpad.rawValue])
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

        let hosting = NSHostingController(rootView: aligned.withAppearance())

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

extension SettingsWindowController: NSWindowDelegate {
    /// NSWindow.undoManager consults this before lazily creating its own,
    /// which is what the nil-target undo:/redo: Edit menu items resolve
    /// against for validation, contextual titles, and dispatch.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        docUndoManager
    }
}
