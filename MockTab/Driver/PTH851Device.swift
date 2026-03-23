import Foundation
import IOKit.hid

/// Wacom Intuos 5 Large (PTH-851) — IntuosV1 HID report format.
/// VendorID: 0x056A  ProductID: 0x0317  InputReportLength: 10 bytes
final class PTH851Device: TabletDevice {

    let spec = DigitizerSpec(maxX: 44704, maxY: 27940, maxPressure: 1023)

    private let device: IOHIDDevice
    private let onTablet: (TabletPoint) -> Void
    private let onAux: ((AuxButtons) -> Void)?
    // Report buffer — IOKit writes into this on each report callback.
    private var reportBuffer = [UInt8](repeating: 0, count: 10)
    private var lastX = 0
    private var lastY = 0
    private var prevInProximity = false

    init(device: IOHIDDevice,
         onTablet: @escaping (TabletPoint) -> Void,
         onAux: ((AuxButtons) -> Void)? = nil)
    {
        self.device = device
        self.onTablet = onTablet
        self.onAux = onAux
    }

    func open() {
        let ret = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard ret == kIOReturnSuccess else {
            print("PTH-851: failed to open — \(ret). Is another tablet driver running?")
            return
        }

        // Feature init: [0x02, 0x02] — activates the digitizer endpoint.
        var initBytes: [UInt8] = [0x02, 0x02]
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0x02, &initBytes, initBytes.count)

        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, &reportBuffer, reportBuffer.count,
                                              PTH851Device.reportCallback, ctx)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)
        IOHIDDeviceRegisterInputReportCallback(device, &reportBuffer, reportBuffer.count, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: - C callback (must be @convention(c), non-capturing)

    private static let reportCallback: IOHIDReportCallback = { ctx, result, sender, type, reportID, report, length in
        guard let ctx = ctx else { return }
        let self_ = Unmanaged<PTH851Device>.fromOpaque(ctx).takeUnretainedValue()
        self_.handleReport(report: report, length: length)
    }

    private func handleReport(report: UnsafePointer<UInt8>, length: CFIndex) {
        guard length >= 2 else { return }

        let id = report[0]

        // Express key report.
        if id == 0x11 {
            guard let onAux = onAux else { return }
            // PTH-851 report layout not yet captured; assuming same as PTH-660/860:
            // [1] = latch, [2] = current key state.  Use [2] if present, else [1].
            let auxByte: UInt8 = length >= 3 ? report[2] : report[1]
            onAux(AuxButtons(buttons: (0..<8).map { bit in (auxByte & (1 << bit)) != 0 }))
            return
        }

        guard id == 0x02 || id == 0x10 else {
            // Phase 1 serial probe: log any report ID we don't recognise.
            let hex = (0..<Swift.min(Int(length), 20))
                .map { String(format: "%02X", report[$0]) }.joined(separator: " ")
            print("PTH-851 UNKNOWN REPORT id=\(String(format:"0x%02X", id)) len=\(length): \(hex)")
            return
        }

        guard length >= 10 else { return }

        let status = report[1]
        let inProximity = (status & 0x20) != 0  // bit 5
        let highConfidence = (status & 0x40) != 0  // bit 6

        // Proximity-out packet — report lift but no coordinates.
        if !inProximity {
            prevInProximity = false
            let pt = TabletPoint(x: 0, y: 0, maxX: spec.maxX, maxY: spec.maxY,
                                 pressure: 0, maxPressure: spec.maxPressure,
                                 tiltX: 0, tiltY: 0,
                                 penButton1: false, penButton2: false,
                                 eraser: false, inProximity: false, hoverDistance: 0)
            onTablet(pt)
            return
        }
        // When confidence is low the position data is unreliable, but we still need to emit a
        // zero-pressure report so InputInjector can fire mouseUp and release any held button.
        // NOTE: keep actual barrel-button bits from status — highConfidence is a position-quality
        // flag, independent of whether a barrel button is physically held.
        guard highConfidence else {
            let pt = TabletPoint(x: lastX, y: lastY, maxX: spec.maxX, maxY: spec.maxY,
                                 pressure: 0, maxPressure: spec.maxPressure,
                                 tiltX: 0, tiltY: 0,
                                 penButton1: (status & 0x02) != 0,
                                 penButton2: (status & 0x04) != 0,
                                 eraser: false, inProximity: true, hoverDistance: 0)
            onTablet(pt)
            return
        }

        // Phase 1 serial probe: log all 10 bytes on proximity-enter transition.
        // IntuosV1 may carry tool type/serial in the first in-proximity report.
        if !prevInProximity {
            let hex = (0..<10).map { String(format: "%02X", report[$0]) }.joined(separator: " ")
            print("PTH-851 PROXIMITY-ENTER: \(hex)")
        }
        prevInProximity = true

        // IntuosV1TabletReport field decoding (see OpenTabletDriver IntuosV1TabletReport.cs)
        let x = ((Int(report[3]) | Int(report[2]) << 8) << 1) | ((Int(report[9]) >> 1) & 1)
        let y = ((Int(report[5]) | Int(report[4]) << 8) << 1) | (Int(report[9]) & 1)
        let pressure = (Int(report[6]) << 3) | ((Int(report[7] & 0xC0)) >> 5) | (Int(report[1]) & 1)
        let tiltXRaw = (((Int(report[7]) << 1) & 0x7E) | (Int(report[8]) >> 7)) - 64
        let tiltYRaw = (Int(report[8]) & 0x7F) - 64

        lastX = x
        lastY = y

        let pt = TabletPoint(
            x: x,
            y: y,
            maxX: spec.maxX,
            maxY: spec.maxY,
            pressure: pressure,
            maxPressure: spec.maxPressure,
            tiltX: Double(tiltXRaw) / 63.0,
            tiltY: Double(tiltYRaw) / 63.0,
            penButton1: (status & 0x02) != 0,
            penButton2: (status & 0x04) != 0,
            eraser: false,  // IntuosV1 doesn't expose eraser in this report type
            inProximity: true,
            hoverDistance: Int(report[9])
        )
        onTablet(pt)
    }
}
