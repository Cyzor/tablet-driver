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

    // MARK: - Device identity

    /// Vendor ID for proximity events.  Defaults to Wacom (0x056A).
    /// Can be set at init or updated later when a device connects.
    var deviceVendorID: Int

    /// Product ID for proximity events.  Identifies the physical tablet model
    /// so drawing apps (Photoshop, Krita, etc.) route pressure correctly.
    var deviceProductID: Int

    /// The tool settings for the pen currently in proximity.
    /// Set by TabletManager on tool-enter; nil reverts to reading from TabletSettings.
    var activeToolSettings: ToolSettings? = nil

    init(vendorID: Int = 0x056A, productID: Int = 0) {
        self.deviceVendorID  = vendorID
        self.deviceProductID = productID
    }

    // MARK: - State

    /// Whether the pen is currently in proximity.  Read by TabletManager
    /// during multi-device handoff so the outgoing device can post its
    /// proximity-exit event before the incoming device takes over.
    private(set) var lastProximity = false
    private var lastTipDown     = false
    private var lastButton1Down = false
    private var lastButton2Down = false
    private var activeButton: CGMouseButton = .left

    // MARK: - Jitter tracking

    /// Rolling window of consecutive raw-position deltas while hovering.
    /// Used by the Info pane to flag potential RF interference.
    private var hoverDeltas: [CGFloat] = []
    private var lastRawPoint: CGPoint = .zero
    private var hasLastRawPoint = false
    private static let jitterWindow = 60    // ~0.5s at 133 Hz

    /// Mean hover-delta over the rolling window (points per sample).
    /// Spikes above ~3 pt/sample while hovering suggest RF noise.
    var jitterLevel: CGFloat {
        guard hoverDeltas.count >= 10 else { return 0 }
        return hoverDeltas.reduce(0, +) / CGFloat(hoverDeltas.count)
    }

    /// True when the recent hover movement looks like electrical noise
    /// rather than intentional pen motion.
    var isJittery: Bool { jitterLevel > 3.0 }

    // EMA-smoothed cursor position
    private var smoothedPoint: CGPoint = .zero
    private var hasSmoothedPoint = false

    // Click counting
    private var lastClickPosition: CGPoint = .zero
    private var lastClickTime:     CFAbsoluteTime = 0
    private var clickCount:        Int = 0
    private var activeClickCount:  Int = 1

    // Express key state tracking
    private var lastAuxButtons: [Bool] = Array(repeating: false, count: 8)

    // MARK: - Pen injection

    func inject(point: TabletPoint, settings: TabletSettings?) {
        let settings = settings ?? TabletSettings()
        let tool = activeToolSettings ?? settings.activeTool
        let rawPoint = mapToScreen(point, settings: settings)
        let pressure = tool.pressureCurve.evaluate(point.normalizedPressure)
        let tipDown  = pressure > 0.004

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
                hasLastRawPoint = false
                hoverDeltas.removeAll()
            }
            lastProximity = point.inProximity
        }
        guard point.inProximity else { return }

        // ── Position smoothing ─────────────────────────────────────────────────
        if enteringProximity || !hasSmoothedPoint {
            smoothedPoint = rawPoint
            hasSmoothedPoint = true
        } else {
            let s = tool.smoothingStrength
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

        // ── Jitter tracking (hover only) ──────────────────────────────────────
        if !tipDown {
            if hasLastRawPoint {
                let delta = hypot(rawPoint.x - lastRawPoint.x,
                                  rawPoint.y - lastRawPoint.y)
                hoverDeltas.append(delta)
                if hoverDeltas.count > Self.jitterWindow {
                    hoverDeltas.removeFirst(hoverDeltas.count - Self.jitterWindow)
                }
            }
            lastRawPoint = rawPoint
            hasLastRawPoint = true
        } else {
            // While drawing, don't accumulate deltas — intentional strokes
            // would inflate the jitter metric.
            hasLastRawPoint = false
            hoverDeltas.removeAll()
        }

        // ── Raw tablet event (for Qt/GTK drawing apps: Krita, GIMP, etc.) ──────
        postTabletPointerEvent(at: screenPoint, pressure: pressure, point: point)

        // ── Tip press transitions ──────────────────────────────────────────────
        if tipDown && !lastTipDown {
            let tipAction    = point.eraser ? tool.eraserBinding : tool.tipBinding
            activeButton = tipAction.mouseButton ?? (point.eraser ? .right : .left)
            let (clickPt, count) = resolveClick(screenPoint, settings: settings)
            activeClickCount = count
            print(String(format: "Inject: mouseDown at (%.0f, %.0f) pressure=%.3f click=%d",
                         clickPt.x, clickPt.y, pressure, count))
            postMouseDown(button: activeButton, at: clickPt,
                          pressure: pressure, clickCount: count)
        } else if !tipDown && lastTipDown {
            print(String(format: "Inject: mouseUp   at (%.0f, %.0f) click=%d",
                         screenPoint.x, screenPoint.y, activeClickCount))
            postMouseUp(button: activeButton, at: screenPoint,
                        clickCount: activeClickCount)
        } else if tipDown {
            postMouseDrag(button: activeButton, at: screenPoint, pressure: pressure)
        } else {
            postMouseMoved(at: screenPoint)
        }
        lastTipDown = tipDown

        // ── Pen button transitions ─────────────────────────────────────────────
        let btn1 = tool.penButton1Binding
        let btn2 = tool.penButton2Binding

        if point.penButton1 && !lastButton1Down {
            fireButtonAction(btn1, down: true, at: screenPoint)
        } else if !point.penButton1 && lastButton1Down {
            fireButtonAction(btn1, down: false, at: screenPoint)
        }
        lastButton1Down = point.penButton1

        if point.penButton2 && !lastButton2Down {
            fireButtonAction(btn2, down: true, at: screenPoint)
        } else if !point.penButton2 && lastButton2Down {
            fireButtonAction(btn2, down: false, at: screenPoint)
        }
        lastButton2Down = point.penButton2
    }

    // MARK: - Express key injection

    func injectAux(buttons: AuxButtons, settings: TabletSettings?) {
        let s = settings ?? TabletSettings()
        let bindings = s.expressKeyBindings
        let cursorPos = currentCursorPosition()
        for i in 0..<8 {
            let down = buttons[i]
            let wasDown = i < lastAuxButtons.count ? lastAuxButtons[i] : false
            if down != wasDown {
                fireButtonAction(bindings[i], down: down, at: cursorPos)
            }
        }
        lastAuxButtons = (0..<8).map { buttons[$0] }
    }

    private func currentCursorPosition() -> CGPoint {
        let loc = NSEvent.mouseLocation
        let screenH = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        return CGPoint(x: loc.x, y: screenH - loc.y)
    }

    // MARK: - Click resolution

    private func resolveClick(_ candidate: CGPoint,
                              settings: TabletSettings) -> (CGPoint, Int) {
        let now  = CFAbsoluteTimeGetCurrent()
        let dist = hypot(candidate.x - lastClickPosition.x,
                         candidate.y - lastClickPosition.y)

        let snapThreshold  = settings.doubleClickDistance
        let countThreshold = snapThreshold > 0 ? snapThreshold : 8.0
        let withinTime     = now - lastClickTime < NSEvent.doubleClickInterval
        let withinDist     = dist < countThreshold

        if withinTime && withinDist { clickCount += 1 } else { clickCount = 1 }

        let snap   = snapThreshold > 0 && withinTime && dist < snapThreshold
        let result = snap ? lastClickPosition : candidate
        lastClickPosition = result
        lastClickTime     = now
        return (result, clickCount)
    }

    // MARK: - Mouse event helpers

    private func postMouseDown(button: CGMouseButton, at location: CGPoint,
                               pressure: Double, clickCount: Int) {
        let type: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: location, mouseButton: button) else { return }
        e.setDoubleValueField(.mouseEventPressure,    value: pressure)
        e.setIntegerValueField(.mouseEventSubtype,    value: 1)   // tabletPoint
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        e.post(tap: .cghidEventTap)
    }

    private func postMouseUp(button: CGMouseButton, at location: CGPoint,
                             clickCount: Int) {
        let type: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: location, mouseButton: button) else { return }
        e.setDoubleValueField(.mouseEventPressure,    value: 0)
        e.setIntegerValueField(.mouseEventSubtype,    value: 1)
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        e.post(tap: .cghidEventTap)
    }

    private func postMouseDrag(button: CGMouseButton, at location: CGPoint,
                               pressure: Double) {
        let type: CGEventType = button == .right ? .rightMouseDragged : .leftMouseDragged
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: location, mouseButton: button) else { return }
        e.setDoubleValueField(.mouseEventPressure,  value: pressure)
        e.setIntegerValueField(.mouseEventSubtype,  value: 1)
        e.post(tap: .cghidEventTap)
    }

    private func postMouseMoved(at location: CGPoint) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: location, mouseButton: .left) else { return }
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Raw tablet pointer event

    private func postTabletPointerEvent(at location: CGPoint, pressure: Double,
                                        point: TabletPoint) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = .tabletPointer
        e.location = location
        e.setIntegerValueField(.tabletEventDeviceID,      value: 1)
        e.setIntegerValueField(.tabletEventPointX,        value: Int64(point.x))
        e.setIntegerValueField(.tabletEventPointY,        value: Int64(point.y))
        e.setDoubleValueField (.tabletEventPointPressure, value: pressure)
        e.setDoubleValueField (.tabletEventTiltX,         value: point.tiltX)
        e.setDoubleValueField (.tabletEventTiltY,         value: point.tiltY)
        let buttons: Int64 = (pressure > 0.004 ? 1 : 0)
                           | (point.penButton1  ? 2 : 0)
                           | (point.penButton2  ? 4 : 0)
        e.setIntegerValueField(.tabletEventPointButtons, value: buttons)
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Proximity event

    private func postProximityEvent(entering: Bool, at location: CGPoint,
                                    eraser: Bool) {
        guard let e = CGEvent(source: nil) else { return }
        e.type = .tabletProximity
        e.location = location

        e.setIntegerValueField(.tabletProximityEventVendorID,          value: Int64(deviceVendorID))
        e.setIntegerValueField(.tabletProximityEventTabletID,          value: Int64(deviceProductID))
        e.setIntegerValueField(.tabletProximityEventPointerID,         value: 1)
        e.setIntegerValueField(.tabletProximityEventDeviceID,          value: 1)
        e.setIntegerValueField(.tabletProximityEventSystemTabletID,    value: 0)

        let ptrType: Int64 = entering ? (eraser ? 3 : 1) : 0
        e.setIntegerValueField(.tabletProximityEventPointerType,       value: ptrType)

        let vendorPtr: Int64 = eraser ? 0x080A : 0x0802
        e.setIntegerValueField(.tabletProximityEventVendorPointerType, value: vendorPtr)
        e.setIntegerValueField(.tabletProximityEventCapabilityMask,    value: 0x04C3)
        e.setIntegerValueField(.tabletProximityEventEnterProximity,    value: entering ? 1 : 0)
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Button binding execution

    private func fireButtonAction(_ binding: ButtonBinding, down: Bool, at location: CGPoint) {
        switch binding.kind {
        case .none:
            break
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
        case .keyCombo:
            if binding.keyLabel.isEmpty && binding.modifierFlags != 0 {
                // Modifier-only binding: post a flagsChanged event so apps see the
                // modifier held/released without any base key being pressed.
                // keyCode holds the primary modifier's left-side virtualKey (55/56/58/59).
                guard let e = CGEvent(source: nil) else { return }
                e.type = .flagsChanged
                e.setIntegerValueField(.keyboardEventKeycode, value: Int64(binding.keyCode))
                e.flags = down ? CGEventFlags(rawValue: binding.modifierFlags) : CGEventFlags()
                e.post(tap: .cghidEventTap)
            } else {
                guard let e = CGEvent(keyboardEventSource: nil,
                                      virtualKey: CGKeyCode(binding.keyCode),
                                      keyDown: down) else { return }
                e.flags = CGEventFlags(rawValue: binding.modifierFlags)
                e.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Screen mapping

    private func mapToScreen(_ point: TabletPoint, settings: TabletSettings) -> CGPoint {
        let displayBounds = targetDisplay(settings: settings)
            ?? CGRect(x: 0, y: 0,
                      width:  CGFloat(CGDisplayPixelsWide(CGMainDisplayID())),
                      height: CGFloat(CGDisplayPixelsHigh(CGMainDisplayID())))

        var areaX = settings.activeAreaX * Double(point.maxX)
        var areaY = settings.activeAreaY * Double(point.maxY)
        var areaW = Swift.max(settings.activeAreaWidth,  0.001) * Double(point.maxX)
        var areaH = Swift.max(settings.activeAreaHeight, 0.001) * Double(point.maxY)

        // Proportional mapping: constrain the active area to the display's aspect ratio,
        // centred within the user-selected area, so pen movement has no distortion.
        if settings.proportionalMapping {
            let tabletAspect  = areaW / areaH
            let displayAspect = Double(displayBounds.width) / Double(displayBounds.height)
            if tabletAspect > displayAspect {
                // Active area wider than display → letterbox left/right
                let effectiveW = areaH * displayAspect
                areaX += (areaW - effectiveW) / 2
                areaW  = effectiveW
            } else if tabletAspect < displayAspect {
                // Active area taller than display → letterbox top/bottom
                let effectiveH = areaW / displayAspect
                areaY += (areaH - effectiveH) / 2
                areaH  = effectiveH
            }
        }

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
