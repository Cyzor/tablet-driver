// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - RotaryIndex

/// Which rotary control a lookup is about. Only PTK-670/870 and the Cintiq
/// 24HD have a second.
enum RotaryIndex: Int, Codable, CaseIterable {
    case first = 0
    case second = 1
}

// MARK: - RotaryConfig

/// One rotary control's modes and which one is active. Mechanism-neutral:
/// rings, dials and strips differ only in the injector.
///
/// The control's toggle binding belongs here too but hasn't moved yet.
struct RotaryConfig: Codable, Equatable {
    var slots: [ControlSlot]
    var activeSlotIndex: Int

    init(slots: [ControlSlot] = ControlSlot.defaults, activeSlotIndex: Int = 0) {
        self.slots = slots
        self.activeSlotIndex = activeSlotIndex
    }

    /// The slot this control is on, or nil if the index is out of range.
    var activeSlot: ControlSlot? {
        slots.indices.contains(activeSlotIndex) ? slots[activeSlotIndex] : nil
    }

    /// Next non-Skip slot, wrapping. Stays put if every slot is Skip.
    func indexAfterCycling() -> Int {
        let count = max(1, slots.count)
        var next = activeSlotIndex
        for _ in 0..<count {
            next = (next + 1) % count
            if slots.indices.contains(next), slots[next].action != .skip { return next }
        }
        return activeSlotIndex
    }

    /// Clamps a jump-to-mode target into range. Unlike cycling, a Skip
    /// target is honored — the user asked for that mode.
    func clampedSlotTarget(_ target: Int) -> Int {
        min(max(0, target), max(0, slots.count - 1))
    }
}

// MARK: - RotarySet

/// Every rotary control on one device. Storage is per-control, but on
/// hardware whose controls aren't independent every lookup resolves to
/// control 0. Only the PTK series is independent today; the 24HD's rings
/// mirror until verified otherwise.
struct RotarySet: Codable, Equatable {
    /// One entry per physical control. Always non-empty.
    private(set) var controls: [RotaryConfig]

    /// Describes the hardware, not a user choice, so it's set from the spec
    /// at connect time and never persisted — a stored copy could outlive a
    /// registry fix or travel in a preset.
    var controlsAreIndependent: Bool

    private enum CodingKeys: String, CodingKey { case controls }

    init(controls: [RotaryConfig] = [RotaryConfig()], controlsAreIndependent: Bool = false) {
        self.controls = controls.isEmpty ? [RotaryConfig()] : controls
        self.controlsAreIndependent = controlsAreIndependent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try c.decode([RotaryConfig].self, forKey: .controls)
        controls = stored.isEmpty ? [RotaryConfig()] : stored
        controlsAreIndependent = false
    }

    /// The effective control for a lookup, after gating and range-clamping.
    func resolvedIndex(_ index: RotaryIndex) -> Int {
        guard controlsAreIndependent else { return 0 }
        return controls.indices.contains(index.rawValue) ? index.rawValue : 0
    }

    subscript(index: RotaryIndex) -> RotaryConfig {
        get { controls[resolvedIndex(index)] }
        set { controls[resolvedIndex(index)] = newValue }
    }

    /// Grows or shrinks to `count` controls; new ones copy control 0.
    ///
    /// No migration from `touchRingSlots`: only the PTK series reads this, and
    /// it has never shipped outside snapshot builds.
    mutating func resize(to count: Int) {
        let target = max(1, count)
        if controls.count > target {
            controls.removeLast(controls.count - target)
        } else {
            while controls.count < target { controls.append(controls[0]) }
        }
    }

    /// Every control back to default modes, keeping the control count and
    /// the hardware capability flag.
    func resetToDefaults() -> RotarySet {
        RotarySet(
            controls: Array(repeating: RotaryConfig(), count: controls.count),
            controlsAreIndependent: controlsAreIndependent)
    }

    // MARK: - The storage seam

    /// One control's state from whichever layout this tablet uses: this set,
    /// or the shared `touchRingSlots` plus per-control active indices. The
    /// settings and the injection snapshot both delegate here so the rule
    /// lives once. Collapses to `self[index]` when every device moves over.
    func resolving(
        _ index: RotaryIndex,
        legacySlots: @autoclosure () -> [ControlSlot],
        legacyActiveIndex: @autoclosure () -> Int,
        legacyActiveIndex2: @autoclosure () -> Int
    ) -> RotaryConfig {
        guard controlsAreIndependent else {
            return RotaryConfig(
                slots: legacySlots(),
                activeSlotIndex: index == .second ? legacyActiveIndex2() : legacyActiveIndex())
        }
        return self[index]
    }
}
