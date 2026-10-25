// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI

// The UserDefaults layer: reload, the
// layered-read and write helpers, the pressure-curve and touch-ring-slot
// codecs, reset, and first-run express-key defaults. The backing-store
// stored state lives on the main class body (Swift class extensions can't
// hold stored properties).
extension TabletSettings {

    // MARK: - Reload

    /// Reloads every setting from UserDefaults using the current `devicePrefix`
    /// and `activeProfile`.  Falls back to bare unprefixed keys, then to
    /// compile-time defaults.
    func reloadAll() {
        isLoading = true
        activeAreaX      = Swift.max(0.0,  Swift.min(loadDouble("activeAreaX",      default: 0.0), 1.0))
        activeAreaY      = Swift.max(0.0,  Swift.min(loadDouble("activeAreaY",      default: 0.0), 1.0))
        activeAreaWidth  = Swift.max(0.01, Swift.min(loadDouble("activeAreaWidth",  default: 1.0), 1.0))
        activeAreaHeight = Swift.max(0.01, Swift.min(loadDouble("activeAreaHeight", default: 1.0), 1.0))
        proportionalMapping = loadBool("proportionalMapping", default: true)
        parallaxOffsetX = Swift.max(-20, Swift.min(loadDouble("parallaxOffsetX", default: 0.0), 20))
        parallaxOffsetY = Swift.max(-20, Swift.min(loadDouble("parallaxOffsetY", default: 0.0), 20))
        calibrationJSON = loadString("calibrationJSON", default: "")
        tabletOrientation =
            TabletOrientation(rawValue: loadInt("tabletOrientation", default: 0)) ?? .landscape
        targetDisplayIndex = loadInt("targetDisplayIndex", default: 0)
        // A UUID from a lower layer names some other setting's display, so
        // an index without its own UUID falls back to list position.
        targetDisplayUUID = resolveLayer(for: "targetDisplayUUID") == resolveLayer(for: "targetDisplayIndex")
            ? loadString("targetDisplayUUID", default: "") : ""
        displayRegionX      = Swift.max(0.0,  Swift.min(loadDouble("displayRegionX",      default: 0.0), 1.0))
        displayRegionY      = Swift.max(0.0,  Swift.min(loadDouble("displayRegionY",      default: 0.0), 1.0))
        displayRegionWidth  = Swift.max(0.01, Swift.min(loadDouble("displayRegionWidth",  default: 1.0), 1.0))
        displayRegionHeight = Swift.max(0.01, Swift.min(loadDouble("displayRegionHeight", default: 1.0), 1.0))
        displayBrightness = loadInt("displayBrightness", default: -1)
        displayContrast = loadInt("displayContrast", default: -1)
        displayGamma = loadInt("displayGamma", default: -1)
        displayColorMode = loadInt("displayColorMode", default: -1)
        quickKeysOrientation = loadInt("quickKeysOrientation", default: -1)
        quickKeysSleepMinutes = loadInt("quickKeysSleepMinutes", default: -1)
        quickKeysOledBrightness = loadInt("quickKeysOledBrightness", default: -1)
        wirelessSleepMinutes = loadInt("wirelessSleepMinutes", default: -1)
        bezelLEDColor = loadString("bezelLEDColor", default: "")
        toggleDisplayIDs = loadString("toggleDisplayIDs", default: "")
        smoothingStrength = loadDouble("smoothingStrength", default: 0.0)
        doubleClickDistance = loadDouble("doubleClickDistance", default: 10.0)
        pen1Raw = loadString("penButton1Binding", default: "")
        pen2Raw = loadString("penButton2Binding", default: "")
        expressKeyRaw = loadString("expressKeyBindings", default: "")
        bezelButtonRaw = loadString("bezelButtonBindings", default: "")
        touchRingButtonRaw = loadString("touchRingButtonBinding", default: "")
        touchRingButtonRaw2 = loadString("touchRingButtonBinding2", default: "")
        loadTouchRingSlots()
        touchRingActiveSlotIndex = loadInt("touchRingActiveSlotIndex", default: 0)
        touchRingActiveSlotIndex2 = loadInt("touchRingActiveSlotIndex2", default: 0)
        loadRotaries(controlCount: rotaries.controls.count)
        reverseRingDirection = loadBool("reverseRingDirection", default: false)
        invertRotation = loadBool("invertRotation", default: false)
        penDeadBand = Swift.max(-1, Swift.min(loadInt("penDeadBand", default: -1), 40))
        relativeCursorMovement = loadBool("relativeCursorMovement", default: false)
        // Migrate the old on/off toggle: users who had it enabled keep the
        // previous hardcoded 80 ms delay until they touch the new slider.
        let legacyTipUpAssistOn = loadBool("tipUpAssist", default: false)
        tipUpAssistDelay = loadDouble(
            "tipUpAssistDelay", default: legacyTipUpAssistOn ? 80.0 : 0.0)
        dragThreshold = loadDouble("dragThreshold", default: 0.0)
        requireContact = RequireContactActions(rawValue: loadInt("requireContact", default: 0))
        pressureSmoothingStrength = loadDouble("pressureSmoothingStrength", default: 0.0)
        touchEnabled = loadBool("touchEnabled", default: false)
        touchSensitivity = Swift.max(0.25, Swift.min(loadDouble("touchSensitivity", default: 1.25), 4.0))
        tapToClick = loadBool("tapToClick", default: false)
        twoFingerRightClick = loadBool("twoFingerRightClick", default: false)
        threeFingerDrag = loadBool("threeFingerDrag", default: false)
        touchOnsetDelayMs = Swift.max(0.0, Swift.min(loadDouble("touchOnsetDelayMs", default: 40.0), 500.0))
        touchTapStabilizationPt = Swift.max(0.0, Swift.min(loadDouble("touchTapStabilizationPt", default: 1.5), 4.0))
        // touchAbsoluteMode is deliberately global — see its doc comment —
        // and reads straight from UserDefaults.standard, not through this
        // per-device load chain.
        twoFingerScroll = loadBool("twoFingerScroll", default: true)
        reverseScrollDirection = loadBool("naturalScrolling", default: false)
        twoFingerScrollMomentum = loadBool("twoFingerScrollMomentum", default: false)
        pinchZoomEnabled = loadBool("pinchZoomEnabled", default: false)
        rotateEnabled = loadBool("rotateEnabled", default: false)
        touchAreaX      = Swift.max(0.0,  Swift.min(loadDouble("touchAreaX",      default: 0.0), 1.0))
        touchAreaY      = Swift.max(0.0,  Swift.min(loadDouble("touchAreaY",      default: 0.0), 1.0))
        touchAreaWidth  = Swift.max(0.01, Swift.min(loadDouble("touchAreaWidth",  default: 1.0), 1.0))
        touchAreaHeight = Swift.max(0.01, Swift.min(loadDouble("touchAreaHeight", default: 1.0), 1.0))
        loadPressureCurve()

        // Sync resolved pressure values and app overrides into activeTool so PenFeel
        // and ButtonsView reflect the active override or profile.
        let op = effectiveOverride.map { appOverrideKeyPrefix($0) }
        activeTool.overridePrefix = op
        activeTool.reload()
        activeTool.applyExternalValues(
            pressureCurve: pressureCurve, smoothingStrength: smoothingStrength,
            pressureSmoothingStrength: pressureSmoothingStrength)

        // Also propagate to all cached per-tool instances so the injector (which uses
        // activeToolSettings — a cached ToolSettings — not activeTool) picks up the change.
        for tool in toolCache.values where tool !== activeTool {
            tool.overridePrefix = op
            tool.reload()
            tool.applyExternalValues(
                pressureCurve: pressureCurve, smoothingStrength: smoothingStrength,
                pressureSmoothingStrength: pressureSmoothingStrength)
        }
        isLoading = false
        migrateTargetDisplayUUID()
    }

    /// Records the UUID for a specific-display mapping saved before UUIDs
    /// were. A pen display maps to its own screen when found; anything else
    /// keeps the display at its saved position, which is where it maps today.
    func migrateTargetDisplayUUID() {
        guard targetDisplayIndex > 0, targetDisplayUUID.isEmpty else { return }
        let penDisplay = penDisplayLocator?()
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return }
        let id = penDisplay ?? (targetDisplayIndex <= ids.count ? ids[targetDisplayIndex - 1] : nil)
        guard let id else { return }
        let uuid = CalibrationKey.uuidString(for: id)
        guard CalibrationKey.isReliable(uuid) else { return }
        let index = ids.firstIndex(of: id).map { $0 + 1 } ?? targetDisplayIndex
        // Saved only where the index itself lives on the device; a profile's
        // or override's index is matched afresh on each load instead.
        if resolveLayer(for: "targetDisplayIndex") == devicePrefix {
            ud.set(uuid, forKey: devicePrefix + "targetDisplayUUID")
            ud.set(index, forKey: devicePrefix + "targetDisplayIndex")
        }
        isLoading = true
        (targetDisplayUUID, targetDisplayIndex) = (uuid, index)
        isLoading = false
    }

    // MARK: - Persistence helpers

    /// Routes a write to the effective app override, then profile, then device
    /// namespace. Marks the key as overridden in whichever layer receives the
    /// write. Uses `effectiveOverride` (not the chip-bar selection) because
    /// some writes originate from hardware while another app is frontmost —
    /// display-toggle express key, touch-ring mode cycle — and must land in
    /// the frontmost app's override, not whichever chip the user left selected.
    /// No-ops while `isLoading` to avoid echoing values back during reload.
    func persist(_ key: String, _ value: Any) {
        guard !isLoading else { return }
        if var override = effectiveOverride {
            ud.set(value, forKey: appOverrideKeyPrefix(override) + key)
            guard !override.overriddenKeys.contains(key) else { return }
            override.overriddenKeys.insert(key)
            if activeAppOverride?.bundleID == override.bundleID { activeAppOverride = override }
            if driverOverride?.bundleID == override.bundleID { driverOverride = override }
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

    /// Returns the UserDefaults key-prefix of whichever inheritance layer "owns"
    /// `key`, or `nil` if no layer has set it. This is the single source of
    /// truth for the read-time precedence walk:
    ///
    ///   active app override (if key is in its `overriddenKeys`)
    ///   → active profile  (if key is in its `overriddenKeys`)
    ///   → device prefix
    ///   → bare unprefixed key (a global `defaults write` value)
    ///   → nil  (caller substitutes the compile-time default)
    ///
    /// The empty-string return ("") signals "use the bare key" —
    /// `prefix + key` is then literally `key`.
    ///
    /// All `load*` helpers below must go through this function. Adding a new
    /// inheritance layer requires editing this method and nowhere else.
    private func resolveLayer(for key: String) -> String? {
        resolveLayer(for: key, override: effectiveOverride, profile: activeProfile)
    }

    /// `resolveLayer(for:)` for any app override and profile, not only the
    /// live ones: where `key` reads from in that context.
    func resolveLayer(for key: String, override: AppOverride?, profile: Profile?) -> String? {
        if let override,
            override.overriddenKeys.contains(key),
            ud.object(forKey: appOverrideKeyPrefix(override) + key) != nil
        {
            return appOverrideKeyPrefix(override)
        }
        if let profile,
            profile.overriddenKeys.contains(key),
            ud.object(forKey: profileKeyPrefix(profile) + key) != nil
        {
            return profileKeyPrefix(profile)
        }
        if ud.object(forKey: devicePrefix + key) != nil {
            return devicePrefix
        }
        if ud.object(forKey: key) != nil {
            return ""
        }
        return nil
    }

    private func loadDouble(_ key: String, default d: Double) -> Double {
        guard let prefix = resolveLayer(for: key) else { return d }
        return ud.double(forKey: prefix + key)
    }

    private func loadBool(_ key: String, default d: Bool) -> Bool {
        guard let prefix = resolveLayer(for: key) else { return d }
        return ud.bool(forKey: prefix + key)
    }

    private func loadInt(_ key: String, default d: Int) -> Int {
        guard let prefix = resolveLayer(for: key) else { return d }
        return ud.integer(forKey: prefix + key)
    }

    private func loadString(_ key: String, default d: String) -> String {
        guard let prefix = resolveLayer(for: key) else { return d }
        return ud.string(forKey: prefix + key) ?? d
    }

    // MARK: - Pressure curve persistence

    func savePressureCurve() {
        guard !isLoading else { return }
        guard !pressureCurveLoadFailed else {
            settingsLogger.error("Refusing to save pressureCurve: last load couldn't parse existing data")
            return
        }
        guard let data = try? JSONEncoder().encode(pressureCurve) else { return }
        // Uses effectiveOverride, not activeAppOverride, to match loadPressureCurve's
        // read layer — see persist()'s doc comment for why (hardware-originated writes
        // while another app is frontmost must land in that app's override).
        if var override = effectiveOverride {
            ud.set(data, forKey: appOverrideKeyPrefix(override) + "pressureCurve")
            guard !override.overriddenKeys.contains("pressureCurve") else { return }
            override.overriddenKeys.insert("pressureCurve")
            if activeAppOverride?.bundleID == override.bundleID { activeAppOverride = override }
            if driverOverride?.bundleID == override.bundleID { driverOverride = override }
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
        if let override = effectiveOverride, override.overriddenKeys.contains("pressureCurve") {
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
        guard let data else {
            pressureCurveLoadFailed = false
            return
        }
        guard let curve = try? JSONDecoder().decode(BezierCurve.self, from: data) else {
            // Data exists but this build can't parse it — likely a newer
            // version's format. Don't let a later save clobber it.
            pressureCurveLoadFailed = true
            settingsLogger.error("pressureCurve data exists but failed to decode; blocking overwrite")
            return
        }
        pressureCurveLoadFailed = false
        pressureCurve = curve
    }

    // MARK: - Touch Ring Slot persistence

    /// Saves touchRingSlots using the same override/profile/device prefix logic as other fields.
    func saveTouchRingSlots() {
        guard !isLoading else { return }
        guard !touchRingSlotsLoadFailed else {
            settingsLogger.error("Refusing to save touchRingSlots: last load couldn't parse existing data")
            return
        }
        guard let data = try? JSONEncoder().encode(touchRingSlots) else { return }
        // Uses effectiveOverride, not activeAppOverride, to match loadTouchRingSlots's
        // read layer — see persist()'s doc comment for why (hardware-originated writes
        // while another app is frontmost must land in that app's override).
        if var override = effectiveOverride {
            ud.set(data, forKey: appOverrideKeyPrefix(override) + "touchRingSlotsJSON")
            guard !override.overriddenKeys.contains("touchRingSlotsJSON") else { return }
            override.overriddenKeys.insert("touchRingSlotsJSON")
            if activeAppOverride?.bundleID == override.bundleID { activeAppOverride = override }
            if driverOverride?.bundleID == override.bundleID { driverOverride = override }
            if let idx = appOverrides.firstIndex(where: { $0.bundleID == override.bundleID }) {
                appOverrides[idx] = override
            }
            saveAppOverrides()
        } else if var preset = activeProfile {
            ud.set(data, forKey: profileKeyPrefix(preset) + "touchRingSlotsJSON")
            guard !preset.overriddenKeys.contains("touchRingSlotsJSON") else { return }
            preset.overriddenKeys.insert("touchRingSlotsJSON")
            activeProfile = preset
            if let idx = profiles.firstIndex(where: { $0.id == preset.id }) {
                profiles[idx] = preset
            }
            saveProfileList()
        } else {
            ud.set(data, forKey: devicePrefix + "touchRingSlotsJSON")
        }
    }

    // MARK: - Per-dial persistence

    /// Saves `rotaries` using the same override/profile/device prefix logic as
    /// `saveTouchRingSlots`.
    func saveRotaries() {
        guard !isLoading, !isApplyingRotaryCapability else { return }
        guard !rotariesLoadFailed else {
            settingsLogger.error("Refusing to save rotaries: last load couldn't parse existing data")
            return
        }
        guard let data = try? JSONEncoder().encode(rotaries) else { return }
        if var override = effectiveOverride {
            ud.set(data, forKey: appOverrideKeyPrefix(override) + "rotariesJSON")
            guard !override.overriddenKeys.contains("rotariesJSON") else { return }
            override.overriddenKeys.insert("rotariesJSON")
            if activeAppOverride?.bundleID == override.bundleID { activeAppOverride = override }
            if driverOverride?.bundleID == override.bundleID { driverOverride = override }
            if let idx = appOverrides.firstIndex(where: { $0.bundleID == override.bundleID }) {
                appOverrides[idx] = override
            }
            saveAppOverrides()
        } else if var preset = activeProfile {
            ud.set(data, forKey: profileKeyPrefix(preset) + "rotariesJSON")
            guard !preset.overriddenKeys.contains("rotariesJSON") else { return }
            preset.overriddenKeys.insert("rotariesJSON")
            activeProfile = preset
            if let idx = profiles.firstIndex(where: { $0.id == preset.id }) {
                profiles[idx] = preset
            }
            saveProfileList()
        } else {
            ud.set(data, forKey: devicePrefix + "rotariesJSON")
        }
    }

    /// Loads `rotaries` from the most specific level that stores ring modes,
    /// or defaults. Where that level has only the shared `touchRingSlots`
    /// (a touch-ring tablet set up before its rings went independent), every
    /// control starts as a copy of it. Nothing is written until an edit.
    func loadRotaries(controlCount: Int) {
        let (prefix, seedFromShared) = rotariesLayer(override: effectiveOverride, profile: activeProfile)
        let data = ud.data(forKey: prefix + "rotariesJSON")

        let wasIndependent = rotaries.controlsAreIndependent
        var loaded: RotarySet
        if let data {
            guard let stored = try? JSONDecoder().decode(RotarySet.self, from: data) else {
                rotariesLoadFailed = true
                settingsLogger.error("rotariesJSON data exists but failed to decode; blocking overwrite")
                isApplyingRotaryCapability = true
                rotaries = RotarySet(controls: [RotaryConfig()], controlsAreIndependent: wasIndependent)
                isApplyingRotaryCapability = false
                return
            }
            loaded = stored
        } else if seedFromShared {
            loaded = RotarySet(controls: [
                RotaryConfig(slots: touchRingSlots, activeSlotIndex: touchRingActiveSlotIndex),
            ])
        } else {
            loaded = RotarySet(controls: [RotaryConfig(slots: defaultRingSlots)])
        }
        rotariesLoadFailed = false
        loaded.controlsAreIndependent = wasIndependent
        loaded.resize(to: controlCount)
        isApplyingRotaryCapability = true
        rotaries = loaded
        isApplyingRotaryCapability = false
    }

    /// The level `loadRotaries` reads in a context, and whether that level has
    /// only the shared ring modes to start both controls from.
    func rotariesLayer(override: AppOverride?, profile: Profile?) -> (prefix: String, seedsFromShared: Bool) {
        let key = "rotariesJSON", sharedKey = "touchRingSlotsJSON"
        let seeds = rotariesSeedFromSharedModes
        if let override,
           override.overriddenKeys.contains(key) || (seeds && override.overriddenKeys.contains(sharedKey)) {
            let prefix = appOverrideKeyPrefix(override)
            return (prefix, ud.data(forKey: prefix + key) == nil)
        }
        if let profile,
           profile.overriddenKeys.contains(key) || (seeds && profile.overriddenKeys.contains(sharedKey)) {
            let prefix = profileKeyPrefix(profile)
            return (prefix, ud.data(forKey: prefix + key) == nil)
        }
        let seed = ud.data(forKey: devicePrefix + key) == nil && seeds && ud.data(forKey: devicePrefix + sharedKey) != nil
        return (devicePrefix, seed)
    }

    /// Applies the tablet's rotary layout at connect time and reloads under
    /// it; the stored blob's device prefix isn't known any earlier.
    /// `seedFromSharedModes` is for touch-ring tablets, whose modes used to
    /// live in `touchRingSlots`.
    func applyRotaryHardware(
        controlCount: Int, independent: Bool, seedFromSharedModes: Bool,
        defaultSlots: [ControlSlot] = ControlSlot.defaults
    ) {
        controlsAreIndependent = independent
        rotariesSeedFromSharedModes = seedFromSharedModes
        defaultRingSlots = defaultSlots
        loadRotaries(controlCount: max(1, controlCount))
    }

    /// The level `loadTouchRingSlots` reads in a context. Unlike other keys it
    /// never falls through to a global `defaults` value.
    func touchRingSlotsLayer(override: AppOverride?, profile: Profile?) -> String {
        if let override, override.overriddenKeys.contains("touchRingSlotsJSON") { return appOverrideKeyPrefix(override) }
        if let profile, profile.overriddenKeys.contains("touchRingSlotsJSON") { return profileKeyPrefix(profile) }
        return devicePrefix
    }

    /// Loads touchRingSlots from the override, profile, or device layer.
    private func loadTouchRingSlots() {
        let data = ud.data(forKey: touchRingSlotsLayer(override: effectiveOverride, profile: activeProfile)
                                   + "touchRingSlotsJSON")

        if let data {
            guard let slots = try? JSONDecoder().decode([ControlSlot].self, from: data) else {
                // Data exists but this build can't parse it — likely a newer
                // version's format. Don't let a later save clobber it.
                touchRingSlotsLoadFailed = true
                settingsLogger.error("touchRingSlotsJSON data exists but failed to decode; blocking overwrite")
                touchRingSlots = ControlSlot.defaults
                return
            }
            touchRingSlotsLoadFailed = false
            touchRingSlots = slots
            return
        }
        touchRingSlotsLoadFailed = false
        touchRingSlots = ControlSlot.defaults
    }

    // MARK: - Reset

    func resetToDefaults() {
        activeAreaX = 0
        activeAreaY = 0
        activeAreaWidth = 1
        activeAreaHeight = 1
        proportionalMapping = true
        parallaxOffsetX = 0
        parallaxOffsetY = 0
        calibrationJSON = ""
        tabletOrientation = .landscape
        targetDisplayIndex = 0
        targetDisplayUUID = ""
        displayRegionX = 0
        displayRegionY = 0
        displayRegionWidth = 1
        displayRegionHeight = 1
        toggleDisplayIDs = ""
        pressureCurve = .linear
        smoothingStrength = 0.0
        doubleClickDistance = 10.0
        pen1Raw = ""
        pen2Raw = ""
        expressKeyRaw = ""
        bezelButtonRaw = ""
        touchRingButtonRaw = ""
        touchRingButtonRaw2 = ""
        touchRingSlots = ControlSlot.defaults
        touchRingActiveSlotIndex = 0
        touchRingActiveSlotIndex2 = 0
        rotaries = rotaries.resetToDefaults(slots: defaultRingSlots)
    }

    // MARK: - First-run defaults

    /// Writes the default ExpressKey bindings if this device has none stored.
    func applyExpressKeyDefaults(vendorID: Int = 0x056A, splitPad: Bool = false) {
        guard ud.string(forKey: devicePrefix + "expressKeyBindings") == nil else { return }
        expressKeyBindings = Self.defaultExpressKeyBindings(vendorID: vendorID, splitPad: splitPad)
    }

    /// Default ExpressKey bindings, 16 entries; 8-key tablets use the first
    /// eight. Keys 1–4 hold ⌘ ⌥ ⌃ ⇧, and 9–12 repeat them for the right
    /// side of a two-sided pad. On the Cintiq 24HD (`splitPad`), each side's
    /// first three keys pick that ring's modes instead. A Quick Keys' index 8
    /// is its mode button, so it stays unbound there.
    ///
    /// Shared by first-run defaults and the Buttons pane's reset.
    static func defaultExpressKeyBindings(vendorID: Int = 0x056A, splitPad: Bool = false) -> [ButtonBinding] {
        if splitPad {
            // Cintiq 24HD: each side's first three keys pick that ring's modes.
            let left = (0..<3).map { ButtonBinding(kind: .ringSelectSlot, keyCode: UInt16($0)) }
            let right = (0..<3).map { ButtonBinding(kind: .ringSelectSlot2, keyCode: UInt16($0)) }
            let rest = [ButtonBinding](repeating: .none, count: 5)
            return left + rest + right + rest
        }
        return [
            ButtonBinding(modifierOnly: .command),  // 0  left key 1 → ⌘
            ButtonBinding(modifierOnly: .option),  // 1  left key 2 → ⌥
            ButtonBinding(modifierOnly: .control),  // 2  left key 3 → ⌃
            ButtonBinding(modifierOnly: .shift),  // 3  left key 4 → ⇧
            .none, .none, .none, .none,  // 4–7 left keys 5–8
            vendorID == 0x28BD ? .none : ButtonBinding(modifierOnly: .command),  // 8
            ButtonBinding(modifierOnly: .option),  // 9  right key 2 (mirror) → ⌥
            ButtonBinding(modifierOnly: .control),  // 10 right key 3 (mirror) → ⌃
            ButtonBinding(modifierOnly: .shift),  // 11 right key 4 (mirror) → ⇧
            .none, .none, .none, .none,  // 12–15 right keys 5–8
        ]
    }
}
