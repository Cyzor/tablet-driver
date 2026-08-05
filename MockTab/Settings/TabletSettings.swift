// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Carbon
import Foundation
import OSLog
import SwiftUI
import TabletKit

let settingsLogger = Logger(subsystem: "com.cyzor.mocktab", category: "settings")

/// All user-configurable settings, persisted via UserDefaults with a per-device
/// key prefix so each tablet remembers its own configuration independently.
///
/// ── Inheritance model ──────────────────────────────────────────────────────
/// A read for any setting walks the layers below in order; the first layer
/// that has the key wins. A write goes to whichever layer is currently
/// "selected" for editing (the device default unless an override is active).
///
///     ┌──────────────────────────────────────────────────────────────┐
///     │ 4. Per-app override   keys: "device-0x0357.app-com.adobe.…" │  highest
///     │    Activated automatically when the bound app is frontmost. │
///     │    Stores only keys that diverge from the layer below.       │
///     ├──────────────────────────────────────────────────────────────┤
///     │ 3. Named preset       (overlay; optional)                    │
///     │    User-saved profile, also stores only diffs. Manually      │
///     │    selected or auto-activated by an app→profile binding.     │
///     ├──────────────────────────────────────────────────────────────┤
///     │ 2. Per-tool settings  keys: "device-0x0357.tool-<serial>.…" │
///     │    One namespace per stylus serial (or "stylus"/"eraser"/    │
///     │    "mouse" for the device-default tool, which shares prefix  │
///     │    with layer 1 to avoid migration).                         │
///     ├──────────────────────────────────────────────────────────────┤
///     │ 1. Device defaults    keys: "device-0x0357.…"                │  lowest
///     │    The baseline for this product ID.                         │
///     └──────────────────────────────────────────────────────────────┘
///
/// Legacy unprefixed keys (from before per-device support) are read as a
/// fallback on first load for a given device, providing seamless migration.
///
/// Activating/deactivating any overlay republishes all @Published properties
/// so SwiftUI views re-render against the effective composed value.
///
/// The class spans four files: this one holds every stored property (Swift
/// extensions can't) plus init, per-device loading, and undo/redo, while the
/// sibling `TabletSettings+*.swift` extensions hold preset handling
/// (+Presets), per-app overrides and auto-switching (+AppOverrides), and the
/// UserDefaults layer (+Persistence). Everything runs on the main actor.
@MainActor
final class TabletSettings: ObservableObject {

    // MARK: - Per-device backing store

    /// Current UserDefaults key prefix, e.g. `"device-0x0357."`.
    /// Changed by `loadForDevice(_:)` when a tablet connects.
    private(set) var devicePrefix = "device-default."

    /// Suppresses UserDefaults writes during `loadForDevice()` / `activate()`.
    var isLoading = false

    /// Set when the last load of a composite JSON blob (profiles, app
    /// overrides, pressure curve, touch ring slots) found data but couldn't
    /// parse it — e.g. this is an older build than whatever wrote it. The
    /// corresponding save function then refuses to overwrite that key, so an
    /// old build can't clobber settings format it doesn't understand.
    /// Cleared as soon as that blob is next saved successfully.
    var profileListLoadFailed = false
    var appOverridesLoadFailed = false
    var appBindingsLoadFailed = false
    var pressureCurveLoadFailed = false
    var touchRingSlotsLoadFailed = false
    var calibrationLoadFailed = false

    /// Undo manager for this device's settings. Owned by the device, not by
    /// whichever window happens to be open for it — multiple windows for the
    /// same device (e.g. Cmd-N "New Window") share this one instance rather
    /// than each claiming their own, which used to silently clobber the
    /// previous window's `settings.undoManager` reference and left its Edit
    /// menu showing stale, orphaned undo entries. Companion devices (the
    /// Xencelabs Quick Keys puck) explicitly adopt their owner's manager so
    /// the two share one undo timeline within the same window — hence this
    /// stays settable rather than a `let`.
    var undoManager: UndoManager? = UndoManager()

    let ud = UserDefaults.standard

    // MARK: - Per-tool settings

    /// The tool settings currently active on this device.
    /// Starts as the device-default tool; swapped by TabletManager on tool-enter.
    @Published var activeTool: ToolSettings = ToolSettings(prefix: "device-default.") {
        didSet {
            activeTool.undoManager = undoManager
            // Sync current override to the newly active tool. Tool swaps can
            // happen while any app is frontmost, so use the effective source,
            // not the chip-bar selection.
            activeTool.overridePrefix = effectiveOverride.map { appOverrideKeyPrefix($0) }
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
    var toolCache: [String: ToolSettings] = [:]

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
        ts.undoManager = undoManager
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

    // MARK: - Pen display parallax offset (points)

    /// Horizontal cursor offset to compensate for parallax on pen displays (Cintiq-class).
    /// Positive values shift the cursor rightward relative to the pen tip.
    @Published var parallaxOffsetX: Double = 0.0 {
        didSet { persist("parallaxOffsetX", parallaxOffsetX) }
    }
    /// Vertical cursor offset to compensate for parallax on pen displays (Cintiq-class).
    /// Positive values shift the cursor downward relative to the pen tip.
    @Published var parallaxOffsetY: Double = 0.0 {
        didSet { persist("parallaxOffsetY", parallaxOffsetY) }
    }

    /// JSON-encoded `[CalibrationEntry]` for multi-point parallax calibration.
    /// Keyed by (orientation, displayID); empty string = no calibration.
    @Published var calibrationJSON: String = "" {
        didSet { persist("calibrationJSON", calibrationJSON) }
    }

    /// Decoded calibration entries from `calibrationJSON`.
    var calibrationEntries: [CalibrationEntry] {
        get {
            guard !calibrationJSON.isEmpty,
                  let data = calibrationJSON.data(using: .utf8) else {
                calibrationLoadFailed = false
                return []
            }
            guard let entries = try? JSONDecoder().decode([CalibrationEntry].self, from: data)
            else {
                // Data exists but this build can't parse it — likely a newer
                // version's format. Don't let a later save clobber it.
                calibrationLoadFailed = true
                settingsLogger.error("calibrationJSON exists but failed to decode; blocking overwrite")
                return []
            }
            calibrationLoadFailed = false
            return entries
        }
        set {
            guard !calibrationLoadFailed else {
                settingsLogger.error("Refusing to save calibration entries: last load couldn't parse existing data")
                return
            }
            if newValue.isEmpty {
                calibrationJSON = ""
            } else if let data = try? JSONEncoder().encode(newValue),
                      let str = String(data: data, encoding: .utf8) {
                calibrationJSON = str
            }
        }
    }

    /// Look up the calibration entry for a specific orientation and display UUID.
    func calibration(for orientation: TabletOrientation, displayUUID: String) -> CalibrationEntry? {
        guard !displayUUID.isEmpty else { return nil }
        return calibrationEntries.first { $0.key.orientation == orientation.rawValue && $0.key.displayUUID == displayUUID }
    }

    /// Physical tablet orientation — clockwise rotation from the default landscape position.
    @Published var tabletOrientation: TabletOrientation = .landscape {
        didSet { persist("tabletOrientation", tabletOrientation.rawValue) }
    }

    // MARK: - Display mapping

    /// Sentinel value for targetDisplayIndex: tablet area spans all displays.
    nonisolated static let displayModeAll = -1
    /// Sentinel value for targetDisplayIndex: tablet cycles through selected displays.
    nonisolated static let displayModeToggle = -2

    /// 0 = primary display, 1..N = specific display (1-indexed CGGetActiveDisplayList order).
    /// -1 = all displays (span union rect), -2 = toggle rotation.
    @Published var targetDisplayIndex: Int = 0 {
        didSet { persist("targetDisplayIndex", targetDisplayIndex) }
    }

    /// Panel backlight brightness (0–100) for pen displays with on-device
    /// control (Xencelabs). -1 = never set here; nothing is sent to the
    /// hardware so the panel keeps its own stored value. Persisted straight
    /// into the device namespace — this is hardware state shared with the
    /// panel's bezel buttons, not a per-profile preference.
    @Published var displayBrightness: Int = -1 {
        didSet {
            guard !isLoading else { return }
            ud.set(displayBrightness, forKey: devicePrefix + "displayBrightness")
        }
    }

    /// Panel contrast (0–100) for pen displays with host-controllable panel
    /// controls (Xencelabs). -1 = never set here; nothing is sent so the panel
    /// keeps its own stored value. Hardware state shared with the bezel buttons,
    /// like `displayBrightness`.
    @Published var displayContrast: Int = -1 {
        didSet {
            guard !isLoading else { return }
            ud.set(displayContrast, forKey: devicePrefix + "displayContrast")
        }
    }

    /// Panel gamma stored as gamma × 10 (e.g. 22 = 2.2). -1 = never set here.
    /// Same hardware-state semantics as `displayBrightness`.
    @Published var displayGamma: Int = -1 {
        didSet {
            guard !isLoading else { return }
            ud.set(displayGamma, forKey: devicePrefix + "displayGamma")
        }
    }

    /// Row index of the panel's "Custom"/User Mode color preset — the only
    /// mode where the vendor's own driver exposes contrast/gamma controls.
    /// Named presets (Adobe RGB, sRGB, etc.) own their contrast/gamma
    /// internally and don't accept independent writes to them.
    static let displayColorModeCustomIndex = 6

    /// Panel color-space preset row index (Adobe RGB, sRGB, REC 709, DCI-P3,
    /// REC 2020, Pantone, Custom). -1 = never set here. Same hardware-state
    /// semantics as `displayBrightness`.
    @Published var displayColorMode: Int = -1 {
        didSet {
            guard !isLoading else { return }
            ud.set(displayColorMode, forKey: devicePrefix + "displayColorMode")
        }
    }

    /// Color of the shared backlight LED behind the pen display's bezel
    /// buttons, stored as "R,G,B,A" sRGB bytes (alpha doubles as LED
    /// brightness, premultiplied into the RGB on the way to the hardware —
    /// same scheme as the Quick Keys dial LED). Empty = never set here; the
    /// panel keeps its own stored color. Same hardware-state semantics as
    /// `displayBrightness`.
    @Published var bezelLEDColor: String = "" {
        didSet {
            guard !isLoading else { return }
            ud.set(bezelLEDColor, forKey: devicePrefix + "bezelLEDColor")
        }
    }

    /// Parse a `bezelLEDColor` string. nil when unset or malformed. Static
    /// so subscribers can decode the value a `$bezelLEDColor` publisher
    /// emits (which arrives before the stored property updates).
    nonisolated static func bezelLEDColor(from string: String) -> ControlSlot.LEDColor? {
        let parts = string.split(separator: ",").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        return ControlSlot.LEDColor(r: parts[0], g: parts[1], b: parts[2], a: parts[3])
    }

    /// Typed view of `bezelLEDColor`. nil when unset or malformed.
    var bezelLEDColorValue: ControlSlot.LEDColor? {
        get { Self.bezelLEDColor(from: bezelLEDColor) }
        set { bezelLEDColor = newValue.map { "\($0.r),\($0.g),\($0.b),\($0.a)" } ?? "" }
    }

    /// Quick Keys OLED text orientation, in 90° steps (0 = upright, 1–3 =
    /// 90°/180°/270°). -1 = never set here; nothing is sent, so the puck
    /// keeps its own stored orientation. Hardware state, not a per-profile
    /// preference — same semantics as `displayBrightness`.
    @Published var quickKeysOrientation: Int = -1 {
        didSet {
            guard !isLoading else { return }
            ud.set(quickKeysOrientation, forKey: devicePrefix + "quickKeysOrientation")
        }
    }

    /// Quick Keys auto-sleep timer, in minutes (0 = never sleep). -1 = never
    /// set here; nothing is sent, so the puck keeps its own stored timer.
    /// Hardware state persisted in puck firmware — same semantics as
    /// `displayBrightness`.
    @Published var quickKeysSleepMinutes: Int = -1 {
        didSet {
            guard !isLoading else { return }
            ud.set(quickKeysSleepMinutes, forKey: devicePrefix + "quickKeysSleepMinutes")
        }
    }

    /// Quick Keys OLED brightness, 0 (off) through 3 (bright). -1 = never set
    /// here; nothing is sent, so the puck keeps its own stored brightness.
    /// Hardware state — same semantics as `displayBrightness`.
    @Published var quickKeysOledBrightness: Int = -1 {
        didSet {
            guard !isLoading else { return }
            ud.set(quickKeysOledBrightness, forKey: devicePrefix + "quickKeysOledBrightness")
        }
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
    /// Smooths pressure readings, scaled inversely to pressure level: heaviest
    /// damping near the noisy low-pressure/activation-threshold band, opening
    /// up toward passthrough as pressure rises toward a firm stroke. 0 = off.
    @Published var pressureSmoothingStrength: Double = 0.0 {
        didSet { persist("pressureSmoothingStrength", pressureSmoothingStrength) }
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
    /// Milliseconds to hold the mouseUp open after tip-lift when the pen is
    /// still moving quickly. 0 = off.
    @Published var tipUpAssistDelay: Double = 0.0 {
        didSet { persist("tipUpAssistDelay", tipUpAssistDelay) }
    }
    /// Minimum distance (points) the pen must travel from tip-down before a
    /// drag is posted. 0 = off. Absorbs hand tremor / pressure-driven jitter
    /// right at tip-down so a light tap doesn't register as a drag.
    @Published var dragThreshold: Double = 0.0 {
        didSet { persist("dragThreshold", dragThreshold) }
    }

    // MARK: - Capacitive finger touch
    //
    // Only meaningful on devices whose WacomDeviceSpec has hasFingerTouch=true.
    // The UI (TouchView) hides these on devices without finger touch.  No
    // decoder produces touch reports yet — these settings exist so the path
    // is wired the moment a real touch capture allows the decoder to land.

    /// Master enable for finger-touch input.  When false, `InputInjector.injectTouch`
    /// becomes a no-op regardless of incoming reports.  Defaults to true so that
    /// Off by default: Wacom's touch behaviour is widely disliked, and many
    /// users prefer to opt in deliberately rather than discover the cursor
    /// jumping the first time they rest a hand on the tablet.
    @Published var touchEnabled: Bool = false {
        didSet { persist("touchEnabled", touchEnabled) }
    }
    /// Scalar applied to cursor movement from finger drag in pointer mode.
    /// 0.25 (slow) – 4.0 (fast); 1.0 is "one tablet-unit per device-unit through
    /// the touch-area mapping".
    @Published var touchSensitivity: Double = 1.0 {
        didSet { persist("touchSensitivity", touchSensitivity) }
    }
    /// When true, a brief single-finger touch (down→up without significant motion)
    /// posts a left click.  Defaults to false because Wacom's tap-to-click is a
    /// frequent source of phantom clicks; users opt in explicitly.
    @Published var tapToClick: Bool = false {
        didSet { persist("tapToClick", tapToClick) }
    }
    /// When true, two-finger motion is translated into a smooth scroll-wheel
    /// CGEvent stream (with phase Began/Changed/Ended), which apps interpret as
    /// trackpad scroll.  Disable to ignore second-finger contacts.
    @Published var twoFingerScroll: Bool = true {
        didSet { persist("twoFingerScroll", twoFingerScroll) }
    }
    /// When true, scroll direction is reversed relative to finger motion (classic
    /// mouse-wheel feel); when false, content follows finger movement.  Defaults to false.
    @Published var reverseScrollDirection: Bool = false {
        didSet { persist("naturalScrolling", reverseScrollDirection) }
    }
    /// When true (default), two-finger scroll emits the full Began/Changed/
    /// Ended phase envelope, which is what gives it iPad-style inertia in most
    /// apps. That envelope is rejected by the same class of gesture recognizer
    /// Pan View's momentum stream is (Calendar Month/Year, WebKit
    /// gesture-scroll) — turn off for those: dropping the phase field trades
    /// the inertia away for a stream that lands everywhere. Same on/off
    /// meaning as `ToolSettings.panScrollMomentum` for Pan View — momentum on
    /// by default everywhere, off trades it for reach.
    @Published var twoFingerScrollMomentum: Bool = true {
        didSet { persist("twoFingerScrollMomentum", twoFingerScrollMomentum) }
    }
    /// When true (and two-finger scroll is on), a pinch gesture posts ⌃+wheel
    /// events as a zoom stand-in for browsers/Electron. Off by default — pan
    /// scroll stays the primary two-finger behaviour.
    @Published var pinchZoomViaModifierWheel: Bool = false {
        didSet { persist("pinchZoomViaModifierWheel", pinchZoomViaModifierWheel) }
    }
    /// Active-touch-area mapping — independent from the pen's active area because
    /// users typically want the full surface for touch but a cropped area for pen
    /// work.  Coordinates are normalised 0..1 over the device's full touch surface.
    /// Defaults to the full surface.
    @Published var touchAreaX: Double = 0.0 {
        didSet { persist("touchAreaX", touchAreaX) }
    }
    @Published var touchAreaY: Double = 0.0 {
        didSet { persist("touchAreaY", touchAreaY) }
    }
    @Published var touchAreaWidth: Double = 1.0 {
        didSet { persist("touchAreaWidth", touchAreaWidth) }
    }
    @Published var touchAreaHeight: Double = 1.0 {
        didSet { persist("touchAreaHeight", touchAreaHeight) }
    }

    // MARK: - Touch ring & strips

    @Published var touchRingSlots: [ControlSlot] = ControlSlot.defaults {
        didSet { saveTouchRingSlots() }
    }
    @Published var touchRingActiveSlotIndex: Int = 0 {
        didSet { persist("touchRingActiveSlotIndex", touchRingActiveSlotIndex) }
    }

    // MARK: - Button bindings (JSON-encoded ButtonBinding)

    @Published var pen1Raw: String = "" { didSet { persist("penButton1Binding", pen1Raw) } }
    @Published var pen2Raw: String = "" { didSet { persist("penButton2Binding", pen2Raw) } }
    @Published var expressKeyRaw: String = "" {
        didSet {
            persist("expressKeyBindings", expressKeyRaw)
            _expressKeyCache = nil
        }
    }
    private var _expressKeyCache: [ButtonBinding]?
    @Published var bezelButtonRaw: String = "" {
        didSet {
            persist("bezelButtonBindings", bezelButtonRaw)
            _bezelButtonCache = nil
        }
    }
    private var _bezelButtonCache: [ButtonBinding]?
    @Published var touchRingButtonRaw: String = "" {
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
        get { ButtonBinding.decode(touchRingButtonRaw) ?? ButtonBinding(kind: .ringCycle) }
        set { touchRingButtonRaw = newValue.encoded }
    }

    var expressKeyBindings: [ButtonBinding] {
        get {
            if let cached = _expressKeyCache { return cached }
            let result: [ButtonBinding]
            if !expressKeyRaw.isEmpty,
                let data = expressKeyRaw.data(using: .utf8),
                let arr = try? JSONDecoder().decode([ButtonBinding].self, from: data)
            {
                var r = arr
                while r.count < 16 { r.append(.none) }
                result = Array(r.prefix(16))
            } else {
                result = Array(repeating: .none, count: 16)
            }
            _expressKeyCache = result
            return result
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                let s = String(data: data, encoding: .utf8)
            else { return }
            expressKeyRaw = s
        }
    }

    /// Bindings for a device's built-in bezel buttons (e.g. the Xencelabs
    /// Pen Display's 3 capacitive touch buttons, the Cintiq DTK-2400's OSD
    /// buttons) — kept separate from `expressKeyBindings` since some devices
    /// (DTK-2400) already use all 16 of those slots for toggle/express keys.
    var bezelButtonBindings: [ButtonBinding] {
        get {
            if let cached = _bezelButtonCache { return cached }
            let result: [ButtonBinding]
            if !bezelButtonRaw.isEmpty,
                let data = bezelButtonRaw.data(using: .utf8),
                let arr = try? JSONDecoder().decode([ButtonBinding].self, from: data)
            {
                var r = arr
                while r.count < 3 { r.append(.none) }
                result = Array(r.prefix(3))
            } else {
                result = Array(repeating: .none, count: 3)
            }
            _bezelButtonCache = result
            return result
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                let s = String(data: data, encoding: .utf8)
            else { return }
            bezelButtonRaw = s
        }
    }

    // MARK: - Presets

    /// A named configuration snapshot.  `overriddenKeys` tracks which settings
    /// the preset stores; all other keys fall through to device defaults.
    struct Profile: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var name: String
        var overriddenKeys: Set<String> = []

        /// Fields a future app version added that this build doesn't know
        /// about. Preserved verbatim on re-encode so editing a profile on an
        /// old build doesn't erase settings a newer build already wrote.
        private var unknownFields: [String: JSONValue] = [:]

        init(id: UUID = UUID(), name: String, overriddenKeys: Set<String> = []) {
            self.id = id
            self.name = name
            self.overriddenKeys = overriddenKeys
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id, name, overriddenKeys
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            overriddenKeys = try c.decode(Set<String>.self, forKey: .overriddenKeys)
            unknownFields = try UnknownFieldsCodec.captureUnknown(
                from: decoder, knownKeys: Set(CodingKeys.allCases.map(\.rawValue)))
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(overriddenKeys, forKey: .overriddenKeys)
            try UnknownFieldsCodec.encodeUnknown(unknownFields, to: encoder)
        }

        static func == (lhs: Profile, rhs: Profile) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name && lhs.overriddenKeys == rhs.overriddenKeys
        }
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

        /// See Profile.unknownFields — same forward-compatibility purpose.
        private var unknownFields: [String: JSONValue] = [:]

        init(bundleID: String, appName: String, overriddenKeys: Set<String> = []) {
            self.bundleID = bundleID
            self.appName = appName
            self.overriddenKeys = overriddenKeys
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case bundleID, appName, overriddenKeys
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bundleID = try c.decode(String.self, forKey: .bundleID)
            appName = try c.decode(String.self, forKey: .appName)
            overriddenKeys = try c.decode(Set<String>.self, forKey: .overriddenKeys)
            unknownFields = try UnknownFieldsCodec.captureUnknown(
                from: decoder, knownKeys: Set(CodingKeys.allCases.map(\.rawValue)))
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(bundleID, forKey: .bundleID)
            try c.encode(appName, forKey: .appName)
            try c.encode(overriddenKeys, forKey: .overriddenKeys)
            try UnknownFieldsCodec.encodeUnknown(unknownFields, to: encoder)
        }

        static func == (lhs: AppOverride, rhs: AppOverride) -> Bool {
            lhs.bundleID == rhs.bundleID && lhs.appName == rhs.appName
                && lhs.overriddenKeys == rhs.overriddenKeys
        }
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
    var driverOverride: AppOverride? = nil

    /// True while MockTab itself is the frontmost app.
    /// Set exclusively by handleAppOverrideActivation (AppWatcher).
    var isSelfFrontmost = true

    /// The override selected in the UI chip bar for editing.
    /// Set only by explicit user actions (chip tap, add/remove) — app-focus
    /// changes never move it, so the bar stays exactly as the user left it.
    /// Controls which prefix persist() writes to and which chip is highlighted.
    @Published var activeAppOverride: AppOverride? = nil

    /// The override whose values the published settings (and therefore the
    /// injector) should reflect right now: the chip-bar selection while the
    /// user is in MockTab editing, the frontmost app's override otherwise.
    /// All load-time override resolution must go through this.
    var effectiveOverride: AppOverride? {
        isSelfFrontmost ? activeAppOverride : driverOverride
    }

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
        activeTool.undoManager = undoManager
        reloadAll()
    }

    /// Instance-aware variant of `init(productID:)`: resolves the namespace
    /// through the registry's claim rule (see `loadForDevice(_:)` below).
    convenience init(instanceKey: DeviceInstanceKey) {
        self.init()
        loadForDevice(instanceKey)
    }

    // MARK: - Per-device loading

    /// Switches the settings backing store to the given device's namespace
    /// and reloads all values.  Called by TabletManager when a device connects.
    func loadForDevice(_ productID: Int) {
        let hex = String(productID, radix: 16, uppercase: true)
        loadForDevice(prefix: "device-0x\(hex).")
    }

    /// Instance-aware variant: resolves the namespace through the registry's
    /// claim-the-legacy-prefix rule, so the first physical unit of a model
    /// keeps the historical `device-0x{PID}.` prefix and later identical
    /// units get their own. The PID-only overload above stays for callers
    /// that predate instance identity (it always resolves to the legacy
    /// prefix, matching an empty instance token).
    func loadForDevice(_ instanceKey: DeviceInstanceKey) {
        loadForDevice(prefix: DeviceRegistry.shared.settingsPrefix(for: instanceKey))
    }

    private func loadForDevice(prefix: String) {
        devicePrefix = prefix
        toolCache.removeAll()
        activeTool = ToolSettings(prefix: devicePrefix)
        activeTool.undoManager = undoManager
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

    // MARK: - Undo/Redo support

    /// Snapshot of active area for undo/redo coalescing
    struct AreaSnapshot: Equatable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
    }

    /// Registers an undoable action with the current undoManager.
    ///
    /// `NSUndoManager` treats any `registerUndo` call made while it is
    /// actively undoing as belonging to the *redo* stack — so an `undo`
    /// closure that itself calls `record(...)` again (typically by calling
    /// the same mutating method with before/after swapped, as
    /// `recordAreaDrag` and `renameAppOverride` already do) gets real,
    /// indefinite undo/redo toggling for free. Call sites whose `undo`
    /// closure is a one-shot "restore to the old value" (most property
    /// setters) won't redo unless they're written the same self-recursive
    /// way. The undo block is responsible for restoring state; `persist()`
    /// fires normally either way.
    func record(_ actionName: String, undo: @escaping () -> Void) {
        guard let um = undoManager else { return }
        um.setActionName(actionName)
        um.registerUndo(withTarget: self) { [weak self] target in
            guard let self else { return }
            undo()
        }
    }

    /// Records an undoable/redoable change to a single value, given its old
    /// and new states and a closure that applies either one. Each invocation
    /// (by Undo or by Redo) re-registers itself with the two values swapped,
    /// so the change toggles back and forth indefinitely — the mechanical
    /// shape most `record(...)` call sites in this codebase already have
    /// (`let old = x; x = new; record("Name") { self.x = old }`), just
    /// generalized so it also supports redo. Prefer this over calling
    /// `record` directly for a plain property swap; use `record` directly
    /// when the change touches more than one value (see e.g.
    /// `importAppOverride`, `removeAppOverride`).
    func recordToggle<T>(_ actionName: String, from oldValue: T, to newValue: T, apply: @escaping (T) -> Void) {
        record(actionName) { [weak self] in
            apply(oldValue)
            self?.recordToggle(actionName, from: newValue, to: oldValue, apply: apply)
        }
    }

    /// Records a coalesced tablet area drag (one undo entry per completed gesture, not per frame).
    /// Call this once in DragGesture.onEnded with a snapshot captured at drag-start.
    func recordAreaDrag(before snap: AreaSnapshot) {
        record(String(localized: "Tablet Area")) { [weak self] in
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

}
