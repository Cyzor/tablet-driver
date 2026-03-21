import Foundation
import IOKit.hid

/// Wacom Cintiq 24HD (DTK-2400) — IntuosV1 HID report format.
/// VendorID: 0x056A  ProductID: 0x00F4  InputReportLength: 10 bytes
///
/// Coordinate space confirmed by live probe (WacomProbeDevice):
///   maxX = 104480  (pen reached 104253 at right bezel; Linux input-wacom: 104480)
///   maxY =  65600  (clean firmware plateau)
///   maxPressure = 2047  (11-bit field, same formula as PTH-851)
///
/// The Cintiq 24HD is a pen display: its active area covers the full
/// 1920 × 1200 screen surface, so the default active-area mapping should
/// span the whole coordinate space and target the Cintiq's own display.
final class DTK2400Device: TabletDevice {

    let spec = DigitizerSpec(maxX: 104480, maxY: 65600, maxPressure: 2047)

    private let device: IOHIDDevice
    private let onTablet: (TabletPoint) -> Void
    private let onAux: ((AuxButtons) -> Void)?
    private var reportBuffer = [UInt8](repeating: 0, count: 10)
    private var lastX = 0
    private var lastY = 0

    init(device: IOHIDDevice,
         onTablet: @escaping (TabletPoint) -> Void,
         onAux: ((AuxButtons) -> Void)? = nil)
    {
        self.device = device
        self.onTablet = onTablet
        self.onAux = onAux
    }

    func open() {
        // Seize the device so macOS's built-in IOHIDEventDriver stops processing it.
        // The Cintiq 24HD descriptor includes a mouse-compatible collection (Report ID 1,
        // tip-switch → left button).  Without seizure the system fires spurious left-click
        // CGEvents from the pen's tip-switch independently of our pressure logic, causing
        // rapid phantom clicks whenever the pen is near the surface.
        // kIOHIDOptionsTypeSeizeDevice also prevents a second DTK2400Device from being
        // created if the OS exposes two IOHIDDevice entries for the same interface.
        let ret = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard ret == kIOReturnSuccess else {
            print("DTK-2400: failed to seize device (\(ret)). Is another tablet driver running?")
            return
        }

        // Feature init: [0x02, 0x02] — activates the digitiser endpoint.
        // Identical to PTH-851; confirmed working by probe session.
        var initBytes: [UInt8] = [0x02, 0x02]
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0x02, &initBytes, initBytes.count)

        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, &reportBuffer, reportBuffer.count,
                                              DTK2400Device.reportCallback, ctx)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(),
                                       RunLoop.Mode.common.rawValue as CFString)
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(),
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
        guard length >= 10 else { return }

        // Report IDs seen on this device: 0x02 (pen), 0x0C (touch/ring — ignored here).
        let id = report[0]
        guard id == 0x02 || id == 0x10 else { return }

        let status      = report[1]
        let inProximity = (status & 0x20) != 0  // bit 5
        let highConf    = (status & 0x40) != 0  // bit 6

        if !inProximity {
            onTablet(TabletPoint(x: 0, y: 0, maxX: spec.maxX, maxY: spec.maxY,
                                 pressure: 0, maxPressure: spec.maxPressure,
                                 tiltX: 0, tiltY: 0,
                                 penButton1: false, penButton2: false,
                                 eraser: false, inProximity: false, hoverDistance: 0))
            return
        }
        // Low-confidence: position unreliable but emit zero-pressure so mouseUp fires.
        guard highConf else {
            onTablet(TabletPoint(x: lastX, y: lastY, maxX: spec.maxX, maxY: spec.maxY,
                                 pressure: 0, maxPressure: spec.maxPressure,
                                 tiltX: 0, tiltY: 0,
                                 penButton1: false, penButton2: false,
                                 eraser: false, inProximity: true, hoverDistance: 0))
            return
        }

        // IntuosV1 coordinate / pressure / tilt decode — identical to PTH851Device.
        let x        = ((Int(report[3]) | Int(report[2]) << 8) << 1) | ((Int(report[9]) >> 1) & 1)
        let y        = ((Int(report[5]) | Int(report[4]) << 8) << 1) | (Int(report[9]) & 1)
        let pressure = (Int(report[6]) << 3) | ((Int(report[7] & 0xC0)) >> 5) | (Int(report[1]) & 1)
        let tiltXRaw = (((Int(report[7]) << 1) & 0x7E) | (Int(report[8]) >> 7)) - 64
        let tiltYRaw = (Int(report[8]) & 0x7F) - 64

        lastX = x
        lastY = y

        onTablet(TabletPoint(
            x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
            pressure: pressure, maxPressure: spec.maxPressure,
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
