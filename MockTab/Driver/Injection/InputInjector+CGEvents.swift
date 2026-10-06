// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import os
import TabletKit

// The CGEvent layer: modifier reconciliation, event constructors, button
// actions, and scroll and ring dispatch. State lives on the main class body.
extension InputInjector {

    // MARK: - Mouse event helpers

    /// Modifier flags for state-change events: physical plus synthetic. Managed
    /// bits (⌘⌥⇧⌃) come from `tapLastPhysicalFlags`, since `hidSystemState` lags
    /// our own posts (OTD PR #4014). Other bits come from `hidSystemState`.
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

    /// Modifier flags for move and drag events. Physical modifiers ride along
    /// for constraint snapping (Illustrator, Keynote), but only while the cache
    /// is current for this report; see `physicalCacheIsCurrent`.
    var moveSafeEventFlags: CGEventFlags {
        let synthetic = groundTruthSyntheticFlags.rawValue
            | SharedAuxModifierState.shared.groundTruthFlags.rawValue
        // A held modifier leaves the cache older than every report, so the
        // timestamp alone would drop it from each drag.
        let current = ModifierMath.physicalCacheIsCurrent(
            reportTimestampNs: Self.currentReportTimestampNs,
            cacheUpdatedAtNs: tapLastPhysicalFlagsAtNs)
            || ModifierMath.physicalCacheAgrees(
                systemFlags: CGEventSource.flagsState(.hidSystemState).rawValue,
                tapPhysicalManaged: tapLastPhysicalFlags,
                syntheticFlags: synthetic)
        if !current { staleModifierCacheDrops &+= 1 }
        return CGEventFlags(rawValue: ModifierMath.moveEventFlags(
            tapPhysicalManaged: tapLastPhysicalFlags,
            syntheticFlags: synthetic,
            physicalCacheIsCurrent: current && !Self.forceDropPhysicalMoveFlags))
    }

    /// Modifiers justified by held pen buttons. ExpressKey modifiers are
    /// excluded; the watchdogs handle those.
    private func expectedSyntheticFlagsForHeldPenButtons() -> CGEventFlags {
        // No snapshot yet means no held buttons either.
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

    /// Release synthetic modifiers the current pen bindings no longer justify,
    /// e.g. a barrel button held for ⌥ across an eraser flip.
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

        // Managed bits come from what's still held, not hidSystemState, which
        // our own posts pollute.
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

    /// Release modifiers held by any device's aux binding (see
    /// `SharedAuxModifierState`). Safe from any instance.
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

        // Managed bits all clear: hidSystemState and tapLastPhysicalFlags both
        // reflect our own earlier posts and would re-assert the bit. A key the user
        // still holds is re-asserted by the OS.
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

        // Audit: log any released bit the OS still reports as held.
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

    /// Releases any plain (non-modifier) keys still held by a `.keyCombo` binding —
    /// see `heldKeyComboRefCounts`. Posts a `keyUp` for each and clears the ref counts.
    /// Safe to call when nothing is held (no-op).
    func releaseAllHeldKeyComboKeys() {
        guard !heldKeyComboRefCounts.isEmpty else { return }
        let toRelease = heldKeyComboRefCounts.keys
        modLog.info("releaseAllHeldKeyComboKeys: clearing keycodes \(Array(toRelease), privacy: .public)")
        heldKeyComboRefCounts.removeAll()
        lastKeyComboChangeAt = Date()

        for key in toRelease {
            guard let e = CGEvent(keyboardEventSource: sessionSource, virtualKey: key, keyDown: false)
            else { continue }
            e.flags = currentEventFlags
            e.post(tap: .cghidEventTap)
        }
    }

    /// The front app changed: release synthetic modifiers so it starts clean.
    func releaseOnAppSwitch() {
        // groundTruthSyntheticFlags / modifierRefCounts are HIDThread-owned.
        CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.releaseAllSyntheticModifiers()
            self?.releaseAllHeldKeyComboKeys()
            // End momentum tails explicitly: macOS 27 force-cancels a gesture left open.
            if let self, self.panMomentumTail.isRunning || self.touchMomentumTail.isRunning {
                TouchPipelineProbe.note { $0.momentumTailsStoppedOnAppSwitch += 1 }
            }
            self?.panMomentumTail.stop()
            self?.touchMomentumTail.stop()
            // Proximity goes to the frontmost app, so one brought forward with
            // the pen already in range never saw it arrive. Rebelle then paints
            // the pen as a mouse, at full pressure, until it leaves and returns.
            // Not mid-stroke: the stroke's own app keeps it.
            if let self, self.lastProximity, !self.lastTipDown, !self.activeToolIsMouse {
                let eraser = self.shimLastPoint?.eraser ?? self.activeToolIsEraser
                self.postProximityEvent(entering: false, at: self.shimLastScreen, eraser: eraser)
                self.postProximityEvent(entering: true, at: self.shimLastScreen, eraser: eraser)
            }
        }
        CFRunLoopWakeUp(HIDThread.shared.runLoop)
    }

    /// Post a finished event. Callers set flags: `currentEventFlags` for state
    /// changes, `moveSafeEventFlags` for movement, which avoids a kernel
    /// round-trip per pen report.
    func finalizeAndPost(_ event: CGEvent) {
        #if DEBUG
        assert(
            groundTruthSyntheticFlags.rawValue & ModifierMath.managedMask
                == groundTruthSyntheticFlags.rawValue,
            "groundTruthSyntheticFlags contains bits outside ModifierMath.managedMask"
        )
        #endif
        // Stamp with the report's receipt time: brush engines derive stroke
        // velocity from event timestamps. Timer-fired posts keep the default.
        if Self.currentReportTimestampNs != 0 {
            event.timestamp = Self.currentReportTimestampNs
        }
        stampClickSequence(event)
        // Wacom's driver marks every event non-coalesced, so the system keeps
        // each pen sample instead of merging moves (event-probe, 2026-09-30).
        event.flags.insert(.maskNonCoalesced)
        // Diagnostic: `event.post` is synchronous IPC into WindowServer and
        // the only stage no other stall probe covers.
        let postStart = mach_absolute_time()
        event.post(tap: .cghidEventTap)
        let postMs =
            Double(mach_absolute_time() &- postStart) * LatencyProbe.timebaseFactor / 1_000_000.0
        if postMs > Self.eventPostWarnThresholdMs {
            injectLog.info("CGEventPost took \(postMs, format: .fixed(precision: 1))ms")
        }
    }

    /// Radius a press may wander and still release as a click. Hardware
    /// captures show sub-3 pt wobble keeping the click state, drags of tens of
    /// points dropping it to 0; the exact system radius is unmeasured.
    static let clickStrayRadius: CGFloat = 4

    /// Gives button events the fields AppKit uses to pair a press with its
    /// drags and release. Without them Pages rejected header/footer
    /// double-clicks and fought drag-selection.
    func stampClickSequence(_ e: CGEvent) {
        switch e.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            clickEventNumber &+= 1
            var state = e.getIntegerValueField(.mouseEventClickState)
            if state == 0 {
                state = 1
                e.setIntegerValueField(.mouseEventClickState, value: 1)
            }
            pressClickState = state
            pressLocation = e.location
            pressStrayed = false
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if hypot(e.location.x - pressLocation.x, e.location.y - pressLocation.y)
                > Self.clickStrayRadius {
                pressStrayed = true
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if hypot(e.location.x - pressLocation.x, e.location.y - pressLocation.y)
                > Self.clickStrayRadius {
                pressStrayed = true
            }
            e.setIntegerValueField(
                .mouseEventClickState, value: pressStrayed ? 0 : pressClickState)
        default:
            return
        }
        e.setIntegerValueField(.mouseEventNumber, value: clickEventNumber)
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
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue)
                | CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passRetained(event) }
                let injector = Unmanaged<InputInjector>.fromOpaque(userInfo).takeUnretainedValue()
                // Hardware keyboard events only (sourceStateID == hidSystemState). Ours
                // use a private state and would corrupt the cache with phantom keys.
                let stateID = Int32(truncatingIfNeeded:
                    event.getIntegerValueField(.eventSourceStateID))
                guard ModifierMath.shouldUpdatePhysicalCache(sourceStateID: stateID) else {
                    return Unmanaged.passRetained(event)
                }
                // A real keystroke, for touch's typing hold-off.
                if event.type == .keyDown {
                    injector.lastPhysicalKeyDownTime = CFAbsoluteTimeGetCurrent()
                    return Unmanaged.passRetained(event)
                }
                injector.tapLastPhysicalFlags =
                    event.flags.rawValue & ModifierMath.managedMask
                // The event's own stamp, on the same kernel clock as
                // `currentReportTimestampNs`, so comparing them measures event order.
                // Wall clock carried tap latency and ratcheted on duplicate deliveries
                // (Cyzor/tablet-driver#18).
                injector.tapLastPhysicalFlagsAtNs = UInt64(event.timestamp)
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
        // Seed the stamp too, or every move before the first keypress drops
        // physical bits. Wall clock is honest here: no event is behind it.
        tapLastPhysicalFlagsAtNs =
            UInt64(Double(mach_absolute_time()) * LatencyProbe.timebaseFactor)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Pen pose for stamping. The hidden `useRotationAsTilt` key sends rotation
    /// as tilt: an obsolete Photoshop workaround.
    func resolveEffectivePose(
        point: TabletPoint,
        snapshot: InjectionSnapshot
    ) -> (tiltX: Double, tiltY: Double, rotation: Double) {
        let tool = snapshot.activeTool

        var tiltX = point.tiltX
        // One blanket flip, matched to the vendor drivers at the app (Rebelle's flat
        // brush, 2026-09-05). Decoders disagree on native sign, so correcting each
        // first would mean two guesses instead of one.
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

    /// Raw digitizer coordinates, which Wacom's driver puts on every pen event.
    func stampTabletPosition(_ e: CGEvent, _ p: TabletPoint) {
        e.setIntegerValueField(.tabletEventPointX, value: Int64(p.x))
        e.setIntegerValueField(.tabletEventPointY, value: Int64(p.y))
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
        // subtype must be set first — tabletEvent fields are stored in a union
        // keyed by subtype; Photoshop reads tabletEventPointPressure (the tablet
        // union), not mouseEventPressure; both must be set for full app coverage.
        e.setIntegerValueField(.mouseEventSubtype, value: 1)
        e.setIntegerValueField(.tabletEventDeviceID, value: tabletDeviceID)
        e.setIntegerValueField(.tabletEventPointButtons, value: 1)
        e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        e.setDoubleValueField(.mouseEventPressure, value: pressure)
        if let p = point {
            stampTabletPosition(e, p)
            let pose = resolveEffectivePose(point: p, snapshot: snapshot)
            e.setDoubleValueField(.tabletEventTiltX, value: pose.tiltX)
            e.setDoubleValueField(.tabletEventTiltY, value: pose.tiltY)
            e.setDoubleValueField(.tabletEventRotation, value: pose.rotation)
        }
        // Synthetic CGEvents default to click state 0; the release's value is
        // derived from this one in `stampClickSequence`.
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
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
        e.setIntegerValueField(.mouseEventSubtype, value: 1)
        e.setIntegerValueField(.tabletEventDeviceID, value: tabletDeviceID)
        e.setIntegerValueField(.tabletEventPointButtons, value: 0)
        e.setDoubleValueField(.tabletEventPointPressure, value: 0)
        e.setDoubleValueField(.mouseEventPressure, value: 0)
        if let p = point {
            stampTabletPosition(e, p)
            let pose = resolveEffectivePose(point: p, snapshot: snapshot)
            e.setDoubleValueField(.tabletEventTiltX, value: pose.tiltX)
            e.setDoubleValueField(.tabletEventTiltY, value: pose.tiltY)
            e.setDoubleValueField(.tabletEventRotation, value: pose.rotation)
        }
        // Click state is set in `stampClickSequence`, from the press.
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
        e.setIntegerValueField(.mouseEventSubtype, value: 1)
        e.setIntegerValueField(.tabletEventDeviceID, value: tabletDeviceID)
        e.setIntegerValueField(.tabletEventPointButtons, value: pressure > InputInjector.tipPressureThreshold ? 1 : 0)
        e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        e.setDoubleValueField(.mouseEventPressure, value: pressure)
        if let point {
            stampTabletPosition(e, point)
            e.setDoubleValueField(.tabletEventTiltX, value: pose.tiltX)
            e.setDoubleValueField(.tabletEventTiltY, value: pose.tiltY)
            e.setDoubleValueField(.tabletEventRotation, value: pose.rotation)
        }
        // Synthetic events default to zero deltas, which breaks controls that read
        // deltaX/Y (Xcode's minimap). NSEvent's deltaY is positive-up, so negate.
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
        if let point {
            e.setIntegerValueField(.mouseEventSubtype, value: 1)
            e.setIntegerValueField(.tabletEventDeviceID, value: tabletDeviceID)
            stampTabletPosition(e, point)
            e.setDoubleValueField(.tabletEventTiltX, value: pose.tiltX)
            e.setDoubleValueField(.tabletEventTiltY, value: pose.tiltY)
            e.setDoubleValueField(.tabletEventRotation, value: pose.rotation)
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
        e.setIntegerValueField(.tabletEventDeviceID, value: tabletDeviceID)
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
        stampProximityFields(e, entering: entering, eraser: eraser)
        e.flags = currentEventFlags
        finalizeAndPost(e)

        // Wacom's driver also sends each proximity change as a mouse event of
        // subtype 2 carrying the same fields; Cocoa apps that read proximity
        // from NSEvent subtypes only see this copy (event-probe, 2026-09-30).
        guard
            let m = CGEvent(
                mouseEventSource: sessionSource, mouseType: .mouseMoved,
                mouseCursorPosition: location, mouseButton: .left)
        else { return }
        m.setIntegerValueField(.mouseEventSubtype, value: 2)
        stampProximityFields(m, entering: entering, eraser: eraser)
        m.flags = moveSafeEventFlags
        finalizeAndPost(m)
    }

    private func stampProximityFields(_ e: CGEvent, entering: Bool, eraser: Bool) {
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
        e.setIntegerValueField(.tabletProximityEventDeviceID, value: tabletDeviceID)

        // Wacom sends each pen's serial; both ends share it, and the unique
        // ID below tells them apart. No app has yet been seen to key tool
        // settings on it (Photoshop, Krita, and Rebelle don't, 2026-09-30).
        let toolCode = activeToolCode
        if activeToolSerial != 0 {
            e.setIntegerValueField(
                .tabletProximityEventVendorPointerSerialNumber,
                value: Int64(activeToolSerial))
        }
        e.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 0)

        // pointerType: 1 = pen, 2 = cursor/mouse, 3 = eraser. Wacom keeps it on
        // the leaving event too; enterProximity alone marks the direction.
        let ptrType: Int64 = eraser ? 3 : (activeToolIsMouse ? 2 : 1)
        e.setIntegerValueField(.tabletProximityEventPointerType, value: ptrType)

        // The pen's own tool code, as Wacom reports it. The eraser end sets
        // bit 0x8 (Grip Pen 0x802 → 0x80A), which Photoshop and Krita need to
        // switch tools: Wacom keeps the pen's code but gives the eraser its own
        // unique ID, and without a serial ours would be identical.
        var vendorPtr: Int64
        let isArtPen: Bool
        if activeToolIsMouse {
            vendorPtr = 0x0006  // Intuos Mouse
            isArtPen = false
        } else {
            switch toolCode {
            case 0x0804, 0x1108, 0x1804:  // Art Pen variants
                vendorPtr = 0x0804
                isArtPen = true
            case 0x0842, 0x0832, 0x0852:  // Pro Pen 2, Stroke Pen, Intuos2 Grip Pen
                vendorPtr = Int64(toolCode)
                isArtPen = false
            default:
                vendorPtr = 0x0802  // Grip Pen fallback
                isArtPen = false
            }
        }
        if eraser { vendorPtr |= 0x8 }
        e.setIntegerValueField(.tabletProximityEventVendorPointerType, value: vendorPtr)
        // Unique per pen end: tool code above the serial, as Wacom's are built.
        e.setIntegerValueField(
            .tabletProximityEventVendorUniqueID,
            value: vendorPtr << 32 | Int64(activeToolSerial))
        // Wacom's mask minus abs Z (hover height), which we don't send: device
        // ID, abs X/Y, buttons, tilt X/Y, pressure, orientation; plus rotation
        // for Art Pens (Photoshop's Rotation brush control checks it). Tilt
        // stays even on tablets without it: no registry or catalog field says
        // which those are, and clearing it hid tilt from apps on every tablet.
        let capabilities: Int64 = isArtPen ? 0x35C7 : 0x15C7
        e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: capabilities)
        e.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
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
        case .clickLock:
            // Toggles on press; the key's own release does nothing.
            guard down else { break }
            if clickLocked {
                releaseClickLock(at: location, snapshot: snapshot)
            } else {
                clickLocked = true
                fireButtonAction(
                    .leftClick, down: true, at: location, snapshot: snapshot,
                    settings: settings, isAux: isAux)
            }
        case .leftClick:
            hoverDragButton = down ? .left : nil
            let type: CGEventType = down ? .leftMouseDown : .leftMouseUp
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: location, mouseButton: .left)
            {
                // Stamped like the other click actions. A bare event made the down and the
                // tip's up look like two streams, and AppKit rejected the up as
                // `receivedEventMidStream`. Pressure 0: a button, not a tip.
                e.setIntegerValueField(.mouseEventSubtype, value: 1)
                e.setIntegerValueField(.tabletEventDeviceID, value: tabletDeviceID)
                e.setIntegerValueField(.tabletEventPointButtons, value: down ? 1 : 0)
                e.setDoubleValueField(.tabletEventPointPressure, value: 0.0)
                e.setDoubleValueField(.mouseEventPressure, value: 0.0)
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
                e.setIntegerValueField(.tabletEventDeviceID, value: tabletDeviceID)
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
                e.setIntegerValueField(.tabletEventDeviceID, value: tabletDeviceID)
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
                e.setIntegerValueField(.tabletEventDeviceID, value: tabletDeviceID)
                e.setIntegerValueField(.tabletEventPointButtons, value: down ? 4 : 0)  // bit 2 = middle
                e.setDoubleValueField(.tabletEventPointPressure, value: down ? 1.0 : 0.0)
                e.setDoubleValueField(.mouseEventPressure, value: down ? 1.0 : 0.0)
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }
        case .keyCombo:
            let bindingFlags = CGEventFlags(rawValue: binding.modifierFlags)
            let modBits: [CGEventFlags] = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

            // Build the event before changing state, so a failed build leaves no
            // orphaned modifier bits.
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

            // Bracket with flagsChanged in hardware order (⌘ down, key down, key up,
            // ⌘ up). Rebelle tracks modifiers from flagsChanged alone.
            let bracketModifiers = !isModifierOnly && binding.modifierFlags != 0
            if bracketModifiers && !down {
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }

            // Aux bindings (ExpressKeys, ring center) use the shared store: a Quick
            // Keys Shift must reach drags posted by the pen tablet's injector. Pen
            // buttons stay local, reconciled against this device's tool.
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

            // Track the plain key itself so a lost up-transition can still be
            // caught by the same watchdogs that protect modifier bits — see
            // `heldKeyComboRefCounts`.
            if !isModifierOnly {
                let key = CGKeyCode(binding.keyCode)
                let count = heldKeyComboRefCounts[key] ?? 0
                if down {
                    heldKeyComboRefCounts[key] = count + 1
                } else {
                    heldKeyComboRefCounts[key] = Swift.max(0, count - 1)
                    if heldKeyComboRefCounts[key] == 0 { heldKeyComboRefCounts.removeValue(forKey: key) }
                }
                lastKeyComboChangeAt = Date()
            }
            // Post the flagsChanged brackets with the committed flags, one per bit,
            // each with its left-hand keycode (apps ignore keycode 0).
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
            // Span mode maps to every selected display simultaneously — there's
            // nothing to cycle, so a bound toggle button is inert here.
            guard snapshot.targetDisplayIndex != TabletSettings.displayModeSpan else { break }
            // Quick Keys move no pointer, so forward to the tablet driving the cursor.
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
        case .ringCycle, .ringCycle2:
            guard down else { break }
            // End any open zoom or rotate gesture before the mode changes.
            closeRingGestureEnvelopes()
            if let s = settings {
                let control: RotaryIndex = binding.kind == .ringCycle2 ? .second : .first
                // Live settings, not `snapshot`: two quick presses would
                // otherwise both advance from the same stale index.
                Task { @MainActor in
                    s.setActiveSlotIndex(s.rotary(control).indexAfterCycling(), for: control)
                }
            }
        case .ringSelectSlot, .ringSelectSlot2:
            guard down else { break }
            closeRingGestureEnvelopes()
            if let s = settings {
                let control: RotaryIndex =
                    binding.kind == .ringSelectSlot2 ? .second : .first
                let requested = Int(binding.keyCode)
                Task { @MainActor in
                    s.setActiveSlotIndex(
                        s.rotary(control).clampedSlotTarget(requested), for: control)
                }
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
        case .spanDisplaysToggle:
            guard down else { break }
            // Aux-only accessories steer the pen tablet, as with displayToggle.
            if let forward = spanDisplaysForwarder {
                forward()
                break
            }
            if let s = settings {
                Task { @MainActor in s.toggleTemporarySpan() }
            }
        case .relativeModeToggle:
            guard down else { break }
            // Quick Keys have no cursor; forward, as with displayToggleForwarder.
            if let forward = relativeModeToggleForwarder {
                forward()
                break
            }
            displayMapper.clearRelativeAnchor()
            if let s = settings {
                Task { @MainActor in s.relativeCursorMovement.toggle() }
            }
        case .scrollDrag:
            // Hold to pan: pen motion becomes scroll events. The button can live on
            // another device (a Quick Keys key while the pen pans), so the gesture runs
            // on whichever injector moves the pointer. Begin and end fire at once.
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
                // The backdate comes from `self`, whose debounce deferred the release, not
                // from `active`.
                active.postPanScroll(
                    active.panScroll.disengage(backdate: pendingButtonUpBackdate))
                if active.panScrollUsePhases {
                    active.panMomentumTail.start(velocity: active.panScroll.releaseVelocity)
                }
                SharedPanScrollState.shared.driver = nil
            }
        }

        // Safety valve: if nothing is physically held on the tablet but we still
        // believe a synthetic modifier (or plain keyCombo key) is pressed, it is
        // by definition a leak.
        if tabletIsQuiescent {
            if !groundTruthSyntheticFlags.isEmpty { releaseAllSyntheticModifiers() }
            if !heldKeyComboRefCounts.isEmpty { releaseAllHeldKeyComboKeys() }
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
        // The user's direction setting, applied once for every ring, strip, and
        // dial. `ringDeltaIsInverted` already normalized the hardware.
        let rawDelta = snapshot.reverseRingDirection ? -unflippedDelta : unflippedDelta
        // Scrolling glides through `RingScrollGlide`: exact distance per tick,
        // spread over a few frames. With a modifier held, apps read the wheel as
        // stepped zoom, and a 60 Hz stream was unusable in Adobe, so modifier-held
        // scrolling keeps one event per click.
        let zoomModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let modifierHeld = !moveSafeEventFlags.intersection(zoomModifiers).isEmpty
        // A modifier held mid-spin must not leave a dial gesture open.
        if modifierHeld { closeMechanicalDialGesture() }
        if hasMechanicalDial, !modifierHeld, case .scroll = slot.action {
            // Clamps Speed values saved under the old 20x ceiling, which would make
            // one click jump 600 points.
            let lines = Double(rawDelta) * min(slot.speed, 3.0)
            dialGlide.impulse(lines: Self.naturalScrollingEnabled ? lines : -lines)
            return
        }
        if slot.action == .zoom || slot.action == .rotate {
            // One post per tick, linearly scaled, on rings and dials alike. Dial clicks
            // are already discrete; an inertial coaster compounded zoom per click on the
            // Xencelabs puck. No natural-scrolling flip: it's a scroll setting.
            let kind: RingGestureKind = slot.action == .zoom ? .zoom : .rotate
            // Scale matches this control's steps/revolution: ring 72, Wacom
            // dial 24, Xencelabs dial 13.
            let scale: Double
            switch (kind, hasMechanicalDial) {
            case (.zoom, false): scale = Self.dialGestureZoomScale
            case (.zoom, true):
                scale = Self.dialGestureZoomScaleMechanical(steps: dialStepsPerRevolution)
            case (.rotate, false): scale = Self.dialGestureRotateScale
            case (.rotate, true):
                scale = Self.dialGestureRotateScaleMechanical(steps: dialStepsPerRevolution)
            }
            let delta = Double(rawDelta) * slot.speed * scale
            if hasMechanicalDial {
                // A dial has no touch to bracket the gesture, so an idle timer ends it
                // once clicks stop.
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
        if !modifierHeld, case .scroll = slot.action {
            let lines = Double(rawDelta) * slot.speed
            ringGlide.impulse(lines: Self.naturalScrollingEnabled ? lines : -lines)
            return
        }
        accum += Double(rawDelta) * slot.speed
        let lines = Int(accum)
        guard lines != 0 else { return }
        accum -= Double(lines)
        switch slot.action {
        case .scroll:
            // Clockwise scrolls down. macOS doesn't apply natural scrolling to injected
            // events, so apply it here.
            let signedLines = Self.naturalScrollingEnabled ? lines : -lines
            // AppKit clamps a large .line delta well below its value (Xencelabs dial,
            // 2026-08-06), so split fast bursts. Single ticks stay one event. Wacom
            // rings and strips only; moving them to pixel units needs a hardware pass.
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
            // Unreachable; kept exhaustive so a new Action case gets caught here.
            break
        }
    }

    func postScrollWheelEvent(delta: Int, at location: CGPoint) {
        // Continuous pixel events, like `postDialScroll`: Mac Mouse Fix and MOS
        // re-accelerate non-continuous wheel events from non-Wacom senders. With a
        // modifier held, apps read stepped zoom, so keep `.line` detents there.
        let zoomModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        if currentEventFlags.intersection(zoomModifiers).isEmpty {
            // Same 3 lines per detent, at the ~10 px/line scale
            // `applyTrackpadDeltaFields` uses. No phases, as in `postDialScroll`.
            let dy = Double(delta * 3 * 10)
            guard
                let e = CGEvent(
                    scrollWheelEvent2Source: sessionSource, units: .pixel,
                    wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0)
            else { return }
            e.location = location
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            applyTrackpadDeltaFields(e, dx: 0, dy: dy)
            e.flags = currentEventFlags
            finalizeAndPost(e)
            return
        }
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

    /// Builds ring, strip, and dial scroll events; the smoothing lives in
    /// `ringGlide`/`dialGlide`. Pixel units: a 60 Hz glide needs sub-line steps,
    /// and small deltas never hit AppKit's clamp. No phases: a dial has no touch
    /// to bracket.
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
        // Ground-truth flags: the glide keeps posting after the click, when a held
        // modifier may be gone.
        e.flags = moveSafeEventFlags
        finalizeAndPost(e)
    }

    /// Zoom per ring tick, as a magnification fraction. Tuned on the PTH-860
    /// (2026-09). Ring only: zoom compounds per tick, so a dial's fewer ticks
    /// need their own constant (`dialGestureZoomScaleMechanical`).
    static let dialGestureZoomScale = 1.0 / 300.0

    /// **Mechanical dial only.** `dialGestureZoomScale` scaled by ring 72 :
    /// dial `steps`, so a revolution zooms about as far as on the ring.
    /// Approximate because zoom compounds (Xencelabs ≈5.99x vs ring ≈6.65x).
    static func dialGestureZoomScaleMechanical(steps: Double) -> Double {
        dialGestureZoomScale * 72.0 / steps
    }

    /// Radians per ring tick at 1x: 72 steps make one turn equal one full
    /// canvas rotation. Ring only; the dial has its own step count
    /// (`dialGestureRotateScaleMechanical`).
    static let dialGestureRotateScale = Double.pi / 36.0

    /// **Mechanical dial only.** One revolution rotates 360° at 1x speed.
    /// Coarse steps (15° at 24, 27.7° at 13) are why it reads steppier than
    /// the ring's 5°; the input stream has nothing finer to smooth with.
    static func dialGestureRotateScaleMechanical(steps: Double) -> Double {
        2.0 * Double.pi / steps
    }

    /// PTK-470/670/870 gen-3 dials: 24 `0x11` reports per slow revolution,
    /// measured on a PTK-870. The 38 ridges are grip, not detents. Bluetooth
    /// sends one frame per detent too.
    static let wacomDialStepsPerRevolution = 24.0

    /// Xencelabs Quick Keys puck: 13 report-0x02 frames per slow revolution,
    /// no finer magnitude. Fast turns drop steps in hardware.
    static let xencelabsDialStepsPerRevolution = 13.0

    /// Posts a ring or dial gesture event. Callers pre-scale `delta` and pass 0
    /// for `.began` and `.ended`.
    func postRingGesture(delta: Double, phase: TouchStateTracker.ScrollPhase, kind: RingGestureKind) {
        switch kind {
        case .zoom: postTouchMagnify(magnification: delta, phase: phase)
        case .rotate: postTouchRotate(rotation: delta, phase: phase)
        }
    }

    // MARK: - Scroll Drag (pan)

    /// Which injector hosts a Pan View gesture: the tablet moving the pointer
    /// with the pen in range, else the one that got the binding.
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

    /// Panning method, captured at engage from `ToolSettings.panScrollMomentum`.
    /// See `postPanScroll`.

    /// Builds Pan View events: pixel units plus the continuous flag read as a
    /// trackpad pan. Kept small as the seam for a future virtual-trackpad backend.
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

    /// Fills the delta fields a trackpad sends, which
    /// `CGEvent(scrollWheelEvent2Source:)` leaves at zero. Apps that read NSEvent
    /// deltas (Calendar, WebKit, Chromium, Adobe palettes) ignored pans without them.
    func applyTrackpadDeltaFields(_ e: CGEvent, dx: Double, dy: Double) {
        // Lines first: writing them recomputes the point and fixed-point fields,
        // and writing them last quantized pans to 8 pt (event-probe, 2026-09-30).
        // At least 1 line, so slow pans aren't lost on the line-delta path.
        let ix = Int64(dx), iy = Int64(dy)
        e.setIntegerValueField(
            .scrollWheelEventDeltaAxis1,
            value: iy == 0 ? 0 : max(1, abs(iy) / 10) * (iy < 0 ? -1 : 1))
        e.setIntegerValueField(
            .scrollWheelEventDeltaAxis2,
            value: ix == 0 ? 0 : max(1, abs(ix) / 10) * (ix < 0 ? -1 : 1))
        // Fixed-point deltas are fractional lines, as a trackpad sends them.
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy / 10)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx / 10)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy.rounded()))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx.rounded()))
    }

    // MARK: - Scroll Drag momentum tail (Natural mode)

    /// Builds the Pan View momentum tail; the decay lives in `panMomentumTail`.
    /// Scroll phase stays 0 while momentum phase runs: both nonzero confuses
    /// AppKit and WebKit.
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
