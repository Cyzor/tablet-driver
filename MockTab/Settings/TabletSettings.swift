// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Carbon
import Foundation
import OSLog
import SwiftUI
import TabletKit

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "settings")

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
                  let data = calibrationJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([CalibrationEntry].self, from: data)) ?? []
        }
        set {
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
    @Published var tipUpAssist: Bool = false {
        didSet { persist("tipUpAssist", tipUpAssist) }
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

    // MARK: - Temporary compatibility shim
    // Binds to the active slot action. Used by ButtonMappingView during Phase 3 UI work.
    // Remove once all callsites are updated to use touchRingSlots.
    var touchRingMode: TouchRingMode {
        get {
            guard touchRingSlots.indices.contains(touchRingActiveSlotIndex) else { return .scroll }
            switch touchRingSlots[touchRingActiveSlotIndex].action {
            case .scroll: return .scroll
            case .off, .skip: return .off
            case .keyPress: return .scroll
            }
        }
        set {
            touchRingSlots = ControlSlot.defaults
            touchRingActiveSlotIndex = 0
        }
    }

    // Backward compat for strip modes - redirects to ring active slot.
    var touchStrip1Mode: TouchRingMode {
        get { touchRingMode }
        set { touchRingMode = newValue }
    }
    var touchStrip2Mode: TouchRingMode {
        get { touchRingMode }
        set { touchRingMode = newValue }
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
        get { ButtonBinding.decode(touchRingButtonRaw) ?? .none }
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

    /// True while MockTab itself is the frontmost app.
    /// Set exclusively by handleAppOverrideActivation (AppWatcher).
    private var isSelfFrontmost = true

    /// The override selected in the UI chip bar for editing.
    /// Set only by explicit user actions (chip tap, add/remove) — app-focus
    /// changes never move it, so the bar stays exactly as the user left it.
    /// Controls which prefix persist() writes to and which chip is highlighted.
    @Published var activeAppOverride: AppOverride? = nil

    /// The override whose values the published settings (and therefore the
    /// injector) should reflect right now: the chip-bar selection while the
    /// user is in MockTab editing, the frontmost app's override otherwise.
    /// All load-time override resolution must go through this.
    private var effectiveOverride: AppOverride? {
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
        tipUpAssist = loadBool("tipUpAssist", default: false)
        touchEnabled = loadBool("touchEnabled", default: false)
        touchSensitivity = Swift.max(0.25, Swift.min(loadDouble("touchSensitivity", default: 1.0), 4.0))
        tapToClick = loadBool("tapToClick", default: false)
        twoFingerScroll = loadBool("twoFingerScroll", default: true)
        reverseScrollDirection = loadBool("naturalScrolling", default: false)
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

    /// Routes a write to the effective app override, then profile, then device
    /// namespace. Marks the key as overridden in whichever layer receives the
    /// write. Uses `effectiveOverride` (not the chip-bar selection) because
    /// some writes originate from hardware while another app is frontmost —
    /// display-toggle express key, touch-ring mode cycle — and must land in
    /// the frontmost app's override, not whichever chip the user left selected.
    /// No-ops while `isLoading` to avoid echoing values back during reload.
    private func persist(_ key: String, _ value: Any) {
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
        guard let data,
            let curve = try? JSONDecoder().decode(BezierCurve.self, from: data)
        else { return }
        pressureCurve = curve
    }

    // MARK: - Touch Ring Slot persistence

    /// Saves touchRingSlots using the same override/preset/device prefix logic as other fields.
    private func saveTouchRingSlots() {
        guard !isLoading else { return }
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

        if let data, let slots = try? JSONDecoder().decode([ControlSlot].self, from: data) {
            touchRingSlots = slots
            return
        }

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
        // Default express key bindings: keys 1-4 are modifier keys (⌘ ⌥ ⌃ ⇧).
        // Rest are unbound (.none).
        // 16-entry layout for dual-ring Cintiq devices (indices 0–15).
        // Indices 0–2  = left  toggle buttons (near ring), 3–7  = left  express keys.
        // Indices 8–10 = right toggle buttons (near ring), 11–15 = right express keys.
        // Devices with only 8 buttons use indices 0–7; the upper 8 entries are ignored.
        //
        // Xencelabs Quick Keys is the one exception: its index 8 isn't a mirrored
        // express key at all — XencelabsDecoder.decodeAux maps it to the puck's
        // physical mode button (see that file's header comment), which this driver
        // treats as "Ring: Cycle". Defaulting it to ⌘ like the Cintiq mirror slot
        // meant every mode-button press quietly asserted Command, which then rode
        // along with whichever express key the user pressed next and wouldn't let go.
        expressKeyBindings = [
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
