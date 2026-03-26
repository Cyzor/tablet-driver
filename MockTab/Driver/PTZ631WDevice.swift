import Foundation
import IOKit.hid

/// Wacom PTZ-631W (Intuos3 Widescreen 6x8) — IntuosV1 HID report format.
/// VendorID: 0x056A  ProductID: 0x00B5  InputReportLength: 10 bytes
///
/// Coordinate space: maxX=54204, maxY=31750, maxPressure=2046 (11-bit).
///
/// **Tool-change packets:** status 0xC2 on proximity enter.
///   Bytes 2–7 carry packed serial number and tool code per IntuosV1 protocol.
///   Eraser detection: lower nibble of toolCode == 0x0A.
///
/// **Express keys:** Report ID 0x03 (IntuosV1 style, 8 keys in byte 4)
///   and 0x0C (Intuos3 style, 4+4 keys in bytes 5–6).
final class PTZ631WDevice: TabletDevice {

    let spec = DigitizerSpec(maxX: 54204, maxY: 31750, maxPressure: 2046)

    private let device: IOHIDDevice
    private let onTablet: (TabletPoint) -> Void
    private let onAux: ((AuxButtons) -> Void)?
    private let onToolEnter: ((ToolIdentity) -> Void)?
    private var reportBuffer = [UInt8](repeating: 0, count: 10)
    private var lastX = 0
    private var lastY = 0
    private var prevInProximity = false

    // ── Tool identity ─────────────────────────────────────────────────────
    private var currentSerial: UInt32 = 0
    private var currentToolCode: UInt16 = 0
    private var isEraser: Bool = false
    private var toolIsMouse: Bool = false

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
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count,
            PTZ631WDevice.reportCallback, ctx)
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(
            device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)
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
        guard length >= 2 else { return }

        let id = report[0]

        // Aux button report — IntuosV1 style: 8 keys packed in byte 4.
        if id == 0x03 {
            guard length >= 10 else { return }
            if let onAux {
                let byte = report[4]
                onAux(AuxButtons(buttons: (0..<8).map { (byte & (1 << $0)) != 0 }))
            }
            return
        }

        // Aux button report — Intuos3 style: 4 keys in byte 5, 4 keys in byte 6.
        if id == 0x0C {
            guard length >= 7 else { return }
            if let onAux {
                let lo = report[5]
                let hi = report[6]
                let buttons =
                    (0..<4).map { (lo & (1 << $0)) != 0 }
                    + (0..<4).map { (hi & (1 << $0)) != 0 }
                onAux(AuxButtons(buttons: buttons))
            }
            return
        }

        // Pen reports: direct tablet report (0x10) or dispatch wrapper (0x02).
        guard id == 0x02 || id == 0x10 else { return }
        guard length >= 10 else { return }

        let status = report[1]

        // ── Tool-change packet: status bits 7:2 == 0b110000 (enter prox) ──
        // IntuosV1 protocol: carries serial number + tool code.
        // Bit 5 (inProximity) is clear, so without this check it would be
        // mishandled as a proximity-out.
        if (status & 0xFC) == 0xC0 {
            handleToolChange(report: report)
            return
        }

        // Skip mouse sub-type reports (0xF0/0xB0) — not yet decoded.
        if id == 0x02 {
            let hi = status & 0xF0
            if hi == 0xF0 || hi == 0xB0 { return }
        }

        // Bit 6 of status = nearProximity. On lift it goes low; emit zero-pressure so
        // InputInjector fires mouseUp and releases any held button.
        let inProximity = (status & 0x40) != 0
        guard inProximity else {
            prevInProximity = false
            onTablet(
                TabletPoint(
                    x: lastX, y: lastY, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: 0, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,
                    penButton1: false, penButton2: false,
                    eraser: isEraser, inProximity: false, hoverDistance: 0))
            return
        }

        // Announce tool on proximity entry if no tool-change packet was seen.
        if !prevInProximity && currentToolCode == 0 {
            onToolEnter?(ToolIdentity(
                serial: 0,
                toolCode: isEraser ? 0x080A : 0x0802,
                isEraser: isEraser,
                isMouse: false))
        }
        prevInProximity = true

        // IntuosV1 coordinate decode.
        let x = ((Int(report[2]) << 8 | Int(report[3])) << 1) | ((Int(report[9]) >> 1) & 1)
        let y = ((Int(report[4]) << 8 | Int(report[5])) << 1) | (Int(report[9]) & 1)
        lastX = x
        lastY = y

        let pressure = (Int(report[6]) << 3) | ((Int(report[7]) & 0xC0) >> 5) | (Int(status) & 1)
        let tiltXRaw = (((Int(report[7]) << 1) & 0x7E) | (Int(report[8]) >> 7)) - 64
        let tiltYRaw = (Int(report[8]) & 0x7F) - 64

        onTablet(
            TabletPoint(
                x: x,
                y: y,
                maxX: spec.maxX,
                maxY: spec.maxY,
                pressure: pressure,
                maxPressure: spec.maxPressure,
                tiltX: Double(tiltXRaw) / 63.0,
                tiltY: Double(tiltYRaw) / 63.0,
                rotation: 0.0,
                penButton1: (status & 0x02) != 0,
                penButton2: (status & 0x04) != 0,
                eraser: isEraser,
                inProximity: true,
                hoverDistance: Int(report[9])
            ))
    }

    // MARK: - Tool-change packet (status bits 7:2 == 0xC0)

    private func handleToolChange(report: UnsafePointer<UInt8>) {
        // IntuosV1 tool-enter packet: serial and tool code packed in bytes 2–8.
        // Linux wacom_wac.c wacom_intuos_inout():
        //   serial = ((data[3]&0x0f)<<28) | (data[4]<<20) | (data[5]<<12) | (data[6]<<4) | (data[7]>>4)
        //   toolId = (data[2]<<4) | (data[3]>>4) | ((data[7]&0x0f)<<16) | ((data[8]&0xf0)<<8)
        guard reportBuffer.count >= 9 else { return }
        let toolCode = UInt16(report[2]) << 4 | UInt16(report[3]) >> 4
        let serial =
            (UInt32(report[3] & 0x0F) << 28)
            | (UInt32(report[4]) << 20)
            | (UInt32(report[5]) << 12)
            | (UInt32(report[6]) << 4)
            | (UInt32(report[7]) >> 4)

        currentSerial   = serial
        currentToolCode = toolCode
        // Eraser: lower nibble 0x00A pattern (standard Wacom eraser codes).
        isEraser = (toolCode & 0x000F) == 0x000A
        // Mouse/cursor tools: lower nibble 0x006 pattern.
        toolIsMouse = (toolCode & 0x000F) == 0x0006

        onToolEnter?(
            ToolIdentity(
                serial: serial,
                toolCode: toolCode,
                isEraser: isEraser,
                isMouse: toolIsMouse))
    }
}
