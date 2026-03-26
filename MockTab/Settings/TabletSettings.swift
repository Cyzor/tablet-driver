import Foundation
import SwiftUI
import AppKit
import Carbon

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

    private let ud = UserDefaults.standard

    // MARK: - Per-tool settings

    /// The tool settings currently active on this device.
    /// Starts as the device-default tool; swapped by TabletManager on tool-enter.
    @Published var activeTool: ToolSettings = ToolSettings(prefix: "device-default.")

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

    @Published var activeAreaX:      Double = 0.0 { didSet { persist("activeAreaX", activeAreaX) } }
    @Published var activeAreaY:      Double = 0.0 { didSet { persist("activeAreaY", activeAreaY) } }
    @Published var activeAreaWidth:  Double = 1.0 { didSet { persist("activeAreaWidth", activeAreaWidth) } }
    @Published var activeAreaHeight: Double = 1.0 { didSet { persist("activeAreaHeight", activeAreaHeight) } }

    /// When true, the active area is cropped to match the target display's aspect ratio
    /// so the pen moves without distortion.  Enabled by default.
    @Published var proportionalMapping: Bool = true { didSet { persist("proportionalMapping", proportionalMapping) } }

    // MARK: - Display mapping

    /// 0 = primary display, 1..N = specific display by CGGetActiveDisplayList index.
    @Published var targetDisplayIndex: Int = 0 { didSet { persist("targetDisplayIndex", targetDisplayIndex) } }

    // MARK: - Pressure curve

    @Published var pressureCurve: BezierCurve = .linear {
        didSet { savePressureCurve() }
    }

    // MARK: - Input smoothing

    @Published var smoothingStrength:  Double = 0.0  { didSet { persist("smoothingStrength", smoothingStrength) } }
    @Published var doubleClickDistance: Double = 10.0 { didSet { persist("doubleClickDistance", doubleClickDistance) } }

    // MARK: - Button bindings (JSON-encoded ButtonBinding)

    @Published private var pen1Raw: String = ""       { didSet { persist("penButton1Binding", pen1Raw) } }
    @Published private var pen2Raw: String = ""       { didSet { persist("penButton2Binding", pen2Raw) } }
    @Published private var expressKeyRaw: String = "" { didSet { persist("expressKeyBindings", expressKeyRaw) } }

    var penButton1Binding: ButtonBinding {
        get { ButtonBinding.decode(pen1Raw) ?? .rightClick }
        set { pen1Raw = newValue.encoded }
    }

    var penButton2Binding: ButtonBinding {
        get { ButtonBinding.decode(pen2Raw) ?? .middleClick }
        set { pen2Raw = newValue.encoded }
    }

    var expressKeyBindings: [ButtonBinding] {
        get {
            guard !expressKeyRaw.isEmpty,
                  let data = expressKeyRaw.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([ButtonBinding].self, from: data)
            else { return Array(repeating: .none, count: 8) }
            var res = arr
            while res.count < 8 { res.append(.none) }
            return Array(res.prefix(8))
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let s = String(data: data, encoding: .utf8) else { return }
            expressKeyRaw = s
        }
    }

    // MARK: - Presets

    /// A named configuration snapshot.  `overriddenKeys` tracks which settings
    /// the preset stores; all other keys fall through to device defaults.
    struct Preset: Identifiable, Codable, Equatable {
        var id:            UUID        = UUID()
        var name:          String
        var overriddenKeys: Set<String> = []
    }

    /// A mapping from one app (by bundle ID) to a preset.
    /// Stored per device; used by app auto-switching.
    struct AppPresetBinding: Identifiable, Codable, Equatable {
        var id:       String { bundleID }
        var bundleID: String
        var appName:  String   // display name captured at bind time
        var presetID: UUID
    }

    /// All presets saved for the current device.
    @Published var presets: [Preset] = []

    /// The currently active preset, or `nil` when using raw device settings.
    @Published var activePreset: Preset? = nil

    /// How the current preset was activated — for status display only, not persisted.
    enum ActivationSource: Equatable {
        case manual
        case app(bundleID: String, name: String)
    }
    @Published var activationSource: ActivationSource = .manual

    /// When true, switching the frontmost app automatically activates the bound preset.
    @Published var autoSwitchEnabled: Bool = false { didSet { persist("autoSwitchEnabled", autoSwitchEnabled) } }

    /// Per-app preset assignments for this device.
    @Published var appBindings: [AppPresetBinding] = []

    // MARK: - Init

    /// Creates a settings instance.  If `productID` is provided, the backing
    /// store is immediately switched to that device's namespace — useful for
    /// constructing a pre-loaded settings object inside a `DeviceContext`.
    init(productID: Int? = nil) {
        if let pid = productID {
            let hex = String(pid, radix: 16, uppercase: true)
            devicePrefix = "device-0x\(hex)."
            loadPresetList()
            loadAppBindings()
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
        loadPresetList()
        loadAppBindings()
        reloadAll()
        activationSource = .manual
    }

    // MARK: - Preset management

    /// UserDefaults key prefix for a specific preset's overridden values.
    private func presetKeyPrefix(_ preset: Preset) -> String {
        "\(devicePrefix)preset-\(preset.id.uuidString)."
    }

    /// Activates `preset` (or pass `nil` to revert to raw device settings).
    /// Marks the source as `.manual` and republishes all settings values.
    func activate(_ preset: Preset?) {
        activePreset = preset
        saveActivePresetID()
        reloadAll()
        activationSource = .manual
    }

    /// Snapshots the current in-memory settings into a new preset, saves it,
    /// and makes it active.
    func saveAsPreset(name: String) {
        var preset = Preset(name: name)
        let prefix = presetKeyPrefix(preset)

        // Copy every current live value into the preset namespace.
        ud.set(activeAreaX,         forKey: prefix + "activeAreaX")
        ud.set(activeAreaY,         forKey: prefix + "activeAreaY")
        ud.set(activeAreaWidth,     forKey: prefix + "activeAreaWidth")
        ud.set(activeAreaHeight,    forKey: prefix + "activeAreaHeight")
        ud.set(proportionalMapping, forKey: prefix + "proportionalMapping")
        ud.set(targetDisplayIndex,  forKey: prefix + "targetDisplayIndex")
        ud.set(smoothingStrength,   forKey: prefix + "smoothingStrength")
        ud.set(doubleClickDistance, forKey: prefix + "doubleClickDistance")
        ud.set(pen1Raw,             forKey: prefix + "penButton1Binding")
        ud.set(pen2Raw,             forKey: prefix + "penButton2Binding")
        ud.set(expressKeyRaw,       forKey: prefix + "expressKeyBindings")
        if let data = try? JSONEncoder().encode(pressureCurve) {
            ud.set(data, forKey: prefix + "pressureCurve")
        }

        preset.overriddenKeys = [
            "activeAreaX", "activeAreaY", "activeAreaWidth", "activeAreaHeight",
            "proportionalMapping", "targetDisplayIndex", "smoothingStrength",
            "doubleClickDistance", "penButton1Binding", "penButton2Binding",
            "expressKeyBindings", "pressureCurve"
        ]

        presets.append(preset)
        savePresetList()
        activePreset = preset
        saveActivePresetID()
    }

    /// Renames `preset` to `newName`.
    func renamePreset(_ preset: Preset, to newName: String) {
        guard let idx = presets.firstIndex(of: preset) else { return }
        presets[idx].name = newName
        if activePreset?.id == preset.id { activePreset?.name = newName }
        savePresetList()
    }

    /// Deletes `preset` and all its stored values.
    /// Removes any app bindings pointing to it.  If it was active, reverts to device defaults.
    func deletePreset(_ preset: Preset) {
        let prefix = presetKeyPrefix(preset)
        let allKeys = ["activeAreaX", "activeAreaY", "activeAreaWidth", "activeAreaHeight",
                       "proportionalMapping", "targetDisplayIndex", "smoothingStrength",
                       "doubleClickDistance", "penButton1Binding", "penButton2Binding",
                       "expressKeyBindings", "pressureCurve"]
        for key in allKeys { ud.removeObject(forKey: prefix + key) }
        presets.removeAll { $0.id == preset.id }
        // Remove app bindings that referenced this preset.
        let before = appBindings.count
        appBindings.removeAll { $0.presetID == preset.id }
        if appBindings.count != before { saveAppBindings() }
        if activePreset?.id == preset.id {
            activate(nil)
        } else {
            savePresetList()
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
            .flatMap { b in presets.first { $0.id == b.presetID } }
        guard target?.id != activePreset?.id || activationSource == .manual else {
            // Same preset already active via auto-switch — just refresh the label.
            activationSource = .app(bundleID: bundleID, name: appName)
            return
        }
        if target?.id != activePreset?.id {
            activePreset = target
            saveActivePresetID()
            reloadAll()
        }
        activationSource = .app(bundleID: bundleID, name: appName)
    }

    /// Binds the currently frontmost app to `preset`.
    /// Replaces any existing binding for that bundle ID.
    func bindFrontmostApp(to preset: Preset) {
        guard let app      = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return }
        let name = app.localizedName ?? bundleID
        appBindings.removeAll { $0.bundleID == bundleID }
        appBindings.append(AppPresetBinding(bundleID: bundleID,
                                            appName:  name,
                                            presetID: preset.id))
        saveAppBindings()
    }

    /// Removes the app binding with the given bundle ID.
    func unbindApp(bundleID: String) {
        appBindings.removeAll { $0.bundleID == bundleID }
        saveAppBindings()
    }

    // MARK: - Preset persistence

    private var presetListKey:     String { devicePrefix + "_presets" }
    private var activePresetIDKey: String { devicePrefix + "_activePreset" }

    private func loadPresetList() {
        guard let data = ud.data(forKey: presetListKey),
              let list = try? JSONDecoder().decode([Preset].self, from: data)
        else { presets = []; activePreset = nil; return }
        presets = list
        if let uuidStr = ud.string(forKey: activePresetIDKey),
           let uuid    = UUID(uuidString: uuidStr),
           let match   = list.first(where: { $0.id == uuid }) {
            activePreset = match
        } else {
            activePreset = nil
        }
    }

    private func savePresetList() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        ud.set(data, forKey: presetListKey)
    }

    private func saveActivePresetID() {
        if let id = activePreset?.id.uuidString {
            ud.set(id, forKey: activePresetIDKey)
        } else {
            ud.removeObject(forKey: activePresetIDKey)
        }
    }

    private var appBindingsKey: String { devicePrefix + "_appBindings" }

    private func saveAppBindings() {
        guard let data = try? JSONEncoder().encode(appBindings) else { return }
        ud.set(data, forKey: appBindingsKey)
    }

    private func loadAppBindings() {
        guard let data = ud.data(forKey: appBindingsKey),
              let list = try? JSONDecoder().decode([AppPresetBinding].self, from: data)
        else { appBindings = []; return }
        appBindings = list
    }

    // MARK: - Reload

    /// Reloads every setting from UserDefaults using the current `devicePrefix`
    /// and `activePreset`.  Falls back to legacy unprefixed keys, then to
    /// compile-time defaults.
    private func reloadAll() {
        isLoading = true
        activeAreaX          = loadDouble("activeAreaX",        default: 0.0)
        activeAreaY          = loadDouble("activeAreaY",        default: 0.0)
        activeAreaWidth      = loadDouble("activeAreaWidth",    default: 1.0)
        activeAreaHeight     = loadDouble("activeAreaHeight",   default: 1.0)
        proportionalMapping  = loadBool("proportionalMapping",  default: true)
        targetDisplayIndex   = loadInt("targetDisplayIndex",    default: 0)
        smoothingStrength    = loadDouble("smoothingStrength",  default: 0.0)
        doubleClickDistance  = loadDouble("doubleClickDistance", default: 10.0)
        pen1Raw              = loadString("penButton1Binding",  default: "")
        pen2Raw              = loadString("penButton2Binding",  default: "")
        expressKeyRaw        = loadString("expressKeyBindings", default: "")
        autoSwitchEnabled    = loadBool("autoSwitchEnabled",    default: false)
        loadPressureCurve()
        isLoading = false
    }

    // MARK: - Persistence helpers

    /// Routes a write to the active preset's namespace (marking the key as
    /// overridden) or to the device namespace when no preset is active.
    /// No-ops while `isLoading` to avoid echoing values back during reload.
    private func persist(_ key: String, _ value: Any) {
        guard !isLoading else { return }
        if var preset = activePreset {
            ud.set(value, forKey: presetKeyPrefix(preset) + key)
            guard !preset.overriddenKeys.contains(key) else { return }
            preset.overriddenKeys.insert(key)
            activePreset = preset
            if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
                presets[idx] = preset
            }
            savePresetList()
        } else {
            ud.set(value, forKey: devicePrefix + key)
        }
    }

    // MARK: - Load helpers

    // Fallback chain: active preset (if key is overridden) → device prefix
    //                 → legacy unprefixed key → compile-time default.

    private func loadDouble(_ key: String, default d: Double) -> Double {
        if let preset = activePreset, preset.overriddenKeys.contains(key),
           ud.object(forKey: presetKeyPrefix(preset) + key) != nil {
            return ud.double(forKey: presetKeyPrefix(preset) + key)
        }
        if ud.object(forKey: devicePrefix + key) != nil { return ud.double(forKey: devicePrefix + key) }
        if ud.object(forKey: key) != nil                { return ud.double(forKey: key) }
        return d
    }

    private func loadBool(_ key: String, default d: Bool) -> Bool {
        if let preset = activePreset, preset.overriddenKeys.contains(key),
           ud.object(forKey: presetKeyPrefix(preset) + key) != nil {
            return ud.bool(forKey: presetKeyPrefix(preset) + key)
        }
        if ud.object(forKey: devicePrefix + key) != nil { return ud.bool(forKey: devicePrefix + key) }
        if ud.object(forKey: key) != nil                { return ud.bool(forKey: key) }
        return d
    }

    private func loadInt(_ key: String, default d: Int) -> Int {
        if let preset = activePreset, preset.overriddenKeys.contains(key),
           ud.object(forKey: presetKeyPrefix(preset) + key) != nil {
            return ud.integer(forKey: presetKeyPrefix(preset) + key)
        }
        if ud.object(forKey: devicePrefix + key) != nil { return ud.integer(forKey: devicePrefix + key) }
        if ud.object(forKey: key) != nil                { return ud.integer(forKey: key) }
        return d
    }

    private func loadString(_ key: String, default d: String) -> String {
        if let preset = activePreset, preset.overriddenKeys.contains(key) {
            if let v = ud.string(forKey: presetKeyPrefix(preset) + key) { return v }
        }
        if let v = ud.string(forKey: devicePrefix + key) { return v }
        if let v = ud.string(forKey: key)                { return v }
        return d
    }

    // MARK: - Pressure curve persistence

    private func savePressureCurve() {
        guard !isLoading else { return }
        guard let data = try? JSONEncoder().encode(pressureCurve) else { return }
        if var preset = activePreset {
            ud.set(data, forKey: presetKeyPrefix(preset) + "pressureCurve")
            guard !preset.overriddenKeys.contains("pressureCurve") else { return }
            preset.overriddenKeys.insert("pressureCurve")
            activePreset = preset
            if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
                presets[idx] = preset
            }
            savePresetList()
        } else {
            ud.set(data, forKey: devicePrefix + "pressureCurve")
        }
    }

    private func loadPressureCurve() {
        let data: Data?
        if let preset = activePreset, preset.overriddenKeys.contains("pressureCurve") {
            data = ud.data(forKey: presetKeyPrefix(preset) + "pressureCurve")
                ?? ud.data(forKey: devicePrefix + "pressureCurve")
                ?? ud.data(forKey: "pressureCurve")
        } else {
            data = ud.data(forKey: devicePrefix + "pressureCurve")
                ?? ud.data(forKey: "pressureCurve")
        }
        guard let data,
              let curve = try? JSONDecoder().decode(BezierCurve.self, from: data)
        else { return }
        pressureCurve = curve
    }

    // MARK: - Reset

    func resetToDefaults() {
        activeAreaX = 0; activeAreaY = 0
        activeAreaWidth = 1; activeAreaHeight = 1
        proportionalMapping = true
        targetDisplayIndex = 0
        pressureCurve = .linear
        smoothingStrength = 0.0
        doubleClickDistance = 10.0
        pen1Raw = ""; pen2Raw = ""; expressKeyRaw = ""
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

// MARK: - ButtonBinding

/// A hardware button assignment: a predefined click action, a recorded key combo, or nothing.
struct ButtonBinding: Codable, Equatable {

    enum Kind: String, Codable {
        case none, leftClick, rightClick, middleClick, keyCombo
    }

    var kind:          Kind   = .none
    var keyCode:       UInt16 = 0
    var modifierFlags: UInt64 = 0   // CGEventFlags raw value
    var keyLabel:      String = ""  // display string for the key (e.g. "Z", "↩", "Space")

    // MARK: Presets

    static let none        = ButtonBinding()
    static let leftClick   = ButtonBinding(kind: .leftClick)
    static let rightClick  = ButtonBinding(kind: .rightClick)
    static let middleClick = ButtonBinding(kind: .middleClick)

    // MARK: Init

    init(kind: Kind = .none, keyCode: UInt16 = 0,
         modifierFlags: UInt64 = 0, keyLabel: String = "") {
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
        if flags.contains(.command)  { f.insert(.maskCommand) }
        if flags.contains(.shift)    { f.insert(.maskShift) }
        if flags.contains(.option)   { f.insert(.maskAlternate) }
        if flags.contains(.control)  { f.insert(.maskControl) }
        modifierFlags = f.rawValue
        if      flags.contains(.command)  { keyCode = 55 }  // kVK_Command
        else if flags.contains(.shift)    { keyCode = 56 }  // kVK_Shift
        else if flags.contains(.option)   { keyCode = 58 }  // kVK_Option
        else if flags.contains(.control)  { keyCode = 59 }  // kVK_Control
        else                              { keyCode = 0  }
    }

    /// Build a key-combo binding from a captured NSEvent keyDown.
    init(fromKey event: NSEvent) {
        kind = .keyCombo
        keyCode = event.keyCode
        // Map NSEvent.ModifierFlags → CGEventFlags raw value.
        let ns = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var f = CGEventFlags()
        if ns.contains(.command)  { f.insert(.maskCommand) }
        if ns.contains(.shift)    { f.insert(.maskShift) }
        if ns.contains(.option)   { f.insert(.maskAlternate) }
        if ns.contains(.control)  { f.insert(.maskControl) }
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
        case .leftClick:   return .left
        case .rightClick:  return .right
        case .middleClick: return .center
        default:           return nil
        }
    }

    // MARK: Display

    var displayLabel: String {
        switch kind {
        case .none:        return "None"
        case .leftClick:   return "Left Click"
        case .rightClick:  return "Right Click"
        case .middleClick: return "Middle Click"
        case .keyCombo:
            let f = CGEventFlags(rawValue: modifierFlags)
            var s = ""
            if f.contains(.maskControl)   { s += "⌃" }
            if f.contains(.maskAlternate) { s += "⌥" }
            if f.contains(.maskShift)     { s += "⇧" }
            if f.contains(.maskCommand)   { s += "⌘" }
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
        case 36:  return "↩"    // Return
        case 48:  return "⇥"    // Tab
        case 49:  return "Space"
        case 51:  return "⌫"    // Delete
        case 53:  return "⎋"    // Escape
        case 71:  return "⌧"    // Clear
        case 76:  return "⌅"    // Enter (numpad)
        case 115: return "↖"    // Home
        case 116: return "⇞"    // Page Up
        case 117: return "⌦"    // Forward Delete
        case 119: return "↘"    // End
        case 121: return "⇟"    // Page Down
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:  break
        }

        // Translate with the full modifier state (handles Dvorak Qwerty-Command, etc.).
        if let ch = translateKeyCode(keyCode, modifiers: modifiers) { return ch }
        // Fallback: translate with no modifiers to get the bare layout character.
        return translateKeyCode(keyCode, modifiers: []) ?? "?"
    }

    /// Calls `UCKeyTranslate` with the current keyboard layout and returns the
    /// printable character for the given keyCode + modifier combination,
    /// or `nil` if the result is empty or a control character.
    private static func translateKeyCode(_ keyCode: UInt16,
                                         modifiers: NSEvent.ModifierFlags) -> String? {
        guard
            let source  = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let cfData = unsafeBitCast(rawData, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(cfData) else { return nil }

        // Build the Carbon modifier key state for UCKeyTranslate.
        // Each constant is the old Mac OS modifier bit >> 8:
        //   cmdKey = 0x0100, shiftKey = 0x0200, alphaLock = 0x0400,
        //   optionKey = 0x0800, controlKey = 0x1000
        var carbonMods: UInt32 = 0
        if modifiers.contains(.command)  { carbonMods |= 1  }
        if modifiers.contains(.shift)    { carbonMods |= 2  }
        if modifiers.contains(.capsLock) { carbonMods |= 4  }
        if modifiers.contains(.option)   { carbonMods |= 8  }
        if modifiers.contains(.control)  { carbonMods |= 16 }

        var chars:     [UniChar] = [0, 0, 0, 0]
        var charCount: Int      = 0
        var deadState: UInt32   = 0

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

        let str = String(chars.prefix(Int(charCount)).compactMap { Unicode.Scalar($0).map(Character.init) })
        // Discard control characters (some layouts return e.g. ETX for ⌘C
        // when Command is not in their modifier table).
        guard str.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { return nil }
        return str.uppercased()
    }
}
