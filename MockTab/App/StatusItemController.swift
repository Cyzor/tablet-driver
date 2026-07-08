// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import ServiceManagement
import TabletKit

/// Owns the menu-bar status item, replacing the SwiftUI `MenuBarExtra`. The
/// menu is rebuilt in full on every open (`menuNeedsUpdate`) rather than kept
/// in sync via notifications — menus are only visible while open, so a
/// rebuild-on-open is trivially fresh with no persistent observation wiring.
/// The one exception is the status-bar icon itself, which must reflect
/// battery state even while the menu is closed, so it's kept live via Combine.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    static let shared = StatusItemController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var contextCancellables = Set<AnyCancellable>()
    private var activeContextCancellable: AnyCancellable?

    func start() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon(pct: nil, charging: false)
        observeBattery()
    }

    // MARK: - Icon

    private func observeBattery() {
        TabletManager.shared.$activeContext
            .sink { [weak self] context in self?.subscribe(to: context) }
            .store(in: &contextCancellables)
    }

    private func subscribe(to context: DeviceContext?) {
        guard let context else {
            activeContextCancellable = nil
            updateIcon(pct: nil, charging: false)
            return
        }
        activeContextCancellable = Publishers.CombineLatest(context.$batteryPercent, context.$batteryCharging)
            .sink { [weak self] pct, charging in self?.updateIcon(pct: pct, charging: charging) }
    }

    private func updateIcon(pct: Int?, charging: Bool) {
        guard let button = statusItem.button else { return }
        if let pct, pct < 20, !charging {
            button.image = NSImage(systemSymbolName: BatteryIndicator.symbolName(pct: pct, charging: false),
                                    accessibilityDescription: nil)
        } else {
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true
            button.image = image
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let pwc = SettingsWindowManager.shared
        let tm = TabletManager.shared
        let settings = pwc.settings

        addItem(to: menu, title: String(localized: "Tablet Area", comment: "Menu item: open Tablet Area tab"),
                action: #selector(showTabletArea))
        addItem(to: menu, title: String(localized: "Button Mapping", comment: "Menu item: open Button Mapping tab"),
                action: #selector(showButtonMapping))
        menu.addItem(.separator())
        addItem(to: menu, title: String(localized: "Detect Tablet", comment: "Menu item: detect and focus active tablet"),
                action: #selector(detectTablet))

        let knownTablets = DeviceRegistry.shared.knownTablets
        if !knownTablets.isEmpty {
            menu.addItem(.separator())
            for tablet in knownTablets {
                // A companion peripheral (Xencelabs Quick Keys puck/dongle)
                // is folded into its owning tablet's window while connected —
                // don't list it as its own selectable device.
                if VendorDeviceRegistry.isConnectedCompanion(
                    productID: tablet.id, connectedProductIDs: tm.connectedProductIDs)
                {
                    continue
                }
                let connected = tm.connectedProductIDs.contains(tablet.id)
                let suffix = connected ? (tm.contexts[tablet.id]?.batteryMenuSuffix ?? "") : ""
                let item = NSMenuItem(title: pwc.menuLabel(forProductID: tablet.id) + suffix,
                                       action: #selector(openTablet(_:)), keyEquivalent: "")
                item.target = self
                item.tag = tablet.id
                item.state = connected ? .on : .off
                menu.addItem(item)
            }
        }

        if pwc.windowDescriptors.count > 1 {
            menu.addItem(.separator())
            for descriptor in pwc.windowDescriptors {
                let item = NSMenuItem(title: descriptor.label, action: #selector(focusWindow(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = descriptor.id
                menu.addItem(item)
            }
        }

        if !settings.profiles.isEmpty {
            menu.addItem(.separator())
            let profileItem = NSMenuItem(title: profileMenuTitle(settings: settings), action: nil, keyEquivalent: "")
            profileItem.submenu = buildProfileSubmenu(settings: settings)
            menu.addItem(profileItem)
        }

        menu.addItem(.separator())

        let loginItem = NSMenuItem(
            title: String(localized: "Launch at Login", comment: "Menu toggle: start app automatically on login"),
            action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let showInDock = UserDefaults.standard.object(forKey: "showInDock") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "showInDock")
        let dockItem = NSMenuItem(
            title: String(localized: "Show in Dock", comment: "Menu toggle: show app icon in dock"),
            action: #selector(toggleShowInDock), keyEquivalent: "")
        dockItem.target = self
        dockItem.state = showInDock ? .on : .off
        menu.addItem(dockItem)

        menu.addItem(.separator())

        addItem(to: menu, title: String(localized: "Quit MockTab", comment: "Menu button: quit the application"),
                action: #selector(quit))
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func profileMenuTitle(settings: TabletSettings) -> String {
        switch settings.activationSource {
        case .manual:
            return String(
                localized: "Profile: \(settings.activeProfile?.name ?? "Device Defaults")",
                comment: "Menu label showing current active profile")
        case .app(_, let appName):
            return String(
                localized: "Profile: \(settings.activeProfile?.name ?? "Device Defaults")  (\(appName))",
                comment: "Menu label showing current active profile and triggering app")
        }
    }

    private func buildProfileSubmenu(settings: TabletSettings) -> NSMenu {
        let sub = NSMenu()

        let defaultsItem = NSMenuItem(
            title: String(localized: "Device Defaults", comment: "Profile option: use device's default settings"),
            action: #selector(activateDeviceDefaults), keyEquivalent: "")
        defaultsItem.target = self
        defaultsItem.state = settings.activeProfile == nil ? .on : .off
        sub.addItem(defaultsItem)
        sub.addItem(.separator())

        for profile in settings.profiles {
            let item = NSMenuItem(title: profile.name, action: #selector(activateProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            item.state = settings.activeProfile?.id == profile.id ? .on : .off
            sub.addItem(item)
        }

        return sub
    }

    // MARK: - Actions

    @objc private func showTabletArea() {
        SettingsWindowManager.shared.showTab(at: 0)
    }

    @objc private func showButtonMapping() {
        SettingsWindowManager.shared.showTab(at: 2)
    }

    @objc private func detectTablet() {
        AppMenuController.activateBestDevice()
    }

    @objc private func openTablet(_ sender: NSMenuItem) {
        SettingsWindowManager.shared.openWindow(forProductID: sender.tag)
    }

    @objc private func focusWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int else { return }
        SettingsWindowManager.shared.focusWindow(id: id)
    }

    @objc private func activateDeviceDefaults() {
        SettingsWindowManager.shared.settings.activate(nil)
    }

    @objc private func activateProfile(_ sender: NSMenuItem) {
        let settings = SettingsWindowManager.shared.settings
        guard let uuid = sender.representedObject as? UUID,
              let profile = settings.profiles.first(where: { $0.id == uuid })
        else { return }
        settings.activate(profile)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Leave the toggle reflecting the actual (unchanged) status; it's
            // re-read fresh from SMAppService on the next menu open.
        }
    }

    @objc private func toggleShowInDock() {
        let current = UserDefaults.standard.object(forKey: "showInDock") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "showInDock")
        let show = !current
        UserDefaults.standard.set(show, forKey: "showInDock")
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
