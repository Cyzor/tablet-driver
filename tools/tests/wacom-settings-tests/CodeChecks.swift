// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// Checks that the code and key-position tables read both ways: everything
// written reads back as itself, and no value has two places to go.

import Foundation

func checkCodes(_ expect: (Bool, String) -> Void) {
    func node(_ name: String, _ code: Int) -> WacomNode {
        WacomNode(name: "ArrayElement", children: [WacomNode(name: name, type: "integer", text: "\(code)")])
    }

    // Buttons
    let kinds = ButtonCodes.rows.flatMap(\.kinds)
    expect(Set(kinds).count == kinds.count, "Each MockTab kind has one button code: \(kinds)")
    for row in ButtonCodes.rows {
        let read = WacomMapper.function(node("ButtonFunction", row.code), layout: { _, _ in nil })
        if let first = row.kinds.first {
            expect(read.2 == .kind(first), "Code \(row.code) reads as \(first): \(read.2.map { "\($0)" } ?? "nil")")
        } else {
            expect(read.1.isSkipped && read.2 == nil, "Code \(row.code) has no MockTab equivalent")
        }
        for kind in row.kinds where row.confidence != .unverified {
            expect(ButtonCodes.code(for: kind) == row.code, "\(kind) writes code \(row.code)")
        }
    }
    // The import turns 108 into ringCycle2 on the second dial's key, so
    // writing needs the way back.
    expect(ButtonCodes.code(for: "ringCycle2") == 108, "ringCycle2 writes code 108")
    expect(ButtonCodes.code(for: "none") == nil, "None writes nothing while code 0 is unverified")
    expect(ButtonCodes.code(for: "keyCombo") == nil, "Keystrokes aren't in the table")

    // Ring and dial modes
    for mode in [RingMode.scroll, .rotate, .off, .skip] {
        let writers = RingCodes.rows.filter { $0.mode == mode && $0.writes }
        expect(writers.count == 1, "\(mode.name) has one code to write: \(writers.map(\.code))")
        if let code = RingCodes.code(for: mode) {
            let read = WacomMapper.ringFunction(node("TouchStripFunction", code), layout: { _, _ in nil })
            expect(read.2 == mode, "\(mode.name) reads back as itself from code \(code)")
        }
    }
    for row in RingCodes.rows {
        let read = WacomMapper.ringFunction(node("TouchStripFunction", row.code), layout: { _, _ in nil })
        expect(read.2 == row.mode, "Ring code \(row.code) reads as \(row.mode.name)")
    }

    // Key positions
    let models = KeyLayouts.twoDials.union(KeyLayouts.oneDial).union(KeyLayouts.eightDown)
        .union(KeyLayouts.sixDown).union(KeyLayouts.fourAcross)
    for pid in models.sorted() {
        let table = KeyLayouts.table(pid)
        let id = String(format: "0x%04X", pid)
        expect(!table.isEmpty, "\(id) has a table")
        expect(Set(table.map(\.name)).count == table.count, "\(id) names each control once")
        expect(Set(table.map(\.target.spot)).count == table.count, "\(id) puts each control in its own place")
        for entry in table {
            expect(KeyLayouts.target(entry.name, productID: pid) == entry.target, "\(id) \(entry.name) reads")
            let back = KeyLayouts.name(for: entry.target.spot, productID: pid)
            expect(back == (entry.target.confidence == .unverified ? nil : entry.name),
                   "\(id) \(entry.target.setting) writes \(back ?? "nothing")")
        }
    }
    expect(KeyLayouts.table(0x0001).isEmpty, "A model without a table has no positions")

    // Comparison by what MockTab gets
    func field(_ name: String, _ text: String, _ type: String = "integer") -> WacomNode {
        WacomNode(name: name, type: type, text: text)
    }
    func control(_ fields: WacomNode...) -> WacomNode { WacomNode(name: "ArrayElement", children: fields) }
    let none: LayoutLookup = { _, _ in nil }
    let click = control(field("ButtonFunction", "1"))
    let clickWithOldKeys = control(field("ButtonFunction", "1"), field("Keystroke", "&command;z", "kestring"))
    expect(WacomMapper.sameButton(click, clickWithOldKeys, layout: none), "Old keystrokes on a click don't count")
    expect(!WacomMapper.sameButton(click, control(field("ButtonFunction", "3")), layout: none), "Different functions differ")
    expect(WacomMapper.sameButton(control(field("ButtonFunction", "41")), control(field("ButtonFunction", "40")), layout: none),
           "Two functions MockTab doesn't have both leave it None")
    expect(!WacomMapper.sameButton(control(field("ButtonFunction", "0")), control(field("ButtonFunction", "41")), layout: none),
           "Unverified and left out differ")

    let scroll = control(field("TouchStripFunction", "45"))
    let scrollWithOldKeys = control(field("TouchStripFunction", "45"), field("TouchStripKeystrokeIncrease", "]", "kestring"),
                                    field("TouchStripKeystrokeName", "Brush size", "string"))
    expect(WacomMapper.sameRingMode(scroll, scrollWithOldKeys, layout: none), "Old keystrokes and name on a scroll mode don't count")
    expect(WacomMapper.ringLabel(scrollWithOldKeys) == nil, "A scroll mode doesn't take an old keystroke name")
    let keys = control(field("TouchStripFunction", "8"), field("TouchStripKeystrokeName", "Brush size", "string"))
    expect(WacomMapper.ringLabel(keys) == "Brush size", "A keystroke mode keeps its name")
}
