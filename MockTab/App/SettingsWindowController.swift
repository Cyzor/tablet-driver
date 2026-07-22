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

extension NSWindow {
    /// Grows the current frame up to `minSize` in either dimension if it's
    /// currently smaller, keeping the top-left corner anchored. No-op if the
    /// frame already meets `minSize`. Needed because `setFrame`/`setContentSize`
    /// don't enforce `minSize` themselves — only interactive resizing and
    /// `zoom(_:)` do.
    func clampToMinSize() {
        let current = frame
        let width = max(current.width, minSize.width)
        let height = max(current.height, minSize.height)
        guard width > current.width || height > current.height else { return }
        setFrame(
            NSRect(
                x: current.minX,
                y: current.maxY - height,
                width: width,
                height: height),
            display: false)
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

    /// True while this controller is itself resizing the window (tab-switch
    /// auto-size, min-size clamp) — `windowDidResize` must not mistake these
    /// for a user drag, or `userHasResized` latches true on the very first
    /// programmatic resize and every future tab switch stops auto-sizing.
    private var isProgrammaticResize = false

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
        // Root cause of the long-standing "window permanently unresizable after
        // switching tabs" bug (introduced in 7c01f64): this used to also set
        // `tabViewItem.viewController.preferredContentSize` to the window's
        // *current* frame size whenever `userHasResized` was true, to stop
        // NSTabViewController's native per-tab auto-resize from fighting a
        // user-resized window. But `showTab(at:)` calls `suppressAutoResize()`
        // (which sets `userHasResized = true`) *before* the window is ever
        // shown — including on the very first tab display — so that line could
        // fire before the window had been laid out, capturing a bogus/zero
        // frame size and pinning the tab's preferredContentSize to it
        // permanently. `applyDefaultSize`'s own `!userHasResized` guard below
        // already prevents the window from being force-resized back to
        // per-tab defaults once the user has taken ownership of the size, so
        // this extra line was both redundant and the actual source of the bug.
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
                let minWidth = self.toolbarMinWidth(in: window)
                window.minSize = NSSize(width: minWidth, height: 500)
                // The measurement above is authoritative for this window's toolbar
                // layout — widen an already-narrower restored/last-known frame now,
                // since setFrame/setContentSize don't enforce minSize on their own.
                self.isProgrammaticResize = true
                window.clampToMinSize()
                self.isProgrammaticResize = false
            }
        }
    }

    @objc private func windowDidResize(_ notification: Notification) {
        guard !isProgrammaticResize else { return }
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
            isProgrammaticResize = true
            window.setContentSize(size)
            isProgrammaticResize = false
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

// MARK: - LazyHostingViewController

/// Defers building its wrapped `NSHostingController` (and thus evaluating the
/// SwiftUI view tree and its GPU-backed layer) until the tab actually becomes
/// visible, instead of all panes paying that cost up front in
/// `SettingsWindowController.init`.
private final class LazyHostingViewController: NSViewController {
    private let make: () -> NSViewController
    private var inner: NSViewController?

    init(make: @escaping () -> NSViewController) {
        self.make = make
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var preferredContentSize: NSSize {
        get { inner?.preferredContentSize ?? super.preferredContentSize }
        set {
            if let inner {
                inner.preferredContentSize = newValue
            } else {
                super.preferredContentSize = newValue
            }
        }
    }

    override func loadView() {
        view = NSView()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard inner == nil else { return }
        let built = make()
        addChild(built)
        built.view.frame = view.bounds
        built.view.autoresizingMask = [.width, .height]
        view.addSubview(built.view)
        inner = built
    }
}

// MARK: - SettingsWindowController

@MainActor
final class SettingsWindowController: NSWindowController {

    let settings: TabletSettings
    let deviceLabel: String
    /// Physical-unit identity this window is bound to; nil for the generic
    /// (no-device) window. Window matching, restore, and the size cache all
    /// key on this.
    let instanceKey: DeviceInstanceKey?
    /// Model axis of the bound device — what spec lookups and the panes
    /// (which predate instance identity) consume.
    var productID: Int? { instanceKey?.productID }
    /// Reads the device's own canonical undo manager (`TabletSettings.undoManager`)
    /// rather than owning one — so multiple windows for the same device share
    /// one undo stack instead of each window's init silently stealing the
    /// device's `undoManager` reference out from under the others.
    var docUndoManager: UndoManager { settings.undoManager ?? UndoManager() }

    /// Expose docUndoManager through the NSResponder chain so AppKit's standard
    /// Cmd+Z / Cmd+Shift+Z handling reaches it when this window is key.
    override var undoManager: UndoManager? { docUndoManager }

    private let tabVC = ResizableTabViewController()

    enum Tab: Int {
        case tabletArea = 0
        case penFeel, buttons, touch, display, devices, profiles, scratchpad, info
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

    init(settings: TabletSettings, deviceLabel: String, instanceKey: DeviceInstanceKey?) {
        self.settings = settings
        self.deviceLabel = deviceLabel
        self.instanceKey = instanceKey
        let productID = instanceKey?.productID

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
        // staticSpec resolves non-Wacom devices too (the Wacom registry alone
        // returns nil for them). An aux-only device — the Quick Keys puck:
        // express keys and dial, no pen digitizer — gets a trimmed window of
        // Buttons, Devices, and Info. The pen-oriented tabs are structurally
        // inapplicable there, so hiding (not disabling) is the right
        // treatment. Scoped to the Xencelabs parser so no Wacom window
        // changes shape. (The wireless dongle no longer has a window
        // identity of its own — it folds into the puck's canonical PID, see
        // `VendorDeviceRegistry.canonicalProductID(for:)`.)
        let staticSpec = productID.flatMap { TabletManager.staticSpec(forProductID: $0) }
        let isAuxOnly = staticSpec?.parser == .xencelabs && staticSpec?.maxX == 0
        let hasTouchTab = staticSpec?.hasFingerTouch == true
        let tabCount = isAuxOnly ? 3 : (hasTouchTab ? 9 : 8)
        window.minSize = NSSize(width: CGFloat(tabCount) * 70 + 80, height: 500)

        // Don't auto-save frame for device-specific windows — SettingsWindowManager
        // handles manual persistence to support per-device window positions.
        if productID == nil {
            window.setFrameAutosaveName("PreferencesWindow")
        }

        super.init(window: window)

        // Vend the device's own undo manager through NSWindow.undoManager
        // (which consults windowWillReturnUndoManager before creating its
        // own), so the nil-target undo:/redo: menu items validate, retitle,
        // and fire against it. `settings.undoManager` and its `activeTool`
        // are already wired to each other at TabletSettings construction
        // time — nothing to assign here, deliberately, so a second window
        // opening for the same device can't steal the reference.
        window.delegate = self

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
            let isInfoTab =
                (label == Self.tabLabels[Tab.info.rawValue]
                    || label == Self.tabLabels[Tab.buttons.rawValue]
                    || label == Self.tabLabels[Tab.scratchpad.rawValue])
            let isKeyWindow = window?.isKeyWindow ?? false
            let visible = isInfoTab && isKeyWindow
            Task { @MainActor in
                TabletManager.shared.infoViewVisible = visible
                if visible { TabletManager.shared.resyncLiveStateForVisibility() }
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
            SettingsWindowManager.shared.replaceWindow(self, withDeviceID: pid)
        }

        if !isAuxOnly {
            addTab(
                label: Self.tabLabels[Tab.tabletArea.rawValue], symbol: "rectangle.dashed",
                height: 790
            ) {
                TabletAreaView(
                    settings: s, tabletManager: tm, registry: dr,
                    onDeviceSelected: onDevice, boundKey: instanceKey)
            }
            addTab(
                label: Self.tabLabels[Tab.penFeel.rawValue], symbol: "scribble.variable",
                height: 480
            ) {
                PenFeelView(settings: s, tabletManager: tm, registry: dr, instanceKey: instanceKey)
            }
        }
        addTab(
            label: Self.tabLabels[Tab.buttons.rawValue], symbol: "square.grid.2x2.fill",
            height: 575
        ) {
            ButtonMappingView(
                settings: s, tabletManager: tm, registry: dr,
                instanceKey: instanceKey)
        }
        // Touch tab is only registered for devices whose spec declares finger touch.
        // The pane itself also guards against being shown for a non-touch device
        // (defence-in-depth in case the spec lookup changes).
        if hasTouchTab {
            addTab(
                label: Self.tabLabels[Tab.touch.rawValue], symbol: "hand.point.up.left", height: 480
            ) {
                TouchView(settings: s, tabletManager: tm, registry: dr, instanceKey: instanceKey)
            }
        }
        if !isAuxOnly {
            addTab(label: Self.tabLabels[Tab.display.rawValue], symbol: "display", height: 370) {
                DisplayMappingView(
                    settings: s, tabletManager: tm, registry: dr, instanceKey: instanceKey)
            }
        }
        addTab(
            label: Self.tabLabels[Tab.devices.rawValue], symbol: "rectangle.on.rectangle",
            height: 480, width: 620
        ) {
            DevicesView(
                settings: s, tabletManager: tm, registry: dr, instanceKey: instanceKey,
                undoManager: um)
        }
        if !isAuxOnly {
            addTab(
                label: Self.tabLabels[Tab.profiles.rawValue], symbol: "star.circle", height: 450
            ) {
                ProfilesView(settings: s, tabletManager: tm, registry: dr, instanceKey: instanceKey)
            }
        }
        if !isAuxOnly {
            addTab(
                label: Self.tabLabels[Tab.scratchpad.rawValue], symbol: "pencil.and.outline",
                height: 360
            ) {
                ScratchpadView(
                    settings: s, tabletManager: tm, registry: dr, instanceKey: instanceKey,
                    undoManager: um)
            }
        }
        addTab(label: Self.tabLabels[Tab.info.rawValue], symbol: "info.circle", height: 430) {
            InfoView(tabletManager: tm, settings: s, instanceKey: instanceKey)
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
        let visible =
            (label == Self.tabLabels[Tab.info.rawValue]
                || label == Self.tabLabels[Tab.buttons.rawValue]
                || label == Self.tabLabels[Tab.scratchpad.rawValue])
            && window?.isKeyWindow == true
        TabletManager.shared.infoViewVisible = visible
        if visible { TabletManager.shared.resyncLiveStateForVisibility() }
    }

    func showTab(at index: Int) {
        // Programmatic tab selection must not trigger per-tab auto-sizing: the
        // user's intent is to navigate, not to resize. Suppress before show() so
        // the flag is in place before viewDidAppear fires.
        suppressAutoResize()
        show()
        guard index >= 0, index < tabVC.tabViewItems.count else { return }
        tabVC.selectedTabViewItemIndex = index
    }

    func showTab(_ tab: Tab) {
        let label = Self.tabLabels[tab.rawValue]
        if let index = tabVC.tabViewItems.firstIndex(where: { $0.label == label }) {
            showTab(at: index)
        }
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
        @ViewBuilder content: @escaping () -> Content
    ) {
        let isDeviceTab = Self.deviceSpecificTabIndices.contains(nextTabIndex)
        let title = isDeviceTab ? "\(label) — \(deviceLabel)" : label

        tabVC.register(
            defaultSize: NSSize(width: width, height: height),
            forTabLabeled: label)

        let lazy = LazyHostingViewController {
            let aligned = content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            let hosting = NSHostingController(rootView: aligned.withAppearance())
            hosting.title = title
            hosting.preferredContentSize = NSSize(width: width, height: 0)
            if #available(macOS 13.0, *) {
                hosting.sizingOptions = []
            }
            return hosting
        }
        lazy.title = title
        lazy.preferredContentSize = NSSize(width: width, height: 0)

        let item = NSTabViewItem(viewController: lazy)
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
