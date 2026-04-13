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
    var activeToolSettings: ToolSettings? = nil
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

    init(vendorID: Int = 0x056A, productID: Int = 0) {
        self.deviceVendorID = vendorID
        self.deviceProductID = productID
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { @MainActor [weak self] _ in self?.cachedDisplayIndex = Int.min }
    }

    deinit {
        if let obs = displayObserver { NotificationCenter.default.removeObserver(obs) }
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
    private var currentToggleIndex: Int = 0
    private var displayObserver: NSObjectProtocol?

    // MARK: - Pen injection

    func inject(point: TabletPoint, settings: TabletSettings?) {
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
        let pressure = tool.pressureCurve.evaluate(point.normalizedPressure)
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
                        clickCount: activeClickCount)
                    lastTipDown = false
                }
                // Release any USB HID mouse buttons that were held when the tool left
                // the tablet (e.g. user yanked the KC-100 off the surface mid-drag).
                if lastUSBMouseMask != 0 {
                    if usbMouseLeftHeld {
                        postMouseUp(
                            button: .left, at: smoothedPoint,
                            clickCount: activeClickCount)
                        usbMouseLeftHeld = false
                    }
                    if (lastUSBMouseMask & 0x02) != 0 {
                        postMouseUp(button: .right, at: smoothedPoint, clickCount: 1)
                    }
                    if (lastUSBMouseMask & 0x04) != 0 {
                        if let e = CGEvent(
                            mouseEventSource: sessionSource, mouseType: .otherMouseUp,
                            mouseCursorPosition: smoothedPoint, mouseButton: .center) {
                            e.flags = currentEventFlags
                            e.post(tap: .cghidEventTap)
                        }
                    }
                    lastUSBMouseMask = 0
                }
                if lastMiddleDown {
                    if let e = CGEvent(
                        mouseEventSource: sessionSource, mouseType: .otherMouseUp,
                        mouseCursorPosition: smoothedPoint, mouseButton: .center) {
                        e.flags = currentEventFlags
                        e.post(tap: .cghidEventTap)
                    }
                    lastMiddleDown = false
                }
                // Safety valve: release any modifier keys stranded by a missed decoder
                // release event (e.g. BT packet drop leaving lastBTPadKeys non-zero).
                // Per-transport fixes (Defect A/B) prevent accumulation; this ensures
                // proximity exit is always a clean slate regardless.
                if !activeSyntheticFlags.isEmpty {
                    let syntheticToRelease = activeSyntheticFlags
                    activeSyntheticFlags = []
                    if let e = CGEvent(source: sessionSource) {
                        e.type = .flagsChanged
                        e.setIntegerValueField(.keyboardEventKeycode, value: 0)
                        // Preserve physical modifiers the user may be holding; strip only ours.
                        let physicalRaw = CGEventSource.flagsState(.hidSystemState).rawValue
                            & ~syntheticToRelease.rawValue
                        e.flags = CGEventFlags(rawValue: physicalRaw)
                        e.post(tap: .cghidEventTap)
                    }
                }
                // Reset aux state so the next injectAux fires fresh transitions.
                lastAuxButtons = [Bool](repeating: false, count: 16)
                lastRingButtonDown = false
                hasSmoothedPoint = false
                hasLastRawPoint = false
                hasPostedPoint = false
                lastRelativeNorm = nil
                lastPostedPressure = -1.0
                clearHoverDeltas()
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
            if !activeToolIsMouse {
                postTabletPointerEvent(at: screenPoint, pressure: pressure, point: point)
            }
            if tipDown {
                let tipAction = activeToolIsEraser ? tool.eraserBinding : tool.tipBinding
                activeButton = tipAction.mouseButton ?? .left
                let (clickPt, count) = resolveClick(screenPoint, settings: settings)
                activeClickCount = count
                postMouseDown(
                    button: activeButton, at: clickPt,
                    pressure: pressure, clickCount: count,
                    point: point)
            } else {
                postMouseUp(
                    button: activeButton, at: screenPoint,
                    clickCount: activeClickCount, point: point)
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
                if !activeToolIsMouse {
                    postTabletPointerEvent(at: screenPoint, pressure: pressure, point: point)
                }
                // USB mouse left button held (KC-100): injectMouseButtons() already sent
                // leftMouseDown; use leftMouseDragged so apps receive proper drag events.
                let dragging = tipDown || (activeToolIsMouse && usbMouseLeftHeld)
                if dragging {
                    postMouseDrag(button: activeButton, at: screenPoint, pressure: pressure, point: point)
                } else {
                    postMouseMoved(at: screenPoint, point: point)
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
            // For mouse tools button1 drives the primary click (tipDown above);
            // dispatching it again as a button action would double-fire.
            if !activeToolIsMouse {
                fireButtonAction(btn1, down: point.penButton1, at: screenPoint, settings: settings)
            }
            lastButton1Down = point.penButton1
        }
        if point.penButton2 != lastButton2Down {
            fireButtonAction(btn2, down: point.penButton2, at: screenPoint, settings: settings)
            lastButton2Down = point.penButton2
        }

        // ── Middle button (mouse tool only, always immediate) ──────────────────
        if point.mouseMiddleButton != lastMiddleDown {
            let type: CGEventType = point.mouseMiddleButton ? .otherMouseDown : .otherMouseUp
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: screenPoint, mouseButton: .center) {
                e.flags = currentEventFlags
                e.post(tap: .cghidEventTap)
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
    func replayPointerEvent() {
        guard let point = shimLastPoint else { return }
        postTabletPointerEvent(at: shimLastScreen, pressure: shimLastPressure, point: point)
        let dragging = lastTipDown || (activeToolIsMouse && usbMouseLeftHeld)
        if dragging {
            postMouseDrag(button: activeButton, at: shimLastScreen, pressure: shimLastPressure, point: point)
        } else {
            postMouseMoved(at: shimLastScreen, point: point)
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
    // Called by WacomUniversalDevice when a 4-byte Report ID 0x01 arrives from the
    // standard mouse interface (usagePage=0x01).  Fires left/right/middle down/up
    // CGEvents at the current cursor location; sets usbMouseLeftHeld so inject()
    // promotes subsequent mouseMoved events to leftMouseDragged while left is held.

    func injectMouseButtons(mask: UInt8, settings: TabletSettings?) {
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
                postMouseDown(button: .left, at: clickPt, pressure: 1.0, clickCount: count)
            } else {
                postMouseUp(button: .left, at: loc, clickCount: activeClickCount)
            }
            lastPostedPoint = loc
            hasPostedPoint = true
        }
        if rightNow != rightWas {
            if rightNow {
                postMouseDown(button: .right, at: loc, pressure: 1.0, clickCount: 1)
            } else {
                postMouseUp(button: .right, at: loc, clickCount: 1)
            }
        }
        if midNow != midWas {
            let type: CGEventType = midNow ? .otherMouseDown : .otherMouseUp
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: loc, mouseButton: .center) {
                e.flags = currentEventFlags
                e.post(tap: .cghidEventTap)
            }
        }
        // Button 4 (bit 3)
        let btn4Now = (mask & 0x08) != 0
        let btn4Was = (oldMask & 0x08) != 0
        if btn4Now != btn4Was {
            let type: CGEventType = btn4Now ? .otherMouseDown : .otherMouseUp
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: loc, mouseButton: CGMouseButton(rawValue: 3)!) {
                e.flags = currentEventFlags
                e.post(tap: .cghidEventTap)
            }
        }
        // Button 5 (bit 4)
        let btn5Now = (mask & 0x10) != 0
        let btn5Was = (oldMask & 0x10) != 0
        if btn5Now != btn5Was {
            let type: CGEventType = btn5Now ? .otherMouseDown : .otherMouseUp
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: loc, mouseButton: CGMouseButton(rawValue: 4)!) {
                e.flags = currentEventFlags
                e.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Express key injection

    func injectAux(buttons: AuxButtons, settings: TabletSettings?) {
        let s = settings ?? TabletSettings()
        let bindings = s.expressKeyBindings
        let cursorPos = currentCursorPosition()

        // ── Express keys ───────────────────────────────────────────────────────
        for i in 0..<16 {
            let down = buttons[i]
            let hasMechanicalPulse = i < 8 && (buttons.mechanicalMask >> i) & 1 != 0
            if down != lastAuxButtons[i] {
                fireButtonAction(bindings[i], down: down, at: cursorPos, settings: s)
                lastAuxButtons[i] = down
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
            fireButtonAction(s.touchRingButtonBinding, down: ringButtonDown, at: cursorPos, settings: s)
            lastRingButtonDown = ringButtonDown
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
            if delta != 0 {
                switch s.touchRingMode {
                case .scroll:
                    postScrollWheelEvent(delta: delta, at: cursorPos)
                case .off:
                    break
                }
            }
        }
        lastRingPos = buttons.touchRingActive ? ringPos : 0x7F

        // ── Touch ring 2 (DTK-2400 right bezel) — shares touchRingMode setting ──
        let ring2Pos = buttons.touchRing2Position
        if buttons.touchRing2Active, lastRing2Pos != 0x7F {
            var delta = Int(ring2Pos) - Int(lastRing2Pos)
            if delta > 36 { delta -= 72 }
            if delta < -36 { delta += 72 }
            if delta != 0 {
                switch s.touchRingMode {
                case .scroll: postScrollWheelEvent(delta: delta, at: cursorPos)
                case .off: break
                }
            }
        }
        lastRing2Pos = buttons.touchRing2Active ? ring2Pos : 0x7F

        // ── Touch strips (Intuos3 WS) ──────────────────────────────────────────
        // Strips are linear (no wrap); each zone step maps 1:1 to a scroll event.

        // Strip 1 (left).
        let s1pos = buttons.touchStrip1Position
        if buttons.touchStrip1Active, lastStrip1Pos != 0xFF {
            let delta = Int(s1pos) - Int(lastStrip1Pos)
            if delta != 0 {
                switch s.touchStrip1Mode {
                case .scroll: postScrollWheelEvent(delta: delta, at: cursorPos)
                case .off: break
                }
            }
        }
        lastStrip1Pos = buttons.touchStrip1Active ? s1pos : 0xFF

        // Strip 2 (right).
        let s2pos = buttons.touchStrip2Position
        if buttons.touchStrip2Active, lastStrip2Pos != 0xFF {
            let delta = Int(s2pos) - Int(lastStrip2Pos)
            if delta != 0 {
                switch s.touchStrip2Mode {
                case .scroll: postScrollWheelEvent(delta: delta, at: cursorPos)
                case .off: break
                }
            }
        }
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

    /// Tracks modifier flags synthesized by tablet button bindings.
    /// Updated atomically in fireButtonAction before any event is posted.
    private var activeSyntheticFlags: CGEventFlags = []

    /// The definitive modifier state stamped on every outbound CGEvent.
    /// Merges physical-keyboard-only state (hidSystemState) with any flags
    /// this driver has pressed via button bindings.  hidSystemState is used
    /// instead of combinedSessionState so that previously injected synthetic
    /// modifiers never feed back into new events — the root cause of the
    /// sticky-modifier bug shared with OpenTabletDriver and Adobe software.
    private var currentEventFlags: CGEventFlags {
        CGEventFlags(
            rawValue: CGEventSource.flagsState(.hidSystemState).rawValue
                | activeSyntheticFlags.rawValue)
    }

    /// CGEventSource backed by privateState so posted events do not write back into
    /// hidSystemState.  Flags are stamped via currentEventFlags (which reads hidSystemState
    /// directly), so physical keyboard state is still reflected on every outbound event —
    /// but the feedback loop that causes sticky modifiers is broken.
    private var sessionSource: CGEventSource? {
        CGEventSource(stateID: .privateState)
    }

    private func postMouseDown(
        button: CGMouseButton, at location: CGPoint,
        pressure: Double, clickCount: Int,
        point: TabletPoint? = nil
    ) {
        let type: CGEventType
        switch button {
        case .right:  type = .rightMouseDown
        case .center: type = .otherMouseDown
        default:      type = .leftMouseDown
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
            e.setDoubleValueField(.tabletEventTiltX, value: p.tiltX)
            e.setDoubleValueField(.tabletEventTiltY, value: p.tiltY)
            e.setDoubleValueField(.tabletEventRotation, value: p.rotation)
        }
        e.flags = currentEventFlags
        e.post(tap: .cghidEventTap)
    }

    private func postMouseUp(
        button: CGMouseButton, at location: CGPoint,
        clickCount: Int, point: TabletPoint? = nil
    ) {
        let type: CGEventType
        switch button {
        case .right:  type = .rightMouseUp
        case .center: type = .otherMouseUp
        default:      type = .leftMouseUp
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
            e.setDoubleValueField(.tabletEventTiltX, value: p.tiltX)
            e.setDoubleValueField(.tabletEventTiltY, value: p.tiltY)
            e.setDoubleValueField(.tabletEventRotation, value: p.rotation)
        }
        e.flags = currentEventFlags
        e.post(tap: .cghidEventTap)
    }

    private func postMouseDrag(
        button: CGMouseButton, at location: CGPoint,
        pressure: Double, point: TabletPoint? = nil
    ) {
        let type: CGEventType
        switch button {
        case .right:  type = .rightMouseDragged
        case .center: type = .otherMouseDragged
        default:      type = .leftMouseDragged
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
            e.setDoubleValueField(.tabletEventTiltX, value: p.tiltX)
            e.setDoubleValueField(.tabletEventTiltY, value: p.tiltY)
            e.setDoubleValueField(.tabletEventRotation, value: p.rotation)
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
        e.post(tap: .cghidEventTap)
    }

    private func postMouseMoved(at location: CGPoint, point: TabletPoint? = nil) {
        guard
            let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: .mouseMoved,
                mouseCursorPosition: location, mouseButton: .left)
        else { return }
        if let p = point {
            e.setIntegerValueField(.mouseEventSubtype, value: 1)
            e.setIntegerValueField(.tabletEventDeviceID, value: 1)
            e.setDoubleValueField(.tabletEventTiltX, value: p.tiltX)
            e.setDoubleValueField(.tabletEventTiltY, value: p.tiltY)
            e.setDoubleValueField(.tabletEventRotation, value: p.rotation)
        }
        e.setIntegerValueField(
            .mouseEventDeltaX, value: Int64((location.x - lastPostedPoint.x).rounded()))
        e.setIntegerValueField(
            .mouseEventDeltaY, value: Int64((location.y - lastPostedPoint.y).rounded()))
        e.flags = currentEventFlags
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Raw tablet pointer event

    private func postTabletPointerEvent(
        at location: CGPoint, pressure: Double,
        point: TabletPoint
    ) {
        guard let e = CGEvent(source: sessionSource) else { return }
        e.type = .tabletPointer
        e.location = location
        e.setIntegerValueField(.tabletEventDeviceID, value: 1)
        e.setIntegerValueField(.tabletEventPointX, value: Int64(point.x))
        e.setIntegerValueField(.tabletEventPointY, value: Int64(point.y))
        e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        e.setDoubleValueField(.tabletEventTiltX, value: point.tiltX)
        e.setDoubleValueField(.tabletEventTiltY, value: point.tiltY)
        e.setDoubleValueField(.tabletEventRotation, value: point.rotation)
        let buttons: Int64 =
            (pressure > 0.004 ? 1 : 0)
            | (point.penButton1 ? 2 : 0)
            | (point.penButton2 ? 4 : 0)
            | (activeToolIsEraser && pressure > 0.004 ? 8 : 0)
        e.setIntegerValueField(.tabletEventPointButtons, value: buttons)
        e.flags = currentEventFlags
        e.post(tap: .cghidEventTap)
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
            let serial: Int64 = eraser
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
        e.post(tap: .cghidEventTap)
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
            let type: CGEventType = down ? .leftMouseDown : .leftMouseUp
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: location, mouseButton: .left) {
                e.flags = currentEventFlags
                e.post(tap: .cghidEventTap)
            }
        case .rightClick, .eraser:
            let type: CGEventType = down ? .rightMouseDown : .rightMouseUp
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: location, mouseButton: .right) {
                e.flags = currentEventFlags
                e.post(tap: .cghidEventTap)
            }
        case .middleClick:
            let type: CGEventType = down ? .otherMouseDown : .otherMouseUp
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: location, mouseButton: .center) {
                e.flags = currentEventFlags
                e.post(tap: .cghidEventTap)
            }
        case .keyCombo:
            // Update internal synthetic state atomically before posting anything,
            // so currentEventFlags already reflects the new state when stamped.
            let bindingFlags = CGEventFlags(rawValue: binding.modifierFlags)
            if down {
                activeSyntheticFlags.insert(bindingFlags)
            } else {
                activeSyntheticFlags.remove(bindingFlags)
            }
            if binding.keyLabel.isEmpty && binding.modifierFlags != 0 {
                guard let e = CGEvent(source: sessionSource) else { return }
                e.type = .flagsChanged
                e.setIntegerValueField(
                    .keyboardEventKeycode,
                    value: Int64(binding.keyCode))
                // flagsChanged events must NOT use currentEventFlags here.
                // Posting through cghidEventTap updates hidSystemState regardless of the
                // event source's stateID, so currentEventFlags would read back the synthetic
                // modifier we just injected on the previous press — re-asserting it on every
                // release and leaving it stuck. Instead we reconstruct a clean physical-only
                // baseline by subtracting all synthetic flags that were active BEFORE this
                // press/release from hidSystemState, then OR in the post-update synthetics.
                let priorSyntheticRaw: UInt64 = down
                    ? activeSyntheticFlags.rawValue & ~bindingFlags.rawValue   // newly added → subtract to get prior
                    : activeSyntheticFlags.rawValue | bindingFlags.rawValue    // just removed → add back to get prior
                let physicalRaw = CGEventSource.flagsState(.hidSystemState).rawValue & ~priorSyntheticRaw
                e.flags = CGEventFlags(rawValue: physicalRaw | activeSyntheticFlags.rawValue)
                e.post(tap: .cghidEventTap)
            } else {
                guard
                    let e = CGEvent(
                        keyboardEventSource: sessionSource,
                        virtualKey: CGKeyCode(binding.keyCode),
                        keyDown: down)
                else { return }
                e.flags = currentEventFlags
                e.post(tap: .cghidEventTap)
            }
        case .displayToggle:
            guard down, let s = settings else { break }
            s.targetDisplayIndex = TabletSettings.displayModeToggle
            cycleToggleDisplay(settings: s)
        }
    }

    // MARK: - Scroll wheel

    private func postScrollWheelEvent(delta: Int, at location: CGPoint) {
        // .line units: one detent = one scroll line, consistent with trackpad / Magic Mouse.
        guard
            let e = CGEvent(
                scrollWheelEvent2Source: sessionSource, units: .line,
                wheelCount: 1, wheel1: Int32(delta * 3), wheel2: 0, wheel3: 0)
        else { return }
        e.location = location
        e.flags = currentEventFlags
        e.post(tap: .cghidEventTap)
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
            let cgRect = CGRect(x: f.minX, y: primaryH - f.maxY,
                                width: f.width, height: f.height)
            return acc.union(cgRect)
        }
        let screen = virtualBounds.isEmpty
            ? CGRect(x: 0, y: 0,
                     width: CGFloat(CGDisplayPixelsWide(CGMainDisplayID())),
                     height: CGFloat(CGDisplayPixelsHigh(CGMainDisplayID())))
            : virtualBounds

        // Compute normalized position within the active area (same orientation math
        // as mapToScreen; active-area crop controls sensitivity).
        let rawX = Double(point.x), rawY = Double(point.y)
        let rawMaxX = Double(point.maxX), rawMaxY = Double(point.maxY)
        let ox: Double; let oy: Double
        let effMaxX: Double; let effMaxY: Double
        switch settings.tabletOrientation {
        case .landscape:
            ox = rawX;           oy = rawY
            effMaxX = rawMaxX;   effMaxY = rawMaxY
        case .portrait:
            ox = rawY;           oy = rawMaxX - rawX
            effMaxX = rawMaxY;   effMaxY = rawMaxX
        case .landscapeFlipped:
            ox = rawMaxX - rawX; oy = rawMaxY - rawY
            effMaxX = rawMaxX;   effMaxY = rawMaxY
        case .portraitFlipped:
            ox = rawMaxY - rawY; oy = rawX
            effMaxX = rawMaxY;   effMaxY = rawMaxX
        }
        let areaW = Swift.max(settings.activeAreaWidth,  0.001) * effMaxX
        let areaH = Swift.max(settings.activeAreaHeight, 0.001) * effMaxY
        let norm = CGPoint(x: (ox - settings.activeAreaX * effMaxX) / areaW,
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
            cachedDisplayBounds = resolveDisplayBounds(settings: settings)
            cachedDisplayIndex = idx
        }
        let displayBounds = cachedDisplayBounds

        // Apply orientation transform before the active-area crop.
        // The active-area fractions are defined in oriented (post-rotation) space,
        // so we transform raw hardware coordinates first, then apply the crop.
        let rawX = Double(point.x)
        let rawY = Double(point.y)
        let rawMaxX = Double(point.maxX)
        let rawMaxY = Double(point.maxY)

        let ox: Double      // oriented x
        let oy: Double      // oriented y
        let effMaxX: Double // range of oriented x axis
        let effMaxY: Double // range of oriented y axis

        switch settings.tabletOrientation {
        case .landscape:
            ox = rawX;           oy = rawY
            effMaxX = rawMaxX;   effMaxY = rawMaxY
        case .portrait:          // 90° CW — USB port moves to left
            ox = rawY;                   oy = rawMaxX - rawX
            effMaxX = rawMaxY;           effMaxY = rawMaxX
        case .landscapeFlipped:  // 180° — USB port at top
            ox = rawMaxX - rawX;         oy = rawMaxY - rawY
            effMaxX = rawMaxX;           effMaxY = rawMaxY
        case .portraitFlipped:   // 90° CCW — USB port moves to right
            ox = rawMaxY - rawY;         oy = rawX
            effMaxX = rawMaxY;           effMaxY = rawMaxX
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

        let sx = Swift.min(
            Swift.max(
                displayBounds.minX + relX * displayBounds.width,
                displayBounds.minX), displayBounds.maxX)
        let sy = Swift.min(
            Swift.max(
                displayBounds.minY + relY * displayBounds.height,
                displayBounds.minY), displayBounds.maxY)
        return CGPoint(x: sx, y: sy)
    }

    /// Queries the OS display list and returns the target display's bounds.
    /// Only called on cache miss; result stored in cachedDisplayBounds.
    private func resolveDisplayBounds(settings: TabletSettings) -> CGRect {
        let fallback = CGRect(
            x: 0, y: 0,
            width: CGFloat(CGDisplayPixelsWide(CGMainDisplayID())),
            height: CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        )
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return fallback
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return fallback
        }
        let idx = settings.targetDisplayIndex
        if idx == TabletSettings.displayModeAll {
            // Union bounding rect spanning every active display.
            return ids.map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
        }
        if idx == TabletSettings.displayModeToggle {
            let rotation = toggleRotation(settings: settings, allIDs: ids)
            guard !rotation.isEmpty else { return CGDisplayBounds(CGMainDisplayID()) }
            return CGDisplayBounds(rotation[currentToggleIndex % rotation.count])
        }
        if idx > 0, idx <= ids.count { return CGDisplayBounds(ids[idx - 1]) }
        return CGDisplayBounds(CGMainDisplayID())
    }

    /// Returns the ordered list of display IDs in the toggle rotation,
    /// filtered by the IDs stored in settings (empty = all included).
    private func toggleRotation(settings: TabletSettings,
                                allIDs: [CGDirectDisplayID]) -> [CGDirectDisplayID] {
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
        cachedDisplayIndex = Int.min   // force cache miss on next inject
    }
}
