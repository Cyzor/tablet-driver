import AppKit

/// Builds and maintains the application-menu contributions that cannot be
/// expressed purely through SwiftUI's command system:
///
/// **Presets menu** — inserted after the Edit menu.  Rebuilt on every open
/// via `NSMenuDelegate.menuNeedsUpdate(_:)` so it always reflects the
/// current device's presets and active selection.
///
/// **Duplicate View menu removal** — SwiftUI generates an empty "View" menu
/// for every app; `CommandMenu("View")` in MockTabApp adds a second one with
/// our items.  The empty duplicate is removed here once SwiftUI has finished
/// its initial menu-building pass.
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
            insertPresetsMenu()
            removeEmptyViewMenu()
        }
    }

    // MARK: - Duplicate View menu removal

    /// SwiftUI generates a default empty "View" menu; our `CommandMenu("View")`
    /// creates a second one.  Walk the main menu and drop whichever "View" entry
    /// has no items — that is always the SwiftUI-generated stub.
    private func removeEmptyViewMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in mainMenu.items where item.title == "View" {
            if item.submenu?.items.isEmpty ?? true {
                mainMenu.removeItem(item)
                return   // only one stub expected
            }
        }
    }

    // MARK: - Presets menu

    private var presetsMenu: NSMenu?

    private func insertPresetsMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        guard mainMenu.items.allSatisfy({ $0.title != "Presets" }) else { return }

        let menu = NSMenu(title: "Presets")
        menu.delegate = self
        presetsMenu = menu

        let menuItem = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        menuItem.submenu = menu

        // Insert after Edit; fall back to index 1 (after the app menu).
        let insertAfter = mainMenu.items.firstIndex(where: { $0.title == "Edit" }) ?? 1
        mainMenu.insertItem(menuItem, at: insertAfter + 1)
    }

    /// Rebuild the Presets menu every time it is about to open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === presetsMenu, let settings else { return }
        menu.removeAllItems()

        if !settings.presets.isEmpty {
            // Device defaults (always present when presets exist).
            let defsItem = NSMenuItem(title: "Device Defaults",
                                      action: #selector(activateDeviceDefaults),
                                      keyEquivalent: "")
            defsItem.target = self
            defsItem.state  = settings.activePreset == nil ? .on : .off
            menu.addItem(defsItem)
            menu.addItem(.separator())

            for preset in settings.presets {
                let item = NSMenuItem(title: preset.name,
                                      action: #selector(activatePreset(_:)),
                                      keyEquivalent: "")
                item.target            = self
                item.representedObject = preset.id
                item.state             = settings.activePreset?.id == preset.id ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let showItem = NSMenuItem(title: "Show Presets",
                                  action: #selector(showPresetsTab),
                                  keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
    }

    @objc private func activateDeviceDefaults() {
        settings?.activate(nil)
    }

    @objc private func activatePreset(_ sender: NSMenuItem) {
        guard let uuid   = sender.representedObject as? UUID,
              let preset = settings?.presets.first(where: { $0.id == uuid })
        else { return }
        settings?.activate(preset)
    }

    @objc private func showPresetsTab() {
        PreferencesWindowController.shared.showTab(named: "Presets")
    }

}
