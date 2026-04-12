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

    private var observerToken: (any NSObjectProtocol)?

    /// Called once at launch to force the lazy singleton to initialize,
    /// register the NSWorkspace notification observer, and seed the initial
    /// per-app override state from whichever app is currently frontmost.
    func start() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier
        else { return }
        let name = app.localizedName ?? bundleID
        for ctx in TabletManager.shared.contexts.values {
            ctx.settings.handleAppOverrideActivation(bundleID: bundleID, appName: name)
        }
    }

    private init() {
        // Block-based API: no NSObject requirement, queue: .main ensures delivery on main thread
        observerToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Explicit @MainActor hop in the closure for clarity and Swift 6 compatibility
            Task { @MainActor [weak self] in
                self?.appDidActivate(notification)
            }
        }
    }

    deinit {
        if let token = observerToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    private func appDidActivate(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
            let bundleID = app.bundleIdentifier
        else { return }
        let name = app.localizedName ?? bundleID
        for ctx in TabletManager.shared.contexts.values {
            ctx.settings.handleAppActivation(bundleID: bundleID, appName: name)
            ctx.settings.handleAppOverrideActivation(bundleID: bundleID, appName: name)
        }
    }
}
