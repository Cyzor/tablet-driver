import Foundation
import SwiftUI
import AppKit
import Carbon

/// All user-configurable settings, persisted via UserDefaults with a per-device
/// key prefix so that each tablet remembers its own configuration independently.
///
/// On first load for a given device, the legacy unprefixed keys (from before
/// per-device support) are used as a fallback, providing seamless migration.
@MainActor
final class TabletSettings: ObservableObject {

    // MARK: - Per-device backing store

    /// Current UserDefaults key prefix, e.g. `"device-0x0357."`.
    /// Changed by `loadForDevice(_:)` when a tablet connects.
    private(set) var devicePrefix = "device-default."

    /// Suppresses UserDefaults writes during `loadForDevice()`.
    private var isLoading = false

    private let ud = UserDefaults.standard

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

    // MARK: - Init

    init() { reloadAll() }

    // MARK: - Per-device loading

    /// Switches the settings backing store to the given device's namespace
    /// and reloads all values.  Called by TabletManager when a device connects.
    func loadForDevice(_ productID: Int) {
        let hex = String(productID, radix: 16, uppercase: true)
        devicePrefix = "device-0x\(hex)."
        reloadAll()
    }

    /// Reloads every setting from UserDefaults using the current `devicePrefix`.
    /// Falls back to legacy unprefixed keys (pre-per-device migration), then
    /// to compile-time defaults.
    private func reloadAll() {
        isLoading = true
        activeAreaX          = loadDouble("activeAreaX",         default: 0.0)
        activeAreaY          = loadDouble("activeAreaY",         default: 0.0)
        activeAreaWidth      = loadDouble("activeAreaWidth",     default: 1.0)
        activeAreaHeight     = loadDouble("activeAreaHeight",    default: 1.0)
        proportionalMapping  = loadBool("proportionalMapping",   default: true)
        targetDisplayIndex   = loadInt("targetDisplayIndex",     default: 0)
        smoothingStrength    = loadDouble("smoothingStrength",   default: 0.0)
        doubleClickDistance  = loadDouble("doubleClickDistance",  default: 10.0)
        pen1Raw              = loadString("penButton1Binding",   default: "")
        pen2Raw              = loadString("penButton2Binding",   default: "")
        expressKeyRaw        = loadString("expressKeyBindings",  default: "")
        loadPressureCurve()
        isLoading = false
    }

    // MARK: - Persistence helpers

    /// Writes a value to UserDefaults under the current device prefix.
    /// No-ops while `isLoading` to avoid echoing values back during reload.
    private func persist(_ key: String, _ value: Any) {
        guard !isLoading else { return }
        ud.set(value, forKey: devicePrefix + key)
    }

    // Fallback chain: prefixed key → legacy unprefixed key → compile-time default.

    private func loadDouble(_ key: String, default d: Double) -> Double {
        if ud.object(forKey: devicePrefix + key) != nil { return ud.double(forKey: devicePrefix + key) }
        if ud.object(forKey: key) != nil                { return ud.double(forKey: key) }
        return d
    }

    private func loadBool(_ key: String, default d: Bool) -> Bool {
        if ud.object(forKey: devicePrefix + key) != nil { return ud.bool(forKey: devicePrefix + key) }
        if ud.object(forKey: key) != nil                { return ud.bool(forKey: key) }
        return d
    }

    private func loadInt(_ key: String, default d: Int) -> Int {
        if ud.object(forKey: devicePrefix + key) != nil { return ud.integer(forKey: devicePrefix + key) }
        if ud.object(forKey: key) != nil                { return ud.integer(forKey: key) }
        return d
    }

    private func loadString(_ key: String, default d: String) -> String {
        if let v = ud.string(forKey: devicePrefix + key) { return v }
        if let v = ud.string(forKey: key)                { return v }
        return d
    }

    // MARK: - Pressure curve persistence

    private func savePressureCurve() {
        guard !isLoading else { return }
        if let data = try? JSONEncoder().encode(pressureCurve) {
            ud.set(data, forKey: devicePrefix + "pressureCurve")
        }
    }

    private func loadPressureCurve() {
        let data = ud.data(forKey: devicePrefix + "pressureCurve")
                ?? ud.data(forKey: "pressureCurve")
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
