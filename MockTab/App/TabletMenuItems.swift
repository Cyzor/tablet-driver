// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import TabletKit

/// The list of known tablets that the main menu, the status menu, and the
/// Dock menu each show.
@MainActor
enum TabletMenuItems {
    /// One item per known tablet, checked when connected. `action` receives
    /// the item, whose `representedObject` is the tablet's
    /// `DeviceInstanceKey.stringValue`; read it back with `instanceKey(of:)`.
    static func items(target: AnyObject, action: Selector) -> [NSMenuItem] {
        let tm = TabletManager.shared
        let windows = SettingsWindowManager.shared
        return DeviceRegistry.shared.knownTablets.compactMap { tablet in
            // A connected companion (Quick Keys puck or dongle) belongs to its
            // tablet's window, so it gets no row of its own.
            if DeviceCompanions.isConnectedCompanion(
                productID: tablet.productID, connectedProductIDs: tm.connectedProductIDs)
            {
                return nil
            }
            let connected = tm.connectedProductIDs.contains(tablet.productID)
            let suffix = connected ? (tm.context(for: tablet)?.batteryMenuSuffix ?? "") : ""
            // The dongle has no window of its own, so its row is disabled. A
            // tablet it relays is listed, and checked, under its own row.
            let isDongle = tm.isDongleRawProductID(tablet.productID)
            let item = NSMenuItem(
                title: windows.menuLabel(forKey: tablet.instanceKey) + suffix,
                action: isDongle ? nil : action,
                keyEquivalent: "")
            item.target = target
            item.isEnabled = !isDongle
            // A composite identity doesn't fit `tag`, an Int.
            item.representedObject = tablet.instanceKey.stringValue
            item.state = connected ? .on : .off
            return item
        }
    }

    /// The tablet an item from `items(target:action:)` stands for.
    static func instanceKey(of item: NSMenuItem) -> DeviceInstanceKey? {
        (item.representedObject as? String).flatMap { DeviceInstanceKey(stringValue: $0) }
    }
}
