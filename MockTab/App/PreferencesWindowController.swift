// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026  This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab.  If not, see <https://www.gnu.org/licenses/>.

import AppKit
import Combine
import SwiftUI

@MainActor
final class PreferencesWindowController {

    static let shared = PreferencesWindowController()

    let settings = TabletSettings()

    private var windows: [SettingsWindowController] = []
    private var defaultWindow: SettingsWindowController?
    private var deviceObserver: AnyCancellable?
    private var isTerminating = false

    private static let restorationKey = "MockTab_OpenWindows"

    private init() {
        deviceObserver = TabletManager.shared.$connectedProductIDs
            .dropFirst()
            .first(where: { !$0.isEmpty })
            .receive(on: RunLoop.main)
            .sink { [weak self] ids in
                guard let self,
                    let dw = self.defaultWindow,
                    dw.productID == nil,
                    let pid = ids.first
                else { return }
                self.replaceWindow(dw, withDeviceID: pid)
            }

        restoreWindows()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Set flag first — prevents the window close cascade that
            // AppKit triggers during termination from wiping the saved list.
            self?.isTerminating = true
            self?.saveWindowState()
        }
    }

    // MARK: - Default window API

    func show() {
        ensureDefaultWindow().show()
    }

    func showIfNoSavedSession() {
        guard windows.isEmpty else { return }
        ensureDefaultWindow().show()
    }

    func showTab(at index: Int) {
        ensureDefaultWindow().showTab(at: index)
    }

    func showTab(named name: String) {
        ensureDefaultWindow().showTab(named: name)
    }

    // MARK: - Multi-window

    @discardableResult
    func openWindow(forProductID productID: Int) -> SettingsWindowController {
        if let existing = windows.first(where: { $0.productID == productID }) {
            existing.show()
            return existing
        }
        let wc = makeWindow(productID: productID, tabIndex: 0, frame: nil)
        wc.show()
        saveWindowState()
        return wc
    }

    @discardableResult
    func openNewWindow() -> SettingsWindowController {
        let pid = activeDeviceProductID()
        let wc = makeWindow(productID: pid, tabIndex: 0, frame: nil)
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
        let entries = windows.compactMap { wc -> [String: Any]? in
            guard let frame = wc.window?.frame else { return nil }
            var entry: [String: Any] = [
                "tabIndex": wc.selectedTabIndex,
                "x": frame.origin.x,
                "y": frame.origin.y,
                "w": frame.size.width,
                "h": frame.size.height,
            ]
            if let pid = wc.productID { entry["productID"] = pid }
            return entry
        }
        //        print("MockTab saveWindowState: \(entries.count) windows → \(entries)")
        UserDefaults.standard.set(entries, forKey: Self.restorationKey)
    }

    private func restoreWindows() {
        guard
            let entries = UserDefaults.standard.array(forKey: Self.restorationKey)
                as? [[String: Any]],
            !entries.isEmpty
        else {
            //            print("MockTab restoreWindows: no saved state found")
            return
        }
        //        print("MockTab restoreWindows: found \(entries.count) entries → \(entries)")

        for (index, entry) in entries.enumerated() {
            let productID = entry["productID"] as? Int
            let tabIndex = entry["tabIndex"] as? Int ?? 0

            let frame: NSRect? = {
                guard let x = entry["x"] as? CGFloat,
                    let y = entry["y"] as? CGFloat,
                    let w = entry["w"] as? CGFloat,
                    let h = entry["h"] as? CGFloat
                else { return nil }
                return NSRect(x: x, y: y, width: w, height: h)
            }()

            let wc = makeWindow(productID: productID, tabIndex: tabIndex, frame: nil)
            if index == 0 { defaultWindow = wc }

            wc.showTab(at: tabIndex)
            if let frame { wc.window?.setFrame(frame, display: true) }
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
        TabletManager.shared.activeContext?.productID
            ?? TabletManager.shared.connectedProductIDs.first
            ?? DeviceRegistry.shared.knownTablets.first?.id
    }

    private func ensureDefaultWindow() -> SettingsWindowController {
        if let dw = defaultWindow, windows.contains(where: { $0 === dw }) {
            return dw
        }
        let pid = activeDeviceProductID()
        let wc = makeWindow(productID: pid, tabIndex: 0, frame: nil)
        wc.window?.setFrameAutosaveName("PreferencesWindow")
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
            wc.window?.setFrame(frame, display: false)
        } else if let lastFrame = windows.last?.window?.frame {
            wc.window?.setFrameOrigin(
                NSPoint(
                    x: lastFrame.minX + 20,
                    y: lastFrame.minY - 20))
        }

        windows.append(wc)
        observeClose(wc)
        return wc
    }

    private func settingsAndLabel(forProductID productID: Int?) -> (TabletSettings, String) {
        if let pid = productID {
            let tm = TabletManager.shared
            let s = tm.contexts[pid]?.settings ?? TabletSettings(productID: pid)
            return (s, displayLabel(forProductID: pid))
        }
        return (settings, "MockTab")
    }

    private func observeClose(_ wc: SettingsWindowController) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: wc.window,
            queue: .main
        ) { [weak self, weak wc] _ in
            guard let self, let wc else { return }
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
