import Foundation
import IOKit.hid

/// Wacom Cintiq 24HD (DTK-2400) — IntuosV1 HID report format.
/// VendorID: 0x056A  ProductID: 0x00F4  InputReportLength: 10 bytes
///
/// Coordinate space: maxX=104480, maxY=65600, maxPressure=2047 (11-bit).
/// Active area covers the full 1920×1200 display surface.
///
/// **EA/E0 alternating report pattern:**
///   Status bit 1 (0x02) is the EA/E0 discriminator — NOT barrel button 1.
///   EA frames (bit 1 set): carry pressure or rotation data in report[6..7].
///   E0 frames (bit 1 clear): carry barrel-button bits; report[6]=0 always.
///
///   EA sub-types (bits 1+3):
///     0xEA/0xEB (bits 1+3 set): Art Pen rotation frame — report[6..7] = rotation angle.
///     0xE2/0xE3 (bit 1 set, bit 3 clear): pressure frame — report[6..7] = 11-bit pressure.
///
/// **Tool-change packets:** status 0xC0 (bits 7,6 set, 5 clear) on proximity enter.
///   Bytes 2–7 carry packed serial number and tool code per IntuosV1 protocol.
///
/// **Barrel button debounce:** E0 frames alternate 1:5 (set:clear) while a button
///   is held.  Clear-counter threshold of 7 survives the gap without false release.
///
/// **Grip Pen bare-tap:** hardware limitation — pressure sensor not activated without
///   barrel button.  Report ID 0x01 tip-switch provides ground-truth contact signal.
final class DTK2400Device: TabletDevice {

    let spec = DigitizerSpec(maxX: 104480, maxY: 65600, maxPressure: 2047)

    private let device: IOHIDDevice
    private let onTablet: (TabletPoint) -> Void
    private let onAux: ((AuxButtons) -> Void)?
    private let onToolEnter: ((ToolIdentity) -> Void)?
    private var reportBuffer = [UInt8](repeating: 0, count: 10)
    private var lastX = 0
    private var lastY = 0

    // ── Pressure state ──────────────────────────────────────────────────────
    private var lastEAPressure = 0

    // ── Rotation ────────────────────────────────────────────────────────────
    private var lastRotation: Double = 0.0

    // ── All-frame hover counter ─────────────────────────────────────────────
    // Counts EVERY frame (EA + E0 + rotation) since the last contact-zone
    // pressure EA.  Reset only by rawPressure >= tipContactThreshold in a
    // non-rotation EA frame.  When it reaches the threshold → force release.
    private var framesSinceLastContactEA = 0
    private static let artPenHoverThreshold  = 35   // ~263 ms at 133 Hz
    private static let gripPenHoverThreshold = 50   // ~375 ms safety net

    private static let tipContactThreshold = 81

    // ── Tip-switch (Report ID 0x01) ─────────────────────────────────────────
    private var lastTipSwitch: Bool = false

    // ── Button debounce ─────────────────────────────────────────────────────
    private var lastButton1: Bool = false
    private var lastButton2: Bool = false
    private var btn1ClearCount = 0
    private var btn2ClearCount = 0
    private static let buttonClearThreshold = 7

    // ── Tool identity ───────────────────────────────────────────────────────
    private var currentSerial: UInt32 = 0
    private var currentToolCode: UInt16 = 0
    private var isEraser: Bool = false
    /// True when the current tool produces rotation EA frames (Art Pen).
    /// Detected from the first EA frame's status bits in each proximity session.
    private var isArtPen: Bool = false
    /// Whether the first EA frame has been seen in the current proximity session.
    private var seenFirstEA: Bool = false

    init(
        device: IOHIDDevice,
        onTablet: @escaping (TabletPoint) -> Void,
        onAux: ((AuxButtons) -> Void)? = nil,
        onToolEnter: ((ToolIdentity) -> Void)? = nil
    ) {
        self.device = device
        self.onTablet = onTablet
        self.onAux = onAux
        self.onToolEnter = onToolEnter
    }

    func open() {
        // Seize to prevent macOS from processing Report ID 0x01 (tip-switch →
        // left click) as native mouse events.  Without seizure, the system fires
        // phantom left-clicks independently of our pressure logic.
        let ret = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard ret == kIOReturnSuccess else {
            print("DTK-2400: failed to seize device (\(ret)). Is another tablet driver running?")
            return
        }

        // Feature init [0x02, 0x02]: activates the digitiser endpoint (same as PTH-851).
        var initBytes: [UInt8] = [0x02, 0x02]
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0x02, &initBytes, initBytes.count)

        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count,
            DTK2400Device.reportCallback, ctx)
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetCurrent(),
            RunLoop.Mode.common.rawValue as CFString)
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(
            device, CFRunLoopGetCurrent(),
            RunLoop.Mode.common.rawValue as CFString)
        IOHIDDeviceRegisterInputReportCallback(device, &reportBuffer, reportBuffer.count, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    }

    // MARK: - C callback

    private static let reportCallback: IOHIDReportCallback = { ctx, _, _, _, _, report, length in
        guard let ctx else { return }
        Unmanaged<DTK2400Device>.fromOpaque(ctx).takeUnretainedValue()
            .handleReport(report: report, length: length)
    }

    private func handleReport(report: UnsafePointer<UInt8>, length: CFIndex) {
        guard length >= 2 else { return }

        let id = report[0]

        // ── Report 0x01: mouse-compatible collection — physical tip-switch ──
        if id == 0x01 {
            handleTipSwitch(report: report, length: length)
            return
        }

        // ── Report 0x0C: express keys (8 keys + touch strips) ───────────────
        if id == 0x0C {
            handleExpressKeys(report: report, length: length)
            return
        }

        guard length >= 10, id == 0x02 || id == 0x10 else { return }

        let status = report[1]

        // ── Tool-change packet: status bits 7:2 == 0b110000 (enter prox) ────
        if (status & 0xFC) == 0xC0 {
            handleToolChange(report: report)
            return
        }

        let inProximity = (status & 0x20) != 0  // bit 5
        let highConf    = (status & 0x40) != 0   // bit 6

        // ── Proximity-out ────────────────────────────────────────────────────
        if !inProximity {
            resetProximityState()
            onTablet(
                TabletPoint(
                    x: lastX, y: lastY, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: 0, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,
                    penButton1: false, penButton2: false,
                    eraser: isEraser, inProximity: false, hoverDistance: 0))
            return
        }

        // ── Low confidence: position unreliable ─────────────────────────────
        guard highConf else {
            onTablet(
                TabletPoint(
                    x: lastX, y: lastY, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: 0, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: lastRotation,
                    penButton1: lastButton1, penButton2: lastButton2,
                    eraser: isEraser, inProximity: true, hoverDistance: 0))
            return
        }

        // ── Coordinate decode (IntuosV1 17-bit) ─────────────────────────────
        let x = ((Int(report[3]) | Int(report[2]) << 8) << 1) | ((Int(report[9]) >> 1) & 1)
        let y = ((Int(report[5]) | Int(report[4]) << 8) << 1) | (Int(report[9]) & 1)

        // All-frame hover counter — incremented every frame; reset only by
        // contact-zone pressure EA frames.
        framesSinceLastContactEA += 1

        let isEA = (status & 0x02) != 0

        if isEA {
            let isRotation = (status & 0x0A) == 0x0A  // bits 1+3 both set

            // Detect Art Pen from first EA frame's status bits.
            if !seenFirstEA {
                seenFirstEA = true
                isArtPen = isRotation
            }

            if isRotation {
                // ── Art Pen rotation frame ───────────────────────────────────
                let rawRot = (Int(report[6]) << 3) | ((Int(report[7]) >> 5) & 7)
                let signedRot = (report[7] & 0x20) != 0 ? rawRot - 1024 : rawRot
                var degrees = Double(signedRot) * 360.0 / 1024.0
                if degrees < 0 { degrees += 360.0 }
                lastRotation = degrees

            } else {
                // ── Normal pressure frame (0xE2/0xE3) ───────────────────────
                let rawPressure =
                    (Int(report[6]) << 3)
                    | ((Int(report[7] & 0xC0)) >> 5)
                    | (Int(status) & 1)

                if rawPressure >= Self.tipContactThreshold {
                    lastEAPressure = rawPressure
                    framesSinceLastContactEA = 0
                } else if rawPressure == 0 {
                    // Zero-pressure interleave: preserve lastEAPressure.
                } else {
                    // Hover zone (1–80): pen lifting off surface.
                    if lastEAPressure > 0 {
                        lastEAPressure = 0
                        framesSinceLastContactEA = 0
                    }
                }
            }

        } else {
            // ── E0 frame: barrel-button channel ─────────────────────────────
            let curBtn1 = (status & 0x04) != 0
            let curBtn2 = (status & 0x10) != 0

            if curBtn1 {
                btn1ClearCount = 0
                lastButton1 = true
            } else {
                btn1ClearCount += 1
                if btn1ClearCount >= Self.buttonClearThreshold {
                    lastButton1 = false
                }
            }

            if curBtn2 {
                btn2ClearCount = 0
                lastButton2 = true
            } else {
                btn2ClearCount += 1
                if btn2ClearCount >= Self.buttonClearThreshold {
                    lastButton2 = false
                }
            }
        }

        // ── All-frame hover timeout ─────────────────────────────────────────
        let timeout = isArtPen ? Self.artPenHoverThreshold : Self.gripPenHoverThreshold
        if lastEAPressure > 0 && framesSinceLastContactEA >= timeout {
            lastEAPressure = 0
            framesSinceLastContactEA = 0
        }

        // ── Tilt decode ─────────────────────────────────────────────────────
        let tiltXRaw = (((Int(report[7]) << 1) & 0x7E) | (Int(report[8]) >> 7)) - 64
        let tiltYRaw = (Int(report[8]) & 0x7F) - 64

        lastX = x
        lastY = y

        onTablet(
            TabletPoint(
                x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                pressure: lastEAPressure, maxPressure: spec.maxPressure,
                tiltX: Double(tiltXRaw) / 63.0,
                tiltY: Double(tiltYRaw) / 63.0,
                rotation: lastRotation,
                penButton1: lastButton1,
                penButton2: lastButton2,
                eraser: isEraser,
                inProximity: true,
                hoverDistance: Int(report[9])
            ))
    }

    // MARK: - Report 0x01: physical tip-switch

    private func handleTipSwitch(report: UnsafePointer<UInt8>, length: CFIndex) {
        let tipDown = (report[1] & 0x01) != 0
        guard tipDown != lastTipSwitch else { return }
        lastTipSwitch = tipDown

        if tipDown {
            if lastEAPressure == 0 {
                lastEAPressure = Self.tipContactThreshold
                framesSinceLastContactEA = 0
            }
        } else {
            lastEAPressure = 0
            framesSinceLastContactEA = 0
        }
    }

    // MARK: - Report 0x0C: express keys

    private func handleExpressKeys(report: UnsafePointer<UInt8>, length: CFIndex) {
        guard length >= 2, let onAux = onAux else { return }
        let keyByte = report[1]
        onAux(AuxButtons(buttons: (0..<8).map { bit in (keyByte & (1 << bit)) != 0 }))
    }

    // MARK: - Tool-change packet (status bits 7:2 == 0xC0)

    private func handleToolChange(report: UnsafePointer<UInt8>) {
        let serial = UInt32(report[3] & 0x0F) << 28
                   | UInt32(report[4]) << 20
                   | UInt32(report[5]) << 12
                   | UInt32(report[6]) << 4
                   | UInt32(report[7]) >> 4
        let toolCode = UInt16(report[2]) << 4
                     | UInt16(report[3]) >> 4
                     | UInt16(report[7] & 0x0F) << 12
                     | UInt16(report[8] & 0xF0) << 4

        currentSerial   = serial
        currentToolCode = toolCode
        isEraser = (toolCode & 0x000F) == 0x000A
            || (toolCode & 0x0FFF) == 0x0804

        onToolEnter?(
            ToolIdentity(
                serial: serial,
                toolCode: toolCode,
                isEraser: isEraser,
                isMouse: false))
    }

    // MARK: - State reset

    private func resetProximityState() {
        lastEAPressure = 0
        lastTipSwitch = false
        framesSinceLastContactEA = 0
        lastButton1 = false
        lastButton2 = false
        lastRotation = 0.0
        btn1ClearCount = 0
        btn2ClearCount = 0
        seenFirstEA = false
        isArtPen = false
    }
}
