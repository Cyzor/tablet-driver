// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

@main
struct MockTabApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(TabletManager.shared)
                .environmentObject(PreferencesWindowController.shared.settings)
                .environmentObject(PreferencesWindowController.shared)
        } label: {
            MenuBarIconLabel(manager: TabletManager.shared)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            // View menu with ⌘1–⌘8 tab shortcuts.
            // Declared here so SwiftUI owns the menu lifecycle and it is never
            // overwritten by SwiftUI's own menu-rebuild passes.
            CommandMenu(String(localized: "View", comment: "Menu header: view/navigate tabs")) {
                Button { PreferencesWindowController.shared.showTab(at: 0) } label: { Label(String(localized: "Tablet Area", comment: "Menu item: open Tablet Area tab"), systemImage: "rectangle.dashed") }
                    .keyboardShortcut("1", modifiers: .command)
                Button { PreferencesWindowController.shared.showTab(at: 1) } label: { Label(String(localized: "Pen Feel", comment: "Menu item: open Pen Feel tab"), systemImage: "scribble.variable") }
                    .keyboardShortcut("2", modifiers: .command)
                Button { PreferencesWindowController.shared.showTab(at: 2) } label: { Label(String(localized: "Buttons", comment: "Menu item: open Button Mapping tab"), systemImage: "square.grid.2x2.fill") }
                    .keyboardShortcut("3", modifiers: .command)
                Button { PreferencesWindowController.shared.showTab(at: 3) } label: { Label(String(localized: "Display", comment: "Menu item: open Display Mapping tab"), systemImage: "display") }
                    .keyboardShortcut("4", modifiers: .command)
                Button { PreferencesWindowController.shared.showTab(at: 4) } label: { Label(String(localized: "Devices", comment: "Menu item: open Devices tab"), systemImage: "rectangle.on.rectangle") }
                    .keyboardShortcut("5", modifiers: .command)
                Button { PreferencesWindowController.shared.showTab(at: 5) } label: { Label(String(localized: "Profiles", comment: "Menu item: open Profiles tab"), systemImage: "star.circle") }
                    .keyboardShortcut("6", modifiers: .command)
                Button { PreferencesWindowController.shared.showTab(at: 6) } label: { Label(String(localized: "Scratchpad", comment: "Menu item: open Scratchpad tab"), systemImage: "pencil.and.outline") }
                    .keyboardShortcut("7", modifiers: .command)
                Button { PreferencesWindowController.shared.showTab(at: 7) } label: { Label(String(localized: "Info", comment: "Menu item: open Info tab"), systemImage: "info.circle") }
                    .keyboardShortcut("8", modifiers: .command)

                // The Show/Hide Tab Bar item is appended natively by
                // AppMenuController.hookTabBarItem() so AppKit validation can
                // grey it out and retitle it like Finder.
            }

            CommandGroup(replacing: .help) {
                Button(String(localized: "MockTab Help", comment: "Help menu: open help window")) {
                    HelpWindowController.shared.show()
                }
                .keyboardShortcut("?", modifiers: .command)

                Button(String(localized: "MockTab Website\u{2026}", comment: "Help menu: open MockTab website")) {
                    NSWorkspace.shared.open(URL(string: "https://mocktab.org")!)
                }
            }

            // Edit menu: replaced wholesale with native selector-based items by
            // AppMenuController.hookEditMenu() so the responder chain enables and
            // disables Undo/Redo/Cut/Copy/Paste/Select All like Finder does.
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Prevent AppKit from inserting a "Quit and Keep Windows" item at ⌘⌥Q.
        // MockTab manages its own window restoration, so the system item is
        // redundant and conflicts with the Factory Reset alternate menu item.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

        // Set the activation policy here — before SwiftUI configures its
        // MenuBarExtra scene — so the app registers with the Dock as a regular
        // app from the start.  If we defer this to applicationDidFinishLaunching
        // (after scene setup), the Dock sees the app launch as an accessory and
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

        Task { @MainActor in
            let settings = PreferencesWindowController.shared.settings
            AppMenuController.shared.setup(settings: settings)
            TabletManager.shared.start()
            AppWatcher.shared.start()
        }

        // Only open a fresh window on first launch — subsequent launches
        // restore their windows via PreferencesWindowController.restoreWindows().
        DispatchQueue.main.async {
            PreferencesWindowController.shared.showIfNoSavedSession()
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
        for ctx in TabletManager.shared.contexts.values {
            ctx.injector.releaseOnAppSwitch()
        }
        HelpWindowController.shared.saveState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            PreferencesWindowController.shared.show()
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
            let pwc = PreferencesWindowController.shared
            let tm = TabletManager.shared
            for tablet in knownTablets {
                let connected = connectedIDs.contains(tablet.id)
                let suffix = connected ? (tm.contexts[tablet.id]?.batteryMenuSuffix ?? "") : ""
                let item = NSMenuItem(
                    title: pwc.menuLabel(forProductID: tablet.id) + suffix,
                    action: #selector(dockOpenTablet(_:)),
                    keyEquivalent: "")
                item.target = self
                item.tag = tablet.id
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
        PreferencesWindowController.shared.showTab(at: 0)
    }

    @objc private func dockShowButtonMapping() {
        PreferencesWindowController.shared.showTab(at: 2)
    }

    @objc private func dockDetectTablet() {
        AppMenuController.activateBestDevice()
    }

    @objc private func dockOpenTablet(_ sender: NSMenuItem) {
        PreferencesWindowController.shared.openWindow(forProductID: sender.tag)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuBarIconLabel: View {
    @ObservedObject var manager: TabletManager

    var body: some View {
        if let pct = manager.activeContext?.batteryPercent, pct < 20,
           manager.activeContext?.batteryCharging != true {
            Image(systemName: BatteryIndicator.symbolName(pct: pct, charging: false))
        } else {
            Image("MenuBarIcon")
                .renderingMode(.template)
        }
    }
}
