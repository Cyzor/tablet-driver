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
            buildViewMenu()
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

    // MARK: - View menu  (⌘1–⌘7 for each preferences tab)

    private func buildViewMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

        // Find or create the View menu.
        let viewMenu: NSMenu
        if let existing = mainMenu.items.first(where: { $0.title == "View" })?.submenu {
            existing.removeAllItems()
            viewMenu = existing
        } else {
            let vm = NSMenu(title: "View")
            let vmItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
            vmItem.submenu = vm
            // Insert before Window, or at end.
            let idx = mainMenu.items.firstIndex(where: { $0.title == "Window" })
                      ?? mainMenu.items.count
            mainMenu.insertItem(vmItem, at: idx)
            viewMenu = vm
        }

        for (index, label) in PreferencesWindowController.tabLabels.enumerated() {
            let key  = String(index + 1)           // "1" through "7"
            let item = NSMenuItem(title: label,
                                  action: #selector(showTabByTag(_:)),
                                  keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            item.target = self
            item.tag    = index
            viewMenu.addItem(item)
        }
    }

    @objc private func showTabByTag(_ sender: NSMenuItem) {
        PreferencesWindowController.shared.showTab(at: sender.tag)
    }
}
