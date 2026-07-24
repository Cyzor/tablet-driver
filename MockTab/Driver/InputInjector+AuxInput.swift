// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import os
import TabletKit

// Non-pen input paths — express keys, bezel buttons, touch ring/strip, and
// rotary side wheels — split out of InputInjector.swift. The button/ring
// tracking state and fractional-delta accumulators these read live on the
// main class body (Swift class extensions can't hold stored properties) and
// stay HIDThread-confined exactly as documented there.
extension InputInjector {

    // MARK: - Express key injection

    /// Ring/strip rotations are discrete pulses, not holds. Pairing down+up in a
    /// single call prevents modifier bits in the binding from leaking into
    /// `groundTruthSyntheticFlags` across rotation samples.
    func fireKeyTap(_ binding: ButtonBinding,
                            at loc: CGPoint,
                            snapshot: InjectionSnapshot,
                            settings: TabletSettings?) {
        fireButtonAction(binding, down: true, at: loc, snapshot: snapshot, settings: settings)
        fireButtonAction(binding, down: false, at: loc, snapshot: snapshot, settings: settings)
    }

    func injectAux(buttons: AuxButtons, settings: TabletSettings?) {
        rearmWatchdog()
        guard let snap = injectionSnapshot else { return }
        let bindings = snap.expressKeyBindings
        let cursorPos = currentCursorPosition()

        // ── Express keys ───────────────────────────────────────────────────────
        for i in 0..<16 {
            let down = buttons[i]
            let hasMechanicalPulse = i < 8 && (buttons.mechanicalMask >> i) & 1 != 0
            if down != lastAuxButtons[i] {
                // Update tracking state first so the quiescent check inside
                // fireButtonAction sees the current button state, not the pre-transition state.
                lastAuxButtons[i] = down
                fireButtonAction(bindings[i], down: down, at: cursorPos,
                                 snapshot: snap, settings: settings, isAux: true)
            } else if down && hasMechanicalPulse {
                // Button is already tracked as down, but a new mechanical pulse arrived —
                // the user re-pressed before the release event was seen. Force a complete
                // up→down cycle so the key fires correctly without getting swallowed.
                fireButtonAction(bindings[i], down: false, at: cursorPos,
                                 snapshot: snap, settings: settings, isAux: true)
                fireButtonAction(bindings[i], down: true, at: cursorPos,
                                 snapshot: snap, settings: settings, isAux: true)
                // lastAuxButtons[i] stays true — the button is still down after this cycle
            }
        }

        // ── Bezel buttons (device's own onboard capacitive buttons; e.g. the
        // Cintiq DTK-2400's OSD keys) — decoded into `buttons[16..18]` by the
        // relevant decoder but routed through their own binding set rather
        // than `expressKeyBindings`, since some devices already use all 16
        // express-key slots. ─────────────────────────────────────────────────
        let bezelBindings = snap.bezelButtonBindings
        for i in 0..<3 {
            let auxIndex = 16 + i
            let down = buttons[auxIndex]
            if down != lastAuxButtons[auxIndex] {
                lastAuxButtons[auxIndex] = down
                fireButtonAction(bezelBindings[i], down: down, at: cursorPos,
                                 snapshot: snap, settings: settings, isAux: true)
            }
        }

        // ── Touch ring center button ───────────────────────────────────────────
        let ringButtonDown = buttons.touchRingButtonDown
        if ringButtonDown != lastRingButtonDown {
            lastRingButtonDown = ringButtonDown
            fireButtonAction(snap.touchRingButtonBinding, down: ringButtonDown,
                             at: cursorPos, snapshot: snap, settings: settings, isAux: true)
        }

        // ── Touch ring ─────────────────────────────────────────────────────────
        // Position 0x7F means no contact.  Compute a wrap-aware delta when a
        // finger is actively moving (both current and previous positions valid).
        // The ring has 72 steps (0–71, ~5° each); wrap threshold is 36.
        let activeSlot: ControlSlot? = snap.touchRingSlots.indices.contains(snap.touchRingActiveSlotIndex)
            ? snap.touchRingSlots[snap.touchRingActiveSlotIndex] : nil

        let ringPos = buttons.touchRingPosition
        if buttons.touchRingActive, lastRingPos != 0x7F {
            var delta = Int(ringPos) - Int(lastRingPos)
            if delta > 36 { delta -= 72 }
            if delta < -36 { delta += 72 }
            // Normalize to the touch strip's "increasing = up" convention.
            // Which way the raw byte counts depends on the hardware family —
            // see `ringDeltaIsInverted`.
            if ringDeltaIsInverted { delta = -delta }
            if delta != 0, let slot = activeSlot {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &ringAccum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            }
        }
        if !buttons.touchRingActive { ringAccum = 0 }
        lastRingPos = buttons.touchRingActive ? ringPos : 0x7F

        // ── Touch ring 2 (DTK-2400 right bezel) — shares touchRingSlots ──
        let ring2Pos = buttons.touchRing2Position
        if buttons.touchRing2Active, lastRing2Pos != 0x7F {
            var delta = Int(ring2Pos) - Int(lastRing2Pos)
            if delta > 36 { delta -= 72 }
            if delta < -36 { delta += 72 }
            if ringDeltaIsInverted { delta = -delta }
            if delta != 0, let slot = activeSlot {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &ring2Accum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            }
        }
        if !buttons.touchRing2Active { ring2Accum = 0 }
        lastRing2Pos = buttons.touchRing2Active ? ring2Pos : 0x7F

        // ── Touch strips (Intuos3 WS) — share touchRingSlots ───────────────────
        // Strips are linear (no wrap); each zone step maps 1:1 to a scroll event.

        // Strip 1 (left).
        let s1pos = buttons.touchStrip1Position
        if buttons.touchStrip1Active, lastStrip1Pos != 0xFF {
            let delta = Int(s1pos) - Int(lastStrip1Pos)
            if delta != 0, let slot = activeSlot {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &strip1Accum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            }
        }
        if !buttons.touchStrip1Active { strip1Accum = 0 }
        lastStrip1Pos = buttons.touchStrip1Active ? s1pos : 0xFF

        // Strip 2 (right).
        let s2pos = buttons.touchStrip2Position
        if buttons.touchStrip2Active, lastStrip2Pos != 0xFF {
            let delta = Int(s2pos) - Int(lastStrip2Pos)
            if delta != 0, let slot = activeSlot {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &strip2Accum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            }
        }
        if !buttons.touchStrip2Active { strip2Accum = 0 }
        lastStrip2Pos = buttons.touchStrip2Active ? s2pos : 0xFF
    }

    // MARK: - Relative wheel (IntuosV3 PTK-x70 side scroll wheels)

    /// Called on HIDThread for each non-zero wheel step from a device with
    /// physical rotary encoders (e.g. PTK-470/670/870).  Routes through
    /// `touchRingSlots[index]` so the user can configure scroll vs. key-press
    /// behaviour through the ring settings UI.  Falls back to a direct scroll
    /// event if no slot is defined for that index.
    func injectWheel(index: Int, delta: Int, settings: TabletSettings?) {
        rearmWatchdog()
        guard let snap = injectionSnapshot else { return }
        let cursorPos = currentCursorPosition()
        // Xencelabs Quick Keys has a single dial reusing the Wacom touch-ring
        // mode-cycling model (4 selectable modes via a mode-cycle key), unlike
        // IntuosV3 PTK-x70's two independent physical wheels (each hardware
        // index is a distinct wheel, not a mode). So for the dial, resolve
        // through the live active-slot index rather than the fixed hardware
        // index — otherwise "Ring: Cycle" / "Jump to Mode N" have no effect
        // on the dial even though the UI exposes them.
        let slotIndex = deviceVendorID == 0x28BD ? snap.touchRingActiveSlotIndex : index
        let slot: ControlSlot? = snap.touchRingSlots.indices.contains(slotIndex)
            ? snap.touchRingSlots[slotIndex] : nil
        if let slot {
            if index == 0 {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &wheel0Accum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            } else {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &wheel1Accum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            }
        } else {
            postScrollWheelEvent(delta: delta, at: cursorPos)
        }
    }
}
