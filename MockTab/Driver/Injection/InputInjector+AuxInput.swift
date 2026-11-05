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

    func updateAuxButton(_ control: AuxButtonState.Control, down: Bool,
                         binding: ButtonBinding, mechanicalPulse: Bool = false,
                         at location: CGPoint, snapshot: InjectionSnapshot,
                         settings: TabletSettings?) {
        let actions = auxButtons.update(control, down: down, binding: binding,
                                        mechanicalPulse: mechanicalPulse)
        for action in actions {
            fireButtonAction(action.binding, down: action.down, at: location,
                             snapshot: snapshot, settings: settings, isAux: true)
        }
    }

    func releaseAuxButtons(at location: CGPoint, snapshot: InjectionSnapshot) {
        for action in auxButtons.releaseAll() {
            fireButtonAction(action.binding, down: false, at: location,
                             snapshot: snapshot, isAux: true)
        }
        hardwareRingButtonDown = false
    }

    /// Ring and strip steps are taps, not holds. Pairing down and up keeps a
    /// binding's modifiers from leaking across steps.
    func fireKeyTap(_ binding: ButtonBinding,
                            at loc: CGPoint,
                            snapshot: InjectionSnapshot,
                            settings: TabletSettings?) {
        fireButtonAction(binding, down: true, at: loc, snapshot: snapshot, settings: settings)
        fireButtonAction(binding, down: false, at: loc, snapshot: snapshot, settings: settings)
    }

    func injectAux(pad: PadState, settings: TabletSettings?) {
        ThreadContract.expectPenThread()
        rearmWatchdog()
        guard let snap = injectionSnapshot else { return }
        let bindings = snap.expressKeyBindings
        let cursorPos = currentCursorPosition()

        // Positions as the tracking state below holds them: 0x7F (ring) and
        // 0xFF (strip) for no contact.
        let ring1 = pad.rings.first
        let ring2 = pad.rings.dropFirst().first
        let touchRingActive = ring1?.position != nil
        let touchRing2Active = ring2?.position != nil
        let touchStrip1Active = pad.strips.first?.position != nil
        let touchStrip2Active = pad.strips.dropFirst().first?.position != nil
        // Strips with modes of their own open zoom and rotate gestures as
        // rings do.
        let rotary1Touched = touchRingActive || (stripsHaveOwnModes && touchStrip1Active)
        let rotary2Touched = touchRing2Active || (stripsHaveOwnModes && touchStrip2Active)

        // ── Express keys ───────────────────────────────────────────────────────
        for i in 0..<16 {
            let down = pad.button(i)
            updateAuxButton(.button(i), down: down, binding: bindings[i],
                            mechanicalPulse: pad.pressedThisReport.contains(i),
                            at: cursorPos, snapshot: snap, settings: settings)
        }

        // ── Bezel buttons (e.g. DTK-2400 OSD keys) ─────────────────────────────
        // `buttons[16...]`, with their own bindings: some devices use all 16
        // ExpressKey slots.
        let bezelBindings = snap.bezelButtonBindings
        for i in bezelBindings.indices {
            let auxIndex = 16 + i
            let down = pad.button(auxIndex)
            updateAuxButton(.button(auxIndex), down: down, binding: bezelBindings[i],
                            at: cursorPos, snapshot: snap, settings: settings)
        }

        // ── Firmware-owned ring mode (ExpressKey Remote) ───────────────────────
        // The remote's center button switches its own mode LEDs, so the
        // active slot follows the reported mode and the button fires nothing:
        // a host-side cycle on the same press would drift out of step.
        hardwareRingButtonDown = pad.hardwareMode != nil && (ring1?.buttonDown ?? false)
        if let mode = pad.hardwareMode {
            if mode != lastHardwareRingMode {
                lastHardwareRingMode = mode
                closeRingGestureEnvelopes()
                if let s = settings {
                    Task { @MainActor in
                        s.setActiveSlotIndex(s.rotary(.first).clampedSlotTarget(mode), for: .first)
                    }
                }
            }
        }

        // ── Touch ring center button ───────────────────────────────────────────
        let ringButtonDown = ring1?.buttonDown ?? false
        if pad.hardwareMode == nil {
            updateAuxButton(.ring, down: ringButtonDown, binding: snap.touchRingButtonBinding,
                            at: cursorPos, snapshot: snap, settings: settings)
        }

        // ── Second dial's toggle key (PTK-670/870) ────────────────────────────
        let ring2ButtonDown = ring2?.buttonDown ?? false
        updateAuxButton(.ring2, down: ring2ButtonDown, binding: snap.touchRingButtonBinding2,
                        at: cursorPos, snapshot: snap, settings: settings)

        // ── Touch ring ─────────────────────────────────────────────────────────
        // 72 steps (0–71); 0x7F means no contact. Deltas wrap at 36.
        let activeSlot: ControlSlot? = snap.rotary(.first).activeSlot

        // Zoom/rotate gesture on a touch ring: begins on contact, before this
        // report's delta, and ends on lift. Dials use an idle timer instead.
        // Keyed on contact alone; see `ring1GestureOpen`.
        if !hasMechanicalDial, let slot = activeSlot, slot.action == .zoom || slot.action == .rotate {
            let kind: RingGestureKind = slot.action == .zoom ? .zoom : .rotate
            if rotary1Touched, !ring1GestureOpen {
                ring1GestureOpen = true
                ring1GestureKind = kind
                postRingGesture(delta: 0, phase: .began, kind: kind)
            } else if !rotary1Touched, ring1GestureOpen {
                ring1GestureOpen = false
                postRingGesture(delta: 0, phase: .ended, kind: ring1GestureKind)
            }
        } else if ring1GestureOpen {
            // The mode changed mid-gesture; end it.
            ring1GestureOpen = false
            postRingGesture(delta: 0, phase: .ended, kind: ring1GestureKind)
        }

        let ringPos = ring1?.position.map { UInt8($0) } ?? 0x7F
        let now = ProcessInfo.processInfo.systemUptime
        // A slow finger can read as lifted mid-turn and land a few steps on.
        // Treat a quick, nearby re-touch as the same touch so that distance
        // isn't dropped.
        var fromPos = lastRingPos
        if touchRingActive, lastRingPos == 0x7F, ringLiftPos != 0x7F,
           now - ringLiftTime < Self.ringDropoutBridge {
            var gap = Int(ringPos) - Int(ringLiftPos)
            if gap > 36 { gap -= 72 }
            if gap < -36 { gap += 72 }
            if abs(gap) < 10 { fromPos = ringLiftPos }
        }
        if !touchRingActive, lastRingPos != 0x7F {
            ringLiftPos = lastRingPos
            ringLiftTime = now
        } else if touchRingActive {
            ringLiftPos = 0x7F
        }
        var ringHeld = false
        if touchRingActive, fromPos != 0x7F {
            var delta = Int(ringPos) - Int(fromPos)
            if delta > 36 { delta -= 72 }
            if delta < -36 { delta += 72 }
            // Normalize to "increasing = up"; see `ringDeltaIsInverted`.
            if ringDeltaIsInverted { delta = -delta }
            ringHeld = !ringSteps.accepts(delta)
            if !ringHeld, delta != 0, let slot = activeSlot {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &ringAccum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            }
        }
        if !touchRingActive {
            ringAccum = 0
            ringSteps.reset()
        }
        if !ringHeld { lastRingPos = touchRingActive ? ringPos : 0x7F }

        // ── Touch ring 2 (Cintiq 24HD right side), with its own modes ─────
        let ring2Slot = snap.rotary(.second).activeSlot
        if !hasMechanicalDial, let slot = ring2Slot, slot.action == .zoom || slot.action == .rotate {
            let kind: RingGestureKind = slot.action == .zoom ? .zoom : .rotate
            if rotary2Touched, !ring2GestureOpen {
                ring2GestureOpen = true
                ring2GestureKind = kind
                postRingGesture(delta: 0, phase: .began, kind: kind)
            } else if !rotary2Touched, ring2GestureOpen {
                ring2GestureOpen = false
                postRingGesture(delta: 0, phase: .ended, kind: ring2GestureKind)
            }
        } else if ring2GestureOpen {
            ring2GestureOpen = false
            postRingGesture(delta: 0, phase: .ended, kind: ring2GestureKind)
        }

        let ring2Pos = ring2?.position.map { UInt8($0) } ?? 0x7F
        var ring2Held = false
        if touchRing2Active, lastRing2Pos != 0x7F {
            var delta = Int(ring2Pos) - Int(lastRing2Pos)
            if delta > 36 { delta -= 72 }
            if delta < -36 { delta += 72 }
            if ringDeltaIsInverted { delta = -delta }
            ring2Held = !ring2Steps.accepts(delta)
            if !ring2Held, delta != 0, let slot = ring2Slot {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &ring2Accum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            }
        }
        if !touchRing2Active {
            ring2Accum = 0
            ring2Steps.reset()
        }
        if !ring2Held { lastRing2Pos = touchRing2Active ? ring2Pos : 0x7F }

        // ── Touch strips, no wrap: each is its own rotary. ─────────────────

        // Strip 1 (left).
        let s1pos = pad.strips.first?.position.map { UInt8($0) } ?? 0xFF
        if touchStrip1Active, lastStrip1Pos != 0xFF {
            let delta = Int(s1pos) - Int(lastStrip1Pos)
            if delta != 0, let slot = activeSlot {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &strip1Accum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            }
        }
        if !touchStrip1Active { strip1Accum = 0 }
        lastStrip1Pos = touchStrip1Active ? s1pos : 0xFF

        // Strip 2 (right).
        let s2pos = pad.strips.dropFirst().first?.position.map { UInt8($0) } ?? 0xFF
        if touchStrip2Active, lastStrip2Pos != 0xFF {
            let delta = Int(s2pos) - Int(lastStrip2Pos)
            if delta != 0, let slot = stripsHaveOwnModes ? ring2Slot : activeSlot {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &strip2Accum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            }
        }
        if !touchStrip2Active { strip2Accum = 0 }
        lastStrip2Pos = touchStrip2Active ? s2pos : 0xFF
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
        ThreadContract.expectPenThread()
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

extension PadState {
    /// Button `index`, or released past the end.
    func button(_ index: Int) -> Bool {
        buttons.indices.contains(index) && buttons[index]
    }
}
