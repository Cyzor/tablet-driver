// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI

// Preset (named profile) handling, split out of TabletSettings.swift:
// preset management and persistence, the full-state snapshots used for
// preset-activation undo, and profile import/export. The preset stored
// state lives on the main class body (Swift class extensions can't hold
// stored properties).
extension TabletSettings {

    // MARK: - Preset management

    /// UserDefaults key prefix for a specific preset's overridden values.
    func profileKeyPrefix(_ profile: Profile) -> String {
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
        ud.set(bezelButtonRaw, forKey: prefix + "bezelButtonBindings")
        ud.set(touchRingButtonRaw, forKey: prefix + "touchRingButtonBinding")
        if let data = try? JSONEncoder().encode(touchRingSlots) {
            ud.set(data, forKey: prefix + "touchRingSlotsJSON")
        }
        ud.set(touchRingActiveSlotIndex, forKey: prefix + "touchRingActiveSlotIndex")
        if let data = try? JSONEncoder().encode(pressureCurve) {
            ud.set(data, forKey: prefix + "pressureCurve")
        }
        ud.set(calibrationJSON, forKey: prefix + "calibrationJSON")

        profile.overriddenKeys = [
            "activeAreaX", "activeAreaY", "activeAreaWidth", "activeAreaHeight",
            "proportionalMapping", "targetDisplayIndex", "toggleDisplayIDs",
            "smoothingStrength", "doubleClickDistance", "penButton1Binding", "penButton2Binding",
            "expressKeyBindings", "bezelButtonBindings", "touchRingButtonBinding", "touchRingSlotsJSON",
            "touchRingActiveSlotIndex", "pressureCurve", "calibrationJSON",
        ]

        profiles.append(profile)
        saveProfileList()
        activeProfile = profile
        saveActiveProfileID()
    }

    /// Creates a new preset from a parsed import dict (keys are the same internal
    /// key names used by `saveAsPreset`, values are already in UserDefaults-ready form).
    /// The preset is appended but NOT activated.  Returns the new preset.
    ///
    /// Undoable: unlike overrides/tool settings, an imported preset always
    /// gets a fresh UUID, so there's no collision to reason about — undo is
    /// simply removing the exact preset that was just created, via the
    /// existing `deletePreset`.
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

        let importedID = profile.id
        // Self-recursive so this also redoes: undo deletes the imported
        // preset, then re-registers a fresh "Import Profile" that re-invokes
        // this same function — a new UUID, but an equivalent preset, same
        // trade-off as `ProfilesView.recordSaveProfile`.
        record(String(localized: "Import Profile", comment: "Undo action name for a preset/profile change")) { [weak self] in
            guard let self, let match = self.profiles.first(where: { $0.id == importedID }) else { return }
            self.deletePreset(match)
            self.record(String(localized: "Import Profile", comment: "Undo action name for a preset/profile change")) { [weak self] in
                self?.importProfile(name: name, from: values)
            }
        }
        return profile
    }

    /// Every UserDefaults key `ToolSettings.reload()` reads — used to detect
    /// whether a tool already has any locally-customized values before an import.
    static let toolSettingsKeys: [String] = [
        "smoothingStrength", "pressureSmoothingStrength", "pressureThreshold", "panScrollSpeed",
        "panScrollMomentum",
        "useRotationAsTilt", "rotationTiltOffsetDegrees", "rotationTiltMagnitude",
        "tipBinding", "eraserBinding", "penButton1Binding", "penButton2Binding",
        "penButton3Binding", "penButton4Binding", "penButton5Binding", "wheelBinding",
        "pressureCurve",
    ]

    /// True if `toolID` already has any locally-customized settings stored.
    /// Used by the import preview to detect a collision before the user commits.
    func hasToolSettings(toolID: String) -> Bool {
        let prefix = "\(devicePrefix)tool-\(toolID)."
        return Self.toolSettingsKeys.contains { ud.object(forKey: prefix + $0) != nil }
    }

    /// Imports one tool's settings from a backup.
    ///
    /// Tool identity is the tool's own ID (serial-derived, not a fresh UUID
    /// like a preset), so an existing local customization for that exact tool
    /// is a genuine identity collision. Defaults to skipping unless
    /// `overwrite` is true. Applies immediately — tool settings are live,
    /// not preset-scoped. Reloads the cached `ToolSettings` instance (if any)
    /// so the UI reflects the change without requiring a relaunch.
    ///
    /// Returns whether the import was applied.
    @discardableResult
    func importToolSettings(toolID: String, from values: [String: Any], overwrite: Bool = false) -> Bool {
        guard overwrite || !hasToolSettings(toolID: toolID) else { return false }
        let prefix = "\(devicePrefix)tool-\(toolID)."

        // Snapshot every known tool-settings key's prior value (absent ones
        // stay absent in the snapshot) so the import can be undone.
        var previousValues: [String: Any] = [:]
        for key in Self.toolSettingsKeys {
            if let v = ud.object(forKey: prefix + key) { previousValues[key] = v }
        }

        for (key, value) in values {
            ud.set(value, forKey: prefix + key)
        }
        toolCache[toolID]?.reload()

        // Self-recursive so this also redoes — see `importAppOverride`.
        record(String(localized: "Import Tool Settings", comment: "Undo action name for a preset/profile change")) { [weak self] in
            guard let self else { return }
            for key in Self.toolSettingsKeys {
                if let v = previousValues[key] {
                    self.ud.set(v, forKey: prefix + key)
                } else {
                    self.ud.removeObject(forKey: prefix + key)
                }
            }
            self.toolCache[toolID]?.reload()
            self.record(String(localized: "Import Tool Settings", comment: "Undo action name for a preset/profile change")) { [weak self] in
                self?.importToolSettings(toolID: toolID, from: values, overwrite: true)
            }
        }
        return true
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
    /// Every UserDefaults key a preset can hold — shared by `deletePreset`
    /// (what to erase) and `deletePresetRecordingUndo` (what to snapshot).
    static let presetKeys = [
        "activeAreaX", "activeAreaY", "activeAreaWidth", "activeAreaHeight",
        "proportionalMapping", "targetDisplayIndex", "toggleDisplayIDs",
        "smoothingStrength", "doubleClickDistance", "penButton1Binding", "penButton2Binding",
        "expressKeyBindings", "bezelButtonBindings", "touchRingButtonBinding", "touchRingSlotsJSON",
        "touchRingActiveSlotIndex", "pressureCurve", "calibrationJSON",
    ]

    func deletePreset(_ profile: Profile) {
        let prefix = profileKeyPrefix(profile)
        for key in Self.presetKeys { ud.removeObject(forKey: prefix + key) }
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

    /// Deletes `profile` with full undo/redo support. `deletePreset` itself
    /// registers no undo — it's a low-level primitive reused by import/
    /// save-profile flows that already handle their own undo. This is the
    /// entry point for a user-initiated delete (e.g. the trash button):
    /// snapshots the preset's stored values, its position in the list, and
    /// any app bindings pointing to it, so undo restores it exactly and a
    /// subsequent redo deletes it again — self-recursive, same idiom as
    /// everywhere else in this file.
    func deletePresetRecordingUndo(_ profile: Profile) {
        let prefix = profileKeyPrefix(profile)
        var snapshot: [String: Any] = [:]
        for key in Self.presetKeys {
            if let v = ud.object(forKey: prefix + key) { snapshot[key] = v }
        }
        let index = profiles.firstIndex(where: { $0.id == profile.id })
        let affectedBindings = appBindings.filter { $0.profileID == profile.id }
        let wasActive = activeProfile?.id == profile.id

        deletePreset(profile)

        record(String(localized: "Delete Profile", comment: "Undo action name for a preset/profile change")) { [weak self] in
            guard let self else { return }
            var restored = profile
            restored.overriddenKeys = Set(snapshot.keys)
            if let index, index <= self.profiles.count {
                self.profiles.insert(restored, at: index)
            } else {
                self.profiles.append(restored)
            }
            for (key, value) in snapshot { self.ud.set(value, forKey: prefix + key) }
            if !affectedBindings.isEmpty {
                self.appBindings.append(contentsOf: affectedBindings)
                self.saveAppBindings()
            }
            self.saveProfileList()
            if wasActive {
                self.activeProfile = restored
                self.saveActiveProfileID()
                self.reloadAll()
            }
            self.record(String(localized: "Delete Profile", comment: "Undo action name for a preset/profile change")) { [weak self] in
                self?.deletePresetRecordingUndo(restored)
            }
        }
    }

    // MARK: - Preset persistence

    private var profileListKey: String { devicePrefix + "_presets" }
    private var activeProfileIDKey: String { devicePrefix + "_activeProfile" }

    func loadProfileList() {
        guard let data = ud.data(forKey: profileListKey) else {
            profileListLoadFailed = false
            profiles = []
            activeProfile = nil
            return
        }
        guard let list = try? JSONDecoder().decode([Profile].self, from: data) else {
            // Data exists but this build can't parse it — likely a newer
            // version's format. Don't let a later save clobber it.
            profileListLoadFailed = true
            settingsLogger.error("Profile list data exists but failed to decode; blocking overwrite")
            profiles = []
            activeProfile = nil
            return
        }
        profileListLoadFailed = false
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

    func saveProfileList() {
        guard !profileListLoadFailed else {
            settingsLogger.error("Refusing to save profile list: last load couldn't parse existing data")
            return
        }
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        ud.set(data, forKey: profileListKey)
    }

    func saveActiveProfileID() {
        if let id = activeProfile?.id.uuidString {
            ud.set(id, forKey: activeProfileIDKey)
        } else {
            ud.removeObject(forKey: activeProfileIDKey)
        }
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
        var parallaxOffsetX: Double
        var parallaxOffsetY: Double
        var calibrationJSON: String
        var tabletOrientation: TabletOrientation
        var targetDisplayIndex: Int
        var toggleDisplayIDs: String
        var smoothingStrength: Double
        var doubleClickDistance: Double
        var pressureCurve: BezierCurve
        var pen1Raw: String
        var pen2Raw: String
        var expressKeyRaw: String
        var bezelButtonRaw: String
        var touchRingButtonRaw: String
        var touchRingSlots: [ControlSlot]
        var touchRingActiveSlotIndex: Int
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
            parallaxOffsetX: parallaxOffsetX,
            parallaxOffsetY: parallaxOffsetY,
            calibrationJSON: calibrationJSON,
            tabletOrientation: tabletOrientation,
            targetDisplayIndex: targetDisplayIndex,
            toggleDisplayIDs: toggleDisplayIDs,
            smoothingStrength: smoothingStrength,
            doubleClickDistance: doubleClickDistance,
            pressureCurve: pressureCurve,
            pen1Raw: pen1Raw,
            pen2Raw: pen2Raw,
            expressKeyRaw: expressKeyRaw,
            bezelButtonRaw: bezelButtonRaw,
            touchRingButtonRaw: touchRingButtonRaw,
            touchRingSlots: touchRingSlots,
            touchRingActiveSlotIndex: touchRingActiveSlotIndex,
            autoSwitchEnabled: autoSwitchEnabled)
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
    func applySnapshot(_ snap: FullSnapshot) {
        activeAreaX = snap.activeAreaX
        activeAreaY = snap.activeAreaY
        activeAreaWidth = snap.activeAreaWidth
        activeAreaHeight = snap.activeAreaHeight
        proportionalMapping = snap.proportionalMapping
        parallaxOffsetX = snap.parallaxOffsetX
        parallaxOffsetY = snap.parallaxOffsetY
        calibrationJSON = snap.calibrationJSON
        tabletOrientation = snap.tabletOrientation
        targetDisplayIndex = snap.targetDisplayIndex
        toggleDisplayIDs = snap.toggleDisplayIDs
        smoothingStrength = snap.smoothingStrength
        doubleClickDistance = snap.doubleClickDistance
        pressureCurve = snap.pressureCurve
        pen1Raw = snap.pen1Raw
        pen2Raw = snap.pen2Raw
        expressKeyRaw = snap.expressKeyRaw
        bezelButtonRaw = snap.bezelButtonRaw
        touchRingButtonRaw = snap.touchRingButtonRaw
        touchRingSlots = snap.touchRingSlots
        touchRingActiveSlotIndex = snap.touchRingActiveSlotIndex
        autoSwitchEnabled = snap.autoSwitchEnabled
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
            touchRingMode: touchRingSlots.indices.contains(touchRingActiveSlotIndex)
                ? touchRingSlots[touchRingActiveSlotIndex].action.rawValue : "scroll",
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
        if TouchRingMode(rawValue: profile.touchRingMode) != nil {
            touchRingSlots = ControlSlot.defaults
            touchRingActiveSlotIndex = 0
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
