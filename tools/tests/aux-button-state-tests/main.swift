// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

private var checks = 0
private var failures = 0
private func expect(_ condition: Bool, _ message: String, line: UInt = #line) {
    checks += 1
    if !condition {
        failures += 1
        FileHandle.standardError.write(Data("FAIL (line \(line)): \(message)\n".utf8))
    }
}

private let command = ButtonBinding(modifierOnly: .command)
private let shift = ButtonBinding(modifierOnly: .shift)
private let commandZ = ButtonBinding(kind: .keyCombo, keyCode: 6,
                                    modifierFlags: CGEventFlags.maskCommand.rawValue, keyLabel: "Z")
private typealias Action = AuxButtonState.Action

// Pad state survives pen activity. Both reported release sequences from the
// stuck-Command bug must yield exactly one down and one matching up, even if
// a profile changes during the hold. Cover bezel and both center keys too.
for control: AuxButtonState.Control in [.button(0), .button(16), .ring, .ring2] {
    for heldReports in [0, 1, 100] {
        var state = AuxButtonState()
        var actions = state.update(control, down: true, binding: command)
        expect(state.isHeld(control), "press must be remembered")
        for _ in 0..<heldReports {
            actions += state.update(control, down: true, binding: shift)
        }
        actions += state.update(control, down: false, binding: shift)
        expect(actions == [Action(binding: command, down: true), Action(binding: command, down: false)],
               "held reports and a changed profile must not duplicate or remap the hold")
        expect(!state.hasHeldControls, "release must clear the physical hold")
        expect(state.update(control, down: false, binding: shift).isEmpty,
               "duplicate releases must not decrement another button's contribution")
    }
}

// A new mapping is picked up only on the next press, including a change to
// None. A release must still lift the original plain key and its modifiers.
do {
    var state = AuxButtonState()
    _ = state.update(.button(2), down: true, binding: commandZ)
    expect(state.update(.button(2), down: false, binding: .none)
           == [Action(binding: commandZ, down: false)], "None must not swallow an old shortcut's release")
    expect(state.update(.button(2), down: true, binding: shift)
           == [Action(binding: shift, down: true)], "next press must use the new mapping")
}

// A mechanical re-press balances the old binding before pressing the current
// one. Click Lock's captured kind controls its held-frame exception.
do {
    var state = AuxButtonState()
    _ = state.update(.button(0), down: true, binding: command)
    expect(state.update(.button(0), down: true, binding: shift, mechanicalPulse: true)
           == [Action(binding: command, down: false), Action(binding: shift, down: true)],
           "mechanical re-press must balance the old shortcut")
    expect(state.update(.button(0), down: false, binding: command)
           == [Action(binding: shift, down: false)], "re-press release must use its captured mapping")
    let lock = ButtonBinding(kind: .clickLock)
    _ = state.update(.button(1), down: true, binding: lock)
    expect(state.update(.button(1), down: true, binding: command, mechanicalPulse: true).isEmpty,
           "Click Lock must ignore held-frame press pulses even after remapping")
    _ = state.update(.button(2), down: true, binding: command)
    expect(state.update(.button(2), down: true, binding: lock, mechanicalPulse: true)
           == [Action(binding: command, down: false), Action(binding: lock, down: true)],
           "remapping to Click Lock must still release the previous shortcut")
}

// Multiple keys and devices can contribute the same modifier. Disconnect
// drains only the owning ledger and is idempotent; the other device remains
// held and eventually supplies its own matching release.
do {
    var tablet = AuxButtonState()
    var remote = AuxButtonState()
    _ = tablet.update(.button(0), down: true, binding: command)
    _ = tablet.update(.button(1), down: true, binding: commandZ)
    _ = tablet.update(.ring, down: true, binding: .spacebar)
    _ = tablet.update(.ring2, down: true, binding: shift)
    _ = remote.update(.button(0), down: true, binding: command)
    let releases = tablet.releaseAll()
    expect(releases == [Action(binding: command, down: false), Action(binding: commandZ, down: false),
                        Action(binding: .spacebar, down: false), Action(binding: shift, down: false)],
           "disconnect must release every captured binding once")
    expect(!tablet.hasHeldControls && tablet.releaseAll().isEmpty,
           "repeated disconnect must not release anything twice")
    expect(remote.isHeld(.button(0)), "disconnect must leave the other device's hold intact")
    expect(remote.update(.button(0), down: false, binding: .none)
           == [Action(binding: command, down: false)], "other device must still balance its own modifier")
}

print("Aux button state: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
