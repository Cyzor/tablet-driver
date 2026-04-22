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
            hookWindowMenu()
            watchMainMenuForRebuild()
        }
    }

    // MARK: - Window menu

    private var windowMenu: NSMenu?

    private func hookWindowMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let windowTitle = String(localized: "Window", comment: "Menu header: window management")

        // Remove any existing Window menu items (including SwiftUI's auto-generated stub,
        // which often has a nil submenu and can't be used as windowsMenu).
        for item in mainMenu.items where item.title == windowTitle {
            mainMenu.removeItem(item)
        }

        let menu = NSMenu(title: windowTitle)
        menu.delegate = self
        windowMenu = menu

        let menuItem = NSMenuItem(title: windowTitle, action: nil, keyEquivalent: "")
        menuItem.submenu = menu

        // Insert after the View menu.
        let viewTitle = String(localized: "View", comment: "Menu header: view/navigate tabs")
        if let idx = mainMenu.items.firstIndex(where: { $0.title == viewTitle }) {
            mainMenu.insertItem(menuItem, at: idx + 1)
        } else {
            mainMenu.addItem(menuItem)
        }
    }

    private func rebuildWindowMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // Standard system entries — target:nil routes through the first-responder chain
        // so each item acts on whichever window is currently key.
        func addItem(_ title: String, action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = nil
            menu.addItem(item)
        }

        addItem(String(localized: "Minimize",       comment: "Window menu"), action: #selector(NSWindow.performMiniaturize(_:)), key: "m")
        addItem(String(localized: "Zoom",           comment: "Window menu"), action: #selector(NSWindow.performZoom(_:)),        key: "", modifiers: [])
        addItem(String(localized: "Full Screen",    comment: "Window menu"), action: #selector(NSWindow.toggleFullScreen(_:)),   key: "f", modifiers: [.control, .command])
        menu.addItem(.separator())
        addItem(String(localized: "Bring All to Front", comment: "Window menu"), action: #selector(NSApplication.arrangeInFront(_:)), key: "", modifiers: [])

        // Open app windows — filter SwiftUI internals (title "Item-0") and titleless utility windows.
        let appWindows = NSApp.windows.filter {
            !$0.isExcludedFromWindowsMenu
                && !$0.title.isEmpty
                && $0.title != "Item-0"
                && ($0.isVisible || $0.isMiniaturized)
        }
        if !appWindows.isEmpty {
            menu.addItem(.separator())
            for win in appWindows {
                let item = NSMenuItem(title: win.title, action: #selector(focusWindow(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = win
                item.state = win.isKeyWindow ? .on : .off
                menu.addItem(item)
            }
        }
    }

    @objc private func focusWindow(_ sender: NSMenuItem) {
        guard let win = sender.representedObject as? NSWindow else { return }
        if win.isMiniaturized { win.deminiaturize(nil) }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Rebuild guard

    // SwiftUI can rebuild NSApp.mainMenu any time a scene re-evaluates (e.g.,
    // when TabletManager publishes during startup), silently removing menus that
    // were inserted via AppKit.  Observing didRemoveItemNotification lets us
    // re-insert them immediately after SwiftUI's rebuild pass settles.

    private var rebuildScheduled = false

    private func watchMainMenuForRebuild() {
        guard let mainMenu = NSApp.mainMenu else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainMenuDidRemoveItem),
            name: NSMenu.didRemoveItemNotification,
            object: mainMenu)
    }

    @objc private func mainMenuDidRemoveItem() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [self] in
            rebuildScheduled = false
            insertTabletMenu()
            insertPresetsMenu()
            removeEmptyViewMenu()
            hookWindowMenu()
        }
    }

    // MARK: - Duplicate View menu removal

    /// SwiftUI generates a default empty "View" menu; our `CommandMenu("View")`
    /// creates a second one.  Walk the main menu and drop whichever "View" entry
    /// has no items — that is always the SwiftUI-generated stub.
    private func removeEmptyViewMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let viewTitle = String(localized: "View", comment: "Menu header: view/navigate tabs")
        for item in mainMenu.items where item.title == viewTitle {
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
            let aboutItem = appMenu.items.first(where: {
                $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:))
            })
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
        guard
            let quitItem = menu.items.last(where: {
                $0.action == #selector(NSApplication.terminate(_:))
            })
        else { return }
        let quitIndex = menu.items.firstIndex(of: quitItem)!

        let item = NSMenuItem(
            title: String(
                localized: "Factory Reset\u{2026}",
                comment: "Menu item: factory reset (Option-key hidden)"),
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
        alert.messageText = String(
            localized: "Reset MockTab to Factory Settings?",
            comment: "Alert title: factory reset confirmation")
        alert.informativeText = String(
            localized:
                "All tablets, tools, presets, and button mappings will be erased. MockTab will restart.",
            comment: "Alert body: explaining the consequences of factory reset")
        alert.alertStyle = .warning
        let resetButton = alert.addButton(
            withTitle: String(localized: "Reset", comment: "Button label: confirm factory reset"))
        alert.addButton(
            withTitle: String(localized: "Cancel", comment: "Button label: cancel factory reset"))
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
        // "Tablet" is not currently in Localizable.xcstrings, but we'll use localized
        // string lookup anyway to be future-proof.
        let tabletTitle = String(
            localized: "Tablet", comment: "Menu header: tablet-specific actions")
        guard mainMenu.items.allSatisfy({ $0.title != tabletTitle }) else { return }

        let menu = NSMenu(title: tabletTitle)
        menu.delegate = self
        tabletMenu = menu

        let menuItem = NSMenuItem(title: tabletTitle, action: nil, keyEquivalent: "")
        menuItem.submenu = menu

        // Insert immediately after the application menu (index 0).
        mainMenu.insertItem(menuItem, at: 1)
    }

    private func rebuildTabletMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // "New Settings Window" — opens a generic window.
        let newItem = NSMenuItem(
            title: String(
                localized: "Duplicate Window", comment: "Menu item: open a new settings window"),
            action: #selector(newSettingsWindow),
            keyEquivalent: "n")
        newItem.keyEquivalentModifierMask = [.command, .shift]
        newItem.target = self
        menu.addItem(newItem)

        // "Detect Tablet" — re-evaluates the active device and focuses its window.
        let detectItem = NSMenuItem(
            title: String(
                localized: "Detect Tablet", comment: "Menu item: find and focus the active tablet"),
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
                        accessibilityDescription: String(
                            localized: "Connected",
                            comment: "Accessibility label for connected tablet indicator"))
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
        let profilesTitle = String(
            localized: "Profiles", comment: "Menu header: profile management")
        guard mainMenu.items.allSatisfy({ $0.title != profilesTitle }) else { return }

        let menu = NSMenu(title: profilesTitle)
        menu.delegate = self
        presetsMenu = menu

        let menuItem = NSMenuItem(title: profilesTitle, action: nil, keyEquivalent: "")
        menuItem.submenu = menu

        // Insert after Edit menu. Finding by "undo:" action is localization-robust.
        let editIndex = mainMenu.items.firstIndex { item in
            item.submenu?.items.contains { $0.action == Selector(("undo:")) } ?? false
        }
        if let editIndex {
            mainMenu.insertItem(menuItem, at: editIndex + 1)
        } else {
            // Fallback: insert after app menu and tablet menu.
            mainMenu.insertItem(menuItem, at: 2)
        }
    }

    /// Rebuild the **Profiles menu every time it is about to open.
    private func rebuildPresetsMenu(_ menu: NSMenu) {
        guard let settings else { return }
        menu.removeAllItems()

        if !settings.profiles.isEmpty {
            let defsItem = NSMenuItem(
                title: String(
                    localized: "Device Defaults",
                    comment: "Profile option: use device's default settings"),
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
            title: String(
                localized: "Show Saved Configurations…", comment: "Menu item: open the Profiles tab"
            ),
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
        } else if menu === windowMenu {
            rebuildWindowMenu(menu)
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
