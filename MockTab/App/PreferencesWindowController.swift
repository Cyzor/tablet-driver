import AppKit
import Combine
import SwiftUI

/// Manages all settings windows.
///
/// Maintains a default window (for the active device or generic settings)
/// and any number of per-device windows spawned via the Tablet menu.
/// Selecting a tablet from the menu activates an existing window for that
/// device if one is already open; only "New Settings Window" creates
/// additional windows unconditionally.
///
/// When the user selects a different tablet from the Tablet Area model
/// picker, the affected window is replaced in-place (same position and
/// tab) with one bound to the new device's settings.
@MainActor
final class PreferencesWindowController {

    static let shared = PreferencesWindowController()

    /// Shared settings instance — used by the menu bar.
    let settings = TabletSettings()

    /// All open settings windows, including the default.
    private var windows: [SettingsWindowController] = []

    /// The default (first) window — created lazily.
    private var defaultWindow: SettingsWindowController?

    private var deviceObserver: AnyCancellable?

    private init() {
        // When the first device connects and the default window has no
        // productID (launched before any tablet was plugged in), replace
        // it so its titles and settings bind to the real device.
        deviceObserver = TabletManager.shared.$connectedProductIDs
            .dropFirst()   // skip the initial empty value
            .first(where: { !$0.isEmpty })
            .receive(on: RunLoop.main)
            .sink { [weak self] ids in
                guard let self,
                      let dw = self.defaultWindow,
                      dw.productID == nil,
                      let pid = ids.first else { return }
                self.replaceWindow(dw, withDeviceID: pid)
            }
    }

    // MARK: - Default window (backward-compatible API)

    /// Shows the default settings window (creating it if needed).
    func show() {
        ensureDefaultWindow().show()
    }

    /// Shows the default window and switches to the tab at `index`.
    func showTab(at index: Int) {
        ensureDefaultWindow().showTab(at: index)
    }

    /// Shows the default window and switches to the first tab named `name`.
    func showTab(named name: String) {
        ensureDefaultWindow().showTab(named: name)
    }

    // MARK: - Multi-window

    /// Opens or activates a window for a specific device.
    /// If a window for this product ID already exists, it is brought to front.
    @discardableResult
    func openWindow(forProductID productID: Int) -> SettingsWindowController {
        // If a window for this device already exists, just activate it.
        if let existing = windows.first(where: { $0.productID == productID }) {
            existing.show()
            return existing
        }

        let (s, label) = settingsAndLabel(forProductID: productID)
        let wc = SettingsWindowController(settings: s, deviceLabel: label, productID: productID)

        // Offset from the last window so they cascade.
        if let lastFrame = windows.last?.window?.frame {
            wc.window?.setFrameOrigin(NSPoint(x: lastFrame.minX + 20,
                                               y: lastFrame.minY - 20))
        }

        windows.append(wc)
        observeClose(wc)
        wc.show()
        return wc
    }

    /// Creates a brand-new window unconditionally (for "New Settings Window").
    @discardableResult
    func openNewWindow() -> SettingsWindowController {
        let pid = activeDeviceProductID()
        let (s, label) = settingsAndLabel(forProductID: pid)
        let wc = SettingsWindowController(settings: s, deviceLabel: label, productID: pid)

        if let lastFrame = windows.last?.window?.frame {
            wc.window?.setFrameOrigin(NSPoint(x: lastFrame.minX + 20,
                                               y: lastFrame.minY - 20))
        }

        windows.append(wc)
        observeClose(wc)
        wc.show()
        return wc
    }

    /// Replaces an existing window with one bound to a different device.
    /// Preserves the window position and selected tab index.
    func replaceWindow(_ old: SettingsWindowController, withDeviceID pid: Int) {
        let frame = old.window?.frame
        let tabIndex = old.selectedTabIndex
        let wasDefault = defaultWindow === old

        // Close the old window.
        old.window?.close()
        // close notification removes it from `windows` and clears defaultWindow

        let (s, label) = settingsAndLabel(forProductID: pid)
        let wc = SettingsWindowController(settings: s, deviceLabel: label, productID: pid)

        if let frame { wc.window?.setFrame(frame, display: false) }

        windows.append(wc)
        observeClose(wc)
        if wasDefault { defaultWindow = wc }
        wc.showTab(at: tabIndex)
    }

    // MARK: - Labels

    /// Display label for a device, preferring nickname over model name.
    func displayLabel(forProductID productID: Int?) -> String {
        guard let productID else { return "MockTab" }
        let registry = DeviceRegistry.shared
        if let tablet = registry.knownTablets.first(where: { $0.id == productID }) {
            if tablet.nickname != tablet.modelName {
                return "\(tablet.nickname)"
            }
            return tablet.modelName
        }
        return TabletManager.deviceName(forProductID: productID)
    }

    /// Menu-ready label: nickname if different from model, else model name.
    /// Includes the model in parentheses when a nickname is set.
    func menuLabel(forProductID productID: Int) -> String {
        let registry = DeviceRegistry.shared
        if let tablet = registry.knownTablets.first(where: { $0.id == productID }) {
            if tablet.nickname != tablet.modelName {
                return "\(tablet.nickname) — \(tablet.modelName)"
            }
            return tablet.modelName
        }
        return TabletManager.deviceName(forProductID: productID)
    }

    // MARK: - Private

    /// Returns the best product ID for a generic/default window.
    private func activeDeviceProductID() -> Int? {
        TabletManager.shared.activeContext?.productID
            ?? TabletManager.shared.connectedProductIDs.first
            ?? DeviceRegistry.shared.knownTablets.first?.id
    }

    private func ensureDefaultWindow() -> SettingsWindowController {
        if let dw = defaultWindow, windows.contains(where: { $0 === dw }) {
            return dw
        }
        let pid = activeDeviceProductID()
        let (s, label) = settingsAndLabel(forProductID: pid)
        let wc = SettingsWindowController(settings: s, deviceLabel: label, productID: pid)
        wc.window?.setFrameAutosaveName("PreferencesWindow")
        defaultWindow = wc
        windows.append(wc)
        observeClose(wc)
        return wc
    }

    private func settingsAndLabel(forProductID productID: Int?) -> (TabletSettings, String) {
        if let pid = productID {
            let tm = TabletManager.shared
            let s = tm.contexts[pid]?.settings ?? TabletSettings(productID: pid)
            return (s, displayLabel(forProductID: pid))
        }
        return (settings, "MockTab")
    }

    /// Watch for window close so we can remove it from our tracking list.
    private func observeClose(_ wc: SettingsWindowController) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: wc.window,
            queue: .main
        ) { [weak self, weak wc] _ in
            guard let self, let wc else { return }
            self.windows.removeAll(where: { $0 === wc })
            if self.defaultWindow === wc { self.defaultWindow = nil }
        }
    }
}
