import Foundation
import IOKit.hid

/// Wacom Intuos Pro Large (PTH-860) — IntuosV2 HID report format.
/// VendorID: 0x056A  ProductID: 0x0358  InputReportLength: 192 bytes
///
/// Serial number layout (same as PTH-660, verified by protocol analysis):
///   Bytes 17–20: pen serial (32-bit LE) — unique per physical pen body
///   Bytes 21–22: tool code (16-bit LE) — e.g. 0x0832 Pro Pen 2, 0x083A eraser
final class PTH860Device: TabletDevice {

    let spec = DigitizerSpec(maxX: 62200, maxY: 43200, maxPressure: 8191)

    private let device: IOHIDDevice
    private let onTablet: (TabletPoint) -> Void
    private let onAux: ((AuxButtons) -> Void)?
    private let onToolEnter: ((ToolIdentity) -> Void)?
    private var reportBuffer = [UInt8](repeating: 0, count: 192)
    private var lastX = 0
    private var lastY = 0
    private var lastSerial: UInt32 = 0
    private var lastToolCode: UInt16 = 0
    private var currentToolCode: UInt16 = 0
    /// Absolute scroll-position counter from byte [16] of mouse-tool reports.
    private var lastScrollPos: UInt8 = 0

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
        let ret = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard ret == kIOReturnSuccess else {
            print("PTH-860: failed to open — \(ret). Is another tablet driver running?")
            return
        }
        sendWacomInputModeInit(device, tag: "PTH-860")
        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count,
            PTH860Device.reportCallback, ctx)
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(
            device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)
        IOHIDDeviceRegisterInputReportCallback(device, &reportBuffer, reportBuffer.count, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: - C callback

    private static let reportCallback: IOHIDReportCallback = {
        ctx, result, sender, type, reportID, report, length in
        guard let ctx = ctx else { return }
        let self_ = Unmanaged<PTH860Device>.fromOpaque(ctx).takeUnretainedValue()
        self_.handleReport(report: report, length: length)
    }

    private func handleReport(report: UnsafePointer<UInt8>, length: CFIndex) {
        guard length >= 2 else { return }

        switch report[0] {
        case 0x01:
            // BLE HOGP pen report (23 bytes) — Intuos Pro over Bluetooth LE.
            handleBLEPen(report: report, length: length)
        case 0x03:
            // BLE HOGP pad report (9 bytes).
            if let aux = decodeBLEPadReport(report: report, length: length) {
                onAux?(aux)
            }
        case 0x10:
            guard length >= 12 else { return }
            handlePenReport(report: report, length: length)
        case 0x1E:
            handleOffsetPenReport(report: report)
        case 0x11:
            handleAuxReport(report: report, length: length)
        case 0x13: break  // touch-ring mode / position — not yet handled
        default: break
        }
    }

    /// Standard pen report (Report ID 0x10) — IntuosV2Report layout.
    private func handlePenReport(report: UnsafePointer<UInt8>, length: CFIndex) {
        let status = report[1]
        let highConfidence = (status & 0x20) != 0  // bit 5

        // Proximity-out: all position bytes zero and confidence lost.
        let allZero =
            report[2] == 0 && report[3] == 0 && report[4] == 0
            && report[5] == 0 && report[6] == 0 && report[7] == 0
        if allZero && !highConfidence {
            let liftPt = TabletPoint(
                x: lastX, y: lastY, maxX: spec.maxX, maxY: spec.maxY,
                pressure: 0, maxPressure: spec.maxPressure,
                tiltX: 0, tiltY: 0, rotation: 0.0,
                penButton1: false, penButton2: false,
                eraser: false, inProximity: false, hoverDistance: 0)
            onTablet(liftPt)
            return
        }

        // Low confidence with a valid position — pen lifting off surface. Emit zero pressure
        // so InputInjector fires mouseUp rather than keeping the button stuck.
        // NOTE: keep barrel-button and eraser bits from status — highConfidence is a
        // position-quality flag independent of which physical buttons are held.
        guard highConfidence else {
            let pt = TabletPoint(
                x: lastX, y: lastY, maxX: spec.maxX, maxY: spec.maxY,
                pressure: 0, maxPressure: spec.maxPressure,
                tiltX: 0, tiltY: 0, rotation: 0.0,
                penButton1: (status & 0x02) != 0,
                penButton2: (status & 0x04) != 0,
                eraser: (status & 0x10) != 0,
                inProximity: true, hoverDistance: 0)
            onTablet(pt)
            return
        }

        // Extract pen serial (bytes 17–20 LE) and tool code (bytes 21–22 LE).
        // Present in every 27-byte report; fire onToolEnter whenever the active pen changes.
        if length >= 27 {
            let serial =
                UInt32(report[17])
                | UInt32(report[18]) << 8
                | UInt32(report[19]) << 16
                | UInt32(report[20]) << 24
            let toolCode = UInt16(report[21]) | UInt16(report[22]) << 8
            currentToolCode = toolCode

            let toolChanged = serial != 0 ? serial != lastSerial : (toolCode != 0 && toolCode != lastToolCode)
            if toolChanged {
                lastSerial     = serial
                lastToolCode   = toolCode

                // Mouse/cursor tools: bits 1+2 set in the low nibble (0x_6 pattern).
                let isMouse = (toolCode & 0x000F) == 0x0006
                // Seed scroll counter to avoid a large spurious delta on first mouse report.
                if isMouse { lastScrollPos = report[16] }

                onToolEnter?(
                    ToolIdentity(
                        serial: serial,
                        toolCode: toolCode,
                        isEraser: (toolCode & 0x0008) != 0,
                        isMouse: isMouse))
            }

        }

        // IntuosV2 coordinate decode — identical for pen and mouse.
        let x = Int(UInt16(report[2]) | UInt16(report[3]) << 8) | (Int(report[4]) << 16)
        let y = Int(UInt16(report[5]) | UInt16(report[6]) << 8) | (Int(report[7]) << 16)
        lastX = x
        lastY = y

        // ── Mouse path ─────────────────────────────────────────────────────────
        // Byte [16] is an absolute 8-bit counter that wraps at 255.  Signed delta
        // via Int8(bitPattern:) handles wrap-around correctly (255→0 = +1 step).
        // Pressure bytes [8–9] are always 0x0000 for cursor/mouse tools.
        //
        // Status bit assumptions (matching pen bit positions):
        //   bit 0x02 = L button,  bit 0x04 = R button
        // Middle button: report[9] bit 0x02 — speculative; verify via log.
        if (currentToolCode & 0x000F) == 0x0006 && currentToolCode != 0 {
            let scrollPos = report[16]
            let wheelDelta = Int(Int8(bitPattern: scrollPos &- lastScrollPos))
            lastScrollPos = scrollPos

            onTablet(TabletPoint(
                x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                pressure: 0, maxPressure: spec.maxPressure,
                tiltX: 0, tiltY: 0, rotation: 0.0,
                penButton1: (status & 0x02) != 0,   // L — assumed same as pen btn1 bit
                penButton2: (status & 0x04) != 0,   // R — assumed same as pen btn2 bit
                eraser: false,
                inProximity: true,
                hoverDistance: 0,
                mouseMiddleButton: (report[9] & 0x02) != 0,  // M — speculative; verify via log
                mouseWheelDelta: wheelDelta))
            return
        }

        // ── Pen path ───────────────────────────────────────────────────────────
        let pressure = Int(UInt16(report[8]) | UInt16(report[9]) << 8)
        let tiltX = Double(Int8(bitPattern: report[10])) / 127.0
        let tiltY = Double(Int8(bitPattern: report[11])) / 127.0

        // Rotation (Twist): Bytes 12-13, signed 16-bit, scaled by 10.
        // Only valid for Art Pen (0x0804).
        let isArtPen = (currentToolCode & 0x0FF6) == 0x0804
        let rawRot = Int16(bitPattern: UInt16(report[12]) | UInt16(report[13]) << 8)
        var rotation = isArtPen ? Double(rawRot) / 10.0 : 0.0
        if rotation < 0 { rotation += 360.0 }

        let pt = TabletPoint(
            x: x,
            y: y,
            maxX: spec.maxX,
            maxY: spec.maxY,
            pressure: pressure,
            maxPressure: spec.maxPressure,
            tiltX: tiltX,
            tiltY: tiltY,
            rotation: rotation,
            penButton1: (status & 0x02) != 0,
            penButton2: (status & 0x04) != 0,
            eraser: (status & 0x10) != 0,
            inProximity: true,
            hoverDistance: Int(report[16])
        )
        onTablet(pt)
    }

    /// BLE HOGP pen report (Report ID 0x01, 23 bytes) — Intuos Pro over BLE.
    private func handleBLEPen(report: UnsafePointer<UInt8>, length: CFIndex) {
        guard let result = decodeBLEPenReport(
            report: report, length: length, spec: spec,
            lastX: &lastX, lastY: &lastY
        ) else { return }

        if result.toolCode != 0 && (result.serial != lastSerial || result.toolCode != lastToolCode) {
            lastSerial   = result.serial
            lastToolCode = result.toolCode
            currentToolCode = result.toolCode
            onToolEnter?(ToolIdentity(
                serial: result.serial,
                toolCode: result.toolCode,
                isEraser: result.point.eraser,
                isMouse: result.isMouse))
        }

        onTablet(result.point)
    }

    /// Offset pen report (Report ID 0x1E) — produced when using driver compatibility mode.
    /// All byte offsets shifted by +1 compared to standard report.
    private func handleOffsetPenReport(report: UnsafePointer<UInt8>) {
        guard report.advanced(by: 0).pointee == 0x1E else { return }
        let status = report[2]
        let x = Int(UInt16(report[3]) | UInt16(report[4]) << 8) | (Int(report[5]) << 16)
        let y = Int(UInt16(report[6]) | UInt16(report[7]) << 8) | (Int(report[8]) << 16)
        let pressure = Int(UInt16(report[9]) | UInt16(report[10]) << 8)
        let tiltX = Double(Int8(bitPattern: report[11])) / 127.0
        let tiltY = Double(Int8(bitPattern: report[12])) / 127.0

        onTablet(
            TabletPoint(
                x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                pressure: pressure, maxPressure: spec.maxPressure,
                tiltX: tiltX, tiltY: tiltY, rotation: 0.0,
                penButton1: (status & 0x02) != 0,
                penButton2: (status & 0x04) != 0,
                eraser: (status & 0x10) != 0,
                inProximity: (status & 0x20) != 0,
                hoverDistance: 0
            ))
    }

    /// Auxiliary (express key) report (Report ID 0x11).
    ///
    /// Report layout (9 bytes, same as PTH-660 — confirmed by capture):
    ///   [0]     0x11  report ID
    ///   [1]     mechanical click state — set only when key is pressed hard enough to actuate
    ///   [2]     capacitive touch state — set on lightest finger contact (too sensitive for buttons)
    ///   [3]     touch-ring touch flag (non-zero while finger is on ring)
    ///   [4]     touch-ring position, 0–71 (5° resolution); 0x7F = idle/no contact
    ///   [5-8]   reserved / zero
    ///
    /// Intuos Pro express keys are capacitive-touch with a mechanical click underneath.
    /// Use [1] (click) not [2] (touch) — Wacom's native driver requires a physical click.
    private func handleAuxReport(report: UnsafePointer<UInt8>, length: CFIndex) {
        guard length >= 3, let onAux = onAux else { return }
        // report[1]: bits 0–7 = express keys 1–8 (mechanical click state)
        let auxByte   = report[1]
        let ringByte: UInt8 = length >= 5 ? report[3] : 0
        let posByte:  UInt8 = length >= 5 ? report[4] : 0x7F
        let ringActive = ringByte != 0
        onAux(AuxButtons(buttons: (0..<8).map { bit in (auxByte & (1 << bit)) != 0 },
                         touchRingActive: ringActive,
                         touchRingPosition: ringActive ? posByte : 0x7F))
    }
}
