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
import SwiftUI

@main
struct MockTabApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("MockTab", image: "MenuBarIcon") {
            MenuBarView()
                .environmentObject(TabletManager.shared)
                .environmentObject(PreferencesWindowController.shared.settings)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            // View menu with ⌘1–⌘8 tab shortcuts.
            // Declared here so SwiftUI owns the menu lifecycle and it is never
            // overwritten by SwiftUI's own menu-rebuild passes.
            CommandMenu(String(localized: "View", comment: "Menu header: view/navigate tabs")) {
                Button(String(localized: "Tablet Area", comment: "Menu item: open Tablet Area tab")) { PreferencesWindowController.shared.showTab(at: 0) }
                    .keyboardShortcut("1", modifiers: .command)
                Button(String(localized: "Pressure", comment: "Menu item: open Pen Feel tab")) { PreferencesWindowController.shared.showTab(at: 1) }
                    .keyboardShortcut("2", modifiers: .command)
                Button(String(localized: "Buttons", comment: "Menu item: open Button Mapping tab")) { PreferencesWindowController.shared.showTab(at: 2) }
                    .keyboardShortcut("3", modifiers: .command)
                Button(String(localized: "Display", comment: "Menu item: open Display Mapping tab")) { PreferencesWindowController.shared.showTab(at: 3) }
                    .keyboardShortcut("4", modifiers: .command)
                Button(String(localized: "Devices", comment: "Menu item: open Devices tab")) { PreferencesWindowController.shared.showTab(at: 4) }
                    .keyboardShortcut("5", modifiers: .command)
                Button(String(localized: "Profiles", comment: "Menu item: open Profiles tab")) { PreferencesWindowController.shared.showTab(at: 5) }
                    .keyboardShortcut("6", modifiers: .command)
                Button(String(localized: "Scratchpad", comment: "Menu item: open Scratchpad tab")) { PreferencesWindowController.shared.showTab(at: 6) }
                    .keyboardShortcut("7", modifiers: .command)
                Button(String(localized: "Info", comment: "Menu item: open Info tab")) { PreferencesWindowController.shared.showTab(at: 7) }
                    .keyboardShortcut("8", modifiers: .command)

                Divider()

                Button(String(localized: "Show Tab Bar", comment: "View menu: toggle the window tab bar")) {
                    NSApp.sendAction(#selector(NSWindow.toggleTabBar(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Default to .regular (visible in Dock) on first run; user can toggle to .accessory
        let showInDock = UserDefaults.standard.object(forKey: "showInDock") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "showInDock")
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)

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
}
