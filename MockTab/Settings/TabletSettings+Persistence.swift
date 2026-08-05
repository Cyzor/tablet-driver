// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI

// The UserDefaults layer, split out of TabletSettings.swift: reload, the
// layered-read and write helpers, the pressure-curve and touch-ring-slot
// codecs, reset, and first-run express-key defaults. The backing-store
// stored state lives on the main class body (Swift class extensions can't
// hold stored properties).
extension TabletSettings {

    // MARK: - Reload

    /// Reloads every setting from UserDefaults using the current `devicePrefix`
    /// and `activeProfile`.  Falls back to legacy unprefixed keys, then to
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
        displayBrightness = loadInt("displayBrightness", default: -1)
        displayContrast = loadInt("displayContrast", default: -1)
        displayGamma = loadInt("displayGamma", default: -1)
        displayColorMode = loadInt("displayColorMode", default: -1)
        quickKeysOrientation = loadInt("quickKeysOrientation", default: -1)
        quickKeysSleepMinutes = loadInt("quickKeysSleepMinutes", default: -1)
        quickKeysOledBrightness = loadInt("quickKeysOledBrightness", default: -1)
        bezelLEDColor = loadString("bezelLEDColor", default: "")
        toggleDisplayIDs = loadString("toggleDisplayIDs", default: "")
        smoothingStrength = loadDouble("smoothingStrength", default: 0.0)
        doubleClickDistance = loadDouble("doubleClickDistance", default: 10.0)
        pen1Raw = loadString("penButton1Binding", default: "")
        pen2Raw = loadString("penButton2Binding", default: "")
        expressKeyRaw = loadString("expressKeyBindings", default: "")
        bezelButtonRaw = loadString("bezelButtonBindings", default: "")
        touchRingButtonRaw = loadString("touchRingButtonBinding", default: "")
        loadTouchRingSlots()
        touchRingActiveSlotIndex = loadInt("touchRingActiveSlotIndex", default: 0)
        autoSwitchEnabled = loadBool("autoSwitchEnabled", default: false)
        invertRotation = loadBool("invertRotation", default: false)
        relativeCursorMovement = loadBool("relativeCursorMovement", default: false)
        // Migrate the old on/off toggle: users who had it enabled keep the
        // previous hardcoded 80 ms delay until they touch the new slider.
        let legacyTipUpAssistOn = loadBool("tipUpAssist", default: false)
        tipUpAssistDelay = loadDouble(
            "tipUpAssistDelay", default: legacyTipUpAssistOn ? 80.0 : 0.0)
        dragThreshold = loadDouble("dragThreshold", default: 0.0)
        pressureSmoothingStrength = loadDouble("pressureSmoothingStrength", default: 0.0)
        touchEnabled = loadBool("touchEnabled", default: false)
        touchSensitivity = Swift.max(0.25, Swift.min(loadDouble("touchSensitivity", default: 1.0), 4.0))
        tapToClick = loadBool("tapToClick", default: false)
        twoFingerScroll = loadBool("twoFingerScroll", default: true)
        reverseScrollDirection = loadBool("naturalScrolling", default: false)
        twoFingerScrollMomentum = loadBool("twoFingerScrollMomentum", default: true)
        pinchZoomEnabled = loadBool("pinchZoomEnabled", default: false)
        touchAreaX      = Swift.max(0.0,  Swift.min(loadDouble("touchAreaX",      default: 0.0), 1.0))
        touchAreaY      = Swift.max(0.0,  Swift.min(loadDouble("touchAreaY",      default: 0.0), 1.0))
        touchAreaWidth  = Swift.max(0.01, Swift.min(loadDouble("touchAreaWidth",  default: 1.0), 1.0))
        touchAreaHeight = Swift.max(0.01, Swift.min(loadDouble("touchAreaHeight", default: 1.0), 1.0))
        loadPressureCurve()

        // Sync resolved pressure values and app overrides into activeTool so PenFeel
        // and ButtonMappingView reflect the active override or profile.
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
    ///   → legacy unprefixed key (pre-per-device migration)
    ///   → nil  (caller substitutes the compile-time default)
    ///
    /// The empty-string return ("") signals "use the unprefixed legacy key" —
    /// `prefix + key` is then literally `key`.
    ///
    /// All `load*` helpers below MUST go through this function. Adding a new
    /// inheritance layer requires editing this method and nowhere else.
    private func resolveLayer(for key: String) -> String? {
        if let override = effectiveOverride,
            override.overriddenKeys.contains(key),
            ud.object(forKey: appOverrideKeyPrefix(override) + key) != nil
        {
            return appOverrideKeyPrefix(override)
        }
        if let preset = activeProfile,
            preset.overriddenKeys.contains(key),
            ud.object(forKey: profileKeyPrefix(preset) + key) != nil
        {
            return profileKeyPrefix(preset)
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

    /// Saves touchRingSlots using the same override/preset/device prefix logic as other fields.
    func saveTouchRingSlots() {
        guard !isLoading else { return }
        guard !touchRingSlotsLoadFailed else {
            settingsLogger.error("Refusing to save touchRingSlots: last load couldn't parse existing data")
            return
        }
        guard let data = try? JSONEncoder().encode(touchRingSlots) else { return }
        if var override = activeAppOverride {
            ud.set(data, forKey: appOverrideKeyPrefix(override) + "touchRingSlotsJSON")
            guard !override.overriddenKeys.contains("touchRingSlotsJSON") else { return }
            override.overriddenKeys.insert("touchRingSlotsJSON")
            activeAppOverride = override
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

    /// Loads touchRingSlots with migration from legacy touchRingMode/touchStrip*Mode keys.
    private func loadTouchRingSlots() {
        // Try override, then preset, then device, then legacy keys.
        var data: Data?
        if let override = effectiveOverride, override.overriddenKeys.contains("touchRingSlotsJSON") {
            data = ud.data(forKey: appOverrideKeyPrefix(override) + "touchRingSlotsJSON")
        } else if let preset = activeProfile, preset.overriddenKeys.contains("touchRingSlotsJSON") {
            data = ud.data(forKey: profileKeyPrefix(preset) + "touchRingSlotsJSON")
        } else {
            data = ud.data(forKey: devicePrefix + "touchRingSlotsJSON")
        }

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

        // Migration: synthesize slots from legacy touchRingMode.
        // touchStrip1Mode and touchStrip2Mode are ignored — strips share the ring's mode.
        let legacyMode =
            TouchRingMode(
                rawValue: loadString("touchRingMode", default: TouchRingMode.scroll.rawValue))
            ?? .scroll
        switch legacyMode {
        default:
            touchRingSlots = ControlSlot.defaults
        }
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
        toggleDisplayIDs = ""
        pressureCurve = .linear
        smoothingStrength = 0.0
        doubleClickDistance = 10.0
        pen1Raw = ""
        pen2Raw = ""
        expressKeyRaw = ""
        bezelButtonRaw = ""
        touchRingButtonRaw = ""
        touchRingSlots = ControlSlot.defaults
        touchRingActiveSlotIndex = 0
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
    func applyExpressKeyDefaults(vendorID: Int = 0x056A) {
        guard ud.string(forKey: devicePrefix + "expressKeyBindings") == nil else { return }
        expressKeyBindings = Self.defaultExpressKeyBindings(vendorID: vendorID)
    }

    /// Default express key bindings: keys 1-4 are modifier keys (⌘ ⌥ ⌃ ⇧).
    /// Rest are unbound (.none).
    /// 16-entry layout for dual-ring Cintiq devices (indices 0–15).
    /// Indices 0–2  = left  toggle buttons (near ring), 3–7  = left  express keys.
    /// Indices 8–10 = right toggle buttons (near ring), 11–15 = right express keys.
    /// Devices with only 8 buttons use indices 0–7; the upper 8 entries are ignored.
    ///
    /// Xencelabs Quick Keys is the one exception: its index 8 isn't a mirrored
    /// express key at all — XencelabsDecoder.decodeAux maps it to the puck's
    /// physical mode button (see that file's header comment), which this driver
    /// treats as "Ring: Cycle". Defaulting it to ⌘ like the Cintiq mirror slot
    /// meant every mode-button press quietly asserted Command, which then rode
    /// along with whichever express key the user pressed next and wouldn't let go.
    ///
    /// Shared by `applyExpressKeyDefaults` (first-run) and the Buttons pane's
    /// "Reset Pane to Defaults" action, so the two can't drift apart again.
    static func defaultExpressKeyBindings(vendorID: Int = 0x056A) -> [ButtonBinding] {
        [
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
