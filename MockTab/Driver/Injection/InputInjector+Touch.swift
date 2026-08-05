// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
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
    ///       - `.pointerMove` → `mouseMoved`
    ///       - `.scrollDelta` → smooth scroll-wheel event with phase
    ///       - `.zoomStep`    → ⌘+Keypad-Plus/Minus keystrokes (pinch stand-in)
    ///       - `.tapClick`    → left-click at the current cursor position
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
            if !contacts.isEmpty {
                _ = touchTracker.process(
                    contacts: [], tapToClick: false, twoFingerScroll: false,
                    reverseScrollDirection: false, sensitivity: 1.0,
                    pinchZoom: false, now: now)
            }
            return
        }

        // Resolve display bounds — touch shares the pen's target display.
        let displayBounds = displayMapper.displayBounds(for: snap)

        // Project each contact to screen-space using the touch-area mapping.
        // Contacts whose raw position falls outside the crop rect return nil
        // and are dropped entirely (no clamping to the rect edge — that would
        // leave the deadzone partially responsive).
        var projected: [(id: Int, screen: CGPoint)] = []
        projected.reserveCapacity(contacts.count)
        for c in contacts {
            guard let p = TouchStateTracker.screenPoint(
                for: c, maxX: cachedTouchMaxX, maxY: cachedTouchMaxY,
                areaX: snap.touchAreaX, areaY: snap.touchAreaY,
                areaWidth: snap.touchAreaWidth, areaHeight: snap.touchAreaHeight,
                displayBounds: displayBounds)
            else { continue }
            projected.append((id: c.id, screen: p))
        }

        let intent = touchTracker.process(
            contacts: projected,
            tapToClick: snap.tapToClick,
            twoFingerScroll: snap.twoFingerScroll,
            reverseScrollDirection: snap.reverseScrollDirection,
            sensitivity: snap.touchSensitivity,
            pinchZoom: snap.pinchZoomEnabled,
            now: now)

        switch intent {
        case .none:
            return
        case .pointerMove(let dx, let dy):
            postTouchPointerMove(dx: dx, dy: dy)
        case .scrollDelta(let dx, let dy, let phase):
            postTouchScroll(
                dx: dx, dy: dy, phase: phase,
                usePhases: snap.twoFingerScrollMomentum)
        case .zoomStep(let count):
            postTouchZoom(count: count)
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
        e.flags = moveSafeEventFlags
        finalizeAndPost(e)
    }

    /// Pinch-zoom stand-in: ⌘+Keypad-Plus (zoom in) or ⌘+Keypad-Minus
    /// (zoom out) keystrokes, one per accumulated step. Matches Wacom's own
    /// documented fallback mapping for apps without native gesture support
    /// (their AppGestures.xml binds the same pinch gesture to ⌘+Keypad-Plus/
    /// Minus when their primary Opt+F15/F16 path — which relies on
    /// per-app menu key-equivalent overrides we don't install — isn't
    /// available). The keypad location is deliberate, not incidental: unlike
    /// the row-1 =/- keys, keypad positions produce the same +/- characters
    /// across keyboard layouts, so this doesn't share the German-layout
    /// failure a row-1-based version would have.
    ///
    /// A CGEvent scroll-wheel stand-in (⌃+wheel, then ⌘+wheel) was tried
    /// first and hardware-tested across Preview, Safari, Chrome, Edge,
    /// Vivaldi, and Firefox: it never worked reliably outside one browser,
    /// and even there only matched the choppiness of a real Cmd+wheel zoom.
    /// This keystroke form reached every one of those apps.
    private func postTouchZoom(count: Int) {
        guard count != 0 else { return }
        // kVK_ANSI_KeypadPlus = 0x45 (69), kVK_ANSI_KeypadMinus = 0x4E (78).
        let keyCode: CGKeyCode = count > 0 ? 69 : 78
        for _ in 0..<abs(count) {
            postZoomKeystroke(keyCode: keyCode)
        }
    }

    private func postZoomKeystroke(keyCode: CGKeyCode) {
        // Real keyboards bracket a modified keystroke with flagsChanged
        // events; see the keyCombo binding path for why that matters to
        // some apps' modifier tracking.
        let flagsDown = CGEvent(source: sessionSource)
        flagsDown?.type = .flagsChanged
        flagsDown?.flags = moveSafeEventFlags.union(.maskCommand)
        flagsDown?.setIntegerValueField(.keyboardEventKeycode, value: 55) // ⌘
        if let e = flagsDown { finalizeAndPost(e) }

        guard let keyDown = CGEvent(
            keyboardEventSource: sessionSource, virtualKey: keyCode, keyDown: true)
        else { return }
        keyDown.flags = moveSafeEventFlags.union(.maskCommand)
        finalizeAndPost(keyDown)

        guard let keyUp = CGEvent(
            keyboardEventSource: sessionSource, virtualKey: keyCode, keyDown: false)
        else { return }
        keyUp.flags = moveSafeEventFlags.union(.maskCommand)
        finalizeAndPost(keyUp)

        let flagsUp = CGEvent(source: sessionSource)
        flagsUp?.type = .flagsChanged
        flagsUp?.flags = moveSafeEventFlags
        flagsUp?.setIntegerValueField(.keyboardEventKeycode, value: 55)
        if let e = flagsUp { finalizeAndPost(e) }
    }

    private func postTouchTapClick(snapshot: InjectionSnapshot, settings: TabletSettings?) {
        let loc = currentCursorPosition()
        let (clickPt, count) = resolveClick(loc, snapshot: snapshot)
        postMouseDown(
            button: .left, at: clickPt, pressure: 1.0, clickCount: count, snapshot: snapshot)
        postMouseUp(button: .left, at: clickPt, clickCount: count, snapshot: snapshot)
    }
}
