import CoreGraphics
import AppKit

/// Converts raw TabletPoint reports into CGEvents and posts them to the HID event tap.
///
/// Event sequence per report:
///   • Proximity change  → tabletProximity event (with full device info)
///   • Every in-proximity report:
///       1. tabletPointer  — carries raw pressure/tilt for Qt/GTK drawing apps
///       2. mouse event    — leftMouseDown / leftMouseDragged / leftMouseUp / mouseMoved
///          with .mouseEventPressure + .mouseEventSubtype=tabletPoint + .mouseEventClickState
///
/// Must run on the main actor — IOHIDManager callbacks are on CFRunLoopGetMain().
@MainActor
final class InputInjector {

    // MARK: - Device identity  (set by TabletManager on connect)

    /// Wacom vendor ID 0x056A; injected into proximity events so apps can identify
    /// the virtual device.
    var deviceVendorID: Int = 0x056A
    /// HID product ID (e.g. 0x0317 for PTH-851, 0x0358 for PTH-860).
    var deviceProductID: Int = 0

    // MARK: - State

    private var lastProximity = false
    private var lastTipDown = false
    private var lastButton1Down = false
    private var lastButton2Down = false
    private var activeButton: CGMouseButton = .left

    // EMA-smoothed cursor position
    private var smoothedPoint: CGPoint = .zero
    private var hasSmoothedPoint = false

    // Click counting — drives mouseEventClickState and position snapping
    private var lastClickPosition: CGPoint = .zero
    private var lastClickTime: CFAbsoluteTime = 0
    private var clickCount: Int = 0
    private var activeClickCount: Int = 1

    // MARK: - Public

    func inject(point: TabletPoint, settings: TabletSettings?) {
        let settings = settings ?? TabletSettings()
        let rawPoint = mapToScreen(point, settings: settings)
        let pressure = settings.pressureCurve.evaluate(point.normalizedPressure)
        let tipDown = pressure > 0.004

        let enteringProximity = point.inProximity && !lastProximity

        // ── Proximity transitions ──────────────────────────────────────────────
        if point.inProximity != lastProximity {
            postProximityEvent(entering: point.inProximity, at: rawPoint,
                               eraser: point.eraser)
            if !point.inProximity {
                if lastTipDown {
                    postMouseUp(button: activeButton, at: smoothedPoint,
                                clickCount: activeClickCount)
                    lastTipDown = false
                }
                hasSmoothedPoint = false
            }
            lastProximity = point.inProximity
        }
        guard point.inProximity else { return }

        // ── Position smoothing ─────────────────────────────────────────────────
        if enteringProximity || !hasSmoothedPoint {
            smoothedPoint = rawPoint
            hasSmoothedPoint = true
        } else {
            let s = settings.smoothingStrength
            if s > 0 {
                let α = 1.0 - s * 0.85
                smoothedPoint = CGPoint(
                    x: smoothedPoint.x + α * (rawPoint.x - smoothedPoint.x),
                    y: smoothedPoint.y + α * (rawPoint.y - smoothedPoint.y)
                )
            } else {
                smoothedPoint = rawPoint
            }
        }
        let screenPoint = smoothedPoint

        // ── Raw tablet event (for Qt/GTK drawing apps: Krita, GIMP, etc.) ──────
        postTabletPointerEvent(at: screenPoint, pressure: pressure, point: point)

        // ── Tip press transitions ──────────────────────────────────────────────
        if tipDown && !lastTipDown {
            activeButton = point.eraser ? .right : .left
            let (clickPt, count) = resolveClick(screenPoint, settings: settings)
            activeClickCount = count
            postMouseDown(button: activeButton, at: clickPt,
                          pressure: pressure, clickCount: count)
        } else if !tipDown && lastTipDown {
            postMouseUp(button: activeButton, at: screenPoint,
                        clickCount: activeClickCount)
        } else if tipDown {
            postMouseDrag(button: activeButton, at: screenPoint, pressure: pressure)
        } else {
            postMouseMoved(at: screenPoint)
        }
        lastTipDown = tipDown

        // ── Pen button transitions ─────────────────────────────────────────────
        let btn1Action = ButtonAction(rawValue: settings.penButton1Action) ?? .rightClick
        let btn2Action = ButtonAction(rawValue: settings.penButton2Action) ?? .middleClick

        if point.penButton1 && !lastButton1Down {
            fireButtonAction(btn1Action, down: true, at: screenPoint)
        } else if !point.penButton1 && lastButton1Down {
            fireButtonAction(btn1Action, down: false, at: screenPoint)
        }
        lastButton1Down = point.penButton1

        if point.penButton2 && !lastButton2Down {
            fireButtonAction(btn2Action, down: true, at: screenPoint)
        } else if !point.penButton2 && lastButton2Down {
            fireButtonAction(btn2Action, down: false, at: screenPoint)
        }
        lastButton2Down = point.penButton2
    }

    // MARK: - Click resolution

    /// Returns the (possibly snapped) click position and the updated click count.
    ///
    /// - Position snapping: if a second tap lands within `doubleClickDistance` pt
    ///   of the first tap AND within the system double-click interval, the second
    ///   tap reports the first tap's exact position so the OS reliably fires a
    ///   double-click.  Chains for triple-click too.
    /// - Click counting: always increments within the system interval and ≤8 pt
    ///   (macOS default) even when snap is disabled, so `.mouseEventClickState`
    ///   is always correct.
    private func resolveClick(_ candidate: CGPoint,
                              settings: TabletSettings) -> (CGPoint, Int) {
        let now = CFAbsoluteTimeGetCurrent()
        let dist = hypot(candidate.x - lastClickPosition.x,
                         candidate.y - lastClickPosition.y)

        let snapThreshold = settings.doubleClickDistance
        // Use snap threshold for count if set, otherwise fall back to macOS default (~8 pt).
        let countThreshold = snapThreshold > 0 ? snapThreshold : 8.0
        let withinTime = now - lastClickTime < NSEvent.doubleClickInterval
        let withinDist = dist < countThreshold

        if withinTime && withinDist {
            clickCount += 1
        } else {
            clickCount = 1
        }

        // Position snap (only when explicitly enabled)
        let snap = snapThreshold > 0 && withinTime && dist < snapThreshold
        let result = snap ? lastClickPosition : candidate
        lastClickPosition = result
        lastClickTime = now
        return (result, clickCount)
    }

    // MARK: - Mouse event helpers

    private func postMouseDown(button: CGMouseButton, at location: CGPoint,
                               pressure: Double, clickCount: Int) {
        let type: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: location, mouseButton: button) else { return }
        e.setDoubleValueField(.mouseEventPressure, value: pressure)
        e.setIntegerValueField(.mouseEventSubtype, value: 1)   // tabletPoint
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        e.post(tap: .cghidEventTap)
    }

    private func postMouseUp(button: CGMouseButton, at location: CGPoint,
                             clickCount: Int) {
        let type: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: location, mouseButton: button) else { return }
        e.setDoubleValueField(.mouseEventPressure, value: 0)
        e.setIntegerValueField(.mouseEventSubtype, value: 1)
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        e.post(tap: .cghidEventTap)
    }

    private func postMouseDrag(button: CGMouseButton, at location: CGPoint,
                               pressure: Double) {
        let type: CGEventType = button == .right ? .rightMouseDragged : .leftMouseDragged
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: location, mouseButton: button) else { return }
        e.setDoubleValueField(.mouseEventPressure, value: pressure)
        e.setIntegerValueField(.mouseEventSubtype, value: 1)
        e.post(tap: .cghidEventTap)
    }

    private func postMouseMoved(at location: CGPoint) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: location, mouseButton: .left) else { return }
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Raw tablet pointer event
    // Posted before each mouse event so that Qt/GTK apps (Krita, GIMP…) receive
    // a proper NSEventTypeTabletPoint to feed their QTabletEvent / GdkDeviceTool
    // paths.  The deviceID matches the one broadcast in proximity events so these
    // apps can associate the data with the registered virtual device.

    private func postTabletPointerEvent(at location: CGPoint, pressure: Double,
                                        point: TabletPoint) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = .tabletPointer
        e.location = location
        e.setIntegerValueField(.tabletEventDeviceID, value: 1)
        e.setIntegerValueField(.tabletEventPointX,   value: Int64(point.x))
        e.setIntegerValueField(.tabletEventPointY,   value: Int64(point.y))
        e.setDoubleValueField (.tabletEventPointPressure, value: pressure)
        e.setDoubleValueField (.tabletEventTiltX,    value: point.tiltX)
        e.setDoubleValueField (.tabletEventTiltY,    value: point.tiltY)
        let buttons: Int64 = (pressure > 0.004 ? 1 : 0)
                           | (point.penButton1 ? 2 : 0)
                           | (point.penButton2 ? 4 : 0)
        e.setIntegerValueField(.tabletEventPointButtons, value: buttons)
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Proximity event

    private func postProximityEvent(entering: Bool, at location: CGPoint,
                                    eraser: Bool) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = .tabletProximity
        e.location = location

        // Device identity — apps register a virtual tablet on these values.
        // deviceID=1 must match what we set in postTabletPointerEvent so that
        // apps like Krita/GIMP can link the two event streams together.
        e.setIntegerValueField(.tabletProximityEventVendorID,          value: Int64(deviceVendorID))
        e.setIntegerValueField(.tabletProximityEventTabletID,          value: Int64(deviceProductID))
        e.setIntegerValueField(.tabletProximityEventPointerID,         value: 1)
        e.setIntegerValueField(.tabletProximityEventDeviceID,          value: 1)
        e.setIntegerValueField(.tabletProximityEventSystemTabletID,    value: 0)

        // Pointer type: 1=pen, 3=eraser
        let ptrType: Int64 = entering ? (eraser ? 3 : 1) : 0
        e.setIntegerValueField(.tabletProximityEventPointerType,       value: ptrType)

        // Wacom vendor pointer type: 0x0802=pen, 0x080A=eraser
        let vendorPtr: Int64 = eraser ? 0x080A : 0x0802
        e.setIntegerValueField(.tabletProximityEventVendorPointerType, value: vendorPtr)

        // Capability flags advertised to the app.
        // bit 0 = buttons, bit 1 = pressure, bit 6 = tiltX, bit 7 = tiltY,
        // bit 10 = hover Z
        e.setIntegerValueField(.tabletProximityEventCapabilityMask,    value: 0x04C3)

        e.setIntegerValueField(.tabletProximityEventEnterProximity,    value: entering ? 1 : 0)
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Button actions

    private func fireButtonAction(_ action: ButtonAction, down: Bool, at location: CGPoint) {
        switch action {
        case .none: break
        case .leftClick:
            let type: CGEventType = down ? .leftMouseDown : .leftMouseUp
            CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
        case .rightClick:
            let type: CGEventType = down ? .rightMouseDown : .rightMouseUp
            CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: location, mouseButton: .right)?.post(tap: .cghidEventTap)
        case .middleClick:
            let type: CGEventType = down ? .otherMouseDown : .otherMouseUp
            CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: location, mouseButton: .center)?.post(tap: .cghidEventTap)
        case .undo:
            postKeyEvent(keyCode: 6, flags: .maskCommand, down: down)
        case .redo:
            postKeyEvent(keyCode: 6, flags: [.maskCommand, .maskShift], down: down)
        case .spaceBar:
            postKeyEvent(keyCode: 49, flags: [], down: down)
        case .escape:
            postKeyEvent(keyCode: 53, flags: [], down: down)
        }
    }

    private func postKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags, down: Bool) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Screen mapping

    private func mapToScreen(_ point: TabletPoint, settings: TabletSettings) -> CGPoint {
        let displayBounds = targetDisplay(settings: settings)
            ?? CGRect(x: 0, y: 0,
                      width: CGFloat(CGDisplayPixelsWide(CGMainDisplayID())),
                      height: CGFloat(CGDisplayPixelsHigh(CGMainDisplayID())))

        let areaX = settings.activeAreaX * Double(point.maxX)
        let areaY = settings.activeAreaY * Double(point.maxY)
        let areaW = Swift.max(settings.activeAreaWidth,  0.001) * Double(point.maxX)
        let areaH = Swift.max(settings.activeAreaHeight, 0.001) * Double(point.maxY)

        let relX = (Double(point.x) - areaX) / areaW
        let relY = (Double(point.y) - areaY) / areaH

        let sx = Swift.min(Swift.max(displayBounds.minX + relX * displayBounds.width,
                                     displayBounds.minX), displayBounds.maxX)
        let sy = Swift.min(Swift.max(displayBounds.minY + relY * displayBounds.height,
                                     displayBounds.minY), displayBounds.maxY)
        return CGPoint(x: sx, y: sy)
    }

    private func targetDisplay(settings: TabletSettings) -> CGRect? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        let idx = settings.targetDisplayIndex
        if idx > 0, idx <= ids.count { return CGDisplayBounds(ids[idx - 1]) }
        return CGDisplayBounds(CGMainDisplayID())
    }
}
