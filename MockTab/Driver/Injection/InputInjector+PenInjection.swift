// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import os
import TabletKit

// The pen hot path: inject(), proximity-exit cleanup, and the Xencelabs
// barrel-button debounce. State lives on the main class body, HIDThread-confined.
extension InputInjector {

    // MARK: - Pen injection

    func inject(point: TabletPoint, settings: TabletSettings?) {
        let signpost = PipelineSignposts.begin("Inject")
        defer { PipelineSignposts.end("Inject", signpost) }
        rearmWatchdog()
        lastPenInjectCallAt = Date()
        TouchPipelineProbe.note { $0.framesPenDelivered += 1 }
        // Seeded before any report arrives; the guard is a backstop.
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
                // An out-of-range report's position is unreliable and would
                // corrupt the relative anchor into a jump. Keep the cursor put.
                rawPoint = currentCursorPosition()
            }
        } else if let absPoint = displayMapper.mapToScreen(
            point, snapshot: snap, deviceProductID: deviceProductID)
        {
            // Points past the active area clamp to its edge. `nil` only means
            // a degenerate area, not "pen out of range".
            rawPoint = displayMapper.pinNearEdges(absPoint, snapshot: snap)
        } else {
            displayMapper.clearRelativeAnchor()
            return
        }
        let rawPressure = InputInjector.curvedPressure(
            point.normalizedPressure, lut: tool.pressureLUT)
        // Mouse tools click with button1. Over USB the KC-100's left button
        // arrives separately via injectMouseButtons(), so don't fire it again.
        let rawTipDown =
            activeToolIsMouse
            ? (usbMouseLeftHeld ? false : point.penButton1)
            : rawPressure > InputInjector.tipPressureThreshold

        // ── Smoothing dt (real elapsed time since the previous pen frame) ──────
        let smoothingNow = CFAbsoluteTimeGetCurrent()
        let smoothingDt = lastSmoothingFrameTime > 0 ? smoothingNow - lastSmoothingFrameTime : 0
        lastSmoothingFrameTime = smoothingNow

        // ── Pressure smoothing (contact only) ──────────────────────────────────
        // Damps noise near the activation threshold (splotchy light strokes).
        // Contact detection above uses raw pressure, so latency is unchanged.
        let pressure: Double
        if rawTipDown {
            pressure = pressureSmoother.applySmoothing(
                rawPressure: rawPressure, strokeStarting: !lastTipDown, dt: smoothingDt)
        } else {
            pressure = rawPressure
            pressureSmoother.reset()
        }

        // ── Xencelabs proximity-dropout debounce ────────────────────────────────
        // A lone out-of-range report defers the exit; a report back in range
        // before the timer fires cancels it. See proximityExitDebounceTimer.
        if deviceVendorID == 0x28BD {
            if point.inProximity {
                if let timer = proximityExitDebounceTimer {
                    CFRunLoopTimerInvalidate(timer)
                    proximityExitDebounceTimer = nil
                }
            } else if lastProximity && proximityExitDebounceTimer == nil {
                // A held button gets the long safety-net delay instead.
                let anyButtonHeld =
                    lastTipDown || lastButton1Down || lastButton2Down || lastButton3Down
                    || lastMiddleDown || usbMouseLeftHeld || lastUSBMouseMask != 0
                let delay = anyButtonHeld
                    ? proximityExitHeldButtonSafetyInterval : proximityExitDebounceInterval
                if anyButtonHeld {
                    // Cancel any pending barrel-button release so it can't fire
                    // during this longer wait; the exit alone decides now.
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
            // Exit reports carry no tool, so a leaving eraser takes the
            // identity it entered with; otherwise apps saw the pen leave.
            postProximityEvent(
                entering: point.inProximity, at: rawPoint,
                eraser: point.inProximity ? point.eraser : activeToolIsEraser)
            if point.inProximity {
                TouchPipelineProbe.note { $0.penProximityEnters += 1 }
                activeToolIsEraser = point.eraser
                lastEraserMode = point.eraser
                smoother.smoothingStrength = tool.smoothingStrength
                pressureSmoother.smoothingStrength = tool.pressureSmoothingStrength
                lastProximity = true
                proximityConfirmStartTime = CFAbsoluteTimeGetCurrent()
            } else {
                commitProximityExit(snap: snap)
            }
        }

        // ── Touch-arbitration confirmation gate ────────────────────────────
        // See `touchPenConfirmedBusy`. Checked every report, so a hover that
        // outlasts the hold-off is confirmed then.
        if point.inProximity, !touchPenConfirmedBusy,
            rawTipDown || CFAbsoluteTimeGetCurrent() - proximityConfirmStartTime >= Self.touchBusyHoldOff
        {
            touchPenConfirmedBusy = true
            touchPenBusyConfirmedAt = CFAbsoluteTimeGetCurrent()
            touchPenBusyHadTipSinceConfirmed = rawTipDown
        }
        // Any tip contact marks the episode as real pen use; see `staleBusyTimeout`.
        if touchPenConfirmedBusy, rawTipDown {
            touchPenBusyHadTipSinceConfirmed = true
        }

        // ── Eraser/tip flip (while in proximity) ───────────────────────────────
        if eraserFlipped {
            // Re-announce proximity so apps pick up the new pointer type.
            postProximityEvent(entering: false, at: rawPoint, eraser: !point.eraser)
            activeToolIsEraser = point.eraser
            lastEraserMode = point.eraser
            postProximityEvent(entering: true, at: rawPoint, eraser: point.eraser)
        }

        guard point.inProximity else { return }

        // ── Position smoothing (every report) ─────────────────────────────────
        let screenPoint = smoother.applySmoothing(
            rawPoint: rawPoint, enteringProximity: enteringProximity, dt: smoothingDt)

        // ── Scroll Drag: convert this frame's motion to a scroll delta ──────
        // Runs before the movement code, which skips cursor motion while
        // panning. dt must be real seconds: the damping is tuned in them.
        let panNow = CFAbsoluteTimeGetCurrent()
        let panDt = lastPanScrollFrameTime > 0 ? panNow - lastPanScrollFrameTime : 0
        lastPanScrollFrameTime = panNow
        if panScroll.isActive {
            postPanScroll(panScroll.process(screen: screenPoint, dt: panDt))
        }
        // Computed once per report for every post below.
        let pose = resolveEffectivePose(point: point, snapshot: snap)
        shimLastPoint = point
        shimLastScreen = screenPoint
        shimLastPressure = pressure

        // ── Jitter tracking (hover only, every report) ─────────────────────────
        if !rawTipDown {
            smoother.observeHoverRaw(rawPoint)
        } else {
            smoother.endHover()
        }

        // Holds a release briefly to absorb chatter. No-op at Steadiness 0.
        let tipDown = resolveDebouncedTipDown(rawTipDown: rawTipDown, tool: tool)

        // ── Tip press transitions (always immediate) ───────────────────────────
        if tipDown != lastTipDown {
            if !activeToolIsMouse && activeAppNeedsTabletPointerEvents {
                postTabletPointerEvent(
                    at: screenPoint, pressure: pressure, point: point, pose: pose,
                    snapshot: snap)
            }
            let tipKind = (activeToolIsEraser ? tool.eraserBinding : tool.tipBinding).kind
            if tipDown {
                cancelPendingMouseUp()
                didEmitDragSinceDown = false
                if fireContactDeferredButtons(at: screenPoint, snap: snap, settings: settings) {
                    // Hover Click off: contact performs the held button's
                    // action in place of the tip's click.
                    tipClickSwallowed = true
                } else if panScroll.isActive {
                    // Pan View: contact grabs the canvas, so no click.
                } else if tipKind == .clickLock && clickLocked {
                    // Tip set to Click Lock: the next contact ends the lock.
                    releaseClickLock(at: screenPoint, snapshot: snap)
                    tipClickSwallowed = true
                } else if clickLocked || tipKind == .none {
                    // Tip set to None, or Click Lock already holds the left
                    // button: contact moves the cursor without clicking.
                    tipClickSwallowed = true
                } else {
                    // Tip set to Click Lock starts the lock with a normal
                    // press; `releaseTip` keeps the button held on lift.
                    if tipKind == .clickLock { clickLocked = true }
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
                releaseContactFiredButtons(at: screenPoint, snap: snap, settings: settings)
                if panScroll.isActive {
                    // No click fired, so no release either.
                } else {
                    releaseTip(at: screenPoint, pressure: pressure, point: point, snap: snap)
                }
            }
            lastPostedPoint = screenPoint
            lastPostedPressure = pressure
            lastPostedRotation = pose.rotation
            hasPostedPoint = true

        } else if panScroll.isActive {
            // ── Scroll Drag: ungated movement ──────────────────────────────
            // Scrolling skips the delta gate. Only bookkeeping happens here.
            if hasPostedPoint {
                let delta = hypot(
                    screenPoint.x - lastPostedPoint.x,
                    screenPoint.y - lastPostedPoint.y)
                smoother.recordMoveDelta(delta)
            }
            lastPostedPoint = screenPoint
            lastPostedPressure = pressure
            lastPostedRotation = pose.rotation
            hasPostedPoint = true

        } else {
            // ── Continuous movement: delta gate ────────────────────────────────
            // Pressure and twist count as movement, so a still pen still
            // updates apps (airbrush buildup; Rebelle and Krita orient the
            // brush while hovering).
            let rotated =
                rotationDelta(pose.rotation, lastPostedRotation) > Self.rotationEpsilon

            let moved =
                !hasPostedPoint
                || (screenPoint.x - lastPostedPoint.x).magnitude > Self.positionEpsilon
                || (screenPoint.y - lastPostedPoint.y).magnitude > Self.positionEpsilon
                || rotated
                || (tipDown
                    && (pressure - lastPostedPressure).magnitude > Self.pressureEpsilon)

            // A KC-100's USB left button already posted its own mouseDown.
            let dragging = (tipDown && !tipClickSwallowed) || (activeToolIsMouse && usbMouseLeftHeld)

            // Backlogged hover reports are dropped from both post streams.
            // Never while dragging: stroke data stays intact.
            let isStale = !dragging && isStaleHoverMove()

            if moved {
                // Track velocity for tip-up assist.
                if hasPostedPoint {
                    let delta = hypot(
                        screenPoint.x - lastPostedPoint.x,
                        screenPoint.y - lastPostedPoint.y)
                    smoother.recordMoveDelta(delta)
                }
                if !activeToolIsMouse && activeAppNeedsTabletPointerEvents && !isStale {
                    postTabletPointerEvent(
                        at: screenPoint, pressure: pressure, point: point, pose: pose,
                        snapshot: snap)
                }
                // Drag threshold: no drag until the pen travels dragThreshold
                // from touchdown, so a shaky tap stays a click.
                let withinDragThreshold =
                    tipDown && !didEmitDragSinceDown
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
                    // Panning: motion became scrolling above; the cursor stays put.
                } else if let dragBtn = hoverDragButton {
                    // A button binding (or Click Lock) holds a mouse button while
                    // hovering; send drags, as SketchUp expects.
                    postMouseDrag(
                        button: dragBtn, at: screenPoint, pressure: 0, point: point,
                        pose: pose, snapshot: snap)
                } else if isStale {
                    // Backlog: skip the post, so the cursor jumps once when live
                    // data resumes instead of replaying history. Logged because it
                    // freezes the cursor with nothing else to show for it.
                    staleHoverSuppressCount += 1
                    let now = Date()
                    if now.timeIntervalSince(lastStaleHoverLogAt) > 1.0 {
                        injectLog.info(
                            "hover move suppressed as stale backlog (\(self.staleHoverSuppressCount) in a row)"
                        )
                        lastStaleHoverLogAt = now
                    }
                } else {
                    if staleHoverSuppressCount > 0 {
                        injectLog.info(
                            "hover resumed after \(self.staleHoverSuppressCount) suppressed stale report(s)"
                        )
                        staleHoverSuppressCount = 0
                    }
                    postMouseMoved(
                        at: screenPoint, point: point, pose: pose,
                        snapshot: snap)
                }
                lastPostedPoint = screenPoint
                lastPostedPressure = pressure
                lastPostedRotation = pose.rotation
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
                // The 3-button pen's lower button, with the same debounce.
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
                // Update first so fireButtonAction's quiescent check sees the new state.
                lastButton1Down = point.penButton1
                // A mouse tool's button1 already clicked as the tip.
                if !activeToolIsMouse {
                    noteButtonForCapture(1, down: point.penButton1, binding: btn1)
                    dispatchBarrelButton(.one, btn1, down: point.penButton1, at: screenPoint,
                                     snap: snap, settings: settings)
                }
            }
            if point.penButton2 != lastButton2Down {
                lastButton2Down = point.penButton2
                noteButtonForCapture(2, down: point.penButton2, binding: btn2)
                dispatchBarrelButton(.two, btn2, down: point.penButton2, at: screenPoint,
                                 snap: snap, settings: settings)
            }
            if point.penButton3 != lastButton3Down {
                lastButton3Down = point.penButton3
                noteButtonForCapture(3, down: point.penButton3, binding: btn3)
                dispatchBarrelButton(.three, btn3, down: point.penButton3, at: screenPoint,
                                 snap: snap, settings: settings)
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

    /// The current report is stale backlog (see `staleReportThresholdMs`), so
    /// its hover move should be skipped. Skipped outright, not throttled: a
    /// throttled sample still visibly replayed old positions.
    /// Names the action a pen-button change fired in the capture log, so a
    /// button that decodes but does nothing shows where it stopped.
    private func noteButtonForCapture(_ n: Int, down: Bool, binding: ButtonBinding) {
        guard HIDCapture.shared.isCapturing else { return }
        HIDCapture.shared.recordNote(
            tag: "MockTab",
            "pen button \(n) \(down ? "down" : "up") → \(binding.kind.rawValue), tool 0x\(String(format: "%04X", activeToolCode))")
    }

    private func isStaleHoverMove() -> Bool {
        guard InputInjector.currentReportTimestampNs != 0 else { return false }
        let nowNs = UInt64(Double(mach_absolute_time()) * LatencyProbe.timebaseFactor)
        guard nowNs > InputInjector.currentReportTimestampNs else { return false }
        let staleMs = Double(nowNs - InputInjector.currentReportTimestampNs) / 1_000_000.0
        return staleMs > Self.staleReportThresholdMs
    }

    /// Release every held USB mouse or middle button, posting the ups so the
    /// system's buttons come up too. Called on proximity exit and tool change.
    /// The idle watchdog can't do this: a held button is normally legitimate.
    func releaseHeldPointerButtons(at location: CGPoint, snapshot: InjectionSnapshot) {
        // E.g. a KC-100 lifted mid-drag.
        if lastUSBMouseMask != 0 {
            if usbMouseLeftHeld {
                postMouseUp(
                    button: .left, at: location,
                    clickCount: activeClickCount,
                    snapshot: snapshot)
                usbMouseLeftHeld = false
            }
            if (lastUSBMouseMask & 0x02) != 0 {
                postMouseUp(
                    button: .right, at: location, clickCount: 1,
                    snapshot: snapshot)
            }
            if (lastUSBMouseMask & 0x04) != 0 {
                if let e = CGEvent(
                    mouseEventSource: sessionSource, mouseType: .otherMouseUp,
                    mouseCursorPosition: location, mouseButton: .center)
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
                mouseCursorPosition: location, mouseButton: .center)
            {
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }
            lastMiddleDown = false
        }
    }

    /// End Click Lock, posting the left button's up. No-op when not locked.
    func releaseClickLock(at location: CGPoint, snapshot: InjectionSnapshot) {
        guard clickLocked else { return }
        clickLocked = false
        hoverDragButton = nil
        // A tip still down from starting the lock must not post a second up.
        if lastTipDown { tipClickSwallowed = true }
        postMouseUp(button: .left, at: location, clickCount: 1, snapshot: snapshot)
    }

    /// Release a button held by a click binding or Click Lock, posting the up.
    /// Called on tool change and disconnect, not proximity exit: holding a
    /// button, lifting the pen, and carrying on is legitimate.
    func releaseBindingHeldButton(at location: CGPoint, snapshot: InjectionSnapshot) {
        clickLocked = false
        guard let held = hoverDragButton else { return }
        switch held {
        case .left:
            postMouseUp(
                button: .left, at: location, clickCount: activeClickCount,
                snapshot: snapshot)
        case .right:
            postMouseUp(button: .right, at: location, clickCount: 1, snapshot: snapshot)
        default:
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: .otherMouseUp,
                mouseCursorPosition: location, mouseButton: .center)
            {
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }
        }
        hoverDragButton = nil
        injectLog.notice("released a binding-held pointer button")
    }

    /// The previous tool is off the tablet, so release what it held.
    func releaseHeldStateForToolChange() {
        guard let snap = injectionSnapshot else { return }
        let loc = currentCursorPosition()
        releaseHeldPointerButtons(at: loc, snapshot: snap)
        // Before the binding release, so a contact-fired click posts one up.
        releaseContactFiredButtons(at: loc, snap: snap, settings: nil)
        releaseBindingHeldButton(at: loc, snapshot: snap)
        releaseTouchDrag(snapshot: snap)
        // End momentum tails explicitly: macOS 27 force-cancels a gesture
        // left open after input stops.
        if panMomentumTail.isRunning || touchMomentumTail.isRunning {
            TouchPipelineProbe.note { $0.momentumTailsStoppedOnToolChange += 1 }
        }
        panMomentumTail.stop()
        touchMomentumTail.stop()
    }

    /// The device disconnected: run the full proximity exit. Binding-held
    /// buttons go first, since the exit clears them without posting an up.
    func releaseHeldStateForDisconnect() {
        guard let snap = injectionSnapshot else { return }
        releaseBindingHeldButton(at: currentCursorPosition(), snapshot: snap)
        commitProximityExit(snap: snap)
        // See releaseHeldStateForToolChange.
        if panMomentumTail.isRunning || touchMomentumTail.isRunning {
            TouchPipelineProbe.note { $0.momentumTailsStoppedOnDisconnect += 1 }
        }
        panMomentumTail.stop()
        touchMomentumTail.stop()
    }

    /// Proximity-exit cleanup: release the tip, held buttons, and modifiers,
    /// then reset per-proximity state. Xencelabs reaches this through
    /// `proximityExitDebounceTimer`.
    func commitProximityExit(snap: InjectionSnapshot) {
        activeToolIsEraser = false
        lastEraserMode = false
        // The release below supersedes it.
        tipUpDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
        tipUpDebounceTimer = nil
        let exitPoint = smoother.smoothedPoint
        // Lifting the pen away ends Click Lock, as in the Xencelabs driver.
        releaseClickLock(at: exitPoint, snapshot: snap)
        if lastTipDown && tipClickSwallowed {
            tipClickSwallowed = false
            lastTipDown = false
        } else if lastTipDown {
            postMouseUp(
                button: activeButton, at: exitPoint,
                clickCount: activeClickCount,
                snapshot: snap)
            lastTipDown = false
        }
        releaseHeldPointerButtons(at: exitPoint, snapshot: snap)
        // Safety valve for modifiers stranded by a lost release report.
        releaseAllSyntheticModifiers()
        releaseAllHeldKeyComboKeys()

        // Don't post flagsChanged for physical modifiers here: it would show a
        // held key as stuck in Keyboard Viewer. moveSafeEventFlags already
        // carries the physical state on the last move.
        lastLoggedManagedFlags = 0

        // Reset aux state so the next injectAux fires fresh transitions.
        cancelPendingMouseUp()
        hoverDragButton = nil
        // Pan View survives the exit: its button owns the gesture. Suspend so
        // re-entry doesn't jump; the release (or the safety net) ends it.
        if panScroll.isActive {
            panScroll.suspend()
            schedulePanScrollSafetyNet(snap: snap)
        }
        lastAuxButtons = [Bool](repeating: false, count: 19)
        lastRingButtonDown = false
        hasPostedPoint = false
        displayMapper.clearRelativeAnchor()
        // End momentum tails; see releaseHeldStateForToolChange.
        if panMomentumTail.isRunning || touchMomentumTail.isRunning {
            TouchPipelineProbe.note { $0.momentumTailsStoppedOnProximityExit += 1 }
        }
        panMomentumTail.stop()
        touchMomentumTail.stop()
        lastPostedPressure = -1.0
        lastPostedRotation = 0.0
        smoother.resetOnProximityExit()
        pressureSmoother.reset()

        // Starts touch's grace window (touchArbitrationGrace), so a stray
        // finger as the pen lifts isn't taken as touch input.
        if touchPenConfirmedBusy {
            penProximityExitTime = CFAbsoluteTimeGetCurrent()
        }
        touchPenConfirmedBusy = false
        touchPenBusyConfirmedAt = 0
        touchPenBusyHadTipSinceConfirmed = false
        // Counted here so every exit path is included, once.
        if lastProximity {
            TouchPipelineProbe.note { $0.penProximityExits += 1 }
        }
        lastProximity = false

        // Release barrel buttons now, cancelling pending debounce timers.
        let exitScreenPoint = smoother.smoothedPoint
        button1UpDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
        button1UpDebounceTimer = nil
        if lastButton1Down {
            lastButton1Down = false
            if !activeToolIsMouse {
                dispatchBarrelButton(
                    .one, snap.activeTool.penButton1Binding, down: false, at: exitScreenPoint,
                    snap: snap, settings: nil)
            }
        }
        button2UpDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
        button2UpDebounceTimer = nil
        if lastButton2Down {
            lastButton2Down = false
            dispatchBarrelButton(
                .two, snap.activeTool.penButton2Binding, down: false, at: exitScreenPoint,
                snap: snap, settings: nil)
        }
        button3UpDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
        button3UpDebounceTimer = nil
        if lastButton3Down {
            lastButton3Down = false
            if !activeToolIsMouse {
                dispatchBarrelButton(
                    .three, snap.activeTool.penButton3Binding, down: false, at: exitScreenPoint,
                    snap: snap, settings: nil)
            }
        }
        contactDeferredButtons = 0
        contactFiredButtons = 0
    }

    /// Force-close a pan whose button release was lost.
    private func panScrollSafetyNetFired() {
        panScrollSafetyNetTimer = nil
        postPanScroll(panScroll.disengage())
        if SharedPanScrollState.shared.driver === self {
            SharedPanScrollState.shared.driver = nil
        }
    }

    /// Arm the lost-release backstop for a pan open at proximity exit.
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

    /// The release arrived; no backstop needed.
    func cancelPanScrollSafetyNet() {
        panScrollSafetyNetTimer.map { CFRunLoopTimerInvalidate($0) }
        panScrollSafetyNetTimer = nil
    }

    /// Steadiness (0-1) scaled to `buttonUpDebounceInterval`'s 50ms ceiling.
    private func tipUpDebounceInterval(for tool: InjectionSnapshot.Tool) -> TimeInterval {
        tool.smoothingStrength * buttonUpDebounceInterval
    }

    /// Press is immediate; release waits out the window. Same shape as
    /// `handleXencelabsBarrelButton`.
    private func resolveDebouncedTipDown(rawTipDown: Bool, tool: InjectionSnapshot.Tool) -> Bool {
        if rawTipDown {
            if let t = tipUpDebounceTimer {
                CFRunLoopTimerInvalidate(t)
                tipUpDebounceTimer = nil
            }
            return true
        }
        let window = tipUpDebounceInterval(for: tool)
        guard lastTipDown, window > 0 else {
            tipUpDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
            tipUpDebounceTimer = nil
            return false
        }
        guard tipUpDebounceTimer == nil else {
            return true
        }
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + window,
            0, 0, 0
        ) { [weak self] _ in
            guard let self else { return }
            self.tipUpDebounceTimer = nil
            guard self.lastTipDown, let snap = self.injectionSnapshot else { return }
            self.commitDebouncedTipUp(snap: snap)
        }
        CFRunLoopAddTimer(HIDThread.shared.runLoop, timer, .commonModes)
        tipUpDebounceTimer = timer
        return true
    }

    /// Tip-up: posts the release, or defers it for a fast stroke
    /// (`tipUpAssistDelay`). Callers post their own pointer event.
    private func releaseTip(
        at screenPoint: CGPoint, pressure: Double, point: TabletPoint, snap: InjectionSnapshot
    ) {
        if tipClickSwallowed {
            tipClickSwallowed = false
            return
        }
        if clickLocked {
            // The tip started Click Lock: the button stays down, and hover drags.
            hoverDragButton = .left
            return
        }
        let btn = activeButton
        let count = activeClickCount

        if snap.tipUpAssistDelay > 0
            && smoother.recentVelocity > Self.tipUpAssistVelocityThreshold {
            // Defer the release so fast strokes aren't cut short. HIDThread
            // timer: on time under main-thread load, and no race on cancel.
            let capturedSnap = snap
            let timer = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault,
                CFAbsoluteTimeGetCurrent() + snap.tipUpAssistDelay / 1000.0,
                0,  // interval — one-shot
                0, 0
            ) { [weak self] _ in
                guard let self, self.pendingMouseUp != nil else { return }
                self.pendingMouseUp = nil
                // Release where the stroke ended, not where the tip lifted.
                self.postMouseUp(
                    button: btn, at: self.lastPostedPoint, clickCount: count,
                    point: point, snapshot: capturedSnap)
            }
            pendingMouseUp = timer
            if let timer {
                CFRunLoopAddTimer(HIDThread.shared.runLoop, timer, .commonModes)
            }
        } else {
            postMouseUp(
                button: btn, at: screenPoint, clickCount: count, point: point, snapshot: snap)
        }
        lastPostedPoint = screenPoint
        lastPostedPressure = pressure
        hasPostedPoint = true
    }

    /// Timer-fired debounced release, at the last known point.
    private func commitDebouncedTipUp(snap: InjectionSnapshot) {
        lastTipDown = false
        guard let pt = shimLastPoint else { return }
        if !activeToolIsMouse && activeAppNeedsTabletPointerEvents {
            postTabletPointerEvent(
                at: lastPostedPoint, pressure: lastPostedPressure, point: pt,
                pose: resolveEffectivePose(point: pt, snapshot: snap), snapshot: snap)
        }
        releaseContactFiredButtons(at: lastPostedPoint, snap: snap, settings: nil)
        if panScroll.isActive {
            // Panning swallowed the press, so no release.
            return
        }
        releaseTip(at: lastPostedPoint, pressure: lastPostedPressure, point: pt, snap: snap)
    }

    /// Names a barrel button for timer handlers, which can't capture `inout`.
    private enum BarrelButtonSlot: CaseIterable {
        case one, two, three

        var bit: UInt8 {
            switch self {
            case .one: 1
            case .two: 2
            case .three: 4
            }
        }

        func binding(in snap: InjectionSnapshot) -> ButtonBinding {
            switch self {
            case .one: snap.activeTool.penButton1Binding
            case .two: snap.activeTool.penButton2Binding
            case .three: snap.activeTool.penButton3Binding
            }
        }
    }

    /// Xencelabs barrel buttons: presses fire at once; releases wait
    /// `buttonUpDebounceInterval` so a flicker never reads as a re-press.
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
            // Still down: cancel any pending release.
            if let t = pendingTimer {
                CFRunLoopTimerInvalidate(t)
                setBarrelButtonTimer(slot, nil)
            }
            if !wasDown {
                setBarrelButtonDown(slot, true)
                dispatchBarrelButton(slot, binding, down: true, at: location, snap: snap, settings: settings)
            }
            return
        }
        guard wasDown, pendingTimer == nil else { return }
        // Right-click and eraser get a longer window, so a held context menu
        // survives a pen lift.
        let window: TimeInterval
        switch binding.kind {
        case .rightClick, .eraser: window = buttonUpDebounceMenuInterval
        default: window = buttonUpDebounceInterval
        }
        let physicalReleaseTime = CFAbsoluteTimeGetCurrent()
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            physicalReleaseTime + window,
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
            // Tell Pan View's momentum how late this release is.
            self.pendingButtonUpBackdate = CFAbsoluteTimeGetCurrent() - physicalReleaseTime
            self.dispatchBarrelButton(slot, binding, down: false, at: location, snap: snap, settings: settings)
            self.pendingButtonUpBackdate = 0
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

    // MARK: - Hover Click

    /// Fires a barrel-button edge. With Hover Click off, a click or Pan View
    /// pressed while hovering waits for tip contact; its release fires only
    /// if contact fired the press.
    private func dispatchBarrelButton(
        _ slot: BarrelButtonSlot, _ binding: ButtonBinding, down: Bool,
        at location: CGPoint, snap: InjectionSnapshot, settings: TabletSettings?
    ) {
        if down {
            if !snap.hoverClick, !lastTipDown, !activeToolIsMouse,
                Self.waitsForContact(binding.kind)
            {
                contactDeferredButtons |= slot.bit
                return
            }
        } else if contactDeferredButtons & slot.bit != 0 {
            contactDeferredButtons &= ~slot.bit
            guard contactFiredButtons & slot.bit != 0 else { return }
            contactFiredButtons &= ~slot.bit
        }
        fireButtonAction(binding, down: down, at: location, snapshot: snap, settings: settings)
    }

    /// Tip contact fires every deferred button still held. True if any fired.
    private func fireContactDeferredButtons(
        at location: CGPoint, snap: InjectionSnapshot, settings: TabletSettings?
    ) -> Bool {
        let pending = contactDeferredButtons & ~contactFiredButtons
        guard pending != 0 else { return false }
        for slot in BarrelButtonSlot.allCases where pending & slot.bit != 0 {
            contactFiredButtons |= slot.bit
            fireButtonAction(
                slot.binding(in: snap), down: true, at: location, snapshot: snap,
                settings: settings)
        }
        return true
    }

    /// Tip lift ends what contact fired. The buttons stay deferred, so the
    /// next contact fires them again.
    private func releaseContactFiredButtons(
        at location: CGPoint, snap: InjectionSnapshot, settings: TabletSettings?
    ) {
        guard contactFiredButtons != 0 else { return }
        let fired = contactFiredButtons
        contactFiredButtons = 0
        for slot in BarrelButtonSlot.allCases where fired & slot.bit != 0 {
            fireButtonAction(
                slot.binding(in: snap), down: false, at: location, snapshot: snap,
                settings: settings)
        }
    }

    /// Actions tied to where the pen is. Keys and modifiers fire on press, so
    /// a held modifier still works while hovering.
    private static func waitsForContact(_ kind: ButtonBinding.Kind) -> Bool {
        switch kind {
        case .leftClick, .rightClick, .eraser, .middleClick, .middleClickWithTip,
            .doubleClick, .scrollDrag:
            return true
        case .none, .clickLock, .keyCombo, .displayToggle, .spacebar, .ringCycle,
            .ringSelectSlot, .relativeModeToggle, .spanDisplaysToggle, .ringCycle2,
            .ringSelectSlot2:
            return false
        }
    }

    /// Shortest angular distance between two barrel angles, in degrees.
    /// Rotation wraps at 360, so plain subtraction reads one step across the
    /// seam (359.8° to 0.2°) as a 359.6° sweep. Never more than 180.
    func rotationDelta(_ a: Double, _ b: Double) -> Double {
        let d = (a - b).magnitude.truncatingRemainder(dividingBy: 360.0)
        return d > 180.0 ? 360.0 - d : d
    }
}
