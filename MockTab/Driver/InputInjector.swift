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
        let rawPoint = mapToScreen(point, settings: settings)
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

        // ── Proximity transitions (always immediate) ───────────────────────────
        if point.inProximity != lastProximity {
            postProximityEvent(
                entering: point.inProximity, at: rawPoint,
                eraser: point.eraser)
            if point.inProximity {
                let s = tool.smoothingStrength
                smoothingAlpha = s > 0 ? 1.0 - s * 0.85 : 1.0
            } else {
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
                        CGEvent(
                            mouseEventSource: nil, mouseType: .otherMouseUp,
                            mouseCursorPosition: smoothedPoint, mouseButton: .center)?
                            .post(tap: .cghidEventTap)
                    }
                    lastUSBMouseMask = 0
                }
                if lastMiddleDown {
                    CGEvent(
                        mouseEventSource: nil, mouseType: .otherMouseUp,
                        mouseCursorPosition: smoothedPoint, mouseButton: .center)?
                        .post(tap: .cghidEventTap)
                    lastMiddleDown = false
                }
                hasSmoothedPoint = false
                hasLastRawPoint = false
                hasPostedPoint = false
                lastPostedPressure = -1.0
                clearHoverDeltas()
            }
            lastProximity = point.inProximity
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
                let tipAction = point.eraser ? tool.eraserBinding : tool.tipBinding
                activeButton = tipAction.mouseButton ?? (point.eraser ? .right : .left)
                let (clickPt, count) = resolveClick(screenPoint, settings: settings)
                activeClickCount = count
                postMouseDown(
                    button: activeButton, at: clickPt,
                    pressure: pressure, clickCount: count)
            } else {
                postMouseUp(
                    button: activeButton, at: screenPoint,
                    clickCount: activeClickCount)
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
                    postMouseDrag(button: activeButton, at: screenPoint, pressure: pressure)
                } else {
                    postMouseMoved(at: screenPoint)
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
                fireButtonAction(btn1, down: point.penButton1, at: screenPoint)
            }
            lastButton1Down = point.penButton1
        }
        if point.penButton2 != lastButton2Down {
            fireButtonAction(btn2, down: point.penButton2, at: screenPoint)
            lastButton2Down = point.penButton2
        }

        // ── Middle button (mouse tool only, always immediate) ──────────────────
        if point.mouseMiddleButton != lastMiddleDown {
            let type: CGEventType = point.mouseMiddleButton ? .otherMouseDown : .otherMouseUp
            CGEvent(
                mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: screenPoint, mouseButton: .center)?
                .post(tap: .cghidEventTap)
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
            postMouseDrag(button: activeButton, at: shimLastScreen, pressure: shimLastPressure)
        } else {
            postMouseMoved(at: shimLastScreen)
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
            CGEvent(
                mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: loc, mouseButton: .center)?
                .post(tap: .cghidEventTap)
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
            if down != lastAuxButtons[i] {
                fireButtonAction(bindings[i], down: down, at: cursorPos)
                lastAuxButtons[i] = down
            }
        }

        // ── Touch ring center button ───────────────────────────────────────────
        let ringButtonDown = buttons.touchRingButtonDown
        if ringButtonDown != lastRingButtonDown {
            fireButtonAction(s.touchRingButtonBinding, down: ringButtonDown, at: cursorPos)
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

    private func postMouseDown(
        button: CGMouseButton, at location: CGPoint,
        pressure: Double, clickCount: Int
    ) {
        let type: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        guard
            let e = CGEvent(
                mouseEventSource: nil, mouseType: type,
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
        e.post(tap: .cghidEventTap)
    }

    private func postMouseUp(
        button: CGMouseButton, at location: CGPoint,
        clickCount: Int
    ) {
        let type: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        guard
            let e = CGEvent(
                mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: location, mouseButton: button)
        else { return }
        e.setIntegerValueField(.mouseEventSubtype, value: 1)
        e.setIntegerValueField(.tabletEventDeviceID, value: 1)
        e.setIntegerValueField(.tabletEventPointButtons, value: 0)
        e.setDoubleValueField(.tabletEventPointPressure, value: 0)
        e.setDoubleValueField(.mouseEventPressure, value: 0)
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        e.post(tap: .cghidEventTap)
    }

    private func postMouseDrag(
        button: CGMouseButton, at location: CGPoint,
        pressure: Double
    ) {
        let type: CGEventType = button == .right ? .rightMouseDragged : .leftMouseDragged
        guard
            let e = CGEvent(
                mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: location, mouseButton: button)
        else { return }
        e.setIntegerValueField(.mouseEventSubtype, value: 1)
        e.setIntegerValueField(.tabletEventDeviceID, value: 1)
        e.setIntegerValueField(.tabletEventPointButtons, value: pressure > 0.004 ? 1 : 0)
        e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        e.setDoubleValueField(.mouseEventPressure, value: pressure)
        // Synthetic CGEvents default to zero deltas, breaking AppKit controls (e.g.
        // Xcode's minimap) that read event.deltaX/Y rather than diffing absolute
        // positions themselves. CG Y=0 is top; NSEvent deltaY is positive-upward,
        // so negate the Y component.
        e.setIntegerValueField(
            .mouseEventDeltaX, value: Int64((location.x - lastPostedPoint.x).rounded()))
        e.setIntegerValueField(
            .mouseEventDeltaY, value: Int64((location.y - lastPostedPoint.y).rounded()))
        e.post(tap: .cghidEventTap)
    }

    private func postMouseMoved(at location: CGPoint) {
        guard
            let e = CGEvent(
                mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: location, mouseButton: .left)
        else { return }
        e.setIntegerValueField(
            .mouseEventDeltaX, value: Int64((location.x - lastPostedPoint.x).rounded()))
        e.setIntegerValueField(
            .mouseEventDeltaY, value: Int64((location.y - lastPostedPoint.y).rounded()))
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Raw tablet pointer event

    private func postTabletPointerEvent(
        at location: CGPoint, pressure: Double,
        point: TabletPoint
    ) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = .tabletPointer
        e.location = location
        e.setIntegerValueField(.tabletEventDeviceID, value: 1)
        e.setIntegerValueField(.tabletEventPointX, value: Int64(point.x))
        e.setIntegerValueField(.tabletEventPointY, value: Int64(point.y))
        e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        e.setDoubleValueField(.tabletEventTiltX, value: point.tiltX)
        e.setDoubleValueField(.tabletEventTiltY, value: point.tiltY)
        let buttons: Int64 =
            (pressure > 0.004 ? 1 : 0)
            | (point.penButton1 ? 2 : 0)
            | (point.penButton2 ? 4 : 0)
        e.setIntegerValueField(.tabletEventPointButtons, value: buttons)
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Proximity event

    private func postProximityEvent(
        entering: Bool, at location: CGPoint,
        eraser: Bool
    ) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = .tabletProximity
        e.location = location

        e.setIntegerValueField(
            .tabletProximityEventVendorID,
            value: Int64(deviceVendorID))
        e.setIntegerValueField(
            .tabletProximityEventTabletID,
            value: Int64(deviceProductID))
        e.setIntegerValueField(.tabletProximityEventPointerID, value: 1)
        e.setIntegerValueField(.tabletProximityEventDeviceID, value: 1)
        e.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 0)

        // pointerType: 0 = leaving, 1 = pen, 2 = cursor/mouse, 3 = eraser
        let ptrType: Int64 = entering ? (eraser ? 3 : (activeToolIsMouse ? 2 : 1)) : 0
        e.setIntegerValueField(.tabletProximityEventPointerType, value: ptrType)

        let vendorPtr: Int64 = eraser ? 0x080A : (activeToolIsMouse ? 0x0006 : 0x0802)
        e.setIntegerValueField(.tabletProximityEventVendorPointerType, value: vendorPtr)
        e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x05C7)
        e.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Button binding execution

    private func fireButtonAction(
        _ binding: ButtonBinding, down: Bool,
        at location: CGPoint
    ) {
        switch binding.kind {
        case .none:
            break
        case .leftClick:
            let type: CGEventType = down ? .leftMouseDown : .leftMouseUp
            CGEvent(
                mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: location, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        case .rightClick:
            let type: CGEventType = down ? .rightMouseDown : .rightMouseUp
            CGEvent(
                mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: location, mouseButton: .right)?
                .post(tap: .cghidEventTap)
        case .middleClick:
            let type: CGEventType = down ? .otherMouseDown : .otherMouseUp
            CGEvent(
                mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: location, mouseButton: .center)?
                .post(tap: .cghidEventTap)
        case .keyCombo:
            if binding.keyLabel.isEmpty && binding.modifierFlags != 0 {
                guard let e = CGEvent(source: nil) else { return }
                e.type = .flagsChanged
                e.setIntegerValueField(
                    .keyboardEventKeycode,
                    value: Int64(binding.keyCode))
                e.flags =
                    down
                    ? CGEventFlags(rawValue: binding.modifierFlags)
                    : CGEventFlags()
                e.post(tap: .cghidEventTap)
            } else {
                guard
                    let e = CGEvent(
                        keyboardEventSource: nil,
                        virtualKey: CGKeyCode(binding.keyCode),
                        keyDown: down)
                else { return }
                e.flags = CGEventFlags(rawValue: binding.modifierFlags)
                e.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Scroll wheel

    private func postScrollWheelEvent(delta: Int, at location: CGPoint) {
        // .line units: one detent = one scroll line, consistent with trackpad / Magic Mouse.
        guard
            let e = CGEvent(
                scrollWheelEvent2Source: nil, units: .line,
                wheelCount: 1, wheel1: Int32(delta * 3), wheel2: 0, wheel3: 0)
        else { return }
        e.location = location
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Screen mapping

    private func mapToScreen(_ point: TabletPoint, settings: TabletSettings) -> CGPoint {
        let idx = settings.targetDisplayIndex
        if cachedDisplayIndex != idx {
            cachedDisplayBounds = resolveDisplayBounds(settings: settings)
            cachedDisplayIndex = idx
        }
        let displayBounds = cachedDisplayBounds

        var areaX = settings.activeAreaX * Double(point.maxX)
        var areaY = settings.activeAreaY * Double(point.maxY)
        var areaW = Swift.max(settings.activeAreaWidth, 0.001) * Double(point.maxX)
        var areaH = Swift.max(settings.activeAreaHeight, 0.001) * Double(point.maxY)

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

        let relX = (Double(point.x) - areaX) / areaW
        let relY = (Double(point.y) - areaY) / areaH

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
