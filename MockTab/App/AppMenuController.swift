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
/// **Profiles menu** — inserted after the Tablet menu.  Rebuilt on every open.
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
            hookAppMenu()
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

    // MARK: - Factory Reset (Option-key hidden item)

    private func hookAppMenu() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu else { return }

        // Find the Quit item. Factory Reset is inserted immediately after it as
        // an isAlternate — the same mechanism Finder uses for "Secure Empty Trash".
        // AppKit's NSMenuView handles the live Option-key toggle natively.
        // Setting self as the menu's delegate is required to trigger the alternate
        // recognition; without it, the item is inserted but never shown.
        guard let quitItem = menu.items.last(where: {
            $0.action == #selector(NSApplication.terminate(_:))
        }) else { return }
        let quitIndex = menu.items.firstIndex(of: quitItem)!

        let item = NSMenuItem(
            title: "Factory Reset\u{2026}",
            action: #selector(confirmFactoryReset),
            keyEquivalent: quitItem.keyEquivalent)
        item.keyEquivalentModifierMask = quitItem.keyEquivalentModifierMask.union(.option)
        item.isAlternate = true
        item.target = self
        menu.insertItem(item, at: quitIndex + 1)
        menu.delegate = self
    }

    @objc private func confirmFactoryReset() {
        let alert = NSAlert()
        alert.messageText = "Reset MockTab to Factory Settings?"
        alert.informativeText =
            "All tablets, tools, presets, and button mappings will be erased. " +
            "MockTab will restart."
        alert.alertStyle = .warning
        let resetButton = alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        // Return key = default button (highlighted, activates on Return).
        resetButton.keyEquivalent = "\r"

        // Monitor for Command-R while dialog is open.
        var eventMonitor: Any?
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Command-R (keyCode 15 = 'R')
            if event.keyCode == 15 && event.modifierFlags.contains(.command) {
                // Defer the reset to allow the dialog to close first
                DispatchQueue.main.async { self?.performFactoryReset() }
                if let monitor = eventMonitor {
                    NSEvent.removeMonitor(monitor)
                }
                return nil  // consume the event
            }
            return event  // pass through all other keys
        }

        let resultCode = alert.runModal()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }

        guard resultCode == .alertFirstButtonReturn else { return }
        performFactoryReset()
    }

    private func performFactoryReset() {
        // Tell PreferencesWindowController not to save when willTerminate fires.
        // This prevents the window state from being re-populated after we clear it.
        PreferencesWindowController.shared.skipNextWindowSave()

        // Wipe the entire UserDefaults domain in one call.  This removes every
        // key ever written: device settings, presets, tool settings, registry,
        // and window state.
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.synchronize()
        }

        // Also clear NSWindow autosave caches for window frames.  These are stored
        // independently in system preferences (com.apple.NSWindow.State) and would
        // otherwise restore stale window geometry on the next launch.
        NSWindow.removeFrame(usingName: NSWindow.FrameAutosaveName("MockTabSettingsWindow"))
        NSWindow.removeFrame(usingName: NSWindow.FrameAutosaveName("PreferencesWindow"))

        // Relaunch so the new instance reads factory defaults rather than the
        // stale in-memory @Published / @AppStorage state from this session.
        let url = Bundle.main.bundleURL
        NSWorkspace.shared.open(url)
        NSApp.terminate(nil)
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
            title: "Duplicate Window",
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
                // Show a checkmark for currently connected tablets.
                if tm.connectedProductIDs.contains(tablet.id) {
                    item.image = NSImage(
                        systemSymbolName: "checkmark.circle.fill",
                        accessibilityDescription: "Connected")
                    item.image?.size = NSSize(width: 12, height: 12)
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

    // MARK: - **Profiles menu

    private var presetsMenu: NSMenu?

    private func insertPresetsMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        guard mainMenu.items.allSatisfy({ $0.title != "Profiles" }) else { return }

        let menu = NSMenu(title: "Profiles")
        menu.delegate = self
        presetsMenu = menu

        let menuItem = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
        menuItem.submenu = menu

        // Insert after Edit menu (which SwiftUI generates).
        if let editIndex = mainMenu.items.firstIndex(where: { $0.title == "Edit" }) {
            mainMenu.insertItem(menuItem, at: editIndex + 1)
        }
    }

    /// Rebuild the **Profiles menu every time it is about to open.
    private func rebuildPresetsMenu(_ menu: NSMenu) {
        guard let settings else { return }
        menu.removeAllItems()

        if !settings.profiles.isEmpty {
            let defsItem = NSMenuItem(
                title: "Device Defaults",
                action: #selector(activateDeviceDefaults),
                keyEquivalent: "")
            defsItem.target = self
            defsItem.state = settings.activeProfile == nil ? .on : .off
            menu.addItem(defsItem)
            menu.addItem(.separator())

            for profile in settings.profiles {
                let item = NSMenuItem(
                    title: profile.name,
                    action: #selector(activatePreset(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = profile.id
                item.state = settings.activeProfile?.id == profile.id ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let showItem = NSMenuItem(
            title: "Show Saved Configurations…",
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
            let profile = settings?.profiles.first(where: { $0.id == uuid })
        else { return }
        settings?.activate(profile)
    }

    @objc private func showPresetsTab() {
        PreferencesWindowController.shared.showTab(named: "Profiles")
    }

}
