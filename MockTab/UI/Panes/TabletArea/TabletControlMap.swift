// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TabletKit

extension ControlTarget {
    /// The controls a pad report holds down, read as `TabletManager` reads
    /// them into `LiveButtonState`: buttons 0–15 are ExpressKeys, 16–18
    /// bezel buttons, and each ring's button its center or toggle.
    /// `includingPresses` adds buttons pressed and let go within the report.
    static func down(in pad: PadState, includingPresses: Bool = false) -> Set<ControlTarget> {
        var down: Set<ControlTarget> = []
        for i in 0..<19 {
            let held = pad.buttons.indices.contains(i) && pad.buttons[i]
            guard held || (includingPresses && pad.pressedThisReport.contains(i)) else { continue }
            down.insert(i < 16 ? .expressKey(i) : .bezel(i - 16))
        }
        for (i, ring) in pad.rings.prefix(2).enumerated() where ring.buttonDown { down.insert(.ringCenter(i)) }
        return down
    }
}

/// Which `ControlTarget` each part of a model's layout drives: libwacom's
/// letters, from `TabletLayoutIdentity`, turned into MockTab's indices.
///
/// Every model with a layout gets a map. Where its key order hasn't been
/// checked on hardware, the order is the best guess the sources support,
/// and a user who sees the wrong key light can report it.
struct TabletControlMap: Equatable {
    enum Family: CaseIterable {
        /// Intuos4: the key set into the ring is its center.
        case intuos4
        /// Intuos5 and Intuos Pro gen 1: the key set into the ring is its center.
        case intuos5
        /// Intuos Pro gen 2 (PTH-x60): the key set into the ring is its center.
        case intuosPro2
        /// Intuos Pro gen 3 (PTK-x70): each dial's mode key is its toggle.
        case intuosPro3
        /// Cintiq 24HD: the mode keys beside each ring are the first three keys of their side.
        case cintiq24HD
        /// Any other model: the general rule below.
        case other
    }

    /// One layout part's targets, as the tablet figure draws them.
    typealias Part = TabletFigure.PartControls

    var family: Family
    /// One for each of the model's layout parts, in the same order.
    var parts: [Part]

    /// Families whose key order has been checked, each citing its evidence.
    /// The rest are drawn from libwacom's order.
    static let verifiedFamilies: Set<Family> = [
        .intuos4,  // libwacom's order, which the kernel's report layout follows
        .intuos5,  // Notes/Evidence/PTH-850-Key-Order.md
        .cintiq24HD,  // Notes/Evidence/DTK-2400-Key-Order.md
        .intuosPro2,  // Notes/Evidence/PTH-860-Bluetooth-Keys.md
        .intuosPro3,  // Notes/Evidence/PTK-870-Key-Order.md
    ]

    /// The map for a connected model, or nil when it has no layout or its
    /// layout names a key twice.
    static func forDevice(productID: Int, spec: TabletSpec) -> TabletControlMap? {
        guard let identity = TabletLayoutIdentity.all[productID],
              Set(identity.letters).count == identity.letters.count
        else { return nil }
        return make(identity, family: family(for: spec), hasCenterRow: hasCenterRow(spec),
                    keysAreBezel: spec.buttonCount == 0 && spec.bezelButtonCount > 0)
    }

    /// The figure parts for a model by product ID, for drawing it in the
    /// diagram's style; a Wacom Bluetooth ID without its own row reads as its
    /// USB model. Nil without a layout.
    static func figureControls(productID: Int) -> [Part]? {
        let model = WacomDeviceRegistry.spec(for: productID) != nil ? productID
            : WacomDeviceRegistry.canonicalProductID(for: productID)
        if let spec = WacomDeviceRegistry.spec(for: model) { return forDevice(productID: model, spec: spec)?.parts }
        // Another brand's model with a layout of its own: its keys are bezel buttons.
        guard let identity = TabletLayoutIdentity.all[productID],
              (VendorDeviceRegistry.profile(forProductID: productID)?.bezelButtonCount ?? 0) > 0
        else { return nil }
        return make(identity, family: .other, hasCenterRow: false, keysAreBezel: true).parts
    }

    /// The family whose rule fits a model, told apart by what the registry
    /// knows about it, not by product ID.
    static func family(for spec: TabletSpec) -> Family {
        switch spec.format {
        // The Cintiq 13HD shares the format but has no ring and a rocker.
        case .intuosV1 where spec.hasTouchRing && !spec.isPenDisplay:
            return spec.family == .intuos4 ? .intuos4 : .intuos5
        // The MobileStudio Pro shares the format but has mode keys around its ring.
        case .intuosV2 where spec.hasTouchRing && !spec.isPenDisplay: return .intuosPro2
        case .intuosV3 where spec.hasMechanicalDial: return .intuosPro3
        // The Companion 2 shares the format but has one ring with a rocker.
        case .cintiqV1 where spec.hasDualRings: return .cintiq24HD
        default: return .other
        }
    }

    /// Whether the Buttons pane shows a Center or Dial Toggle row for the
    /// first ring, as `touchRingBlock` decides.
    static func hasCenterRow(_ spec: TabletSpec) -> Bool {
        spec.hasTouchRing && !(spec.hasDualRings && spec.format == .cintiqV1)
    }

    /// Decoder button order by evdev code, keyed by the codes libwacom
    /// lists for a model. Each list belongs to one report layout, so it
    /// picks that layout's bit order (the kernel's `wacom_bpt_touch`,
    /// `wacom_bpt3_button_msg`, and `wacom_graphire_irq`).
    private static let evdevOrder: [[Int]: [Int]] = [
        [0x111, 0x116, 0x115, 0x110]: [0x110, 0x115, 0x116, 0x111],  // Bamboo Pen & Touch, CTH-460
        [0x110, 0x115, 0x116, 0x111]: [0x111, 0x116, 0x115, 0x110],  // Bamboo CTH-470
        [0x110, 0x111, 0x115, 0x116]: [0x111, 0x110, 0x115, 0x116],  // Intuos CTH-480, CTL-490
        [0x116, 0x115, 0x110, 0x111]: [0x116, 0x115, 0x110, 0x111],  // Bamboo Fun CTE
    ]

    /// Applies the rule. Special keys take their own targets: a ring's center
    /// key where the pane has a Center row, a dial's mode key as its toggle,
    /// and a strip's mode key as the bezel slot the decoder reports it in.
    /// Every other key takes an ExpressKey index: by the decoder's evdev
    /// order where libwacom lists codes, else in letter order.
    /// `keysAreBezel`: a model whose only keys are bezel buttons, which they drive.
    static func make(_ identity: TabletLayoutIdentity, family: Family, hasCenterRow: Bool,
                     keysAreBezel: Bool = false) -> TabletControlMap {
        var special: [Character: ControlTarget] = [:]
        if hasCenterRow && family != .intuosPro3 {
            for entry in identity.entries {
                switch entry {
                case let .ring(n, .center(letter)): special[letter] = .ringCenter(n - 1)
                case let .ring(n, .beside(grid)):
                    if let pad = TabletFigure.pad(grid) { special[pad.center] = .ringCenter(n - 1) }
                default: break
                }
            }
        }
        for (letter, mode) in identity.modeSwitches where mode.mode == nil {
            switch mode.control {
            case let .dial(n): special[letter] = .ringCenter(n - 1)
            case let .strip(n): special[letter] = .bezel(n - 1)
            case .ring: break
            }
        }
        var targets = special
        let plain = Set(identity.letters).subtracting(special.keys).sorted()
        if let codes = identity.evdevCodes, let order = evdevOrder[codes] {
            for letter in plain {
                let position = Int(letter.asciiValue! - 65)
                if position < codes.count, let index = order.firstIndex(of: codes[position]) {
                    targets[letter] = .expressKey(index)
                }
            }
        } else {
            for (index, letter) in plain.enumerated() { targets[letter] = keysAreBezel ? .bezel(index) : .expressKey(index) }
        }

        let parts = identity.entries.map { entry -> Part in
            let control: ControlTarget?
            switch entry {
            // A ring with four keys around it and one inside is a rocker, drawn as a pad.
            case let .ring(_, .beside(grid)) where TabletFigure.pad(grid) != nil: control = nil
            case let .ring(n, _): control = .ring(n - 1)
            case let .dial(n, _): control = .dial(n - 1)
            case let .strip(n): control = .strip(n - 1)
            case .run, .cluster: control = nil
            }
            var keys: [Character: ControlTarget] = [:]
            for letter in entry.letters { keys[letter] = targets[letter] }
            return Part(entry: entry, control: control, keys: keys)
        }
        return TabletControlMap(family: family, parts: parts)
    }

    /// Every target the map draws.
    var targets: [ControlTarget] {
        parts.flatMap { part in (part.control.map { [$0] } ?? []) + part.keys.values }
    }

    /// Whether a model's ring has a lamp at each corner, so the mode lit at
    /// the upper left changes as the tablet turns: the Intuos5 and Intuos
    /// Pro gen 1 and 2. Other rings' lamps keep their order.
    static func ringLampsTurn(_ spec: TabletSpec) -> Bool {
        spec.ringSlotCount == 4 && [.intuos5, .intuosPro2].contains(family(for: spec))
    }

    /// Whether a model's own mode keys each pick a mode, as on the Cintiq
    /// 24HD and MobileStudio Pro, instead of one key cycling through them.
    static func modeKeysPickModes(productID: Int) -> Bool {
        TabletLayoutIdentity.all[productID]?.modeSwitches.values.contains { $0.mode != nil } == true
    }
}

extension TabletFigure {
    /// What turning this Landscape figure from `old` to `new` does to saved
    /// assignments: each control's moves to the control now in its place.
    /// Needs `controls`; without them only lamps and strips move.
    func turnCarry(from old: TabletOrientation, to new: TabletOrientation, ringLampsTurn: Bool) -> TurnCarry {
        var carry = TurnCarry()
        guard old != new else { return carry }
        if let before = landscapeEquivalents(turnedTo: old), let after = landscapeEquivalents(turnedTo: new) {
            let atPlace = Dictionary(after.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
            for (control, place) in before {
                guard let moved = atPlace[place], moved != control else { continue }
                switch (control, moved) {
                case let (.expressKey(a), .expressKey(b)): carry.keys[a] = b
                case let (.bezel(a), .bezel(b)): carry.bezelButtons[a] = b
                case (.ring(0), .ring(1)), (.dial(0), .dial(1)): carry.tradesRotaries = true
                default: break
                }
            }
        }
        if ringLampsTurn { carry.lampShift = (new.counterclockwiseTurns - old.counterclockwiseTurns + 4) % 4 }
        let hasStrips = parts.contains { $0.control == .strip }
        carry.invertsStrips = hasStrips && old.isHalfTurn != new.isHalfTurn
        return carry
    }
}
