// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

// main.swift — Standalone checks for where a tablet's controls sit.
//
// Compiled against the real TabletFigure.swift, the generated layout table,
// TabletLayoutIdentity.swift, TabletControlMap.swift, TabletOrientation.swift,
// and TabletKit. Run via tools/tests/tablet-position-tests/run.sh. Exits
// non-zero on failure.

import CoreGraphics
import Foundation
import TabletKit

private var failures = 0
private var checks = 0

private func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
    checks += 1
    guard !condition else { return }
    failures += 1
    FileHandle.standardError.write(Data("FAIL (line \(line)): \(message())\n".utf8))
}

private func hex(_ id: Int) -> String { String(format: "%04X", id) }

private func describe(_ t: ControlTarget) -> String {
    switch t {
    case let .expressKey(i): return "K\(i)"
    case let .bezel(i): return "B\(i)"
    case let .ringCenter(i): return "C\(i)"
    case let .ring(i): return "R\(i)"
    case let .dial(i): return "D\(i)"
    case let .strip(i): return "S\(i)"
    }
}

/// The model's figure in Landscape with its control map, as the Buttons pane builds it.
private func figure(_ productID: Int) -> TabletFigure? {
    guard let controls = TabletControlMap.figureControls(productID: productID) else { return nil }
    let spec = WacomDeviceRegistry.spec(for: productID)
    let mm = spec?.activeWidthMM.flatMap { w in spec?.activeHeightMM.map { CGSize(width: w, height: $0) } }
    let aspect = spec.map { $0.maxY > 0 ? Double($0.maxX) / Double($0.maxY) : 1.5 } ?? 1.5
    var figure = TabletFigure(layoutProductID: productID, surfaceMM: mm, aspect: aspect,
                              isPenDisplay: spec?.isPenDisplay ?? false)
    figure.controls = controls
    return figure
}

private let ids = Set(TabletLayoutIdentity.all.keys).union(TabletLayoutExtras.productIDs).sorted()
private var models = 0
// Models whose reading order isn't their numbering, which is why a control's
// number comes from its place in Landscape, not from reading order.
private var readOutOfOrder = 0

for id in ids {
    guard let figure = figure(id), let controls = figure.controls else { continue }
    models += 1
    let name = WacomDeviceRegistry.spec(for: id)?.name ?? "?"
    let order = figure.controlsInReadingOrder()

    // Every control the map drives is drawn, once.
    let mapped = Set(controls.flatMap { ($0.control.map { [$0] } ?? []) + Array($0.keys.values) })
    expect(Set(order) == mapped && order.count == mapped.count,
           "\(hex(id)) \(name): drawn \(order.map(describe)) vs mapped \(mapped.map(describe).sorted())")

    if Dictionary(grouping: order, by: \.kind).values.contains(where: { $0.map(\.index) != $0.map(\.index).sorted() }) {
        readOutOfOrder += 1
    }

    // Every orientation lines up one to one, and Landscape keeps today's numbering.
    for orientation in TabletOrientation.allCases {
        guard let eq = figure.landscapeEquivalents(turnedTo: orientation) else {
            expect(false, "\(hex(id)) \(name): \(orientation) doesn't line up with Landscape")
            continue
        }
        expect(Set(eq.keys) == mapped && Set(eq.values) == mapped && eq.allSatisfy { $0.key.kind == $0.value.kind },
               "\(hex(id)) \(name): \(orientation) isn't one to one within each kind")
        if orientation == .landscape {
            expect(eq.allSatisfy { $0.key == $0.value }, "\(hex(id)) \(name): Landscape renumbers a control")
        }
    }
}
expect(models > 90, "only \(models) models have a drawing and a control map")

// MARK: - Layouts, one of each kind

private func equivalents(_ id: Int, _ orientation: TabletOrientation) -> [ControlTarget: ControlTarget] {
    figure(id)?.landscapeEquivalents(turnedTo: orientation) ?? [:]
}

private func keys(_ map: [ControlTarget: ControlTarget], _ count: Int) -> [Int] {
    (0..<count).map { map[.expressKey($0)]?.index ?? -1 }
}

// PTH-860, keys down the left edge: Portrait keeps their order, a half turn
// reverses it. Cyzor's screenshots: Portrait's leftmost key is Key 1,
// Portrait Flipped's is Key 8.
expect(keys(equivalents(0x0358, .portrait), 8) == Array(0..<8), "PTH-860 Portrait keeps key order")
expect(keys(equivalents(0x0358, .landscapeFlipped), 8) == Array((0..<8).reversed()), "PTH-860 flipped reverses keys")
expect(keys(equivalents(0x0358, .portraitFlipped), 8) == Array((0..<8).reversed()), "PTH-860 Portrait Flipped reverses keys")
expect(equivalents(0x0358, .landscapeFlipped)[.ringCenter(0)] == .ringCenter(0), "PTH-860 ring center stays")

// CTL-4100, keys along the top: Portrait reverses them, Portrait Flipped doesn't.
expect(keys(equivalents(0x0374, .portrait), 4) == [3, 2, 1, 0], "CTL-4100 Portrait reverses keys")
expect(keys(equivalents(0x0374, .landscapeFlipped), 4) == [3, 2, 1, 0], "CTL-4100 flipped reverses keys")
expect(keys(equivalents(0x0374, .portraitFlipped), 4) == [0, 1, 2, 3], "CTL-4100 Portrait Flipped keeps key order")

// PTK-870, two pads and two dials along the top: each quarter turn moves a
// pad's keys one place, and a half turn trades the two sides.
expect(keys(equivalents(0x03F9, .landscapeFlipped), 8) == [6, 7, 4, 5, 2, 3, 0, 1], "PTK-870 flipped turns and trades pads")
expect(keys(equivalents(0x03F9, .portrait), 8) == [7, 4, 5, 6, 3, 0, 1, 2], "PTK-870 Portrait turns each pad a quarter")
expect(equivalents(0x03F9, .landscapeFlipped)[.dial(1)] == .dial(0), "PTK-870 flipped trades dials")
expect(equivalents(0x03F9, .portrait)[.dial(1)] == .dial(0), "PTK-870 Portrait reads the right dial first")
expect(equivalents(0x03F9, .landscapeFlipped)[.ringCenter(1)] == .ringCenter(0), "PTK-870 flipped trades dial toggles")

// Intuos3 6×8, keys and a strip on each side: a half turn trades the sides
// and reverses the keys, though the keys don't read in their numbering.
expect(keys(equivalents(0x00B1, .landscapeFlipped), 8) == Array((0..<8).reversed()), "Intuos3 flipped reverses keys")
expect(equivalents(0x00B1, .landscapeFlipped)[.strip(1)] == .strip(0), "Intuos3 flipped trades strips")

// MARK: - The carry

/// Assignments that tell every key, button, and mode apart.
private func distinctAssignments(rotaries: Bool) -> TurnAssignments {
    func key(_ i: Int) -> ButtonBinding { ButtonBinding(kind: .keyCombo, keyCode: UInt16(i + 1)) }
    let slots = ControlSlot.defaults.enumerated().map { i, slot -> ControlSlot in
        var slot = slot
        slot.speed = Double(i + 1)
        return slot
    }
    return TurnAssignments(
        expressKeys: (0..<16).map(key), bezelButtons: (16..<19).map(key),
        center: ButtonBinding(kind: .ringCycle), center2: ButtonBinding(kind: .ringCycle2),
        sharedSlots: slots, activeSlot: 1, activeSlot2: 2,
        rotaries: rotaries ? [RotaryConfig(slots: slots, activeSlotIndex: 0), RotaryConfig(slots: slots.reversed(), activeSlotIndex: 3)] : nil,
        reverseDirection: false)
}

private func lampsTurn(_ id: Int) -> Bool {
    WacomDeviceRegistry.spec(for: id).map(TabletControlMap.ringLampsTurn) ?? false
}

// Every model, every pair of orientations: each place keeps its key's
// action, and turning back undoes the turn.
for id in ids {
    guard let figure = figure(id) else { continue }
    let lamps = lampsTurn(id)
    let original = distinctAssignments(rotaries: true)
    for from in TabletOrientation.allCases {
        guard let seenFrom = figure.landscapeEquivalents(turnedTo: from) else { continue }
        for to in TabletOrientation.allCases {
            guard let seenTo = figure.landscapeEquivalents(turnedTo: to) else { continue }
            let carry = figure.turnCarry(from: from, to: to, ringLampsTurn: lamps)
            let turned = carry.carried(original)
            let atPlace = Dictionary(seenTo.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
            for (control, place) in seenFrom {
                guard case let .expressKey(before) = control, case let .expressKey(after)? = atPlace[place] else { continue }
                expect(turned.expressKeys[after] == original.expressKeys[before],
                       "\(hex(id)) \(from)→\(to): key \(after) holds key \(before)'s action")
            }
            let back = figure.turnCarry(from: to, to: from, ringLampsTurn: lamps).carried(turned)
            expect(back == original, "\(hex(id)) \(from)→\(to)→\(from) restores everything")
            if from == to { expect(carry.isIdentity, "\(hex(id)) \(from) to itself moves nothing") }
        }
    }
    // Four quarter turns come back around.
    let path: [TabletOrientation] = [.landscape, .portrait, .landscapeFlipped, .portraitFlipped, .landscape]
    var walked = original
    for (from, to) in zip(path, path.dropFirst()) {
        walked = figure.turnCarry(from: from, to: to, ringLampsTurn: lamps).carried(walked)
    }
    expect(walked == original, "\(hex(id)) four quarter turns restore everything")

    // The escape hatch: a half turn's carry without turning, twice, puts
    // everything back in any orientation. Pen displays whose two sides
    // differ pair places in cycles instead, so twice doesn't come back
    // around there; undo does. Three of them can't turn on their stands.
    let asymmetric: Set<Int> = [0x00C5, 0x00F4, 0x00F8, 0x03F0]  // 20WSX, 24HD, 24HD Touch, Movink 13
    for orientation in TabletOrientation.allCases {
        let around = figure.turnCarry(from: orientation, to: orientation.halfTurned, ringLampsTurn: lamps)
        let restores = around.carried(around.carried(original)) == original
        expect(restores != asymmetric.contains(id),
               "\(hex(id)) turning assignments around twice in \(orientation) \(restores ? "restores" : "doesn't restore") everything")
    }
}

// PTH-860 flipped: keys reverse, the corner lamps' modes move two places, and
// a key that jumps to a mode follows it. Its center stays put.
do {
    let carry = figure(0x0358)!.turnCarry(from: .landscape, to: .landscapeFlipped, ringLampsTurn: lampsTurn(0x0358))
    expect(carry.lampShift == 2 && !carry.tradesRotaries, "PTH-860 flip moves lamps two places")
    var old = distinctAssignments(rotaries: false)
    old.expressKeys[0] = ButtonBinding(kind: .ringSelectSlot, keyCode: 0)
    let new = carry.carried(old)
    expect(new.sharedSlots[2] == old.sharedSlots[0] && new.sharedSlots[0] == old.sharedSlots[2], "PTH-860 modes move two places")
    expect(new.activeSlot == 3, "PTH-860 active mode moves with its lamp")
    expect(new.expressKeys[7] == ButtonBinding(kind: .ringSelectSlot, keyCode: 2), "PTH-860 jump-to-mode key follows its mode")
    expect(new.center == old.center, "PTH-860 center stays")
    let portrait = figure(0x0358)!.turnCarry(from: .landscape, to: .portrait, ringLampsTurn: true)
    expect(portrait.keys.isEmpty && portrait.lampShift == 1, "PTH-860 Portrait keeps keys, moves lamps one place")
}

// PTK-870 flipped: the dials trade modes and toggle keys, and a key that
// cycles the left dial still does.
do {
    let carry = figure(0x03F9)!.turnCarry(from: .landscape, to: .landscapeFlipped, ringLampsTurn: lampsTurn(0x03F9))
    expect(carry.tradesRotaries && carry.lampShift == 0, "PTK-870 flip trades dials, no lamps")
    var old = distinctAssignments(rotaries: true)
    old.expressKeys[0] = ButtonBinding(kind: .ringCycle)
    let new = carry.carried(old)
    expect(new.rotaries?[0] == old.rotaries?[1] && new.rotaries?[1] == old.rotaries?[0], "PTK-870 dials trade modes")
    expect(new.center == ButtonBinding(kind: .ringCycle) && new.center2 == ButtonBinding(kind: .ringCycle2),
           "PTK-870 default toggles stay as they were")
    expect(new.expressKeys[6] == ButtonBinding(kind: .ringCycle2), "PTK-870 key cycling the left dial follows it")
}

// Intuos3: a half turn reverses the strips' direction; a quarter turn doesn't.
expect(figure(0x00B1)!.turnCarry(from: .landscape, to: .landscapeFlipped, ringLampsTurn: false).invertsStrips,
       "Intuos3 flip reverses strips")
expect(!figure(0x00B1)!.turnCarry(from: .landscape, to: .portrait, ringLampsTurn: false).invertsStrips,
       "Intuos3 Portrait keeps strip direction")

// MARK: - Which hardware picks modes by key

// Jump to Mode is offered only where the hardware's own mode keys pick a
// mode each: the Cintiq 24HD class and the MobileStudio Pro. Cycle-button
// hardware doesn't get it.
for (id, picks) in [(0x00F4, true), (0x00F8, true), (0x034D, true), (0x034E, true),
                    (0x0358, false), (0x00B9, false), (0x0027, false), (0x03F9, false), (0x00CC, false), (0x0374, false)] {
    expect(TabletControlMap.modeKeysPickModes(productID: id) == picks,
           "\(hex(id)) mode keys \(picks ? "pick modes" : "don't pick modes")")
}

// MARK: - Where carried values are written

do {
    let a = "com.example.a", p = UUID(), q = UUID()
    // Tablet only: the tablet's own value changes.
    let solo = LayeredSetting(device: 1).rewritten(overrideIDs: [], profileIDs: [], preferredProfile: nil) { _, _ in 2 }
    expect(solo == LayeredSetting(device: 2), "tablet alone rewrites its own value")

    // An override that kept its orientation, sharing the tablet's value: the
    // tablet's value turns, and the override keeps the old one as its own.
    let shared = LayeredSetting(device: 1).rewritten(overrideIDs: [a], profileIDs: [], preferredProfile: nil) { o, _ in
        o == nil ? 2 : 1
    }
    expect(shared.device == 2 && shared.overrides[a] == 1, "unturned override keeps the old value as its own")

    // A profile with its own value turns in place; nothing new is written.
    let profiled = LayeredSetting(device: 1, profiles: [p: 5]).rewritten(
        overrideIDs: [], profileIDs: [p, q], preferredProfile: p
    ) { _, profile in profile == p ? 6 : 1 }
    expect(profiled.device == 1 && profiled.profiles == [p: 6], "a profile's own value turns in place")

    // Nothing turned: nothing changes.
    let still = LayeredSetting(device: 1, profiles: [p: 5], overrides: [a: 7])
    let same = still.rewritten(overrideIDs: [a], profileIDs: [p], preferredProfile: nil) { still.value(override: $0, profile: $1) }
    expect(same == still, "no turn writes nothing")

    // An override serving two profiles that want different values keeps the
    // preferred profile's.
    let split = LayeredSetting(device: 1, overrides: [a: 1]).rewritten(
        overrideIDs: [a], profileIDs: [p], preferredProfile: p
    ) { o, profile in o == nil ? 1 : (profile == p ? 3 : 4) }
    expect(split.overrides[a] == 3, "override keeps the preferred profile's value")
}

print("tablet-position-tests: \(models) models line up in every orientation (\(readOutOfOrder) read out of numbering order)")
print("tablet-position-tests: \(checks - failures) of \(checks) checks passed")
exit(failures == 0 ? 0 : 1)
