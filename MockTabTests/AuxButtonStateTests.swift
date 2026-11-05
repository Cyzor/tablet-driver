// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab contributors
// SPDX-License-Identifier: GPL-3.0-or-later

// An ExpressKey press keeps its binding until its own release, whatever pen
// proximity, profiles, or app overrides do meanwhile. `AuxButtonState.swift`
// is compiled into this bundle, so the app isn't launched.

import CoreGraphics
import Testing

private let command = ButtonBinding(modifierOnly: .command)
private let shift = ButtonBinding(modifierOnly: .shift)
private let commandZ = ButtonBinding(
    kind: .keyCombo, keyCode: 6, modifierFlags: CGEventFlags.maskCommand.rawValue, keyLabel: "Z")
private typealias Action = AuxButtonState.Action

@Suite struct AuxButtonStateTests {

    /// Held reports and a mapping change mid-hold yield one down and its
    /// matching up, for ExpressKeys, bezel keys, and both center keys.
    @Test(arguments: [
        AuxButtonState.Control.button(0), .button(16), .ring, .ring2,
    ], [0, 1, 100])
    func holdPairsOneDownWithOneUp(control: AuxButtonState.Control, heldReports: Int) {
        var state = AuxButtonState()
        var actions = state.update(control, down: true, binding: command)
        #expect(state.isHeld(control))
        for _ in 0..<heldReports {
            actions += state.update(control, down: true, binding: shift)
        }
        actions += state.update(control, down: false, binding: shift)
        #expect(actions == [Action(binding: command, down: true), Action(binding: command, down: false)])
        #expect(!state.hasHeldControls)
        // A second release must not lift another key's share of a modifier.
        #expect(state.update(control, down: false, binding: shift).isEmpty)
    }

    /// A new mapping applies from the next press, even a change to None.
    @Test func newMappingWaitsForNextPress() {
        var state = AuxButtonState()
        _ = state.update(.button(2), down: true, binding: commandZ)
        #expect(state.update(.button(2), down: false, binding: .none)
            == [Action(binding: commandZ, down: false)])
        #expect(state.update(.button(2), down: true, binding: shift)
            == [Action(binding: shift, down: true)])
    }

    /// A mechanical re-press releases the old binding before pressing the
    /// current one. Click Lock ignores held-frame pulses.
    @Test func mechanicalRepress() {
        var state = AuxButtonState()
        _ = state.update(.button(0), down: true, binding: command)
        #expect(state.update(.button(0), down: true, binding: shift, mechanicalPulse: true)
            == [Action(binding: command, down: false), Action(binding: shift, down: true)])
        #expect(state.update(.button(0), down: false, binding: command)
            == [Action(binding: shift, down: false)])

        let lock = ButtonBinding(kind: .clickLock)
        _ = state.update(.button(1), down: true, binding: lock)
        #expect(state.update(.button(1), down: true, binding: command, mechanicalPulse: true).isEmpty)

        _ = state.update(.button(2), down: true, binding: command)
        #expect(state.update(.button(2), down: true, binding: lock, mechanicalPulse: true)
            == [Action(binding: command, down: false), Action(binding: lock, down: true)])
    }

    /// Disconnect releases each of its device's holds once and leaves other
    /// devices' holds alone.
    @Test func disconnectReleasesOnlyItsOwnHolds() {
        var tablet = AuxButtonState()
        var remote = AuxButtonState()
        _ = tablet.update(.button(0), down: true, binding: command)
        _ = tablet.update(.button(1), down: true, binding: commandZ)
        _ = tablet.update(.ring, down: true, binding: .spacebar)
        _ = tablet.update(.ring2, down: true, binding: shift)
        _ = remote.update(.button(0), down: true, binding: command)
        #expect(tablet.releaseAll() == [
            Action(binding: command, down: false), Action(binding: commandZ, down: false),
            Action(binding: .spacebar, down: false), Action(binding: shift, down: false),
        ])
        #expect(!tablet.hasHeldControls)
        #expect(tablet.releaseAll().isEmpty)
        #expect(remote.isHeld(.button(0)))
        #expect(remote.update(.button(0), down: false, binding: .none)
            == [Action(binding: command, down: false)])
    }
}
