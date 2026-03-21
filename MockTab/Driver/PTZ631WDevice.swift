import Foundation
import IOKit.hid

/// Wacom PTZ-631W (Intuos3 Widescreen 6x8) — IntuosV1 HID report format.
/// VendorID: 0x056A  ProductID: 0x00B5  InputReportLength: 10 bytes
final class PTZ631WDevice: TabletDevice {

    let spec = DigitizerSpec(maxX: 54204, maxY: 31750, maxPressure: 2046)

    private let device: IOHIDDevice
    private let onTablet: (TabletPoint) -> Void
    private let onAux: ((AuxButtons) -> Void)?
    private var reportBuffer = [UInt8](repeating: 0, count: 10)

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
            print("PTZ-631W: failed to open — \(ret). Is another tablet driver running?")
            return
        }

        // Feature init: [0x02, 0x02] activates the digitizer; [0x04, 0x00] follows after 150 ms.
        var init1: [UInt8] = [0x02, 0x02]
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0x02, &init1, init1.count)
        let dev = device
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            var init2: [UInt8] = [0x04, 0x00]
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 0x04, &init2, init2.count)
        }

        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, &reportBuffer, reportBuffer.count,
                                              PTZ631WDevice.reportCallback, ctx)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)
        IOHIDDeviceRegisterInputReportCallback(device, &reportBuffer, reportBuffer.count, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: - C callback (must be @convention(c), non-capturing)

    private static let reportCallback: IOHIDReportCallback = { ctx, _, _, _, _, report, length in
        guard let ctx = ctx else { return }
        let self_ = Unmanaged<PTZ631WDevice>.fromOpaque(ctx).takeUnretainedValue()
        self_.handleReport(report: report, length: length)
    }

    private func handleReport(report: UnsafePointer<UInt8>, length: CFIndex) {
        guard length >= 10 else { return }

        let id = report[0]

        // Aux button report — IntuosV1 style: 8 keys packed in byte 4.
        if id == 0x03 {
            if let onAux {
                let byte = report[4]
                onAux(AuxButtons(buttons: (0..<8).map { (byte & (1 << $0)) != 0 }))
            }
            return
        }

        // Aux button report — Intuos3 style: 4 keys in byte 5, 4 keys in byte 6.
        if id == 0x0C {
            if let onAux {
                let lo = report[5], hi = report[6]
                let buttons = (0..<4).map { (lo & (1 << $0)) != 0 }
                           + (0..<4).map { (hi & (1 << $0)) != 0 }
                onAux(AuxButtons(buttons: buttons))
            }
            return
        }

        // Pen reports: direct tablet report (0x10) or dispatch wrapper (0x02).
        guard id == 0x02 || id == 0x10 else { return }

        // For 0x02 reports, skip tool-change (0xC2) and mouse (0xF0/0xB0) sub-types.
        let status = report[1]
        if id == 0x02 {
            let hi = status & 0xF0
            if status == 0xC2 || hi == 0xF0 || hi == 0xB0 { return }
        }

        // Bit 6 of status = nearProximity. On lift it goes low; emit zero-pressure so
        // InputInjector fires mouseUp and releases any held button.
        let inProximity = (status & 0x40) != 0
        guard inProximity else {
            onTablet(TabletPoint(x: 0, y: 0, maxX: spec.maxX, maxY: spec.maxY,
                                 pressure: 0, maxPressure: spec.maxPressure,
                                 tiltX: 0, tiltY: 0,
                                 penButton1: false, penButton2: false,
                                 eraser: false, inProximity: false, hoverDistance: 0))
            return
        }

        // IntuosV1TabletReport field decoding (matches OpenTabletDriver IntuosV1TabletReport).
        let x        = ((Int(report[2]) << 8 | Int(report[3])) << 1) | ((Int(report[9]) >> 1) & 1)
        let y        = ((Int(report[4]) << 8 | Int(report[5])) << 1) |  (Int(report[9]) & 1)
        let pressure = (Int(report[6]) << 3) | ((Int(report[7]) & 0xC0) >> 5) | (Int(status) & 1)
        let tiltXRaw = (((Int(report[7]) << 1) & 0x7E) | (Int(report[8]) >> 7)) - 64
        let tiltYRaw =   (Int(report[8]) & 0x7F) - 64

        onTablet(TabletPoint(
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
            eraser: false,
            inProximity: true,
            hoverDistance: Int(report[9])
        ))
    }
}
