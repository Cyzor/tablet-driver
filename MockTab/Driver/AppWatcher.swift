// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

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

    /// Bundle IDs of Qt/GTK apps that consume `.tabletPointer` CGEvents.
    /// All other apps only need the mouse event with mouseEventSubtype=1.
    static let qtGtkBundleIDs: Set<String> = [
        "org.kde.krita",
        "org.gimp.gimp-2.10",
        "org.gimp.gimp",
    ]

    /// Bundle IDs that need plain mouse events with no tablet-union metadata.
    /// Pages text engine is confused by mouseEventSubtype=1 and ignores drags.
    static let plainMouseBundleIDs: Set<String> = [
        "com.apple.iWork.Pages",
        "com.apple.iWork.Keynote",
        "com.apple.iWork.Numbers",
        "com.apple.Pages", // macOS 26+
        "com.apple.Keynote",
        "com.apple.Numbers",
    ]

    private var observerToken: (any NSObjectProtocol)?
    private var releaseTokens: [any NSObjectProtocol] = []

    /// Called once at launch to force the lazy singleton to initialize,
    /// register the NSWorkspace notification observer, and seed the initial
    /// per-app override state from whichever app is currently frontmost.
    func start() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier
        else { return }
        let name = app.localizedName ?? bundleID
        let needsTabletPointer = Self.qtGtkBundleIDs.contains(bundleID)
        let profile: InputInjector.AppInputProfile =
            Self.plainMouseBundleIDs.contains(bundleID) ? .pagesPlainMouse : .generic
        for ctx in TabletManager.shared.contexts.values {
            ctx.settings.handleAppOverrideActivation(bundleID: bundleID, appName: name)
            ctx.injector.activeAppNeedsTabletPointerEvents = needsTabletPointer
            ctx.injector.activeAppProfile = profile
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

        // Broader safety valves: release synthetic modifiers whenever this app
        // loses focus or the system is about to lose our input context. The
        // underlying release is idempotent, so overlapping signals are harmless.
        let wsCenter = NSWorkspace.shared.notificationCenter
        let nc = NotificationCenter.default
        let releaseSources: [(NotificationCenter, Notification.Name)] = [
            (nc, NSApplication.didResignActiveNotification),
            (wsCenter, NSWorkspace.willSleepNotification),
            (wsCenter, NSWorkspace.screensDidSleepNotification),
            (wsCenter, NSWorkspace.sessionDidResignActiveNotification),
        ]
        for (center, name) in releaseSources {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    for ctx in TabletManager.shared.contexts.values {
                        ctx.injector.releaseOnAppSwitch()
                    }
                }
            }
            releaseTokens.append(token)
        }
    }

    deinit {
        if let token = observerToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        let wsCenter = NSWorkspace.shared.notificationCenter
        let nc = NotificationCenter.default
        for token in releaseTokens {
            wsCenter.removeObserver(token)
            nc.removeObserver(token)
        }
    }

    private func appDidActivate(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
            let bundleID = app.bundleIdentifier
        else { return }
        let name = app.localizedName ?? bundleID
        let needsTabletPointer = Self.qtGtkBundleIDs.contains(bundleID)
        let profile: InputInjector.AppInputProfile =
            Self.plainMouseBundleIDs.contains(bundleID) ? .pagesPlainMouse : .generic
        for ctx in TabletManager.shared.contexts.values {
            ctx.settings.handleAppActivation(bundleID: bundleID, appName: name)
            ctx.settings.handleAppOverrideActivation(bundleID: bundleID, appName: name)
            ctx.injector.activeAppNeedsTabletPointerEvents = needsTabletPointer
            ctx.injector.activeAppProfile = profile
            ctx.injector.releaseOnAppSwitch()
        }
    }
}
