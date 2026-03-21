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
            let injector = InputInjector()
            TabletManager.shared.injector = injector
            let settings = PreferencesWindowController.shared.settings
            // Wire settings before start() so the driver uses persisted preferences immediately.
            TabletManager.shared.settings = settings
            // Wire app-watcher for preset auto-switching.
            AppWatcher.shared.settings = settings
            // Build Presets and View application menus.
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
