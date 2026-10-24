// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// The profile choices that the Profiles menu and the status menu both show:
/// Device Defaults, a separator, then each profile, the active one checked.
@MainActor
enum ProfileMenuItems {
    static func items(
        for settings: TabletSettings, target: AnyObject, defaultsAction: Selector, profileAction: Selector
    ) -> [NSMenuItem] {
        let defaults = NSMenuItem(
            title: String(localized: "Device Defaults", comment: "Profile option: use device's default settings"),
            action: defaultsAction, keyEquivalent: "")
        defaults.target = target
        defaults.state = settings.activeProfile == nil ? .on : .off
        let profiles = settings.profiles.map { profile in
            let item = NSMenuItem(title: profile.name, action: profileAction, keyEquivalent: "")
            item.target = target
            item.representedObject = profile.id
            item.state = settings.activeProfile?.id == profile.id ? .on : .off
            return item
        }
        return [defaults, .separator()] + profiles
    }

    /// The profile an item from `items(for:...)` stands for.
    static func profile(of item: NSMenuItem, in settings: TabletSettings) -> TabletSettings.Profile? {
        guard let id = item.representedObject as? UUID else { return nil }
        return settings.profiles.first { $0.id == id }
    }
}
