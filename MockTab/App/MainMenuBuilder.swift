// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Builds `NSApp.mainMenu` from scratch. There is no storyboard/nib in this
/// app, so unlike a SwiftUI `App`, AppKit gives us nothing for free — every
/// standard item (About, Services, Hide, Quit, Help) has to be added here.
///
/// The Edit and Window menus are left as empty placeholders: `AppMenuController`
/// replaces their contents wholesale (`hookEditMenu`, `hookWindowMenu`) so
/// responder-chain validation greys items out Finder-style. Tablet and
/// Profiles menus are inserted by `AppMenuController` as well.
@MainActor
enum MainMenuBuilder {

    static let editMenuTitle = String(localized: "Edit", comment: "Menu header: edit actions")
    static let viewMenuTitle = String(localized: "View", comment: "Menu header: view/navigate tabs")
    static let windowMenuTitle = String(localized: "Window", comment: "Menu header: window management")

    static func build() -> NSMenu {
        let mainMenu = NSMenu()

        mainMenu.addItem(buildAppMenuItem())
        mainMenu.addItem(buildEditMenuItem())
        mainMenu.addItem(buildViewMenuItem())
        mainMenu.addItem(buildWindowMenuItem())
        mainMenu.addItem(buildHelpMenuItem())

        return mainMenu
    }

    private static func buildAppMenuItem() -> NSMenuItem {
        let appName = "MockTab"
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: String(localized: "About \(appName)", comment: "App menu: show About panel"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")

        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: String(localized: "Services", comment: "App menu: Services submenu"),
                                       action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)

        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: String(localized: "Hide \(appName)", comment: "App menu: hide the app"),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")

        let hideOthers = NSMenuItem(title: String(localized: "Hide Others", comment: "App menu: hide other apps"),
                                     action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)

        appMenu.addItem(withTitle: String(localized: "Show All", comment: "App menu: show all apps"),
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")

        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: String(localized: "Quit \(appName)", comment: "App menu: quit the app"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        return appMenuItem
    }

    private static func buildEditMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: editMenuTitle, action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: editMenuTitle)
        return item
    }

    private static func buildViewMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: viewMenuTitle, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: viewMenuTitle)

        let tabs: [(title: String, image: String, key: String)] = [
            (String(localized: "Tablet Area", comment: "Menu item: open Tablet Area tab"), "rectangle.dashed", "1"),
            (String(localized: "Pen Feel", comment: "Menu item: open Pen Feel tab"), "scribble.variable", "2"),
            (String(localized: "Buttons", comment: "Menu item: open Button Mapping tab"), "square.grid.2x2.fill", "3"),
            (String(localized: "Display", comment: "Menu item: open Display Mapping tab"), "display", "4"),
            (String(localized: "Devices", comment: "Menu item: open Devices tab"), "rectangle.on.rectangle", "5"),
            (String(localized: "Profiles", comment: "Menu item: open Profiles tab"), "star.circle", "6"),
            (String(localized: "Scratchpad", comment: "Menu item: open Scratchpad tab"), "pencil.and.outline", "7"),
            (String(localized: "Info", comment: "Menu item: open Info tab"), "info.circle", "8"),
        ]
        for (index, tab) in tabs.enumerated() {
            let menuItem = NSMenuItem(title: tab.title, action: #selector(AppMenuController.showTabFromMainMenu(_:)), keyEquivalent: tab.key)
            menuItem.keyEquivalentModifierMask = .command
            menuItem.tag = index
            menuItem.target = AppMenuController.shared
            menuItem.image = NSImage(systemSymbolName: tab.image, accessibilityDescription: nil)
            menu.addItem(menuItem)
        }

        // Show/Hide Tab Bar and the Text Size submenu are appended natively by
        // AppMenuController (hookTabBarItem, insertTextSizeSubmenu).

        item.submenu = menu
        return item
    }

    private static func buildWindowMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: windowMenuTitle, action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: windowMenuTitle)
        return item
    }

    private static func buildHelpMenuItem() -> NSMenuItem {
        let helpTitle = String(localized: "Help", comment: "Menu header: app help")
        let item = NSMenuItem(title: helpTitle, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: helpTitle)

        let helpItem = NSMenuItem(
            title: String(localized: "MockTab Help", comment: "Help menu: open help window"),
            action: #selector(AppMenuController.showHelpFromMainMenu),
            keyEquivalent: "?")
        helpItem.keyEquivalentModifierMask = .command
        helpItem.target = AppMenuController.shared
        menu.addItem(helpItem)

        let websiteItem = NSMenuItem(
            title: String(localized: "MockTab Website\u{2026}", comment: "Help menu: open MockTab website"),
            action: #selector(AppMenuController.showWebsiteFromMainMenu),
            keyEquivalent: "")
        websiteItem.target = AppMenuController.shared
        menu.addItem(websiteItem)

        item.submenu = menu
        NSApp.helpMenu = menu
        return item
    }
}
