import Foundation
import IOKit.hid

/// Wacom Intuos 5 Large / Intuos Pro L (PTH-851) — dual-transport driver.
/// VendorID: 0x056A  ProductID: 0x0317
///
/// **USB / RF dongle:** IntuosV1 HID report format, 10-byte reports.
///   Coordinate space: maxX=44704, maxY=27940, maxPressure=1023 (10-bit).
///
/// **Bluetooth Low Energy (HOGP):** 23-byte pen report (ID 0x01), 9-byte
///   pad report (ID 0x03).  13-bit pressure (8191), tilt as sin(angle)/127.
///   macOS pairs via System Settings → Bluetooth; IOHIDManager sees the
///   device with the same PID but transport "BluetoothLowEnergy".
///
/// Transport is auto-detected from which report IDs arrive.
///
/// **Tool-change packets (USB):** status `(& 0xFC) == 0xC0` on proximity enter.
/// **Mouse tools (USB):** subtype 0x06 (KC-100) and 0x08 (2D mouse).
final class PTH851Device: TabletDevice {

    // USB spec — used for IntuosV1 reports.
    // BLE reports carry their own maxPressure (8191) and coordinates that
    // fit within the same maxX/maxY range.
    let spec = DigitizerSpec(maxX: 44704, maxY: 27940, maxPressure: 1023)

    /// BLE pen reports use 13-bit pressure; scale accordingly.
    private static let bleMaxPressure = 8191

    private let device: IOHIDDevice
    private let onTablet: (TabletPoint) -> Void
    private let onAux: ((AuxButtons) -> Void)?
    private let onToolEnter: ((ToolIdentity) -> Void)?
    // Buffer large enough for BLE pen report (23 bytes).
    private var reportBuffer = [UInt8](repeating: 0, count: 64)
    private var lastX = 0
    private var lastY = 0
    private var prevInProximity = false

    // ── Tool identity ─────────────────────────────────────────────────────
    private var currentToolCode: UInt16 = 0
    private var currentSerial: UInt32 = 0
    private var isEraser: Bool = false
    private var toolIsMouse: Bool = false

    /// Tracks whether we've seen BLE-format reports (0x01/0x03).
    /// Once set, USB-format init is skipped and BLE maxPressure is used.
    private var isBLE = false

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
            print("PTH-851: failed to open — \(ret). Is another tablet driver running?")
            return
        }

        // Detect transport.  BLE devices report "BluetoothLowEnergy" or "Bluetooth".
        let transport = IOHIDDeviceGetProperty(
            device, kIOHIDTransportKey as CFString) as? String ?? ""
        isBLE = transport.localizedCaseInsensitiveContains("bluetooth")

        if !isBLE {
            // USB / RF dongle: feature init activates the digitizer endpoint.
            var initBytes: [UInt8] = [0x02, 0x02]
            IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0x02, &initBytes, initBytes.count)
        }

        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count,
            PTH851Device.reportCallback, ctx)
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)

        if isBLE {
            print("PTH-851: connected via Bluetooth LE")
        }
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(
            device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)
        IOHIDDeviceRegisterInputReportCallback(device, &reportBuffer, reportBuffer.count, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: - C callback (must be @convention(c), non-capturing)

    private static let reportCallback: IOHIDReportCallback = {
        ctx, result, sender, type, reportID, report, length in
        guard let ctx = ctx else { return }
        let self_ = Unmanaged<PTH851Device>.fromOpaque(ctx).takeUnretainedValue()
        self_.handleReport(report: report, length: length)
    }

    private func handleReport(report: UnsafePointer<UInt8>, length: CFIndex) {
        guard length >= 2 else { return }

        let id = report[0]

        // ── BLE HOGP pen report (Report ID 0x01, 23 bytes) ────────────────
        if id == 0x01 && length >= 11 {
            handleBLEPen(report: report, length: length)
            return
        }

        // ── BLE HOGP pad report (Report ID 0x03, 9 bytes) ────────────────
        if id == 0x03 && length >= 3 {
            if let aux = decodeBLEPadReport(report: report, length: length) {
                onAux?(aux)
            }
            return
        }

        // ── USB express key report (Report ID 0x11) ──────────────────────
        if id == 0x11 {
            guard let onAux = onAux else { return }
            // PTH-851 (Intuos 5) has purely mechanical express keys.
            let auxByte: UInt8 = length >= 3 ? report[2] : report[1]
            onAux(AuxButtons(buttons: (0..<8).map { bit in (auxByte & (1 << bit)) != 0 }))
            return
        }

        // ── USB pen reports (Report ID 0x02 / 0x10, 10 bytes) ────────────
        guard id == 0x02 || id == 0x10 else { return }
        guard length >= 10 else { return }
        handleUSBPen(report: report, length: length)
    }

    // MARK: - BLE pen report

    private func handleBLEPen(report: UnsafePointer<UInt8>, length: CFIndex) {
        isBLE = true
        let bleSpec = DigitizerSpec(
            maxX: spec.maxX, maxY: spec.maxY, maxPressure: Self.bleMaxPressure)
        guard let result = decodeBLEPenReport(
            report: report, length: length, spec: bleSpec,
            lastX: &lastX, lastY: &lastY
        ) else { return }

        // Fire onToolEnter when tool identity changes.
        if result.serial != currentSerial || result.toolCode != currentToolCode {
            if result.toolCode != 0 {
                currentSerial   = result.serial
                currentToolCode = result.toolCode
                isEraser        = result.point.eraser
                toolIsMouse     = result.isMouse
                onToolEnter?(ToolIdentity(
                    serial: result.serial,
                    toolCode: result.toolCode,
                    isEraser: result.point.eraser,
                    isMouse: result.isMouse))
            }
        }

        onTablet(result.point)
    }

    // MARK: - USB pen report (IntuosV1, 10-byte)

    private func handleUSBPen(report: UnsafePointer<UInt8>, length: CFIndex) {
        let status = report[1]

        // Tool-change packet.
        if (status & 0xFC) == 0xC0 {
            handleToolChange(report: report)
            return
        }

        let inProximity    = (status & 0x20) != 0
        let highConfidence = (status & 0x40) != 0
        let subtype        = (status >> 1) & 0x0F

        // Proximity-out.
        if !inProximity {
            prevInProximity = false
            toolIsMouse = false
            onTablet(TabletPoint(
                x: lastX, y: lastY, maxX: spec.maxX, maxY: spec.maxY,
                pressure: 0, maxPressure: spec.maxPressure,
                tiltX: 0, tiltY: 0, rotation: 0.0,
                penButton1: false, penButton2: false,
                eraser: isEraser, inProximity: false, hoverDistance: 0))
            return
        }

        // Low confidence.
        guard highConfidence else {
            onTablet(TabletPoint(
                x: lastX, y: lastY, maxX: spec.maxX, maxY: spec.maxY,
                pressure: 0, maxPressure: spec.maxPressure,
                tiltX: 0, tiltY: 0, rotation: 0.0,
                penButton1: !toolIsMouse && (status & 0x02) != 0,
                penButton2: !toolIsMouse && (status & 0x04) != 0,
                eraser: isEraser, inProximity: true, hoverDistance: 0))
            return
        }

        // Announce tool type on proximity entry (fallback).
        if !prevInProximity {
            let isMouse = subtype == 0x06 || subtype == 0x08
            toolIsMouse = isMouse
            if currentToolCode == 0 {
                let fallbackCode: UInt16 = isMouse
                    ? (subtype == 0x06 ? 0x0806 : 0x0016)
                    : (isEraser ? 0x080A : 0x0802)
                onToolEnter?(ToolIdentity(
                    serial: 0, toolCode: fallbackCode,
                    isEraser: isEraser, isMouse: isMouse))
            }
        }
        prevInProximity = true

        // Coordinate decode.
        let x = ((Int(report[3]) | Int(report[2]) << 8) << 1) | ((Int(report[9]) >> 1) & 1)
        let y = ((Int(report[5]) | Int(report[4]) << 8) << 1) | (Int(report[9]) & 1)
        lastX = x
        lastY = y

        // Mouse subtype 0x06 (KC-100).
        if subtype == 0x06 {
            let buttons    = report[6]
            let whlByte    = report[7]
            let wheelDelta = Int((whlByte & 0x80) >> 7) - Int((whlByte & 0x40) >> 6)
            onTablet(TabletPoint(
                x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                pressure: 0, maxPressure: spec.maxPressure,
                tiltX: 0, tiltY: 0, rotation: 0.0,
                penButton1: (buttons & 0x01) != 0,
                penButton2: (buttons & 0x04) != 0,
                eraser: false, inProximity: true, hoverDistance: 0,
                mouseMiddleButton: (buttons & 0x02) != 0,
                mouseWheelDelta: wheelDelta))
            return
        }

        // Mouse subtype 0x08 (2D mouse).
        if subtype == 0x08 {
            let btnByte    = report[8]
            let wheelDelta = Int(btnByte & 0x01) - Int((btnByte & 0x02) >> 1)
            onTablet(TabletPoint(
                x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                pressure: 0, maxPressure: spec.maxPressure,
                tiltX: 0, tiltY: 0, rotation: 0.0,
                penButton1: (btnByte & 0x04) != 0,
                penButton2: (btnByte & 0x10) != 0,
                eraser: false, inProximity: true, hoverDistance: 0,
                mouseMiddleButton: (btnByte & 0x08) != 0,
                mouseWheelDelta: wheelDelta))
            return
        }

        // Pen path.
        let pressure = (Int(report[6]) << 3) | ((Int(report[7] & 0xC0)) >> 5) | (Int(report[1]) & 1)
        let tiltXRaw = (((Int(report[7]) << 1) & 0x7E) | (Int(report[8]) >> 7)) - 64
        let tiltYRaw = (Int(report[8]) & 0x7F) - 64

        onTablet(TabletPoint(
            x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
            pressure: pressure, maxPressure: spec.maxPressure,
            tiltX: Double(tiltXRaw) / 63.0,
            tiltY: Double(tiltYRaw) / 63.0,
            rotation: 0.0,
            penButton1: (status & 0x02) != 0,
            penButton2: (status & 0x04) != 0,
            eraser: isEraser,
            inProximity: true,
            hoverDistance: Int(report[9])))
    }

    // MARK: - Tool-change packet (IntuosV1, status bits 7:2 == 0xC0)

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
        isEraser    = (toolCode & 0x000F) == 0x000A
        toolIsMouse = (toolCode & 0x000F) == 0x0006

        onToolEnter?(ToolIdentity(
            serial: serial, toolCode: toolCode,
            isEraser: isEraser, isMouse: toolIsMouse))
    }
}
