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
import Carbon
import Foundation
import SwiftUI

/// All user-configurable settings, persisted via UserDefaults with a per-device
/// key prefix so that each tablet remembers its own configuration independently.
///
/// On first load for a given device, the legacy unprefixed keys (from before
/// per-device support) are used as a fallback, providing seamless migration.
///
/// Layer 2 — Named Presets: an optional overlay on top of device settings.
/// A preset stores only the keys it explicitly overrides; everything else falls
/// through to the device default.  Activating/deactivating a preset republishes
/// all @Published properties transparently to SwiftUI.
@MainActor
final class TabletSettings: ObservableObject {

    // MARK: - Per-device backing store

    /// Current UserDefaults key prefix, e.g. `"device-0x0357."`.
    /// Changed by `loadForDevice(_:)` when a tablet connects.
    private(set) var devicePrefix = "device-default."

    /// Suppresses UserDefaults writes during `loadForDevice()` / `activate()`.
    private var isLoading = false

    /// Suppresses undo registration when replaying undo/redo actions.
    /// Does NOT suppress `persist()` itself — undo must save restored state to UserDefaults.
    var isUndoing = false

    /// Undo manager for this device's settings, passed from SettingsWindowController.
    /// Each window gets its own independent undo stack.
    weak var undoManager: UndoManager?

    private let ud = UserDefaults.standard

    // MARK: - Per-tool settings

    /// The tool settings currently active on this device.
    /// Starts as the device-default tool; swapped by TabletManager on tool-enter.
    @Published var activeTool: ToolSettings = ToolSettings(prefix: "device-default.") {
        didSet {
            activeTool.undoManager = undoManager
            // Sync current override to the newly active tool
            activeTool.overridePrefix = activeAppOverride.map { appOverrideKeyPrefix($0) }
            activeTool.reload()

            activeTool.onOverrideKeyWritten = { [weak self] key in
                guard let self, var override = self.activeAppOverride else { return }
                guard !override.overriddenKeys.contains(key) else { return }
                override.overriddenKeys.insert(key)
                self.activeAppOverride = override
                if let idx = self.appOverrides.firstIndex(where: {
                    $0.bundleID == override.bundleID
                }) {
                    self.appOverrides[idx] = override
                }
                self.saveAppOverrides()
            }
        }
    }

    /// Cache of per-serial ToolSettings instances for this device.
    private var toolCache: [String: ToolSettings] = [:]

    /// Returns (creating if needed) the ToolSettings for the given KnownTool.id.
    /// The device-default (id "stylus"/"eraser"/"mouse") shares the devicePrefix namespace so
    /// that existing stored values are read without migration.
    func toolSettings(forID id: String, isMouse: Bool = false) -> ToolSettings {
        if let cached = toolCache[id] { return cached }
        let ts: ToolSettings
        if id == "stylus" || id == "eraser" || id == "mouse" {
            // Device-default tool: reads/writes to the same devicePrefix as TabletSettings.
            ts = ToolSettings(prefix: devicePrefix, isMouse: isMouse)
        } else {
            // Per-serial tool: reads from its own namespace, falls back to device defaults.
            ts = ToolSettings(
                prefix: "\(devicePrefix)tool-\(id).",
                fallbackPrefix: devicePrefix,
                isMouse: isMouse)
        }
        toolCache[id] = ts
        return ts
    }

    // MARK: - Active area (fractions of the full digitizer surface, 0.0..1.0)

    @Published var activeAreaX: Double = 0.0 { didSet { persist("activeAreaX", activeAreaX) } }
    @Published var activeAreaY: Double = 0.0 { didSet { persist("activeAreaY", activeAreaY) } }
    @Published var activeAreaWidth: Double = 1.0 {
        didSet { persist("activeAreaWidth", activeAreaWidth) }
    }
    @Published var activeAreaHeight: Double = 1.0 {
        didSet { persist("activeAreaHeight", activeAreaHeight) }
    }

    /// When true, the active area is cropped to match the target display's aspect ratio
    /// so the pen moves without distortion.  Enabled by default.
    @Published var proportionalMapping: Bool = true {
        didSet { persist("proportionalMapping", proportionalMapping) }
    }

    /// Physical tablet orientation — clockwise rotation from the default landscape position.
    @Published var tabletOrientation: TabletOrientation = .landscape {
        didSet { persist("tabletOrientation", tabletOrientation.rawValue) }
    }

    // MARK: - Display mapping

    /// Sentinel value for targetDisplayIndex: tablet area spans all displays.
    static let displayModeAll = -1
    /// Sentinel value for targetDisplayIndex: tablet cycles through selected displays.
    static let displayModeToggle = -2

    /// 0 = primary display, 1..N = specific display (1-indexed CGGetActiveDisplayList order).
    /// -1 = all displays (span union rect), -2 = toggle rotation.
    @Published var targetDisplayIndex: Int = 0 {
        didSet { persist("targetDisplayIndex", targetDisplayIndex) }
    }

    /// CGDirectDisplayID values (comma-separated) included in the toggle rotation.
    /// Empty string means all connected displays are included.
    @Published var toggleDisplayIDs: String = "" {
        didSet { persist("toggleDisplayIDs", toggleDisplayIDs) }
    }

    /// Typed get/set for the toggle display ID set.
    var toggleDisplayIDSet: Set<CGDirectDisplayID> {
        get {
            Set(
                toggleDisplayIDs.split(separator: ",")
                    .compactMap { CGDirectDisplayID($0.trimmingCharacters(in: .whitespaces)) })
        }
        set {
            let s = newValue.sorted().map { String($0) }.joined(separator: ",")
            toggleDisplayIDs = s
        }
    }

    // MARK: - Pressure curve

    @Published var pressureCurve: BezierCurve = .linear {
        didSet { savePressureCurve() }
    }

    // MARK: - Input smoothing

    @Published var smoothingStrength: Double = 0.0 {
        didSet { persist("smoothingStrength", smoothingStrength) }
    }
    @Published var doubleClickDistance: Double = 10.0 {
        didSet { persist("doubleClickDistance", doubleClickDistance) }
    }
    @Published var invertRotation: Bool = false {
        didSet { persist("invertRotation", invertRotation) }
    }
    @Published var relativeCursorMovement: Bool = false {
        didSet { persist("relativeCursorMovement", relativeCursorMovement) }
    }

    // MARK: - Touch ring & strips

    @Published var touchRingMode: TouchRingMode = .scroll {
        didSet { persist("touchRingMode", touchRingMode.rawValue) }
    }
    @Published var touchStrip1Mode: TouchRingMode = .scroll {
        didSet { persist("touchStrip1Mode", touchStrip1Mode.rawValue) }
    }
    @Published var touchStrip2Mode: TouchRingMode = .scroll {
        didSet { persist("touchStrip2Mode", touchStrip2Mode.rawValue) }
    }

    // MARK: - Button bindings (JSON-encoded ButtonBinding)

    @Published private var pen1Raw: String = "" { didSet { persist("penButton1Binding", pen1Raw) } }
    @Published private var pen2Raw: String = "" { didSet { persist("penButton2Binding", pen2Raw) } }
    @Published private var expressKeyRaw: String = "" {
        didSet { persist("expressKeyBindings", expressKeyRaw) }
    }
    @Published private var touchRingButtonRaw: String = "" {
        didSet { persist("touchRingButtonBinding", touchRingButtonRaw) }
    }

    var penButton1Binding: ButtonBinding {
        get { ButtonBinding.decode(pen1Raw) ?? .rightClick }
        set { pen1Raw = newValue.encoded }
    }

    var penButton2Binding: ButtonBinding {
        get { ButtonBinding.decode(pen2Raw) ?? .middleClick }
        set { pen2Raw = newValue.encoded }
    }

    var touchRingButtonBinding: ButtonBinding {
        get { ButtonBinding.decode(touchRingButtonRaw) ?? .none }
        set { touchRingButtonRaw = newValue.encoded }
    }

    var expressKeyBindings: [ButtonBinding] {
        get {
            guard !expressKeyRaw.isEmpty,
                let data = expressKeyRaw.data(using: .utf8),
                let arr = try? JSONDecoder().decode([ButtonBinding].self, from: data)
            else { return Array(repeating: .none, count: 16) }
            var res = arr
            while res.count < 16 { res.append(.none) }
            return Array(res.prefix(16))
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                let s = String(data: data, encoding: .utf8)
            else { return }
            expressKeyRaw = s
        }
    }

    // MARK: - Presets

    /// A named configuration snapshot.  `overriddenKeys` tracks which settings
    /// the preset stores; all other keys fall through to device defaults.
    struct Profile: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var name: String
        var overriddenKeys: Set<String> = []
    }

    /// A mapping from one app (by bundle ID) to a preset.
    /// Stored per device; used by app auto-switching.
    struct AppProfileBinding: Identifiable, Codable, Equatable {
        var id: String { bundleID }
        var bundleID: String
        var appName: String  // display name captured at bind time
        var profileID: UUID
    }

    /// A per-app function override.  Stores only keys that differ from the device
    /// baseline (or any active named profile).  Applied automatically whenever the
    /// registered application is frontmost — no toggle required.
    struct AppOverride: Identifiable, Codable, Equatable {
        var bundleID: String
        var appName: String
        var overriddenKeys: Set<String> = []
        var id: String { bundleID }
    }

    /// All presets saved for the current device.
    @Published var profiles: [Profile] = []

    /// The currently active preset, or `nil` when using raw device settings.
    @Published var activeProfile: (Profile?) = nil

    /// How the current preset was activated — for status display only, not persisted.
    enum ActivationSource: Equatable {
        case manual
        case app(bundleID: String, name: String)
    }
    @Published var activationSource: ActivationSource = .manual

    /// When true, switching the frontmost app automatically activates the bound preset.
    @Published var autoSwitchEnabled: Bool = false {
        didSet { persist("autoSwitchEnabled", autoSwitchEnabled) }
    }

    /// Per-app preset assignments for this device.
    @Published var appBindings: [AppProfileBinding] = []

    /// All per-app overrides registered for this device.
    @Published var appOverrides: [AppOverride] = []

    /// The override the driver is currently applying, keyed by frontmost app.
    /// Set exclusively by handleAppOverrideActivation (AppWatcher).
    /// Used by reloadAll() / load helpers so the injector reads the right values.
    private var driverOverride: AppOverride? = nil

    /// The override selected in the UI chip bar for editing.
    /// Set by selectAppOverride (chip tap) or synced from driverOverride on app switch.
    /// Controls which prefix persist() writes to and which chip is highlighted.
    @Published var activeAppOverride: AppOverride? = nil

    // MARK: - Init

    /// Creates a settings instance.  If `productID` is provided, the backing
    /// store is immediately switched to that device's namespace — useful for
    /// constructing a pre-loaded settings object inside a `DeviceContext`.
    init(productID: Int? = nil) {
        if let pid = productID {
            let hex = String(pid, radix: 16, uppercase: true)
            devicePrefix = "device-0x\(hex)."
            loadProfileList()
            loadAppBindings()
            loadAppOverrides()
        }
        activeTool = ToolSettings(prefix: devicePrefix)
        reloadAll()
    }

    // MARK: - Per-device loading

    /// Switches the settings backing store to the given device's namespace
    /// and reloads all values.  Called by TabletManager when a device connects.
    func loadForDevice(_ productID: Int) {
        let hex = String(productID, radix: 16, uppercase: true)
        devicePrefix = "device-0x\(hex)."
        toolCache.removeAll()
        activeTool = ToolSettings(prefix: devicePrefix)
        // Clear undo stack to prevent cross-device undo entries
        undoManager?.removeAllActions()
        loadProfileList()
        loadAppBindings()
        loadAppOverrides()
        driverOverride = nil
        activeAppOverride = nil
        activeTool.overridePrefix = nil
        reloadAll()
        activationSource = .manual
    }

    // MARK: - Preset management

    /// UserDefaults key prefix for a specific preset's overridden values.
    private func profileKeyPrefix(_ profile: Profile) -> String {
        "\(devicePrefix)preset-\(profile.id.uuidString)."
    }

    /// Activates `preset` (or pass `nil` to revert to raw device settings).
    /// Marks the source as `.manual` and republishes all settings values.
    func activate(_ preset: (Profile?)) {
        activeProfile = preset
        saveActiveProfileID()
        reloadAll()
        activationSource = .manual
    }

    /// Snapshots the current in-memory settings into a new preset, saves it,
    /// and makes it active.
    func saveAsPreset(name: String) {
        var profile = Profile(name: name)
        let prefix = profileKeyPrefix(profile)

        // Copy every current live value into the preset namespace.
        ud.set(activeAreaX, forKey: prefix + "activeAreaX")
        ud.set(activeAreaY, forKey: prefix + "activeAreaY")
        ud.set(activeAreaWidth, forKey: prefix + "activeAreaWidth")
        ud.set(activeAreaHeight, forKey: prefix + "activeAreaHeight")
        ud.set(proportionalMapping, forKey: prefix + "proportionalMapping")
        ud.set(targetDisplayIndex, forKey: prefix + "targetDisplayIndex")
        ud.set(toggleDisplayIDs, forKey: prefix + "toggleDisplayIDs")
        ud.set(smoothingStrength, forKey: prefix + "smoothingStrength")
        ud.set(doubleClickDistance, forKey: prefix + "doubleClickDistance")
        ud.set(pen1Raw, forKey: prefix + "penButton1Binding")
        ud.set(pen2Raw, forKey: prefix + "penButton2Binding")
        ud.set(expressKeyRaw, forKey: prefix + "expressKeyBindings")
        ud.set(touchRingButtonRaw, forKey: prefix + "touchRingButtonBinding")
        ud.set(touchRingMode.rawValue, forKey: prefix + "touchRingMode")
        ud.set(touchStrip1Mode.rawValue, forKey: prefix + "touchStrip1Mode")
        ud.set(touchStrip2Mode.rawValue, forKey: prefix + "touchStrip2Mode")
        if let data = try? JSONEncoder().encode(pressureCurve) {
            ud.set(data, forKey: prefix + "pressureCurve")
        }

        profile.overriddenKeys = [
            "activeAreaX", "activeAreaY", "activeAreaWidth", "activeAreaHeight",
            "proportionalMapping", "targetDisplayIndex", "toggleDisplayIDs",
            "smoothingStrength", "doubleClickDistance", "penButton1Binding", "penButton2Binding",
            "expressKeyBindings", "touchRingButtonBinding", "touchRingMode",
            "touchStrip1Mode", "touchStrip2Mode", "pressureCurve",
        ]

        profiles.append(profile)
        saveProfileList()
        activeProfile = profile
        saveActiveProfileID()
    }

    /// Creates a new preset from a parsed import dict (keys are the same internal
    /// key names used by `saveAsPreset`, values are already in UserDefaults-ready form).
    /// The preset is appended but NOT activated.  Returns the new preset.
    @discardableResult
    func importProfile(name: String, from values: [String: Any]) -> Profile {
        var profile = Profile(name: name)
        let prefix = profileKeyPrefix(profile)
        var writtenKeys = Set<String>()
        for (key, value) in values {
            ud.set(value, forKey: prefix + key)
            writtenKeys.insert(key)
        }
        profile.overriddenKeys = writtenKeys
        profiles.append(profile)
        saveProfileList()
        return profile
    }

    /// Returns a preset name that doesn't collide with any existing preset name.
    /// If `name` is already taken, appends " (2)", " (3)", etc.
    func uniqueProfileName(_ name: String) -> String {
        let existing = Set(profiles.map(\.name))
        guard existing.contains(name) else { return name }
        var n = 2
        while existing.contains("\(name) (\(n))") { n += 1 }
        return "\(name) (\(n))"
    }

    /// Renames `preset` to `newName`.
    func renamePreset(_ profile: Profile, to newName: String) {
        guard let idx = profiles.firstIndex(of: profile) else { return }
        profiles[idx].name = newName
        if activeProfile?.id == profile.id { activeProfile?.name = newName }
        saveProfileList()
    }

    /// Deletes `preset` and all its stored values.
    /// Removes any app bindings pointing to it.  If it was active, reverts to device defaults.
    func deletePreset(_ profile: Profile) {
        let prefix = profileKeyPrefix(profile)
        let allKeys = [
            "activeAreaX", "activeAreaY", "activeAreaWidth", "activeAreaHeight",
            "proportionalMapping", "targetDisplayIndex", "toggleDisplayIDs",
            "smoothingStrength", "doubleClickDistance", "penButton1Binding", "penButton2Binding",
            "expressKeyBindings", "touchRingButtonBinding", "touchRingMode",
            "touchStrip1Mode", "touchStrip2Mode", "pressureCurve",
        ]
        for key in allKeys { ud.removeObject(forKey: prefix + key) }
        profiles.removeAll { $0.id == profile.id }
        // Remove app bindings that referenced this profile.
        let before = appBindings.count
        appBindings.removeAll { $0.profileID == profile.id }
        if appBindings.count != before { saveAppBindings() }
        if activeProfile?.id == profile.id {
            activate(nil)
        } else {
            saveProfileList()
        }
    }

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
    /// When MockTab itself is frontmost (the user is editing settings), only
    /// `driverOverride` is updated and the UI editing context is left alone —
    /// `activeAppOverride`, `activeTool.overridePrefix`, and all @Published values
    /// keep their current state so the user can freely edit any chip without
    /// losing their selection when they switch between apps.
    ///
    /// When a drawing app becomes frontmost, the UI chip bar is synced to the
    /// driver's active app and settings are reloaded for the injector.
    func handleAppOverrideActivation(bundleID: String, appName: String) {
        let isSelf = bundleID == (Bundle.main.bundleIdentifier ?? "")
        let newOverride = isSelf ? nil : appOverrides.first { $0.bundleID == bundleID }
        guard newOverride?.bundleID != driverOverride?.bundleID else { return }
        driverOverride = newOverride
        guard !isSelf else { return }
        // Drawing app became frontmost — sync UI chip bar to driver state and reload.
        activeAppOverride = driverOverride
        activeTool.overridePrefix = driverOverride.map { appOverrideKeyPrefix($0) }
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

    // MARK: - App override persistence

    private var appOverridesKey: String { devicePrefix + "_appOverrides" }

    private func appOverrideKeyPrefix(_ override: AppOverride) -> String {
        "\(devicePrefix)appOverride-\(override.bundleID)."
    }

    func saveAppOverrides() {
        guard let data = try? JSONEncoder().encode(appOverrides) else { return }
        ud.set(data, forKey: appOverridesKey)
    }

    private func loadAppOverrides() {
        guard let data = ud.data(forKey: appOverridesKey),
            let list = try? JSONDecoder().decode([AppOverride].self, from: data)
        else {
            appOverrides = []
            return
        }
        appOverrides = list
    }

    // MARK: - Preset persistence

    private var profileListKey: String { devicePrefix + "_presets" }
    private var activeProfileIDKey: String { devicePrefix + "_activeProfile" }

    private func loadProfileList() {
        guard let data = ud.data(forKey: profileListKey),
            let list = try? JSONDecoder().decode([Profile].self, from: data)
        else {
            profiles = []
            activeProfile = nil
            return
        }
        profiles = list
        if let uuidStr = ud.string(forKey: activeProfileIDKey),
            let uuid = UUID(uuidString: uuidStr),
            let match = list.first(where: { $0.id == uuid })
        {
            activeProfile = match
        } else {
            activeProfile = nil
        }
    }

    private func saveProfileList() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        ud.set(data, forKey: profileListKey)
    }

    private func saveActiveProfileID() {
        if let id = activeProfile?.id.uuidString {
            ud.set(id, forKey: activeProfileIDKey)
        } else {
            ud.removeObject(forKey: activeProfileIDKey)
        }
    }

    private var appBindingsKey: String { devicePrefix + "_appBindings" }

    private func saveAppBindings() {
        guard let data = try? JSONEncoder().encode(appBindings) else { return }
        ud.set(data, forKey: appBindingsKey)
    }

    private func loadAppBindings() {
        guard let data = ud.data(forKey: appBindingsKey),
            let list = try? JSONDecoder().decode([AppProfileBinding].self, from: data)
        else {
            appBindings = []
            return
        }
        appBindings = list
    }

    // MARK: - Undo/Redo support

    /// Snapshot of active area for undo/redo coalescing
    struct AreaSnapshot: Equatable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
    }

    /// Registers an undo action with the current undoManager.
    /// Guards against registration during undo replay to prevent infinite loops.
    /// The undo block is responsible for restoring state; persist() will fire normally.
    func record(_ actionName: String, undo: @escaping () -> Void) {
        guard let um = undoManager, !isUndoing else { return }
        um.setActionName(actionName)
        um.registerUndo(withTarget: self) { [weak self] target in
            guard let self else { return }
            self.isUndoing = true
            undo()
            self.isUndoing = false
        }
    }

    /// Records a coalesced tablet area drag (one undo entry per completed gesture, not per frame).
    /// Call this once in DragGesture.onEnded with a snapshot captured at drag-start.
    func recordAreaDrag(before snap: AreaSnapshot) {
        record("Tablet Area") { [weak self] in
            guard let self else { return }
            let after = AreaSnapshot(
                x: self.activeAreaX, y: self.activeAreaY,
                w: self.activeAreaWidth, h: self.activeAreaHeight)
            self.activeAreaX = snap.x
            self.activeAreaY = snap.y
            self.activeAreaWidth = snap.w
            self.activeAreaHeight = snap.h
            self.recordAreaDrag(before: after)  // re-registers as redo
        }
    }

    // MARK: - Reload

    /// Reloads every setting from UserDefaults using the current `devicePrefix`
    /// and `activeProfile`.  Falls back to legacy unprefixed keys, then to
    /// compile-time defaults.
    private func reloadAll() {
        isLoading = true
        activeAreaX = loadDouble("activeAreaX", default: 0.0)
        activeAreaY = loadDouble("activeAreaY", default: 0.0)
        activeAreaWidth = loadDouble("activeAreaWidth", default: 1.0)
        activeAreaHeight = loadDouble("activeAreaHeight", default: 1.0)
        proportionalMapping = loadBool("proportionalMapping", default: true)
        tabletOrientation =
            TabletOrientation(rawValue: loadInt("tabletOrientation", default: 0)) ?? .landscape
        targetDisplayIndex = loadInt("targetDisplayIndex", default: 0)
        toggleDisplayIDs = loadString("toggleDisplayIDs", default: "")
        smoothingStrength = loadDouble("smoothingStrength", default: 0.0)
        doubleClickDistance = loadDouble("doubleClickDistance", default: 10.0)
        pen1Raw = loadString("penButton1Binding", default: "")
        pen2Raw = loadString("penButton2Binding", default: "")
        expressKeyRaw = loadString("expressKeyBindings", default: "")
        touchRingButtonRaw = loadString("touchRingButtonBinding", default: "")
        touchRingMode =
            TouchRingMode(
                rawValue: loadString("touchRingMode", default: TouchRingMode.scroll.rawValue))
            ?? .scroll
        touchStrip1Mode =
            TouchRingMode(
                rawValue: loadString("touchStrip1Mode", default: TouchRingMode.scroll.rawValue))
            ?? .scroll
        touchStrip2Mode =
            TouchRingMode(
                rawValue: loadString("touchStrip2Mode", default: TouchRingMode.scroll.rawValue))
            ?? .scroll
        autoSwitchEnabled = loadBool("autoSwitchEnabled", default: false)
        invertRotation = loadBool("invertRotation", default: false)
        relativeCursorMovement = loadBool("relativeCursorMovement", default: false)
        loadPressureCurve()

        // Sync resolved pressure values and app overrides into activeTool so PenFeel
        // and ButtonMappingView reflect the active override or profile.
        let op = activeAppOverride.map { appOverrideKeyPrefix($0) }
        activeTool.overridePrefix = op
        activeTool.reload()
        activeTool.applyExternalValues(
            pressureCurve: pressureCurve, smoothingStrength: smoothingStrength)

        // Also propagate to all cached per-tool instances so the injector (which uses
        // activeToolSettings — a cached ToolSettings — not activeTool) picks up the change.
        for tool in toolCache.values where tool !== activeTool {
            tool.overridePrefix = op
            tool.reload()
            tool.applyExternalValues(
                pressureCurve: pressureCurve, smoothingStrength: smoothingStrength)
        }
        isLoading = false
    }

    // MARK: - Persistence helpers

    /// Routes a write to the active app override, then profile, then device namespace.
    /// Marks the key as overridden in whichever layer receives the write.
    /// No-ops while `isLoading` to avoid echoing values back during reload.
    private func persist(_ key: String, _ value: Any) {
        guard !isLoading else { return }
        if var override = activeAppOverride {
            ud.set(value, forKey: appOverrideKeyPrefix(override) + key)
            guard !override.overriddenKeys.contains(key) else { return }
            override.overriddenKeys.insert(key)
            activeAppOverride = override
            if let idx = appOverrides.firstIndex(where: { $0.bundleID == override.bundleID }) {
                appOverrides[idx] = override
            }
            saveAppOverrides()
        } else if var preset = activeProfile {
            ud.set(value, forKey: profileKeyPrefix(preset) + key)
            guard !preset.overriddenKeys.contains(key) else { return }
            preset.overriddenKeys.insert(key)
            activeProfile = preset
            if let idx = profiles.firstIndex(where: { $0.id == preset.id }) {
                profiles[idx] = preset
            }
            saveProfileList()
        } else {
            ud.set(value, forKey: devicePrefix + key)
        }
    }

    // MARK: - Load helpers

    // Fallback chain: active app override (if key is overridden)
    //                 → active profile (if key is overridden)
    //                 → device prefix → legacy unprefixed key → compile-time default.

    private func loadDouble(_ key: String, default d: Double) -> Double {
        // When user is editing a non-active app, show that app's values in the UI.
        // Otherwise show the driver's active values.
        let sourceOverride =
            (activeAppOverride?.bundleID != driverOverride?.bundleID)
            ? activeAppOverride
            : driverOverride
        if let override = sourceOverride, override.overriddenKeys.contains(key),
            ud.object(forKey: appOverrideKeyPrefix(override) + key) != nil
        {
            return ud.double(forKey: appOverrideKeyPrefix(override) + key)
        }
        if let preset = activeProfile, preset.overriddenKeys.contains(key),
            ud.object(forKey: profileKeyPrefix(preset) + key) != nil
        {
            return ud.double(forKey: profileKeyPrefix(preset) + key)
        }
        if ud.object(forKey: devicePrefix + key) != nil {
            return ud.double(forKey: devicePrefix + key)
        }
        if ud.object(forKey: key) != nil { return ud.double(forKey: key) }
        return d
    }

    private func loadBool(_ key: String, default d: Bool) -> Bool {
        let sourceOverride =
            (activeAppOverride?.bundleID != driverOverride?.bundleID)
            ? activeAppOverride
            : driverOverride
        if let override = sourceOverride, override.overriddenKeys.contains(key),
            ud.object(forKey: appOverrideKeyPrefix(override) + key) != nil
        {
            return ud.bool(forKey: appOverrideKeyPrefix(override) + key)
        }
        if let preset = activeProfile, preset.overriddenKeys.contains(key),
            ud.object(forKey: profileKeyPrefix(preset) + key) != nil
        {
            return ud.bool(forKey: profileKeyPrefix(preset) + key)
        }
        if ud.object(forKey: devicePrefix + key) != nil {
            return ud.bool(forKey: devicePrefix + key)
        }
        if ud.object(forKey: key) != nil { return ud.bool(forKey: key) }
        return d
    }

    private func loadInt(_ key: String, default d: Int) -> Int {
        let sourceOverride =
            (activeAppOverride?.bundleID != driverOverride?.bundleID)
            ? activeAppOverride
            : driverOverride
        if let override = sourceOverride, override.overriddenKeys.contains(key),
            ud.object(forKey: appOverrideKeyPrefix(override) + key) != nil
        {
            return ud.integer(forKey: appOverrideKeyPrefix(override) + key)
        }
        if let preset = activeProfile, preset.overriddenKeys.contains(key),
            ud.object(forKey: profileKeyPrefix(preset) + key) != nil
        {
            return ud.integer(forKey: profileKeyPrefix(preset) + key)
        }
        if ud.object(forKey: devicePrefix + key) != nil {
            return ud.integer(forKey: devicePrefix + key)
        }
        if ud.object(forKey: key) != nil { return ud.integer(forKey: key) }
        return d
    }

    private func loadString(_ key: String, default d: String) -> String {
        let sourceOverride =
            (activeAppOverride?.bundleID != driverOverride?.bundleID)
            ? activeAppOverride
            : driverOverride
        if let override = sourceOverride, override.overriddenKeys.contains(key),
            let v = ud.string(forKey: appOverrideKeyPrefix(override) + key)
        {
            return v
        }
        if let preset = activeProfile, preset.overriddenKeys.contains(key) {
            if let v = ud.string(forKey: profileKeyPrefix(preset) + key) { return v }
        }
        if let v = ud.string(forKey: devicePrefix + key) { return v }
        if let v = ud.string(forKey: key) { return v }
        return d
    }

    // MARK: - Pressure curve persistence

    private func savePressureCurve() {
        guard !isLoading else { return }
        guard let data = try? JSONEncoder().encode(pressureCurve) else { return }
        if var override = activeAppOverride {
            ud.set(data, forKey: appOverrideKeyPrefix(override) + "pressureCurve")
            guard !override.overriddenKeys.contains("pressureCurve") else { return }
            override.overriddenKeys.insert("pressureCurve")
            activeAppOverride = override
            if let idx = appOverrides.firstIndex(where: { $0.bundleID == override.bundleID }) {
                appOverrides[idx] = override
            }
            saveAppOverrides()
        } else if var preset = activeProfile {
            ud.set(data, forKey: profileKeyPrefix(preset) + "pressureCurve")
            guard !preset.overriddenKeys.contains("pressureCurve") else { return }
            preset.overriddenKeys.insert("pressureCurve")
            activeProfile = preset
            if let idx = profiles.firstIndex(where: { $0.id == preset.id }) {
                profiles[idx] = preset
            }
            saveProfileList()
        } else {
            ud.set(data, forKey: devicePrefix + "pressureCurve")
        }
    }

    private func loadPressureCurve() {
        let data: Data?
        let sourceOverride =
            (activeAppOverride?.bundleID != driverOverride?.bundleID)
            ? activeAppOverride
            : driverOverride
        if let override = sourceOverride, override.overriddenKeys.contains("pressureCurve") {
            data =
                ud.data(forKey: appOverrideKeyPrefix(override) + "pressureCurve")
                ?? ud.data(forKey: devicePrefix + "pressureCurve")
                ?? ud.data(forKey: "pressureCurve")
        } else if let preset = activeProfile, preset.overriddenKeys.contains("pressureCurve") {
            data =
                ud.data(forKey: profileKeyPrefix(preset) + "pressureCurve")
                ?? ud.data(forKey: devicePrefix + "pressureCurve")
                ?? ud.data(forKey: "pressureCurve")
        } else {
            data =
                ud.data(forKey: devicePrefix + "pressureCurve")
                ?? ud.data(forKey: "pressureCurve")
        }
        guard let data,
            let curve = try? JSONDecoder().decode(BezierCurve.self, from: data)
        else { return }
        pressureCurve = curve
    }

    // MARK: - Reset

    func resetToDefaults() {
        activeAreaX = 0
        activeAreaY = 0
        activeAreaWidth = 1
        activeAreaHeight = 1
        proportionalMapping = true
        tabletOrientation = .landscape
        targetDisplayIndex = 0
        toggleDisplayIDs = ""
        pressureCurve = .linear
        smoothingStrength = 0.0
        doubleClickDistance = 10.0
        pen1Raw = ""
        pen2Raw = ""
        expressKeyRaw = ""
        touchRingButtonRaw = ""
        touchRingMode = .scroll
    }

    // MARK: - Full state snapshots (for preset activation undo)

    /// Captures all current in-memory setting values for undo/redo of structural
    /// operations like preset activation that republish all settings at once.
    struct FullSnapshot: Equatable {
        var activeAreaX: Double
        var activeAreaY: Double
        var activeAreaWidth: Double
        var activeAreaHeight: Double
        var proportionalMapping: Bool
        var tabletOrientation: TabletOrientation
        var targetDisplayIndex: Int
        var toggleDisplayIDs: String
        var smoothingStrength: Double
        var doubleClickDistance: Double
        var pressureCurve: BezierCurve
        var pen1Raw: String
        var pen2Raw: String
        var expressKeyRaw: String
        var touchRingButtonRaw: String
        var touchRingMode: TouchRingMode
        var touchStrip1Mode: TouchRingMode
        var touchStrip2Mode: TouchRingMode
        var autoSwitchEnabled: Bool
    }

    /// Creates a snapshot of all current settings values.
    func snapshot() -> FullSnapshot {
        FullSnapshot(
            activeAreaX: activeAreaX,
            activeAreaY: activeAreaY,
            activeAreaWidth: activeAreaWidth,
            activeAreaHeight: activeAreaHeight,
            proportionalMapping: proportionalMapping,
            tabletOrientation: tabletOrientation,
            targetDisplayIndex: targetDisplayIndex,
            toggleDisplayIDs: toggleDisplayIDs,
            smoothingStrength: smoothingStrength,
            doubleClickDistance: doubleClickDistance,
            pressureCurve: pressureCurve,
            pen1Raw: pen1Raw,
            pen2Raw: pen2Raw,
            expressKeyRaw: expressKeyRaw,
            touchRingButtonRaw: touchRingButtonRaw,
            touchRingMode: touchRingMode,
            touchStrip1Mode: touchStrip1Mode,
            touchStrip2Mode: touchStrip2Mode,
            autoSwitchEnabled: autoSwitchEnabled
        )
    }

    /// Applies a previously captured snapshot, registering undo for the prior state.
    /// Used for preset activation, deletion, and other structural operations.
    func restoreSnapshot(_ snap: FullSnapshot, actionName: String) {
        record(actionName) { [weak self] in
            guard let self else { return }
            let current = self.snapshot()
            self.applySnapshot(snap)
            self.restoreSnapshot(current, actionName: actionName)
        }
    }

    /// Restores all settings from a snapshot without triggering undo registration.
    /// This is the actual work function called during undo/redo replay.
    private func applySnapshot(_ snap: FullSnapshot) {
        activeAreaX = snap.activeAreaX
        activeAreaY = snap.activeAreaY
        activeAreaWidth = snap.activeAreaWidth
        activeAreaHeight = snap.activeAreaHeight
        proportionalMapping = snap.proportionalMapping
        tabletOrientation = snap.tabletOrientation
        targetDisplayIndex = snap.targetDisplayIndex
        toggleDisplayIDs = snap.toggleDisplayIDs
        smoothingStrength = snap.smoothingStrength
        doubleClickDistance = snap.doubleClickDistance
        pressureCurve = snap.pressureCurve
        pen1Raw = snap.pen1Raw
        pen2Raw = snap.pen2Raw
        expressKeyRaw = snap.expressKeyRaw
        touchRingButtonRaw = snap.touchRingButtonRaw
        touchRingMode = snap.touchRingMode
        touchStrip1Mode = snap.touchStrip1Mode
        touchStrip2Mode = snap.touchStrip2Mode
        autoSwitchEnabled = snap.autoSwitchEnabled
    }

    // MARK: - First-run defaults

    /// Writes sensible express key defaults for this device if the user has never
    /// configured them (i.e. no stored value exists in UserDefaults).
    ///
    /// Physical key order for PTH-660/860 (8-key Intuos Pro layout, bits 0–7):
    ///   The bitmask assignment vs. physical position is confirmed by live
    ///   capture.  Defaults chosen for cross-app utility in digital art:
    ///     0  ⌘Z    Undo          (universal)
    ///     1  ⌘⇧Z   Redo          (universal)
    ///     2  Space  Pan/scroll    (Photoshop, Krita, Illustrator, Affinity)
    ///     3  ⌥      Eyedropper   (all major painting apps; hold for sample)
    ///     4  ⌃      Control      (brush-size modifier in Krita / Blender)
    ///     5–7  —    None          (leave open for user assignment)
    func applyExpressKeyDefaults() {
        guard ud.string(forKey: devicePrefix + "expressKeyBindings") == nil else { return }
        // Default express key bindings: keys 1-4 are modifier keys (⌘ ⌥ ⌃ ⇧).
        // Rest are unbound (.none).
        // 16-entry layout for dual-ring Cintiq devices (indices 0–15).
        // Indices 0–2  = left  toggle buttons (near ring), 3–7  = left  express keys.
        // Indices 8–10 = right toggle buttons (near ring), 11–15 = right express keys.
        // Devices with only 8 buttons use indices 0–7; the upper 8 entries are ignored.
        expressKeyBindings = [
            ButtonBinding(modifierOnly: .command),  // 0  left key 1 → ⌘
            ButtonBinding(modifierOnly: .option),  // 1  left key 2 → ⌥
            ButtonBinding(modifierOnly: .control),  // 2  left key 3 → ⌃
            ButtonBinding(modifierOnly: .shift),  // 3  left key 4 → ⇧
            .none, .none, .none, .none,  // 4–7 left keys 5–8
            ButtonBinding(modifierOnly: .command),  // 8  right key 1 (mirror) → ⌘
            ButtonBinding(modifierOnly: .option),  // 9  right key 2 (mirror) → ⌥
            ButtonBinding(modifierOnly: .control),  // 10 right key 3 (mirror) → ⌃
            ButtonBinding(modifierOnly: .shift),  // 11 right key 4 (mirror) → ⇧
            .none, .none, .none, .none,  // 12–15 right keys 5–8
        ]
    }

    // MARK: - Profile import / export

    /// Captures the current device and active-tool settings as a portable `Profile`.
    ///
    /// The snapshot reflects what is actually in use at call time: area, display,
    /// active-tool pressure curve and button bindings, touch ring mode.
    /// It does not include express-key bindings (Phase 2) or per-serial overrides.
    func exportCurrentAsProfile(name: String, deviceName: String) -> TabletSnapshot {
        TabletSnapshot(
            name: name,
            deviceModel: deviceName,
            tabletAreaX: activeAreaX,
            tabletAreaY: activeAreaY,
            tabletAreaWidth: activeAreaWidth,
            tabletAreaHeight: activeAreaHeight,
            proportionalMapping: proportionalMapping,
            targetDisplayIndex: targetDisplayIndex,
            pressureCurve: activeTool.pressureCurve,
            smoothingStrength: activeTool.smoothingStrength,
            penButton1: activeTool.penButton1Binding,
            penButton2: activeTool.penButton2Binding,
            tipBinding: activeTool.tipBinding,
            eraserBinding: activeTool.eraserBinding,
            touchRingMode: touchRingMode.rawValue,
            touchRingButtonBinding: touchRingButtonBinding
        )
    }

    /// Applies a `Profile` to the current device, replacing all covered settings.
    ///
    /// Settings not represented in `Profile` (express keys, double-click distance,
    /// strip modes) are left unchanged.  An unrecognised `touchRingMode` string
    /// is silently ignored so future format additions don't break older builds.
    func importSnapshot(_ profile: TabletSnapshot) {
        activeAreaX = profile.tabletAreaX
        activeAreaY = profile.tabletAreaY
        activeAreaWidth = profile.tabletAreaWidth
        activeAreaHeight = profile.tabletAreaHeight
        proportionalMapping = profile.proportionalMapping
        targetDisplayIndex = profile.targetDisplayIndex
        activeTool.pressureCurve = profile.pressureCurve
        activeTool.smoothingStrength = profile.smoothingStrength
        activeTool.penButton1Binding = profile.penButton1
        activeTool.penButton2Binding = profile.penButton2
        activeTool.tipBinding = profile.tipBinding
        activeTool.eraserBinding = profile.eraserBinding
        if let mode = TouchRingMode(rawValue: profile.touchRingMode) {
            touchRingMode = mode
        }
        touchRingButtonBinding = profile.touchRingButtonBinding
    }

    /// Applies pen-display defaults for the first connection of a Cintiq-class device.
    ///
    /// Locates the display matching `width × height` in the active display list
    /// (CGGetActiveDisplayList order, 1-based index) and sets `targetDisplayIndex`
    /// to it.  Disables `proportionalMapping` because the digitizer covers the
    /// exact screen surface — proportional correction would introduce edge dead zones.
    ///
    /// Call only when the device has no stored settings yet (first-ever connection).
    func applyPenDisplayDefaults(width: Int, height: Int) {
        proportionalMapping = false
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return }
        for (i, id) in ids.enumerated()
        where CGDisplayPixelsWide(id) == width && CGDisplayPixelsHigh(id) == height {
            targetDisplayIndex = i + 1
            return
        }
    }
}

// MARK: - TouchRingMode

/// What the touch ring / scroll ring produces when turned.
enum TouchRingMode: String, Codable, CaseIterable {
    /// Emit scroll-wheel events (default).
    case scroll
    /// Do nothing.
    case off

    var displayLabel: String {
        switch self {
        case .scroll:
            return String(localized: "Scroll", comment: "Touch ring mode: scroll wheel output")
        case .off: return String(localized: "Off", comment: "Touch ring mode: disabled")
        }
    }
}

// MARK: - TabletOrientation

/// Physical rotation of the tablet relative to the default landscape position.
/// The raw value is the number of 90° clockwise quarter-turns.
enum TabletOrientation: Int, CaseIterable {
    case landscape = 0  // default  — USB port at bottom
    case portrait = 1  // 90° CCW  — USB port at right
    case landscapeFlipped = 2  // 180°     — USB port at top
    case portraitFlipped = 3  // 90° CW   — USB port at left

    /// Clockwise rotation angle in radians used for Canvas transforms.
    var rotationAngle: Double {
        switch self {
        case .landscape: return 0
        case .portrait: return 3 * .pi / 2  // 270° (swapped from 90°)
        case .landscapeFlipped: return .pi  // 180°
        case .portraitFlipped: return .pi / 2  // 90° (swapped from 270°)
        }
    }

    /// Whether this orientation swaps the X and Y hardware axes.
    var swapsAxes: Bool { self == .portrait || self == .portraitFlipped }

    var label: String {
        switch self {
        case .landscape:
            return String(localized: "Landscape", comment: "Tablet orientation: default landscape")
        case .portrait:
            return String(localized: "Portrait", comment: "Tablet orientation: rotated 90° CCW")
        case .landscapeFlipped:
            return String(
                localized: "Landscape Flipped", comment: "Tablet orientation: rotated 180°")
        case .portraitFlipped:
            return String(
                localized: "Portrait Flipped", comment: "Tablet orientation: rotated 90° CW")
        }
    }
}

// MARK: - ButtonBinding

/// A hardware button assignment: a predefined click action, a recorded key combo, or nothing.
struct ButtonBinding: Codable, Equatable {

    enum Kind: String, Codable {
        case none, leftClick, rightClick, middleClick, eraser, keyCombo, displayToggle, doubleClick,
            spacebar
    }

    var kind: Kind = .none
    var keyCode: UInt16 = 0
    var modifierFlags: UInt64 = 0  // CGEventFlags raw value
    var keyLabel: String = ""  // display string for the key (e.g. "Z", "↩", "Space")

    // MARK: Presets

    static let none = ButtonBinding()
    static let leftClick = ButtonBinding(kind: .leftClick)
    static let rightClick = ButtonBinding(kind: .rightClick)
    static let middleClick = ButtonBinding(kind: .middleClick)
    static let eraser = ButtonBinding(kind: .eraser)
    static let doubleClick = ButtonBinding(kind: .doubleClick)
    static let spacebar = ButtonBinding(kind: .spacebar)

    // MARK: Init

    init(
        kind: Kind = .none, keyCode: UInt16 = 0,
        modifierFlags: UInt64 = 0, keyLabel: String = ""
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.keyLabel = keyLabel
    }

    /// Build a modifier-only binding (no base key).
    /// `keyLabel` is left empty — InputInjector uses this as the signal to post a
    /// `.flagsChanged` CGEvent rather than a `keyDown/Up`.
    /// `keyCode` is set to the canonical left-side virtualKey of the primary modifier
    /// so the flagsChanged event carries a sensible keycode (55 ⌘, 56 ⇧, 58 ⌥, 59 ⌃).
    init(modifierOnly flags: NSEvent.ModifierFlags) {
        kind = .keyCombo
        keyLabel = ""
        var f = CGEventFlags()
        if flags.contains(.command) { f.insert(.maskCommand) }
        if flags.contains(.shift) { f.insert(.maskShift) }
        if flags.contains(.option) { f.insert(.maskAlternate) }
        if flags.contains(.control) { f.insert(.maskControl) }
        modifierFlags = f.rawValue
        if flags.contains(.command) {
            keyCode = 55
        }  // kVK_Command
        else if flags.contains(.shift) {
            keyCode = 56
        }  // kVK_Shift
        else if flags.contains(.option) {
            keyCode = 58
        }  // kVK_Option
        else if flags.contains(.control) {
            keyCode = 59
        }  // kVK_Control
        else {
            keyCode = 0
        }
    }

    /// Build a key-combo binding from a captured NSEvent keyDown.
    init(fromKey event: NSEvent) {
        kind = .keyCombo
        keyCode = event.keyCode
        // Map NSEvent.ModifierFlags → CGEventFlags raw value.
        let ns = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var f = CGEventFlags()
        if ns.contains(.command) { f.insert(.maskCommand) }
        if ns.contains(.shift) { f.insert(.maskShift) }
        if ns.contains(.option) { f.insert(.maskAlternate) }
        if ns.contains(.control) { f.insert(.maskControl) }
        modifierFlags = f.rawValue
        // Pass the full modifier flags so UCKeyTranslate applies any layout-switching
        // modifier behaviour (e.g. Dvorak Qwerty-Command shows QWERTY char with ⌘).
        keyLabel = ButtonBinding.charLabel(keyCode: event.keyCode, modifiers: ns)
    }

    // MARK: Mouse button helper

    /// The CGMouseButton this binding maps to, if it's a click action.
    /// Returns nil for keystroke or .none bindings.
    var mouseButton: CGMouseButton? {
        switch kind {
        case .leftClick: return .left
        case .rightClick: return .right
        case .middleClick: return .center
        default: return nil
        }
    }

    // MARK: Display

    var displayLabel: String {
        switch kind {
        case .none: return String(localized: "None", comment: "Button action: no action")
        case .leftClick:
            return String(localized: "Left Click", comment: "Button action: left mouse click")
        case .rightClick:
            return String(localized: "Right Click", comment: "Button action: right mouse click")
        case .middleClick:
            return String(localized: "Middle Click", comment: "Button action: middle mouse click")
        case .eraser:
            return String(localized: "Eraser", comment: "Button action: switch to eraser tool")
        case .displayToggle:
            return String(
                localized: "Toggle Display", comment: "Button action: cycle through displays")
        case .doubleClick:
            return String(localized: "Double Click", comment: "Button action: double-click")
        case .spacebar: return String(localized: "Spacebar", comment: "Button action: spacebar key")
        case .keyCombo:
            let f = CGEventFlags(rawValue: modifierFlags)
            var s = ""
            if f.contains(.maskControl) { s += "⌃" }
            if f.contains(.maskAlternate) { s += "⌥" }
            if f.contains(.maskShift) { s += "⇧" }
            if f.contains(.maskCommand) { s += "⌘" }
            return s + keyLabel
        }
    }

    // MARK: JSON helpers

    var encoded: String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? ""
    }

    static func decode(_ s: String) -> ButtonBinding? {
        guard !s.isEmpty, let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ButtonBinding.self, from: data)
    }

    /// Reconstructs a ButtonBinding from a human-readable display label produced
    /// by `displayLabel`.  Used by the profile importer to reverse the export encoding.
    ///
    /// Simple cases ("Right Click", "Toggle Display", etc.) are decoded exactly.
    /// Key combos ("⌘Z", "⌃⇧F5", etc.) are parsed by stripping modifier prefixes
    /// and then scanning the `charLabel` reverse-table for a matching keyCode.
    /// Unknown labels fall back to `.none` so a bad value doesn't hard-fail an import.
    static func fromDisplayLabel(_ label: String) -> ButtonBinding {
        switch label {
        case "None": return .none
        case "Left Click": return .leftClick
        case "Right Click": return .rightClick
        case "Middle Click": return .middleClick
        case "Eraser": return .eraser
        case "Toggle Display": return ButtonBinding(kind: .displayToggle)
        default:
            return parseKeyComboLabel(label) ?? .none
        }
    }

    /// Parses modifier-prefix strings like "⌘Z", "⌃⇧F5", "⌥Space" into a
    /// `.keyCombo` ButtonBinding.  Returns nil if the label can't be decoded.
    private static func parseKeyComboLabel(_ label: String) -> ButtonBinding? {
        var remaining = label
        var nsFlags = NSEvent.ModifierFlags()
        var cgFlags = CGEventFlags()

        // Strip leading modifier symbols in any order.
        let modPairs: [(String, NSEvent.ModifierFlags, CGEventFlags, UInt16)] = [
            ("⌃", .control, .maskControl, 59),
            ("⌥", .option, .maskAlternate, 58),
            ("⇧", .shift, .maskShift, 56),
            ("⌘", .command, .maskCommand, 55),
        ]
        var changed = true
        while changed {
            changed = false
            for (sym, ns, cg, _) in modPairs {
                if remaining.hasPrefix(sym) {
                    remaining = String(remaining.dropFirst())
                    nsFlags.insert(ns)
                    cgFlags.insert(cg)
                    changed = true
                }
            }
        }
        guard !remaining.isEmpty else { return nil }

        // Find the keyCode that produces this label.
        let keyCode = keyCodeForLabel(remaining, modifiers: nsFlags)
        guard let kc = keyCode else { return nil }

        // Build keyLabel using charLabel so it matches what we'd produce normally.
        let keyLabel = charLabel(keyCode: kc, modifiers: nsFlags)
        return ButtonBinding(
            kind: .keyCombo, keyCode: kc,
            modifierFlags: cgFlags.rawValue, keyLabel: keyLabel)
    }

    /// Reverse lookup: given a display string and modifier state, find a virtual key code.
    /// Checks the static symbol table first, then scans keyCodes 0–127 via `charLabel`.
    private static func keyCodeForLabel(_ label: String, modifiers: NSEvent.ModifierFlags)
        -> UInt16?
    {
        // Static reverse table for special keys (same set as charLabel).
        let specialKeys: [String: UInt16] = [
            "↩": 36, "⇥": 48, "Space": 49, "⌫": 51, "⎋": 53,
            "⌧": 71, "⌅": 76, "↖": 115, "⇞": 116, "⌦": 117,
            "↘": 119, "⇟": 121, "←": 123, "→": 124, "↓": 125, "↑": 126,
            "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96,
            "F6": 97, "F7": 98, "F8": 100, "F9": 101, "F10": 109,
            "F11": 103, "F12": 111,
        ]
        if let kc = specialKeys[label] { return kc }

        // Scan printable key range.
        for kc: UInt16 in 0..<128 {
            if charLabel(keyCode: kc, modifiers: modifiers) == label { return kc }
        }
        return nil
    }

    // MARK: Key label lookup

    /// Returns the display label for a keyCode + full modifier state.
    ///
    /// Uses `UCKeyTranslate` with the live keyboard layout so that layout-switching
    /// modifiers work correctly.  The notable case is Dvorak Qwerty-Command: holding
    /// ⌘ switches the layout to QWERTY, so ⌘C should display as "C" not "J".
    /// `UCKeyTranslate` handles this automatically because it consults the layout's
    /// own modifier table, which for that layout maps Command-held keycodes to the
    /// QWERTY character set.
    private static func charLabel(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
        // Non-printing / navigation keys don't go through UCKeyTranslate.
        switch Int(keyCode) {
        case 36: return "↩"  // Return
        case 48: return "⇥"  // Tab
        case 49: return "Space"
        case 51: return "⌫"  // Delete
        case 53: return "⎋"  // Escape
        case 71: return "⌧"  // Clear
        case 76: return "⌅"  // Enter (numpad)
        case 115: return "↖"  // Home
        case 116: return "⇞"  // Page Up
        case 117: return "⌦"  // Forward Delete
        case 119: return "↘"  // End
        case 121: return "⇟"  // Page Down
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default: break
        }

        // Translate with the full modifier state (handles Dvorak Qwerty-Command, etc.).
        if let ch = translateKeyCode(keyCode, modifiers: modifiers) { return ch }
        // Fallback: translate with no modifiers to get the bare layout character.
        return translateKeyCode(keyCode, modifiers: []) ?? "?"
    }

    /// Calls `UCKeyTranslate` with the current keyboard layout and returns the
    /// printable character for the given keyCode + modifier combination,
    /// or `nil` if the result is empty or a control character.
    private static func translateKeyCode(
        _ keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> String? {
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let cfData = unsafeBitCast(rawData, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(cfData) else { return nil }

        // Build the Carbon modifier key state for UCKeyTranslate.
        // Each constant is the old Mac OS modifier bit >> 8:
        //   cmdKey = 0x0100, shiftKey = 0x0200, alphaLock = 0x0400,
        //   optionKey = 0x0800, controlKey = 0x1000
        var carbonMods: UInt32 = 0
        if modifiers.contains(.command) { carbonMods |= 1 }
        if modifiers.contains(.shift) { carbonMods |= 2 }
        if modifiers.contains(.capsLock) { carbonMods |= 4 }
        if modifiers.contains(.option) { carbonMods |= 8 }
        if modifiers.contains(.control) { carbonMods |= 16 }

        var chars: [UniChar] = [0, 0, 0, 0]
        var charCount: Int = 0
        var deadState: UInt32 = 0

        // Rebind within the closure to satisfy Swift's strict aliasing rules.
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDown),
                carbonMods,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadState,
                4,
                &charCount,
                &chars
            )
        }
        guard status == noErr, charCount > 0 else { return nil }

        let str = String(
            chars.prefix(Int(charCount)).compactMap { Unicode.Scalar($0).map(Character.init) })
        // Discard control characters (some layouts return e.g. ETX for ⌘C
        // when Command is not in their modifier table).
        guard str.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { return nil }
        return str.uppercased()
    }
}
