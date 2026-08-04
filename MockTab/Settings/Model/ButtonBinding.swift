// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Carbon
import Foundation

// MARK: - ButtonBinding

/// A hardware button assignment: a predefined click action, a recorded key combo, or nothing.
struct ButtonBinding: Codable, Equatable {

    enum Kind: String, Codable {
        case none, leftClick, rightClick, middleClick, middleClickWithTip, eraser, keyCombo,
            displayToggle, doubleClick, spacebar, ringCycle, ringSelectSlot, scrollDrag,
            relativeModeToggle
    }

    var kind: Kind = .none
    var keyCode: UInt16 = 0
    var modifierFlags: UInt64 = 0  // CGEventFlags raw value
    var keyLabel: String = ""  // display string for the key (e.g. "Z", "↩", "Space")

    /// Fields a future app version added that this build doesn't know about.
    /// Preserved verbatim on re-encode — see TabletSettings.Profile.unknownFields.
    /// Note: this only helps with *added fields*; an unrecognized `kind` raw
    /// value still fails to decode, since Kind has no "unknown case" slot.
    private var unknownFields: [String: JSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, keyCode, modifierFlags, keyLabel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        keyCode = try c.decode(UInt16.self, forKey: .keyCode)
        modifierFlags = try c.decode(UInt64.self, forKey: .modifierFlags)
        keyLabel = try c.decode(String.self, forKey: .keyLabel)
        unknownFields = try UnknownFieldsCodec.captureUnknown(
            from: decoder, knownKeys: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(keyCode, forKey: .keyCode)
        try c.encode(modifierFlags, forKey: .modifierFlags)
        try c.encode(keyLabel, forKey: .keyLabel)
        try UnknownFieldsCodec.encodeUnknown(unknownFields, to: encoder)
    }

    static func == (lhs: ButtonBinding, rhs: ButtonBinding) -> Bool {
        lhs.kind == rhs.kind && lhs.keyCode == rhs.keyCode
            && lhs.modifierFlags == rhs.modifierFlags && lhs.keyLabel == rhs.keyLabel
    }

    // MARK: Presets

    static let none = ButtonBinding()
    static let leftClick = ButtonBinding(kind: .leftClick)
    static let rightClick = ButtonBinding(kind: .rightClick)
    static let middleClick = ButtonBinding(kind: .middleClick)
    static let eraser = ButtonBinding(kind: .eraser)
    static let doubleClick = ButtonBinding(kind: .doubleClick)
    static let spacebar = ButtonBinding(kind: .spacebar)
    static let scrollDrag = ButtonBinding(kind: .scrollDrag)

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
        case .middleClick, .middleClickWithTip: return .center
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
        case .middleClickWithTip:
            return String(
                localized: "Middle Click + Tip",
                comment: "Button action: middle click with simulated tip pressure, for apps like SketchUp"
            )
        case .eraser:
            return String(localized: "Eraser", comment: "Button action: switch to eraser tool")
        case .displayToggle:
            return String(
                localized: "Toggle Display", comment: "Button action: cycle through displays")
        case .doubleClick:
            return String(localized: "Double Click", comment: "Button action: double-click")
        case .spacebar: return String(localized: "Spacebar", comment: "Button action: spacebar key")
        case .ringCycle:
            return String(localized: "Ring: Cycle", comment: "Button action: cycle ring mode")
        case .ringSelectSlot:
            return String(
                localized: "Ring: Mode \(keyCode + 1)", comment: "Button action: jump to ring slot")
        case .scrollDrag:
            return String(
                localized: "Pan View",
                comment: "Button action: hold to pan/scroll with pen motion")
        case .relativeModeToggle:
            return String(
                localized: "Toggle Relative Mode",
                comment: "Button action: switch between absolute and relative cursor movement")
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
        case "Middle Click + Tip": return ButtonBinding(kind: .middleClickWithTip)
        case "Eraser": return .eraser
        case "Pan View": return .scrollDrag
        case "Scroll Drag": return .scrollDrag  // pre-rename label; keeps older exported profiles importable
        case "Toggle Display": return ButtonBinding(kind: .displayToggle)
        case "Toggle Relative Mode": return ButtonBinding(kind: .relativeModeToggle)
        case "Ring: Cycle": return ButtonBinding(kind: .ringCycle)
        default:
            if label.hasPrefix("Ring: Mode ") {
                let numStr = label.dropFirst("Ring: Mode ".count)
                if let num = Int(numStr), num > 0 {
                    return ButtonBinding(kind: .ringSelectSlot, keyCode: UInt16(num - 1))
                }
            }
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
