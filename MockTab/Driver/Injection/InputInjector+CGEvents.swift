// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import os
import TabletKit

// The CGEvent posting layer, split out of InputInjector.swift: modifier
// reconciliation, the mouse/tablet/proximity event constructors, button-
// binding execution, and scroll/ring dispatch. The synthetic-modifier state
// these read and the shared event source live on the main class body (Swift
// class extensions can't hold stored properties) and stay HIDThread-confined
// exactly as documented there.
extension InputInjector {

    // MARK: - Mouse event helpers

    /// Full modifier flags for state-change events (down/up/click/scroll/flagsChanged).
    ///
    /// Combines physical modifier state with synthetic modifiers from tablet button bindings.
    /// For managed bits (⌘⌥⇧⌃), uses `tapLastPhysicalFlags` rather than reading
    /// `hidSystemState` directly.  `hidSystemState` does not update atomically after posting
    /// events (see OTD PR #4014) — it can lag by one or more run-loop cycles, causing stale
    /// managed bits to re-appear in the next outbound event.  `tapLastPhysicalFlags` is set
    /// inside the flagsChanged session tap, at the exact moment the OS delivers the change to
    /// apps, making it the freshest available physical-state source for managed bits.
    /// Non-managed bits (capslock, numlock, fn …) continue to come from `hidSystemState`.
    /// Logs every transition in managed bits for diagnostics.
    var currentEventFlags: CGEventFlags {
        let result = CGEventFlags(rawValue: ModifierMath.currentEventFlags(
            systemFlags: CGEventSource.flagsState(.hidSystemState).rawValue,
            tapPhysicalManaged: tapLastPhysicalFlags,
            syntheticFlags: groundTruthSyntheticFlags.rawValue
                | SharedAuxModifierState.shared.groundTruthFlags.rawValue))
        let managedNow = result.rawValue & ModifierMath.managedMask
        if managedNow != lastLoggedManagedFlags {
            _ = groundTruthSyntheticFlags.rawValue & ModifierMath.managedMask
            _ = lastLoggedManagedFlags
            // modLog.info("flags: 0x\(String(prev, radix: 16), privacy: .public) → 0x\(String(managedNow, radix: 16), privacy: .public) [hid=0x\(String(physManaged, radix: 16), privacy: .public) synth=0x\(String(synth, radix: 16), privacy: .public)]")
            lastLoggedManagedFlags = managedNow
        }
        return result
    }

    /// Modifier flags for high-frequency move/drag events (mouseMoved, leftMouseDragged, etc.).
    ///
    /// Includes physical (keyboard) modifiers so apps like Illustrator and Keynote can
    /// read ⇧/⌘/⌥/⌃ from drag events for constraint-snapping.  The tap callback is
    /// scheduled on HIDThread (same as inject()), so tapLastPhysicalFlags is written and
    /// read on one thread — the cross-thread race that previously caused stuck modifiers
    /// is eliminated at the source rather than worked around by dropping physical state.
    var moveSafeEventFlags: CGEventFlags {
        let synth = groundTruthSyntheticFlags.rawValue
            | SharedAuxModifierState.shared.groundTruthFlags.rawValue
        return CGEventFlags(rawValue:
            (tapLastPhysicalFlags & ModifierMath.managedMask)
            | synth
            | ModifierMath.leftDeviceBits(for: synth))
    }

    /// The union of modifier flags justified by currently-held pen barrel buttons.
    /// Used by `reconcileSyntheticFlags` to identify orphaned bits after a tool change.
    /// Express-key modifiers are excluded — they arrive via `injectAux` with their own
    /// settings context and are handled by the DispatchWorkItem / time-based watchdogs.
    private func expectedSyntheticFlagsForHeldPenButtons() -> CGEventFlags {
        // Pen-button bindings live on the active tool's snapshot (refreshed on every
        // ToolSettings change). When no snapshot has been seeded yet — e.g. during
        // the brief window before DeviceContext.observeInjectionSnapshot() runs —
        // there are no held pen buttons either, so an empty result is correct.
        guard let snap = injectionSnapshot else { return [] }
        var flags = CGEventFlags()
        if lastButton1Down {
            flags.formUnion(CGEventFlags(rawValue: snap.activeTool.penButton1Binding.modifierFlags))
        }
        if lastButton2Down {
            flags.formUnion(CGEventFlags(rawValue: snap.activeTool.penButton2Binding.modifierFlags))
        }
        if lastButton3Down {
            flags.formUnion(CGEventFlags(rawValue: snap.activeTool.penButton3Binding.modifierFlags))
        }
        return flags
    }

    /// Called whenever `activeToolSettings` changes. Releases any synthetic modifier bits
    /// that are no longer justified by the current pen button bindings. This handles the
    /// eraser-flip / tool-switch scenario: if the user held a barrel button mapped to ⌥
    /// and the tool identity changed mid-hold, the up-edge fires against the new binding
    /// and ⌥ would otherwise be orphaned in `groundTruthSyntheticFlags` forever.
    func reconcileSyntheticFlags() {
        guard !groundTruthSyntheticFlags.isEmpty else { return }
        let expected = expectedSyntheticFlagsForHeldPenButtons()
        let excessRaw = ModifierMath.excessSyntheticBits(
            groundTruth: groundTruthSyntheticFlags.rawValue,
            expected: expected.rawValue)
        guard excessRaw != 0 else { return }
        let excess = CGEventFlags(rawValue: excessRaw)
        modLog.info("reconcile: tool change orphaned bits 0x\(String(excessRaw, radix: 16), privacy: .public)")

        // Clear excess bits first (mirroring releaseAllSyntheticModifiers ordering):
        // history stays intact so stale-bit detection strips them from outbound events.
        for (bit, _) in Self.modifierKeyCodes where excess.contains(bit) {
            modifierRefCounts[bit.rawValue] = 0
            groundTruthSyntheticFlags.remove(bit)
        }
        lastSyntheticFlagChangeAt = Date()

        // Build explicit release flags: managed bits come from remaining-held synthetic
        // bits (excess already cleared above); non-managed bits from system. Same
        // rationale as releaseAllSyntheticModifiers — hidSystemState is contaminated
        // with our earlier synthetic posts; don't let it re-assert the bits.
        let reconcileFlags = CGEventFlags(rawValue: ModifierMath.releaseEventFlags(
            systemFlags: CGEventSource.flagsState(.hidSystemState).rawValue,
            remainingSyntheticFlags: groundTruthSyntheticFlags.rawValue))

        for (bit, keyCode) in Self.modifierKeyCodes where excess.contains(bit) {
            guard let e = CGEvent(source: sessionSource) else { continue }
            e.type = .flagsChanged
            e.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
            e.flags = reconcileFlags
            e.post(tap: .cghidEventTap)
        }
    }

    /// Releases any synthetic modifier keys currently held by an aux/express-key
    /// binding on ANY device (see `SharedAuxModifierState`). Mirrors
    /// `releaseAllSyntheticModifiers` but clears the shared store instead of this
    /// instance's own ground truth. Safe to call from any instance — the shared
    /// state, and hidSystemState, don't belong to a particular device.
    func releaseSharedAuxModifiers() {
        let shared = SharedAuxModifierState.shared
        guard !shared.groundTruthFlags.isEmpty else { return }
        let toRelease = shared.groundTruthFlags

        shared.groundTruthFlags = []
        for key in shared.refCounts.keys { shared.refCounts[key] = 0 }
        shared.lastChangeAt = Date()

        let releaseFlags = CGEventFlags(rawValue: ModifierMath.releaseEventFlags(
            systemFlags: CGEventSource.flagsState(.hidSystemState).rawValue,
            remainingSyntheticFlags: groundTruthSyntheticFlags.rawValue))

        for (bit, keyCode) in Self.modifierKeyCodes where toRelease.contains(bit) {
            guard let e = CGEvent(source: sessionSource) else { continue }
            e.type = .flagsChanged
            e.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
            e.flags = releaseFlags
            e.post(tap: .cghidEventTap)
        }
    }

    /// Releases any synthetic modifier keys currently held by tablet button bindings.
    /// Posts one `.flagsChanged` event per held modifier bit, then clears all state.
    /// Safe to call when `groundTruthSyntheticFlags` is already empty (no-op).
    func releaseAllSyntheticModifiers() {
        guard !groundTruthSyntheticFlags.isEmpty else { return }
        let toRelease = groundTruthSyntheticFlags
        let systemBefore = CGEventSource.flagsState(.hidSystemState).rawValue & ModifierMath.managedMask
        modLog.info("releaseAll: clearing 0x\(String(toRelease.rawValue, radix: 16), privacy: .public) (system=0x\(String(systemBefore, radix: 16), privacy: .public))")

        // Clear ground truth and ref counts BEFORE posting.
        groundTruthSyntheticFlags = []
        for key in modifierRefCounts.keys { modifierRefCounts[key] = 0 }
        lastSyntheticFlagChangeAt = Date()

        // Build the explicit release flags: non-managed system bits unchanged;
        // managed bits = 0 for everything being released, 0 for all remaining synthetic
        // bits (ground truth is already cleared).  We do NOT read hidSystemState for
        // managed bits because hidSystemState is polluted by our own earlier synthetic
        // flagsChanged events posted via cghidEventTap — it would re-assert the very
        // bit we are trying to release.  tapLastPhysicalFlags has the same contamination,
        // so we also exclude it for managed bits and start from a clean managed=0 base.
        // If the user is simultaneously holding the same modifier physically on the
        // keyboard, the OS will re-assert it via its own flagsChanged as the key stays
        // held — we don't need to preserve it in this event.
        // Managed bits all clear; non-managed bits preserved from system.
        let releaseFlags = CGEventFlags(rawValue: ModifierMath.releaseEventFlags(
            systemFlags: CGEventSource.flagsState(.hidSystemState).rawValue,
            remainingSyntheticFlags: 0))

        // One flagsChanged per bit with its canonical keycode. Posted DIRECTLY (not via
        // finalizeAndPost) to avoid having currentEventFlags re-stamp the stale system value
        // back in.  Many apps (Electron, Cocoa text input) silently ignore keycode-0 events.
        for (bit, keyCode) in Self.modifierKeyCodes where toRelease.contains(bit) {
            guard let e = CGEvent(source: sessionSource) else { continue }
            e.type = .flagsChanged
            e.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
            e.flags = releaseFlags
            e.post(tap: .cghidEventTap)
        }

        // Audit: re-read hidSystemState shortly after, log if any "released" bit is
        // still set there. Captures the case where the release events were posted but
        // the OS still reports the modifier as held — points to event-tap interference
        // or a state-source mismatch. Async so we sample after WindowServer settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard self != nil else { return }
            let systemAfter = CGEventSource.flagsState(.hidSystemState).rawValue & ModifierMath.managedMask
            let stillStuck = toRelease.rawValue & systemAfter
            if stillStuck != 0 {
                modLog.error("releaseAll: post-audit FAILED — bits 0x\(String(stillStuck, radix: 16), privacy: .public) STILL set in hidSystemState 50ms after release events posted")
            } else {
                modLog.debug("releaseAll: post-audit ok — hidSystemState clean")
            }
        }
    }

    /// Called when the frontmost application changes. Releases any synthetic modifier
    /// keys so the new app receives a clean keyboard state.
    ///
    /// To disable this behavior, remove the call in AppWatcher.appDidActivate — the
    /// proximity-exit safety valve (which calls releaseAllSyntheticModifiers) is
    /// unaffected and continues to operate independently.
    func releaseOnAppSwitch() {
        // groundTruthSyntheticFlags / modifierRefCounts are HIDThread-owned.
        CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.releaseAllSyntheticModifiers()
        }
        CFRunLoopWakeUp(HIDThread.shared.runLoop)
    }

    /// Post a completed CGEvent.
    ///
    /// The caller is responsible for setting `event.flags` before calling:
    /// use `currentEventFlags` for state-change events (mouseDown/Up, click,
    /// scroll, flagsChanged) and `moveSafeEventFlags` for high-frequency
    /// movement events (mouseMoved, leftMouseDragged, tabletPointer).
    /// Keeping the flags decision at the call site avoids invoking
    /// `CGEventSource.flagsState` — a kernel round-trip — on every pen report.
    func finalizeAndPost(_ event: CGEvent) {
        #if DEBUG
        assert(
            groundTruthSyntheticFlags.rawValue & ModifierMath.managedMask
                == groundTruthSyntheticFlags.rawValue,
            "groundTruthSyntheticFlags contains bits outside ModifierMath.managedMask"
        )
        #endif
        // Stamp with the kernel receipt time of the driving HID report so
        // inter-event timing reflects the pen's actual motion, not our
        // scheduling jitter — brush engines derive stroke velocity from
        // event timestamps. Timer-fired posts carry 0 and keep the default.
        if Self.currentReportTimestampNs != 0 {
            event.timestamp = Self.currentReportTimestampNs
        }
        event.post(tap: .cghidEventTap)
    }

    @MainActor
    func installFlagsChangedTap() {
        // Listen-only tap at the session level for .flagsChanged events only.
        // Passive: we never modify events, just observe them.
        let selfPtr = Unmanaged.passUnretained(self)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: { _, _, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passRetained(event) }
                let injector = Unmanaged<InputInjector>.fromOpaque(userInfo).takeUnretainedValue()
                // Only update tapLastPhysicalFlags for hardware keyboard events.
                // Our own injected flagsChanged events use .privateState source and DO
                // write into hidSystemState — reading hidSystemState here would reflect
                // them and corrupt tapLastPhysicalFlags with phantom physical key state.
                // Filter by sourceStateID: hardware events have .hidSystemState (raw=1);
                // our events have a private state ID.  Read event.flags directly to get
                // the exact post-event modifier state without hidSystemState lag/pollution.
                let stateID = Int32(truncatingIfNeeded:
                    event.getIntegerValueField(.eventSourceStateID))
                guard ModifierMath.shouldUpdatePhysicalCache(sourceStateID: stateID) else {
                    return Unmanaged.passRetained(event)
                }
                injector.tapLastPhysicalFlags =
                    event.flags.rawValue & ModifierMath.managedMask
                return Unmanaged.passRetained(event)
            },
            userInfo: selfPtr.toOpaque()
        )
        guard let tap else {
            modLog.error("flagsChanged tap: CGEvent.tap failed (accessibility permission missing?)")
            return
        }
        flagsChangedTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // Register on HIDThread so the tap callback and inject() share one thread.
        // tapLastPhysicalFlags is therefore written and read without cross-thread races.
        CFRunLoopAddSource(HIDThread.shared.runLoop, runLoopSource, .commonModes)
        flagsChangedTapSource = runLoopSource
        // Warm the cache before enabling so the first tap callback has a valid baseline.
        tapLastPhysicalFlags = CGEventSource.flagsState(.hidSystemState).rawValue & ModifierMath.managedMask
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Resolves effective pen pose for CGEvent stamping.
    /// When useRotationAsTilt is true on the active tool, real tilt is suppressed and
    /// barrel rotation is sent as synthetic tilt instead — a "bait and switch" so
    /// Photoshop's Pen Tilt brush dynamics respond to barrel twist.
    func resolveEffectivePose(
        point: TabletPoint,
        snapshot: InjectionSnapshot
    ) -> (tiltX: Double, tiltY: Double, rotation: Double) {
        let tool = snapshot.activeTool

        var tiltX = point.tiltX
        // TabletPoint uses the HID tilt convention (+Y = leans toward the user).
        // NSEvent.tilt.y is the opposite: Apple leaves the sign undocumented, but
        // Chromium's macOS event builder negates tilt.y to reach the Pointer
        // Events sign and says so, and OpenTabletDriver negates on macOS too.
        // Applied once here, not per decoder: the mismatch is with the platform,
        // not any device. Verified at the application 2026-09-05 — Rebelle's flat
        // brush leans the right way for Xencelabs and Wacom pens and matches the
        // vendor drivers; without this every brand pointed backward on Y.
        var tiltY = -point.tiltY
        let rotation = point.rotation

        if tool.useRotationAsTilt && point.rotation != 0.0 {
            var degrees = point.rotation

            if snapshot.invertRotation {
                degrees = (360.0 - degrees).truncatingRemainder(dividingBy: 360.0)
            }

            degrees += tool.rotationTiltOffsetDegrees
            // Rotation gives 0–360° but Photoshop's tilt range is only 0–180°.
            // Double the rotation so a full barrel sweep covers the full tilt span.
            let radians = degrees * 2.0 * .pi / 180.0
            let magnitude = tool.rotationTiltMagnitude

            // Overwrites the negation above deliberately: this synthetic vector
            // is already tuned against Photoshop, so it needs no correction.
            tiltX = magnitude * cos(radians)
            tiltY = magnitude * sin(radians)
        }

        return (tiltX, tiltY, rotation)
    }

    func postMouseDown(
        button: CGMouseButton, at location: CGPoint,
        pressure: Double, clickCount: Int,
        point: TabletPoint? = nil,
        snapshot: InjectionSnapshot
    ) {
        let type: CGEventType
        switch button {
        case .right: type = .rightMouseDown
        case .center: type = .otherMouseDown
        default: type = .leftMouseDown
        }
        guard
            let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: location, mouseButton: button)
        else { return }
        if activeAppProfile != .pagesPlainMouse {
            // subtype must be set first — tabletEvent fields are stored in a union
            // keyed by subtype; Photoshop reads tabletEventPointPressure (the tablet
            // union), not mouseEventPressure; both must be set for full app coverage.
            // Pages text engine is confused by subtype=1 and treats the event as a
            // tablet gesture rather than a plain mouse click, breaking text selection.
            e.setIntegerValueField(.mouseEventSubtype, value: 1)
            e.setIntegerValueField(.tabletEventDeviceID, value: 1)
            e.setIntegerValueField(.tabletEventPointButtons, value: 1)
            e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
            e.setDoubleValueField(.mouseEventPressure, value: pressure)
            if let p = point {
                let pose = resolveEffectivePose(point: p, snapshot: snapshot)
                e.setDoubleValueField(.tabletEventTiltX, value: pose.tiltX)
                e.setDoubleValueField(.tabletEventTiltY, value: pose.tiltY)
                e.setDoubleValueField(.tabletEventRotation, value: pose.rotation)
            }
        }
        // Synthetic CGEvents default to click count 0. Always set it so that
        // double-clicks are recognised (e.g. entering floating text-box edit mode
        // in Pages/Keynote/Numbers requires clickState=2 even in plain-mouse mode).
        //
        // In plain-mouse mode only inject click state for multi-clicks: Quartz
        // already tracks single-click state internally, and explicitly setting
        // clickState=1 disrupts Pages' drag-selection state machine.
        if activeAppProfile != .pagesPlainMouse || clickCount > 1 {
            e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        e.flags = currentEventFlags
        finalizeAndPost(e)
    }

    func postMouseUp(
        button: CGMouseButton, at location: CGPoint,
        clickCount: Int, point: TabletPoint? = nil,
        snapshot: InjectionSnapshot
    ) {
        let type: CGEventType
        switch button {
        case .right: type = .rightMouseUp
        case .center: type = .otherMouseUp
        default: type = .leftMouseUp
        }
        guard
            let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: location, mouseButton: button)
        else { return }
        if activeAppProfile != .pagesPlainMouse {
            e.setIntegerValueField(.mouseEventSubtype, value: 1)
            e.setIntegerValueField(.tabletEventDeviceID, value: 1)
            e.setIntegerValueField(.tabletEventPointButtons, value: 0)
            e.setDoubleValueField(.tabletEventPointPressure, value: 0)
            e.setDoubleValueField(.mouseEventPressure, value: 0)
            if let p = point {
                let pose = resolveEffectivePose(point: p, snapshot: snapshot)
                e.setDoubleValueField(.tabletEventTiltX, value: pose.tiltX)
                e.setDoubleValueField(.tabletEventTiltY, value: pose.tiltY)
                e.setDoubleValueField(.tabletEventRotation, value: pose.rotation)
            }
        }
        if activeAppProfile != .pagesPlainMouse || clickCount > 1 {
            e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        e.flags = currentEventFlags
        finalizeAndPost(e)
    }

    func postMouseDrag(
        button: CGMouseButton, at location: CGPoint,
        pressure: Double, point: TabletPoint? = nil,
        pose: (tiltX: Double, tiltY: Double, rotation: Double),
        snapshot: InjectionSnapshot
    ) {
        let type: CGEventType
        switch button {
        case .right: type = .rightMouseDragged
        case .center: type = .otherMouseDragged
        default: type = .leftMouseDragged
        }
        guard
            let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: location, mouseButton: button)
        else { return }
        if activeAppProfile != .pagesPlainMouse {
            e.setIntegerValueField(.mouseEventSubtype, value: 1)
            e.setIntegerValueField(.tabletEventDeviceID, value: 1)
            e.setIntegerValueField(.tabletEventPointButtons, value: pressure > InputInjector.tipPressureThreshold ? 1 : 0)
            e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
            e.setDoubleValueField(.mouseEventPressure, value: pressure)
            if point != nil {
                e.setDoubleValueField(.tabletEventTiltX, value: pose.tiltX)
                e.setDoubleValueField(.tabletEventTiltY, value: pose.tiltY)
                e.setDoubleValueField(.tabletEventRotation, value: pose.rotation)
            }
        }
        // Synthetic CGEvents default to zero deltas, breaking AppKit controls (e.g.
        // Xcode's minimap) that read event.deltaX/Y rather than diffing absolute
        // positions themselves. CG Y=0 is top; NSEvent deltaY is positive-upward,
        // so negate the Y component.
        e.setIntegerValueField(
            .mouseEventDeltaX, value: Int64((location.x - lastPostedPoint.x).rounded()))
        e.setIntegerValueField(
            .mouseEventDeltaY, value: Int64((location.y - lastPostedPoint.y).rounded()))
        e.flags = moveSafeEventFlags
        finalizeAndPost(e)
    }

    func postMouseMoved(
        at location: CGPoint, point: TabletPoint? = nil,
        pose: (tiltX: Double, tiltY: Double, rotation: Double),
        snapshot: InjectionSnapshot
    ) {
        guard
            let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: .mouseMoved,
                mouseCursorPosition: location, mouseButton: .left)
        else { return }
        if activeAppProfile != .pagesPlainMouse {
            if point != nil {
                e.setIntegerValueField(.mouseEventSubtype, value: 1)
                e.setIntegerValueField(.tabletEventDeviceID, value: 1)
                e.setDoubleValueField(.tabletEventTiltX, value: pose.tiltX)
                e.setDoubleValueField(.tabletEventTiltY, value: pose.tiltY)
                e.setDoubleValueField(.tabletEventRotation, value: pose.rotation)
            }
        }
        e.setIntegerValueField(
            .mouseEventDeltaX, value: Int64((location.x - lastPostedPoint.x).rounded()))
        e.setIntegerValueField(
            .mouseEventDeltaY, value: Int64((location.y - lastPostedPoint.y).rounded()))
        e.flags = moveSafeEventFlags
        finalizeAndPost(e)
    }

    // MARK: - Raw tablet pointer event

    func postTabletPointerEvent(
        at location: CGPoint, pressure: Double,
        point: TabletPoint,
        pose: (tiltX: Double, tiltY: Double, rotation: Double),
        snapshot: InjectionSnapshot
    ) {
        guard let e = CGEvent(source: sessionSource) else {
            injectLog.error("postTabletPointerEvent: CGEvent creation failed — pen point dropped")
            return
        }
        e.type = .tabletPointer
        e.location = location
        e.setIntegerValueField(.tabletEventDeviceID, value: 1)
        e.setIntegerValueField(.tabletEventPointX, value: Int64(point.x))
        e.setIntegerValueField(.tabletEventPointY, value: Int64(point.y))
        e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        e.setDoubleValueField(.tabletEventTiltX, value: pose.tiltX)
        e.setDoubleValueField(.tabletEventTiltY, value: pose.tiltY)
        e.setDoubleValueField(.tabletEventRotation, value: pose.rotation)
        let buttons: Int64 =
            (pressure > InputInjector.tipPressureThreshold ? 1 : 0)
            | (point.penButton1 ? 2 : 0)
            | (point.penButton2 ? 4 : 0)
            | (activeToolIsEraser && pressure > InputInjector.tipPressureThreshold ? 8 : 0)
        e.setIntegerValueField(.tabletEventPointButtons, value: buttons)
        e.flags = moveSafeEventFlags
        finalizeAndPost(e)
    }

    // MARK: - Proximity event

    func postProximityEvent(
        entering: Bool, at location: CGPoint,
        eraser: Bool
    ) {
        guard let e = CGEvent(source: sessionSource) else {
            injectLog.error("postProximityEvent: CGEvent creation failed — entering=\(entering) eraser=\(eraser)")
            return
        }
        e.type = .tabletProximity
        e.location = location

        e.setIntegerValueField(
            .tabletProximityEventVendorID,
            value: Int64(deviceVendorID))
        e.setIntegerValueField(
            .tabletProximityEventTabletID,
            value: Int64(deviceProductID))
        // Tip and eraser ends get distinct pointerIDs so apps that track tool identity
        // separately (e.g. Procreate, Clip Studio) don't conflate the two ends.
        // 0x0002 = pen tip, 0x0082 = eraser (high bit marks the "other end" of the same pen).
        let pointerID: Int64 = eraser ? 0x0082 : 0x0002
        e.setIntegerValueField(.tabletProximityEventPointerID, value: pointerID)
        e.setIntegerValueField(.tabletProximityEventDeviceID, value: 1)

        // Serial lets apps maintain per-tool brush memories (e.g. Photoshop's tool presets).
        // Eraser end uses serial | 0x80000000 so tip and eraser each get an independent slot.
        // kCGTabletProximityEventPointerSerialNumber = 172 (raw value; not exposed in Swift).
        if activeToolSerial != 0 {
            let serial: Int64 =
                eraser
                ? Int64(bitPattern: UInt64(activeToolSerial) | 0x8000_0000)
                : Int64(activeToolSerial)
            if let serialField = CGEventField(rawValue: 172) {
                e.setIntegerValueField(serialField, value: serial)
            }
        }
        e.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 0)

        // pointerType: 0 = leaving, 1 = pen, 2 = cursor/mouse, 3 = eraser
        let ptrType: Int64 = entering ? (eraser ? 3 : (activeToolIsMouse ? 2 : 1)) : 0
        e.setIntegerValueField(.tabletProximityEventPointerType, value: ptrType)

        // Use activeToolCode for vendor pointer type; default to Grip Pen (0x0802).
        // Art Pen variants use 0x0812 (rotation-capable pen subtype) so apps like Krita
        // and Rebelle categorise the tool correctly and use rotation rather than tilt.
        // Previously reported as 0x0802 to work around a barrel-button debounce bug
        // (EA/E0 sub-frame; barrel bits read from rotation packets) — now fixed.
        let toolCode = activeToolCode
        let vendorPtr: Int64
        if eraser {
            vendorPtr = 0x080A  // Grip Pen Eraser
        } else if activeToolIsMouse {
            vendorPtr = 0x0006  // Intuos Mouse
        } else {
            switch toolCode {
            case 0x0804, 0x1108, 0x1804:  // Art Pen variants
                vendorPtr = 0x0812  // Art Pen / rotation-capable pen
            case 0x0842:  // Pro Pen 3
                vendorPtr = 0x0842
            case 0x0832:  // Pro Pen 2
                vendorPtr = 0x0832
            case 0x0852:  // Pen 4K
                vendorPtr = 0x0852
            default:
                vendorPtr = 0x0802  // Grip Pen fallback
            }
        }
        e.setIntegerValueField(.tabletProximityEventVendorPointerType, value: vendorPtr)
        e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x05C7)
        e.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        e.flags = currentEventFlags
        finalizeAndPost(e)
    }

    // MARK: - Button binding execution

    /// Settings writes for `.displayToggle` / `.ringCycle` / `.ringSelectSlot` are
    /// dispatched to main; everything else runs synchronously on the caller's thread
    /// (HIDThread for inject/injectAux/injectMouseButtons).
    func fireButtonAction(
        _ binding: ButtonBinding, down: Bool,
        at location: CGPoint,
        snapshot: InjectionSnapshot,
        settings: TabletSettings? = nil,
        isAux: Bool = false
    ) {
        switch binding.kind {
        case .none:
            break
        case .leftClick:
            hoverDragButton = down ? .left : nil
            let type: CGEventType = down ? .leftMouseDown : .leftMouseUp
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: location, mouseButton: .left)
            {
                // Same tablet stamping as `.rightClick`/`.middleClick` below.
                // This case used to post a bare mouse event while its three
                // siblings stamped subtype/devID/ptBtns, which made a binding's
                // down and a pen tip's up (which always stamps, via
                // `postMouseUp`) look like two different input streams — enough
                // for AppKit's gesture recognizer to reject the up as
                // `receivedEventMidStream`. Pressure stays 0: this is a button
                // press, not a tip contact.
                //
                // Profile-gated, unlike the siblings: this button's release can
                // arrive from `postMouseUp` (pen tip, `releaseBindingHeldButton`),
                // which skips stamping entirely under `pagesPlainMouse`. Stamping
                // unconditionally here would pair a stamped down with an unstamped
                // up in Pages — the same mismatch, inverted.
                if activeAppProfile != .pagesPlainMouse {
                    e.setIntegerValueField(.mouseEventSubtype, value: 1)
                    e.setIntegerValueField(.tabletEventDeviceID, value: 1)
                    e.setIntegerValueField(.tabletEventPointButtons, value: down ? 1 : 0)
                    e.setDoubleValueField(.tabletEventPointPressure, value: 0.0)
                    e.setDoubleValueField(.mouseEventPressure, value: 0.0)
                }
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }
        case .rightClick, .eraser:
            hoverDragButton = down ? .right : nil
            let type: CGEventType = down ? .rightMouseDown : .rightMouseUp
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: location, mouseButton: .right)
            {
                // Match OTD's event format: subtype=1 + devID + ptBtns, pressure explicitly 0.
                // CGEvent auto-sets mouseEventPressure=1.0 on mouseDown; zeroing it prevents
                // apps like QGIS, SketchUp from treating the button press as a tip contact.
                e.setIntegerValueField(.mouseEventSubtype, value: 1)
                e.setIntegerValueField(.tabletEventDeviceID, value: 1)
                e.setIntegerValueField(.tabletEventPointButtons, value: down ? 2 : 0)  // bit 1 = right
                e.setDoubleValueField(.tabletEventPointPressure, value: 0.0)
                e.setDoubleValueField(.mouseEventPressure, value: 0.0)
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }
        case .middleClick:
            hoverDragButton = down ? .center : nil
            let type: CGEventType = down ? .otherMouseDown : .otherMouseUp
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: location, mouseButton: .center)
            {
                // Match OTD's event format: subtype=1 + devID + ptBtns, pressure explicitly 0.
                // CGEvent auto-sets mouseEventPressure=1.0 on mouseDown; zeroing it prevents
                // apps like SketchUp from treating the button press as a tip contact.
                e.setIntegerValueField(.mouseEventSubtype, value: 1)
                e.setIntegerValueField(.tabletEventDeviceID, value: 1)
                e.setIntegerValueField(.tabletEventPointButtons, value: down ? 4 : 0)
                e.setDoubleValueField(.tabletEventPointPressure, value: 0.0)
                e.setDoubleValueField(.mouseEventPressure, value: 0.0)
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }
        case .middleClickWithTip:
            hoverDragButton = down ? .center : nil
            // Like middleClick, but stamps tablet tip-down fields so apps that gate
            // on tip contact (SketchUp, some CAD tools) accept the event.
            let type: CGEventType = down ? .otherMouseDown : .otherMouseUp
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: location, mouseButton: .center)
            {
                e.setIntegerValueField(.mouseEventSubtype, value: 1)
                e.setIntegerValueField(.tabletEventDeviceID, value: 1)
                e.setIntegerValueField(.tabletEventPointButtons, value: down ? 4 : 0)  // bit 2 = middle
                e.setDoubleValueField(.tabletEventPointPressure, value: down ? 1.0 : 0.0)
                e.setDoubleValueField(.mouseEventPressure, value: down ? 1.0 : 0.0)
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }
        case .keyCombo:
            let bindingFlags = CGEventFlags(rawValue: binding.modifierFlags)
            let modBits: [CGEventFlags] = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

            // Build the CGEvent BEFORE mutating state. If construction fails (rare, but
            // can happen under memory pressure or CoreGraphics saturation), we bail without
            // touching groundTruthSyntheticFlags or modifierRefCounts. The old code mutated
            // state first, leaving orphaned modifier bits when the event never reached the OS.
            let isModifierOnly = binding.keyLabel.isEmpty && binding.modifierFlags != 0
            let event: CGEvent?
            if isModifierOnly {
                let e = CGEvent(source: sessionSource)
                e?.type = .flagsChanged
                e?.setIntegerValueField(.keyboardEventKeycode, value: Int64(binding.keyCode))
                event = e
            } else {
                event = CGEvent(
                    keyboardEventSource: sessionSource,
                    virtualKey: CGKeyCode(binding.keyCode),
                    keyDown: down)
            }

            if event == nil {
                modLog.error("CGEvent creation failed — keyCombo '\(binding.keyLabel, privacy: .public)' down=\(down); state NOT mutated")
            }
            guard let e = event else { break }

            // Real keyboards bracket a modified keystroke with flagsChanged
            // events (⌘ down → Space down → Space up → ⌘ up); apps that track
            // modifier state from flagsChanged transitions alone (Rebelle)
            // never saw a modifier release when we only stamped flags on the
            // keyDown/keyUp pair. Post in hardware order: modifiers assert
            // before the keyDown; the keyUp still carries the held modifiers
            // (so it goes out before the state decrement below); the release
            // flagsChanged comes last.
            let bracketModifiers = !isModifierOnly && binding.modifierFlags != 0
            if bracketModifiers && !down {
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }

            // Event created successfully — now commit the state delta.
            //
            // Aux-sourced bindings (express keys, touch-ring center click) go to the
            // process-wide shared store instead of this instance's own ground truth.
            // An aux-only accessory (Xencelabs QuickKeys) is its own physical device
            // with its own InputInjector — a Shift it asserts must still show up in
            // the flags on drag events posted by whichever InputInjector is actually
            // driving the pointer (the pen tablet's), which never sees this instance's
            // local groundTruthSyntheticFlags. Pen-button bindings (barrel buttons)
            // keep using local state because they're reconciled against this device's
            // own active tool (see reconcileSyntheticFlags) — sharing them globally
            // would let an unrelated device's tool change strip them.
            if isAux {
                let shared = SharedAuxModifierState.shared
                let flagsBefore = shared.groundTruthFlags
                for bit in modBits {
                    if bindingFlags.contains(bit) {
                        let raw = bit.rawValue
                        let currentCount = shared.refCounts[raw] ?? 0
                        if down {
                            shared.refCounts[raw] = currentCount + 1
                            shared.groundTruthFlags.insert(bit)
                        } else {
                            let newCount = Swift.max(0, currentCount - 1)
                            shared.refCounts[raw] = newCount
                            if newCount == 0 { shared.groundTruthFlags.remove(bit) }
                        }
                    }
                }
                if shared.groundTruthFlags != flagsBefore {
                    shared.lastChangeAt = Date()
                    modLog.debug("keyCombo(aux) \(down ? "DOWN" : "UP", privacy: .public) bindFlags=0x\(String(binding.modifierFlags, radix: 16), privacy: .public) keyCode=\(binding.keyCode) shared: 0x\(String(flagsBefore.rawValue, radix: 16), privacy: .public) → 0x\(String(shared.groundTruthFlags.rawValue, radix: 16), privacy: .public)")
                }
            } else {
                let flagsBefore = groundTruthSyntheticFlags
                for bit in modBits {
                    if bindingFlags.contains(bit) {
                        let raw = bit.rawValue
                        let currentCount = modifierRefCounts[raw] ?? 0
                        if down {
                            modifierRefCounts[raw] = currentCount + 1
                            groundTruthSyntheticFlags.insert(bit)
                        } else {
                            let newCount = Swift.max(0, currentCount - 1)
                            modifierRefCounts[raw] = newCount
                            if newCount == 0 { groundTruthSyntheticFlags.remove(bit) }
                        }
                    }
                }
                if groundTruthSyntheticFlags != flagsBefore {
                    lastSyntheticFlagChangeAt = Date()
                    modLog.debug("keyCombo \(down ? "DOWN" : "UP", privacy: .public) bindFlags=0x\(String(binding.modifierFlags, radix: 16), privacy: .public) keyCode=\(binding.keyCode) groundTruth: 0x\(String(flagsBefore.rawValue, radix: 16), privacy: .public) → 0x\(String(self.groundTruthSyntheticFlags.rawValue, radix: 16), privacy: .public)")
                }
            }
            // State is committed — post the flagsChanged bracket(s) with the
            // post-commit flags: on DOWN they assert the modifiers ahead of the
            // keyDown; on UP they carry the released state after the keyUp that
            // already went out above. One event per modifier bit with its
            // canonical left-hand keycode (keycode-0 events are ignored by
            // many apps — see modifierKeyCodes).
            if bracketModifiers {
                for (bit, keyCode) in Self.modifierKeyCodes where bindingFlags.contains(bit) {
                    guard let fc = CGEvent(source: sessionSource) else { continue }
                    fc.type = .flagsChanged
                    fc.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
                    fc.flags = currentEventFlags
                    finalizeAndPost(fc)
                }
            }
            if !(bracketModifiers && !down) {
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }
        case .displayToggle:
            guard down else { break }
            // Aux-only accessories (Xencelabs Quick Keys) move no pointer of
            // their own, so cycling this injector's mapping would do nothing
            // visible — TabletManager wires a forwarder that steers the
            // tablet actually driving the cursor. Never set on pen-bearing
            // devices, so their toggle path below is unchanged.
            if let forward = displayToggleForwarder {
                forward()
                break
            }
            // Cache invalidation is local to HIDThread; only the persisted
            // index needs to round-trip through main.
            cycleToggleDisplay(snapshot: snapshot)
            if let s = settings {
                Task { @MainActor in s.targetDisplayIndex = TabletSettings.displayModeToggle }
            }
        case .ringCycle:
            guard down else { break }
            // Close any open .zoom/.rotate envelope before the mode changes
            // out from under it — synchronous, on HIDThread, before the
            // async index update below. Mechanical-dial hardware: the
            // coaster; capacitive rings: the direct envelope flags. Correct
            // for either mechanism regardless of which one this device uses.
            closeRingGestureEnvelopes()
            if let s = settings {
                Task { @MainActor in
                    // Slots set to Skip are left out of the rotation —
                    // Wacom's native way to shorten the mode cycle when only
                    // one or two modes matter. If every slot is set to Skip,
                    // stay where we are.
                    let count = max(1, s.touchRingSlots.count)
                    var next = s.touchRingActiveSlotIndex
                    for _ in 0..<count {
                        next = (next + 1) % count
                        if s.touchRingSlots.indices.contains(next),
                            s.touchRingSlots[next].action != .skip
                        { break }
                    }
                    s.touchRingActiveSlotIndex = next
                }
            }
        case .ringSelectSlot:
            guard down else { break }
            closeRingGestureEnvelopes()
            let target = min(Int(binding.keyCode), max(0, snapshot.touchRingSlots.count - 1))
            if let s = settings {
                Task { @MainActor in s.touchRingActiveSlotIndex = target }
            }
        case .doubleClick:
            guard down else { break }
            for clickState in [1, 2] {
                for isDown in [true, false] {
                    let type: CGEventType = isDown ? .leftMouseDown : .leftMouseUp
                    if let e = CGEvent(
                        mouseEventSource: sessionSource, mouseType: type,
                        mouseCursorPosition: location, mouseButton: .left)
                    {
                        e.flags = currentEventFlags
                        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
                        finalizeAndPost(e)
                    }
                }
            }
        case .spacebar:
            if let e = CGEvent(keyboardEventSource: sessionSource, virtualKey: 49, keyDown: down) {
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }
        case .relativeModeToggle:
            guard down else { break }
            // Aux-only accessories (Xencelabs Quick Keys) have no cursor of
            // their own — see displayToggleForwarder above for the identical
            // reasoning. Forward to whichever tablet is actually driving the
            // pointer instead of flipping this injector's own inert setting.
            if let forward = relativeModeToggleForwarder {
                forward()
                break
            }
            displayMapper.clearRelativeAnchor()
            if let s = settings {
                Task { @MainActor in s.relativeCursorMovement.toggle() }
            }
        case .scrollDrag:
            // Hold-to-pan: while engaged, inject()'s movement path converts
            // pen motion into phased pixel scroll events (see postPanScroll).
            // The binding may live on a different device than the one moving
            // the pointer (e.g. a Quick Keys puck button while the pen pans),
            // so the gesture is driven on whichever injector is currently
            // moving the pointer — resolved via SharedPanScrollState. The
            // engage/disengage intents fire immediately so apps see the
            // gesture's began/ended brackets even if the pen never moves.
            let driver = Self.resolvePanScrollDriver(preferring: self)
            if down {
                SharedPanScrollState.shared.driver = driver
                driver.panScrollUsePhases = snapshot.activeTool.panScrollMomentum
                // A fresh grab halts any coasting tail from the previous
                // gesture, same as touching a real trackpad mid-momentum.
                driver.panMomentumTail.cancel()
                driver.postPanScroll(driver.panScroll.engage(
                    reverse: snapshot.reverseScrollDirection,
                    speed: snapshot.activeTool.panScrollSpeed))
            } else {
                let active = SharedPanScrollState.shared.driver ?? driver
                active.cancelPanScrollSafetyNet()
                // The backdate is read from `self` — the injector whose button
                // debounce deferred this release — not from `active`, which may
                // be a different injector hosting the gesture (puck button, pen
                // pans). Zero unless a debounced release is committing now.
                active.postPanScroll(
                    active.panScroll.disengage(backdate: pendingButtonUpBackdate))
                if active.panScrollUsePhases {
                    active.panMomentumTail.start(velocity: active.panScroll.releaseVelocity)
                }
                SharedPanScrollState.shared.driver = nil
            }
        }

        // Safety valve: if nothing is physically held on the tablet but we still
        // believe a synthetic modifier is pressed, it is by definition a leak.
        if tabletIsQuiescent && !groundTruthSyntheticFlags.isEmpty {
            releaseAllSyntheticModifiers()
        }
        rearmWatchdog()
    }

    // MARK: - Scroll wheel

    /// Scales `rawDelta` by `slot.speed`, accumulates fractional remainder, then
    /// fires scroll lines or key taps. Caps key repeat at 4 per pulse to prevent
    /// runaway at high speed + large delta.
    func dispatchRingDelta(
        rawDelta unflippedDelta: Int, slot: ControlSlot, accum: inout Double,
        at location: CGPoint, snapshot: InjectionSnapshot, settings: TabletSettings?
    ) {
        // User-facing direction preference, applied once here rather than at
        // each of the six call sites (two rings, two strips, two wheels) so
        // every mechanism and every slot action gets it identically. Distinct
        // from `ringDeltaIsInverted`, which has already normalized the raw
        // hardware convention by the time deltas reach this point.
        let rawDelta = snapshot.reverseRingDirection ? -unflippedDelta : unflippedDelta
        // Mechanical-dial hardware (Xencelabs dial; PTK-470/670/870 gen-3 —
        // see `hasMechanicalDial`), scrolling: hand the click to the
        // inertial emitter instead of posting for it. Everything else about
        // the slot still applies — speed scaling and the natural-scrolling
        // convention below are the same numbers, they just seed velocity
        // rather than a one-shot event. Key-press and off/skip slots are
        // untouched, and so is every other device's ring or strip.
        // Modifier-held dial scrolling is not scrolling: apps read ⌥/⌘+wheel as
        // zoom, and zoom is a stepped operation, one notch per detent. A 60 Hz
        // continuous stream hands those apps dozens of zoom steps per second —
        // confirmed unusable in Adobe on hardware. Keep the old discrete
        // one-event-per-click path whenever a modifier is down, which is also
        // the behaviour that was already known good for zoom.
        let zoomModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let modifierHeld = !moveSafeEventFlags.intersection(zoomModifiers).isEmpty
        // Posts .ended if a .zoom/.rotate gesture is currently open on
        // mechanical-dial hardware — a modifier held mid-spin must not
        // leave the app stuck mid-pinch/-rotate. No-op for scroll, which
        // never opens one, and for capacitive hardware, whose envelope is
        // owned by injectAux's touchRingActive edge instead.
        if modifierHeld { closeMechanicalDialGesture() }
        if hasMechanicalDial, !modifierHeld, case .scroll = slot.action {
            // The dial's Speed slider was given a 20x ceiling (44e22ad) purely
            // so one click's line count could cross the chunk threshold that
            // works around AppKit's per-event clamp. Pixel-unit output has no
            // such clamp to work around, so that headroom is now dead — and a
            // saved 20 would put a single click past the velocity ceiling.
            // The slider is back to the normal 0-3x range, so this clamp only
            // catches values saved while the taller one was live.
            let lines = Double(rawDelta) * min(slot.speed, 3.0)
            dialCoaster.impulse(lines: Self.naturalScrollingEnabled ? lines : -lines)
            return
        }
        if slot.action == .zoom || slot.action == .rotate {
            // One post per raw tick, linearly scaled — no accumulator, no
            // physics, on *either* mechanism. This branch used to be
            // capacitive-ring-only, with mechanical-dial hardware routed
            // through `dialCoaster`'s inertial physics instead; that was
            // wrong (see `closeMechanicalDialGesture`'s doc comment) — a
            // dial click is a discrete, already-quantized ±1 tick (confirmed
            // for the Xencelabs dial: `XencelabsDecoder`'s "Dial clicks
            // arrive as discrete events, not a counter"), and feeding a
            // single already-final click through inertial buildup for
            // "smoothness" was solving a problem that didn't exist while
            // creating one that did — nonlinear compounding zoom/rotation
            // per click, a confirmed hardware finding on the Xencelabs puck.
            // Note: unlike the mechanical branch this replaced,
            // `naturalScrollingEnabled` is deliberately NOT applied here —
            // it is a scroll-direction preference, and this ring/dial
            // gesture path never applied it even for the capacitive ring,
            // which is the case already validated as feeling right.
            let kind: RingGestureKind = slot.action == .zoom ? .zoom : .rotate
            // Both zoom and rotate need a mechanism-specific scale — the
            // ring and the mechanical dial have different, measured
            // steps/revolution (72 vs. 13), and zoom's multiplicative
            // compounding makes that difference matter for it too, not just
            // rotate. See `dialGestureZoomScaleMechanical`'s and
            // `dialGestureRotateScaleMechanical`'s doc comments.
            let scale: Double
            switch (kind, hasMechanicalDial) {
            case (.zoom, false): scale = Self.dialGestureZoomScale
            case (.zoom, true): scale = Self.dialGestureZoomScaleMechanical
            case (.rotate, false): scale = Self.dialGestureRotateScale
            case (.rotate, true): scale = Self.dialGestureRotateScaleMechanical
            }
            let delta = Double(rawDelta) * slot.speed * scale
            if hasMechanicalDial {
                // No finger-presence signal exists to bracket .began/.ended
                // the way injectAux's touchRingActive edge does for the
                // capacitive ring — a bare rotary encoder only ever reports
                // "a click happened". Envelope open/close is instead owned
                // by an idle timer: rearmed on every tick, closes the
                // gesture once clicks actually stop arriving.
                if !mechanicalDialGestureOpen {
                    mechanicalDialGestureOpen = true
                    mechanicalDialGestureKind = kind
                    postRingGesture(delta: 0, phase: .began, kind: kind)
                }
                rearmMechanicalDialGestureIdleTimer(kind: kind)
            }
            postRingGesture(delta: delta, phase: .changed, kind: kind)
            return
        }
        accum += Double(rawDelta) * slot.speed
        let lines = Int(accum)
        guard lines != 0 else { return }
        accum -= Double(lines)
        switch slot.action {
        case .scroll:
            // Nominal convention is the vendor/classic one: clockwise (positive
            // `lines`) scrolls down. macOS applies its natural-scrolling flip
            // below the CGEvent layer, so injected scroll events never receive
            // it — apply it here instead, from the mirrored system setting.
            let signedLines = Self.naturalScrollingEnabled ? lines : -lines
            // A single .line-unit CGEvent with a large magnitude gets clamped
            // by AppKit/NSScrollView well below its literal value (confirmed
            // by hardware test 2026-08-06 on the Xencelabs dial: raising the
            // per-tick multiplier well past this chunk size produced no
            // further visible scroll). Split only bursts above the chunk
            // size — normal-speed single ticks stay exactly one event, so a
            // continuously-reporting device like a Wacom ring still feels
            // smooth rather than jittery; only a genuinely fast spin, which
            // would have been clamped anyway, gets broken into a few chunks
            // so the intended distance actually lands.
            //
            // Wacom rings and strips only: the Xencelabs dial returns above
            // into its inertial coaster, whose pixel-unit output never
            // approaches the clamp this works around. Retiring the chunking
            // entirely would mean moving rings to pixel units too — the open
            // .pixel redesign, which needs its own hardware pass on a ring.
            let scrollChunk = 10
            if abs(signedLines) <= scrollChunk {
                postScrollWheelEvent(delta: signedLines, at: location)
            } else {
                let sign = signedLines > 0 ? 1 : -1
                var remaining = abs(signedLines)
                while remaining > 0 {
                    let step = min(remaining, scrollChunk)
                    postScrollWheelEvent(delta: sign * step, at: location)
                    remaining -= step
                }
            }
        case .keyPress:
            let binding = lines > 0 ? slot.cwBinding : slot.ccwBinding
            let count = min(abs(lines), 4)
            for _ in 0..<count {
                fireKeyTap(binding, at: location, snapshot: snapshot, settings: settings)
            }
        case .off, .skip:
            break
        case .zoom, .rotate:
            // Unreachable: both branches above return before this switch is
            // ever reached for a .zoom/.rotate slot. Kept exhaustive rather
            // than `default:` so a future Action case is caught by the
            // compiler here too.
            break
        }
    }

    func postScrollWheelEvent(delta: Int, at location: CGPoint) {
        // .line units: one detent = one scroll line, consistent with trackpad / Magic Mouse.
        guard
            let e = CGEvent(
                scrollWheelEvent2Source: sessionSource, units: .line,
                wheelCount: 1, wheel1: Int32(delta * 3), wheel2: 0, wheel3: 0)
        else { return }
        e.location = location
        e.flags = currentEventFlags
        finalizeAndPost(e)
    }

    /// Sole event-construction site for the Xencelabs dial; the inertia lives
    /// in `dialCoaster` (see MomentumTail.swift).
    ///
    /// Pixel units rather than the `.line` units `postScrollWheelEvent` uses,
    /// for two reasons. A 60 Hz emitter needs sub-line granularity — in line
    /// units the smallest event it can post is a whole line, which would
    /// reintroduce as quantization exactly the steppiness the coast exists to
    /// remove. And small per-tick pixel deltas never approach AppKit's
    /// per-event clamp, so the dial no longer needs the `scrollChunk` split
    /// that works around it on the line path.
    ///
    /// No phase fields: a dial has no touch-down or lift to bracket, and the
    /// stream is already continuous, so there is no gesture envelope to
    /// describe. `isContinuous` plus the trackpad delta fields is what makes
    /// apps read it as smooth scrolling rather than discrete detents.
    func postDialScroll(dy: Double) {
        guard
            let e = CGEvent(
                scrollWheelEvent2Source: sessionSource,
                units: .pixel,
                wheelCount: 1,
                wheel1: Int32(dy), wheel2: 0, wheel3: 0)
        else { return }
        e.location = currentCursorPosition()
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        applyTrackpadDeltaFields(e, dx: 0, dy: dy)
        // Ground-truth flags, like the two momentum tails and unlike
        // `postScrollWheelEvent`: those post synchronously inside the click's
        // own callback, whereas the coast keeps posting from a timer for
        // seconds afterwards, by which time a held modifier may be long gone.
        e.flags = moveSafeEventFlags
        finalizeAndPost(e)
    }

    /// Per-tick magnification-fraction scale, applied to `dispatchRingDelta`'s
    /// raw ±1 (or larger) ring/dial tick before it reaches `postTouchMagnify`.
    /// `magnify.value` in touch's own pinch path is a relative-growth
    /// fraction (e.g. 0.02 = "2% bigger this frame"), not points — this
    /// constant is the conversion factor. Empirically tuned, not derived —
    /// zoom has no natural "one revolution = X%" mapping the way rotate has
    /// "one revolution = 360°" — confirmed "about right" on the PTH-860
    /// (2026-09).
    ///
    /// **Ring only.** Originally shared with the mechanical dial on the
    /// reasoning that both deliver an already-final, discrete tick — true,
    /// but irrelevant here: `magnify.value` *compounds* multiplicatively
    /// per tick (`(1 + scale·speed)` per event), so the same scale produces
    /// wildly different totals per revolution depending on how many ticks
    /// that revolution contains. At max speed the ring's 72 ticks/revolution
    /// gives ≈6.65x; the dial's 13 (see `dialGestureRotateScaleMechanical`'s
    /// doc comment for how that count was measured) gives only ≈1.41x under
    /// this same constant — confirmed on hardware (2026-09) as "even maximum
    /// feels more like 1x." See `dialGestureZoomScaleMechanical` for the
    /// dial's own, tick-count-corrected constant.
    static let dialGestureZoomScale = 1.0 / 300.0

    /// **Mechanical dial only.** `dialGestureZoomScale` scaled by the ratio
    /// of tick counts (ring 72 : dial 13) so one full revolution produces
    /// roughly the same zoom-per-revolution on either mechanism, despite
    /// the dial needing far fewer, much larger per-tick jumps to get there.
    /// Not exact — `magnify.value`'s multiplicative compounding means a
    /// per-tick linear correction can only approximate the ring's smoother,
    /// finer-grained curve, not reproduce it — but it closes the ~4.7x gap
    /// down to matching within a few percent at max speed (measured: ring
    /// ≈6.65x/revolution, dial ≈5.99x/revolution at this value). PTK-470/
    /// 670/870's gen-3 dials share this constant for now (see
    /// `dialGestureRotateScaleMechanical`'s doc comment on why, and its
    /// caveat about their own tick count being unmeasured).
    static let dialGestureZoomScaleMechanical = dialGestureZoomScale * 72.0 / 13.0

    /// Rotation scale — radians per raw ring/dial tick, at 1x speed.
    ///
    /// Calibrated, not a guess, for the **capacitive ring**: the ring
    /// reports 72 fixed steps per physical revolution (see
    /// `InputInjector+AuxInput.swift`'s "72 steps (0-71, ~5° each)" comment),
    /// so `π/36` radians/step (5°/step) makes one full physical revolution
    /// of the ring equal exactly one full 360° canvas rotation at 1x speed —
    /// the anchor a user reaches for turning a ring, confirmed by hardware
    /// feedback (PTH-860) that the previous value (`π/900`, ≈14.4°/rev at
    /// 1x) needed ~25x speed to reach 1:1, an unreasonably tall slider range
    /// for what should be the natural default.
    ///
    /// **Ring only** — do not apply to mechanical-dial hardware. The
    /// Xencelabs dial has a different, measured steps/revolution (13, not
    /// 72 — see `dialGestureRotateScaleMechanical` just below); reusing
    /// this constant for the dial was tried and produced ~330°/revolution
    /// instead of 360°/revolution, confirmed on hardware (2026-09).
    static let dialGestureRotateScale = Double.pi / 36.0

    /// **Mechanical dial only** (Xencelabs puck; also PTK-470/670/870's
    /// gen-3 dials, pending their own measurement — see the note below).
    ///
    /// Same derivation as `dialGestureRotateScale`, using the dial's own
    /// steps/revolution in place of the ring's 72: `2π/13` radians/step
    /// (≈27.7°/step) makes one full physical revolution of the dial equal
    /// exactly one full 360° canvas rotation at 1x speed.
    ///
    /// The 13 was measured directly via `tools/capture/hid_input_capture.c`
    /// against report ID 0x02 (2026-09): one full slow physical revolution
    /// produced exactly 13 identical `02 f0 00 00 00 00 00 01 00 00` input
    /// reports, one per detent-equivalent step — no field in that report
    /// carries anything finer (seven of its nine bytes are always zero; the
    /// descriptor bounds it to flat 8-bit fields, no sub-step position or
    /// magnitude). A faster revolution produced only 10 reports for the
    /// same physical turn, meaning the encoder or its firmware drops steps
    /// under fast rotation — a real hardware ceiling, not something this
    /// scale can compensate for. An earlier, indirect measurement (binding
    /// rotation to a keypress in the vendor's own native driver and
    /// counting 14 key-repeats per turn) was close but one off; the direct
    /// capture above is the more trustworthy count and superseded it.
    ///
    /// `speedRange(for: .rotate)`'s 1.0 ceiling still applies unchanged: it
    /// means "one dial revolution" here exactly as it means "one ring
    /// revolution" for the capacitive case — the per-device scale is what
    /// carries the physical difference, not the ceiling. The dial's
    /// intrinsically coarse ~27.7°-per-step granularity (confirmed above as
    /// a hardware limit, not a software one) is why rotation on this
    /// mechanism reads as steppier than the ring's smoother 5°-per-step feel
    /// even once the revolution-to-360° mapping is correct — there is
    /// nothing left to extract from the input stream to smooth it further.
    ///
    /// PTK-470/670/870's gen-3 dials are a different physical mechanism
    /// from the Xencelabs dial (see `WacomDeviceSpec.hasMechanicalDial`'s
    /// doc comment) and share `hasMechanicalDial: true`, hence this
    /// constant today — but their own steps/revolution has not been
    /// separately measured. If their rotate feel turns out wrong, that's
    /// this constant needing to become genuinely per-model rather than
    /// per-mechanism, not evidence the Xencelabs measurement above is wrong.
    static let dialGestureRotateScaleMechanical = 2.0 * Double.pi / 13.0

    /// Mechanism-neutral gesture post: both the mechanical-dial and
    /// capacitive-ring paths in `dispatchRingDelta`, plus `injectAux`'s
    /// capacitive envelope open/close, funnel through here. `delta` is
    /// expected pre-scaled by the caller. `.began`/`.ended` should always be
    /// called with `delta: 0` — this function applies no phase-based
    /// zeroing itself, callers own that convention.
    func postRingGesture(delta: Double, phase: TouchStateTracker.ScrollPhase, kind: RingGestureKind) {
        switch kind {
        case .zoom: postTouchMagnify(magnification: delta, phase: phase)
        case .rotate: postTouchRotate(rotation: delta, phase: phase)
        }
    }

    // MARK: - Scroll Drag (pan)

    /// Resolve which injector should host a Scroll Drag gesture. The pen
    /// tablet that's actively moving the pointer (active context, pen in
    /// proximity) is the natural driver; if none qualifies (e.g. the pen is
    /// out of range at the moment the button fires), fall back to the injector
    /// that received the binding, so a barrel binding on the pen itself always
    /// works and a puck binding degrades gracefully rather than dropping the
    /// gesture entirely.
    static func resolvePanScrollDriver(preferring fallback: InputInjector) -> InputInjector {
        for injector in allLiveInjectors where injector.isActive && injector.lastProximity {
            return injector
        }
        // No pen currently in proximity — prefer the active context's injector
        // (the pen the user is about to move) over an aux-only accessory.
        for injector in allLiveInjectors where injector.isActive {
            return injector
        }
        return fallback
    }

    /// Sole event-construction site for Pan View gestures. Pixel units + the
    /// continuous flag makes apps treat the stream as a trackpad pan (smooth,
    /// rubber-banded) rather than discrete wheel ticks.
    ///
    /// Panning method, captured at engage from `ToolSettings.panScrollMomentum`.
    /// See `postPanScroll` for what the two modes emit.

    /// Kept as one small function on purpose: it is the backend seam. If the
    /// parked IOHIDUserDevice virtual-trackpad spike ever ships, this becomes
    /// "report contacts to the virtual device" (which buys genuine system
    /// gesture + momentum streams, unavailable to CGEvent-posted scrolls),
    /// and nothing else in the gesture path changes.
    func postPanScroll(_ intent: PanScrollTracker.Intent) {
        guard case .scroll(let dx, let dy, let phase) = intent else { return }
        if !panScrollUsePhases {
            // Compatible mode: zero-delta began/ended brackets carry no delta;
            // with no phase envelope to deliver them, skip them as no-ops.
            guard dx != 0 || dy != 0 else { return }
        }
        // Read once and reuse below — the wheel event and its companion
        // gesture event describe the same instant, so a second WindowServer
        // round-trip a few microseconds later gains nothing.
        let loc = currentCursorPosition()
        // See postTouchScrollGesture (InputInjector+Touch.swift) for why this
        // companion event exists and why it's posted before the wheel event.
        if panScrollUsePhases {
            postPanScrollGesture(dx: dx, dy: dy, phase: phase, location: loc)
        }
        guard
            let e = CGEvent(
                scrollWheelEvent2Source: sessionSource,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(dy),
                wheel2: Int32(dx),
                wheel3: 0)
        else { return }
        e.location = loc
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        if panScrollUsePhases {
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        applyTrackpadDeltaFields(e, dx: dx, dy: dy)
        e.flags = moveSafeEventFlags
        finalizeAndPost(e)
    }

    /// Companion to `postPanScroll` — same technique as `postTouchScrollGesture`,
    /// not sent during the momentum tail. Field numbers documented there.
    private func postPanScrollGesture(
        dx: Double, dy: Double, phase: PanScrollTracker.ScrollPhase, location: CGPoint
    ) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = CGEventType(rawValue: 29)!
        e.location = location
        e.setIntegerValueField(CGEventField(rawValue: 110)!, value: 6)
        e.setIntegerValueField(CGEventField(rawValue: 132)!, value: Int64(phase.rawValue))
        e.setDoubleValueField(CGEventField(rawValue: 116)!, value: dx)
        e.setDoubleValueField(CGEventField(rawValue: 119)!, value: dy)
        finalizeAndPost(e)
    }

    /// Populates the delta fields a real trackpad driver emits alongside the
    /// raw wheel values, which `CGEvent(scrollWheelEvent2Source:)` leaves at
    /// zero. `NSEvent.scrollingDeltaX/Y` for a continuous stream derives from
    /// the point/fixed-point delta fields, and `deltaX/Y` from the line-delta
    /// fields — so consumers that read NSEvent directly (Calendar's paged
    /// Month/Year recognizer, WebKit/Chromium gesture-scroll incl.
    /// overscroll-behavior sites, Adobe's line-delta palettes) saw a
    /// well-phased gesture with zero deltas and ignored it. NSScrollView
    /// tolerates the wheel-only shape, which is why the gap was app-specific.
    func applyTrackpadDeltaFields(_ e: CGEvent, dx: Double, dy: Double) {
        let ix = Int64(dx), iy = Int64(dy)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: iy)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: ix)
        e.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Int64(dy * 65536.0))
        e.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Int64(dx * 65536.0))
        // Line deltas (~10 px/line, the scale real trackpads report); keep a
        // minimum of 1 so slow pans don't quantize to nothing on the legacy
        // line-delta path.
        e.setIntegerValueField(
            .scrollWheelEventDeltaAxis1,
            value: iy == 0 ? 0 : max(1, abs(iy) / 10) * (iy < 0 ? -1 : 1))
        e.setIntegerValueField(
            .scrollWheelEventDeltaAxis2,
            value: ix == 0 ? 0 : max(1, abs(ix) / 10) * (ix < 0 ? -1 : 1))
    }

    // MARK: - Scroll Drag momentum tail (Natural mode)

    /// Sole event-construction site for the Scroll Drag momentum tail; the
    /// decay itself lives in `panMomentumTail` (see MomentumTail.swift).
    ///
    /// During the tail `scrollWheelEventScrollPhase` is held at 0 and
    /// `scrollWheelEventMomentumPhase` carries the sequence instead — setting
    /// both nonzero on the same event makes AppKit/WebKit misread the stream.
    func postPanScrollMomentum(dx: Double, dy: Double, phase: MomentumPhase) {
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
