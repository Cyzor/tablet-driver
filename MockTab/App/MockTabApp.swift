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
            CommandMenu("View") {
                Button("Tablet Area") { PreferencesWindowController.shared.showTab(at: 0) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Pressure") { PreferencesWindowController.shared.showTab(at: 1) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Buttons") { PreferencesWindowController.shared.showTab(at: 2) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Display") { PreferencesWindowController.shared.showTab(at: 3) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Devices") { PreferencesWindowController.shared.showTab(at: 4) }
                    .keyboardShortcut("5", modifiers: .command)
                Button("Presets") { PreferencesWindowController.shared.showTab(at: 5) }
                    .keyboardShortcut("6", modifiers: .command)
                Button("Scratchpad") { PreferencesWindowController.shared.showTab(at: 6) }
                    .keyboardShortcut("7", modifiers: .command)
                Button("Info") { PreferencesWindowController.shared.showTab(at: 7) }
                    .keyboardShortcut("8", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var shimProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AXIsProcessTrusted() {
            let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
            AXIsProcessTrustedWithOptions(opts)
        }

        Task { @MainActor in
            let settings = PreferencesWindowController.shared.settings
            AppWatcher.shared.settings = settings
            AppMenuController.shared.setup(settings: settings)
            TabletManager.shared.start()
        }

        // spawnShim() — disabled; Adobe pressure is fixed via capability mask 0x05C7, no Apple Events needed.

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

    func applicationWillTerminate(_ notification: Notification) {
        shimProcess?.terminate()
        shimProcess = nil
    }

    private func spawnShim() {
        // WacomShim.app is embedded at MockTab.app/Contents/Helpers/WacomShim.app
        // via the "Embed Helpers" CopyFiles build phase.
        let shimURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/WacomShim.app/Contents/MacOS/WacomShim")
        guard FileManager.default.isExecutableFile(atPath: shimURL.path) else {
            print("AppDelegate: WacomShim not found in bundle — Adobe pressure fix inactive")
            return
        }
        let proc = Process()
        proc.executableURL = shimURL
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.shimProcess = nil }
        }
        do {
            try proc.run()
            shimProcess = proc
            print("AppDelegate: WacomShim launched (pid \(proc.processIdentifier))")
        } catch {
            print("AppDelegate: failed to launch WacomShim — \(error)")
        }
    }

    @objc
    private func appDidBecomeActive() {
        TabletManager.shared.appIsFrontmost = true
    }

    @objc
    private func appDidResignActive() {
        TabletManager.shared.appIsFrontmost = false
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
