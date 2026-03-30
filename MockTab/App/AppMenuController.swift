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

/// Builds and maintains the application-menu contributions that cannot be
/// expressed purely through SwiftUI's command system:
///
/// **Tablet menu** — first menu after the application menu.  Contains
/// "New Settings Window" and a dynamic list of known tablets from
/// DeviceRegistry.  Rebuilt on every open via `menuNeedsUpdate(_:)`.
///
/// **Presets menu** — inserted after the Tablet menu.  Rebuilt on every open.
///
/// **Duplicate View menu removal** — SwiftUI generates an empty "View" menu;
/// we remove it here so only the one with ⌘1–⌘8 shortcuts remains.
@MainActor
final class AppMenuController: NSObject, NSMenuDelegate {

    static let shared = AppMenuController()

    private weak var settings: TabletSettings?

    // MARK: - Setup

    func setup(settings: TabletSettings) {
        self.settings = settings
        // Main menu is available by applicationDidFinishLaunching, but
        // defer one run-loop tick to let SwiftUI finish its menu scaffolding.
        DispatchQueue.main.async { [self] in
            insertTabletMenu()
            insertPresetsMenu()
            removeEmptyViewMenu()
            hookAboutMenuItem()
        }
    }

    // MARK: - Duplicate View menu removal

    /// SwiftUI generates a default empty "View" menu; our `CommandMenu("View")`
    /// creates a second one.  Walk the main menu and drop whichever "View" entry
    /// has no items — that is always the SwiftUI-generated stub.
    private func removeEmptyViewMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in mainMenu.items where item.title == "View" {
            if item.submenu?.items.isEmpty ?? true {
                mainMenu.removeItem(item)
                return  // only one stub expected
            }
        }
    }

    
    // MARK: - About

    private func hookAboutMenuItem() {
        guard
            let appMenu = NSApp.mainMenu?.items.first?.submenu,
            let aboutItem = appMenu.items.first(where: { $0.title.hasPrefix("About") })
        else { return }

        aboutItem.target = self
        aboutItem.action = #selector(showAboutWindow)
    }

    @objc private func showAboutWindow() {
        AboutWindowController.shared.show()
    }
    
    
    // MARK: - Tablet menu

    private var tabletMenu: NSMenu?

    private func insertTabletMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        guard mainMenu.items.allSatisfy({ $0.title != "Tablet" }) else { return }

        let menu = NSMenu(title: "Tablet")
        menu.delegate = self
        tabletMenu = menu

        let menuItem = NSMenuItem(title: "Tablet", action: nil, keyEquivalent: "")
        menuItem.submenu = menu

        // Insert immediately after the application menu (index 0).
        mainMenu.insertItem(menuItem, at: 1)
    }

    private func rebuildTabletMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // "New Settings Window" — opens a generic window.
        let newItem = NSMenuItem(
            title: "New Settings Window",
            action: #selector(newSettingsWindow),
            keyEquivalent: "n")
        newItem.keyEquivalentModifierMask = [.command, .shift]
        newItem.target = self
        menu.addItem(newItem)

        // "Detect Tablet" — re-evaluates the active device and focuses its window.
        let detectItem = NSMenuItem(
            title: "Detect Tablet",
            action: #selector(detectTablet),
            keyEquivalent: "r")
        detectItem.keyEquivalentModifierMask = [.command]
        detectItem.target = self
        menu.addItem(detectItem)

        // List known tablets from DeviceRegistry.
        let registry = DeviceRegistry.shared
        let tm = TabletManager.shared
        if !registry.knownTablets.isEmpty {
            menu.addItem(.separator())

            for tablet in registry.knownTablets {
                let label = PreferencesWindowController.shared.menuLabel(forProductID: tablet.id)
                let item = NSMenuItem(
                    title: label,
                    action: #selector(openDeviceWindow(_:)),
                    keyEquivalent: "")
                item.target = self
                item.tag = tablet.id
                // Show a dot for currently connected tablets.
                if tm.connectedProductIDs.contains(tablet.id) {
                    item.image = NSImage(
                        systemSymbolName: "circle.fill",
                        accessibilityDescription: "Connected")
                    item.image?.size = NSSize(width: 6, height: 6)
                }
                menu.addItem(item)
            }
        }
    }

    @objc private func newSettingsWindow() {
        PreferencesWindowController.shared.openNewWindow()
    }

    @objc private func openDeviceWindow(_ sender: NSMenuItem) {
        PreferencesWindowController.shared.openWindow(forProductID: sender.tag)
    }

    @objc private func detectTablet() {
        AppMenuController.activateBestDevice()
    }

    /// Picks the most relevant connected (or known) device and activates its
    /// settings window.  Called from both the menu item and TabletAreaView's
    /// "Detect Tablet" button.
    @MainActor
    static func activateBestDevice() {
        let tm = TabletManager.shared
        // Prefer the pen-in-proximity context; fall back to first connected,
        // then first ever-seen device.
        let pid =
            tm.activeContext?.productID
            ?? tm.connectedProductIDs.first
            ?? DeviceRegistry.shared.knownTablets.first?.id
        guard let pid else { return }
        PreferencesWindowController.shared.openWindow(forProductID: pid)
    }

    // MARK: - Presets menu

    private var presetsMenu: NSMenu?

    private func insertPresetsMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        guard mainMenu.items.allSatisfy({ $0.title != "Presets" }) else { return }

        let menu = NSMenu(title: "Presets")
        menu.delegate = self
        presetsMenu = menu

        let menuItem = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        menuItem.submenu = menu

        // Insert after Edit menu (which SwiftUI generates).
        if let editIndex = mainMenu.items.firstIndex(where: { $0.title == "Edit" }) {
            mainMenu.insertItem(menuItem, at: editIndex + 1)
        }
    }

    /// Rebuild the Presets menu every time it is about to open.
    private func rebuildPresetsMenu(_ menu: NSMenu) {
        guard let settings else { return }
        menu.removeAllItems()

        if !settings.presets.isEmpty {
            let defsItem = NSMenuItem(
                title: "Device Defaults",
                action: #selector(activateDeviceDefaults),
                keyEquivalent: "")
            defsItem.target = self
            defsItem.state = settings.activePreset == nil ? .on : .off
            menu.addItem(defsItem)
            menu.addItem(.separator())

            for preset in settings.presets {
                let item = NSMenuItem(
                    title: preset.name,
                    action: #selector(activatePreset(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = preset.id
                item.state = settings.activePreset?.id == preset.id ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let showItem = NSMenuItem(
            title: "Show Presets",
            action: #selector(showPresetsTab),
            keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === tabletMenu {
            rebuildTabletMenu(menu)
        } else if menu === presetsMenu {
            rebuildPresetsMenu(menu)
        }
    }

    // MARK: - Preset actions

    @objc private func activateDeviceDefaults() {
        settings?.activate(nil)
    }

    @objc private func activatePreset(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? UUID,
            let preset = settings?.presets.first(where: { $0.id == uuid })
        else { return }
        settings?.activate(preset)
    }

    @objc private func showPresetsTab() {
        PreferencesWindowController.shared.showTab(named: "Presets")
    }

}
