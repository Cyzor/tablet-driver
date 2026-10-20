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
/// letters, from `TabletLayoutIdentity`, turned into MockTab's indices by
/// the rule for the model's family.
///
/// A family's key order comes from libwacom and the kernel, which can be
/// wrong for a given model, so `forDevice` returns nil until the family is
/// in `verifiedFamilies`. A tablet without a verified family gets no
/// diagram rather than one that lights the wrong key.
struct TabletControlMap: Equatable {
    enum Family: CaseIterable {
        /// Intuos4: the key set into the ring is its center. Its keys arrive in
        /// a different report from Intuos5's, so it's verified apart.
        case intuos4
        /// Intuos5 and Intuos Pro gen 1: the key set into the ring is its center.
        case intuos5
        /// Intuos Pro gen 2 (PTH-x60): the key set into the ring is its center.
        case intuosPro2
        /// Intuos Pro gen 3 (PTK-x70): each dial's mode key is its toggle.
        case intuosPro3
        /// Cintiq 24HD: the mode keys beside each ring are the first three keys of their side.
        case cintiq24HD
    }

    /// One layout part's targets, as the tablet figure draws them.
    typealias Part = TabletFigure.PartControls

    var family: Family
    /// One for each of the model's layout parts, in the same order.
    var parts: [Part]

    /// Families whose key order has been checked on hardware. Each entry
    /// cites its evidence.
    static let verifiedFamilies: Set<Family> = [
        .intuos5,  // Notes/Evidence/PTH-850-Key-Order.md
        .cintiq24HD,  // Notes/Evidence/DTK-2400-Key-Order.md
    ]

    /// The map for a connected model, or nil when it has no layout, no known
    /// family, or a family not yet verified.
    static func forDevice(productID: Int, spec: TabletSpec) -> TabletControlMap? {
        guard let family = family(for: spec), verifiedFamilies.contains(family),
              let identity = TabletLayoutIdentity.all[productID]
        else { return nil }
        return make(identity, family: family)
    }

    /// The family whose rule fits a model, told apart by what the registry
    /// knows about it, not by product ID.
    static func family(for spec: TabletSpec) -> Family? {
        switch spec.format {
        // The Cintiq 13HD shares the format but has no ring and a rocker.
        case .intuosV1 where spec.hasTouchRing && !spec.isPenDisplay:
            return spec.family == .intuos4 ? .intuos4 : .intuos5
        // The MobileStudio Pro shares the format but has mode keys around its ring.
        case .intuosV2 where spec.hasTouchRing && !spec.isPenDisplay: return .intuosPro2
        case .intuosV3 where spec.hasMechanicalDial: return .intuosPro3
        // The Companion 2 shares the format but has one ring with a rocker.
        case .cintiqV1 where spec.hasDualRings: return .cintiq24HD
        default: return nil
        }
    }

    /// Applies a family's rule, without the verification gate. Special keys
    /// (ring centers, dial toggles) take their own targets; every other key
    /// takes the next ExpressKey index in letter order.
    static func make(_ identity: TabletLayoutIdentity, family: Family) -> TabletControlMap {
        var special: [Character: ControlTarget] = [:]
        for entry in identity.entries {
            switch (family, entry) {
            case let (.intuos4, .ring(n, .center(letter))), let (.intuos5, .ring(n, .center(letter))),
                 let (.intuosPro2, .ring(n, .center(letter))):
                special[letter] = .ringCenter(n - 1)
            default: break
            }
        }
        if family == .intuosPro3 {
            for (letter, mode) in identity.modeSwitches {
                if case let .dial(n) = mode.control, mode.mode == nil { special[letter] = .ringCenter(n - 1) }
            }
        }
        let plain = Set(identity.letters).subtracting(special.keys).sorted()
        var targets = special
        for (index, letter) in plain.enumerated() { targets[letter] = .expressKey(index) }

        let parts = identity.entries.map { entry -> Part in
            let control: ControlTarget?
            switch entry {
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
}
