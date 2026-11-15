// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import os
import TabletKit

// Capacitive finger-touch injection. The touch state it reads (`touchTracker`,
// `cachedTouch*`, `penProximityExitTime`) lives on the main class body, since
// extensions can't hold stored properties, and stays HIDThread-confined.
extension InputInjector {

    /// Injects a touch contact frame.
    ///
    /// - With touch off, it does nothing.
    /// - With the pen confirmed busy (`touchPenConfirmedBusy`) or lifted within
    ///   `touchArbitrationGrace`, it skips the frame and winds down the tracker,
    ///   so a stale gesture doesn't survive the pen's arrival.
    /// - Otherwise it projects each contact through the touch-area mapping to
    ///   screen space, hands the set to `TouchStateTracker`, and turns its
    ///   `Intent` into CGEvents: `mouseMoved`, scroll-wheel events with phase,
    ///   magnify and rotate gestures (both can post in one frame), and a left
    ///   click at the cursor for a tap.
    func injectTouch(contacts: [TouchContact], settings: TabletSettings?) {
        ThreadContract.expectPenThread()
        rearmWatchdog()
        guard let snap = injectionSnapshot else {
            TouchPipelineProbe.note { $0.framesNoSnapshot += 1 }
            return
        }
        guard snap.touchEnabled else {
            TouchPipelineProbe.note { $0.framesTouchDisabled += 1 }
            releaseTouchDrag(snapshot: snap)
            return
        }

        // Cache the touch coordinate maximums per device. The registry lookup
        // is a linear scan, and at 100 Hz with a palm on the tablet it was a
        // measurable CPU cost. This runs before the arbitration gate because
        // palm classification needs the maximums.
        //
        // A dongle-bound device's own PID has no touch-area data in the
        // registry; the paired tablet's does. Without preferring
        // `pairedProductID`, the maximums fell back to 1 and every touch
        // coordinate collapsed toward one corner of the active area.
        let effectiveTouchPID = snap.pairedProductID != 0 ? snap.pairedProductID : deviceProductID
        if cachedTouchSpecPID != effectiveTouchPID {
            let spec = WacomDeviceRegistry.spec(for: effectiveTouchPID)
            // With no registry range, use the sensor descriptor's, so contacts
            // don't collapse into one corner. The registry wins where set,
            // since fixed-format decoders on verified tablets don't read the
            // descriptor's coordinate space.
            let described = DescribedTouchRanges.range(forProductID: effectiveTouchPID)
            if let described, (spec?.touchMaxX ?? 0) == 0 {
                cachedTouchMaxX = Swift.max(1, described.x)
                cachedTouchMaxY = Swift.max(1, described.y)
            } else {
                cachedTouchMaxX = Swift.max(1, spec?.touchMaxX ?? 1)
                cachedTouchMaxY = Swift.max(1, spec?.touchMaxY ?? 1)
            }
            // With no physical size, fall back to the raw maximums, which
            // applies no correction (see `cachedTouchWidthMM`).
            cachedTouchWidthMM = spec?.activeWidthMM ?? Double(cachedTouchMaxX)
            cachedTouchHeightMM = spec?.activeHeightMM ?? Double(cachedTouchMaxY)
            cachedTouchIsDirect = spec?.isPenDisplay ?? false
            cachedTouchModelName = spec?.name ?? ""
            touchPanelNeedsResolve = true
            cachedTouchSpecPID = effectiveTouchPID
        }

        // Pen arbitration: the pen wins. Skip frames and wind down the tracker
        // so a half-formed gesture doesn't resume after the pen lifts. Touch
        // during pen use isn't offered: the firmware streams it, but palm
        // rejection wasn't reliable enough to ship.
        let now = ProcessInfo.processInfo.systemUptime
        // `staleBusy` lets touch through only once a busy pen has sat with no
        // tip contact for `staleBusyTimeout`: the ambiguous Bluetooth
        // proximity case (see `staleBusyTimeout`), not touch while drawing,
        // which `touchPenConfirmedBusy` still blocks at every tip contact.
        let staleBusy = touchPenConfirmedBusy
            && !touchPenBusyHadTipSinceConfirmed
            && now - touchPenBusyConfirmedAt >= Self.staleBusyTimeout
        let penBusy = (touchPenConfirmedBusy && !staleBusy) ||
            now - penProximityExitTime < Self.touchArbitrationGrace
        if staleBusy, !penBusy {
            TouchPipelineProbe.note { $0.framesStaleBusyRecovered += 1 }
        }
        if penBusy {
            TouchPipelineProbe.note { $0.noteTouchPenBusy() }
            touchPalmRejector.reset()
            touchPenHeldIDs.formUnion(contacts.map(\.id))
            touchSequenceTainted = !contacts.isEmpty
            touchOwnedPointerPosition = nil
            // Wind down whenever a gesture is live, even on a frame with no
            // contacts. That empty frame is the lift signal; gating on
            // `!contacts.isEmpty` meant a lift inside a pen-busy window never
            // closed the gesture, and every later touch kept scrolling. Gating
            // on `mode != .idle` keeps hover frames from driving the tracker.
            if touchTracker.mode != .idle {
                // A bare `reset()` never tells the app the gesture ended, so its
                // own recognizer (Krita's pinch and rotate handler, say) waits
                // for a phase-ended event, reads as stuck engaged, and rejects
                // the next gesture. Wind down through the same path as a real
                // lift, so every open phase closes. The pen arriving ends the
                // touch; it never clicks.
                let windDown = touchTracker.process(
                    contacts: [],
                    tapToClick: false,
                    twoFingerScroll: snap.twoFingerScroll,
                    reverseScrollDirection: snap.reverseScrollDirection,
                    sensitivity: snap.touchSensitivity,
                    pinchZoom: snap.pinchZoomEnabled,
                    twoFingerRightClick: false,
                    threeFingerDrag: false,
                    rotate: snap.rotateEnabled,
                    absoluteTouch: cachedTouchIsDirect,
                    onsetDelay: snap.touchOnsetDelay,
                    tapStabilizationPt: snap.touchTapStabilizationPt,
                    now: now)
                noteOnsetLifecycle(now: now)
                handleTouchIntent(windDown, snap: snap, settings: settings)
            }
            return
        }

        TouchPipelineProbe.note { $0.noteTouchNotPenBusy() }

        // Palm classification runs before projection and gesture tracking. On
        // the IntuosV2 touch family it keeps a simultaneous finger and rejects
        // only the palm-sized contact; other tablets pass through until they
        // have calibrated thresholds.
        let filtered = touchPalmRejector.filter(
            contacts: contacts.map {
                (id: $0.id, major: $0.contactArea, minor: $0.contactMinor)
            },
            productID: deviceProductID,
            keep: touchTracker.dragFingerIDs)
        let presentIDs = Set(contacts.map(\.id))
        touchPenHeldIDs.formIntersection(presentIDs)
        let acceptedIDs = filtered.acceptedIDs.subtracting(touchPenHeldIDs)
        if touchTracker.mode == .idle, !contacts.isEmpty,
           now - penProximityExitTime < Self.penInHandWindow {
            touchSequenceTainted = true
        }
        if acceptedIDs.count < contacts.count { touchSequenceTainted = true }
        if !contacts.isEmpty, now - lastPhysicalKeyDownTime < Self.typingHoldOff {
            touchSequenceTainted = true
        }
        let filteredContacts = contacts.filter { acceptedIDs.contains($0.id) }
        if filteredContacts.count < contacts.count {
            let dropped = contacts.count - filteredContacts.count
            TouchPipelineProbe.note { $0.contactsPalmRejected += dropped }
        }
        // A frame with two or more contacts that leaves palm filtering with
        // fewer can no longer start or sustain a two-finger gesture. Count
        // each entry into that state once, not every frame: a resting palm
        // beside one finger holds it at report rate and would swamp the
        // signal. `contactsPalmRejected` alone can't tell a lost gesture from a
        // correctly rejected lone palm.
        let brokeTwoFingerNow = contacts.count >= 2 && filteredContacts.count < 2
        if brokeTwoFingerNow, !palmRejectionBrokeTwoFingerActive {
            TouchPipelineProbe.note { $0.palmRejectionBrokeTwoFingerFrames += 1 }
        }
        palmRejectionBrokeTwoFingerActive = brokeTwoFingerNow
        notePalmNeighbors(contacts: contacts, acceptedIDs: filtered.acceptedIDs)
        if !filtered.newlyRejectedIDs.isEmpty || !filtered.newlyAcceptedIDs.isEmpty {
            let rejected = contacts
                .filter { filtered.newlyRejectedIDs.contains($0.id) }
                .map { "\($0.id):\($0.contactArea ?? -1)/\($0.contactMinor ?? -1)" }
                .joined(separator: ",")
            let accepted = contacts
                .filter { filtered.newlyAcceptedIDs.contains($0.id) }
                .map { "\($0.id):\($0.contactArea ?? -1)/\($0.contactMinor ?? -1)" }
                .joined(separator: ",")
            injectLog.info(
                "touch palm filter: rejected=id:major/minor[\(rejected, privacy: .public)], accepted=id:major/minor[\(accepted, privacy: .public)]")
        }

        // Rotate the touch-area crop and the sensor maxima into oriented space
        // once per frame. `snap.touchArea*` is stored raw, unlike the pen's
        // oriented `activeArea*`, so the crop needs the rotation each contact
        // gets below. The maxima swap depends only on frame-constant inputs, so
        // it sits outside the loop.
        let orientation = snap.tabletOrientation
        // A pen display's touch covers its own screen whole, or the finger
        // and cursor part ways.
        let orientedArea = cachedTouchIsDirect
            ? (x: 0.0, y: 0.0, w: 1.0, h: 1.0)
            : DisplayMapper.orientedCropRect(
                areaX: snap.touchAreaX, areaY: snap.touchAreaY,
                areaWidth: snap.touchAreaWidth, areaHeight: snap.touchAreaHeight,
                orientation: orientation)
        let effMaxX: Double = orientation.swapsAxes ? Double(cachedTouchMaxY) : Double(cachedTouchMaxX)
        let effMaxY: Double = orientation.swapsAxes ? Double(cachedTouchMaxX) : Double(cachedTouchMaxY)

        // Touch shares the pen's target display, fit to the touch area's
        // physical aspect as the tablet is turned, so shapes traced on the pad
        // aren't stretched by the display's ratio.
        let displayBounds = cachedTouchIsDirect
            ? touchPanelBounds(snap: snap)
            : DisplayMapper.aspectFitRect(
                displayMapper.displayBounds(for: snap),
                aspect: DisplayMapper.orientedCropAspect(
                    widthMM: cachedTouchWidthMM, heightMM: cachedTouchHeightMM,
                    crop: orientedArea, orientation: orientation))

        // Project each contact to screen space with the touch-area mapping.
        // Contacts outside the crop rect return nil and don't count; clamping
        // them to the edge would leave the dead zone partly responsive.
        var projected: [(id: Int, screen: CGPoint)] = []
        projected.reserveCapacity(filteredContacts.count)
        for c in filteredContacts {
            let (ox, oy, _, _) = DisplayMapper.orient(
                x: Double(c.x), y: Double(c.y),
                maxX: Double(cachedTouchMaxX), maxY: Double(cachedTouchMaxY),
                orientation: orientation)
            guard let p = TouchStateTracker.screenPoint(
                x: ox, y: oy, maxX: effMaxX, maxY: effMaxY,
                areaX: orientedArea.x, areaY: orientedArea.y,
                areaWidth: orientedArea.w, areaHeight: orientedArea.h,
                displayBounds: displayBounds)
            else { continue }
            projected.append((id: c.id, screen: p))
        }
        if projected.count < filteredContacts.count {
            let dropped = filteredContacts.count - projected.count
            TouchPipelineProbe.note { $0.contactsOffArea += dropped }
        }
        if !projected.isEmpty {
            let direct = cachedTouchIsDirect
            let matched = cachedTouchPanelBounds != nil
            TouchPipelineProbe.note {
                $0.framesTracked += 1
                if direct {
                    $0.touchScreenMatchedPanel = matched
                    $0.touchScreenX = displayBounds.origin.x
                    $0.touchScreenY = displayBounds.origin.y
                    $0.touchScreenWidth = displayBounds.width
                    $0.touchScreenHeight = displayBounds.height
                }
            }
        }

        // Diagnostic: a committed pan scroll on fewer than two contacts is the
        // stuck-scroll signature (see
        // `CaptureTouchPipeline.scrollSingleContactFrames`). Sampling it here
        // keeps `TouchStateTracker` free of the probe. `now` is the tracker's
        // clock, so a sub-millisecond gap between frames, the batched Bluetooth
        // burst that corrupts release velocity, shows up too.
        if touchTracker.mode == .scroll, touchTracker.committedToPan,
            !touchTracker.isHoldingWoundDownScroll
        {
            if projected.count >= 2 {
                TouchPipelineProbe.note { $0.noteScrollTwoContactFrame() }
            } else {
                TouchPipelineProbe.note { $0.noteScrollSingleContactFrame() }
            }
        }
        if lastTouchFrameTime != 0, now - lastTouchFrameTime < 0.001 {
            TouchPipelineProbe.note { $0.subMillisecondDtFrames += 1 }
        }
        lastTouchFrameTime = now

        // A real trackpad stops a coasting flick the instant two fingers land,
        // like grabbing a spinning wheel, before any gesture is recognized.
        // Waiting for the tracker's intent would need motion past the
        // pinch/pan threshold first, which feels like a nudge to stop the coast.
        // So cancel on the raw idle-to-two-contacts transition. It takes two
        // fingers, so an ordinary single-finger move doesn't stop a coast the
        // user never touched.
        //
        // `.pending` counts as well as `.idle`: `process()` returns early on a
        // sequence's first contact, so `.idle` still holds here only when both
        // fingers landed in one HID frame. A landing split across two frames,
        // the common case and a certainty when palm filtering rejects the
        // first contact, would never arrest the coast. `stop()` does nothing
        // without a tail, so testing both modes costs nothing.
        if projected.count >= 2, touchTracker.mode == .idle || touchTracker.mode == .pending {
            touchMomentumTail.stop()
        }

        // Diagnostic: tally how each sequence with two or more fingers resolves
        // (see `CaptureTouchPipeline.twoFingerResolved*`). A lift with no prior
        // commit closes a sequence that never resolved to any gesture; the
        // intent switch below tallies the commits.
        if projected.isEmpty {
            if touchSequenceSawTwoFingers, !touchSequenceCommitted {
                TouchPipelineProbe.note { $0.twoFingerResolvedNone += 1 }
            }
            touchSequenceSawTwoFingers = false
            touchSequenceCommitted = false
            touchSequenceSawPinch = false
            touchSequenceSawRotate = false
            touchSequenceBothCounted = false
            touchOwnedPointerPosition = nil
            // Fingers lifted, so other devices may move the pointer next.
            lastDeltaOrigin = nil
        } else if projected.count >= 2 {
            touchSequenceSawTwoFingers = true
        }

        // Built only when a gesture needs it, to avoid a per-frame allocation.
        // Millimeters, not raw device units: the touch space is anisotropic
        // (the PTH-850 has about 12.6 units/mm in X and 20.2 in Y), so raw
        // units would skew the angle of a 45° finger pair and make a horizontal
        // span read narrower than a vertical one of the same size.
        var rawTouchPositionsMM: [Int: CGPoint] = [:]
        if snap.rotateEnabled || snap.twoFingerRightClick || snap.threeFingerDrag {
            rawTouchPositionsMM.reserveCapacity(filteredContacts.count)
            let mmPerUnitX = cachedTouchWidthMM / Double(cachedTouchMaxX)
            let mmPerUnitY = cachedTouchHeightMM / Double(cachedTouchMaxY)
            for c in filteredContacts {
                rawTouchPositionsMM[c.id] = CGPoint(x: Double(c.x) * mmPerUnitX, y: Double(c.y) * mmPerUnitY)
            }
        }

        let intent = touchTracker.process(
            contacts: projected,
            tapToClick: snap.tapToClick,
            twoFingerScroll: snap.twoFingerScroll,
            reverseScrollDirection: snap.reverseScrollDirection,
            sensitivity: snap.touchSensitivity,
            pinchZoom: snap.pinchZoomEnabled,
            twoFingerRightClick: snap.twoFingerRightClick,
            threeFingerDrag: snap.threeFingerDrag && !touchSequenceTainted,
            rotate: snap.rotateEnabled,
            rawPositions: rawTouchPositionsMM,
            touchDiagonal: hypot(cachedTouchWidthMM, cachedTouchHeightMM),
            absoluteTouch: cachedTouchIsDirect,
            onsetDelay: snap.touchOnsetDelay,
            tapStabilizationPt: snap.touchTapStabilizationPt,
            now: now)

        if touchTracker.scrollWoundDownThisFrame {
            TouchPipelineProbe.note { $0.scrollWindDowns += 1 }
        }


        noteOnsetLifecycle(now: now)
        handleTouchIntent(intent, snap: snap, settings: settings)
        if contacts.isEmpty {
            if let miss = touchTracker.threeFingerTapMiss {
                let reason = touchSequenceTainted ? "blocked" : miss
                TouchPipelineProbe.note { $0.threeFingerTapMisses = ($0.threeFingerTapMisses ?? [:]).merging([reason: 1], uniquingKeysWith: +) }
            }
            touchSequenceTainted = false
        }
    }

    /// The pen display's own screen, whatever the pen is mapped to. Falls back
    /// to the screen under the pen's mapping when no Wacom panel matches by
    /// name (non-Wacom pen displays, or two identical Cintiqs).
    private func touchPanelBounds(snap: InjectionSnapshot) -> CGRect {
        if touchPanelNeedsResolve {
            touchPanelNeedsResolve = false
            cachedTouchPanelBounds = DDCLink.wacomPanelDisplay(modelName: cachedTouchModelName)
                .map { CGDisplayBounds($0.id) }
        }
        if let panel = cachedTouchPanelBounds { return panel }
        let pen = displayMapper.displayBounds(for: snap)
        var id: CGDirectDisplayID = 0
        var found: UInt32 = 0
        guard CGGetDisplaysWithPoint(CGPoint(x: pen.midX, y: pen.midY), 1, &id, &found) == .success,
            found > 0
        else { return pen }
        return CGDisplayBounds(id)
    }

    /// Records that a pinch or rotate component opened its envelope this frame.
    /// A component can join partway through a sequence, which a per-frame
    /// "both present" test can't see. This feeds `twoFingerResolvedBoth` (the
    /// sequence ran both at once, which the single-component counters can't
    /// tell from two separate sequences) and `twoFingerLateJoins` (a `.began`
    /// arriving after the sequence had committed).
    func noteGestureComponentBegan(pinch: Bool) {
        if touchSequenceCommitted {
            TouchPipelineProbe.note { $0.twoFingerLateJoins += 1 }
        }
        touchSequenceCommitted = true
        if pinch { touchSequenceSawPinch = true } else { touchSequenceSawRotate = true }
        if touchSequenceSawPinch, touchSequenceSawRotate, !touchSequenceBothCounted {
            touchSequenceBothCounted = true
            TouchPipelineProbe.note { $0.twoFingerResolvedBoth += 1 }
        }
    }

    /// Folds this frame's `touchTracker.mode` into the onset-window counters.
    /// `.idle` → `.pending` starts a new sequence and its onset window. If the
    /// last sequence tore down less than `reArmWindow` ago, it's one
    /// interrupted drag paying the delay again. Also tracks the running
    /// single-contact drag duration for `longestSingleContactDragMs`. Call it on
    /// every `injectTouch` frame that advanced the tracker, the pen-busy
    /// wind-down included, so a teardown there isn't mistaken for a re-arm.
    func noteOnsetLifecycle(now: TimeInterval) {
        let mode = touchTracker.mode
        defer { prevTouchMode = mode }

        if prevTouchMode == .idle, mode == .pending {
            let reArmed = lastTouchTeardownTime != 0
                && now - lastTouchTeardownTime < CaptureTouchPipeline.reArmWindow
            TouchPipelineProbe.note {
                $0.onsetWindowsEntered += 1
                if reArmed { $0.onsetWindowsReArmedWithin += 1 }
            }
        }

        if prevTouchMode != .idle, mode == .idle {
            lastTouchTeardownTime = now
        }

        if mode == .pointer {
            if singleContactDragStart == 0 { singleContactDragStart = now }
            let ms = Int((now - singleContactDragStart) * 1000)
            TouchPipelineProbe.note {
                $0.longestSingleContactDragMs = Swift.max($0.longestSingleContactDragMs, ms)
            }
        } else {
            singleContactDragStart = 0
        }
    }

    /// Translates a resolved `Intent` into CGEvents. The per-frame path and
    /// `injectTouch`'s pen-arbitration branch share it; the branch feeds it a
    /// synthetic lift intent, so an open gesture phase always closes.
    private func handleTouchIntent(
        _ intent: TouchStateTracker.Intent,
        snap: InjectionSnapshot, settings: TabletSettings?
    ) {
        // The diagnostics count resolved intents, not posted CGEvents; the
        // post helpers below have their own failure paths.
        if touchSequenceTainted {
            switch intent {
            case .tapClick, .secondaryClick, .pointerMove, .pointerWarp:
                TouchPipelineProbe.note { $0.taintedActionsDropped = ($0.taintedActionsDropped ?? 0) + 1 }
                return
            default:
                break
            }
        }
        if touchSequenceSawPalm {
            TouchPipelineProbe.note {
                switch intent {
                case .pointerMove, .pointerWarp:
                    $0.palmSequencePointerMoves = ($0.palmSequencePointerMoves ?? 0) + 1
                case .tapClick, .secondaryClick:
                    $0.palmSequenceClicks = ($0.palmSequenceClicks ?? 0) + 1
                case .scrollDelta(_, _, .began):
                    $0.palmSequenceGestures = ($0.palmSequenceGestures ?? 0) + 1
                default:
                    break
                }
            }
        }
        switch intent {
        case .none:
            return
        case .pointerMove(let dx, let dy):
            TouchPipelineProbe.note { $0.pointerMoves += 1 }
            postTouchPointerMove(dx: dx, dy: dy)
        case .pointerWarp(let target):
            TouchPipelineProbe.note { $0.pointerMoves += 1 }
            touchOwnedPointerPosition = nil
            postTouchPointerWarp(to: target)
        case .scrollDelta(let dx, let dy, let phase):
            TouchPipelineProbe.note { $0.scrolls += 1 }
            if phase == .began {
                touchSequenceCommitted = true
                TouchPipelineProbe.note { $0.twoFingerResolvedPan += 1 }
                // A fresh two-finger scroll halts the previous gesture's coast,
                // as touching a real trackpad mid-momentum does.
                touchMomentumTail.cancel()
            }
            postTouchScroll(dx: dx, dy: dy, phase: phase)
            if phase == .ended, snap.twoFingerScrollMomentum {
                let raw = touchTracker.releaseVelocity
                let rawMag = hypot(raw.dx, raw.dy)
                // Clamp the seed here, not in `MomentumTail`, which
                // `panMomentumTail` shares and tunes separately. A tail travels
                // v²/(2·decel), so capping speed caps distance: 6000 pts/s is
                // about 3000 pts. Anything faster is a corrupted Bluetooth burst
                // sample (see `TouchStateTracker.minVelocityDt`) and reads as an
                // occasional runaway coast.
                let v: CGVector
                if rawMag > Self.touchMomentumMaxSeedVelocity {
                    let s = Self.touchMomentumMaxSeedVelocity / rawMag
                    v = CGVector(dx: raw.dx * s, dy: raw.dy * s)
                } else {
                    v = raw
                }
                let suppressedByRecency = touchTracker.releaseSuppressedByRecency
                touchMomentumTail.start(velocity: v)
                // `start()` cancels first, so `isRunning` afterward means this
                // release started a tail.
                let started = touchMomentumTail.isRunning
                let frameGap = touchTracker.releaseFrameGap
                let motionGap = touchTracker.releaseMotionGap
                TouchPipelineProbe.note {
                    $0.maxReleaseVelocity = Swift.max($0.maxReleaseVelocity, rawMag)
                    $0.noteReleaseGaps(frameGap: frameGap, motionGap: motionGap)
                    if started {
                        $0.momentumTailStarts += 1
                    } else if suppressedByRecency {
                        $0.momentumSuppressedStale += 1
                    } else {
                        $0.momentumSuppressedSlow += 1
                    }
                }
            }
        case .twoFingerGesture(let magnify, let rotateGesture):
            if touchSequenceSawPalm,
               magnify?.phase == .began || rotateGesture?.phase == .began {
                TouchPipelineProbe.note { $0.palmSequenceGestures = ($0.palmSequenceGestures ?? 0) + 1 }
            }
            // Either or both components can be present, since a real trackpad
            // can magnify and rotate at once (see
            // `TouchStateTracker.TwoFingerKind`), so this posts up to two
            // CGEvents in one frame.
            if let magnify {
                TouchPipelineProbe.note { $0.zooms += 1 }
                if magnify.phase == .began {
                    noteGestureComponentBegan(pinch: true)
                    TouchPipelineProbe.note { $0.twoFingerResolvedPinch += 1 }
                }
                postTouchMagnify(magnification: magnify.value, phase: magnify.phase)
            }
            if let rotateGesture {
                TouchPipelineProbe.note { $0.rotates += 1 }
                if rotateGesture.phase == .began {
                    noteGestureComponentBegan(pinch: false)
                    TouchPipelineProbe.note { $0.twoFingerResolvedRotate += 1 }
                }
                postTouchRotate(rotation: rotateGesture.value, phase: rotateGesture.phase)
            }
        case .tapClick:
            touchOwnedPointerPosition = nil
            TouchPipelineProbe.note { $0.taps += 1 }
            postTouchTapClick(snapshot: snap, settings: settings)
        case .secondaryClick:
            touchOwnedPointerPosition = nil
            TouchPipelineProbe.note { $0.taps += 1 }
            postTouchSecondaryClick(snapshot: snap)
        case .dragDown(let at):
            touchOwnedPointerPosition = nil
            let loc = at.map { pinTouchPoint($0, snapshot: snap) } ?? currentCursorPosition()
            TouchPipelineProbe.note { $0.threeFingerDrags = ($0.threeFingerDrags ?? 0) + 1 }
            postMouseDown(button: .left, at: loc, pressure: 1.0, clickCount: 1, snapshot: snap)
            touchDragPosition = loc
        case .dragMove(let dx, let dy):
            guard let base = touchDragPosition else { return }
            postTouchDrag(to: CGPoint(x: base.x + dx, y: base.y + dy), snapshot: snap)
        case .dragWarp(let target):
            guard touchDragPosition != nil else { return }
            postTouchDrag(to: target, snapshot: snap)
        case .dragUp:
            releaseTouchDrag(snapshot: snap)
        }
    }

    /// Relative motion accumulates on an owned float position, never on a
    /// per-frame OS readback. At about 100 Hz the readback races WindowServer's
    /// commit of the previous post, so consecutive frames add their deltas to
    /// the same stale base and only the last lands, and slow sweeps fall short
    /// of the screen edge (issue #13). `DisplayMapper.ownedRelativePosition`
    /// does the same for pen relative mode. The first move of a sequence seeds
    /// it from the OS, and anything else that moves the cursor clears it: a
    /// sequence end, pen priority, an absolute warp, or a tap. Pinning here as
    /// well keeps the owned copy from running off-screen and needing to catch
    /// up on reversal.
    private func postTouchPointerMove(dx: Double, dy: Double) {
        let base = touchOwnedPointerPosition ?? currentCursorPosition()
        var target = CGPoint(x: base.x + dx, y: base.y + dy)
        if let snap = injectionSnapshot {
            target = pinTouchPoint(target, snapshot: snap)
        }
        touchOwnedPointerPosition = target
        postTouchPointerWarp(to: target)
    }

    /// Both touch pointer intents end here. `.pointerMove` (relative) resolves
    /// its delta to an absolute target first; `.pointerWarp` (absolute) already
    /// has one from `TouchStateTracker.screenPoint`. Edge pinning runs either
    /// way: it changes nothing in bounds and protects against a mapping edge
    /// case just outside.
    private func postTouchPointerWarp(to point: CGPoint) {
        var target = point
        if let snap = injectionSnapshot {
            target = pinTouchPoint(target, snapshot: snap)
        }
        guard let e = CGEvent(
            mouseEventSource: sessionSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: target,
            mouseButton: .left)
        else { return }
        stampMouseDelta(e, to: target)
        e.flags = moveSafeEventFlags
        finalizeAndPost(e)
    }

    /// Always phased, like Pan View's `postPanScroll`, whatever the Momentum
    /// setting, which only adds the coast. Phase-free events stay with the last
    /// view that scrolled until a pause, so a scroll couldn't move from a
    /// column to the Finder's browser.
    private func postTouchScroll(dx: Double, dy: Double, phase: TouchStateTracker.ScrollPhase) {
        // Read once: the wheel event and its companion gesture event describe
        // the same instant.
        let loc = currentCursorPosition()
        // A real trackpad posts a gesture-scroll companion alongside the wheel
        // event, and apps with their own gesture-scroll physics key off it
        // instead of, or besides, the wheel event. It posts first here because
        // the other order stuttered, though a real trackpad posts the wheel
        // first.
        postTouchScrollGesture(dx: dx, dy: dy, phase: phase, location: loc)
        // Pixel units plus the phase field make apps treat the stream as a
        // trackpad scroll (smooth, with rubber-banding), not discrete wheel ticks.
        guard let e = CGEvent(
            scrollWheelEvent2Source: sessionSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(dy.rounded()),
            wheel2: Int32(dx.rounded()),
            wheel3: 0)
        else { return }
        e.location = loc
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        applyTrackpadDeltaFields(e, dx: dx, dy: dy)
        e.flags = moveSafeEventFlags
        finalizeAndPost(e)
    }

    /// Companion to `postTouchScroll`. It uses `postTouchMagnify`'s technique
    /// with the scroll subtype, carrying the gesture delta directly. The
    /// momentum tail doesn't send it: a real trackpad's momentum stream is
    /// wheel events only, and this accompanies a live, phased gesture.
    private func postTouchScrollGesture(
        dx: Double, dy: Double, phase: TouchStateTracker.ScrollPhase, location: CGPoint
    ) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = Self.nsEventTypeGesture
        e.location = location
        e.setIntegerValueField(Self.fieldIOHIDEventSubtype, value: Self.iohidEventTypeScroll)
        e.setIntegerValueField(Self.fieldGesturePhase, value: Int64(phase.rawValue))
        e.setDoubleValueField(Self.fieldGestureDeltaX, value: dx)
        e.setDoubleValueField(Self.fieldGestureDeltaY, value: dy)
        finalizeAndPost(e)
    }

    /// Pinch-zoom: a synthesized magnify gesture, phased like `postTouchScroll`.
    /// It needs no entitlement. Setting a CGEvent's real type (`.type`, not a
    /// field) to 29 (`NSEventTypeGesture`) plus a few undocumented but public
    /// integer and double fields makes the OS treat it as a genuine trackpad
    /// pinch. The open-source Mac Mouse Fix project uses the same technique
    /// (`TouchSimulator.m`), which traces back to CalfTrail Touch and
    /// SensibleSideButtons. This is an independent reimplementation, not a
    /// copy: Mac Mouse Fix ships under a source-available, non-GPL license.
    /// Not `private`: ring and dial `.zoom` actions (`postRingGesture` in
    /// +CGEvents.swift) call it too, with a different envelope source.
    func postTouchMagnify(magnification: Double, phase: TouchStateTracker.ScrollPhase) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = Self.nsEventTypeGesture
        e.location = currentCursorPosition()
        e.setIntegerValueField(Self.fieldIOHIDEventSubtype, value: Self.iohidEventTypeZoom)
        e.setIntegerValueField(Self.fieldGesturePhase, value: Int64(phase.rawValue))
        e.setDoubleValueField(Self.fieldMagnification, value: magnification)
        finalizeAndPost(e)
    }

    /// Rotate: a synthesized rotation gesture, phased like `postTouchMagnify`,
    /// with the same technique and provenance. The subtype and rotation field
    /// come from Mac Mouse Fix's `postRotationEventWithRotation:phase:`.
    ///
    /// `TouchStateTracker` passes radians; this converts to degrees, assuming
    /// the field takes what `NSEvent.rotation` documents. Rotation feels right
    /// in use, so the scale is roughly correct, but nothing documents the
    /// field's unit and the magnitude is unmeasured.
    /// Not `private`: ring and dial `.rotate` actions (`postRingGesture` in
    /// +CGEvents.swift) call it too, with a different envelope source.
    func postTouchRotate(rotation: Double, phase: TouchStateTracker.ScrollPhase) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = Self.nsEventTypeGesture
        e.location = currentCursorPosition()
        e.setIntegerValueField(Self.fieldIOHIDEventSubtype, value: Self.iohidEventTypeRotation)
        e.setIntegerValueField(Self.fieldGesturePhase, value: Int64(phase.rawValue))
        e.setDoubleValueField(Self.fieldRotation, value: rotation * 180.0 / .pi)
        finalizeAndPost(e)
    }

    /// Upper bound on the touch momentum seed velocity (points/second). A tail
    /// travels v²/(2·`MomentumTail.deceleration`), so this caps the coast near
    /// 3000 points: a hard flick, not the screen-clearing runaway a corrupted
    /// burst sample would produce. It applies here, not in `MomentumTail`,
    /// which `panMomentumTail` shares and tunes separately.
    static let touchMomentumMaxSeedVelocity: Double = 6000

    /// Undocumented CGEvent type and field numbers for gesture synthesis (see
    /// `postTouchMagnify` for provenance and the license note). The scroll
    /// subtype's `fieldGestureDeltaX/Y` and `iohidEventTypeScroll` come from
    /// Mac Mouse Fix's `GestureScrollSimulator.m`.
    private static let nsEventTypeGesture = CGEventType(rawValue: 29)!
    private static let fieldIOHIDEventSubtype = CGEventField(rawValue: 110)!
    private static let fieldMagnification = CGEventField(rawValue: 113)!
    private static let fieldRotation = CGEventField(rawValue: 114)!
    private static let fieldGestureDeltaX = CGEventField(rawValue: 116)!
    private static let fieldGestureDeltaY = CGEventField(rawValue: 119)!
    private static let fieldGesturePhase = CGEventField(rawValue: 132)!
    private static let iohidEventTypeRotation: Int64 = 5
    private static let iohidEventTypeScroll: Int64 = 6
    private static let iohidEventTypeZoom: Int64 = 8

    private func postTouchTapClick(snapshot: InjectionSnapshot, settings: TabletSettings?) {
        let loc = currentCursorPosition()
        let (clickPt, count) = resolveClick(loc, snapshot: snapshot)
        postMouseDown(
            button: .left, at: clickPt, pressure: 1.0, clickCount: count, snapshot: snapshot)
        postMouseUp(button: .left, at: clickPt, clickCount: count, snapshot: snapshot)
    }

    /// Palm diagnostics: once per contact, how far a contact that got past
    /// palm rejection sat from the nearest rejected one. Cleared when the
    /// next sequence starts, not at lift, so the lift's own tap still counts.
    func notePalmNeighbors(
        contacts: [TouchContact], acceptedIDs: Set<Int>
    ) {
        guard !contacts.isEmpty else { return }
        if touchTracker.mode == .idle {
            touchSequenceSawPalm = false
            palmNeighborMeasuredIDs.removeAll(keepingCapacity: true)
        }
        let palms = contacts.filter { !acceptedIDs.contains($0.id) }
        guard !palms.isEmpty else { return }
        if !touchSequenceSawPalm {
            touchSequenceSawPalm = true
            TouchPipelineProbe.note { $0.palmSequences = ($0.palmSequences ?? 0) + 1 }
        }
        guard cachedTouchMaxX > 0, cachedTouchMaxY > 0, cachedTouchWidthMM > 0 else { return }
        let mmX = cachedTouchWidthMM / Double(cachedTouchMaxX)
        let mmY = cachedTouchHeightMM / Double(cachedTouchMaxY)
        for c in contacts where acceptedIDs.contains(c.id) && !palmNeighborMeasuredIDs.contains(c.id) {
            palmNeighborMeasuredIDs.insert(c.id)
            let nearest = palms.map {
                hypot(Double(c.x - $0.x) * mmX, Double(c.y - $0.y) * mmY)
            }.min() ?? .infinity
            let size = [c.contactArea, c.contactMinor].compactMap { $0 }.max()
            TouchPipelineProbe.note { $0.notePalmNeighbor(mm: nearest, size: size) }
        }
    }

    /// Absolute touch follows the pen's mapping; relative touch roams the
    /// whole desktop, like a trackpad.
    private func pinTouchPoint(_ p: CGPoint, snapshot: InjectionSnapshot) -> CGPoint {
        cachedTouchIsDirect
            ? displayMapper.pinNearEdges(p, snapshot: snapshot)
            : displayMapper.pinNearDesktopEdges(p)
    }

    private func postTouchDrag(to point: CGPoint, snapshot: InjectionSnapshot) {
        let target = pinTouchPoint(point, snapshot: snapshot)
        postMouseDrag(button: .left, at: target, pressure: 1.0, pose: (0, 0, 0), snapshot: snapshot)
        touchDragPosition = target
    }

    /// Ends a three-finger drag. Every path that can strand the held button
    /// calls this: the lift, the pen arriving, touch turned off, tool change
    /// or disconnect, and the leak watchdog.
    func releaseTouchDrag(snapshot: InjectionSnapshot) {
        guard let loc = touchDragPosition else { return }
        touchDragPosition = nil
        postMouseUp(button: .left, at: loc, clickCount: 1, snapshot: snapshot)
    }

    private func postTouchSecondaryClick(snapshot: InjectionSnapshot) {
        let loc = currentCursorPosition()
        postMouseDown(button: .right, at: loc, pressure: 1.0, clickCount: 1, snapshot: snapshot)
        postMouseUp(button: .right, at: loc, clickCount: 1, snapshot: snapshot)
    }
}
