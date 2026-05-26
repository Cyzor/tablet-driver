// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

// ModifierMath.swift — pure-math helpers for the synthetic-modifier state
// machine in InputInjector. These are stateless functions on their inputs;
// they own no state and are safe to call from any thread.
//
// Extracted from InputInjector so the bit logic can be exercised by the
// SwiftPM test package without standing up the full AppKit / IOKit runtime.
// See Notes/InputInjector-Modifier-State-Invariants.md for the rules that
// govern when each helper is called and why the math is the way it is.

import CoreGraphics
import Foundation

enum ModifierMath {

    /// Bits this driver "owns" for synthetic-modifier injection: ⌘⌥⇧⌃.
    /// This is the canonical definition; `InputInjector` references it directly.
    static let managedMask: UInt64 =
        CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskControl.rawValue

    /// Build the `flags` field for an outbound `flagsChanged` release event.
    ///
    /// Non-managed bits are preserved from `systemFlags` (CapsLock, Fn, etc.
    /// must keep their current state). Managed bits come entirely from
    /// `remainingSyntheticFlags`; the caller must already have removed any
    /// bits it intends to release from that value.
    ///
    /// IMPORTANT: do not pass `hidSystemState` as the managed-bit source.
    /// `hidSystemState` is polluted by our own injected events; using it for
    /// managed bits would re-assert the very bits the release event is meant
    /// to clear. Pass it ONLY for non-managed bits via `systemFlags`.
    static func releaseEventFlags(
        systemFlags: UInt64,
        remainingSyntheticFlags: UInt64
    ) -> UInt64 {
        let nonManaged = systemFlags & ~managedMask
        let managed = remainingSyntheticFlags & managedMask
        return nonManaged | managed
    }

    /// Identify which synthetic-modifier bits are no longer justified by the
    /// currently-held pen-button bindings — i.e. orphans left behind by a
    /// tool change (e.g. eraser flip mid-hold).
    ///
    /// Only considers bits inside `managedMask`; bits outside are not ours
    /// to release.
    static func excessSyntheticBits(
        groundTruth: UInt64,
        expected: UInt64
    ) -> UInt64 {
        groundTruth & ~expected & managedMask
    }

    /// Combine physical and synthetic modifier state for outbound state-change
    /// events (mouseDown / mouseUp / click / scroll / flagsChanged). Mirrors
    /// `InputInjector.currentEventFlags`.
    ///
    /// - For managed bits: take physical OR synthetic. Physical state comes
    ///   from the listen-only tap cache (`tapLastPhysicalFlags`), NOT from
    ///   `hidSystemState` — the latter lags one or more run-loop cycles
    ///   behind real keyboard events.
    /// - For non-managed bits: preserve `systemFlags` unchanged.
    static func currentEventFlags(
        systemFlags: UInt64,
        tapPhysicalManaged: UInt64,
        syntheticFlags: UInt64
    ) -> UInt64 {
        let nonManaged = systemFlags & ~managedMask
        let physManaged = tapPhysicalManaged & managedMask
        let synthManaged = syntheticFlags & managedMask
        return nonManaged | physManaged | synthManaged
    }

    /// True when a `flagsChanged` event seen by the listen-only tap should
    /// update `tapLastPhysicalFlags`. Filters out our own injected events
    /// (which have a private source state ID); only hardware-keyboard events
    /// (`hidSystemState`) qualify.
    static func shouldUpdatePhysicalCache(sourceStateID: Int32) -> Bool {
        sourceStateID == CGEventSourceStateID.hidSystemState.rawValue
    }
}
