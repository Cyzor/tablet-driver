// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Prevent AppKit from inserting a "Quit and Keep Windows" item at ⌘⌥Q.
        // MockTab manages its own window restoration, so the system item is
        // redundant and conflicts with the Factory Reset alternate menu item.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

        // Set the activation policy here — before applicationDidFinishLaunching —
        // so the app registers with the Dock as a regular app from the start.
        // If we defer this, the Dock sees the app launch as an accessory and
        // never establishes the applicationDockMenu callback, even though the
        // icon appears.
        let showInDock = UserDefaults.standard.object(forKey: "showInDock") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "showInDock")
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {

        // The Accessibility prompt is deferred to the first tablet connection
        // (TabletManager.promptForAccessibilityIfNeeded) so the request appears
        // when injection is actually about to happen, not cold at launch.

        NSApp.mainMenu = MainMenuBuilder.build()
        StatusItemController.shared.start()

        let settings = SettingsWindowManager.shared.settings
        AppMenuController.shared.setup(settings: settings)
        TabletManager.shared.start()
        AppWatcher.shared.start()

        // Only open a fresh window on first launch — subsequent launches
        // restore their windows via SettingsWindowManager.restoreWindows().
        DispatchQueue.main.async {
            SettingsWindowManager.shared.showIfNoSavedSession()
            HelpWindowController.shared.restoreIfWasOpen()
        }

        // Track app focus to gate live state updates.  When MockTab is backgrounded,
        // stop publishing livePoint/liveButtons to save CPU and battery.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.willResignActiveNotification,
            object: nil)

    }

    @objc
    private func appDidBecomeActive() {
        TabletManager.shared.appIsFrontmost = true
    }

    @objc
    private func appDidResignActive() {
        TabletManager.shared.appIsFrontmost = false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Release any held synthetic modifiers before exit. Prevents Shift/Cmd/Opt/Ctrl
        // appearing stuck system-wide after a force-quit or crash-then-relaunch cycle.
        for ctx in TabletManager.shared.deviceContexts.values {
            ctx.injector.releaseOnAppSwitch()
        }
        HelpWindowController.shared.saveState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            SettingsWindowManager.shared.show()
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let tabletArea = NSMenuItem(
            title: String(localized: "Tablet Area", comment: "Dock menu: open Tablet Area tab"),
            action: #selector(dockShowTabletArea),
            keyEquivalent: "")
        tabletArea.target = self
        menu.addItem(tabletArea)

        let buttons = NSMenuItem(
            title: String(localized: "Button Mapping", comment: "Dock menu: open Button Mapping tab"),
            action: #selector(dockShowButtonMapping),
            keyEquivalent: "")
        buttons.target = self
        menu.addItem(buttons)

        menu.addItem(.separator())

        let detect = NSMenuItem(
            title: String(localized: "Detect Tablet", comment: "Dock menu: detect and focus active tablet"),
            action: #selector(dockDetectTablet),
            keyEquivalent: "")
        detect.target = self
        menu.addItem(detect)

        // List known tablets, matching the Tablet menu in the main menu bar.
        // A filled checkmark icon marks currently connected devices.
        let knownTablets = DeviceRegistry.shared.knownTablets
        if !knownTablets.isEmpty {
            menu.addItem(.separator())
            let connectedIDs = TabletManager.shared.connectedProductIDs
            let pwc = SettingsWindowManager.shared
            let tm = TabletManager.shared
            for tablet in knownTablets {
                let connected = connectedIDs.contains(tablet.productID)
                let suffix = connected ? (tm.context(for: tablet)?.batteryMenuSuffix ?? "") : ""
                let item = NSMenuItem(
                    title: pwc.menuLabel(forKey: tablet.instanceKey) + suffix,
                    action: #selector(dockOpenTablet(_:)),
                    keyEquivalent: "")
                item.target = self
                // Composite instance identity doesn't fit NSMenuItem.tag
                // (an Int) — carry it via representedObject instead.
                item.representedObject = tablet.instanceKey.stringValue
                // Dock menus reliably honor NSMenuItem.state (left-gutter
                // checkmark) but not all NSMenuItem.image values render in the
                // Dock's restricted menu pipeline, so use the canonical
                // selected-state indicator here rather than a custom image.
                if connected {
                    item.state = .on
                }
                menu.addItem(item)
            }
        }

        return menu
    }

    @objc private func dockShowTabletArea() {
        SettingsWindowManager.shared.showTab(at: 0)
    }

    @objc private func dockShowButtonMapping() {
        SettingsWindowManager.shared.showTab(at: 2)
    }

    @objc private func dockDetectTablet() {
        AppMenuController.activateBestDevice()
    }

    @objc private func dockOpenTablet(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
            let key = DeviceInstanceKey(stringValue: id)
        else { return }
        SettingsWindowManager.shared.openWindow(forInstanceKey: key)
        NSApp.activate(ignoringOtherApps: true)
    }
}
