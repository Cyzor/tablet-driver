// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import SwiftUI
import TabletKit

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

    /// Last-known window size per logical window, keyed by productID (as string)
    /// or "generic". Captured when a window closes so re-opening it restores the
    /// size the user last had, even though the closed window is no longer in
    /// `windows` and therefore absent from `saveWindowState()`.
    private var lastKnownSizes: [String: NSSize] = [:]

    private func sizeKey(productID: Int?) -> String {
        productID.map(String.init) ?? "generic"
    }

    private static let restorationKey = "MockTab_OpenWindows"

    private init() {
        deviceObserver = TabletManager.shared.$connectedProductIDs
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] ids in
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
                   dw.productID == nil,
                   let pid = ids.first(where: { id in
                       !self.windows.contains(where: { $0.productID == id })
                           && !VendorDeviceRegistry.isConnectedCompanion(
                               productID: id, connectedProductIDs: ids)
                   }) {
                    self.replaceWindow(dw, withDeviceID: pid)
                    return  // replaceWindow handled this pid; loop below skips it
                }
                // For every connected tablet with no open window, open one —
                // except a companion peripheral (e.g. the Xencelabs Quick
                // Keys puck/dongle) whose owning tablet is also connected;
                // that one is folded into the tablet's own Buttons pane
                // instead (see ButtonMappingView's companion section). This
                // re-evaluates on every change to `ids`, so a companion
                // whose owning tablet later disconnects gets its own window
                // on the very next publish (it's still in `ids`, still has
                // no window, and is no longer claimed).
                for pid in ids
                where !self.windows.contains(where: { $0.productID == pid })
                    && !VendorDeviceRegistry.isConnectedCompanion(
                        productID: pid, connectedProductIDs: ids)
                {
                    self.openWindow(forProductID: pid)
                }
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
    func openWindow(forProductID productID: Int) -> SettingsWindowController {
        // A companion peripheral (Xencelabs Quick Keys puck/dongle) never
        // gets a window of its own while its owning tablet is connected —
        // redirect to the owner instead. Covers every caller (menus, status
        // item, "Detect Tablet"), not just the auto-open sink.
        if let ownerPID = VendorDeviceRegistry.connectedCompanionOwner(
            forProductID: productID, connectedProductIDs: TabletManager.shared.connectedProductIDs)
        {
            return openWindow(forProductID: ownerPID)
        }
        if let existing = windows.first(where: { $0.productID == productID }) {
            NSApp.activate(ignoringOtherApps: true)
            existing.show()
            return existing
        }
        let wc = makeWindow(productID: productID, tabIndex: 0, frame: nil)
        NSApp.activate(ignoringOtherApps: true)
        wc.show()
        saveWindowState()
        return wc
    }

    @discardableResult
    func openNewWindow() -> SettingsWindowController {
        let pid = activeDeviceProductID()
        let wc = makeWindow(productID: pid, tabIndex: 0, frame: nil)
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

        let wc = makeWindow(productID: pid, tabIndex: tabIndex, frame: frame)
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
            if let pid = wc.productID { entry["productID"] = pid }
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
        // A companion's own window shouldn't be restored alongside its
        // owning tablet's — mirrors the live-connect suppression below.
        // Resolved against the saved set itself since actual connection
        // state isn't known yet at launch.
        // Entries saved before a transport merge may carry a retired PID
        // (Quick Keys dongle) — fold to canonical before restoring, and
        // restore at most one window per canonical device since a pre-merge
        // save can hold both faces of what is now one identity.
        let savedProductIDs = entries.compactMap {
            ($0["productID"] as? Int).map(VendorDeviceRegistry.canonicalProductID(for:))
        }
        var restoredPIDs = Set<Int>()

        for (index, entry) in entries.enumerated() {
            let productID = (entry["productID"] as? Int)
                .map(VendorDeviceRegistry.canonicalProductID(for:))
            let tabIndex  = entry["tabIndex"]  as? Int ?? 0
            if let pid = productID {
                if restoredPIDs.contains(pid) { continue }
                if VendorDeviceRegistry.isConnectedCompanion(
                    productID: pid, connectedProductIDs: savedProductIDs)
                {
                    continue
                }
                restoredPIDs.insert(pid)
            }
            let frame: NSRect? = {
                guard let x = entry["x"] as? CGFloat,
                      let y = entry["y"] as? CGFloat,
                      let w = entry["w"] as? CGFloat,
                      let h = entry["h"] as? CGFloat
                else { return nil }
                return NSRect(x: x, y: y, width: w, height: h)
            }()

            let wc = makeWindow(productID: productID, tabIndex: tabIndex, frame: frame)
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
        let id: Int  // productID, or -1 for the generic window
        let label: String
    }

    private func publishWindowDescriptors() {
        windowDescriptors = windows.map { wc in
            let pid = wc.productID
            return WindowDescriptor(id: pid ?? -1, label: displayLabel(forProductID: pid))
        }
    }

    /// Bring an open window to front by its productID (-1 = generic window).
    func focusWindow(id: Int) {
        if id == -1 {
            ensureDefaultWindow().show()
        } else if let wc = windows.first(where: { ($0.productID ?? -1) == id }) {
            NSApp.activate(ignoringOtherApps: true)
            wc.show()
        }
    }

    // MARK: - Labels

    func displayLabel(forProductID productID: Int?) -> String {
        guard let productID else { return "MockTab" }
        let registry = DeviceRegistry.shared
        if let tablet = registry.knownTablets.first(where: { $0.id == productID }) {
            if tablet.nickname != tablet.modelName { return tablet.nickname }
            return tablet.modelName
        }
        return TabletManager.deviceName(forProductID: productID)
    }

    func menuLabel(forProductID productID: Int) -> String {
        let registry = DeviceRegistry.shared
        if let tablet = registry.knownTablets.first(where: { $0.id == productID }) {
            if tablet.nickname != tablet.modelName {
                return "\(tablet.nickname) — \(tablet.modelName)"
            }
            return tablet.modelName
        }
        return TabletManager.deviceName(forProductID: productID)
    }

    // MARK: - Private

    private func activeDeviceProductID() -> Int? {
        let connected = TabletManager.shared.connectedProductIDs
        // Never hand out a claimed companion (puck/dongle whose owning
        // tablet is connected) — its UI lives in the owner's window.
        return TabletManager.shared.activeContext?.productID
            ?? connected.first(where: {
                !VendorDeviceRegistry.isConnectedCompanion(
                    productID: $0, connectedProductIDs: connected)
            })
            ?? connected.first
            ?? DeviceRegistry.shared.knownTablets.first?.id
    }

    private func frontmostSettingsWindow() -> SettingsWindowController {
        windows.first(where: { $0.window?.isKeyWindow == true }) ?? ensureDefaultWindow()
    }

    private func ensureDefaultWindow() -> SettingsWindowController {
        if let dw = defaultWindow, windows.contains(where: { $0 === dw }) {
            return dw
        }
        let pid = activeDeviceProductID()
        let wc = makeWindow(productID: pid, tabIndex: 0, frame: nil)
        // SettingsWindowController.init already sets this autosave name when
        // productID == nil; only needed here for the pid != nil case, where
        // this "default" window is standing in for a specific device.
        if pid != nil {
            wc.window?.setFrameAutosaveName("PreferencesWindow")
        }
        defaultWindow = wc
        return wc
    }

    @discardableResult
    private func makeWindow(
        productID: Int?,
        tabIndex: Int,
        frame: NSRect?
    ) -> SettingsWindowController {
        let (s, label) = settingsAndLabel(forProductID: productID)
        let wc = SettingsWindowController(
            settings: s, deviceLabel: label, productID: productID)

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
            if let lastSize = lastKnownSizes[sizeKey(productID: productID)] {
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

    private func settingsAndLabel(forProductID productID: Int?) -> (TabletSettings, String) {
        if let pid = productID {
            let tm = TabletManager.shared
            // Pre-create the DeviceContext if the device hasn't connected yet so the
            // window and driver share the same TabletSettings instance.  connectDevice()
            // adopts any pre-existing context via `contexts[pid] ?? DeviceContext(...)`,
            // ensuring writes from the UI are immediately visible to the driver.
            if tm.contexts[pid] == nil {
                // Use the last-known vendor for this product (persisted from a
                // prior live connect) so the stub doesn't default to Wacom for
                // a non-Wacom device — TabletManager.deviceConnected() reuses
                // whatever context already occupies this key, so a wrong
                // vendorID here would stick (it's a `let`) for the rest of
                // this launch, breaking vendor-specific spec lookups.
                let vendorID = DeviceRegistry.shared.vendorID(forProductID: pid) ?? 0x056A
                tm.contexts[pid] = DeviceContext(productID: pid, vendorID: vendorID)
            }
            return (tm.contexts[pid]!.settings, displayLabel(forProductID: pid))
        }
        return (settings, "MockTab")
    }

    private func observeClose(_ wc: SettingsWindowController) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: wc.window,
            queue: .main
        ) { [weak self, weak wc] _ in
            MainActor.assumeIsolated {
                guard let self, let wc else { return }
                // Capture size before removing so re-opening restores it.
                if let size = wc.window?.frame.size {
                    self.lastKnownSizes[self.sizeKey(productID: wc.productID)] = size
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
