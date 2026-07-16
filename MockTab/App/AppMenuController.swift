// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import TabletKit
import UniformTypeIdentifiers

/// Standard responder-chain actions that have no public `#selector`-able
/// declaration in AppKit. NSWindow handles both by forwarding to the first
/// responder's `undoManager`, validating (and retitling) the menu items.
@objc private protocol UndoRedoResponding {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

extension Notification.Name {
    /// Posted by the Profiles menu "Import Configuration…" item after the user picks a file.
    /// `userInfo["data"]` contains the raw `Data` to import.
    static let mockTabImportData = Notification.Name("MockTab.importData")
}

/// Builds and maintains the application-menu contributions that cannot be
/// expressed purely through SwiftUI's command system:
///
/// **Tablet menu** — first menu after the application menu.  Contains
/// "New Settings Window" and a dynamic list of known tablets from
/// DeviceRegistry.  Rebuilt on every open via `menuNeedsUpdate(_:)`.
///
/// **Profiles menu** — inserted after the Tablet menu.  Rebuilt on every open.
///
/// **Edit menu** — SwiftUI's Button-based items are always enabled; replaced
/// with nil-target selector items so AppKit responder-chain validation grays
/// out inapplicable commands, Finder-style.  Same for Show/Hide Tab Bar in
/// the View menu.
///
/// **Duplicate View menu removal** — SwiftUI generates an empty "View" menu;
/// we remove it here so only the one with ⌘1–⌘8 shortcuts remains.
@MainActor
final class AppMenuController: NSObject, NSMenuDelegate {

    static let shared = AppMenuController()

    private weak var settings: TabletSettings?
    // MARK: - Setup

    func setup(settings: TabletSettings) {
        self.settings = settings

        insertTabletMenu()
        insertPresetsMenu()
        hookAboutMenuItem()
        hookAppMenu()
        hookEditMenu()
        hookViewMenu()
        insertTextSizeSubmenu()
        hookTabBarItem()
        hookWindowMenu()
    }

    // MARK: - View menu item actions (targets for MainMenuBuilder's ⌘1–⌘8 items)

    @objc func showTabFromMainMenu(_ sender: NSMenuItem) {
        SettingsWindowManager.shared.showTab(at: sender.tag)
    }

    @objc func showHelpFromMainMenu() {
        HelpWindowController.shared.show()
    }

    @objc func showWebsiteFromMainMenu() {
        NSWorkspace.shared.open(URL(string: "https://mocktab.org")!)
    }

    // MARK: - Edit menu

    private var editMenu: NSMenu?

    /// Replaces the SwiftUI-generated Edit menu's contents with native items
    /// that use nil-target standard selectors. AppKit's responder-chain
    /// validation then grays out whatever has no effect — clipboard items
    /// without a focused text field, Undo/Redo without recorded actions —
    /// and gives Undo/Redo their contextual titles from the key window's
    /// UndoManager (vended by SettingsWindowController via
    /// `windowWillReturnUndoManager`).
    private func hookEditMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        guard let editItem = mainMenu.items.first(where: { $0.title == MainMenuBuilder.editMenuTitle }) else { return }

        if editMenu == nil {
            let menu = NSMenu(title: editItem.title)
            func addItem(_ title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags = .command) {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
                item.keyEquivalentModifierMask = modifiers
                item.target = nil
                menu.addItem(item)
            }
            addItem(String(localized: "Undo", comment: "Edit menu: undo last action"),
                    action: #selector(UndoRedoResponding.undo(_:)), key: "z")
            addItem(String(localized: "Redo", comment: "Edit menu: redo last undone action"),
                    action: #selector(UndoRedoResponding.redo(_:)), key: "z", modifiers: [.command, .shift])
            menu.addItem(.separator())
            addItem(String(localized: "Cut", comment: "Edit menu: cut selection"),
                    action: #selector(NSText.cut(_:)), key: "x")
            addItem(String(localized: "Copy", comment: "Edit menu: copy selection"),
                    action: #selector(NSText.copy(_:)), key: "c")
            addItem(String(localized: "Paste", comment: "Edit menu: paste from clipboard"),
                    action: #selector(NSText.paste(_:)), key: "v")
            menu.addItem(.separator())
            addItem(String(localized: "Select All", comment: "Edit menu: select all text"),
                    action: #selector(NSText.selectAll(_:)), key: "a")
            editMenu = menu
        }

        if editItem.submenu !== editMenu {
            editItem.submenu = editMenu
        }
    }

    // MARK: - View menu

    /// Holds a weak reference so `menuWillOpen` can retitle the Show/Hide Tab Bar
    /// item and update the Text Size checkmarks before each open.  SwiftUI rebuilds
    /// the View menu periodically; `hookViewMenu()` is re-run from
    /// `mainMenuDidRemoveItem` to refresh both the weak ref and the delegate.
    private weak var viewMenu: NSMenu?

    private func hookViewMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let viewTitle = String(localized: "View", comment: "Menu header: view/navigate tabs")
        // Identify OUR View menu (the one carrying the ⌘1 pane shortcut) — there
        // can be a system-generated View stub with the same title on macOS 26.
        for item in mainMenu.items where item.title == viewTitle {
            guard let sub = item.submenu,
                  sub.items.contains(where: {
                      $0.keyEquivalent == "1" && $0.keyEquivalentModifierMask == [.command]
                  })
            else { continue }
            viewMenu = sub
            sub.delegate = self
            return
        }
    }

    // MARK: - Text Size submenu

    /// Inserts (or re-inserts) a "Text Size" submenu into the View menu.
    /// Built entirely in AppKit so checkmark state is updated in `menuWillOpen`
    /// by reading UserDefaults directly — SwiftUI's reactive Picker/Toggle
    /// cannot reliably reflect @AppStorage state in menu checkmarks.
    private func insertTextSizeSubmenu() {
        guard let viewMenu else { return }

        // Remove ALL stale or system-injected copies (macOS 26 injects its own
        // "Text Size" entry on each rebuild; removing only the first one leaves extras).
        // Snapshot items first so index shifts don't skip entries.
        for item in viewMenu.items.filter({ $0.title == textSizeMenuTitle }) {
            guard let idx = viewMenu.items.firstIndex(of: item) else { continue }
            viewMenu.removeItem(at: idx)
            // Remove the separator immediately before the (now-gone) item if it's ours.
            if idx > 0, viewMenu.items[idx - 1].isSeparatorItem {
                viewMenu.removeItem(at: idx - 1)
            }
        }

        let sub = NSMenu(title: textSizeMenuTitle)
        for i in 0..<AppearancePrefs.scales.count {
            let item = NSMenuItem(
                title: AppearancePrefs.label(forIndex: i),
                action: #selector(setTextSize(_:)),
                keyEquivalent: "")
            item.target = self
            item.tag = i
            sub.addItem(item)
        }

        let parent = NSMenuItem(title: textSizeMenuTitle, action: nil, keyEquivalent: "")
        parent.submenu = sub

        // Insert separator → Text Size after the pane shortcuts: before the
        // first separator if one exists (the one preceding the native Show/Hide
        // Tab Bar item on rebuild passes), else at the end.
        let dividerIndex = viewMenu.items.firstIndex(where: { $0.isSeparatorItem }) ?? viewMenu.items.count
        viewMenu.insertItem(parent, at: dividerIndex)
        viewMenu.insertItem(.separator(), at: dividerIndex)
    }

    private let textSizeMenuTitle = String(
        localized: "Text Size",
        comment: "View menu: submenu containing the in-app text-size choices")

    @objc private func setTextSize(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: AppearancePrefs.storageKey)
    }

    // MARK: - Show/Hide Tab Bar

    /// Appends a native Show/Hide Tab Bar item to the View menu. With a nil
    /// target and the standard `toggleTabBar:` selector, AppKit both retitles
    /// the item (Show vs. Hide) and disables it when the key window cannot
    /// toggle its tab bar — e.g. a window already merged into a tab group —
    /// matching Finder.
    private func hookTabBarItem() {
        guard let viewMenu else { return }

        // Remove stale copies from earlier passes (snapshot first; index math
        // as in insertTextSizeSubmenu).
        for item in viewMenu.items.filter({ $0.action == #selector(NSWindow.toggleTabBar(_:)) }) {
            guard let idx = viewMenu.items.firstIndex(of: item) else { continue }
            viewMenu.removeItem(at: idx)
            if idx > 0, viewMenu.items[idx - 1].isSeparatorItem {
                viewMenu.removeItem(at: idx - 1)
            }
        }

        let item = NSMenuItem(
            title: String(localized: "Show Tab Bar", comment: "View menu: show the window tab bar"),
            action: #selector(NSWindow.toggleTabBar(_:)),
            keyEquivalent: "t")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = nil
        viewMenu.addItem(.separator())
        viewMenu.addItem(item)
    }

    // MARK: - Window menu

    private var windowMenu: NSMenu?
    private weak var closeItem: NSMenuItem?

    private func hookWindowMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let windowTitle = String(localized: "Window", comment: "Menu header: window management")

        // Remove any existing Window menu items (including SwiftUI's auto-generated stub,
        // which often has a nil submenu and can't be used as windowsMenu).
        for item in mainMenu.items where item.title == windowTitle {
            mainMenu.removeItem(item)
        }

        // Create the NSMenu only once. The rebuild guard calls this function repeatedly
        // when SwiftUI rebuilds the main menu; recreating the NSMenu each time loses
        // AppKit's window-tracking state — AppKit only adds existing windows to the
        // windowsMenu when they are first ordered-front, so a fresh menu starts empty.
        if windowMenu == nil {
            let menu = NSMenu(title: windowTitle)
            windowMenu = menu
            menu.delegate = self

            func addItem(_ title: String, action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command) {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
                item.keyEquivalentModifierMask = modifiers
                item.target = nil
                menu.addItem(item)
            }

            // "Close" item that will transform to "Close All" when Option is pressed
            let closeItem = NSMenuItem(title: String(localized: "Close",
                                                     comment: "Window menu: close current window"),
                                      action: #selector(NSWindow.performClose(_:)),
                                      keyEquivalent: "w")
            closeItem.keyEquivalentModifierMask = [.command]
            closeItem.target = nil
            menu.addItem(closeItem)
            self.closeItem = closeItem

            // Menu tracking only runs the flagsTimer (below) while the Window menu is
            // open, so the visible Close item's keyEquivalentModifierMask reverts to
            // plain ⌘W as soon as the menu closes. That means ⌘⌥W pressed outside menu
            // tracking never matches it. Register a permanently hidden item that owns
            // the ⌘⌥W shortcut at all times; the visible item stays cosmetic-only.
            let closeAllKeyItem = NSMenuItem(title: String(localized: "Close All", comment: "Window menu: close all windows"),
                                            action: #selector(closeAllWindows(_:)),
                                            keyEquivalent: "w")
            closeAllKeyItem.keyEquivalentModifierMask = [.command, .option]
            closeAllKeyItem.target = self
            closeAllKeyItem.isHidden = true
            closeAllKeyItem.allowsKeyEquivalentWhenHidden = true
            menu.addItem(closeAllKeyItem)

            addItem(String(localized: "Minimize",           comment: "Window menu"), action: #selector(NSWindow.performMiniaturize(_:)), key: "m")
            addItem(String(localized: "Zoom",               comment: "Window menu"), action: #selector(NSWindow.performZoom(_:)),        key: "", modifiers: [])
            addItem(String(localized: "Full Screen",        comment: "Window menu"), action: #selector(NSWindow.toggleFullScreen(_:)),   key: "f", modifiers: [.control, .command])
            menu.addItem(.separator())
            addItem(String(localized: "Merge All Windows", comment: "Window menu: merge all open windows into one tabbed window"), action: #selector(NSWindow.mergeAllWindows(_:)), key: "", modifiers: [])
            menu.addItem(.separator())
            addItem(String(localized: "Bring All to Front", comment: "Window menu"), action: #selector(NSApplication.arrangeInFront(_:)), key: "", modifiers: [])

            // Suppress SwiftUI internal windows from AppKit's auto-managed window list.
            for win in NSApp.windows where win.title.isEmpty || win.title == "Item-0" {
                win.isExcludedFromWindowsMenu = true
            }

            // Register as the official windows menu so AppKit injects its standard
            // entries (Cycle Through Windows, Merge All Windows, Show Next/Previous Tab,
            // Move Tab to New Window, Center, Move & Resize) and manages the window list.
            NSApp.windowsMenu = menu

            // AppKit only auto-adds a window to windowsMenu when it is first ordered
            // front. Windows restored from UserDefaults on launch are already visible
            // before windowsMenu is set, so they are never retroactively picked up.
            // Explicitly register all eligible existing windows now.
            for win in NSApp.windows
            where !win.isExcludedFromWindowsMenu && !win.title.isEmpty && win.title != "Item-0" {
                NSApp.addWindowsItem(win, title: win.title, filename: false)
            }
        }

        let menuItem = NSMenuItem(title: windowTitle, action: nil, keyEquivalent: "")
        menuItem.submenu = windowMenu

        // Insert after the View menu.
        let viewTitle = String(localized: "View", comment: "Menu header: view/navigate tabs")
        if let idx = mainMenu.items.firstIndex(where: { $0.title == viewTitle }) {
            mainMenu.insertItem(menuItem, at: idx + 1)
        } else {
            mainMenu.addItem(menuItem)
        }
    }

    @objc private func closeAllWindows(_ sender: Any?) {
        let windows = NSApp.windows
        for window in windows {
            if !window.isExcludedFromWindowsMenu {
                window.performClose(sender)
            }
        }
    }

    private func updateCloseItemState() {
        guard let closeItem else { return }
        let optionPressed = NSEvent.modifierFlags.contains(.option)
        if optionPressed {
            closeItem.title = String(localized: "Close All", comment: "Window menu: close all windows")
            closeItem.action = #selector(closeAllWindows(_:))
            closeItem.target = self
        } else {
            closeItem.title = String(localized: "Close", comment: "Window menu: close current window")
            closeItem.action = #selector(NSWindow.performClose(_:))
            closeItem.target = nil
        }
    }

    private var flagsTimer: Timer?

    // MARK: - About

    private func hookAboutMenuItem() {
        guard
            let appMenu = NSApp.mainMenu?.items.first?.submenu,
            let aboutItem = appMenu.items.first(where: {
                $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:))
            })
        else { return }

        aboutItem.target = self
        aboutItem.action = #selector(showAboutWindow)
    }

    @objc private func showAboutWindow() {
        AboutWindowController.shared.show()
    }

    // MARK: - Factory Reset (Option-key hidden item)

    private weak var hideDockIconItem: NSMenuItem?

    private func hookAppMenu() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu else { return }

        // Always re-assign the delegate — SwiftUI rebuilds can clear it, which
        // breaks the menuWillOpen visibility management.  The rest of the
        // function is idempotent: items are only inserted when not already present.
        menu.delegate = self

        // Find the Quit item. Factory Reset is inserted immediately after it,
        // hidden, and shown/hidden by modifier state in menuWillOpen plus an
        // eventTracking-mode timer while the menu is open.  (isAlternate would
        // be the native mechanism, but macOS 27 force-unhides alternates after
        // window transitions, so visibility is managed explicitly.)
        guard
            let quitItem = menu.items.last(where: {
                $0.action == #selector(NSApplication.terminate(_:))
            })
        else { return }
        // Always remove and re-insert the Factory Reset items so they land
        // directly after Quit regardless of any SwiftUI-driven menu reordering.
        for item in menu.items.filter({ $0.action == #selector(confirmFactoryReset) }) {
            menu.removeItem(item)
        }
        // Three alternates so Factory Reset is reachable on every OS version:
        //   ⌘⌥Q       — macOS 15 and earlier (Option alone)
        //   ⌘⇧Q       — all versions (Shift alone)
        //   ⌘⌥⇧Q     — all versions (Option+Shift)
        // macOS 26 intercepts ⌘⌥Q at the system level before AppKit sees it,
        // making the Shift-based shortcuts the reliable fallback there.
        let key = quitItem.keyEquivalent
        let alternates: [NSEvent.ModifierFlags] = [
            [.command, .option],
            [.command, .shift],
            [.command, .option, .shift],
        ]
        let freshQuitIndex = menu.items.firstIndex(of: quitItem)!
        for (i, modifiers) in alternates.enumerated() {
            let item = NSMenuItem(
                title: String(
                    localized: "Factory Reset\u{2026}",
                    comment: "Menu item: factory reset (hidden alternate)"),
                action: #selector(confirmFactoryReset),
                keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.isHidden = true
            // Without isAlternate, hidden items don't fire key equivalents by default.
            item.allowsKeyEquivalentWhenHidden = true
            item.target = self
            menu.insertItem(item, at: freshQuitIndex + 1 + i)
        }

        // Only insert "Hide Dock Icon…" if it isn't already there.
        // Hidden automatically in menuWillOpen when in accessory mode.
        let alreadyHasHide = menu.items.contains {
            $0.action == #selector(confirmHideDockIcon)
        }
        if !alreadyHasHide {
            let hideItem = NSMenuItem(
                title: String(
                    localized: "Hide Dock Icon\u{2026}",
                    comment: "Menu item: hide the app's Dock icon"),
                action: #selector(confirmHideDockIcon),
                keyEquivalent: "")
            hideItem.target = self
            // Insert before the separator that precedes Quit.
            let separatorIndex = (freshQuitIndex > 0 && menu.items[freshQuitIndex - 1].isSeparatorItem)
                ? freshQuitIndex - 1
                : freshQuitIndex
            menu.insertItem(NSMenuItem.separator(), at: separatorIndex)
            menu.insertItem(hideItem, at: separatorIndex)
            menu.insertItem(NSMenuItem.separator(), at: separatorIndex)
            hideDockIconItem = hideItem
        } else if hideDockIconItem == nil {
            // Item survived the rebuild; re-acquire the weak reference.
            hideDockIconItem = menu.items.first { $0.action == #selector(confirmHideDockIcon) }
        }
    }

    @objc private func confirmHideDockIcon() {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Hide MockTab's Dock Icon?",
            comment: "Alert title: hide Dock icon confirmation")
        alert.informativeText = String(
            localized: "MockTab will no longer appear in the Dock or as an active app in the menu bar. You can still access all controls from its menu bar icon. To bring the Dock icon back, click the MockTab menu bar icon and choose \u{201C}Show in Dock\u{201D}.",
            comment: "Alert body: explaining consequences of hiding Dock icon")
        alert.alertStyle = .informational
        let hideButton = alert.addButton(
            withTitle: String(localized: "Hide Dock Icon", comment: "Button label: confirm hide Dock icon"))
        alert.addButton(
            withTitle: String(localized: "Cancel", comment: "Button label: cancel hide Dock icon"))
        hideButton.keyEquivalent = "\r"

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(false, forKey: "showInDock")
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func confirmFactoryReset() {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Reset MockTab to Factory Settings?",
            comment: "Alert title: factory reset confirmation")
        alert.informativeText = String(
            localized:
                "All tablets, tools, presets, and button mappings will be erased. MockTab will restart.",
            comment: "Alert body: explaining the consequences of factory reset")
        alert.alertStyle = .warning
        let resetButton = alert.addButton(
            withTitle: String(localized: "Reset", comment: "Button label: confirm factory reset"))
        alert.addButton(
            withTitle: String(localized: "Cancel", comment: "Button label: cancel factory reset"))
        // Return key = default button (highlighted, activates on Return).
        resetButton.keyEquivalent = "\r"

        // Monitor for Command-R while dialog is open.
        var eventMonitor: Any?
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Command-R (keyCode 15 = 'R')
            if event.keyCode == 15 && event.modifierFlags.contains(.command) {
                // Defer the reset to allow the dialog to close first
                DispatchQueue.main.async { self?.performFactoryReset() }
                if let monitor = eventMonitor {
                    NSEvent.removeMonitor(monitor)
                }
                return nil  // consume the event
            }
            return event  // pass through all other keys
        }

        let resultCode = alert.runModal()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }

        guard resultCode == .alertFirstButtonReturn else { return }
        performFactoryReset()
    }

    private func performFactoryReset() {
        // Tell SettingsWindowManager not to save when willTerminate fires.
        // This prevents the window state from being re-populated after we clear it.
        SettingsWindowManager.shared.skipNextWindowSave()

        // Wipe the entire UserDefaults domain in one call.  This removes every
        // key ever written: device settings, presets, tool settings, registry,
        // and window state.
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.synchronize()
        }

        // Also clear NSWindow autosave caches for window frames.  These are stored
        // independently in system preferences (com.apple.NSWindow.State) and would
        // otherwise restore stale window geometry on the next launch.
        NSWindow.removeFrame(usingName: NSWindow.FrameAutosaveName("MockTabSettingsWindow"))
        NSWindow.removeFrame(usingName: NSWindow.FrameAutosaveName("PreferencesWindow"))

        // Relaunch so the new instance reads factory defaults rather than the
        // stale in-memory @Published / @AppStorage state from this session.
        // NSWorkspace.open() won't spawn a second instance while this one is
        // still alive, so we delegate the open to a detached shell that polls
        // until our PID exits and then calls `open`.
        let bundlePath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \"\(bundlePath)\""
        Process.launchedProcess(launchPath: "/bin/sh", arguments: ["-c", script])
        NSApp.terminate(nil)
    }

    // MARK: - Tablet menu

    private var tabletMenu: NSMenu?

    private func insertTabletMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let tabletTitle = String(
            localized: "Tablet", comment: "Menu header: tablet-specific actions")

        // Always remove and reinsert so position is correct after any SwiftUI rebuild.
        for item in mainMenu.items where item.title == tabletTitle {
            mainMenu.removeItem(item)
        }

        // Create the NSMenu only once; reuse on subsequent calls to preserve delegate state.
        if tabletMenu == nil {
            let menu = NSMenu(title: tabletTitle)
            menu.delegate = self
            tabletMenu = menu
        }

        let menuItem = NSMenuItem(title: tabletTitle, action: nil, keyEquivalent: "")
        menuItem.submenu = tabletMenu

        // Insert immediately after the app menu. Locate the app menu by its Quit action
        // rather than by index — robust against SwiftUI inserting items before it.
        let appMenuIdx = mainMenu.items.firstIndex {
            $0.submenu?.items.contains { $0.action == #selector(NSApplication.terminate(_:)) } ?? false
        } ?? 1
        mainMenu.insertItem(menuItem, at: appMenuIdx + 1)
    }

    private func rebuildTabletMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // "New Settings Window" — opens a generic window.
        let newItem = NSMenuItem(
            title: String(
                localized: "Duplicate Window", comment: "Menu item: open a new settings window"),
            action: #selector(newSettingsWindow),
            keyEquivalent: "n")
        newItem.keyEquivalentModifierMask = [.command, .shift]
        newItem.target = self
        menu.addItem(newItem)

        // "Detect Tablet" — re-evaluates the active device and focuses its window.
        let detectItem = NSMenuItem(
            title: String(
                localized: "Detect Tablet", comment: "Menu item: find and focus the active tablet"),
            action: #selector(detectTablet),
            keyEquivalent: "r")
        detectItem.keyEquivalentModifierMask = [.command]
        detectItem.target = self
        menu.addItem(detectItem)

        // List known tablets from DeviceRegistry.
        let registry = DeviceRegistry.shared
        let tm = TabletManager.shared
        if !registry.knownTablets.isEmpty {
            menu.addItem(.separator())

            for tablet in registry.knownTablets {
                // A companion peripheral (Xencelabs Quick Keys puck/dongle)
                // is folded into its owning tablet's window while connected —
                // don't list it as its own selectable device.
                if VendorDeviceRegistry.isConnectedCompanion(
                    productID: tablet.productID, connectedProductIDs: tm.connectedProductIDs)
                {
                    continue
                }
                let connected = tm.connectedProductIDs.contains(tablet.productID)
                let suffix = connected ? (tm.context(for: tablet)?.batteryMenuSuffix ?? "") : ""
                let label = SettingsWindowManager.shared.menuLabel(forKey: tablet.instanceKey) + suffix
                let item = NSMenuItem(
                    title: label,
                    action: #selector(openDeviceWindow(_:)),
                    keyEquivalent: "")
                item.target = self
                // Composite instance identity doesn't fit NSMenuItem.tag
                // (an Int) — carry it via representedObject instead.
                item.representedObject = tablet.instanceKey.stringValue
                // Show the native state checkmark for currently connected tablets,
                // matching the flush-left alignment of the other checkmarked items
                // (toggles, active profile) in the same menu.
                item.state = connected ? .on : .off
                menu.addItem(item)
            }
        }
    }

    @objc private func newSettingsWindow() {
        SettingsWindowManager.shared.openNewWindow()
    }

    @objc private func openDeviceWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
            let key = DeviceInstanceKey(stringValue: id)
        else { return }
        SettingsWindowManager.shared.openWindow(forInstanceKey: key)
    }

    @objc private func detectTablet() {
        AppMenuController.activateBestDevice()
    }

    /// Picks the most relevant connected (or known) device and activates its
    /// settings window.  Called from both the menu item and TabletAreaView's
    /// "Detect Tablet" button.
    @MainActor
    static func activateBestDevice() {
        let tm = TabletManager.shared
        // Prefer the pen-in-proximity unit; fall back to first connected,
        // then first ever-seen device.
        if let key = tm.activeContext?.instanceKey
            ?? DeviceRegistry.shared.knownTablets.first(where: {
                tm.connectedProductIDs.contains($0.productID)
            })?.instanceKey
            ?? DeviceRegistry.shared.knownTablets.first?.instanceKey
        {
            SettingsWindowManager.shared.openWindow(forInstanceKey: key)
        } else if let pid = tm.connectedProductIDs.first {
            SettingsWindowManager.shared.openWindow(forProductID: pid)
        }
    }

    // MARK: - **Profiles menu

    private var presetsMenu: NSMenu?

    private func insertPresetsMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let profilesTitle = String(
            localized: "Profiles", comment: "Menu header: profile management")

        // Always remove and reinsert so position is correct after any SwiftUI rebuild.
        for item in mainMenu.items where item.title == profilesTitle {
            mainMenu.removeItem(item)
        }

        // Create the NSMenu only once; reuse on subsequent calls to preserve delegate state.
        if presetsMenu == nil {
            let menu = NSMenu(title: profilesTitle)
            menu.delegate = self
            presetsMenu = menu
        }

        let menuItem = NSMenuItem(title: profilesTitle, action: nil, keyEquivalent: "")
        menuItem.submenu = presetsMenu

        // Locate Edit by its ⌘Z shortcut — reliable regardless of locale or whether
        // SwiftUI exposes an undo: selector on its Button-generated menu items.
        let editIndex = mainMenu.items.firstIndex { item in
            item.submenu?.items.contains {
                $0.keyEquivalent == "z" && $0.keyEquivalentModifierMask == .command
            } ?? false
        }
        if let editIndex {
            mainMenu.insertItem(menuItem, at: editIndex + 1)
        } else {
            // Fallback: place after Tablet, before View.
            let tabletTitle = String(localized: "Tablet", comment: "Menu header: tablet-specific actions")
            let afterTablet = (mainMenu.items.firstIndex { $0.title == tabletTitle } ?? 2) + 2
            mainMenu.insertItem(menuItem, at: min(afterTablet, mainMenu.items.count))
        }
    }

    /// Rebuild the **Profiles menu every time it is about to open.
    private func rebuildPresetsMenu(_ menu: NSMenu) {
        guard let settings else { return }
        menu.removeAllItems()

        if !settings.profiles.isEmpty {
            let defsItem = NSMenuItem(
                title: String(
                    localized: "Device Defaults",
                    comment: "Profile option: use device's default settings"),
                action: #selector(activateDeviceDefaults),
                keyEquivalent: "")
            defsItem.target = self
            defsItem.state = settings.activeProfile == nil ? .on : .off
            menu.addItem(defsItem)
            menu.addItem(.separator())

            for profile in settings.profiles {
                let item = NSMenuItem(
                    title: profile.name,
                    action: #selector(activatePreset(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = profile.id
                item.state = settings.activeProfile?.id == profile.id ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let showItem = NSMenuItem(
            title: String(
                localized: "Show Saved Configurations…", comment: "Menu item: open the Profiles tab"
            ),
            action: #selector(showPresetsTab),
            keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(.separator())

        let importItem = NSMenuItem(
            title: String(localized: "Import Configuration\u{2026}", comment: "Profiles menu: import configuration from file"),
            action: #selector(menuImportConfiguration),
            keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)

        let exportItem = NSMenuItem(
            title: String(localized: "Export Configuration\u{2026}", comment: "Profiles menu: export configuration to file"),
            action: #selector(menuExportConfiguration),
            keyEquivalent: "")
        exportItem.target = self
        menu.addItem(exportItem)

        menu.addItem(.separator())

        let revealItem = NSMenuItem(
            title: String(localized: "Reveal MockTab Settings File\u{2026}", comment: "Profiles menu: reveal preferences plist in Finder"),
            action: #selector(menuRevealSettingsFile),
            keyEquivalent: "")
        revealItem.target = self
        menu.addItem(revealItem)
    }

    // MARK: - Configuration import / export / reveal

    @objc private func menuImportConfiguration() {
        SettingsWindowManager.shared.showTab(.profiles)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = String(
            localized: "Choose a MockTab backup file to import",
            comment: "File picker message for importing backup")
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url) else { return }
            NotificationCenter.default.post(
                name: .mockTabImportData,
                object: nil,
                userInfo: ["data": data])
        }
    }

    @objc private func menuExportConfiguration() {
        SettingsWindowManager.shared.showTab(.profiles)
        let exporter = PresetExporter(
            registry: DeviceRegistry.shared,
            tabletManager: TabletManager.shared)
        guard let data = exporter.export() else { return }
        let panel = NSSavePanel()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "MockTab-\(fmt.string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    @objc private func menuRevealSettingsFile() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(bundleID).plist")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === tabletMenu {
            rebuildTabletMenu(menu)
        } else if menu === presetsMenu {
            rebuildPresetsMenu(menu)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === windowMenu {
            // Update "Close" item title/action based on Option key state.
            // Poll with a timer while the menu is open to respond to modifier key changes.
            updateCloseItemState()
            flagsTimer?.invalidate()
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateCloseItemState() }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            flagsTimer = timer
            return
        }

        if menu === viewMenu {
            // Retitle Show/Hide Tab Bar based on current visibility. AppKit validates
            // (enables/disables) the item automatically; it does not retitle it.
            let visible = NSApp.mainWindow?.tabGroup?.isTabBarVisible ?? false
            for item in menu.items where item.action == #selector(NSWindow.toggleTabBar(_:)) {
                item.title = visible
                    ? String(localized: "Hide Tab Bar",
                             comment: "View menu: hide the window tab bar (shown when tab bar is visible)")
                    : String(localized: "Show Tab Bar",
                             comment: "View menu: show the window tab bar")
            }

            // Update checkmarks in the Text Size submenu to reflect current selection.
            let activeIndex = UserDefaults.standard.integer(forKey: AppearancePrefs.storageKey)
            if let textSizeItem = menu.items.first(where: { $0.title == textSizeMenuTitle }),
               let textSizeSub = textSizeItem.submenu
            {
                for item in textSizeSub.items {
                    item.state = item.tag == activeIndex ? .on : .off
                }
            }

            return
        }

        guard menu === NSApp.mainMenu?.items.first?.submenu else { return }

        // Factory Reset visibility is managed explicitly (isAlternate is unusable:
        // macOS 27 force-unhides alternates after window transitions).
        updateFactoryResetVisibility(in: menu)
        // Menu tracking runs its own event loop that bypasses NSEvent local
        // monitors, so poll the modifier state with a timer instead. Scheduling
        // in .eventTracking mode keeps it firing while the menu is open.
        flagsTimer?.invalidate()
        // The timer block is @Sendable, but it only ever fires on the main
        // run loop; the unsafe capture just carries the non-Sendable NSMenu
        // across into MainActor.assumeIsolated.
        nonisolated(unsafe) weak let menuRef = menu
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if let menu = menuRef { self?.updateFactoryResetVisibility(in: menu) }
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        flagsTimer = timer

        guard let item = hideDockIconItem else { return }

        // Hide "Hide Dock Icon…" when already running as an accessory (no Dock icon).
        let showingInDock = UserDefaults.standard.object(forKey: "showInDock") == nil
            || UserDefaults.standard.bool(forKey: "showInDock")
        item.isHidden = !showingInDock
        // Hide the separator that sits immediately after the item.
        if let idx = menu.items.firstIndex(of: item),
           idx + 1 < menu.items.count,
           menu.items[idx + 1].isSeparatorItem
        {
            menu.items[idx + 1].isHidden = !showingInDock
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === windowMenu {
            flagsTimer?.invalidate()
            flagsTimer = nil
            // AppKit sends the clicked item's action *after* menuDidClose returns, so
            // resetting the item here synchronously would clobber the action a click
            // just selected (e.g. turn a "Close All" click back into plain "Close"
            // before it fires). Defer the reset to the next run-loop turn instead.
            DispatchQueue.main.async { [weak self] in
                self?.closeItem?.title = String(localized: "Close", comment: "Window menu: close current window")
                self?.closeItem?.action = #selector(NSWindow.performClose(_:))
                self?.closeItem?.target = nil
            }
            return
        }

        guard menu === NSApp.mainMenu?.items.first?.submenu else { return }
        flagsTimer?.invalidate()
        flagsTimer = nil
        // Re-hide all Factory Reset items so that if the delegate is subsequently
        // cleared by a SwiftUI refresh, they don't remain visible on next open.
        for item in menu.items where item.action == #selector(confirmFactoryReset) {
            item.isHidden = true
        }
    }

    private func updateFactoryResetVisibility(in menu: NSMenu) {
        // Show exactly the variant whose non-Command modifier mask matches what is held.
        let relevantFlags = NSEvent.modifierFlags.intersection([.option, .shift])
        for resetItem in menu.items where resetItem.action == #selector(confirmFactoryReset) {
            let nonCommandMods = resetItem.keyEquivalentModifierMask.subtracting(.command)
            resetItem.isHidden = (nonCommandMods != relevantFlags)
        }
    }

    // MARK: - Preset actions

    @objc private func activateDeviceDefaults() {
        settings?.activate(nil)
    }

    @objc private func activatePreset(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? UUID,
            let profile = settings?.profiles.first(where: { $0.id == uuid })
        else { return }
        settings?.activate(profile)
    }

    @objc private func showPresetsTab() {
        SettingsWindowManager.shared.showTab(.profiles)
    }

}
