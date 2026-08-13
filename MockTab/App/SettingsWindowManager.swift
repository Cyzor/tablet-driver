// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// `@preconcurrency` on AppKit: the one-shot close observer in `observeClose`
// captures its own `NSObjectProtocol` token so it can unregister itself. That
// type comes from ObjectiveC (re-exported by AppKit) and is not `Sendable`,
// though the closure is delivered on `.main` and immediately enters
// `MainActor.assumeIsolated`. This suppresses the Sendable diagnostics only —
// it changes no code generation.
@preconcurrency import AppKit
import Combine
import SwiftUI
import TabletKit

/// Owns the lifecycle of every open settings window and the shared
/// `TabletSettings` instance. One per app run; each window it opens gets a
/// `SettingsWindowController`, which owns that window's own AppKit plumbing.
@MainActor
final class SettingsWindowManager: ObservableObject {

    static let shared = SettingsWindowManager()

    let settings = TabletSettings()

    private var windows: [SettingsWindowController] = [] {
        didSet { publishWindowDescriptors() }
    }
    /// Published list of open windows for the menu bar / dock menus.
    /// Updated automatically whenever `windows` changes.
    @Published private(set) var windowDescriptors: [WindowDescriptor] = []

    private var defaultWindow: SettingsWindowController?
    private var deviceObserver: AnyCancellable?
    private var isTerminating = false
    private var skipWindowSave = false

    /// Last-known window size per logical window, keyed by the device's
    /// instance-key string or "generic". Captured when a window closes so
    /// re-opening it restores the size the user last had, even though the
    /// closed window is no longer in `windows` and therefore absent from
    /// `saveWindowState()`.
    private var lastKnownSizes: [String: NSSize] = [:]

    private func sizeKey(_ key: DeviceInstanceKey?) -> String {
        key.map { DeviceRegistry.shared.normalizedKey($0).stringValue } ?? "generic"
    }

    /// Whether two window identities denote the same physical unit, folding
    /// the claimed instance and the legacy empty-instance form together — a
    /// window restored from a pre-instance save must match the same device
    /// once it connects with its real serial.
    private func sameDevice(_ a: DeviceInstanceKey?, _ b: DeviceInstanceKey?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let registry = DeviceRegistry.shared
        return registry.normalizedKey(a) == registry.normalizedKey(b)
    }

    private func window(for key: DeviceInstanceKey) -> SettingsWindowController? {
        windows.first(where: { sameDevice($0.instanceKey, key) })
    }

    /// Resolves a bare model PID (menus, legacy callers, old saved state) to
    /// a physical unit: the connected unit holding the model's claimed
    /// namespace when one is live, else the registry's first row for that
    /// model, else the legacy empty-instance identity.
    private func resolveKey(forProductID productID: Int) -> DeviceInstanceKey {
        let tm = TabletManager.shared
        if let context = tm.contexts[productID] {
            return context.instanceKey
        }
        if let row = DeviceRegistry.shared.knownTablets.first(
            where: { $0.productID == productID })
        {
            return row.instanceKey
        }
        return DeviceInstanceKey(productID: productID, instance: "")
    }

    private static let restorationKey = "MockTab_OpenWindows"

    private init() {
        // Also observe the context store: a second unit of an already-
        // connected model changes `deviceContexts` without changing the
        // model-level `connectedProductIDs` set.
        deviceObserver = TabletManager.shared.$connectedProductIDs
            .combineLatest(TabletManager.shared.$deviceContexts)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] ids, deviceContexts in
                guard let self else { return }
                // Close any open window whose device has just become a
                // claimed companion — devices enumerate one at a time, so a
                // puck/dongle that arrived before its owning tablet got a
                // window while momentarily unowned. The loop below then
                // opens (or keeps) the owner's window in its place.
                for wc in self.windows {
                    if let pid = wc.productID,
                        VendorDeviceRegistry.isConnectedCompanion(
                            productID: pid, connectedProductIDs: ids)
                    {
                        wc.window?.close()
                    }
                }
                // Migrate a generic (no-device) default window to the first
                // newly-connected tablet that doesn't already have a window —
                // skipping claimed companions, which fold into their owner's
                // window instead of receiving one of their own.
                if let dw = self.defaultWindow,
                   dw.instanceKey == nil,
                   let pid = ids.first(where: { id in
                       !self.windows.contains(where: { $0.productID == id })
                           && !VendorDeviceRegistry.isConnectedCompanion(
                               productID: id, connectedProductIDs: ids)
                   }) {
                    self.replaceWindow(dw, withDeviceID: pid)
                }
                // Deliberately no auto-open: connecting a device no longer
                // builds a settings window on its own. Windows are created
                // only by explicit user action (status item, menus, dock
                // reopen) or session restore — keeping the idle driver free
                // of any SwiftUI/window instantiation.
            }

        restoreWindows()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Set flag first — prevents the window close cascade that
                // AppKit triggers during termination from wiping the saved list.
                self?.isTerminating = true
                self?.saveWindowState()
            }
        }
    }

    /// Tell SettingsWindowManager to skip the next window state save.
    /// Used by Factory Reset to prevent willTerminate from re-saving cleared state.
    func skipNextWindowSave() {
        skipWindowSave = true
    }

    // MARK: - Default window API

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        ensureDefaultWindow().show()
    }

    func showIfNoSavedSession() {
        guard windows.isEmpty else { return }
        // An empty (but present) saved list means the user quit with every
        // window closed — respect that and stay windowless. Only a missing
        // key (true first launch) opens the default window uninvited.
        guard UserDefaults.standard.object(forKey: Self.restorationKey) == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        ensureDefaultWindow().show()
    }

    func showTab(at index: Int) {
        frontmostSettingsWindow().showTab(at: index)
    }

    func showTab(_ tab: SettingsWindowController.Tab) {
        frontmostSettingsWindow().showTab(tab)
    }

    // MARK: - Multi-window

    @discardableResult
    func openWindow(forInstanceKey key: DeviceInstanceKey) -> SettingsWindowController {
        // A companion peripheral (Xencelabs Quick Keys puck/dongle) never
        // gets a window of its own while its owning tablet is connected —
        // redirect to the owner instead. Covers every caller (menus, status
        // item, "Detect Tablet"), not just the auto-open sink. Ownership is
        // a model-level relation; the owner resolves to its connected unit.
        if let ownerPID = VendorDeviceRegistry.connectedCompanionOwner(
            forProductID: key.productID,
            connectedProductIDs: TabletManager.shared.connectedProductIDs)
        {
            return openWindow(forInstanceKey: resolveKey(forProductID: ownerPID))
        }
        if let existing = window(for: key) {
            NSApp.activate(ignoringOtherApps: true)
            existing.show()
            return existing
        }
        let wc = makeWindow(instanceKey: key, tabIndex: 0, frame: nil)
        NSApp.activate(ignoringOtherApps: true)
        wc.show()
        saveWindowState()
        return wc
    }

    /// Model-PID entry point for callers with no instance in hand
    /// ("Detect Tablet", device-picker callbacks).
    @discardableResult
    func openWindow(forProductID productID: Int) -> SettingsWindowController {
        openWindow(forInstanceKey: resolveKey(forProductID: productID))
    }

    @discardableResult
    func openNewWindow() -> SettingsWindowController {
        let wc = makeWindow(instanceKey: activeDeviceKey(), tabIndex: 0, frame: nil)
        NSApp.activate(ignoringOtherApps: true)
        wc.show()
        saveWindowState()
        return wc
    }

    func replaceWindow(_ old: SettingsWindowController, withDeviceID pid: Int) {
        let frame = old.window?.frame
        let tabIndex = old.selectedTabIndex
        let wasDefault = defaultWindow === old

        old.window?.close()

        let wc = makeWindow(instanceKey: resolveKey(forProductID: pid), tabIndex: tabIndex, frame: frame)
        if wasDefault { defaultWindow = wc }
        wc.showTab(at: tabIndex)
        saveWindowState()
    }

    // MARK: - Persistence

    func saveWindowState() {
        guard !skipWindowSave else { return }

        // Assign a stable integer ID to each tab group so windows can be
        // reunited into the same group on restore.
        var tabGroupMap: [ObjectIdentifier: Int] = [:]
        var nextGroupID = 0

        let entries = windows.compactMap { wc -> [String: Any]? in
            guard let win = wc.window, let frame = win.frame as NSRect? else { return nil }
            var entry: [String: Any] = [
                "tabIndex": wc.selectedTabIndex,
                "x": frame.origin.x,
                "y": frame.origin.y,
                "w": frame.size.width,
                "h": frame.size.height,
            ]
            if let key = wc.instanceKey { entry["deviceID"] = key.stringValue }
            if let tg = win.tabGroup {
                let key = ObjectIdentifier(tg)
                if tabGroupMap[key] == nil {
                    tabGroupMap[key] = nextGroupID
                    nextGroupID += 1
                }
                entry["tabGroupID"] = tabGroupMap[key]!
                entry["tabGroupSelected"] = tg.selectedWindow === win
            }
            return entry
        }
        UserDefaults.standard.set(entries, forKey: Self.restorationKey)
    }

    private func restoreWindows() {
        guard
            let entries = UserDefaults.standard.array(forKey: Self.restorationKey)
                as? [[String: Any]],
            !entries.isEmpty
        else { return }

        var created: [(wc: SettingsWindowController, entry: [String: Any])] = []
        // Saved identity: composite "deviceID" string (current format), with
        // pre-instance saves falling back to the bare "productID" Int (read
        // as the legacy empty-instance identity). Either way the PID folds
        // to canonical — entries saved before a transport merge may carry a
        // retired PID (Quick Keys dongle).
        func savedKey(_ entry: [String: Any]) -> DeviceInstanceKey? {
            let raw: DeviceInstanceKey?
            if let s = entry["deviceID"] as? String {
                raw = DeviceInstanceKey(stringValue: s)
            } else {
                raw = (entry["productID"] as? Int).map {
                    DeviceInstanceKey(productID: $0, instance: "")
                }
            }
            return raw.map {
                DeviceInstanceKey(
                    productID: VendorDeviceRegistry.canonicalProductID(for: $0.productID),
                    instance: $0.instance)
            }
        }
        // A companion's own window shouldn't be restored alongside its
        // owning tablet's — mirrors the live-connect suppression below.
        // Resolved against the saved set itself since actual connection
        // state isn't known yet at launch.
        let savedProductIDs = entries.compactMap { savedKey($0)?.productID }
        // Restore at most one window per physical unit (claim-normalized, so
        // a pre-merge or pre-instance save holding two faces of what is now
        // one identity restores a single window).
        var restoredKeys = Set<DeviceInstanceKey>()

        for (index, entry) in entries.enumerated() {
            let instanceKey = savedKey(entry)
            let tabIndex  = entry["tabIndex"]  as? Int ?? 0
            if let key = instanceKey {
                let normalized = DeviceRegistry.shared.normalizedKey(key)
                if restoredKeys.contains(normalized) { continue }
                if VendorDeviceRegistry.isConnectedCompanion(
                    productID: key.productID, connectedProductIDs: savedProductIDs)
                {
                    continue
                }
                restoredKeys.insert(normalized)
            }
            let frame: NSRect? = {
                guard let x = entry["x"] as? CGFloat,
                      let y = entry["y"] as? CGFloat,
                      let w = entry["w"] as? CGFloat,
                      let h = entry["h"] as? CGFloat
                else { return nil }
                return NSRect(x: x, y: y, width: w, height: h)
            }()

            let wc = makeWindow(instanceKey: instanceKey, tabIndex: tabIndex, frame: frame)
            if index == 0 { defaultWindow = wc }
            wc.show()
            wc.showTab(at: tabIndex)
            created.append((wc, entry))
        }

        // Reconstruct tab groups. Collect windows by saved tabGroupID, preserving
        // the order they were saved in (which matches the original tab order).
        var groups: [Int: [(wc: SettingsWindowController, selected: Bool)]] = [:]
        for (wc, entry) in created {
            guard let gid = entry["tabGroupID"] as? Int else { continue }
            let selected = entry["tabGroupSelected"] as? Bool ?? false
            groups[gid, default: []].append((wc, selected))
        }

        for (_, members) in groups.sorted(by: { $0.key < $1.key }) {
            guard members.count > 1, let first = members.first?.wc else { continue }
            for member in members.dropFirst() {
                if let win = member.wc.window {
                    first.window?.addTabbedWindow(win, ordered: .above)
                }
            }
            // Restore which tab was selected when the user quit.
            if let selectedWC = members.first(where: { $0.selected })?.wc {
                selectedWC.window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: - Window list (for menu bar / dock menus)

    struct WindowDescriptor: Identifiable {
        let id: String  // instance-key string, or "generic" for the generic window
        let label: String
    }

    private func publishWindowDescriptors() {
        windowDescriptors = windows.map { wc in
            WindowDescriptor(
                id: wc.instanceKey?.stringValue ?? "generic",
                label: displayLabel(forKey: wc.instanceKey))
        }
    }

    /// Bring an open window to front by its descriptor ID
    /// ("generic" = the no-device window).
    func focusWindow(id: String) {
        if id == "generic" {
            ensureDefaultWindow().show()
        } else if let key = DeviceInstanceKey(stringValue: id), let wc = window(for: key) {
            NSApp.activate(ignoringOtherApps: true)
            wc.show()
        }
    }

    // MARK: - Labels

    private func row(forKey key: DeviceInstanceKey) -> DeviceRegistry.KnownTablet? {
        let registry = DeviceRegistry.shared
        let normalized = registry.normalizedKey(key)
        return registry.knownTablets.first(
            where: { registry.normalizedKey($0.instanceKey) == normalized })
            ?? registry.knownTablets.first(where: { $0.productID == key.productID })
    }

    func displayLabel(forKey key: DeviceInstanceKey?) -> String {
        guard let key else { return "MockTab" }
        if let tablet = row(forKey: key) {
            if tablet.nickname != tablet.modelName { return tablet.nickname }
            return tablet.modelName
        }
        return TabletManager.deviceName(forProductID: key.productID)
    }

    func menuLabel(forKey key: DeviceInstanceKey) -> String {
        if let tablet = row(forKey: key) {
            if tablet.nickname != tablet.modelName {
                return "\(tablet.nickname) — \(tablet.modelName)"
            }
            return tablet.modelName
        }
        return TabletManager.deviceName(forProductID: key.productID)
    }

    // MARK: - Private

    private func activeDeviceKey() -> DeviceInstanceKey? {
        let tm = TabletManager.shared
        let connected = tm.connectedProductIDs
        // Never hand out a claimed companion (puck/dongle whose owning
        // tablet is connected) — its UI lives in the owner's window.
        return tm.activeContext?.instanceKey
            ?? tm.deviceContexts.values.first(where: {
                $0.isConnected
                    && !VendorDeviceRegistry.isConnectedCompanion(
                        productID: $0.productID, connectedProductIDs: connected)
            })?.instanceKey
            ?? connected.first.map { resolveKey(forProductID: $0) }
            ?? DeviceRegistry.shared.knownTablets.first?.instanceKey
    }

    /// Whether the key settings window offers the given tab, or nil when no
    /// settings window is key. Menu validation only — unlike
    /// `frontmostSettingsWindow()`, this must not create a window.
    func keyWindowHasTab(_ tab: SettingsWindowController.Tab) -> Bool? {
        windows.first(where: { $0.window?.isKeyWindow == true })?.hasTab(tab)
    }

    private func frontmostSettingsWindow() -> SettingsWindowController {
        windows.first(where: { $0.window?.isKeyWindow == true }) ?? ensureDefaultWindow()
    }

    private func ensureDefaultWindow() -> SettingsWindowController {
        if let dw = defaultWindow, windows.contains(where: { $0 === dw }) {
            return dw
        }
        let key = activeDeviceKey()
        let wc = makeWindow(instanceKey: key, tabIndex: 0, frame: nil)
        // SettingsWindowController.init already sets this autosave name when
        // no device is bound; only needed here for the bound case, where
        // this "default" window is standing in for a specific device.
        if key != nil {
            wc.window?.setFrameAutosaveName("PreferencesWindow")
        }
        defaultWindow = wc
        return wc
    }

    @discardableResult
    private func makeWindow(
        instanceKey: DeviceInstanceKey?,
        tabIndex: Int,
        frame: NSRect?
    ) -> SettingsWindowController {
        let (s, label) = settingsAndLabel(forKey: instanceKey)
        let wc = SettingsWindowController(
            settings: s, deviceLabel: label, instanceKey: instanceKey)

        if let frame {
            // Explicit frame passed (from restore or replace operations).
            // Mark as user-resized so tab switches don't override the saved size
            // with per-tab preset defaults.
            wc.window?.setFrame(frame, display: false)
            wc.window?.clampToMinSize()
            wc.suppressAutoResize()
        } else {
            // Place new window: cascade from the previous window if one exists,
            // otherwise land in the upper-left area of the primary display.
            // If we have a last-known size for this device, restore it so the
            // window comes back at the same size the user last had.
            if let lastSize = lastKnownSizes[sizeKey(instanceKey)] {
                wc.window?.setContentSize(lastSize)
                wc.window?.clampToMinSize()
            }
            // Whether or not we had a last-known size, don't let a later
            // showTab(at:) snap the window to that tab's per-tab default —
            // that's the old System-Preferences-style resize-per-tab
            // behavior, and it can fire on restore whenever saved frame
            // data is missing/incomplete even though this isn't really a
            // brand-new window.
            wc.suppressAutoResize()

            let screen = NSScreen.main ?? NSScreen.screens.first
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let windowSize = wc.window?.frame.size ?? NSSize(width: 560, height: 870)

            let origin: NSPoint
            if let lastFrame = windows.last?.window?.frame {
                // Cascade: step right and down from the previous window
                var candidate = NSPoint(x: lastFrame.minX + 20, y: lastFrame.minY - 20)
                // Wrap horizontally if the window would clip the right edge
                if candidate.x + windowSize.width > visible.maxX {
                    candidate.x = visible.minX + 40
                }
                // Wrap vertically if the window would fall below the bottom edge
                if candidate.y < visible.minY {
                    candidate.y = visible.maxY - windowSize.height - 40
                }
                origin = candidate
            } else {
                // First window: upper-left area of the primary display, with a
                // small inset so it clears the menu bar comfortably.
                origin = NSPoint(
                    x: visible.minX + 40,
                    y: visible.maxY - windowSize.height - 40
                )
            }
            wc.window?.setFrameOrigin(origin)
        }

        windows.append(wc)
        observeClose(wc)
        return wc
    }

    private func settingsAndLabel(forKey key: DeviceInstanceKey?) -> (TabletSettings, String) {
        if let key {
            let tm = TabletManager.shared
            // Pre-create the DeviceContext if the device hasn't connected yet
            // so the window and driver share the same TabletSettings instance.
            // deviceConnected() adopts a pre-existing context for the same
            // instance (or, for an empty-instance stub, re-keys it on the
            // model's first connect), ensuring writes from the UI are
            // immediately visible to the driver.
            let existing = tm.deviceContexts[key]
                ?? tm.deviceContexts.values.first(where: {
                    sameDevice($0.instanceKey, key)
                })
            if let existing {
                return (existing.settings, displayLabel(forKey: key))
            }
            // Use the last-known vendor for this product (persisted from a
            // prior live connect) so the stub doesn't default to Wacom for
            // a non-Wacom device — TabletManager.deviceConnected() reuses
            // whatever context already occupies this key, so a wrong
            // vendorID here would stick (it's a `let`) for the rest of
            // this launch, breaking vendor-specific spec lookups.
            let vendorID = DeviceRegistry.shared.vendorID(forProductID: key.productID) ?? 0x056A
            let stub = DeviceContext(instanceKey: key, vendorID: vendorID)
            tm.registerRestoredContext(stub)
            return (stub.settings, displayLabel(forKey: key))
        }
        return (settings, "MockTab")
    }

    private func observeClose(_ wc: SettingsWindowController) {
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: wc.window,
            queue: .main
        ) { [weak self, weak wc] _ in
            MainActor.assumeIsolated {
                // One-shot: a window closes once; drop the observer so its
                // block doesn't stay registered for the process lifetime.
                if let token { NotificationCenter.default.removeObserver(token) }
                guard let self, let wc else { return }
                // Capture size before removing so re-opening restores it.
                if let size = wc.window?.frame.size {
                    self.lastKnownSizes[self.sizeKey(wc.instanceKey)] = size
                }
                self.windows.removeAll(where: { $0 === wc })
                if self.defaultWindow === wc { self.defaultWindow = nil }
                // Skip saving during termination — AppKit closes all windows
                // as part of shutdown, which would zero out the saved list
                // before willTerminateNotification fires.
                guard !self.isTerminating else { return }
                self.saveWindowState()
            }
        }
    }
}
