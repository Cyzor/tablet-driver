// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine

/// Which windows are collecting device data, so nothing quits MockTab under
/// one. Weak, so a window that closes without saying so can't hold it open.
@MainActor
final class CaptureActivity: ObservableObject {
    static let shared = CaptureActivity()

    private let owners = NSMapTable<AnyObject, WindowRef>.weakToStrongObjects()

    var isActive: Bool { owners.keyEnumerator().nextObject() != nil }

    func begin(_ owner: AnyObject, in window: WindowRef) {
        objectWillChange.send()
        owners.setObject(window, forKey: owner)
    }

    func end(_ owner: AnyObject) {
        objectWillChange.send()
        owners.removeObject(forKey: owner)
    }

    /// Brings a capturing window forward, its capture sheet with it.
    func show() {
        guard let window = owners.objectEnumerator()?.allObjects
            .compactMap({ ($0 as? WindowRef)?.window }).first
        else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
