import CoreGraphics
import AppKit

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

    var deviceVendorID:     Int
    var deviceProductID:    Int
    var activeToolSettings: ToolSettings? = nil

    init(vendorID: Int = 0x056A, productID: Int = 0) {
        self.deviceVendorID  = vendorID
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

    private(set) var lastProximity  = false
    private var lastTipDown         = false
    private var lastButton1Down     = false
    private var lastButton2Down     = false
    private var activeButton: CGMouseButton = .left

    // MARK: - Jitter tracking
    //
    // Fixed ring buffer + running sum.
    // Eliminates O(n) Array.removeFirst() and a full reduce() on every jitterLevel read.

    private static let jitterWindow = 60    // ~0.5 s at 133 Hz
    private var hoverRing  = ContiguousArray<CGFloat>(repeating: 0, count: jitterWindow)
    private var hoverHead  = 0
    private var hoverCount = 0
    private var hoverSum:  CGFloat = 0
    private var lastRawPoint:   CGPoint = .zero
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
        hoverSum  += delta
        hoverHead  = (hoverHead + 1) % Self.jitterWindow
    }

    private func clearHoverDeltas() {
        guard hoverCount > 0 else { return }
        hoverCount = 0
        hoverSum   = 0
    }

    // MARK: - Smoothing

    private var smoothedPoint:   CGPoint = .zero
    private var hasSmoothedPoint = false
    /// Cached EMA alpha, recomputed at proximity entry.
    /// 1.0 == raw (no smoothing); math collapses to smoothedPoint = rawPoint.
    private var smoothingAlpha: Double = 1.0

    // MARK: - Delta gate
    //
    // Skip posting to the Window Server when position and pressure haven't changed
    // meaningfully. The tablet sends identical coordinates at 133 Hz while stationary;
    // suppressing those drops Mach IPC to zero and eliminates idle wakeups entirely.

    private static let positionEpsilon: CGFloat = 0.5   // sub-pixel, not worth posting
    private static let pressureEpsilon: Double  = 0.002

    private var lastPostedPoint:    CGPoint = .zero
    private var lastPostedPressure: Double  = -1.0
    private var hasPostedPoint      = false

    // MARK: - Click state

    private var lastClickPosition: CGPoint = .zero
    private var lastClickTime:     CFAbsoluteTime = 0
    private var clickCount:        Int = 0
    private var activeClickCount:  Int = 1

    // MARK: - Express key state

    private var lastAuxButtons = [Bool](repeating: false, count: 8)

    // MARK: - Display bounds cache

    private var cachedDisplayBounds: CGRect = .zero
    private var cachedDisplayIndex:  Int    = Int.min
    private var displayObserver: NSObjectProtocol?

    // MARK: - Pen injection

    func inject(point: TabletPoint, settings: TabletSettings?) {
        let settings = settings ?? TabletSettings()
        let tool     = activeToolSettings ?? settings.activeTool
        let rawPoint = mapToScreen(point, settings: settings)
        let pressure = tool.pressureCurve.evaluate(point.normalizedPressure)
        let tipDown  = pressure > 0.004

        let enteringProximity = point.inProximity && !lastProximity

        // ── Proximity transitions (always immediate) ───────────────────────────
        if point.inProximity != lastProximity {
            postProximityEvent(entering: point.inProximity, at: rawPoint,
                               eraser: point.eraser)
            if point.inProximity {
                let s = tool.smoothingStrength
                smoothingAlpha = s > 0 ? 1.0 - s * 0.85 : 1.0
            } else {
                if lastTipDown {
                    postMouseUp(button: activeButton, at: smoothedPoint,
                                clickCount: activeClickCount)
                    lastTipDown = false
                }
                hasSmoothedPoint   = false
                hasLastRawPoint    = false
                hasPostedPoint     = false
                lastPostedPressure = -1.0
                clearHoverDeltas()
            }
            lastProximity = point.inProximity
        }
        guard point.inProximity else { return }

        // ── Position smoothing (every report) ─────────────────────────────────
        if enteringProximity || !hasSmoothedPoint {
            smoothedPoint    = rawPoint
            hasSmoothedPoint = true
        } else {
            smoothedPoint = CGPoint(
                x: smoothedPoint.x + smoothingAlpha * (rawPoint.x - smoothedPoint.x),
                y: smoothedPoint.y + smoothingAlpha * (rawPoint.y - smoothedPoint.y)
            )
        }
        let screenPoint = smoothedPoint

        // ── Jitter tracking (hover only, every report) ─────────────────────────
        if !tipDown {
            if hasLastRawPoint {
                addHoverDelta(hypot(rawPoint.x - lastRawPoint.x,
                                    rawPoint.y - lastRawPoint.y))
            }
            lastRawPoint    = rawPoint
            hasLastRawPoint = true
        } else {
            hasLastRawPoint = false
            clearHoverDeltas()
        }

        // ── Tip press transitions (always immediate) ───────────────────────────
        if tipDown != lastTipDown {
            postTabletPointerEvent(at: screenPoint, pressure: pressure, point: point)
            if tipDown {
                let tipAction = point.eraser ? tool.eraserBinding : tool.tipBinding
                activeButton  = tipAction.mouseButton ?? (point.eraser ? .right : .left)
                let (clickPt, count) = resolveClick(screenPoint, settings: settings)
                activeClickCount = count
                postMouseDown(button: activeButton, at: clickPt,
                              pressure: pressure, clickCount: count)
            } else {
                postMouseUp(button: activeButton, at: screenPoint,
                            clickCount: activeClickCount)
            }
            lastPostedPoint    = screenPoint
            lastPostedPressure = pressure
            hasPostedPoint     = true

        } else {
            // ── Continuous movement: delta gate ────────────────────────────────
            let moved = !hasPostedPoint
                     || abs(screenPoint.x - lastPostedPoint.x) > Self.positionEpsilon
                     || abs(screenPoint.y - lastPostedPoint.y) > Self.positionEpsilon
                     || (tipDown && abs(pressure - lastPostedPressure) > Self.pressureEpsilon)

            if moved {
                postTabletPointerEvent(at: screenPoint, pressure: pressure, point: point)
                if tipDown {
                    postMouseDrag(button: activeButton, at: screenPoint, pressure: pressure)
                } else {
                    postMouseMoved(at: screenPoint)
                }
                lastPostedPoint    = screenPoint
                lastPostedPressure = pressure
                hasPostedPoint     = true
            }
        }
        lastTipDown = tipDown

        // ── Pen button transitions (always immediate) ──────────────────────────
        let btn1 = tool.penButton1Binding
        let btn2 = tool.penButton2Binding

        if point.penButton1 != lastButton1Down {
            fireButtonAction(btn1, down: point.penButton1, at: screenPoint)
            lastButton1Down = point.penButton1
        }
        if point.penButton2 != lastButton2Down {
            fireButtonAction(btn2, down: point.penButton2, at: screenPoint)
            lastButton2Down = point.penButton2
        }
    }

    // MARK: - Express key injection

    func injectAux(buttons: AuxButtons, settings: TabletSettings?) {
        let s         = settings ?? TabletSettings()
        let bindings  = s.expressKeyBindings
        let cursorPos = currentCursorPosition()
        for i in 0..<8 {
            let down = buttons[i]
            if down != lastAuxButtons[i] {
                fireButtonAction(bindings[i], down: down, at: cursorPos)
                lastAuxButtons[i] = down
            }
        }
    }

    private func currentCursorPosition() -> CGPoint {
        let loc     = NSEvent.mouseLocation
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
        e.setDoubleValueField (.mouseEventPressure,   value: pressure)
        e.setIntegerValueField(.mouseEventSubtype,    value: 1)
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        e.post(tap: .cghidEventTap)
    }

    private func postMouseUp(button: CGMouseButton, at location: CGPoint,
                             clickCount: Int) {
        let type: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: location, mouseButton: button) else { return }
        e.setDoubleValueField (.mouseEventPressure,   value: 0)
        e.setIntegerValueField(.mouseEventSubtype,    value: 1)
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        e.post(tap: .cghidEventTap)
    }

    private func postMouseDrag(button: CGMouseButton, at location: CGPoint,
                               pressure: Double) {
        let type: CGEventType = button == .right ? .rightMouseDragged : .leftMouseDragged
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: location, mouseButton: button) else { return }
        e.setDoubleValueField (.mouseEventPressure, value: pressure)
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
        e.type     = .tabletPointer
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
        e.setIntegerValueField(.tabletEventPointButtons,  value: buttons)
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Proximity event

    private func postProximityEvent(entering: Bool, at location: CGPoint,
                                    eraser: Bool) {
        guard let e = CGEvent(source: nil) else { return }
        e.type     = .tabletProximity
        e.location = location

        e.setIntegerValueField(.tabletProximityEventVendorID,
                               value: Int64(deviceVendorID))
        e.setIntegerValueField(.tabletProximityEventTabletID,
                               value: Int64(deviceProductID))
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

    private func fireButtonAction(_ binding: ButtonBinding, down: Bool,
                                  at location: CGPoint) {
        switch binding.kind {
        case .none:
            break
        case .leftClick:
            let type: CGEventType = down ? .leftMouseDown : .leftMouseUp
            CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: location, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        case .rightClick:
            let type: CGEventType = down ? .rightMouseDown : .rightMouseUp
            CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: location, mouseButton: .right)?
                .post(tap: .cghidEventTap)
        case .middleClick:
            let type: CGEventType = down ? .otherMouseDown : .otherMouseUp
            CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: location, mouseButton: .center)?
                .post(tap: .cghidEventTap)
        case .keyCombo:
            if binding.keyLabel.isEmpty && binding.modifierFlags != 0 {
                guard let e = CGEvent(source: nil) else { return }
                e.type = .flagsChanged
                e.setIntegerValueField(.keyboardEventKeycode,
                                       value: Int64(binding.keyCode))
                e.flags = down ? CGEventFlags(rawValue: binding.modifierFlags)
                                : CGEventFlags()
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
        let idx = settings.targetDisplayIndex
        if cachedDisplayIndex != idx {
            cachedDisplayBounds = resolveDisplayBounds(settings: settings)
            cachedDisplayIndex  = idx
        }
        let displayBounds = cachedDisplayBounds

        var areaX = settings.activeAreaX * Double(point.maxX)
        var areaY = settings.activeAreaY * Double(point.maxY)
        var areaW = Swift.max(settings.activeAreaWidth,  0.001) * Double(point.maxX)
        var areaH = Swift.max(settings.activeAreaHeight, 0.001) * Double(point.maxY)

        if settings.proportionalMapping {
            let tabletAspect  = areaW / areaH
            let displayAspect = Double(displayBounds.width) / Double(displayBounds.height)
            if tabletAspect > displayAspect {
                let effectiveW = areaH * displayAspect
                areaX += (areaW - effectiveW) / 2
                areaW  = effectiveW
            } else if tabletAspect < displayAspect {
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

    /// Queries the OS display list and returns the target display's bounds.
    /// Only called on cache miss; result stored in cachedDisplayBounds.
    private func resolveDisplayBounds(settings: TabletSettings) -> CGRect {
        let fallback = CGRect(
            x: 0, y: 0,
            width:  CGFloat(CGDisplayPixelsWide(CGMainDisplayID())),
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
        if idx > 0, idx <= ids.count { return CGDisplayBounds(ids[idx - 1]) }
        return CGDisplayBounds(CGMainDisplayID())
    }
}
