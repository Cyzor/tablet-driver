// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI

// Per-app behavior, split out of TabletSettings.swift: auto-switching on
// app focus, per-app override management and persistence, and the
// app-to-preset binding persistence auto-switching consumes. The override
// stored state lives on the main class body (Swift class extensions can't
// hold stored properties).
extension TabletSettings {

    // MARK: - App auto-switching

    /// Called by `AppWatcher` on every app-focus change.
    /// Switches to the bound preset for `bundleID`, or reverts to device defaults
    /// if no binding exists.  No-ops when `autoSwitchEnabled` is false or the
    /// desired preset is already active.
    func handleAppActivation(bundleID: String, appName: String) {
        guard autoSwitchEnabled else { return }
        let target = appBindings.first(where: { $0.bundleID == bundleID })
            .flatMap { b in profiles.first { $0.id == b.profileID } }
        guard target?.id != activeProfile?.id || activationSource == .manual else {
            // Same profile already active via auto-switch — just refresh the label.
            activationSource = .app(bundleID: bundleID, name: appName)
            return
        }
        if target?.id != activeProfile?.id {
            activeProfile = target
            saveActiveProfileID()
            reloadAll()
        }
        activationSource = .app(bundleID: bundleID, name: appName)
    }

    /// Binds the currently frontmost app to `preset`.
    /// Replaces any existing binding for that bundle ID.
    func bindFrontmostApp(to profile: Profile) {
        guard let app = NSWorkspace.shared.frontmostApplication,
            let bundleID = app.bundleIdentifier
        else { return }
        let name = app.localizedName ?? bundleID
        appBindings.removeAll { $0.bundleID == bundleID }
        appBindings.append(
            AppProfileBinding(
                bundleID: bundleID,
                appName: name,
                profileID: profile.id))
        saveAppBindings()
    }

    /// Removes the app binding with the given bundle ID.
    func unbindApp(bundleID: String) {
        appBindings.removeAll { $0.bundleID == bundleID }
        saveAppBindings()
    }

    // MARK: - App override management

    /// Called by AppWatcher on every app-focus change.
    /// Updates the driver override so the injector applies the right settings.
    ///
    /// The UI editing context (`activeAppOverride`, the chip-bar highlight) is
    /// never touched here — it belongs to the user and must stay exactly as
    /// they left it across app switches. Only `driverOverride` tracks the
    /// frontmost app, and `effectiveOverride` picks between the two: the
    /// chip-bar selection while MockTab is frontmost (so edits preview live),
    /// the frontmost app's override otherwise (so the injector applies the
    /// right values). Values are reloaded only when that effective source
    /// actually changes — including on return to MockTab, which swaps the
    /// published values back to the user's selection.
    func handleAppOverrideActivation(bundleID: String, appName: String) {
        let isSelf = bundleID == (Bundle.main.bundleIdentifier ?? "")
        let previousEffective = effectiveOverride?.bundleID
        isSelfFrontmost = isSelf
        driverOverride = isSelf ? nil : appOverrides.first { $0.bundleID == bundleID }
        guard effectiveOverride?.bundleID != previousEffective else { return }
        activeTool.overridePrefix = effectiveOverride.map { appOverrideKeyPrefix($0) }
        reloadAll()
    }

    /// Selects an override by bundle ID for viewing/editing in the UI without
    /// requiring the app to be frontmost.  Pass nil to return to device defaults.
    /// Changes the editing context (chip highlight, persist routing, UI panel values)
    /// but does NOT affect what the driver applies (driverOverride).
    func selectAppOverride(bundleID: String?) {
        let newOverride = bundleID.flatMap { bid in appOverrides.first { $0.bundleID == bid } }
        guard newOverride?.bundleID != activeAppOverride?.bundleID else { return }
        activeAppOverride = newOverride
        activeTool.overridePrefix = newOverride.map { appOverrideKeyPrefix($0) }
        reloadAll()
    }

    /// Registers the given application as having a per-app override for this device.
    /// Creates an empty override entry; settings modified afterwards are routed to it.
    /// No-ops if the app already has a registered override.
    func addAppOverride(bundleID: String, appName: String) {
        guard !appOverrides.contains(where: { $0.bundleID == bundleID }) else { return }
        appOverrides.append(AppOverride(bundleID: bundleID, appName: appName))
        saveAppOverrides()
        activeAppOverride = appOverrides.last
        activeTool.overridePrefix = activeAppOverride.map { appOverrideKeyPrefix($0) }
        // No reloadAll needed — the override is empty; values are unchanged.
        record("Add App Override") { [weak self] in
            self?.removeAppOverride(bundleID: bundleID)
        }
    }

    /// Moves an app override from `source` index to `destination` index.  Registers undo.
    func reorderAppOverrides(from source: Int, to destination: Int) {
        guard source != destination,
            appOverrides.indices.contains(source),
            appOverrides.indices.contains(destination)
        else { return }
        var reordered = appOverrides
        let item = reordered.remove(at: source)
        reordered.insert(item, at: destination)
        appOverrides = reordered
        saveAppOverrides()
        record("Reorder App Override") { [weak self] in
            self?.reorderAppOverrides(from: destination, to: source)
        }
    }

    /// Renames the override entry for `bundleID`.  Registers undo.
    func renameAppOverride(bundleID: String, to newName: String) {
        guard let idx = appOverrides.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        let oldName = appOverrides[idx].appName
        appOverrides[idx].appName = newName
        if activeAppOverride?.bundleID == bundleID { activeAppOverride?.appName = newName }
        saveAppOverrides()
        record("Rename App Override") { [weak self] in
            self?.renameAppOverride(bundleID: bundleID, to: oldName)
        }
    }

    /// Removes override keys for `bundleID` scoped to `keyScope`.
    /// Deletes the entire override entry when no keys remain.
    /// Pass `keyScope: nil` to remove all keys (full delete).
    /// Registers undo by snapshotting UserDefaults values before deletion.
    func removeAppOverride(bundleID: String, keyScope: Set<String>? = nil) {
        guard let override = appOverrides.first(where: { $0.bundleID == bundleID }) else { return }
        let prefix = appOverrideKeyPrefix(override)
        let keysToRemove =
            keyScope.map { override.overriddenKeys.intersection($0) }
            ?? override.overriddenKeys

        // Snapshot stored values before deleting so undo can restore them.
        var snapshot: [String: Any] = [:]
        for key in keysToRemove {
            if let value = ud.object(forKey: prefix + key) {
                snapshot[key] = value
            }
        }
        let capturedOverride = override
        let capturedPrefix = prefix

        for key in keysToRemove { ud.removeObject(forKey: prefix + key) }

        let remaining = override.overriddenKeys.subtracting(keysToRemove)
        if remaining.isEmpty {
            appOverrides.removeAll { $0.bundleID == bundleID }
        } else {
            var updated = override
            updated.overriddenKeys = remaining
            if let idx = appOverrides.firstIndex(where: { $0.bundleID == bundleID }) {
                appOverrides[idx] = updated
            }
        }
        saveAppOverrides()

        if activeAppOverride?.bundleID == bundleID {
            if remaining.isEmpty {
                activeAppOverride = nil
                activeTool.overridePrefix = nil
            } else {
                activeAppOverride = appOverrides.first { $0.bundleID == bundleID }
            }
            reloadAll()
        }

        record("Remove App Override") { [weak self] in
            guard let self else { return }
            // Restore UserDefaults values.
            for (key, value) in snapshot {
                self.ud.set(value, forKey: capturedPrefix + key)
            }
            // Re-insert the override struct.
            if !self.appOverrides.contains(where: { $0.bundleID == capturedOverride.bundleID }) {
                self.appOverrides.append(capturedOverride)
                self.saveAppOverrides()
            }
        }
    }

    /// Removes every app override for this tablet — all apps, all keys, not
    /// just the current tab's. Registers a single undo action that restores
    /// the full set (Option-click "Remove All" in the override banner).
    func removeAllAppOverrides() {
        guard !appOverrides.isEmpty else { return }
        let capturedOverrides = appOverrides

        // Snapshot every stored override value before deleting so one undo
        // can restore all of them.
        var snapshot: [String: Any] = [:]
        for override in capturedOverrides {
            let prefix = appOverrideKeyPrefix(override)
            for key in override.overriddenKeys {
                if let value = ud.object(forKey: prefix + key) {
                    snapshot[prefix + key] = value
                }
            }
        }

        for override in capturedOverrides {
            let prefix = appOverrideKeyPrefix(override)
            for key in override.overriddenKeys { ud.removeObject(forKey: prefix + key) }
        }
        appOverrides.removeAll()
        saveAppOverrides()

        if activeAppOverride != nil {
            activeAppOverride = nil
            activeTool.overridePrefix = nil
            reloadAll()
        }

        record("Remove All App Overrides") { [weak self] in
            guard let self else { return }
            for (key, value) in snapshot { self.ud.set(value, forKey: key) }
            self.appOverrides = capturedOverrides
            self.saveAppOverrides()
        }
    }

    // MARK: - App override persistence

    private var appOverridesKey: String { devicePrefix + "_appOverrides" }

    func appOverrideKeyPrefix(_ override: AppOverride) -> String {
        "\(devicePrefix)appOverride-\(override.bundleID)."
    }

    func saveAppOverrides() {
        guard let data = try? JSONEncoder().encode(appOverrides) else { return }
        ud.set(data, forKey: appOverridesKey)
    }

    func loadAppOverrides() {
        guard let data = ud.data(forKey: appOverridesKey),
            let list = try? JSONDecoder().decode([AppOverride].self, from: data)
        else {
            appOverrides = []
            return
        }
        appOverrides = list
    }

    // MARK: - App binding persistence

    private var appBindingsKey: String { devicePrefix + "_appBindings" }

    func saveAppBindings() {
        guard let data = try? JSONEncoder().encode(appBindings) else { return }
        ud.set(data, forKey: appBindingsKey)
    }

    func loadAppBindings() {
        guard let data = ud.data(forKey: appBindingsKey),
            let list = try? JSONDecoder().decode([AppProfileBinding].self, from: data)
        else {
            appBindings = []
            return
        }
        appBindings = list
    }
}
