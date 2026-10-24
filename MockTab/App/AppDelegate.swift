// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import TabletKit

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
        // First, before any setting is read, written, or migrated.
        if let domain = Bundle.main.bundleIdentifier {
            SettingsBackup.backUpOnBuildChange(build: Bundle.main.versionLabel, domain: domain)
        }

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

        // Install the menu before AppKit begins tracking so the system sees
        // the final structure from the start (avoids Menu_Tracking warnings
        // caused by replacing the menu mid-track in didFinishLaunching).
        NSApp.mainMenu = MainMenuBuilder.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {

        // The Accessibility prompt is deferred to the first tablet connection
        // (TabletManager.promptForAccessibilityIfNeeded) so the request appears
        // when injection is actually about to happen, not cold at launch.
        StatusItemController.shared.start()

        let settings = SettingsWindowManager.shared.settings
        AppMenuController.shared.setup(settings: settings)
        TabletManager.shared.start()
        AppWatcher.shared.start()
        // After the driver starts, so the pen works while windows build.
        DisplayInfo.prewarmThumbnails()
        InfoView.prewarmSystemQueries()
        SettingsWindowManager.shared.restoreWindows {
            HelpWindowController.shared.restoreIfWasOpen()
        }

        // Only open a fresh window on first launch — subsequent launches
        // restore their windows via SettingsWindowManager.restoreWindows().
        DispatchQueue.main.async {
            SettingsWindowManager.shared.showIfNoSavedSession()
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
        // Release every held button, key, and modifier, and tell apps the pen
        // left, before exit; Click Lock would otherwise leave the left button
        // down system-wide. The process ends when this returns, so wait for
        // HIDThread, which owns that state, briefly.
        let injectors = TabletManager.shared.deviceContexts.values.map(\.injector)
        let released = DispatchSemaphore(value: 0)
        HIDThread.shared.perform {
            for injector in injectors { injector.releaseHeldStateForQuit() }
            released.signal()
        }
        _ = released.wait(timeout: .now() + .milliseconds(250))
        // Hands touch sensors back in the mode macOS found them in.
        TabletManager.shared.stop()
        HelpWindowController.shared.saveState()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
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
            title: String(localized: "Buttons", comment: "Dock menu: open Buttons tab"),
            action: #selector(dockShowButtons),
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

        let tablets = TabletMenuItems.items(target: self, action: #selector(dockOpenTablet(_:)))
        if !tablets.isEmpty {
            menu.addItem(.separator())
            tablets.forEach(menu.addItem)
        }

        return menu
    }

    @objc private func dockShowTabletArea() {
        SettingsWindowManager.shared.showTab(.tabletArea)
    }

    @objc private func dockShowButtons() {
        SettingsWindowManager.shared.showTab(.buttons)
    }

    @objc private func dockDetectTablet() {
        AppMenuController.activateBestDevice()
    }

    @objc private func dockOpenTablet(_ sender: NSMenuItem) {
        guard let key = TabletMenuItems.instanceKey(of: sender) else { return }
        SettingsWindowManager.shared.openWindow(forInstanceKey: key)
        NSApp.activate(ignoringOtherApps: true)
    }
}
