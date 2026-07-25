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
        var tiltY = point.tiltY
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
            e.setIntegerValueField(.tabletEventPointButtons, value: pressure > 0.004 ? 1 : 0)
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
            (pressure > 0.004 ? 1 : 0)
            | (point.penButton1 ? 2 : 0)
            | (point.penButton2 ? 4 : 0)
            | (activeToolIsEraser && pressure > 0.004 ? 8 : 0)
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
                driver.cancelMomentumTail()
                driver.postPanScroll(driver.panScroll.engage(
                    reverse: snapshot.reverseScrollDirection,
                    speed: snapshot.activeTool.panScrollSpeed))
            } else {
                let active = SharedPanScrollState.shared.driver ?? driver
                active.cancelPanScrollSafetyNet()
                active.postPanScroll(active.panScroll.disengage())
                if active.panScrollUsePhases {
                    active.startMomentumTail(velocity: active.panScroll.releaseVelocity)
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
        rawDelta: Int, slot: ControlSlot, accum: inout Double,
        at location: CGPoint, snapshot: InjectionSnapshot, settings: TabletSettings?
    ) {
        accum += Double(rawDelta) * slot.speed
        let lines = Int(accum)
        guard lines != 0 else { return }
        accum -= Double(lines)
        switch slot.action {
        case .scroll:
            postScrollWheelEvent(delta: lines, at: location)
        case .keyPress:
            let binding = lines > 0 ? slot.cwBinding : slot.ccwBinding
            let count = min(abs(lines), 4)
            for _ in 0..<count {
                fireKeyTap(binding, at: location, snapshot: snapshot, settings: settings)
            }
        case .off, .skip:
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
        if panScrollUsePhases {
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        applyTrackpadDeltaFields(e, dx: dx, dy: dy)
        e.flags = moveSafeEventFlags
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
    private func applyTrackpadDeltaFields(_ e: CGEvent, dx: Double, dy: Double) {
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

    /// `kCGMomentumScrollPhase` values (distinct from and mutually exclusive
    /// with `CGScrollPhase` — see `PanScrollTracker.ScrollPhase`). During the
    /// tail, `scrollWheelEventScrollPhase` is held at 0 and this field carries
    /// the sequence instead; setting both nonzero on the same event makes
    /// AppKit/WebKit misread the stream.
    private enum MomentumPhase: Int64 {
        case begin = 1
        case `continue` = 2
        case end = 3
    }

    /// Tick cadence for the synthetic momentum decay tail — matches a real
    /// trackpad's momentum-stream rate.
    static let momentumTailInterval: TimeInterval = 1.0 / 60.0

    /// Per-tick velocity multiplier. Tuned so a firm flick's tail runs a few
    /// hundred ms before dropping below `momentumStopVelocity`.
    static let momentumDecayPerTick = 0.85

    /// Velocity magnitude (points/second) below which the tail ends. Also
    /// the floor below which a tail never starts at all — a slow, deliberate
    /// release isn't a flick on a real trackpad either, and doesn't get a
    /// momentum phase there; this must match, or a slow release would coast
    /// when native input wouldn't.
    static let momentumStopVelocity: CGFloat = 8.0

    /// Starts (or restarts) the momentum decay tail after a Scroll Drag
    /// release. `velocity` is `PanScrollTracker.releaseVelocity` (points/second).
    /// Only invoked in Natural mode (`panScrollUsePhases`).
    func startMomentumTail(velocity: CGVector) {
        cancelMomentumTail()
        guard hypot(velocity.dx, velocity.dy) >= Self.momentumStopVelocity else { return }
        momentumVelocity = velocity
        momentumAccumX = 0
        momentumAccumY = 0
        postPanScrollMomentum(dx: 0, dy: 0, phase: .begin)
        scheduleMomentumTailTick()
    }

    /// Cancels any in-flight momentum tail without posting a `.end` event —
    /// used when a new Scroll Drag engages before the previous tail decayed
    /// out, matching a real trackpad halting coast-on-touch.
    func cancelMomentumTail() {
        momentumTailTimer.map { CFRunLoopTimerInvalidate($0) }
        momentumTailTimer = nil
    }

    private func scheduleMomentumTailTick() {
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + Self.momentumTailInterval,
            0, 0, 0
        ) { [weak self] _ in
            self?.momentumTailTick()
        }
        CFRunLoopAddTimer(HIDThread.shared.runLoop, timer, .commonModes)
        momentumTailTimer = timer
    }

    private func momentumTailTick() {
        momentumTailTimer = nil
        let dt = Self.momentumTailInterval
        let dx = momentumVelocity.dx * dt
        let dy = momentumVelocity.dy * dt
        momentumVelocity.dx *= Self.momentumDecayPerTick
        momentumVelocity.dy *= Self.momentumDecayPerTick

        momentumAccumX += dx
        momentumAccumY += dy
        let ix = Int(momentumAccumX.rounded(.towardZero))
        let iy = Int(momentumAccumY.rounded(.towardZero))
        momentumAccumX -= Double(ix)
        momentumAccumY -= Double(iy)

        let magnitude = hypot(momentumVelocity.dx, momentumVelocity.dy)
        if magnitude < Self.momentumStopVelocity {
            postPanScrollMomentum(dx: Double(ix), dy: Double(iy), phase: .end)
            return
        }
        if ix != 0 || iy != 0 {
            postPanScrollMomentum(dx: Double(ix), dy: Double(iy), phase: .continue)
        }
        scheduleMomentumTailTick()
    }

    private func postPanScrollMomentum(dx: Double, dy: Double, phase: MomentumPhase) {
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
