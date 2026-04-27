// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026  This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab.  If not, see <https://www.gnu.org/licenses/>.

import AppKit
import CoreGraphics
import os

private let modLog = Logger(subsystem: "com.cyzor.mocktab", category: "modifiers")

/// Converts raw TabletPoint reports into CGEvents and posts them to the HID event tap.
///
/// Event sequence per report:
///   • Proximity change  → tabletProximity event (immediate)
///   • Every in-proximity report:
///       1. tabletPointer  — raw pressure/tilt for Qt/GTK (Krita, GIMP)
///       2. mouse event    — leftMouseDown / leftMouseDragged / leftMouseUp / mouseMoved
///          with .mouseEventPressure + .mouseEventSubtype=tabletPoint + .mouseEventClickState
///
/// Throughput strategy:
///   Posts CGEvents only when position or pressure changes meaningfully (delta gate).
///   When the pen is stationary the tablet still sends 133 Hz reports with identical
///   coordinates; the gate suppresses all of them — zero Mach IPC, zero wakeups.
///   Tip/button/proximity transitions always post immediately regardless of delta.
///
/// Must run on the main actor — IOHIDManager callbacks are on CFRunLoopGetMain().
@MainActor
final class InputInjector {

    // MARK: - Device identity

    var deviceVendorID: Int
    var deviceProductID: Int
    var activeToolSettings: ToolSettings? = nil {
        didSet { reconcileSyntheticFlags() }
    }
    /// When true the active tool is a cordless mouse.
    /// tipDown is driven by penButton1 instead of pressure, and button1 is
    /// not dispatched as a separate button action (it already fires the primary click).
    var activeToolIsMouse: Bool = false
    /// Cached eraser flag. Primary source: set by TabletManager.onToolEnter from ToolIdentity.isEraser
    /// when the tool code changes (covers tool-flip without a proximity gap). Also refreshed at
    /// proximity entry from point.eraser as defense-in-depth; cleared at proximity exit.
    var activeToolIsEraser: Bool = false
    /// Serial number of the active tool. Set by TabletManager.onToolEnter; 0 if unavailable.
    /// Used in proximity events so apps key per-tool brush memory on the correct identity.
    var activeToolSerial: UInt32 = 0
    /// The tool code for the current tool. Used for proximity events and tool identification.
    /// May be overridden by forcedToolCode from DeviceRegistry if set by the user.
    var activeToolCode: UInt16 = 0x0802

    /// When true, the frontmost app consumes `.tabletPointer` CGEvents (Qt/GTK: Krita, GIMP).
    /// Set by AppWatcher on every app switch. When false, postTabletPointerEvent is skipped,
    /// saving one WindowServer IPC round-trip per inject() call.
    var activeAppNeedsTabletPointerEvents: Bool = false

    init(vendorID: Int = 0x056A, productID: Int = 0) {
        self.deviceVendorID = vendorID
        self.deviceProductID = productID
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated {
            self?.cachedDisplayIndex = Int.min
            self?.cachedCalibrationOrientation = -1
        } }
        leakWatchdogTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkLeakWatchdog() }
        }
    }

    deinit {
        if let obs = displayObserver { NotificationCenter.default.removeObserver(obs) }
        leakWatchdogTimer?.invalidate()
    }

    // MARK: - State

    private(set) var lastProximity = false
    private var lastTipDown = false
    private var lastEraserMode = false  // Track eraser/tip flip while in proximity
    private var lastButton1Down = false
    private var lastButton2Down = false
    private var lastMiddleDown = false
    private var activeButton: CGMouseButton = .left

    // MARK: - USB mouse button state
    //
    // For KC-100 cordless mouse over USB: buttons arrive on a separate standard
    // HID mouse interface (Report ID 0x01) rather than in the digitizer 0x10 stream.
    // injectMouseButtons() is called from that interface's device driver; inject()
    // reads usbMouseLeftHeld to decide drag vs hover when emitting movement events.
    private var lastUSBMouseMask: UInt8 = 0
    private var usbMouseLeftHeld: Bool = false

    // MARK: - Jitter tracking
    //
    // Fixed ring buffer + running sum.
    // Eliminates O(n) Array.removeFirst() and a full reduce() on every jitterLevel read.

    private static let jitterWindow = 60  // ~0.5 s at 133 Hz
    private var hoverRing = ContiguousArray<CGFloat>(repeating: 0, count: jitterWindow)
    private var hoverHead = 0
    private var hoverCount = 0
    private var hoverSum: CGFloat = 0
    private var lastRawPoint: CGPoint = .zero
    private var hasLastRawPoint = false

    /// Mean hover-position delta over the rolling window (points per sample).
    /// Spikes above ~3 pt/sample while hovering suggest RF interference.
    var jitterLevel: CGFloat {
        guard hoverCount >= 10 else { return 0 }
        return hoverSum / CGFloat(hoverCount)
    }

    var isJittery: Bool { jitterLevel > 3.0 }

    private func addHoverDelta(_ delta: CGFloat) {
        if hoverCount == Self.jitterWindow {
            hoverSum -= hoverRing[hoverHead]
        } else {
            hoverCount += 1
        }
        hoverRing[hoverHead] = delta
        hoverSum += delta
        hoverHead = (hoverHead + 1) % Self.jitterWindow
    }

    private func clearHoverDeltas() {
        guard hoverCount > 0 else { return }
        hoverCount = 0
        hoverSum = 0
    }

    // MARK: - Relative movement
    //
    // When relativeCursorMovement is enabled, the pen acts like a mouse: each report
    // moves the cursor by the delta from the previous normalized tablet position,
    // scaled to the display size.  lastRelativeNorm is cleared at proximity exit so
    // the first report after hover-entry doesn't produce a large jump.

    private var lastRelativeNorm: CGPoint? = nil

    // MARK: - Smoothing

    private var smoothedPoint: CGPoint = .zero
    private var hasSmoothedPoint = false
    /// Cached EMA alpha, recomputed at proximity entry.
    /// 1.0 == raw (no smoothing); math collapses to smoothedPoint = rawPoint.
    private var smoothingAlpha: Double = 1.0

    // MARK: - Delta gate
    //
    // Skip posting to the Window Server when position and pressure haven't changed
    // meaningfully. The tablet sends identical coordinates at 133 Hz while stationary;
    // suppressing those drops Mach IPC to zero and eliminates idle wakeups entirely.

    private static let positionEpsilon: CGFloat = 0.5  // sub-pixel, not worth posting
    private static let pressureEpsilon: Double = 0.002

    // MARK: - Tip-up assist
    //
    // When enabled, delays the mouseUp briefly after the tip lifts if the pen is still
    // in motion. This prevents accidental stroke termination from light tip-release
    // during fast strokes. The pending mouseUp is cancelled if the tip comes back down.

    private static let tipUpAssistDelay: Double = 0.08  // seconds
    private static let tipUpAssistVelocityThreshold: CGFloat = 2.0  // pts/sample
    private var pendingMouseUp: DispatchWorkItem? = nil
    /// Rolling short-window velocity estimate (last 4 position deltas, screen pts/sample).
    private var recentDeltas = ContiguousArray<CGFloat>(repeating: 0, count: 4)
    private var recentDeltaHead = 0

    private func recordMoveDelta(_ delta: CGFloat) {
        recentDeltas[recentDeltaHead] = delta
        recentDeltaHead = (recentDeltaHead + 1) % recentDeltas.count
    }

    private var recentVelocity: CGFloat {
        recentDeltas.reduce(0, +) / CGFloat(recentDeltas.count)
    }

    /// Set while a barrel-button click binding is held, so the movement path posts
    /// otherMouseDragged / rightMouseDragged instead of mouseMoved.
    private var hoverDragButton: CGMouseButton? = nil

    private var lastPostedPoint: CGPoint = .zero
    private var lastPostedPressure: Double = -1.0
    private var hasPostedPoint = false

    // MARK: - Click state

    private var lastClickPosition: CGPoint = .zero
    private var lastClickTime: CFAbsoluteTime = 0
    private var clickCount: Int = 0
    private var activeClickCount: Int = 1

    // MARK: - Express key / touch ring state

    private var lastAuxButtons = [Bool](repeating: false, count: 16)
    private var lastRingButtonDown = false
    /// Last observed touch ring position (0–71). 0x7F = no contact.
    private var lastRingPos: UInt8 = 0x7F
    /// Last observed right touch ring position (DTK-2400). 0x7F = no contact.
    private var lastRing2Pos: UInt8 = 0x7F
    /// Last observed Intuos3 WS touch strip positions. 0xFF = no contact.
    private var lastStrip1Pos: UInt8 = 0xFF
    private var lastStrip2Pos: UInt8 = 0xFF
    /// Fractional-delta accumulators for ring/strip speed scaling.
    /// Carry sub-integer remainders across pulses so speed < 1.0 fires evenly.
    private var ringAccum: Double = 0
    private var ring2Accum: Double = 0
    private var strip1Accum: Double = 0
    private var strip2Accum: Double = 0

    // MARK: - Synthetic-modifier safety valves

    /// Idle watchdog. If the driver thinks a modifier is held but no tablet
    /// activity arrives for `watchdogInterval`, release all synthetic flags.
    /// Rearmed on every inject/injectAux/injectMouseButtons/fireButtonAction.
    /// At 133 Hz pen reporting this never expires during legitimate holds —
    /// the pen leaving the tablet is what stops the stream, at which point
    /// any still-held synthetic flag is by definition a leak.
    private var watchdogItem: DispatchWorkItem?
    private let watchdogInterval: DispatchTimeInterval = .milliseconds(400)

    // MARK: - Time-based leak watchdog
    //
    // Second safety net that fires even when lastAuxButtons is stuck (e.g. USB
    // disconnect mid-press). Unlike the DispatchWorkItem watchdog above, which
    // is only armed while tablet activity is flowing, this 1 Hz timer runs
    // continuously and does not depend on quiescence flags being correct.

    private var leakWatchdogTimer: Timer?
    /// Timestamp of the last groundTruthSyntheticFlags mutation.
    private var lastSyntheticFlagChangeAt: Date = .distantPast
    /// Timestamp of the last tablet HID report (inject / injectAux / injectMouseButtons).
    /// Stamped inside rearmWatchdog(), which every entry point calls.
    private var lastInjectCallAt: Date = .distantPast

    /// True when no physical tablet control is held. If this holds and
    /// `groundTruthSyntheticFlags` is non-empty, the flags are a leak.
    private var tabletIsQuiescent: Bool {
        !lastTipDown && !lastButton1Down && !lastButton2Down
            && !lastRingButtonDown
            && lastRingPos == 0x7F && lastRing2Pos == 0x7F
            && lastStrip1Pos == 0xFF && lastStrip2Pos == 0xFF
            && lastUSBMouseMask == 0
            && !lastAuxButtons.contains(true)
    }

    private func rearmWatchdog() {
        lastInjectCallAt = Date()
        watchdogItem?.cancel()
        guard !groundTruthSyntheticFlags.isEmpty else {
            watchdogItem = nil
            return
        }
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.groundTruthSyntheticFlags.isEmpty else { return }
                self.releaseAllSyntheticModifiers()
            }
        }
        watchdogItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogInterval, execute: item)
    }

    /// 1 Hz time-based leak detection. Fires even when `lastAuxButtons` is corrupt
    /// (e.g. USB disconnect mid-press), a scenario where the DispatchWorkItem watchdog
    /// above is never rearmed and therefore never fires.
    ///
    /// Condition: synthetic flags have been stuck in the same state for > 3 s AND the
    /// tablet has been completely idle for > 3 s. A legitimately held express-key keeps
    /// resetting `lastInjectCallAt` via `rearmWatchdog`, so this never fires during real use.
    private func checkLeakWatchdog() {
        guard !groundTruthSyntheticFlags.isEmpty else { return }
        let heldInterval = Date().timeIntervalSince(lastSyntheticFlagChangeAt)
        let idleInterval = Date().timeIntervalSince(lastInjectCallAt)
        if heldInterval > 3.0 && idleInterval > 3.0 {
            modLog.notice("leak-watchdog: releasing stuck synthetic flags 0x\(String(self.groundTruthSyntheticFlags.rawValue, radix: 16), privacy: .public) (held \(Int(heldInterval))s, idle \(Int(idleInterval))s)")
            releaseAllSyntheticModifiers()
        }
    }

    // MARK: - Adobe shim replay cache
    //
    // Populated on every inject() call so WacomShim can re-emit the last
    // tablet event in response to an Apple Events eSendTabletEvent request.

    private(set) var shimLastPoint: TabletPoint? = nil
    private(set) var shimLastScreen: CGPoint = .zero
    private(set) var shimLastPressure: Double = 0.0

    // MARK: - Display bounds cache

    private var cachedDisplayBounds: CGRect = .zero
    private var cachedDisplayIndex: Int = Int.min
    private var cachedDisplayID: CGDirectDisplayID = 0
    private var cachedCalibration: CalibrationEntry?
    private var cachedCalibrationOrientation: Int = -1
    private var currentToggleIndex: Int = 0
    private var displayObserver: NSObjectProtocol?

    // MARK: - Pen injection

    func inject(point: TabletPoint, settings: TabletSettings?) {
        rearmWatchdog()
        let settings = settings ?? TabletSettings()
        let tool = activeToolSettings ?? settings.activeTool
        var point = point
        if settings.invertRotation && point.rotation != 0.0 {
            point.rotation = (360.0 - point.rotation).truncatingRemainder(dividingBy: 360.0)
        }
        let rawPoint: CGPoint
        if settings.relativeCursorMovement {
            rawPoint = resolveRelativePoint(point, settings: settings)
        } else {
            guard let absPoint = mapToScreen(point, settings: settings) else {
                // Pen outside active area — deadzone, no events
                lastRelativeNorm = nil
                return
            }
            rawPoint = absPoint
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

        let enteringProximity = point.inProximity && !lastProximity
        let eraserFlipped = point.inProximity && lastProximity && (point.eraser != lastEraserMode)

        // ── Proximity transitions (always immediate) ───────────────────────────
        if point.inProximity != lastProximity {
            postProximityEvent(
                entering: point.inProximity, at: rawPoint,
                eraser: point.eraser)
            if point.inProximity {
                activeToolIsEraser = point.eraser
                lastEraserMode = point.eraser
                let s = tool.smoothingStrength
                smoothingAlpha = s > 0 ? 1.0 - s * 0.85 : 1.0
            } else {
                activeToolIsEraser = false
                lastEraserMode = false
                if lastTipDown {
                    postMouseUp(
                        button: activeButton, at: smoothedPoint,
                        clickCount: activeClickCount,
                        settings: settings)
                    lastTipDown = false
                }
                // Release any USB HID mouse buttons that were held when the tool left
                // the tablet (e.g. user yanked the KC-100 off the surface mid-drag).
                if lastUSBMouseMask != 0 {
                    if usbMouseLeftHeld {
                        postMouseUp(
                            button: .left, at: smoothedPoint,
                            clickCount: activeClickCount,
                            settings: settings)
                        usbMouseLeftHeld = false
                    }
                    if (lastUSBMouseMask & 0x02) != 0 {
                        postMouseUp(
                            button: .right, at: smoothedPoint, clickCount: 1,
                            settings: settings)
                    }
                    if (lastUSBMouseMask & 0x04) != 0 {
                        if let e = CGEvent(
                            mouseEventSource: sessionSource, mouseType: .otherMouseUp,
                            mouseCursorPosition: smoothedPoint, mouseButton: .center)
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
                        mouseCursorPosition: smoothedPoint, mouseButton: .center)
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

                // Proximity-exit modifier sync: our last injected events may have carried
                // physical modifier bits (e.g. ⌘=1 because the user held ⌘ while drawing).
                // When inject() stops at proximity exit, apps that track modifier state from
                // tablet event flags (Illustrator, Photoshop) retain that last value.  The
                // physical keyboard's own flagsChanged(⌘=0) travels a separate path and may
                // arrive before or after our final event — timing is non-deterministic.
                // Explicitly post a flagsChanged for each managed bit that was in our last
                // injected event, stamped with hidSystemState at this instant.  If the key
                // is already physically released, apps are corrected to ⌘=0.  If still held,
                // the event is a no-op (just confirms the physical state apps already know).
                if lastLoggedManagedFlags != 0 {
                    modLog.debug("proximity-exit: syncing managed flags (last=0x\(String(self.lastLoggedManagedFlags, radix: 16), privacy: .public))")
                    let toSync = CGEventFlags(rawValue: lastLoggedManagedFlags)
                    for (bit, keyCode) in Self.modifierKeyCodes where toSync.contains(bit) {
                        guard let e = CGEvent(source: sessionSource) else { continue }
                        e.type = .flagsChanged
                        e.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
                        finalizeAndPost(e)
                    }
                }

                // Reset aux state so the next injectAux fires fresh transitions.
                pendingMouseUp?.cancel()
                pendingMouseUp = nil
                hoverDragButton = nil
                lastAuxButtons = [Bool](repeating: false, count: 16)
                lastRingButtonDown = false
                hasSmoothedPoint = false
                hasLastRawPoint = false
                hasPostedPoint = false
                lastRelativeNorm = nil
                lastPostedPressure = -1.0
                clearHoverDeltas()
                for i in recentDeltas.indices { recentDeltas[i] = 0 }
                recentDeltaHead = 0
            }
            lastProximity = point.inProximity
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
        if enteringProximity || !hasSmoothedPoint {
            smoothedPoint = rawPoint
            hasSmoothedPoint = true
        } else {
            smoothedPoint = CGPoint(
                x: smoothedPoint.x + smoothingAlpha * (rawPoint.x - smoothedPoint.x),
                y: smoothedPoint.y + smoothingAlpha * (rawPoint.y - smoothedPoint.y)
            )
        }
        let screenPoint = smoothedPoint
        shimLastPoint = point
        shimLastScreen = screenPoint
        shimLastPressure = pressure

        // ── Jitter tracking (hover only, every report) ─────────────────────────
        if !tipDown {
            if hasLastRawPoint {
                addHoverDelta(
                    hypot(
                        rawPoint.x - lastRawPoint.x,
                        rawPoint.y - lastRawPoint.y))
            }
            lastRawPoint = rawPoint
            hasLastRawPoint = true
        } else {
            hasLastRawPoint = false
            clearHoverDeltas()
        }

        // ── Tip press transitions (always immediate) ───────────────────────────
        if tipDown != lastTipDown {
            if !activeToolIsMouse && activeAppNeedsTabletPointerEvents {
                postTabletPointerEvent(
                    at: screenPoint, pressure: pressure, point: point, settings: settings)
            }
            if tipDown {
                // Cancel any pending deferred mouseUp — tip is back down.
                pendingMouseUp?.cancel()
                pendingMouseUp = nil
                let tipAction = activeToolIsEraser ? tool.eraserBinding : tool.tipBinding
                activeButton = tipAction.mouseButton ?? .left
                let (clickPt, count) = resolveClick(screenPoint, settings: settings)
                activeClickCount = count
                postMouseDown(
                    button: activeButton, at: clickPt,
                    pressure: pressure, clickCount: count,
                    point: point,
                    settings: settings)
            } else {
                let btn = activeButton
                let count = activeClickCount
                let pt = point
                let sp = screenPoint

                if settings.tipUpAssist && recentVelocity > Self.tipUpAssistVelocityThreshold {
                    // Defer the mouseUp briefly so fast strokes aren't cut short.
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.pendingMouseUp != nil else { return }
                        self.pendingMouseUp = nil
                        self.postMouseUp(
                            button: btn, at: sp, clickCount: count, point: pt, settings: settings)
                    }
                    pendingMouseUp = work
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + Self.tipUpAssistDelay, execute: work)
                } else {
                    postMouseUp(
                        button: activeButton, at: screenPoint,
                        clickCount: activeClickCount, point: point,
                        settings: settings)
                }
            }
            lastPostedPoint = screenPoint
            lastPostedPressure = pressure
            hasPostedPoint = true

        } else {
            // ── Continuous movement: delta gate ────────────────────────────────
            let moved =
                !hasPostedPoint
                || abs(screenPoint.x - lastPostedPoint.x) > Self.positionEpsilon
                || abs(screenPoint.y - lastPostedPoint.y) > Self.positionEpsilon
                || (tipDown && abs(pressure - lastPostedPressure) > Self.pressureEpsilon)

            if moved {
                // Track velocity for tip-up assist.
                if hasPostedPoint {
                    let delta = hypot(
                        screenPoint.x - lastPostedPoint.x,
                        screenPoint.y - lastPostedPoint.y)
                    recordMoveDelta(delta)
                }
                if !activeToolIsMouse && activeAppNeedsTabletPointerEvents {
                    postTabletPointerEvent(
                        at: screenPoint, pressure: pressure, point: point, settings: settings)
                }
                // USB mouse left button held (KC-100): injectMouseButtons() already sent
                // leftMouseDown; use leftMouseDragged so apps receive proper drag events.
                let dragging = tipDown || (activeToolIsMouse && usbMouseLeftHeld)
                if dragging {
                    postMouseDrag(
                        button: activeButton, at: screenPoint, pressure: pressure, point: point,
                        settings: settings)
                } else if let dragBtn = hoverDragButton {
                    // Barrel button held while hovering — send otherMouseDragged /
                    // rightMouseDragged so apps like SketchUp receive a proper drag stream.
                    postMouseDrag(
                        button: dragBtn, at: screenPoint, pressure: 0, point: point,
                        settings: settings)
                } else {
                    postMouseMoved(
                        at: screenPoint, point: point,
                        settings: settings)
                }
                lastPostedPoint = screenPoint
                lastPostedPressure = pressure
                hasPostedPoint = true
            }
        }
        lastTipDown = tipDown

        // ── Pen button transitions (always immediate) ──────────────────────────
        let btn1 = tool.penButton1Binding
        let btn2 = tool.penButton2Binding

        if point.penButton1 != lastButton1Down {
            // Update tracking state first so the quiescent check inside
            // fireButtonAction sees the current button state, not the pre-transition state.
            lastButton1Down = point.penButton1
            // For mouse tools button1 drives the primary click (tipDown above);
            // dispatching it again as a button action would double-fire.
            if !activeToolIsMouse {
                fireButtonAction(btn1, down: point.penButton1, at: screenPoint, settings: settings)
            }
        }
        if point.penButton2 != lastButton2Down {
            lastButton2Down = point.penButton2
            fireButtonAction(btn2, down: point.penButton2, at: screenPoint, settings: settings)
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

    // MARK: - Adobe shim replay

    /// Re-emits the last tablet pointer event.
    /// Called by TabletManager when WacomShim receives an eSendTabletEvent(eEventPointer)
    /// Apple Event from Adobe Photoshop / Illustrator.
    func replayPointerEvent(settings: TabletSettings? = nil) {
        guard let point = shimLastPoint else { return }
        let s = settings ?? TabletSettings()
        postTabletPointerEvent(
            at: shimLastScreen, pressure: shimLastPressure, point: point, settings: s)
        let dragging = lastTipDown || (activeToolIsMouse && usbMouseLeftHeld)
        if dragging {
            postMouseDrag(
                button: activeButton, at: shimLastScreen, pressure: shimLastPressure, point: point,
                settings: s)
        } else {
            postMouseMoved(at: shimLastScreen, point: point, settings: s)
        }
    }

    /// Re-emits the last proximity event.
    /// Called when WacomShim receives eSendTabletEvent(eEventProximity) from Adobe.
    func replayProximityEvent() {
        guard shimLastPoint != nil else { return }
        postProximityEvent(
            entering: lastProximity, at: shimLastScreen,
            eraser: shimLastPoint?.eraser ?? false)
    }

    // MARK: - USB HID mouse button injection (KC-100 cordless mouse)
    //
    // Called by WacomKnownDevice when a 4-byte Report ID 0x01 arrives from the
    // standard mouse interface (usagePage=0x01).  Fires left/right/middle down/up
    // CGEvents at the current cursor location; sets usbMouseLeftHeld so inject()
    // promotes subsequent mouseMoved events to leftMouseDragged while left is held.

    func injectMouseButtons(mask: UInt8, settings: TabletSettings?) {
        rearmWatchdog()
        guard mask != lastUSBMouseMask else { return }
        let s = settings ?? TabletSettings()
        let loc = currentCursorPosition()
        let oldMask = lastUSBMouseMask
        lastUSBMouseMask = mask

        let leftNow = (mask & 0x01) != 0
        let leftWas = (oldMask & 0x01) != 0
        let rightNow = (mask & 0x02) != 0
        let rightWas = (oldMask & 0x02) != 0
        let midNow = (mask & 0x04) != 0
        let midWas = (oldMask & 0x04) != 0

        if leftNow != leftWas {
            usbMouseLeftHeld = leftNow
            activeButton = .left
            if leftNow {
                let (clickPt, count) = resolveClick(loc, settings: s)
                activeClickCount = count
                postMouseDown(
                    button: .left, at: clickPt, pressure: 1.0, clickCount: count, settings: s)
            } else {
                postMouseUp(button: .left, at: loc, clickCount: activeClickCount, settings: s)
            }
            lastPostedPoint = loc
            hasPostedPoint = true
        }
        if rightNow != rightWas {
            if rightNow {
                postMouseDown(button: .right, at: loc, pressure: 1.0, clickCount: 1, settings: s)
            } else {
                postMouseUp(button: .right, at: loc, clickCount: 1, settings: s)
            }
        }
        // Button 3 (bit 2) — routed through configured binding
        if midNow != midWas {
            let tool = activeToolSettings
            let binding = tool?.penButton3Binding ?? .middleClick
            fireButtonAction(binding, down: midNow, at: loc, settings: s)
        }
        // Button 4 (bit 3) — routed through configured binding
        let btn4Now = (mask & 0x08) != 0
        let btn4Was = (oldMask & 0x08) != 0
        if btn4Now != btn4Was {
            let tool = activeToolSettings
            let binding = tool?.penButton4Binding ?? .none
            fireButtonAction(binding, down: btn4Now, at: loc, settings: s)
        }
        // Button 5 (bit 4) — routed through configured binding
        let btn5Now = (mask & 0x10) != 0
        let btn5Was = (oldMask & 0x10) != 0
        if btn5Now != btn5Was {
            let tool = activeToolSettings
            let binding = tool?.penButton5Binding ?? .none
            fireButtonAction(binding, down: btn5Now, at: loc, settings: s)
        }
    }

    // MARK: - Express key injection

    /// Ring/strip rotations are discrete pulses, not holds. Pairing down+up in a
    /// single call prevents modifier bits in the binding from leaking into
    /// `groundTruthSyntheticFlags` across rotation samples.
    private func fireKeyTap(_ binding: ButtonBinding,
                            at loc: CGPoint,
                            settings: TabletSettings) {
        fireButtonAction(binding, down: true, at: loc, settings: settings)
        fireButtonAction(binding, down: false, at: loc, settings: settings)
    }

    func injectAux(buttons: AuxButtons, settings: TabletSettings?) {
        rearmWatchdog()
        let s = settings ?? TabletSettings()
        let bindings = s.expressKeyBindings
        let cursorPos = currentCursorPosition()

        // ── Express keys ───────────────────────────────────────────────────────
        for i in 0..<16 {
            let down = buttons[i]
            let hasMechanicalPulse = i < 8 && (buttons.mechanicalMask >> i) & 1 != 0
            if down != lastAuxButtons[i] {
                // Update tracking state first so the quiescent check inside
                // fireButtonAction sees the current button state, not the pre-transition state.
                lastAuxButtons[i] = down
                fireButtonAction(bindings[i], down: down, at: cursorPos, settings: s)
            } else if down && hasMechanicalPulse {
                // Button is already tracked as down, but a new mechanical pulse arrived —
                // the user re-pressed before the release event was seen. Force a complete
                // up→down cycle so the key fires correctly without getting swallowed.
                fireButtonAction(bindings[i], down: false, at: cursorPos, settings: s)
                fireButtonAction(bindings[i], down: true, at: cursorPos, settings: s)
                // lastAuxButtons[i] stays true — the button is still down after this cycle
            }
        }

        // ── Touch ring center button ───────────────────────────────────────────
        let ringButtonDown = buttons.touchRingButtonDown
        if ringButtonDown != lastRingButtonDown {
            lastRingButtonDown = ringButtonDown
            fireButtonAction(
                s.touchRingButtonBinding, down: ringButtonDown, at: cursorPos, settings: s)
        }

        // ── Touch ring ─────────────────────────────────────────────────────────
        // Position 0x7F means no contact.  Compute a wrap-aware delta when a
        // finger is actively moving (both current and previous positions valid).
        // The ring has 72 steps (0–71, ~5° each); wrap threshold is 36.
        let ringPos = buttons.touchRingPosition
        if buttons.touchRingActive, lastRingPos != 0x7F {
            var delta = Int(ringPos) - Int(lastRingPos)
            if delta > 36 { delta -= 72 }
            if delta < -36 { delta += 72 }
            if delta != 0,
               let slot = s.touchRingSlots.indices.contains(s.touchRingActiveSlotIndex)
                   ? s.touchRingSlots[s.touchRingActiveSlotIndex] : nil
            {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &ringAccum, at: cursorPos, settings: s)
            }
        }
        if !buttons.touchRingActive { ringAccum = 0 }
        lastRingPos = buttons.touchRingActive ? ringPos : 0x7F

        // ── Touch ring 2 (DTK-2400 right bezel) — shares touchRingSlots ──
        let ring2Pos = buttons.touchRing2Position
        if buttons.touchRing2Active, lastRing2Pos != 0x7F {
            var delta = Int(ring2Pos) - Int(lastRing2Pos)
            if delta > 36 { delta -= 72 }
            if delta < -36 { delta += 72 }
            if delta != 0,
               let slot = s.touchRingSlots.indices.contains(s.touchRingActiveSlotIndex)
                   ? s.touchRingSlots[s.touchRingActiveSlotIndex] : nil
            {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &ring2Accum, at: cursorPos, settings: s)
            }
        }
        if !buttons.touchRing2Active { ring2Accum = 0 }
        lastRing2Pos = buttons.touchRing2Active ? ring2Pos : 0x7F

        // ── Touch strips (Intuos3 WS) — share touchRingSlots ───────────────────
        // Strips are linear (no wrap); each zone step maps 1:1 to a scroll event.

        // Strip 1 (left).
        let s1pos = buttons.touchStrip1Position
        if buttons.touchStrip1Active, lastStrip1Pos != 0xFF {
            let delta = Int(s1pos) - Int(lastStrip1Pos)
            if delta != 0,
               let slot = s.touchRingSlots.indices.contains(s.touchRingActiveSlotIndex)
                   ? s.touchRingSlots[s.touchRingActiveSlotIndex] : nil
            {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &strip1Accum, at: cursorPos, settings: s)
            }
        }
        if !buttons.touchStrip1Active { strip1Accum = 0 }
        lastStrip1Pos = buttons.touchStrip1Active ? s1pos : 0xFF

        // Strip 2 (right).
        let s2pos = buttons.touchStrip2Position
        if buttons.touchStrip2Active, lastStrip2Pos != 0xFF {
            let delta = Int(s2pos) - Int(lastStrip2Pos)
            if delta != 0,
               let slot = s.touchRingSlots.indices.contains(s.touchRingActiveSlotIndex)
                   ? s.touchRingSlots[s.touchRingActiveSlotIndex] : nil
            {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &strip2Accum, at: cursorPos, settings: s)
            }
        }
        if !buttons.touchStrip2Active { strip2Accum = 0 }
        lastStrip2Pos = buttons.touchStrip2Active ? s2pos : 0xFF
    }

    private func currentCursorPosition() -> CGPoint {
        let loc = NSEvent.mouseLocation
        let screenH = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        return CGPoint(x: loc.x, y: screenH - loc.y)
    }

    // MARK: - Click resolution

    private func resolveClick(
        _ candidate: CGPoint,
        settings: TabletSettings
    ) -> (CGPoint, Int) {
        let now = CFAbsoluteTimeGetCurrent()
        let dist = hypot(
            candidate.x - lastClickPosition.x,
            candidate.y - lastClickPosition.y)

        let snapThreshold = settings.doubleClickDistance
        let countThreshold = snapThreshold > 0 ? snapThreshold : 8.0
        let withinTime = now - lastClickTime < NSEvent.doubleClickInterval
        let withinDist = dist < countThreshold

        if withinTime && withinDist { clickCount += 1 } else { clickCount = 1 }

        let snap = snapThreshold > 0 && withinTime && dist < snapThreshold
        let result = snap ? lastClickPosition : candidate
        lastClickPosition = result
        lastClickTime = now
        return (result, clickCount)
    }

    // MARK: - Mouse event helpers

    /// Ground-truth of what synthetic modifiers should be active based on tablet button state.
    private var groundTruthSyntheticFlags: CGEventFlags = []

    /// Reference counts for each modifier bit to support multiple buttons mapped to the same key.
    private var modifierRefCounts: [UInt64: Int] = [
        CGEventFlags.maskCommand.rawValue: 0,
        CGEventFlags.maskShift.rawValue: 0,
        CGEventFlags.maskAlternate.rawValue: 0,
        CGEventFlags.maskControl.rawValue: 0,
    ]

    /// Bits that this driver "owns" when active.
    private let managedModifierMask: UInt64 =
        CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue

    /// Left-hand canonical keycodes for each managed modifier bit.
    /// Electron and AppKit text input only update their internal modifier state when
    /// a flagsChanged event carries a keycode that matches the actual modifier key —
    /// keycode 0 is silently ignored by many apps.
    private static let modifierKeyCodes: [(CGEventFlags, CGKeyCode)] = [
        (.maskCommand,   55),  // left ⌘
        (.maskShift,     56),  // left ⇧
        (.maskAlternate, 58),  // left ⌥
        (.maskControl,   59),  // left ⌃
    ]

    /// Last managed-bit result returned by currentEventFlags — used to suppress duplicate log lines.
    private var lastLoggedManagedFlags: UInt64 = 0

    /// The definitive modifier state for the NEXT outbound CGEvent.
    ///
    /// Physical keyboard state from hidSystemState combined with whatever synthetic modifiers
    /// are currently active from tablet button bindings.  Our privateState events do NOT write
    /// back to hidSystemState, so there is no feedback loop.
    ///
    /// Logs every transition in managed modifier bits (info level) so stuck-modifier incidents
    /// produce a precise timeline even when the synthetic machinery is not involved.
    private var currentEventFlags: CGEventFlags {
        let systemRaw = CGEventSource.flagsState(.hidSystemState).rawValue
        let result = CGEventFlags(rawValue: systemRaw | groundTruthSyntheticFlags.rawValue)
        let managedNow = result.rawValue & managedModifierMask
        if managedNow != lastLoggedManagedFlags {
            let hidManaged = systemRaw & managedModifierMask
            let synth = groundTruthSyntheticFlags.rawValue & managedModifierMask
            let prev = lastLoggedManagedFlags
            modLog.info("flags: 0x\(String(prev, radix: 16), privacy: .public) → 0x\(String(managedNow, radix: 16), privacy: .public) [hid=0x\(String(hidManaged, radix: 16), privacy: .public) synth=0x\(String(synth, radix: 16), privacy: .public)]")
            lastLoggedManagedFlags = managedNow
        }
        return result
    }

    /// The union of modifier flags justified by currently-held pen barrel buttons.
    /// Used by `reconcileSyntheticFlags` to identify orphaned bits after a tool change.
    /// Express-key modifiers are excluded — they arrive via `injectAux` with their own
    /// settings context and are handled by the DispatchWorkItem / time-based watchdogs.
    private func expectedSyntheticFlagsForHeldPenButtons() -> CGEventFlags {
        guard let tool = activeToolSettings else { return [] }
        var flags = CGEventFlags()
        if lastButton1Down {
            flags.formUnion(CGEventFlags(rawValue: tool.penButton1Binding.modifierFlags))
        }
        if lastButton2Down {
            flags.formUnion(CGEventFlags(rawValue: tool.penButton2Binding.modifierFlags))
        }
        return flags
    }

    /// Called whenever `activeToolSettings` changes. Releases any synthetic modifier bits
    /// that are no longer justified by the current pen button bindings. This handles the
    /// eraser-flip / tool-switch scenario: if the user held a barrel button mapped to ⌥
    /// and the tool identity changed mid-hold, the up-edge fires against the new binding
    /// and ⌥ would otherwise be orphaned in `groundTruthSyntheticFlags` forever.
    private func reconcileSyntheticFlags() {
        guard !groundTruthSyntheticFlags.isEmpty else { return }
        let expected = expectedSyntheticFlagsForHeldPenButtons()
        let excessRaw = groundTruthSyntheticFlags.rawValue & ~expected.rawValue & managedModifierMask
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

        for (bit, keyCode) in Self.modifierKeyCodes where excess.contains(bit) {
            guard let e = CGEvent(source: sessionSource) else { continue }
            e.type = .flagsChanged
            e.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
            finalizeAndPost(e)
        }
    }

    /// Releases any synthetic modifier keys currently held by tablet button bindings.
    /// Posts one `.flagsChanged` event per held modifier bit, then clears all state.
    /// Safe to call when `groundTruthSyntheticFlags` is already empty (no-op).
    private func releaseAllSyntheticModifiers() {
        guard !groundTruthSyntheticFlags.isEmpty else { return }
        let toRelease = groundTruthSyntheticFlags
        let systemBefore = CGEventSource.flagsState(.hidSystemState).rawValue & managedModifierMask
        modLog.info("releaseAll: clearing 0x\(String(toRelease.rawValue, radix: 16), privacy: .public) (system=0x\(String(systemBefore, radix: 16), privacy: .public))")

        // Clear ground truth and ref counts before posting so currentEventFlags
        // computes the correct post-release physical state for the flagsChanged events.
        groundTruthSyntheticFlags = []
        for key in modifierRefCounts.keys { modifierRefCounts[key] = 0 }
        lastSyntheticFlagChangeAt = Date()

        // One flagsChanged per bit with its canonical keycode. Many apps (Electron,
        // some Cocoa text inputs) silently discard flagsChanged events with keycode 0.
        // currentEventFlags now returns hidSystemState | groundTruth (= hidSystemState,
        // since groundTruth is empty). If the physical keyboard still holds the bit,
        // the event will correctly report it as still held rather than released.
        for (bit, keyCode) in Self.modifierKeyCodes where toRelease.contains(bit) {
            guard let e = CGEvent(source: sessionSource) else { continue }
            e.type = .flagsChanged
            e.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
            finalizeAndPost(e)
        }

        // Audit: re-read hidSystemState shortly after, log if any "released" bit is
        // still set there. Captures the case where the release events were posted but
        // the OS still reports the modifier as held — points to event-tap interference
        // or a state-source mismatch. Async so we sample after WindowServer settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self else { return }
            let systemAfter = CGEventSource.flagsState(.hidSystemState).rawValue & self.managedModifierMask
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
        releaseAllSyntheticModifiers()
    }

    /// Stamps an event with reconstructed flags and posts it.
    /// ALL outbound events must go through this helper to maintain state synchronization.
    private func finalizeAndPost(_ event: CGEvent) {
        #if DEBUG
        assert(
            groundTruthSyntheticFlags.rawValue & managedModifierMask
                == groundTruthSyntheticFlags.rawValue,
            "groundTruthSyntheticFlags contains bits outside managedModifierMask"
        )
        #endif
        event.flags = currentEventFlags
        event.post(tap: .cghidEventTap)
    }

    /// CGEventSource backed by privateState so posted events do not write back into
    /// hidSystemState.  Flags are stamped via currentEventFlags (which reads hidSystemState
    /// directly), so physical keyboard state is still reflected on every outbound event —
    /// but the feedback loop that causes sticky modifiers is broken.
    ///
    /// Stored once at init — NOT a computed property.  Creating a new CGEventSource on
    /// every event (400+/s at 133 Hz) allocates a private-state slab in the WindowServer
    /// on each call, causing the memory leak observed when a pen is in proximity.
    private let sessionSource: CGEventSource? = CGEventSource(stateID: .privateState)

    /// Resolves effective pen pose for CGEvent stamping.
    /// When useRotationAsTilt is true on the active tool, real tilt is suppressed and
    /// barrel rotation is sent as synthetic tilt instead — a "bait and switch" so
    /// Photoshop's Pen Tilt brush dynamics respond to barrel twist.
    private func resolveEffectivePose(
        point: TabletPoint,
        settings: TabletSettings
    ) -> (tiltX: Double, tiltY: Double, rotation: Double) {
        let tool = activeToolSettings ?? settings.activeTool

        var tiltX = point.tiltX
        var tiltY = point.tiltY
        let rotation = point.rotation

        if tool.useRotationAsTilt && point.rotation != 0.0 {
            var degrees = point.rotation

            if settings.invertRotation {
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

    private func postMouseDown(
        button: CGMouseButton, at location: CGPoint,
        pressure: Double, clickCount: Int,
        point: TabletPoint? = nil,
        settings: TabletSettings
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
        e.setIntegerValueField(.tabletEventDeviceID, value: 1)
        e.setIntegerValueField(.tabletEventPointButtons, value: 1)
        e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        e.setDoubleValueField(.mouseEventPressure, value: pressure)
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        if let p = point {
            let pose = resolveEffectivePose(point: p, settings: settings)
            e.setDoubleValueField(.tabletEventTiltX, value: pose.tiltX)
            e.setDoubleValueField(.tabletEventTiltY, value: pose.tiltY)
            e.setDoubleValueField(.tabletEventRotation, value: pose.rotation)
        }
        e.flags = currentEventFlags
        finalizeAndPost(e)
    }

    private func postMouseUp(
        button: CGMouseButton, at location: CGPoint,
        clickCount: Int, point: TabletPoint? = nil,
        settings: TabletSettings
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
        e.setIntegerValueField(.tabletEventDeviceID, value: 1)
        e.setIntegerValueField(.tabletEventPointButtons, value: 0)
        e.setDoubleValueField(.tabletEventPointPressure, value: 0)
        e.setDoubleValueField(.mouseEventPressure, value: 0)
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        if let p = point {
            let pose = resolveEffectivePose(point: p, settings: settings)
            e.setDoubleValueField(.tabletEventTiltX, value: pose.tiltX)
            e.setDoubleValueField(.tabletEventTiltY, value: pose.tiltY)
            e.setDoubleValueField(.tabletEventRotation, value: pose.rotation)
        }
        e.flags = currentEventFlags
        finalizeAndPost(e)
    }

    private func postMouseDrag(
        button: CGMouseButton, at location: CGPoint,
        pressure: Double, point: TabletPoint? = nil,
        settings: TabletSettings
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
        e.setIntegerValueField(.tabletEventDeviceID, value: 1)
        e.setIntegerValueField(.tabletEventPointButtons, value: pressure > 0.004 ? 1 : 0)
        e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        e.setDoubleValueField(.mouseEventPressure, value: pressure)
        if let p = point {
            let pose = resolveEffectivePose(point: p, settings: settings)
            e.setDoubleValueField(.tabletEventTiltX, value: pose.tiltX)
            e.setDoubleValueField(.tabletEventTiltY, value: pose.tiltY)
            e.setDoubleValueField(.tabletEventRotation, value: pose.rotation)
        }
        // Synthetic CGEvents default to zero deltas, breaking AppKit controls (e.g.
        // Xcode's minimap) that read event.deltaX/Y rather than diffing absolute
        // positions themselves. CG Y=0 is top; NSEvent deltaY is positive-upward,
        // so negate the Y component.
        e.setIntegerValueField(
            .mouseEventDeltaX, value: Int64((location.x - lastPostedPoint.x).rounded()))
        e.setIntegerValueField(
            .mouseEventDeltaY, value: Int64((location.y - lastPostedPoint.y).rounded()))
        e.flags = currentEventFlags
        finalizeAndPost(e)
    }

    private func postMouseMoved(
        at location: CGPoint, point: TabletPoint? = nil, settings: TabletSettings
    ) {
        guard
            let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: .mouseMoved,
                mouseCursorPosition: location, mouseButton: .left)
        else { return }
        e.setIntegerValueField(
            .mouseEventDeltaX, value: Int64((location.x - lastPostedPoint.x).rounded()))
        e.setIntegerValueField(
            .mouseEventDeltaY, value: Int64((location.y - lastPostedPoint.y).rounded()))
        e.flags = currentEventFlags
        finalizeAndPost(e)
    }

    // MARK: - Raw tablet pointer event

    private func postTabletPointerEvent(
        at location: CGPoint, pressure: Double,
        point: TabletPoint, settings: TabletSettings
    ) {
        guard let e = CGEvent(source: sessionSource) else { return }
        e.type = .tabletPointer
        e.location = location
        e.setIntegerValueField(.tabletEventDeviceID, value: 1)
        e.setIntegerValueField(.tabletEventPointX, value: Int64(point.x))
        e.setIntegerValueField(.tabletEventPointY, value: Int64(point.y))
        e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        let pose = resolveEffectivePose(point: point, settings: settings)
        e.setDoubleValueField(.tabletEventTiltX, value: pose.tiltX)
        e.setDoubleValueField(.tabletEventTiltY, value: pose.tiltY)
        e.setDoubleValueField(.tabletEventRotation, value: pose.rotation)
        let buttons: Int64 =
            (pressure > 0.004 ? 1 : 0)
            | (point.penButton1 ? 2 : 0)
            | (point.penButton2 ? 4 : 0)
            | (activeToolIsEraser && pressure > 0.004 ? 8 : 0)
        e.setIntegerValueField(.tabletEventPointButtons, value: buttons)
        e.flags = currentEventFlags
        finalizeAndPost(e)
    }

    // MARK: - Proximity event

    private func postProximityEvent(
        entering: Bool, at location: CGPoint,
        eraser: Bool
    ) {
        guard let e = CGEvent(source: sessionSource) else { return }
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

    private func fireButtonAction(
        _ binding: ButtonBinding, down: Bool,
        at location: CGPoint,
        settings: TabletSettings? = nil
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
            let event: CGEvent?
            if binding.keyLabel.isEmpty && binding.modifierFlags != 0 {
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

            // Event created successfully — now commit the state delta.
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
            finalizeAndPost(e)

        case .displayToggle:
            guard down, let s = settings else { break }
            s.targetDisplayIndex = TabletSettings.displayModeToggle
            cycleToggleDisplay(settings: s)
        case .ringCycle:
            guard down, let s = settings else { break }
            s.touchRingActiveSlotIndex = (s.touchRingActiveSlotIndex + 1) % max(1, s.touchRingSlots.count)
        case .ringSelectSlot:
            guard down, let s = settings else { break }
            s.touchRingActiveSlotIndex = min(Int(binding.keyCode), max(0, s.touchRingSlots.count - 1))
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
    private func dispatchRingDelta(
        rawDelta: Int, slot: ControlSlot, accum: inout Double,
        at location: CGPoint, settings: TabletSettings
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
            for _ in 0..<count { fireKeyTap(binding, at: location, settings: settings) }
        case .off:
            break
        }
    }

    private func postScrollWheelEvent(delta: Int, at location: CGPoint) {
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

    // MARK: - Screen mapping

    /// In relative mode: computes a delta from the previous normalized tablet position
    /// and applies it to the current cursor location.
    ///
    /// Display mapping is intentionally ignored — it makes no sense for mouse-like input.
    /// Deltas are scaled by the total virtual screen space (union of all displays), so a
    /// full active-area sweep traverses the entire available screen real estate.  The
    /// cursor is clamped to the same total bounds so it can reach any display.
    ///
    /// Active-area crop is still respected: a smaller crop = higher sensitivity.
    private func resolveRelativePoint(_ point: TabletPoint, settings: TabletSettings) -> CGPoint {
        // Total virtual screen: union of all display frames.
        // NSScreen.frame is in AppKit coordinates (bottom-left origin); CGEvent uses
        // top-left origin, so we convert.  We cache nothing here — display changes
        // affect cachedDisplayBounds (absolute mode) via the existing observer.
        let primaryH = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        let virtualBounds: CGRect = NSScreen.screens.reduce(CGRect.null) { acc, screen in
            // Convert AppKit frame (bottom-left origin) → CG frame (top-left origin).
            let f = screen.frame
            let cgRect = CGRect(
                x: f.minX, y: primaryH - f.maxY,
                width: f.width, height: f.height)
            return acc.union(cgRect)
        }
        let screen =
            virtualBounds.isEmpty
            ? CGRect(
                x: 0, y: 0,
                width: CGFloat(CGDisplayPixelsWide(CGMainDisplayID())),
                height: CGFloat(CGDisplayPixelsHigh(CGMainDisplayID())))
            : virtualBounds

        // Compute normalized position within the active area (same orientation math
        // as mapToScreen; active-area crop controls sensitivity).
        let rawX = Double(point.x)
        let rawY = Double(point.y)
        let rawMaxX = Double(point.maxX)
        let rawMaxY = Double(point.maxY)
        let ox: Double
        let oy: Double
        let effMaxX: Double
        let effMaxY: Double
        switch settings.tabletOrientation {
        case .landscape:
            ox = rawX
            oy = rawY
            effMaxX = rawMaxX
            effMaxY = rawMaxY
        case .portrait:
            ox = rawY
            oy = rawMaxX - rawX
            effMaxX = rawMaxY
            effMaxY = rawMaxX
        case .landscapeFlipped:
            ox = rawMaxX - rawX
            oy = rawMaxY - rawY
            effMaxX = rawMaxX
            effMaxY = rawMaxY
        case .portraitFlipped:
            ox = rawMaxY - rawY
            oy = rawX
            effMaxX = rawMaxY
            effMaxY = rawMaxX
        }
        let areaW = Swift.max(settings.activeAreaWidth, 0.001) * effMaxX
        let areaH = Swift.max(settings.activeAreaHeight, 0.001) * effMaxY
        let norm = CGPoint(
            x: (ox - settings.activeAreaX * effMaxX) / areaW,
            y: (oy - settings.activeAreaY * effMaxY) / areaH)

        // First report after proximity entry: anchor without moving.
        guard let prev = lastRelativeNorm else {
            lastRelativeNorm = norm
            return currentCursorPosition()
        }
        lastRelativeNorm = norm

        let dx = (norm.x - prev.x) * screen.width
        let dy = (norm.y - prev.y) * screen.height
        let cur = currentCursorPosition()
        return CGPoint(
            x: Swift.min(Swift.max(cur.x + dx, screen.minX), screen.maxX),
            y: Swift.min(Swift.max(cur.y + dy, screen.minY), screen.maxY))
    }

    /// Maps a tablet point to screen coordinates, accounting for orientation and active area cropping.
    /// Returns nil if the pen is outside the active area (deadzone).
    private func mapToScreen(_ point: TabletPoint, settings: TabletSettings) -> CGPoint? {
        let idx = settings.targetDisplayIndex
        if cachedDisplayIndex != idx {
            let (bounds, displayID) = resolveDisplayBoundsAndID(settings: settings)
            cachedDisplayBounds = bounds
            cachedDisplayID = displayID
            cachedDisplayIndex = idx
            // Invalidate calibration cache when display changes.
            cachedCalibrationOrientation = -1
        }
        let displayBounds = cachedDisplayBounds

        // Apply orientation transform before the active-area crop.
        // The active-area fractions are defined in oriented (post-rotation) space,
        // so we transform raw hardware coordinates first, then apply the crop.
        let rawX = Double(point.x)
        let rawY = Double(point.y)
        let rawMaxX = Double(point.maxX)
        let rawMaxY = Double(point.maxY)

        let ox: Double  // oriented x
        let oy: Double  // oriented y
        let effMaxX: Double  // range of oriented x axis
        let effMaxY: Double  // range of oriented y axis

        switch settings.tabletOrientation {
        case .landscape:
            ox = rawX
            oy = rawY
            effMaxX = rawMaxX
            effMaxY = rawMaxY
        case .portrait:  // 90° CW — USB port moves to left
            ox = rawY
            oy = rawMaxX - rawX
            effMaxX = rawMaxY
            effMaxY = rawMaxX
        case .landscapeFlipped:  // 180° — USB port at top
            ox = rawMaxX - rawX
            oy = rawMaxY - rawY
            effMaxX = rawMaxX
            effMaxY = rawMaxY
        case .portraitFlipped:  // 90° CCW — USB port moves to right
            ox = rawMaxY - rawY
            oy = rawX
            effMaxX = rawMaxY
            effMaxY = rawMaxX
        }

        var areaX = settings.activeAreaX * effMaxX
        var areaY = settings.activeAreaY * effMaxY
        var areaW = Swift.max(settings.activeAreaWidth, 0.001) * effMaxX
        var areaH = Swift.max(settings.activeAreaHeight, 0.001) * effMaxY

        if settings.proportionalMapping {
            let tabletAspect = areaW / areaH
            let displayAspect = Double(displayBounds.width) / Double(displayBounds.height)
            if tabletAspect > displayAspect {
                let effectiveW = areaH * displayAspect
                areaX += (areaW - effectiveW) / 2
                areaW = effectiveW
            } else if tabletAspect < displayAspect {
                let effectiveH = areaW / displayAspect
                areaY += (areaH - effectiveH) / 2
                areaH = effectiveH
            }
        }

        let relX = (ox - areaX) / areaW
        let relY = (oy - areaY) / areaH

        // Outside active area — deadzone
        guard relX >= 0, relX <= 1, relY >= 0, relY <= 1 else { return nil }

        // Apply multi-point calibration transform in normalized space (if available).
        var calX = relX, calY = relY
        let orientRaw = settings.tabletOrientation.rawValue
        if cachedCalibrationOrientation != orientRaw {
            cachedCalibration = settings.calibration(for: settings.tabletOrientation,
                                                      displayID: cachedDisplayID)
            cachedCalibrationOrientation = orientRaw
        }
        if let cal = cachedCalibration {
            (calX, calY) = cal.apply(to: (relX, relY))
        }

        var sx = displayBounds.minX + calX * displayBounds.width
        var sy = displayBounds.minY + calY * displayBounds.height

        // Additive fine-tune offset (points, user-configured) — stacks on top of calibration.
        sx += settings.parallaxOffsetX
        sy += settings.parallaxOffsetY

        sx = Swift.min(Swift.max(sx, displayBounds.minX), displayBounds.maxX)
        sy = Swift.min(Swift.max(sy, displayBounds.minY), displayBounds.maxY)
        return CGPoint(x: sx, y: sy)
    }

    /// Queries the OS display list and returns the target display's bounds and ID.
    /// Only called on cache miss; results stored in cachedDisplayBounds/cachedDisplayID.
    private func resolveDisplayBoundsAndID(settings: TabletSettings) -> (CGRect, CGDirectDisplayID) {
        let mainID = CGMainDisplayID()
        let fallback = CGRect(
            x: 0, y: 0,
            width: CGFloat(CGDisplayPixelsWide(mainID)),
            height: CGFloat(CGDisplayPixelsHigh(mainID))
        )
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return (fallback, mainID)
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return (fallback, mainID)
        }
        let idx = settings.targetDisplayIndex
        if idx == TabletSettings.displayModeAll {
            // Union bounding rect spanning every active display — no single display ID.
            return (ids.map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }, 0)
        }
        if idx == TabletSettings.displayModeToggle {
            let rotation = toggleRotation(settings: settings, allIDs: ids)
            guard !rotation.isEmpty else { return (CGDisplayBounds(mainID), mainID) }
            let toggleID = rotation[currentToggleIndex % rotation.count]
            return (CGDisplayBounds(toggleID), toggleID)
        }
        if idx > 0, idx <= ids.count {
            let targetID = ids[idx - 1]
            return (CGDisplayBounds(targetID), targetID)
        }
        return (CGDisplayBounds(mainID), mainID)
    }

    /// Returns the ordered list of display IDs in the toggle rotation,
    /// filtered by the IDs stored in settings (empty = all included).
    private func toggleRotation(
        settings: TabletSettings,
        allIDs: [CGDirectDisplayID]
    ) -> [CGDirectDisplayID] {
        let stored = settings.toggleDisplayIDSet
        if stored.isEmpty { return allIDs }
        return allIDs.filter { stored.contains($0) }
    }

    /// Advances the toggle rotation to the next display in the sequence.
    /// No-op when fewer than two displays are in the rotation.
    func cycleToggleDisplay(settings: TabletSettings) {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return }
        let rotation = toggleRotation(settings: settings, allIDs: ids)
        guard rotation.count > 1 else { return }
        currentToggleIndex = (currentToggleIndex + 1) % rotation.count
        cachedDisplayIndex = Int.min  // force cache miss on next inject
        cachedCalibrationOrientation = -1
    }

    /// Force re-read of calibration data on next inject.
    /// Call after calibration data is stored or cleared.
    func invalidateCalibrationCache() {
        cachedCalibrationOrientation = -1
    }
}
