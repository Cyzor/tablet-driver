// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - TurnCarry

/// What turning a tablet does to its saved assignments, so every place keeps
/// its action. Saved assignments belong to physical controls; when the
/// tablet turns, each moves to the control that now sits in its old place.
struct TurnCarry: Equatable {
    /// ExpressKey `from`'s assignment moves to key `keys[from]`. Keys not
    /// listed stay.
    var keys: [Int: Int] = [:]
    /// The same for bezel buttons.
    var bezelButtons: [Int: Int] = [:]
    /// The two rings or dials, and their center or toggle keys, trade places.
    var tradesRotaries = false
    /// A ring with a lamp at each corner turns its lamps with it: the mode in
    /// saved slot s moves to slot s + `lampShift`, wrapping at four.
    var lampShift = 0
    /// Touch strips now run the other way as you see them.
    var invertsStrips = false

    /// The command that applies a half turn's carry without turning the
    /// tablet, and its undo name.
    static var turnAroundTitle: String {
        String(localized: "Turn Assignments Around",
               comment: "Tablet diagram right-click command and its undo name: moves each key's assignment to the key in the opposite place, as a half turn would, without turning the tablet")
    }

    var isIdentity: Bool {
        keys.allSatisfy { $0.key == $0.value } && bezelButtons.allSatisfy { $0.key == $0.value }
            && !tradesRotaries && lampShift % 4 == 0 && !invertsStrips
    }

    /// `binding` aimed at the same ring and mode after the turn. Other
    /// actions don't name a control and pass through.
    func carried(_ binding: ButtonBinding) -> ButtonBinding {
        var carried = binding
        switch binding.kind {
        case .ringCycle: carried.kind = tradesRotaries ? .ringCycle2 : .ringCycle
        case .ringCycle2: carried.kind = tradesRotaries ? .ringCycle : .ringCycle2
        case .ringSelectSlot: carried.kind = tradesRotaries ? .ringSelectSlot2 : .ringSelectSlot
        case .ringSelectSlot2: carried.kind = tradesRotaries ? .ringSelectSlot : .ringSelectSlot2
        default: return binding
        }
        if binding.kind == .ringSelectSlot || binding.kind == .ringSelectSlot2 {
            carried.keyCode = UInt16(shifted(Int(binding.keyCode), count: 4))
        }
        return carried
    }

    /// Everything a turn moves, carried.
    func carried(_ old: TurnAssignments) -> TurnAssignments {
        var new = old
        new.expressKeys = moved(old.expressKeys, by: keys)
        new.bezelButtons = moved(old.bezelButtons, by: bezelButtons)
        let first = carried(old.center), second = carried(old.center2)
        (new.center, new.center2) = tradesRotaries ? (second, first) : (first, second)
        new.sharedSlots = shiftedSlots(old.sharedSlots)
        let active = shifted(old.activeSlot, count: old.sharedSlots.count)
        let active2 = shifted(old.activeSlot2, count: old.sharedSlots.count)
        (new.activeSlot, new.activeSlot2) = tradesRotaries ? (active2, active) : (active, active2)
        new.rotaries = old.rotaries.map { controls in
            let turned = controls.map { control in
                RotaryConfig(slots: shiftedSlots(control.slots),
                             activeSlotIndex: shifted(control.activeSlotIndex, count: control.slots.count))
            }
            return tradesRotaries && turned.count == 2 ? [turned[1], turned[0]] : turned
        }
        new.reverseDirection = old.reverseDirection != invertsStrips
        return new
    }

    private func moved(_ list: [ButtonBinding], by map: [Int: Int]) -> [ButtonBinding] {
        var moved = list.map(carried)
        for (from, to) in map where list.indices.contains(from) && list.indices.contains(to) {
            moved[to] = carried(list[from])
        }
        return moved
    }

    /// Only a four-slot ring's modes sit at its corners.
    private func shifted(_ index: Int, count: Int) -> Int {
        guard count == 4, (0..<4).contains(index) else { return index }
        return ((index + lampShift) % 4 + 4) % 4
    }

    private func shiftedSlots(_ slots: [ControlSlot]) -> [ControlSlot] {
        guard slots.count == 4, lampShift % 4 != 0 else { return slots }
        var shifted = slots
        for (i, slot) in slots.enumerated() { shifted[self.shifted(i, count: 4)] = slot }
        return shifted
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

// MARK: - TurnAssignments

/// The saved assignments a turn moves, as one app-and-profile context reads
/// them, defaults filled in.
struct TurnAssignments: Equatable {
    var expressKeys: [ButtonBinding]
    var bezelButtons: [ButtonBinding]
    /// The first ring's center button or dial's toggle key.
    var center: ButtonBinding
    var center2: ButtonBinding
    /// A single ring's modes, or both rings' on hardware whose rings share them.
    var sharedSlots: [ControlSlot]
    var activeSlot: Int
    var activeSlot2: Int
    /// Each ring or dial's own modes, on hardware whose two are independent.
    var rotaries: [RotaryConfig]?
    var reverseDirection: Bool
}

// MARK: - LayeredSetting

/// One saved setting across a tablet's layers: its value on the tablet
/// itself, and in each profile and app override that saves its own. A
/// context reads the override's value first, then the profile's, then the
/// tablet's.
struct LayeredSetting<Value: Equatable>: Equatable {
    var device: Value
    var profiles: [UUID: Value] = [:]
    var overrides: [String: Value] = [:]

    func value(override: String?, profile: UUID?) -> Value {
        if let override, let value = overrides[override] { return value }
        if let profile, let value = profiles[profile] { return value }
        return device
    }

    /// The setting rewritten so every context reads what `desired` gives it,
    /// each change made in the least specific layer that can hold it: the
    /// tablet's own for contexts without a profile or override, then each
    /// profile, then each app override. An override serves every profile at
    /// once, so where its profiles want different values, `preferredProfile`
    /// decides.
    func rewritten(
        overrideIDs: [String], profileIDs: [UUID], preferredProfile: UUID?,
        desired: (_ override: String?, _ profile: UUID?) -> Value
    ) -> LayeredSetting {
        var result = self
        result.device = desired(nil, nil)
        for profile in profileIDs {
            let want = desired(nil, profile)
            if result.profiles[profile] != nil || result.device != want { result.profiles[profile] = want }
        }
        for override in overrideIDs {
            let contexts: [UUID?] = [nil] + profileIDs.map { Optional($0) }
            let wants = contexts.map { desired(override, $0) }
            let underneath = contexts.map { result.value(override: nil, profile: $0) }
            guard result.overrides[override] != nil || wants != underneath else { continue }
            let pick = contexts.firstIndex(of: preferredProfile) ?? 0
            result.overrides[override] = wants[pick]
        }
        return result
    }
}
