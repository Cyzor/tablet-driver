// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TabletKit

/// A control the Buttons pane has state or a row for.
enum ControlTarget: Hashable {
    /// `LiveButtonState.expressKeys` and `expressKeyBindings`, 0–15.
    case expressKey(Int)
    /// `bezelButtons`, 0–2.
    case bezel(Int)
    /// A ring's center button or a dial's toggle key, 0 or 1:
    /// `touchRingButtonDown` and `touchRing2ButtonDown`.
    case ringCenter(Int)
    /// The ring, dial, or strip itself, 0 or 1.
    case ring(Int)
    case dial(Int)
    case strip(Int)

    /// A fixed bit for each target, so a set of them fits a `UInt64`.
    var bit: Int {
        switch self {
        case let .expressKey(i): return i
        case let .bezel(i): return 16 + i
        case let .ringCenter(i): return 19 + i
        case let .ring(i): return 21 + i
        case let .dial(i): return 23 + i
        case let .strip(i): return 25 + i
        }
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
        /// Intuos4, Intuos5, and Intuos Pro gen 1: the key set into the ring is its center.
        case intuos4To5
        /// Intuos Pro gen 2 (PTH-x60): the key set into the ring is its center.
        case intuosPro2
        /// Intuos Pro gen 3 (PTK-x70): each dial's mode key is its toggle.
        case intuosPro3
        /// Cintiq 24HD: the mode keys beside each ring are the first three keys of their side.
        case cintiq24HD
    }

    /// One layout part's targets.
    struct Part: Equatable {
        /// The ring, dial, or strip the part is, if it's one.
        var control: ControlTarget?
        /// Each of the part's keys by letter.
        var keys: [Character: ControlTarget] = [:]
    }

    var family: Family
    /// One for each of the model's layout parts, in the same order.
    var parts: [Part]

    /// Families whose key order has been checked on hardware. Each entry
    /// cites its evidence.
    static let verifiedFamilies: Set<Family> = []

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
        case .intuosV1 where spec.hasTouchRing && !spec.isPenDisplay: return .intuos4To5
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
            case let (.intuos4To5, .ring(n, .center(letter))), let (.intuosPro2, .ring(n, .center(letter))):
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
            return Part(control: control, keys: keys)
        }
        return TabletControlMap(family: family, parts: parts)
    }

    /// Every target the map draws.
    var targets: [ControlTarget] {
        parts.flatMap { part in (part.control.map { [$0] } ?? []) + part.keys.values }
    }
}
