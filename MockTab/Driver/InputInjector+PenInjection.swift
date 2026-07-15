// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import os
import TabletKit

// The pen hot path — inject(), its proximity-exit cleanup, and the
// Xencelabs barrel-button debounce — split out of InputInjector.swift. All
// per-report tracking state it reads and writes lives on the main class body
// (Swift class extensions can't hold stored properties) and stays
// HIDThread-confined exactly as documented there.
extension InputInjector {

    // MARK: - Pen injection

    func inject(point: TabletPoint, settings: TabletSettings?) {
        rearmWatchdog()
        // The snapshot is seeded synchronously in DeviceContext.observeInjectionSnapshot()
        // before any HID report can arrive, so this guard is defense-in-depth.
        guard let snap = injectionSnapshot else { return }
        let tool = snap.activeTool
        var point = point
        if snap.invertRotation && point.rotation != 0.0 {
            point.rotation = (360.0 - point.rotation).truncatingRemainder(dividingBy: 360.0)
        }
        let rawPoint: CGPoint
        if snap.relativeCursorMovement {
            rawPoint = displayMapper.resolveRelativePoint(
                point, snapshot: snap, currentCursorPosition: currentCursorPosition())
        } else {
            guard let absPoint = displayMapper.mapToScreen(
                point, snapshot: snap, deviceProductID: deviceProductID)
            else {
                // Pen outside active area — deadzone, no events
                displayMapper.clearRelativeAnchor()
                return
            }
            rawPoint = Self.pinNearScreenEdges(
                absPoint, in: displayMapper.displayBounds(for: snap))
        }
        let lutIdx = Swift.min(Swift.max(Int((point.normalizedPressure * 255.0).rounded()), 0), 255)
        let pressure = tool.pressureLUT[lutIdx]
        // Mouse tools have no tip pressure — button1 is the primary click trigger.
        // For KC-100 over USB, the left button arrives via the separate 0x01 mouse interface
        // and injectMouseButtons() has already fired leftMouseDown/Up.  Keep tipDown false
        // so inject() doesn't re-fire the click; usbMouseLeftHeld drives drag vs hover below.
        let tipDown =
            activeToolIsMouse
            ? (usbMouseLeftHeld ? false : point.penButton1)
            : pressure > 0.004

        // ── Xencelabs proximity-dropout debounce ────────────────────────────────
        // See proximityExitDebounceTimer's declaration for why. A lone
        // out-of-range report defers the exit cleanup instead of running it
        // immediately; a real report reappearing before the timer fires
        // cancels the deferral and this frame is processed as a normal
        // in-proximity sample (lastProximity never flipped, so nothing else
        // downstream notices the blip).
        if deviceVendorID == 0x28BD {
            if point.inProximity {
                if let timer = proximityExitDebounceTimer {
                    CFRunLoopTimerInvalidate(timer)
                    proximityExitDebounceTimer = nil
                }
            } else if lastProximity && proximityExitDebounceTimer == nil {
                // A held tip/barrel/mouse button gets the long safety-net delay
                // instead of the short blip debounce — see the property's doc.
                let anyButtonHeld =
                    lastTipDown || lastButton1Down || lastButton2Down || lastButton3Down
                    || lastMiddleDown || usbMouseLeftHeld || lastUSBMouseMask != 0
                let delay = anyButtonHeld
                    ? proximityExitHeldButtonSafetyInterval : proximityExitDebounceInterval
                if anyButtonHeld {
                    // The button-level up-debounce (handleXencelabsBarrelButton) runs on
                    // its own short timer and would otherwise fire a release out from
                    // under this longer wait — e.g. a transient hover-blip up-edge right
                    // before crossing fully out of range armed its 80ms timer, which would
                    // still fire mid-wait and release the button behind our back. Once
                    // proximity itself is the thing being waited on, it alone decides.
                    if let t = button1UpDebounceTimer {
                        CFRunLoopTimerInvalidate(t)
                        button1UpDebounceTimer = nil
                    }
                    if let t = button2UpDebounceTimer {
                        CFRunLoopTimerInvalidate(t)
                        button2UpDebounceTimer = nil
                    }
                    if let t = button3UpDebounceTimer {
                        CFRunLoopTimerInvalidate(t)
                        button3UpDebounceTimer = nil
                    }
                }
                let timer = CFRunLoopTimerCreateWithHandler(
                    kCFAllocatorDefault,
                    CFAbsoluteTimeGetCurrent() + delay,
                    0, 0, 0
                ) { [weak self] _ in
                    guard let self else { return }
                    self.proximityExitDebounceTimer = nil
                    self.commitProximityExit(snap: snap)
                }
                CFRunLoopAddTimer(HIDThread.shared.runLoop, timer, .commonModes)
                proximityExitDebounceTimer = timer
                return
            }
        }

        let enteringProximity = point.inProximity && !lastProximity
        let eraserFlipped = point.inProximity && lastProximity && (point.eraser != lastEraserMode)

        // ── Proximity transitions (always immediate) ───────────────────────────
        if point.inProximity != lastProximity {
            // Suppress tabletProximity for plain-mouse profiles: receiving this event
            // triggers NSTextView's tablet-tracking code path, causing it to route
            // subsequent mouse events through pressure-selection logic that breaks
            // normal text selection (drag doesn't extend, only Shift/Command drag works).
            if activeAppProfile == .generic {
                postProximityEvent(
                    entering: point.inProximity, at: rawPoint,
                    eraser: point.eraser)
            }
            if point.inProximity {
                activeToolIsEraser = point.eraser
                lastEraserMode = point.eraser
                let s = tool.smoothingStrength
                smoother.smoothingAlpha = s > 0 ? 1.0 - s * 0.85 : 1.0
                lastProximity = true
            } else {
                commitProximityExit(snap: snap)
            }
        }

        // ── Eraser/tip flip (while in proximity) ───────────────────────────────
        if eraserFlipped {
            // Pen was flipped between tip and eraser while in proximity.
            // Post synthetic proximity exit/enter so apps re-register the tool identity.
            // This ensures distinct pointerType (1=pen, 3=eraser) and serial registration.
            postProximityEvent(entering: false, at: rawPoint, eraser: !point.eraser)
            activeToolIsEraser = point.eraser
            lastEraserMode = point.eraser
            postProximityEvent(entering: true, at: rawPoint, eraser: point.eraser)
        }

        guard point.inProximity else { return }

        // ── Position smoothing (every report) ─────────────────────────────────
        let screenPoint = smoother.applySmoothing(
            rawPoint: rawPoint, enteringProximity: enteringProximity)
        shimLastPoint = point
        shimLastScreen = screenPoint
        shimLastPressure = pressure

        // ── Jitter tracking (hover only, every report) ─────────────────────────
        if !tipDown {
            smoother.observeHoverRaw(rawPoint)
        } else {
            smoother.endHover()
        }

        // ── Tip press transitions (always immediate) ───────────────────────────
        if tipDown != lastTipDown {
            if !activeToolIsMouse && activeAppNeedsTabletPointerEvents {
                postTabletPointerEvent(
                    at: screenPoint, pressure: pressure, point: point, snapshot: snap)
            }
            if tipDown {
                // Cancel any pending deferred mouseUp — tip is back down.
                cancelPendingMouseUp()
                didEmitDragSinceDown = false
                let tipAction = activeToolIsEraser ? tool.eraserBinding : tool.tipBinding
                activeButton = tipAction.mouseButton ?? .left
                let (clickPt, count) = resolveClick(screenPoint, snapshot: snap)
                activeClickCount = count
                postMouseDown(
                    button: activeButton, at: clickPt,
                    pressure: pressure, clickCount: count,
                    point: point,
                    snapshot: snap)
            } else {
                let btn = activeButton
                let count = activeClickCount
                let pt = point

                if activeAppProfile == .generic
                    && snap.tipUpAssist
                    && smoother.recentVelocity > Self.tipUpAssistVelocityThreshold {
                    // Defer the mouseUp briefly so fast strokes aren't cut short.
                    // The deferred mouseUp captures `snap` so it has all the values it
                    // needs; the live snapshot may have rolled over by the time it fires.
                    let capturedSnap = snap
                    // One-shot timer on HIDThread's run loop: the delay stays
                    // honest under main-thread congestion, and the handler runs
                    // on the same thread that owns all per-report state — no hop,
                    // no cancellation race (invalidation on this thread guarantees
                    // the handler never fires afterwards).
                    let timer = CFRunLoopTimerCreateWithHandler(
                        kCFAllocatorDefault,
                        CFAbsoluteTimeGetCurrent() + Self.tipUpAssistDelay,
                        0,  // interval — one-shot
                        0, 0
                    ) { [weak self] _ in
                        guard let self, self.pendingMouseUp != nil else { return }
                        self.pendingMouseUp = nil
                        // Fire at lastPostedPoint, not at the tip-lift position.
                        // By the time this fires (~80ms after physical tip-lift),
                        // mouseMoved events have advanced lastPostedPoint to wherever
                        // the pen currently is.  Firing at the original lift-off would
                        // warp the cursor back, then snap forward on the next inject(),
                        // creating a visible cursor zap and spurious drag.  For drawing
                        // strokes the pen travels only a few pixels in 80ms, so
                        // stroke-end fidelity is effectively unchanged.
                        self.postMouseUp(
                            button: btn, at: self.lastPostedPoint, clickCount: count,
                            point: pt, snapshot: capturedSnap)
                    }
                    pendingMouseUp = timer
                    if let timer {
                        CFRunLoopAddTimer(HIDThread.shared.runLoop, timer, .commonModes)
                    }
                } else {
                    postMouseUp(
                        button: activeButton, at: screenPoint,
                        clickCount: activeClickCount, point: point,
                        snapshot: snap)
                }
            }
            lastPostedPoint = screenPoint
            lastPostedPressure = pressure
            hasPostedPoint = true

        } else {
            // ── Continuous movement: delta gate ────────────────────────────────
            let moved =
                !hasPostedPoint
                || (screenPoint.x - lastPostedPoint.x).magnitude > Self.positionEpsilon
                || (screenPoint.y - lastPostedPoint.y).magnitude > Self.positionEpsilon
                || (tipDown && (pressure - lastPostedPressure).magnitude > Self.pressureEpsilon)

            // USB mouse left button held (KC-100): injectMouseButtons() already sent
            // leftMouseDown; use leftMouseDragged so apps receive proper drag events.
            let dragging = tipDown || (activeToolIsMouse && usbMouseLeftHeld)

            // Pages text engine requires a leftMouseDragged immediately after
            // leftMouseDown to start selection; tiny sub-epsilon pen movement on
            // the first contact frame can cause the gate to suppress that first drag
            // event, leaving Pages in a state where selection never begins.
            let forceFirstDrag = dragging && activeAppProfile == .pagesPlainMouse && !didEmitDragSinceDown

            if moved || forceFirstDrag {
                // Track velocity for tip-up assist.
                if hasPostedPoint {
                    let delta = hypot(
                        screenPoint.x - lastPostedPoint.x,
                        screenPoint.y - lastPostedPoint.y)
                    smoother.recordMoveDelta(delta)
                }
                if !activeToolIsMouse && activeAppNeedsTabletPointerEvents {
                    postTabletPointerEvent(
                        at: screenPoint, pressure: pressure, point: point, snapshot: snap)
                }
                if dragging {
                    postMouseDrag(
                        button: activeButton, at: screenPoint, pressure: pressure, point: point,
                        snapshot: snap)
                    didEmitDragSinceDown = true
                } else if let dragBtn = hoverDragButton {
                    // Barrel button held while hovering — send otherMouseDragged /
                    // rightMouseDragged so apps like SketchUp receive a proper drag stream.
                    postMouseDrag(
                        button: dragBtn, at: screenPoint, pressure: 0, point: point,
                        snapshot: snap)
                } else {
                    postMouseMoved(
                        at: screenPoint, point: point,
                        snapshot: snap)
                }
                lastPostedPoint = screenPoint
                lastPostedPressure = pressure
                hasPostedPoint = true
            }
        }
        lastTipDown = tipDown

        // ── Pen button transitions (always immediate, except Xencelabs's
        //    deferred-release debounce — see button1/2UpDebounceTimer) ─────────
        let btn1 = tool.penButton1Binding
        let btn2 = tool.penButton2Binding
        let btn3 = tool.penButton3Binding

        if deviceVendorID == 0x28BD {
            if !activeToolIsMouse {
                handleXencelabsBarrelButton(
                    slot: .one, down: point.penButton1, binding: btn1,
                    at: screenPoint, snap: snap, settings: settings)
                // The 3-button pen's dedicated lower button (barrelLowBit in
                // XencelabsDecoder) arrives in the same digitizer stream as
                // button1/2 but was never dispatched here — it only reached
                // TabletManager's live UI display, never fireButtonAction, so
                // a binding assigned to it had no effect anywhere else on the
                // system. Shares the same debounce treatment as button1/2
                // since it rides the same short button-sensing range.
                handleXencelabsBarrelButton(
                    slot: .three, down: point.penButton3, binding: btn3,
                    at: screenPoint, snap: snap, settings: settings)
            } else {
                lastButton1Down = point.penButton1
            }
            handleXencelabsBarrelButton(
                slot: .two, down: point.penButton2, binding: btn2,
                at: screenPoint, snap: snap, settings: settings)
        } else {
            if point.penButton1 != lastButton1Down {
                // Update tracking state first so the quiescent check inside
                // fireButtonAction sees the current button state, not the pre-transition state.
                lastButton1Down = point.penButton1
                // For mouse tools button1 drives the primary click (tipDown above);
                // dispatching it again as a button action would double-fire.
                if !activeToolIsMouse {
                    fireButtonAction(btn1, down: point.penButton1, at: screenPoint,
                                     snapshot: snap, settings: settings)
                }
            }
            if point.penButton2 != lastButton2Down {
                lastButton2Down = point.penButton2
                fireButtonAction(btn2, down: point.penButton2, at: screenPoint,
                                 snapshot: snap, settings: settings)
            }
        }

        // ── Middle button (mouse tool only, always immediate) ──────────────────
        if point.mouseMiddleButton != lastMiddleDown {
            let type: CGEventType = point.mouseMiddleButton ? .otherMouseDown : .otherMouseUp
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: screenPoint, mouseButton: .center)
            {
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }
            lastMiddleDown = point.mouseMiddleButton
        }

        // ── Scroll wheel (mouse tool only, always immediate) ───────────────────
        if point.mouseWheelDelta != 0 {
            postScrollWheelEvent(delta: point.mouseWheelDelta, at: screenPoint)
        }
    }

    /// Runs the proximity-exit cleanup: releases the tip, any held USB/middle
    /// mouse buttons, and synthetic modifiers, then resets per-proximity
    /// state. Called immediately from `inject()` for every device, or from
    /// `proximityExitDebounceTimer`'s handler for Xencelabs once a real exit
    /// has been confirmed (see that property's declaration).
    private func commitProximityExit(snap: InjectionSnapshot) {
        activeToolIsEraser = false
        lastEraserMode = false
        let exitPoint = smoother.smoothedPoint
        if lastTipDown {
            postMouseUp(
                button: activeButton, at: exitPoint,
                clickCount: activeClickCount,
                snapshot: snap)
            lastTipDown = false
        }
        // Release any USB HID mouse buttons that were held when the tool left
        // the tablet (e.g. user yanked the KC-100 off the surface mid-drag).
        if lastUSBMouseMask != 0 {
            if usbMouseLeftHeld {
                postMouseUp(
                    button: .left, at: exitPoint,
                    clickCount: activeClickCount,
                    snapshot: snap)
                usbMouseLeftHeld = false
            }
            if (lastUSBMouseMask & 0x02) != 0 {
                postMouseUp(
                    button: .right, at: exitPoint, clickCount: 1,
                    snapshot: snap)
            }
            if (lastUSBMouseMask & 0x04) != 0 {
                if let e = CGEvent(
                    mouseEventSource: sessionSource, mouseType: .otherMouseUp,
                    mouseCursorPosition: exitPoint, mouseButton: .center)
                {
                    e.flags = currentEventFlags
                    finalizeAndPost(e)
                }
            }
            lastUSBMouseMask = 0
        }
        if lastMiddleDown {
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: .otherMouseUp,
                mouseCursorPosition: exitPoint, mouseButton: .center)
            {
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }
            lastMiddleDown = false
        }
        // Safety valve: release any modifier keys stranded by a missed decoder
        // release event (e.g. BT packet drop leaving lastBTPadKeys non-zero).
        // Per-transport fixes (Defect A/B) prevent accumulation; this ensures
        // proximity exit is always a clean slate regardless.
        releaseAllSyntheticModifiers()

        // Do NOT post proximity-exit flagsChanged events for physical modifiers.
        // flagsChanged events posted via cghidEventTap update the system keyboard
        // state (Keyboard Viewer, hidSystemState), so posting one with a modifier
        // bit SET because tapLastPhysicalFlags still reflects a held key causes the
        // Keyboard Viewer to show it as stuck.  The physical keyboard's own
        // flagsChanged events are the authoritative source for physical modifier
        // state; apps receive them independently of our event stream.
        // The race this sync tried to fix (our last move event arriving after the
        // physical key-up, leaving apps with stale modifier state) is now handled
        // by moveSafeEventFlags including tapLastPhysicalFlags, so the last move
        // event already carries the correct physical state.
        lastLoggedManagedFlags = 0  // reset for clean logging on next proximity entry

        // Reset aux state so the next injectAux fires fresh transitions.
        cancelPendingMouseUp()
        hoverDragButton = nil
        lastAuxButtons = [Bool](repeating: false, count: 19)
        lastRingButtonDown = false
        hasPostedPoint = false
        displayMapper.clearRelativeAnchor()
        lastPostedPressure = -1.0
        smoother.resetOnProximityExit()

        // Record the moment the pen leaves proximity so finger-touch can
        // apply a short grace window (touchArbitrationGrace) before
        // accepting contacts again — prevents the palm rejection failure
        // pattern where lifting the pen drops a stray finger on the
        // tablet and the touch path races the pen-up.
        if lastProximity {
            penProximityExitTime = CFAbsoluteTimeGetCurrent()
        }
        lastProximity = false

        // Finalize any barrel-button release still pending its debounce window
        // (see button1/2UpDebounceTimer) — a full commit is happening anyway,
        // so there's no more benefit to waiting the rest of the window out.
        let exitScreenPoint = smoother.smoothedPoint
        if let t = button1UpDebounceTimer {
            CFRunLoopTimerInvalidate(t)
            button1UpDebounceTimer = nil
            if lastButton1Down {
                lastButton1Down = false
                if !activeToolIsMouse {
                    fireButtonAction(
                        snap.activeTool.penButton1Binding, down: false, at: exitScreenPoint,
                        snapshot: snap, settings: nil)
                }
            }
        }
        if let t = button2UpDebounceTimer {
            CFRunLoopTimerInvalidate(t)
            button2UpDebounceTimer = nil
            if lastButton2Down {
                lastButton2Down = false
                fireButtonAction(
                    snap.activeTool.penButton2Binding, down: false, at: exitScreenPoint,
                    snapshot: snap, settings: nil)
            }
        }
        if let t = button3UpDebounceTimer {
            CFRunLoopTimerInvalidate(t)
            button3UpDebounceTimer = nil
            if lastButton3Down {
                lastButton3Down = false
                if !activeToolIsMouse {
                    fireButtonAction(
                        snap.activeTool.penButton3Binding, down: false, at: exitScreenPoint,
                        snapshot: snap, settings: nil)
                }
            }
        }
    }

    /// Which barrel button a debounced-release timer handler is resolving —
    /// used instead of `inout` state (escaping closures can't capture `inout`
    /// parameters), so the handler can read/write the right stored properties
    /// by branching on this instead of holding a reference to them directly.
    private enum BarrelButtonSlot { case one, two, three }

    /// Xencelabs-only barrel-button handling: presses fire immediately;
    /// releases are debounced (see `button1UpDebounceTimer`/
    /// `button2UpDebounceTimer`'s declaration) so a button re-asserting
    /// within `buttonUpDebounceInterval` never produces a release/press pair.
    private func handleXencelabsBarrelButton(
        slot: BarrelButtonSlot, down: Bool,
        binding: ButtonBinding, at location: CGPoint,
        snap: InjectionSnapshot, settings: TabletSettings?
    ) {
        let wasDown: Bool
        let pendingTimer: CFRunLoopTimer?
        switch slot {
        case .one: wasDown = lastButton1Down; pendingTimer = button1UpDebounceTimer
        case .two: wasDown = lastButton2Down; pendingTimer = button2UpDebounceTimer
        case .three: wasDown = lastButton3Down; pendingTimer = button3UpDebounceTimer
        }

        if down {
            // Reasserted (or still down) — cancel any pending release; if it
            // hadn't already committed, nothing downstream ever saw a release.
            if let t = pendingTimer {
                CFRunLoopTimerInvalidate(t)
                setBarrelButtonTimer(slot, nil)
            }
            if !wasDown {
                setBarrelButtonDown(slot, true)
                fireButtonAction(binding, down: true, at: location, snapshot: snap, settings: settings)
            }
            return
        }
        guard wasDown, pendingTimer == nil else { return }
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + buttonUpDebounceInterval,
            0, 0, 0
        ) { [weak self] _ in
            guard let self else { return }
            self.setBarrelButtonTimer(slot, nil)
            let stillDown: Bool
            switch slot {
            case .one: stillDown = self.lastButton1Down
            case .two: stillDown = self.lastButton2Down
            case .three: stillDown = self.lastButton3Down
            }
            guard stillDown else { return }
            self.setBarrelButtonDown(slot, false)
            self.fireButtonAction(binding, down: false, at: location, snapshot: snap, settings: settings)
        }
        CFRunLoopAddTimer(HIDThread.shared.runLoop, timer, .commonModes)
        setBarrelButtonTimer(slot, timer)
    }

    private func setBarrelButtonDown(_ slot: BarrelButtonSlot, _ down: Bool) {
        switch slot {
        case .one: lastButton1Down = down
        case .two: lastButton2Down = down
        case .three: lastButton3Down = down
        }
    }

    private func setBarrelButtonTimer(_ slot: BarrelButtonSlot, _ timer: CFRunLoopTimer?) {
        switch slot {
        case .one: button1UpDebounceTimer = timer
        case .two: button2UpDebounceTimer = timer
        case .three: button3UpDebounceTimer = timer
        }
    }
}
