import AppKit

/// Builds and maintains two application-menu contributions:
///
/// **Presets menu** — inserted after the Edit menu.  Rebuilt on every open
/// via `NSMenuDelegate.menuNeedsUpdate(_:)` so it always reflects the
/// current device's presets and active selection.
///
/// **View menu** — populated with one item per preferences tab (⌘1–⌘7),
/// creating the menu if SwiftUI hasn't generated one.
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
