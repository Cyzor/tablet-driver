// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026  This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab.  If not, see <https://www.gnu.org/licenses/>.

import AppKit

/// Observes NSWorkspace app-activation events and tells TabletSettings to
/// switch presets automatically when `autoSwitchEnabled` is true.
///
/// Lives on @MainActor because TabletSettings is @MainActor; NSWorkspace
/// notifications are always delivered on the main thread when the observer
/// queue is `.main`.
@MainActor
final class AppWatcher {

    static let shared = AppWatcher()

    weak var settings: TabletSettings?

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // NSWorkspace notifications arrive on the main thread.
    @objc private nonisolated func appDidActivate(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
            let bundleID = app.bundleIdentifier
        else { return }
        let name = app.localizedName ?? bundleID
        Task { @MainActor [weak self] in
            self?.settings?.handleAppActivation(bundleID: bundleID, appName: name)
            self?.settings?.handleAppOverrideActivation(bundleID: bundleID, appName: name)
        }
    }
}
