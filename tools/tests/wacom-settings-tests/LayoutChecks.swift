// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// Checks the key lookup against every keyboard layout installed on this
// Mac: each key it picks types its character, every layout that can type
// Latin letters finds all of them and the digits, and a few familiar layouts
// give the keys a person would press.

import Foundation

func checkLayouts(_ expect: (Bool, String) -> Void) {
    let all = KeyboardLayout.allInstalled()
    expect(all.count >= 20, "Installed layouts: \(all.count)")
    let printable = (0x21...0x7E).compactMap { Unicode.Scalar($0).map(Character.init) }
    guard let us = KeyboardLayout.installed("com.apple.keylayout.US") else {
        expect(false, "U.S. layout installed")
        return
    }
    let letters = "abcdefghijklmnopqrstuvwxyz0123456789"
    var wrong: [String] = []
    var missing: [String] = []
    var unresolved: [String] = []
    for layout in all {
        let chain = KeyboardLayout.lookup([layout, us])
        for command in [false, true] {
            let tag = { (c: Character) in "\(layout.id) \(command ? "⌘" : "")\(c)" }
            for c in printable {
                guard let k = layout.key(c, command: command) else { continue }
                let held = command ? k.adds.union(.command) : k.adds
                if layout.types(k.keyCode, holding: held)?.0 != c { wrong.append(tag(c)) }
            }
            for c in letters where chain(c, command) == nil { unresolved.append(tag(c)) }
            // With ⌘ held, some Latin layouts (Sami, Akan) type no q or x.
            guard layout.isASCIICapable, !command else { continue }
            for c in letters where layout.key(c, command: command) == nil { missing.append(tag(c)) }
        }
    }
    expect(wrong.isEmpty, "Each key types its character: \(wrong.prefix(5))")
    expect(missing.isEmpty, "Latin layouts type every letter and digit: \(missing.prefix(5))")
    expect(unresolved.isEmpty, "Every layout, with U.S. behind it, finds every letter and digit: \(unresolved.prefix(5))")

    func key(_ id: String, _ c: Character, command: Bool = false) -> LayoutKey? {
        KeyboardLayout.installed("com.apple.keylayout." + id)?.key(c, command: command)
    }
    expect(key("US", "#") == LayoutKey(keyCode: 20, adds: .shift, exact: false), "U.S. # is ⇧3")
    expect(key("German", "z") == LayoutKey(keyCode: 16), "German z sits where U.S. y does")
    expect(key("German", "[") == LayoutKey(keyCode: 23, adds: .option, exact: false), "German [ is ⌥5")
    expect(key("German", "^") == LayoutKey(keyCode: 10, exact: false), "A dead key is found, as approximate")
    expect(key("French", "1") == LayoutKey(keyCode: 83), "French 1 without Shift is on the keypad")
    expect(key("DVORAK-QWERTYCMD", "z") == LayoutKey(keyCode: 44)
           && key("DVORAK-QWERTYCMD", "z", command: true) == LayoutKey(keyCode: 6),
           "Dvorak – QWERTY ⌘ switches keys while ⌘ is down")

    // Layouts without Latin letters type ⌘ shortcuts themselves; plain letters
    // come from the next layout.
    for id in ["Russian", "KANA"] {
        guard let own = KeyboardLayout.installed("com.apple.keylayout." + id) else {
            expect(false, "\(id) layout installed")
            continue
        }
        let lookup = KeyboardLayout.lookup([own, us])
        let c = lookup("c", true)
        expect(c?.keyCode == own.key("c", command: true)?.keyCode && c?.exact == true && c?.label == "C",
               "\(id) ⌘C uses its own key: \(String(describing: c))")
        expect(lookup("b", false) == LayoutKey(keyCode: 11, exact: false, label: "B"),
               "\(id) b falls back to U.S., approximate, labeled B")
    }

    // Labels follow macOS menus: the key's own character, modifiers apart.
    let labeled: [(id: String, wacom: String, code: UInt16, mods: KeyModifiers, label: String, recorded: String)] = [
        ("German", "[", 23, .option, "5", "["),
        ("US", "&shift;#", 20, .shift, "3", "⇧#"),
        ("DVORAK-QWERTYCMD", "&command;c", 8, .command, "C", "⌘C"),
    ]
    for l in labeled {
        guard let layout = KeyboardLayout.installed("com.apple.keylayout." + l.id),
              case .key(let k, _) = Keystroke.parse(l.wacom, layout: KeyboardLayout.lookup([layout])) else {
            expect(false, "\(l.wacom) parses on \(l.id)")
            continue
        }
        expect(k.keyCode == l.code && k.modifiers == l.mods && k.label == l.label && k.recorded == l.recorded,
               "\(l.id) \(l.wacom) is \(l.mods.symbols)\(l.label): \(k)")
    }
    expect(KeyboardLayout.current().last?.id == "com.apple.keylayout.US", "U.S. is the last resort")
}
