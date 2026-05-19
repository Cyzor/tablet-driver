// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

@main
struct MockTabApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("MockTab", image: "MenuBarIcon") {
            MenuBarView()
                .environmentObject(TabletManager.shared)
                .environmentObject(PreferencesWindowController.shared.settings)
                .environmentObject(PreferencesWindowController.shared)
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

                Divider()

                Button(String(localized: "Show Tab Bar", comment: "View menu: toggle the window tab bar")) {
                    NSApp.sendAction(#selector(NSWindow.toggleTabBar(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
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

            CommandGroup(replacing: .undoRedo) {
                Button(String(localized: "Undo", comment: "Edit menu: undo last action")) {
                    PreferencesWindowController.shared.getUndoManager()?.undo()
                }
                .keyboardShortcut("z", modifiers: .command)

                Button(String(localized: "Redo", comment: "Edit menu: redo last undone action")) {
                    PreferencesWindowController.shared.getUndoManager()?.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])

                Divider()

                Button(String(localized: "Cut", comment: "Edit menu: cut selection")) {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("x", modifiers: .command)
                Button(String(localized: "Copy", comment: "Edit menu: copy selection")) {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("c", modifiers: .command)
                Button(String(localized: "Paste", comment: "Edit menu: paste from clipboard")) {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v", modifiers: .command)
                Button(String(localized: "Select All", comment: "Edit menu: select all text")) {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("a", modifiers: .command)
            }

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

        // Claim the delegate slot before SwiftUI's @NSApplicationDelegateAdaptor shim
        // has a chance to install itself.  The Dock queries applicationDockMenu at
        // process registration; if the shim is in place at that moment it responds nil
        // and the Dock caches "no custom menu" for the lifetime of the process.
        // Assigning here — the earliest delegate point in the AppKit lifecycle —
        // ensures our real AppDelegate is the one the Dock sees.
        // Note: this fix only matters for a Finder/conventional launch.  Xcode debug
        // launches go through a different process-registration path and the Dock
        // menu may not appear there regardless; that's an Xcode artifact, not a bug.
        NSApp.delegate = self

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

        if !AXIsProcessTrusted() {
            let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
            AXIsProcessTrustedWithOptions(opts)
        }

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
}
