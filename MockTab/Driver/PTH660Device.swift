import Foundation
import IOKit.hid

/// Wacom Intuos Pro M (PTH-660) — IntuosV2 HID report format.
/// VendorID: 0x056A  ProductID: 0x0357  InputReportLength: 192 bytes
/// Digitizer surface: 44800 × 29600 lp (224 × 148 mm), 13-bit pressure.
///
/// Serial number layout (verified by live capture, 27-byte 0x10 reports):
///   Bytes 17–20: pen serial (32-bit LE) — unique per physical pen body
///   Bytes 21–22: tool code (16-bit LE) — e.g. 0x0802, 0x0842
///   Bytes 25–26: tool code repeated
final class PTH660Device: TabletDevice {

    let spec = DigitizerSpec(maxX: 44800, maxY: 29600, maxPressure: 8191)

    private let device: IOHIDDevice
    private let onTablet: (TabletPoint) -> Void
    private let onAux: ((AuxButtons) -> Void)?
    private let onToolEnter: ((ToolIdentity) -> Void)?
    private var reportBuffer = [UInt8](repeating: 0, count: 192)
    private var lastX = 0
    private var lastY = 0
    private var lastSerial: UInt32 = 0

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
            print("PTH-660: failed to open — \(ret). Is another tablet driver running?")
            return
        }
        // PTH-660 needs no feature init report (same as PTH-860).
        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count,
            PTH660Device.reportCallback, ctx)
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

    private static let reportCallback: IOHIDReportCallback = { ctx, _, _, _, _, report, length in
        guard let ctx = ctx else { return }
        let self_ = Unmanaged<PTH660Device>.fromOpaque(ctx).takeUnretainedValue()
        self_.handleReport(report: report, length: length)
    }

    private func handleReport(report: UnsafePointer<UInt8>, length: CFIndex) {
        guard length >= 2 else { return }
        switch report[0] {
        case 0x10:
            guard length >= 12 else { return }
            handlePenReport(report: report, length: length)
        case 0x1E: handleOffsetPenReport(report: report)
        case 0x11: handleAuxReport(report: report, length: length)
        case 0x13: break  // touch-ring mode / position — not yet handled
        default: break
        }
    }

    /// Standard pen report (Report ID 0x10) — IntuosV2Report layout.
    private func handlePenReport(report: UnsafePointer<UInt8>, length: CFIndex) {
        let status = report[1]
        let highConfidence = (status & 0x20) != 0

        let allZero =
            report[2] == 0 && report[3] == 0 && report[4] == 0
            && report[5] == 0 && report[6] == 0 && report[7] == 0
        if allZero && !highConfidence {
            onTablet(
                TabletPoint(
                    x: 0, y: 0, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: 0, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,
                    penButton1: false, penButton2: false,
                    eraser: false, inProximity: false, hoverDistance: 0))
            return
        }

        // NOTE: keep barrel-button and eraser bits from status — highConfidence is a
        // position-quality flag independent of which physical buttons are held.
        guard highConfidence else {
            onTablet(
                TabletPoint(
                    x: lastX, y: lastY, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: 0, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,
                    penButton1: (status & 0x02) != 0,
                    penButton2: (status & 0x04) != 0,
                    eraser: (status & 0x10) != 0,
                    inProximity: true, hoverDistance: 0))
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
            if serial != 0 && serial != lastSerial {
                lastSerial = serial
                onToolEnter?(
                    ToolIdentity(
                        serial: serial,
                        toolCode: toolCode,
                        isEraser: (toolCode & 0x0008) != 0))
            }
        }

        let x = Int(UInt16(report[2]) | UInt16(report[3]) << 8) | (Int(report[4]) << 16)
        let y = Int(UInt16(report[5]) | UInt16(report[6]) << 8) | (Int(report[7]) << 16)
        let pressure = Int(UInt16(report[8]) | UInt16(report[9]) << 8)
        let tiltX = Double(Int8(bitPattern: report[10])) / 127.0
        let tiltY = Double(Int8(bitPattern: report[11])) / 127.0
        let rotation = Double(UInt16(report[12]) | UInt16(report[13]) << 8) / 10.0

        lastX = x
        lastY = y

        onTablet(
            TabletPoint(
                x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                pressure: pressure, maxPressure: spec.maxPressure,
                tiltX: tiltX, tiltY: tiltY,
                rotation: rotation,
                penButton1: (status & 0x02) != 0,
                penButton2: (status & 0x04) != 0,
                eraser: (status & 0x10) != 0,
                inProximity: true,
                hoverDistance: Int(report[16])
            ))
    }

    /// Offset pen report (Report ID 0x1E) — produced in driver-compatibility mode.
    private func handleOffsetPenReport(report: UnsafePointer<UInt8>) {
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
    /// Report layout (9 bytes, confirmed by capture):
    ///   [0]     0x11  report ID
    ///   [1]     latch — momentarily equals [2] during a held key; unreliable for edge detection
    ///   [2]     current button state — set for the full duration the key is held  ← use this
    ///   [3]     touch-ring touch flag
    ///   [4]     touch-ring position (0x7F = idle/center)
    ///   [5-8]   reserved / zero
    private func handleAuxReport(report: UnsafePointer<UInt8>, length: CFIndex) {
        guard length >= 3, let onAux = onAux else { return }
        // report[2] is the live "key currently held" bitmask (bits 0–7 = keys 1–8).
        let auxByte = report[2]
        onAux(AuxButtons(buttons: (0..<8).map { bit in (auxByte & (1 << bit)) != 0 }))
    }
}
