import Foundation
import IOKit.hid

/// Wacom Intuos Pro Medium (PTH-850) — IntuosV1 HID report format.
/// VendorID: 0x056A  ProductID: 0x0028
///
/// Two HID interfaces:
///   • Digitizer interface (the one we open): Reports 2 & 3 = 10 bytes (IntuosV1, identical to PTH-851)
///   • Vendor interface (separate): Report 2 = 64 bytes (aux keys + touch ring — handled elsewhere if needed)
///
/// No per-pen serial, no rotation, no 27-byte fields like the V2 models (PTH-660/860).
final class PTH850Device: TabletDevice {

    let spec = DigitizerSpec(maxX: 44800, maxY: 29600, maxPressure: 8191)

    private let device: IOHIDDevice
    private let onTablet: (TabletPoint) -> Void
    private let onAux: ((AuxButtons) -> Void)?
    private let onToolEnter: ((ToolIdentity) -> Void)?

    private var reportBuffer = [UInt8](repeating: 0, count: 10)
    private var lastX = 0
    private var lastY = 0

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
            print("PTH-850: failed to open — \(ret). Is another tablet driver running?")
            return
        }

        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count,
            PTH850Device.reportCallback, ctx)
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
        let self_ = Unmanaged<PTH850Device>.fromOpaque(ctx).takeUnretainedValue()
        self_.handleReport(report: report, length: length)
    }

    private func handleReport(report: UnsafePointer<UInt8>, length: CFIndex) {
        guard length >= 10 else { return }

        switch report[0] {
        case 2, 3:          // Both report IDs are used on the digitizer interface
            handlePenReport(report: report, length: length)
        default:
            break            // Vendor interface (64-byte reports) is on a separate HID device
        }
    }

    /// IntuosV1 10-byte pen report (Report ID 2 or 3)
    private func handlePenReport(report: UnsafePointer<UInt8>, length: CFIndex) {
        let status = report[1]

        let x = Int(UInt16(report[2]) | UInt16(report[3]) << 8)
        let y = Int(UInt16(report[4]) | UInt16(report[5]) << 8)
        let pressure = Int(UInt16(report[6]) | UInt16(report[7]) << 8)
        let tiltX = Double(Int8(bitPattern: report[8])) / 127.0
        let tiltY = Double(Int8(bitPattern: report[9])) / 127.0

        // Out-of-proximity lift (same pattern as your V2 code)
        if x == 0 && y == 0 && pressure == 0 {
            let liftPt = TabletPoint(
                x: 0, y: 0, maxX: spec.maxX, maxY: spec.maxY,
                pressure: 0, maxPressure: spec.maxPressure,
                tiltX: 0, tiltY: 0, rotation: 0.0,
                penButton1: false, penButton2: false,
                eraser: false, inProximity: false, hoverDistance: 0)
            onTablet(liftPt)
            return
        }

        lastX = x
        lastY = y

        let pt = TabletPoint(
            x: x,
            y: y,
            maxX: spec.maxX,
            maxY: spec.maxY,
            pressure: pressure,
            maxPressure: spec.maxPressure,
            tiltX: tiltX,
            tiltY: tiltY,
            rotation: 0.0,                    // V1 has no rotation (Art Pen support added in V2)
            penButton1: (status & 0x02) != 0,
            penButton2: (status & 0x04) != 0,
            eraser:     (status & 0x10) != 0, // same bit as PTH-860
            inProximity: true,
            hoverDistance: 0
        )
        onTablet(pt)
    }
}