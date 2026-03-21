import SwiftUI
import AppKit

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
            // View menu with ⌘1–⌘7 tab shortcuts.
            // Declared here so SwiftUI owns the menu lifecycle and it is never
            // overwritten by SwiftUI's own menu-rebuild passes.
            CommandMenu("View") {
                Button("Tablet Area")  { PreferencesWindowController.shared.showTab(at: 0) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Pressure")     { PreferencesWindowController.shared.showTab(at: 1) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Buttons")      { PreferencesWindowController.shared.showTab(at: 2) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Display")      { PreferencesWindowController.shared.showTab(at: 3) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Devices")      { PreferencesWindowController.shared.showTab(at: 4) }
                    .keyboardShortcut("5", modifiers: .command)
                Button("Presets")      { PreferencesWindowController.shared.showTab(at: 5) }
                    .keyboardShortcut("6", modifiers: .command)
                Button("Scratchpad")   { PreferencesWindowController.shared.showTab(at: 6) }
                    .keyboardShortcut("7", modifiers: .command)
                Button("Info")         { PreferencesWindowController.shared.showTab(at: 7) }
                    .keyboardShortcut("8", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AXIsProcessTrusted() {
            let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
            AXIsProcessTrustedWithOptions(opts)
        }

        Task { @MainActor in
            // Each tablet now creates its own InputInjector and TabletSettings
            // inside a DeviceContext.  The PreferencesWindowController's settings
            // instance is used for the UI and menu bar until per-device windows
            // are implemented.
            let settings = PreferencesWindowController.shared.settings
            AppWatcher.shared.settings = settings
            AppMenuController.shared.setup(settings: settings)
            TabletManager.shared.start()
        }

        // Show preferences window on first launch.
        DispatchQueue.main.async {
            PreferencesWindowController.shared.show()
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
