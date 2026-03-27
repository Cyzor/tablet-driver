import Foundation
import IOKit.hid

/// Digitizer dimensions in device units for a given tablet model.
struct DigitizerSpec {
    var maxX: Int
    var maxY: Int
    var maxPressure: Int
}

protocol TabletDevice: AnyObject {
    var spec: DigitizerSpec { get }
    func open()
    func close()
}

// Convenience: read an integer property from an IOHIDDevice.
func hidIntProperty(_ device: IOHIDDevice, _ key: String) -> Int {
    guard let val = IOHIDDeviceGetProperty(device, key as CFString) else { return 0 }
    return (val as? NSNumber)?.intValue ?? 0
}

/// Sends the HID Digitizer Input Mode feature report to switch the device into
/// full tablet mode, unlocking cursor/mouse tool button state in pen reports.
///
/// Searches the device's elements for Usage Page 0x0D (Digitizer) / Usage 0x29
/// (Input Mode), reads its report ID, and sends [reportID, 2].  Call once per
/// interface immediately after a successful IOHIDDeviceOpen.
///
/// No-op when the element is not present on this interface (safe to call on both
/// interfaces of a PTH-660/860 — the vendor interface simply has no match).
func sendWacomInputModeInit(_ device: IOHIDDevice, tag: String) {
    // Match on the standard HID Digitizer Input Mode usage.
    let match: [String: Any] = ["UsagePage": 0x0D, "Usage": 0x29]
    guard
        let cfArr = IOHIDDeviceCopyMatchingElements(device, match as CFDictionary, 0),
        CFArrayGetCount(cfArr) > 0,
        let rawPtr = CFArrayGetValueAtIndex(cfArr, 0)
    else {
        print("\(tag): no InputMode element on this interface — skipping init")
        return
    }
    // CFArrayGetValueAtIndex returns an unretained IOHIDElement reference.
    let elem = Unmanaged<IOHIDElement>.fromOpaque(rawPtr).takeUnretainedValue()
    let reportID   = IOHIDElementGetReportID(elem)
    let reportBits = IOHIDElementGetReportSize(elem) * IOHIDElementGetReportCount(elem)
    print("\(tag): InputMode element found — reportID=\(reportID) size=\(reportBits) bits (\((reportBits + 7) / 8) bytes payload)")

    // Use IOHIDDeviceSetValue rather than IOHIDDeviceSetReport with a raw byte array.
    // IOHIDDeviceSetReport([reportID, 2]) only sends 2 bytes; if the feature report is
    // longer the device discards it.  IOHIDDeviceSetValue lets IOHIDKit build the
    // correctly-sized report from the element descriptor (handles byte offset + padding).
    let value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, elem, 0, 2)
    let ret = IOHIDDeviceSetValue(device, elem, value)
    if ret == kIOReturnSuccess {
        print("\(tag): InputMode init OK (reportID=\(reportID))")
    } else {
        print("\(tag): InputMode init FAILED (0x\(String(ret, radix: 16, uppercase: true)))")
    }
}

// MARK: - BLE HOGP Report Decoders

/// Decode a BLE HOGP pen report (Report ID 0x01, 23 bytes) common to all
/// Intuos Pro models (PTH-451/651/851, PTH-660/860) when connected via
/// Bluetooth Low Energy.
///
/// Layout (from Wacom-Wireless-Specification-Notes.md §4.5):
///   [0]     0x01 Report ID
///   [1]     bits 0–3 = tool index; bit 4 = tip switch; bit 5 = barrel 1;
///           bit 6 = barrel 2; bit 7 = proximity
///   [2–3]   X  (LE uint16)
///   [4–5]   Y  (LE uint16)
///   [6–7]   Pressure (LE uint16, 0–8191)
///   [8]     Distance (uint8, 0–63)
///   [9]     Tilt X (signed int8, −127..+127 = sin(angle))
///   [10]    Tilt Y (signed int8)
///   [11–14] Tool serial (LE uint32)
///   [15–16] Tool ID (LE uint16)
///   [17–22] Reserved
///
/// Tilt encoding differs from USB: proportional to sin(angle), divide by 127
/// to get −1..+1 — same normalization we use for IntuosV2 USB.
struct BLEPenResult {
    let point: TabletPoint
    let serial: UInt32
    let toolCode: UInt16
    let isMouse: Bool
}

func decodeBLEPenReport(
    report: UnsafePointer<UInt8>,
    length: CFIndex,
    spec: DigitizerSpec,
    lastX: inout Int,
    lastY: inout Int
) -> BLEPenResult? {
    guard length >= 11 else { return nil }

    let flags       = report[1]
    _               = (flags & 0x10) != 0   // tip switch — implicit in pressure > 0
    let barrel1     = (flags & 0x20) != 0
    let barrel2     = (flags & 0x40) != 0
    let inProximity = (flags & 0x80) != 0

    let x        = Int(UInt16(report[2]) | UInt16(report[3]) << 8)
    let y        = Int(UInt16(report[4]) | UInt16(report[5]) << 8)
    let pressure = Int(UInt16(report[6]) | UInt16(report[7]) << 8)
    let distance = Int(report[8])
    let tiltX    = Double(Int8(bitPattern: report[9])) / 127.0
    let tiltY    = Double(Int8(bitPattern: report[10])) / 127.0

    let serial: UInt32 = length >= 15
        ? UInt32(report[11]) | UInt32(report[12]) << 8
          | UInt32(report[13]) << 16 | UInt32(report[14]) << 24
        : 0
    let toolCode: UInt16 = length >= 17
        ? UInt16(report[15]) | UInt16(report[16]) << 8
        : 0

    let isEraser = (toolCode & 0x0008) != 0
    let isMouse  = (toolCode & 0x000F) == 0x0006

    if inProximity {
        lastX = x
        lastY = y
    }

    let point = TabletPoint(
        x: inProximity ? x : lastX,
        y: inProximity ? y : lastY,
        maxX: spec.maxX, maxY: spec.maxY,
        pressure: inProximity ? pressure : 0,
        maxPressure: spec.maxPressure,
        tiltX: tiltX, tiltY: tiltY, rotation: 0.0,
        penButton1: barrel1,
        penButton2: barrel2,
        eraser: isEraser,
        inProximity: inProximity,
        hoverDistance: distance)

    return BLEPenResult(point: point, serial: serial, toolCode: toolCode, isMouse: isMouse)
}

// MARK: - WacomDecoder protocol

enum WirelessStatus {
    case active
    case lost
    case lowBattery
    case unknown(UInt8)
}

/// All mutable state shared between reports for a single decoder session.
/// Passed `inout` through every `decode` call so decoders can be pure structs.
struct DecoderState {
    var lastX: Int = 0
    var lastY: Int = 0
    /// Serial number at the last tool-identity change.
    var lastSerial: UInt32 = 0
    /// Tool code at the last tool-identity change (V2 change detection).
    var lastToolCode: UInt16 = 0
    /// Currently active tool code.
    var currentToolCode: UInt16 = 0
    /// Absolute scroll-position counter for mouse-tool reports (V2).
    var lastScrollPos: UInt8 = 0
    var prevInProximity: Bool = false
    var isEraser: Bool = false
    var toolIsMouse: Bool = false
    /// BT 0x80 container pad state — emit aux only on change.
    var lastBTPadKeys: UInt8 = 0
    var lastBTPadRing: UInt8 = 0x7F
    var lastBTPadBtn:  UInt8 = 0
}

enum DecodeResult {
    case none
    case pen(TabletPoint)
    case toolEnter(ToolIdentity)
    case aux(AuxButtons)
    case wireless(WirelessStatus)
}

protocol WacomDecoder {
    /// Decode one raw HID report into zero or more results.
    /// Mutating to allow decoder structs with their own cached state if needed.
    mutating func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState
    ) -> [DecodeResult]
}

// MARK: - BLE HOGP Report Decoders

/// Decode a BLE HOGP pad report (Report ID 0x03, 9 bytes) common to
/// Intuos Pro models when connected via BLE.
///
/// Layout (from §4.7):
///   [0]     0x03 Report ID
///   [1]     Keys 1–8 bitmask
///   [2]     bit 7 = ring active; bits 0–6 = ring position (0–71)
///   [3]     bits 0–1 = ring mode
///   [4–8]   Reserved
func decodeBLEPadReport(
    report: UnsafePointer<UInt8>,
    length: CFIndex
) -> AuxButtons? {
    guard length >= 3 else { return nil }
    let keys       = report[1]
    let ringByte   = report[2]
    let ringActive = (ringByte & 0x80) != 0
    let ringPos    = ringByte & 0x7F

    return AuxButtons(
        buttons: (0..<8).map { (keys & (1 << $0)) != 0 },
        touchRingActive: ringActive,
        touchRingPosition: ringActive ? ringPos : 0x7F)
}
