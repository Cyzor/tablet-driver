// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import os
import TabletKit

// Non-pen input: ExpressKeys, bezel buttons, touch rings and strips, and
// dials. Their state lives on the main class body, HIDThread-confined.
extension InputInjector {

    // MARK: - Express key injection

    /// Ring and strip steps are taps, not holds. Pairing down and up keeps a
    /// binding's modifiers from leaking across steps.
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
                // Update first so fireButtonAction's quiescent check sees the new state.
                lastAuxButtons[i] = down
                fireButtonAction(bindings[i], down: down, at: cursorPos,
                                 snapshot: snap, settings: settings, isAux: true)
            } else if down && hasMechanicalPulse && bindings[i].kind != .clickLock {
                // A re-press arrived before its release: force up then down so
                // it isn't swallowed. Click Lock skips this, since some decoders
                // flag every held frame as a new press and each would toggle it.
                fireButtonAction(bindings[i], down: false, at: cursorPos,
                                 snapshot: snap, settings: settings, isAux: true)
                fireButtonAction(bindings[i], down: true, at: cursorPos,
                                 snapshot: snap, settings: settings, isAux: true)
            }
        }

        // ── Bezel buttons (e.g. DTK-2400 OSD keys) ─────────────────────────────
        // `buttons[16..18]`, with their own bindings: some devices use all 16
        // ExpressKey slots.
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

        // ── Firmware-owned ring mode (ExpressKey Remote) ───────────────────────
        // The remote's center button switches its own mode LEDs, so the
        // active slot follows the reported mode and the button fires nothing:
        // a host-side cycle on the same press would drift out of step.
        if let mode = buttons.touchRingHardwareMode {
            if mode != lastHardwareRingMode {
                lastHardwareRingMode = mode
                closeRingGestureEnvelopes()
                if let s = settings {
                    Task { @MainActor in
                        s.setActiveSlotIndex(s.rotary(.first).clampedSlotTarget(mode), for: .first)
                    }
                }
            }
            lastRingButtonDown = buttons.touchRingButtonDown
        }

        // ── Touch ring center button ───────────────────────────────────────────
        let ringButtonDown = buttons.touchRingButtonDown
        if buttons.touchRingHardwareMode == nil, ringButtonDown != lastRingButtonDown {
            lastRingButtonDown = ringButtonDown
            fireButtonAction(snap.touchRingButtonBinding, down: ringButtonDown,
                             at: cursorPos, snapshot: snap, settings: settings, isAux: true)
        }

        // ── Second dial's toggle key (PTK-670/870) ────────────────────────────
        let ring2ButtonDown = buttons.touchRing2ButtonDown
        if ring2ButtonDown != lastRing2ButtonDown {
            lastRing2ButtonDown = ring2ButtonDown
            fireButtonAction(snap.touchRingButtonBinding2, down: ring2ButtonDown,
                             at: cursorPos, snapshot: snap, settings: settings, isAux: true)
        }

        // ── Touch ring ─────────────────────────────────────────────────────────
        // 72 steps (0–71); 0x7F means no contact. Deltas wrap at 36.
        let activeSlot: ControlSlot? = snap.rotary(.first).activeSlot

        // Zoom/rotate gesture on a touch ring: begins on contact, before this
        // report's delta, and ends on lift. Dials use an idle timer instead.
        // Keyed on `touchRingActive` alone; see `ring1GestureOpen`.
        if !hasMechanicalDial, let slot = activeSlot, slot.action == .zoom || slot.action == .rotate {
            let kind: RingGestureKind = slot.action == .zoom ? .zoom : .rotate
            if buttons.touchRingActive, !ring1GestureOpen {
                ring1GestureOpen = true
                ring1GestureKind = kind
                postRingGesture(delta: 0, phase: .began, kind: kind)
            } else if !buttons.touchRingActive, ring1GestureOpen {
                ring1GestureOpen = false
                postRingGesture(delta: 0, phase: .ended, kind: ring1GestureKind)
            }
        } else if ring1GestureOpen {
            // The mode changed mid-gesture; end it.
            ring1GestureOpen = false
            postRingGesture(delta: 0, phase: .ended, kind: ring1GestureKind)
        }

        let ringPos = buttons.touchRingPosition
        let now = CFAbsoluteTimeGetCurrent()
        // A slow finger can read as lifted for a frame mid-turn and come back
        // several steps on (PTH-660 capture, 2026-09-27: 41 → no contact →
        // 36 after 320 ms). Treat a quick, nearby re-touch as the same touch
        // so that distance isn't dropped.
        var fromPos = lastRingPos
        if buttons.touchRingActive, lastRingPos == 0x7F, ringLiftPos != 0x7F,
           now - ringLiftTime < Self.ringDropoutBridge {
            var gap = Int(ringPos) - Int(ringLiftPos)
            if gap > 36 { gap -= 72 }
            if gap < -36 { gap += 72 }
            if abs(gap) < 10 { fromPos = ringLiftPos }
        }
        if !buttons.touchRingActive, lastRingPos != 0x7F {
            ringLiftPos = lastRingPos
            ringLiftTime = now
        } else if buttons.touchRingActive {
            ringLiftPos = 0x7F
        }
        if buttons.touchRingActive, fromPos != 0x7F {
            var delta = Int(ringPos) - Int(fromPos)
            if delta > 36 { delta -= 72 }
            if delta < -36 { delta += 72 }
            // Normalize to "increasing = up"; see `ringDeltaIsInverted`.
            if ringDeltaIsInverted { delta = -delta }
            if delta != 0, let slot = activeSlot {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &ringAccum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            }
        }
        if !buttons.touchRingActive { ringAccum = 0 }
        lastRingPos = buttons.touchRingActive ? ringPos : 0x7F

        // ── Touch ring 2 (DTK-2400 right bezel) ──────────────────────────
        // Reads control 1: the 24HD's rings mirror each other.
        let ring2Slot = activeSlot
        if !hasMechanicalDial, let slot = ring2Slot, slot.action == .zoom || slot.action == .rotate {
            let kind: RingGestureKind = slot.action == .zoom ? .zoom : .rotate
            if buttons.touchRing2Active, !ring2GestureOpen {
                ring2GestureOpen = true
                ring2GestureKind = kind
                postRingGesture(delta: 0, phase: .began, kind: kind)
            } else if !buttons.touchRing2Active, ring2GestureOpen {
                ring2GestureOpen = false
                postRingGesture(delta: 0, phase: .ended, kind: ring2GestureKind)
            }
        } else if ring2GestureOpen {
            ring2GestureOpen = false
            postRingGesture(delta: 0, phase: .ended, kind: ring2GestureKind)
        }

        let ring2Pos = buttons.touchRing2Position
        if buttons.touchRing2Active, lastRing2Pos != 0x7F {
            var delta = Int(ring2Pos) - Int(lastRing2Pos)
            if delta > 36 { delta -= 72 }
            if delta < -36 { delta += 72 }
            if ringDeltaIsInverted { delta = -delta }
            if delta != 0, let slot = ring2Slot {
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

    /// Ends any open zoom/rotate gesture on any ring or dial. Called before a
    /// mode change. Settings edits don't call it: the idle timer and
    /// `injectAux`'s per-report check already end those within a moment.
    func closeRingGestureEnvelopes() {
        closeMechanicalDialGesture()
        if ring1GestureOpen {
            ring1GestureOpen = false
            postRingGesture(delta: 0, phase: .ended, kind: ring1GestureKind)
        }
        if ring2GestureOpen {
            ring2GestureOpen = false
            postRingGesture(delta: 0, phase: .ended, kind: ring2GestureKind)
        }
    }

    /// Rearms the idle timer that ends a dial's zoom/rotate gesture. Called on
    /// every tick. The close reads the current gesture kind when it fires.
    func rearmMechanicalDialGestureIdleTimer(kind: RingGestureKind) {
        if let t = mechanicalDialGestureIdleTimer { CFRunLoopTimerInvalidate(t) }
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + Self.mechanicalDialGestureIdleTimeout,
            0, 0, 0
        ) { [weak self] _ in
            self?.closeMechanicalDialGesture()
        }
        mechanicalDialGestureIdleTimer = timer
        if let timer { CFRunLoopAddTimer(HIDThread.shared.runLoop, timer, .commonModes) }
    }

    /// Ends a dial's open zoom/rotate gesture. No-op when none is open.
    func closeMechanicalDialGesture() {
        mechanicalDialGestureIdleTimer.map { CFRunLoopTimerInvalidate($0) }
        mechanicalDialGestureIdleTimer = nil
        guard mechanicalDialGestureOpen else { return }
        mechanicalDialGestureOpen = false
        postRingGesture(delta: 0, phase: .ended, kind: mechanicalDialGestureKind)
    }

    /// One dial step (PTK-470/670/870, Quick Keys). Plays the dial's active
    /// mode, or scrolls if none is set.
    func injectWheel(index: Int, delta: Int, settings: TabletSettings?) {
        rearmWatchdog()
        guard let snap = injectionSnapshot else { return }
        let cursorPos = currentCursorPosition()
        // Each PTK dial has its own active mode. The Quick Keys' single dial
        // reports as index 1 on some transports, so it stays the first control.
        let control: RotaryIndex =
            (deviceVendorID == 0x28BD || index == 0) ? .first : .second
        let slot: ControlSlot? = snap.rotary(control).activeSlot
        if let slot {
            if index == 0 {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &wheel0Accum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            } else {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &wheel1Accum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            }
        } else {
            // No mode set: scroll, with the same direction rules as
            // dispatchRingDelta's `.scroll` case.
            let d = snap.reverseRingDirection ? -delta : delta
            postScrollWheelEvent(delta: Self.naturalScrollingEnabled ? d : -d, at: cursorPos)
        }
    }
}
