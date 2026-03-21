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
        }
    }
}
