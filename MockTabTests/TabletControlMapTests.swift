// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import TabletKit
import Testing

@Suite("Tablet control map")
struct TabletControlMapTests {
    /// Every registry model with a map.
    private static let mapped: [(spec: TabletSpec, map: TabletControlMap)] =
        WacomDeviceRegistry.knownDevices.compactMap { spec in
            TabletControlMap.forDevice(productID: spec.productID, spec: spec).map { (spec, $0) }
        }

    /// Models whose registry key count disagrees with libwacom's, so a
    /// diagram would have keys with no row or rows with no key. Fix the
    /// registry, then take the model out of this list.
    private static let knownCountMismatches: Set<Int> = [
        0x0017, 0x0018, 0x0065,  // Bamboo Fun CTE-450/650, MTE-450: a Center row, but no center button
        0x03F5,  // PTK-470: registry says 5 keys, libwacom 4 and a dial toggle
        0x00D0,  // CTT-460: registry says no keys, libwacom 4
        0x00C5,  // Cintiq 20WSX: registry says 10 keys, libwacom 14
        0x0325,  // Companion 2: registry says 4 keys, libwacom 11
        0x034D, 0x0398, 0x034E, 0x0399, 0x03AA,  // MobileStudio Pro: the ring's four mode keys have no rows
    ]

    /// The rows the Buttons pane shows for a model's keys, rings, and dials,
    /// following `singleSidedSection`, `dualSidedSection`, and `touchRingBlock`.
    private static func paneRows(_ spec: TabletSpec) -> Set<ControlTarget> {
        let splitPad = spec.hasDualRings && spec.format == .cintiqV1
        var rows = Set((0..<(splitPad ? 16 : min(spec.buttonCount, 16))).map(ControlTarget.expressKey))
        if spec.hasTouchRing && !splitPad { rows.insert(.ringCenter(0)) }
        if spec.hasTouchRing && spec.hasDualRings && spec.hasMechanicalDial && !splitPad { rows.insert(.ringCenter(1)) }
        return rows
    }

    @Test("Every model with a layout has a map, unless it names a key twice")
    func coverage() {
        #expect(TabletControlMap.verifiedFamilies == [.intuos4, .intuos5, .cintiq24HD, .intuosPro2, .intuosPro3])
        for spec in WacomDeviceRegistry.knownDevices {
            let shown = TabletControlMap.forDevice(productID: spec.productID, spec: spec) != nil
            let identity = TabletLayoutIdentity.all[spec.productID]
            let expected = identity.map { Set($0.letters).count == $0.letters.count } ?? false
            #expect(shown == expected, "\(spec.name)")
        }
        #expect(TabletControlMap.forDevice(productID: 0x003A, spec: WacomDeviceRegistry.spec(for: 0x003A)!) == nil,
                "the DTI-520's layout names key B twice")
    }

    @Test("Families are told apart by registry features")
    func families() {
        let expected: [Int: TabletControlMap.Family] = [
            0x00B8: .intuos4, 0x00B9: .intuos4, 0x00BC: .intuos4,
            0x00BD: .intuos4,  // Bluetooth row, no key-display flag of its own
            0x0026: .intuos5, 0x0028: .intuos5, 0x0315: .intuos5, 0x0317: .intuos5,
            0x0357: .intuosPro2, 0x0358: .intuosPro2, 0x0361: .intuosPro2, 0x0392: .intuosPro2,
            0x03F5: .intuosPro3, 0x03F9: .intuosPro3,
            0x00F4: .cintiq24HD, 0x00F8: .cintiq24HD,
            // Same formats, different shapes: the general rule.
            0x0304: .other, 0x034D: .other, 0x0325: .other, 0x00CC: .other, 0x0374: .other,
        ]
        for (pid, family) in expected {
            let spec = WacomDeviceRegistry.spec(for: pid)
            #expect(spec != nil, "\(pid) is in the registry")
            if let spec { #expect(TabletControlMap.family(for: spec) == family, "\(spec.name)") }
        }
        // Every family has members.
        for family in TabletControlMap.Family.allCases {
            #expect(Self.mapped.contains { $0.map.family == family }, "\(family) has a model")
        }
    }

    @Test("Each key drives one target, and targets don't repeat")
    func targetsUnique() {
        #expect(!Self.mapped.isEmpty)
        for (spec, map) in Self.mapped {
            let identity = TabletLayoutIdentity.all[spec.productID]!
            #expect(map.parts.count == identity.entries.count, "\(spec.name)")
            let keys = map.parts.flatMap(\.keys)
            #expect(Set(keys.map(\.key)) == Set(identity.letters), "\(spec.name): every letter mapped")
            #expect(Set(map.targets).count == map.targets.count, "\(spec.name): no target twice")
            for target in map.targets {
                switch target {
                case let .expressKey(i): #expect((0..<16).contains(i), "\(spec.name)")
                case let .bezel(i): #expect((0..<3).contains(i), "\(spec.name)")
                case let .ringCenter(i), let .ring(i), let .dial(i), let .strip(i):
                    #expect((0..<2).contains(i), "\(spec.name)")
                }
            }
        }
    }

    @Test("Keys match the pane's rows")
    func matchesPaneRows() {
        for (spec, map) in Self.mapped where !Self.knownCountMismatches.contains(spec.productID) {
            let keys = Set(map.parts.flatMap(\.keys.values)).filter { if case .bezel = $0 { return false } else { return true } }
            #expect(keys == Self.paneRows(spec), "\(spec.name)")
        }
        // A fixed mismatch should leave the list.
        for pid in Self.knownCountMismatches {
            let entry = Self.mapped.first { $0.spec.productID == pid }
            #expect(entry != nil, "\(pid) is still mapped")
            if let entry {
                let keys = Set(entry.map.parts.flatMap(\.keys.values)).filter { if case .bezel = $0 { return false } else { return true } }
                #expect(keys != Self.paneRows(entry.spec), "\(entry.spec.name) now matches")
            }
        }
    }

    @Test("Keys follow the decoder's order where libwacom lists evdev codes")
    func evdevOrder() throws {
        func keys(_ pid: Int) throws -> [Character: ControlTarget] {
            let map = try #require(Self.mapped.first { $0.spec.productID == pid }?.map)
            return map.parts.reduce(into: [:]) { $0.merge($1.keys) { a, _ in a } }
        }
        // CTH-460: libwacom lists RIGHT, BACK, FORWARD, LEFT; the decoder reads LEFT first.
        #expect(try keys(0x00D1) == ["A": .expressKey(3), "B": .expressKey(2), "C": .expressKey(1), "D": .expressKey(0)])
        // CTH-470: LEFT, FORWARD, BACK, RIGHT, against the decoder's RIGHT, BACK, FORWARD, LEFT.
        #expect(try keys(0x00DC) == ["A": .expressKey(3), "B": .expressKey(2), "C": .expressKey(1), "D": .expressKey(0)])
        // CTH-480: LEFT, RIGHT, FORWARD, BACK, against RIGHT, LEFT, FORWARD, BACK.
        #expect(try keys(0x0302) == ["A": .expressKey(1), "B": .expressKey(0), "C": .expressKey(2), "D": .expressKey(3)])
        // Bamboo Fun: libwacom and the decoder agree.
        #expect(try keys(0x0017) == ["A": .expressKey(0), "B": .expressKey(1), "C": .expressKey(2), "D": .expressKey(3)])
    }

    @Test("The general rule's special keys")
    func generalRule() throws {
        func keys(_ pid: Int) throws -> [Character: ControlTarget] {
            let map = try #require(Self.mapped.first { $0.spec.productID == pid }?.map)
            return map.parts.reduce(into: [:]) { $0.merge($1.keys) { a, _ in a } }
        }
        // 21UX2: strip mode keys arrive in the bezel slots; the rest in letter order.
        let ux2 = try keys(0x00CC)
        #expect(ux2["A"] == .bezel(0) && ux2["J"] == .bezel(1))
        #expect(ux2["B"] == .expressKey(0) && ux2["I"] == .expressKey(7) && ux2["K"] == .expressKey(8) && ux2["R"] == .expressKey(15))
        // 13HD: no Center row, so the rocker's middle is key 1.
        #expect(try keys(0x0304)["A"] == .expressKey(0))
        // MobileStudio Pro 13: the ring's center has its row; mode keys follow the six keys.
        let msp = try keys(0x034D)
        #expect(msp["G"] == .ringCenter(0) && msp["F"] == .expressKey(5) && msp["H"] == .expressKey(6))
    }

    @Test("Bits are distinct and fit 64")
    func bits() {
        let all: [ControlTarget] = (0..<16).map(ControlTarget.expressKey) + (0..<3).map(ControlTarget.bezel)
            + (0..<2).flatMap { [ControlTarget.ringCenter($0), .ring($0), .dial($0), .strip($0)] }
        #expect(Set(all.map(\.bit)).count == all.count)
        #expect(all.allSatisfy { (0..<64).contains($0.bit) })
    }

    @Test("Pad reports read as the Buttons pane reads them")
    func down() {
        var buttons = Array(repeating: false, count: 19)
        buttons[0] = true; buttons[15] = true; buttons[17] = true
        let pad = PadState(buttons: buttons, pressedThisReport: [3],
                           rings: [RingState(position: nil, buttonDown: false), RingState(position: 4, buttonDown: true)])
        #expect(ControlTarget.down(in: pad) == [.expressKey(0), .expressKey(15), .bezel(1), .ringCenter(1)])
        #expect(ControlTarget.down(in: pad, includingPresses: true).contains(.expressKey(3)))
        #expect(ControlTarget.down(in: PadState(buttons: [])).isEmpty)
    }

    /// Reports from key-order walks, one per key in walk order, with the
    /// letter each key is in libwacom's layout. Each pair is a key press and
    /// the report that lets it go.
    private static func walk(_ letters: String, _ report: (Int) -> [UInt8], released: [UInt8])
        -> [(letter: Character, report: [UInt8], released: [UInt8])] {
        letters.enumerated().map { ($1, report($0), released) }
    }

    /// PTH-850 over USB: keys B–E, the ring center A, then F–I.
    private static let pth850Walk = walk("BCDEAFGHI", { i in
        i == 4 ? [0x03, 0x80, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
            : { b in [0x03, 0x80, 0x00, 0x00, b, b, 0x00, 0x00, 0x00, 0x00] }(UInt8(1 << (i < 4 ? i : i - 1)))
    }, released: [0x03, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

    /// DTK-2400 over USB: the left side's A–H in byte 6, the right side's I–P in byte 8.
    private static let dtk2400Walk = walk("ABCDEFGHIJKLMNOP", { i in
        var r: [UInt8] = [0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        r[i < 8 ? 6 : 8] = UInt8(1 << (i % 8))
        return r
    }, released: [0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

    /// PTK-870 over USB: report 0x11, outer keys in byte 1, center keys in byte 3.
    private static let ptk870Walk = walk("ADIBCEHJFG", { i in
        let bits: [(Int, UInt8)] = [(1, 0x01), (1, 0x08), (3, 0x01), (1, 0x02), (1, 0x04),
                                    (1, 0x10), (1, 0x80), (3, 0x02), (1, 0x20), (1, 0x40)]
        var r: [UInt8] = [0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        r[bits[i].0] = bits[i].1
        return r
    }, released: [0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

    /// PTK-870 over Bluetooth LE: report 0x1A, outer keys in byte 18, center keys in byte 19.
    private static let ptk870BLEWalk = walk("ADIBCEHJFG", { i in
        let bits: [(Int, UInt8)] = [(18, 0x01), (18, 0x08), (19, 0x01), (18, 0x02), (18, 0x04),
                                    (18, 0x10), (18, 0x80), (19, 0x02), (18, 0x20), (18, 0x40)]
        var r: [UInt8] = [0x1A, 0x02] + Array(repeating: 0, count: 18)
        r[bits[i].0] = bits[i].1
        return r
    }, released: [0x1A, 0x02] + Array(repeating: 0, count: 18))

    @Test("Walked keys light the key that was pressed", arguments: [
        (0x0028, "PTH-850"), (0x00F4, "DTK-2400"), (0x03F9, "PTK-870"), (0x03F9, "PTK-870 BLE"),
    ])
    func walks(pid: Int, model: String) throws {
        let steps = switch model {
        case "PTH-850": Self.pth850Walk
        case "DTK-2400": Self.dtk2400Walk
        case "PTK-870": Self.ptk870Walk
        default: Self.ptk870BLEWalk
        }
        let spec = try #require(WacomDeviceRegistry.spec(for: pid))
        let map = try #require(TabletControlMap.forDevice(productID: pid, spec: spec))
        var targets: [Character: ControlTarget] = [:]
        for part in map.parts { targets.merge(part.keys) { a, _ in a } }
        var decoder = spec.makeDecoder()
        for (letter, report, released) in steps {
            let down = HIDReport.withReport(report) { decoder.events($0) }
                .reduce(into: Set<ControlTarget>()) { set, event in
                    if case let .pad(pad) = event { set.formUnion(ControlTarget.down(in: pad, includingPresses: true)) }
                }
            #expect(down == [try #require(targets[letter])], "\(model) key \(letter)")
            _ = HIDReport.withReport(released) { decoder.events($0) }
        }
    }

    @Test("Rules for each family")
    func rules() throws {
        func map(_ pid: Int) throws -> TabletControlMap {
            try #require(Self.mapped.first { $0.spec.productID == pid }?.map)
        }
        let pro2 = try map(0x0358)  // k ABCD; r 1 I; k EFGH
        #expect(pro2.parts[0].keys == ["A": .expressKey(0), "B": .expressKey(1), "C": .expressKey(2), "D": .expressKey(3)])
        #expect(pro2.parts[1].control == .ring(0) && pro2.parts[1].keys == ["I": .ringCenter(0)])
        #expect(pro2.parts[2].keys["H"] == .expressKey(7))

        let intuos5 = try map(0x0028)  // k BCDE; r 1 A; k FGHI
        #expect(intuos5.family == .intuos5)
        #expect(intuos5.parts[0].keys["B"] == .expressKey(0))
        #expect(intuos5.parts[1].control == .ring(0) && intuos5.parts[1].keys == ["A": .ringCenter(0)])
        #expect(intuos5.parts[2].keys["I"] == .expressKey(7))

        let ptk = try map(0x03F9)  // c .D./AIC/.B.; d 1; d 2; c .H./EJG/.F. | m I=d1 J=d2
        #expect(ptk.parts[0].keys == ["A": .expressKey(0), "B": .expressKey(1), "C": .expressKey(2),
                                      "D": .expressKey(3), "I": .ringCenter(0)])
        #expect(ptk.parts[1].control == .dial(0) && ptk.parts[2].control == .dial(1))
        #expect(ptk.parts[3].keys["J"] == .ringCenter(1))

        let hd = try map(0x00F4)  // r 1 A@/B@/C@; c DEF/DEG/DEH; r 2 I@/J@/K@; c LMN/LMO/LMP
        #expect(hd.parts[0].control == .ring(0)
                && hd.parts[0].keys == ["A": .expressKey(0), "B": .expressKey(1), "C": .expressKey(2)])
        #expect(hd.parts[2].control == .ring(1))
        // The left ring is the first one decoded (DTK-2400 evidence).
        let hdLine = try #require(TabletLayoutTable.packed.split(separator: "\n").first { $0.contains("00F4") })
        let hdParts = hdLine.split(separator: ":")[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(hdParts[0].hasPrefix("rL") && hdParts[2].hasPrefix("rR"), "\(hdParts)")
        #expect(hd.parts[2].keys["I"] == .expressKey(8))
        #expect(hd.parts[3].keys["P"] == .expressKey(15))
    }
}
