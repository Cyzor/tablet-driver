// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Finds the key that types a character on a keyboard layout, as MockTab
// stores shortcuts: a key code plus modifiers. It reads the layout's own key
// table, so any layout works, including ones that switch keys while ⌘ is
// down (Dvorak – QWERTY ⌘) and ones that need ⌥ for brackets (German).

import Carbon
import Foundation

/// Where a character sits on a keyboard layout.
struct LayoutKey: Equatable {
    let keyCode: UInt16
    /// Modifiers the character needs beyond the shortcut's own, such as
    /// Shift for # on a U.S. layout or Option for [ on a German one.
    var adds: KeyModifiers = []
    /// No added modifiers, not a dead key, and on the layout in use.
    var exact = true
    /// The key's label in MockTab, set by `KeyboardLayout.lookup`.
    var label: String?
}

/// Capitals, as on key caps, unless that changes the text (ß stays ß).
func keyCap(_ s: String) -> String {
    let upper = s.uppercased()
    return upper.count == s.count ? upper : s
}

/// The key that types a character, with ⌘ held when `command` is true.
typealias LayoutLookup = (_ character: Character, _ command: Bool) -> LayoutKey?

struct KeyboardLayout {
    let id: String
    let name: String
    let isASCIICapable: Bool
    private let data: Data
    private let plain: [Character: LayoutKey]
    private let command: [Character: LayoutKey]

    init?(_ source: TISInputSource) {
        func property<T>(_ key: CFString) -> T? {
            TISGetInputSourceProperty(source, key).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as? T } ?? nil
        }
        guard let layoutData: Data = property(kTISPropertyUnicodeKeyLayoutData) else { return nil }
        data = layoutData
        id = property(kTISPropertyInputSourceID) ?? ""
        name = property(kTISPropertyLocalizedName) ?? id
        isASCIICapable = property(kTISPropertyInputSourceIsASCIICapable) ?? false
        plain = Self.table(data, holding: [])
        command = Self.table(data, holding: .command)
    }

    func key(_ c: Character, command held: Bool) -> LayoutKey? { (held ? command : plain)[c] }

    /// The one character a key types with `mods` held, and whether it's a
    /// dead key, which types nothing until the next key.
    func types(_ keyCode: UInt16, holding mods: KeyModifiers) -> (Character, dead: Bool)? {
        Self.typed(data, keyCode, mods)
    }

    /// The label MockTab gives a key, as macOS menus show shortcuts: the
    /// key's own character, or with ⌘ held the one ⌘ types.
    func label(_ keyCode: UInt16, command: Bool) -> String? {
        let c = (command ? types(keyCode, holding: .command) : nil) ?? types(keyCode, holding: [])
        return c.map { keyCap(String($0.0)) }
    }

    // MARK: Choosing a layout

    /// The current layout, then the one macOS types shortcuts with when the
    /// current one can't type Latin letters (Russian, Japanese Kana), then
    /// U.S. as a last resort.
    static func current() -> [KeyboardLayout] {
        let sources = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
        ].compactMap { $0 }.compactMap(KeyboardLayout.init)
        return unique(sources + [installed("com.apple.keylayout.US")].compactMap { $0 })
    }

    static func installed(_ id: String) -> KeyboardLayout? {
        list([kTISPropertyInputSourceID: id]).first
    }

    static func allInstalled() -> [KeyboardLayout] {
        list([kTISPropertyInputSourceType: kTISTypeKeyboardLayout as Any])
    }

    /// Looks a character up on each layout in turn. A key from a later layout
    /// is approximate: it types the character there, not on the first. On a
    /// layout without Latin letters, a character that needs ⌥ is incidental
    /// (⌥B types b on Kana), so a later layout's key comes first. Labels come
    /// from the first Latin layout, the one macOS types shortcuts with.
    static func lookup(_ layouts: [KeyboardLayout]) -> LayoutLookup {
        let labels = layouts.first(where: \.isASCIICapable) ?? layouts.first
        return { c, command in
            var found: LayoutKey?
            var incidental: LayoutKey?
            for (i, layout) in layouts.enumerated() {
                guard var k = layout.key(c, command: command) else { continue }
                if i > 0 { k.exact = false }
                if !layout.isASCIICapable && k.adds.contains(.option) {
                    incidental = incidental ?? k
                    continue
                }
                found = k
                break
            }
            guard var k = found ?? incidental else { return nil }
            k.label = labels?.label(k.keyCode, command: command)
            return k
        }
    }

    private static func list(_ filter: [CFString: Any]) -> [KeyboardLayout] {
        let sources = TISCreateInputSourceList(filter as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource]
        return (sources ?? []).compactMap(KeyboardLayout.init)
    }

    private static func unique(_ layouts: [KeyboardLayout]) -> [KeyboardLayout] {
        var seen = Set<String>()
        return layouts.filter { seen.insert($0.id).inserted }
    }

    // MARK: Key table

    /// Keypad keys type what main keys do; a main key reads more naturally.
    private static let keypad: Set<UInt16> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]

    /// Each character's key: fewest added modifiers first, then a key that
    /// isn't dead, then a main key over the keypad, then the lowest code.
    private static func table(_ data: Data, holding held: KeyModifiers) -> [Character: LayoutKey] {
        var best: [Character: (rank: Int, key: LayoutKey)] = [:]
        for (order, adds) in [KeyModifiers(), .shift, .option, [.shift, .option]].enumerated() {
            for code in UInt16(0)..<128 {
                guard let (c, dead) = typed(data, code, held.union(adds)) else { continue }
                let rank = order * 4 + (dead ? 2 : 0) + (keypad.contains(code) ? 1 : 0)
                if let current = best[c], current.rank <= rank { continue }
                best[c] = (rank, LayoutKey(keyCode: code, adds: adds, exact: adds.isEmpty && !dead))
            }
        }
        return best.mapValues(\.key)
    }

    private static func typed(_ data: Data, _ code: UInt16, _ mods: KeyModifiers) -> (Character, dead: Bool)? {
        var carbon = 0
        if mods.contains(.command) { carbon |= cmdKey }
        if mods.contains(.shift) { carbon |= shiftKey }
        if mods.contains(.option) { carbon |= optionKey }
        if mods.contains(.control) { carbon |= controlKey }
        let state = UInt32((carbon >> 8) & 0xFF)
        return data.withUnsafeBytes { raw -> (Character, dead: Bool)? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            func translate(_ options: Int) -> (String, deadState: UInt32)? {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), state, UInt32(LMGetKbdType()),
                    OptionBits(options), &dead, chars.count, &length, &chars)
                return status == noErr ? (String(utf16CodeUnits: chars, count: length), dead) : nil
            }
            // The mask, not the bit number: with no options a dead key types nothing.
            guard let (s, _) = translate(kUCKeyTranslateNoDeadKeysMask), s.count == 1, let c = s.first,
                  !c.isWhitespace, c.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
            else { return nil }
            return (c, (translate(0)?.deadState ?? 0) != 0)
        }
    }
}
