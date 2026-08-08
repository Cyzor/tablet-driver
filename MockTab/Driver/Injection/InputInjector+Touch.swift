// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import os
import TabletKit

// Capacitive finger-touch injection, split out of InputInjector.swift. The
// per-sequence touch state it reads (`touchTracker`, `cachedTouch*`,
// `penProximityExitTime`) lives on the main class body — Swift class
// extensions can't hold stored properties — and stays HIDThread-confined
// exactly as documented there.
extension InputInjector {

    /// Inject a touch contact frame.
    ///
    /// Behaviour:
    ///   • `touchEnabled == false` → no-op.
    ///   • Pen in proximity, or pen lifted within `touchArbitrationGrace`
    ///     → drop the frame (and reset tracker so a stale gesture mid-touch
    ///     doesn't persist when the pen interrupts).
    ///   • Otherwise project each contact through the user's touch-area
    ///     mapping into screen-space, hand to `TouchStateTracker`, and
    ///     translate its `Intent` into CGEvents:
    ///       - `.pointerMove`   → `mouseMoved`
    ///       - `.scrollDelta`   → smooth scroll-wheel event with phase
    ///       - `.zoomMagnify`   → synthesized magnify gesture with phase
    ///       - `.tapClick`      → left-click at the current cursor position
    ///
    /// No shipping decoder produces touch frames yet; this is hot-path
    /// plumbing for when a per-family touch decoder lands.
    func injectTouch(contacts: [TouchContact], settings: TabletSettings?) {
        rearmWatchdog()
        guard let snap = injectionSnapshot, snap.touchEnabled else { return }

        // Cache touch coordinate maximums per device.  Without this, the
        // registry lookup (linear scan over ~80 specs) ran on every HID
        // frame — at 100 Hz with a palm on the tablet, that alone was a
        // measurable CPU contributor.  (Before the arbitration gate because
        // palm classification needs the maximums.)
        if cachedTouchSpecPID != deviceProductID {
            let spec = WacomDeviceRegistry.spec(for: deviceProductID)
            cachedTouchMaxX = Swift.max(1, spec?.touchMaxX ?? 1)
            cachedTouchMaxY = Swift.max(1, spec?.touchMaxY ?? 1)
            // Falls back to the raw maximums (no correction) when the spec
            // has no physical size — see `cachedTouchWidthMM`'s doc comment.
            cachedTouchWidthMM = spec?.activeWidthMM ?? Double(cachedTouchMaxX)
            cachedTouchHeightMM = spec?.activeHeightMM ?? Double(cachedTouchMaxY)
            cachedTouchSpecPID = deviceProductID
        }

        // Pen arbitration: pen takes priority.  Drop frames and reset tracker
        // so a half-formed gesture doesn't resume after the pen lifts.
        //
        // An iPad-style "scroll while the pen is in use" mode was prototyped
        // and removed (2026-06): firmware does stream touch with the pen busy,
        // but palm rejection wasn't shippable — scrolls died mid-gesture and
        // per-app event arbitration was inconsistent.  Git history has the
        // prototype if another attempt is ever made.
        let now = CFAbsoluteTimeGetCurrent()
        let penBusy = lastProximity ||
            now - penProximityExitTime < Self.touchArbitrationGrace
        if penBusy {
            touchPalmRejector.reset()
            if !contacts.isEmpty {
                _ = touchTracker.process(
                    contacts: [], tapToClick: false, twoFingerScroll: false,
                    reverseScrollDirection: false, sensitivity: 1.0,
                    pinchZoom: false, now: now)
            }
            return
        }

        // Palm classification must happen before projection and gesture
        // tracking. On the IntuosV2 touch family it preserves a simultaneous
        // normal finger while dropping only the palm-sized contact; other
        // tablets pass through unchanged until they have their own
        // calibrated thresholds.
        let filtered = touchPalmRejector.filter(
            contacts: contacts.map {
                (id: $0.id, major: $0.contactArea, minor: $0.contactMinor)
            },
            productID: deviceProductID)
        let filteredContacts = contacts.filter { filtered.acceptedIDs.contains($0.id) }
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

        // Resolve display bounds — touch shares the pen's target display.
        let displayBounds = displayMapper.displayBounds(for: snap)

        // Project each contact to screen-space using the touch-area mapping.
        // Contacts whose raw position falls outside the crop rect return nil
        // and are dropped entirely (no clamping to the rect edge — that would
        // leave the deadzone partially responsive).
        var projected: [(id: Int, screen: CGPoint)] = []
        projected.reserveCapacity(filteredContacts.count)
        for c in filteredContacts {
            guard let p = TouchStateTracker.screenPoint(
                for: c, maxX: cachedTouchMaxX, maxY: cachedTouchMaxY,
                areaX: snap.touchAreaX, areaY: snap.touchAreaY,
                areaWidth: snap.touchAreaWidth, areaHeight: snap.touchAreaHeight,
                displayBounds: displayBounds)
            else { continue }
            projected.append((id: c.id, screen: p))
        }

        // A real trackpad stops a coasting flick the instant two fingers land
        // on the surface — before any gesture is even recognized, like
        // grabbing a spinning wheel. Gating the cancel behind the tracker's
        // resolved intent (as happens naturally below) instead requires
        // motion past the pinch/pan discrimination threshold first, which
        // reads as needing a "nudge" to arrest the coast. Cancel on the raw
        // idle-to-two-contacts transition instead. Requires *two* fingers,
        // not one — an ordinary single-finger pointer move shouldn't stop a
        // coast the user never touched.
        //
        // `.pending` counts as well as `.idle`: process()'s idle branch returns
        // early on the first contact of any sequence, so `.idle` -> `.pending`
        // always burns a frame and `.idle` only still holds here when both
        // fingers landed in the very same HID frame. A landing split across two
        // frames — the common case at report rate, and guaranteed whenever palm
        // filtering drops a contact on the first one — would otherwise never
        // arrest the coast at all. MomentumTail.stop() no-ops when no tail is
        // in flight, so testing both modes is free.
        if projected.count >= 2, touchTracker.mode == .idle || touchTracker.mode == .pending {
            touchMomentumTail.stop()
        }

        // Only built when Rotate is on — the raw-position dictionary would
        // otherwise allocate on every frame for no reason. Converted to
        // millimeters, not left in raw device units: the touch coordinate
        // space is anisotropic (e.g. the PTH-850 is ~12.6 units/mm in X vs
        // ~20.2 in Y), so a raw-unit separation gate would read a 45°
        // physical finger pair as a different angle and a horizontally-held
        // span as narrower than a vertically-held one of the same physical
        // size. mm is the only unit where "how far apart are the fingers,
        // physically" means the same thing regardless of axis.
        var rawTouchPositionsMM: [Int: CGPoint] = [:]
        if snap.rotateEnabled {
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
            smartZoom: snap.smartZoomEnabled,
            rotate: snap.rotateEnabled,
            rawPositions: rawTouchPositionsMM,
            touchDiagonal: hypot(cachedTouchWidthMM, cachedTouchHeightMM),
            now: now)

        switch intent {
        case .none:
            return
        case .pointerMove(let dx, let dy):
            postTouchPointerMove(dx: dx, dy: dy)
        case .scrollDelta(let dx, let dy, let phase):
            if phase == .began {
                // A fresh two-finger scroll halts any coasting tail from the
                // previous gesture, same as touching a real trackpad mid-momentum.
                touchMomentumTail.cancel()
            }
            postTouchScroll(
                dx: dx, dy: dy, phase: phase,
                usePhases: snap.twoFingerScrollMomentum)
            if phase == .ended, snap.twoFingerScrollMomentum {
                touchMomentumTail.start(velocity: touchTracker.releaseVelocity)
            }
        case .zoomMagnify(let magnification, let phase):
            postTouchMagnify(magnification: magnification, phase: phase)
        case .smartZoom:
            postTouchSmartZoom()
        case .rotate(let rotation, let phase):
            postTouchRotate(rotation: rotation, phase: phase)
        case .tapClick:
            postTouchTapClick(snapshot: snap, settings: settings)
        }
    }

    private func postTouchPointerMove(dx: Double, dy: Double) {
        let loc = currentCursorPosition()
        var target = CGPoint(x: loc.x + dx, y: loc.y + dy)
        if let snap = injectionSnapshot {
            target = Self.pinNearScreenEdges(target, in: displayMapper.displayBounds(for: snap))
        }
        guard let e = CGEvent(
            mouseEventSource: sessionSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: target,
            mouseButton: .left)
        else { return }
        e.flags = moveSafeEventFlags
        finalizeAndPost(e)
    }

    /// Mirrors Pan View's `panScrollUsePhases`/`postPanScroll` split — same
    /// on/off meaning, same tradeoff. `usePhases == false` drops the phase
    /// field entirely (phase-free stream), on the theory that some gesture
    /// recognizers reject a phased envelope without genuine trackpad gesture
    /// backing — same failure class as Pan View's Calendar/WebKit cases.
    /// Zero-delta Began/Ended brackets exist only to open/close the phase
    /// envelope, so they're dropped as no-ops in that mode too.
    private func postTouchScroll(
        dx: Double, dy: Double, phase: TouchStateTracker.ScrollPhase,
        usePhases: Bool
    ) {
        if !usePhases, dx == 0, dy == 0 { return }
        // A real trackpad driver posts a gesture-scroll companion event
        // alongside the wheel event; apps that build their own gesture-scroll
        // physics (rather than relying on NSScrollView's free coast) key off
        // this stream instead of — or in addition to — the wheel event. Post
        // it first: posting the wheel event after it (not before) is what a
        // real trackpad's ordering looks like and avoids a stutter seen when
        // ordered the other way. Only meaningful with a real phase.
        if usePhases {
            postTouchScrollGesture(dx: dx, dy: dy, phase: phase)
        }
        let loc = currentCursorPosition()
        // .pixel units + the scroll-phase field is what makes apps treat the
        // stream as a trackpad scroll (smooth, with rubber-banding) rather
        // than a discrete wheel-tick scroll.
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
        if usePhases {
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        applyTrackpadDeltaFields(e, dx: dx, dy: dy)
        e.flags = moveSafeEventFlags
        finalizeAndPost(e)
    }

    /// Companion to `postTouchScroll` — same synthesized-gesture technique as
    /// `postTouchMagnify` (`nsEventTypeGesture`/`fieldIOHIDEventSubtype`/
    /// `fieldGesturePhase`, all reused from there), but subtype
    /// `kIOHIDEventTypeScroll` instead of zoom, carrying the gesture delta
    /// directly rather than a magnification factor. Not sent during the
    /// momentum tail — a real trackpad's momentum stream is wheel-event only,
    /// this event only accompanies a live, phase-bracketed gesture.
    private func postTouchScrollGesture(dx: Double, dy: Double, phase: TouchStateTracker.ScrollPhase) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = Self.nsEventTypeGesture
        e.location = currentCursorPosition()
        e.setIntegerValueField(Self.fieldIOHIDEventSubtype, value: Self.iohidEventTypeScroll)
        e.setIntegerValueField(Self.fieldGesturePhase, value: Int64(phase.rawValue))
        e.setDoubleValueField(Self.fieldGestureDeltaX, value: dx)
        e.setDoubleValueField(Self.fieldGestureDeltaY, value: dy)
        finalizeAndPost(e)
    }

    /// Pinch-zoom: a real synthesized magnify gesture, phase-bracketed like
    /// `postTouchScroll`. A ⌘+wheel stand-in and, after that failed hardware
    /// testing, a ⌘+Keypad-Plus/Minus keystroke stand-in were both tried and
    /// hardware-verified working (see git history) before this — the
    /// keystroke form reached Preview, Safari, and Chromium/Firefox browsers,
    /// but only as discrete menu-command steps, and every mechanism was
    /// believed to require a private, Apple-only entitlement for anything
    /// smoother, matching a previously closed investigation into synthesizing
    /// native gestures.
    ///
    /// That turned out to be wrong. The technique below needs no entitlement
    /// at all — a CGEvent's *real* type (`.type`, not a field) set to 29
    /// (`NSEventTypeGesture`) plus a few undocumented-but-public integer/
    /// double fields is enough for the OS to treat it exactly like a genuine
    /// trackpad pinch. Traced independently on hardware to confirm it wasn't
    /// a fluke; the same technique (undocumented CGEvent fields, no private
    /// API) is used in production by the open-source Mac Mouse Fix project
    /// (github.com/noah-nuebling/mac-mouse-fix, Helper/Core/Touch/
    /// TouchSimulator.m), which traces it further back to CalfTrail Touch /
    /// SensibleSideButtons reverse-engineering work. Reimplemented
    /// independently here, not copied — MMF ships under a source-available,
    /// non-GPL license.
    private func postTouchMagnify(magnification: Double, phase: TouchStateTracker.ScrollPhase) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = Self.nsEventTypeGesture
        e.location = currentCursorPosition()
        e.setIntegerValueField(Self.fieldIOHIDEventSubtype, value: Self.iohidEventTypeZoom)
        e.setIntegerValueField(Self.fieldGesturePhase, value: Int64(phase.rawValue))
        e.setDoubleValueField(Self.fieldMagnification, value: magnification)
        finalizeAndPost(e)
    }

    /// Smart Zoom: two-finger double-tap, posted as a single one-shot event —
    /// no phase envelope, unlike `postTouchMagnify`. Same technique and
    /// provenance (see that function's doc comment); subtype sourced from
    /// Mac Mouse Fix's `postSmartZoomEvent` (`TouchSimulator.m`), which sets
    /// no fields beyond type and subtype.
    private func postTouchSmartZoom() {
        guard let e = CGEvent(source: nil) else { return }
        e.type = Self.nsEventTypeGesture
        e.location = currentCursorPosition()
        e.setIntegerValueField(Self.fieldIOHIDEventSubtype, value: Self.iohidEventTypeZoomToggle)
        finalizeAndPost(e)
    }

    /// Rotate: a synthesized rotation gesture, phase-bracketed like
    /// `postTouchMagnify`. Same technique and provenance (see that
    /// function's doc comment); subtype and rotation field sourced from Mac
    /// Mouse Fix's `postRotationEventWithRotation:phase:` (`TouchSimulator.m`).
    ///
    /// Unit: `TouchStateTracker` hands this function radians (natural for
    /// its internal `atan2` math); converted here to degrees on the
    /// assumption the field expects what `NSEvent.rotation` — the public API
    /// apps actually read a real trackpad rotation through — documents.
    /// Hardware feedback 2026-08-08: rotate is responsive when it engages,
    /// which is consistent with this scaling being roughly right (a 57×
    /// unit error would have been obvious as "nothing happens" or "spins
    /// wildly"), but that's corroborating evidence, not a controlled
    /// measurement — MMF's own source never states what its `rotation`
    /// parameter's unit actually is. Direction was independently confirmed
    /// wrong and fixed at the source (see `TouchStateTracker`'s `.rotate`
    /// case doc comment); magnitude scaling has not had the same scrutiny.
    private func postTouchRotate(rotation: Double, phase: TouchStateTracker.ScrollPhase) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = Self.nsEventTypeGesture
        e.location = currentCursorPosition()
        e.setIntegerValueField(Self.fieldIOHIDEventSubtype, value: Self.iohidEventTypeRotation)
        e.setIntegerValueField(Self.fieldGesturePhase, value: Int64(phase.rawValue))
        e.setDoubleValueField(Self.fieldRotation, value: rotation * 180.0 / .pi)
        finalizeAndPost(e)
    }

    /// Undocumented CGEvent type/field numbers for gesture synthesis —
    /// see `postTouchMagnify`'s doc comment for provenance and license note.
    /// `fieldGestureDeltaX/Y` and `iohidEventTypeScroll` are the scroll-
    /// subtype siblings of the zoom fields below, sourced from the same
    /// technique's use in Mac Mouse Fix's `GestureScrollSimulator.m`.
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
    private static let iohidEventTypeZoomToggle: Int64 = 22

    private func postTouchTapClick(snapshot: InjectionSnapshot, settings: TabletSettings?) {
        let loc = currentCursorPosition()
        let (clickPt, count) = resolveClick(loc, snapshot: snapshot)
        postMouseDown(
            button: .left, at: clickPt, pressure: 1.0, clickCount: count, snapshot: snapshot)
        postMouseUp(button: .left, at: clickPt, clickCount: count, snapshot: snapshot)
    }

    // MARK: - Touch scroll momentum tail

    /// Sole event-construction site for the touch-scroll momentum tail; the
    /// decay itself lives in `touchMomentumTail` (see MomentumTail.swift).
    ///
    /// `postTouchScroll`'s phased began/changed/ended stream is enough for
    /// `NSScrollView` apps to synthesize their own coast, but apps that read
    /// gesture-scroll deltas directly and build their own physics (Safari,
    /// Firefox, Affinity — confirmed by hardware test 2026-08-05) never see
    /// one, because `CGEventPost` carries no real trackpad hardware behind it
    /// to generate a `kCGMomentumScrollPhase` stream.
    func postTouchScrollMomentum(dx: Double, dy: Double, phase: MomentumPhase) {
        guard
            let e = CGEvent(
                scrollWheelEvent2Source: sessionSource,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(dy),
                wheel2: Int32(dx),
                wheel3: 0)
        else { return }
        e.location = currentCursorPosition()
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: phase.rawValue)
        applyTrackpadDeltaFields(e, dx: dx, dy: dy)
        e.flags = moveSafeEventFlags
        finalizeAndPost(e)
    }
}
