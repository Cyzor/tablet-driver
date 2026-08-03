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
            if point.inProximity {
                rawPoint = displayMapper.resolveRelativePoint(
                    point, snapshot: snap, currentCursorPosition: currentCursorPosition(),
                    deviceProductID: deviceProductID)
            } else {
                // Don't let an out-of-proximity report (a Xencelabs blip mid-debounce,
                // or any vendor's genuine exit) touch the relative anchor — its position
                // data is exactly the kind of near-edge-of-range reading likely to be
                // noisy or clamped, and poisoning lastRelativeNorm with it corrupts the
                // next real report's delta into a spurious jump. The cursor is already
                // sitting wherever the last real move put it; reuse that.
                rawPoint = currentCursorPosition()
            }
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
        let rawPressure = InputInjector.curvedPressure(
            point.normalizedPressure, lut: tool.pressureLUT)
        // Mouse tools have no tip pressure — button1 is the primary click trigger.
        // For KC-100 over USB, the left button arrives via the separate 0x01 mouse interface
        // and injectMouseButtons() has already fired leftMouseDown/Up.  Keep tipDown false
        // so inject() doesn't re-fire the click; usbMouseLeftHeld drives drag vs hover below.
        let tipDown =
            activeToolIsMouse
            ? (usbMouseLeftHeld ? false : point.penButton1)
            : rawPressure > InputInjector.tipPressureThreshold

        // ── Pressure smoothing (contact only) ──────────────────────────────────
        // Damps sensor noise near the low-pressure/activation-threshold band
        // (visible as splotchy line-width variation on slow, light strokes).
        // Uses raw pressure for tipDown detection above so contact latency is
        // unaffected; only the transmitted line-width value is smoothed, and
        // a stroke's first sample always adopts the raw value verbatim.
        let pressure: Double
        if tipDown {
            pressure = pressureSmoother.applySmoothing(
                rawPressure: rawPressure, strokeStarting: !lastTipDown)
        } else {
            pressure = rawPressure
            pressureSmoother.reset()
        }

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
                    // A held button's own up-debounce (handleXencelabsBarrelButton)
                    // runs on its own short timer; a hover-blip up-edge just before
                    // crossing fully out of range could have armed it, and it would
                    // otherwise fire mid-wait and release the button behind this
                    // longer deferral's back. Once full proximity loss is the thing
                    // being waited on, it alone decides — cancel the pending release.
                    button1UpDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
                    button1UpDebounceTimer = nil
                    button2UpDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
                    button2UpDebounceTimer = nil
                    button3UpDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
                    button3UpDebounceTimer = nil
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
                smoother.smoothingStrength = tool.smoothingStrength
                pressureSmoother.smoothingStrength = tool.pressureSmoothingStrength
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

        // ── Scroll Drag: convert this frame's motion to a scroll delta ──────
        // Runs before the movement/delta-gate path below, which consults
        // panScroll.isActive to post scrolls in place of cursor motion. dt
        // feeds the tracker's release-velocity estimate and its anchor
        // damping; deltas themselves are displacement, not rate. The
        // damping is calibrated in real seconds, so this must stay a true
        // inter-report delta. The smoother keeps tracking normally while
        // panned, so cursor re-entry on disengage doesn't jump.
        let panNow = CFAbsoluteTimeGetCurrent()
        let panDt = lastPanScrollFrameTime > 0 ? panNow - lastPanScrollFrameTime : 0
        lastPanScrollFrameTime = panNow
        if panScroll.isActive {
            postPanScroll(panScroll.process(screen: screenPoint, dt: panDt))
        }
        // Pose is per-report constant; computed once here and passed to every
        // post call below instead of each recomputing it.
        let pose = resolveEffectivePose(point: point, snapshot: snap)
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
                    at: screenPoint, pressure: pressure, point: point, pose: pose,
                    snapshot: snap)
            }
            if tipDown {
                // Cancel any pending deferred mouseUp — tip is back down.
                cancelPendingMouseUp()
                didEmitDragSinceDown = false
                if panScroll.isActive {
                    // Scroll Drag is holding the pointer as a pan surface:
                    // the tip contact is a grab, not a click. Swallow the
                    // mouseDown so a touch doesn't start a selection or fire
                    // the tip binding; the matching mouseUp below is
                    // swallowed symmetrically (lastTipDown still tracks the
                    // physical tip).
                } else {
                    let tipAction = activeToolIsEraser ? tool.eraserBinding : tool.tipBinding
                    activeButton = tipAction.mouseButton ?? .left
                    let (clickPt, count) = resolveClick(screenPoint, snapshot: snap)
                    activeClickCount = count
                    tipDownOrigin = clickPt
                    postMouseDown(
                        button: activeButton, at: clickPt,
                        pressure: pressure, clickCount: count,
                        point: point,
                        snapshot: snap)
                }
            } else {
                if panScroll.isActive {
                    // Symmetric to the swallowed mouseDown above: no click
                    // ever fired, so no mouseUp either. The pen lift is just
                    // the end of a grab.
                } else {
                let btn = activeButton
                let count = activeClickCount
                let pt = point

                if activeAppProfile == .generic
                    && snap.tipUpAssistDelay > 0
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
                        CFAbsoluteTimeGetCurrent() + snap.tipUpAssistDelay / 1000.0,
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
            }
            lastPostedPoint = screenPoint
            lastPostedPressure = pressure
            hasPostedPoint = true

        } else if panScroll.isActive {
            // ── Scroll Drag: ungated movement ──────────────────────────────
            // Scroll motion is independent of the cursor delta gate (which is
            // tuned to suppress stationary-pen duplicates, not to meter a
            // gesture). The tip's click was swallowed on the way down, so the
            // pen reads as a pure pan surface here — no drag, no hover move,
            // just position bookkeeping for the next frame's delta and the
            // velocity window.
            if hasPostedPoint {
                let delta = hypot(
                    screenPoint.x - lastPostedPoint.x,
                    screenPoint.y - lastPostedPoint.y)
                smoother.recordMoveDelta(delta)
            }
            lastPostedPoint = screenPoint
            lastPostedPressure = pressure
            hasPostedPoint = true

        } else {
            // ── Continuous movement: delta gate ────────────────────────────────
            // Pressure-only changes count as movement so drawing apps receive
            // pressure updates from a stationary pen (airbrush buildup) — but
            // not for Finder, where the resulting drag events cancel desktop
            // rename-edit (see AppInputProfile.finderPlainMouse).
            let moved =
                !hasPostedPoint
                || (screenPoint.x - lastPostedPoint.x).magnitude > Self.positionEpsilon
                || (screenPoint.y - lastPostedPoint.y).magnitude > Self.positionEpsilon
                || (tipDown && activeAppProfile != .finderPlainMouse
                    && (pressure - lastPostedPressure).magnitude > Self.pressureEpsilon)

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
                        at: screenPoint, pressure: pressure, point: point, pose: pose,
                        snapshot: snap)
                }
                // Drag threshold: while the tip is down and no drag has been
                // emitted yet, hold off posting leftMouseDragged until the pen
                // has traveled snap.dragThreshold points from where it went
                // down. Absorbs tremor/pressure jitter that would otherwise
                // turn a tap into a spurious drag (e.g. canceling a Finder
                // rename-edit or starting an unwanted text selection).
                // forceFirstDrag always bypasses this — Pages needs that first
                // drag event regardless.
                let withinDragThreshold =
                    tipDown && !didEmitDragSinceDown && !forceFirstDrag
                    && snap.dragThreshold > 0
                    && hypot(screenPoint.x - tipDownOrigin.x, screenPoint.y - tipDownOrigin.y)
                        < snap.dragThreshold

                if dragging {
                    if !withinDragThreshold {
                        postMouseDrag(
                            button: activeButton, at: screenPoint, pressure: pressure, point: point,
                            pose: pose, snapshot: snap)
                        didEmitDragSinceDown = true
                    }
                } else if panScroll.isActive {
                    // Scroll Drag held: pen motion became scroll deltas above;
                    // the cursor stays put. Skip the drag/move posting entirely.
                } else if let dragBtn = hoverDragButton {
                    // Barrel button held while hovering — send otherMouseDragged /
                    // rightMouseDragged so apps like SketchUp receive a proper drag stream.
                    postMouseDrag(
                        button: dragBtn, at: screenPoint, pressure: 0, point: point,
                        pose: pose, snapshot: snap)
                } else {
                    postMouseMoved(
                        at: screenPoint, point: point, pose: pose,
                        snapshot: snap)
                }
                lastPostedPoint = screenPoint
                lastPostedPressure = pressure
                hasPostedPoint = true
            }
        }
        lastTipDown = tipDown

        // ── Pen button transitions (always immediate) ───────────────────────────
        let btn1 = tool.penButton1Binding
        let btn2 = tool.penButton2Binding
        let btn3 = tool.penButton3Binding

        if deviceVendorID == 0x28BD {
            if !activeToolIsMouse {
                handleXencelabsBarrelButton(
                    slot: .one, down: point.penButton1, binding: btn1,
                    at: screenPoint, snap: snap, settings: settings)
                // barrelLowBit (3-button pen's dedicated lower button, see
                // XencelabsDecoder) arrives in the same digitizer stream as
                // button1/2 but previously wasn't dispatched here — it only
                // reached TabletManager's live UI display, never
                // fireButtonAction, so a binding assigned to it had no
                // effect anywhere else on the system. Same debounce as the
                // others since it rides the same short button-sensing range.
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
        // Scroll Drag: a confirmed exit does NOT close the gesture. The
        // gesture is owned by its button (puck or barrel), not by proximity —
        // the user's model is "while the button is held, pen contact pans."
        // The pen leaving range mid-hold (a Xencelabs 0xC0 blip, or a genuine
        // lift-and-return) must not end the pan or the next tap would read as
        // a click/selection. `suspend()` drops the anchor so re-entry doesn't
        // jump; the gesture closes on the button's release edge (or the
        // safety-net timeout below if the release is genuinely lost).
        if panScroll.isActive {
            panScroll.suspend()
            schedulePanScrollSafetyNet(snap: snap)
        }
        lastAuxButtons = [Bool](repeating: false, count: 19)
        lastRingButtonDown = false
        hasPostedPoint = false
        displayMapper.clearRelativeAnchor()
        lastPostedPressure = -1.0
        smoother.resetOnProximityExit()
        pressureSmoother.reset()

        // Record the moment the pen leaves proximity so finger-touch can
        // apply a short grace window (touchArbitrationGrace) before
        // accepting contacts again — prevents the palm rejection failure
        // pattern where lifting the pen drops a stray finger on the
        // tablet and the touch path races the pen-up.
        if lastProximity {
            penProximityExitTime = CFAbsoluteTimeGetCurrent()
        }
        lastProximity = false

        // Release any barrel buttons still down at exit, finalizing any
        // pending up-debounce timer immediately — a full commit is happening
        // anyway, so there's no benefit to waiting the window out, and a
        // live timer must not fire after cleanup.
        let exitScreenPoint = smoother.smoothedPoint
        button1UpDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
        button1UpDebounceTimer = nil
        if lastButton1Down {
            lastButton1Down = false
            if !activeToolIsMouse {
                fireButtonAction(
                    snap.activeTool.penButton1Binding, down: false, at: exitScreenPoint,
                    snapshot: snap, settings: nil)
            }
        }
        button2UpDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
        button2UpDebounceTimer = nil
        if lastButton2Down {
            lastButton2Down = false
            fireButtonAction(
                snap.activeTool.penButton2Binding, down: false, at: exitScreenPoint,
                snapshot: snap, settings: nil)
        }
        button3UpDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
        button3UpDebounceTimer = nil
        if lastButton3Down {
            lastButton3Down = false
            if !activeToolIsMouse {
                fireButtonAction(
                    snap.activeTool.penButton3Binding, down: false, at: exitScreenPoint,
                    snapshot: snap, settings: nil)
            }
        }
        // NOTE: no pan-scroll disengage here. The gesture survives proximity
        // exit (suspended, not closed — see the top of this function); it ends
        // on the button's release edge or the safety-net timer, whichever
        // comes first.
    }

    /// Force-close an active pan gesture whose owning button's release was
    /// genuinely lost (pen set down out of range; no release report). Fires on
    /// HIDThread. Resets both the gesture and the shared routing pointer.
    private func panScrollSafetyNetFired() {
        panScrollSafetyNetTimer = nil
        postPanScroll(panScroll.disengage())
        if SharedPanScrollState.shared.driver === self {
            SharedPanScrollState.shared.driver = nil
        }
    }

    /// Schedule the lost-release backstop when proximity exits with a pan
    /// still open. Rearmed on each call (each confirmed exit restarts the
    /// window).
    func schedulePanScrollSafetyNet(snap: InjectionSnapshot) {
        panScrollSafetyNetTimer.map { CFRunLoopTimerInvalidate($0) }
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + panScrollSafetyNetInterval,
            0, 0, 0
        ) { [weak self] _ in
            self?.panScrollSafetyNetFired()
        }
        CFRunLoopAddTimer(HIDThread.shared.runLoop, timer, .commonModes)
        panScrollSafetyNetTimer = timer
    }

    /// Cancel the backstop on the normal release path — a button edge arrived,
    /// so the gesture is closing cleanly and no force-close is needed.
    func cancelPanScrollSafetyNet() {
        panScrollSafetyNetTimer.map { CFRunLoopTimerInvalidate($0) }
        panScrollSafetyNetTimer = nil
    }

    /// Which barrel button a debounced-release timer handler is resolving —
    /// used instead of `inout` state (escaping closures can't capture `inout`
    /// parameters), so the handler branches on this to reach the right
    /// stored properties.
    private enum BarrelButtonSlot { case one, two, three }

    /// Xencelabs-only barrel-button dispatch: presses fire immediately;
    /// releases are held for `buttonUpDebounceInterval` (see its declaration)
    /// so a button re-asserting within that small window never produces a
    /// release/press pair. A flat window, no tilt or history heuristics.
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
        // Right-click / eraser bindings get the longer menu window so a
        // held contextual menu survives a pen lift (see
        // buttonUpDebounceMenuInterval). Everything else stays crisp.
        let window: TimeInterval
        switch binding.kind {
        case .rightClick, .eraser: window = buttonUpDebounceMenuInterval
        default: window = buttonUpDebounceInterval
        }
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + window,
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
