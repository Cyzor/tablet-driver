// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid
import OSLog

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "device")

/// Digitizer dimensions in device units for a given tablet model.
public struct DigitizerSpec {
    public var maxX: Int
    public var maxY: Int
    public var maxPressure: Int
    /// Number of programmable express-key buttons on this device.
    /// Used by BambooDecoder to select the correct pad-byte bit layout.
    public var buttonCount: Int = 0
    /// True if this device's pen reports carry tilt data.
    /// Currently relevant for BambooDecoder only (report[8]/report[9], 4-bit signed).
    /// IntuosV1/V2/Intuos3 always decode tilt regardless of this flag.
    public var hasTilt: Bool = false
    /// True if this model has two touch rings (one per bezel), e.g. Cintiq 24HD.
    /// Used by CintiqV1Decoder to gate decoding of the second ring byte in 0x0C reports.
    public var hasDualRings: Bool = false
    /// True if this device is a pen display (Cintiq-class) with a built-in screen.
    /// Used to gate pen-display-specific UI (e.g. parallax offset calibration).
    public var isPenDisplay: Bool = false
    /// Number of ring mode slots this device supports.
    /// Matches the number of physical toggle positions (e.g. 4 LED positions on Intuos Pro).
    /// The UI shows this many slots; the model always stores 4 (same pattern as expressKeyBindings).
    public var ringSlotCount: Int = 4
    /// True if this device has capacitive finger touch in addition to the pen.
    /// Mirrors `WacomDeviceSpec.hasFingerTouch`; gates UI for the Touch pane
    /// and the touch-enable feature report.  See `hasFingerTouch` doc there.
    public var hasFingerTouch: Bool = false
    /// Maximum simultaneous touch contacts the device reports (1 for single-touch
    /// Cintiqs like DTH-2400/DTH-2200; 10 for multi-touch DTH-271/DTH-135/DTH-1320).
    public var maxTouchContacts: Int = 0
}

protocol TabletDevice: AnyObject {
    var spec: DigitizerSpec { get }
    func open()
    func close()
    /// Update the physical ring LED to reflect the active mode slot (0-based).
    /// No-op on devices that don't support LED control.
    func setRingLED(index: Int)
}

extension TabletDevice {
    func setRingLED(index: Int) {}
}

// Convenience: read an integer property from an IOHIDDevice.
func hidIntProperty(_ device: IOHIDDevice, _ key: String) -> Int {
    guard let val = IOHIDDeviceGetProperty(device, key as CFString) else { return 0 }
    return (val as? NSNumber)?.intValue ?? 0
}

/// Query the HID descriptor elements for the digitizer's coordinate and pressure ranges.
///
/// Returns `(maxX, maxY, maxPressure)` read from logical-maximum values on
/// Generic Desktop X/Y and Digitizer Tip Pressure elements. Also returns
/// `isLargeReport` (true when MaxInputReportSize > 64) to distinguish IntuosV1
/// from IntuosV2 report families.
///
/// Used by `TabletManager` when building a `WacomDeviceSpec` at runtime —
/// e.g. for the ACK-40401 wireless dongle whose paired-tablet dimensions are
/// encoded in its HID descriptor rather than the static registry.
func queryHIDDigitizerSpec(_ device: IOHIDDevice)
    -> (maxX: Int, maxY: Int, maxPressure: Int, isLargeReport: Bool)
{
    var maxX = 0
    var maxY = 0
    var maxP = 0
    let maxReportSize = hidIntProperty(device, kIOHIDMaxInputReportSizeKey)
    let isLargeReport = maxReportSize > 64

    guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) else {
        let fallbackP = isLargeReport ? 8191 : 1023
        let (fallbackX, fallbackY) = isLargeReport ? (65535, 40960) : (22860, 14430)
        return (fallbackX, fallbackY, fallbackP, isLargeReport)
    }

    let count = CFArrayGetCount(elements)
    for i in 0..<count {
        // Fix: Safely unwrap the optional pointer returned by CFArrayGetValueAtIndex
        guard let rawPtr = CFArrayGetValueAtIndex(elements, i) else { continue }
        let elem = Unmanaged<IOHIDElement>.fromOpaque(rawPtr).takeUnretainedValue()
        let page = IOHIDElementGetUsagePage(elem)
        let usage = IOHIDElementGetUsage(elem)
        let logMax = IOHIDElementGetLogicalMax(elem)

        if page == 0x01 {
            if usage == 0x30 && logMax > maxX { maxX = logMax }
            if usage == 0x31 && logMax > maxY { maxY = logMax }
        }
        if page == 0x0D && usage == 0x30 && logMax > maxP { maxP = logMax }
    }

    // Fallback values when descriptor doesn't specify X/Y. Large devices (192+ byte reports)
    // get 65535x40960; smaller IntuosV1-family (10-byte) get 22860x14430.
    if maxX == 0 { maxX = isLargeReport ? 65535 : 22860 }
    if maxY == 0 { maxY = isLargeReport ? 40960 : 14430 }
    if maxP == 0 { maxP = isLargeReport ? 8191 : 1023 }
    return (maxX, maxY, maxP, isLargeReport)
}

/// Sends the HID Digitizer Input Mode feature report to switch the device into
/// full tablet mode, unlocking cursor/mouse tool button state in pen reports.
///
/// Searches the device's elements for Usage Page 0x0D (Digitizer) / Usage 0x29
/// (Input Mode), reads its report ID, and sends [reportID, 2]. Call once per
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
        logger.debug("\(tag, privacy: .public): no InputMode element on this interface — skipping init")
        return
    }

    // CFArrayGetValueAtIndex returns an unretained IOHIDElement reference.
    let elem = Unmanaged<IOHIDElement>.fromOpaque(rawPtr).takeUnretainedValue()
    let reportID = IOHIDElementGetReportID(elem)
    let reportBits = IOHIDElementGetReportSize(elem) * IOHIDElementGetReportCount(elem)
    logger.debug("\(tag, privacy: .public): InputMode element found — reportID=\(reportID, privacy: .public) size=\(reportBits, privacy: .public) bits (\((reportBits + 7) / 8, privacy: .public) bytes payload)")

    // Use IOHIDDeviceSetValue rather than IOHIDDeviceSetReport with a raw byte array.
    // IOHIDDeviceSetReport([reportID, 2]) only sends 2 bytes; if the feature report is
    // longer the device discards it. IOHIDDeviceSetValue lets IOHIDKit build the
    // correctly-sized report from the element descriptor (handles byte offset + padding).
    let value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, elem, 0, 2)
    let ret = IOHIDDeviceSetValue(device, elem, value)
    if ret == kIOReturnSuccess {
        logger.debug("\(tag, privacy: .public): InputMode init OK (reportID=\(reportID, privacy: .public))")
    } else {
        logger.error("\(tag, privacy: .public): InputMode init FAILED (0x\(String(ret, radix: 16, uppercase: true), privacy: .public))")
    }
}

// MARK: - BLE HOGP Report Decoders

/// Decode a BLE HOGP pen report (Report ID 0x01, 23 bytes) common to all
/// Intuos Pro models (PTH-451/651/851, PTH-660/860) when connected via
/// Bluetooth Low Energy.
///
/// Layout (from Wacom-Wireless-Specification-Notes.md §4.5):
/// [0] 0x01 Report ID
/// [1] bits 0–3 = tool index; bit 4 = tip switch; bit 5 = barrel 1;
///     bit 6 = barrel 2; bit 7 = proximity
/// [2–3] X (LE uint16)
/// [4–5] Y (LE uint16)
/// [6–7] Pressure (LE uint16, 0–8191)
/// [8] Distance (uint8, 0–63)
/// [9] Tilt X (signed int8, −127..+127 = sin(angle))
/// [10] Tilt Y (signed int8)
/// [11–14] Tool serial (LE uint32)
/// [15–16] Tool ID (LE uint16)
/// [17–22] Reserved
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

    let flags = report[1]
    _ = (flags & 0x10) != 0  // tip switch — implicit in pressure > 0
    let barrel1 = (flags & 0x20) != 0
    let barrel2 = (flags & 0x40) != 0
    let inProximity = (flags & 0x80) != 0

    let x = Int(UInt16(report[2]) | UInt16(report[3]) << 8)
    let y = Int(UInt16(report[4]) | UInt16(report[5]) << 8)
    let pressure = Int(UInt16(report[6]) | (UInt16(report[7] & 0x1F) << 8))
    let distance = Int(report[8])
    let tiltX = Double(Int8(bitPattern: report[9])) / 127.0
    let tiltY = Double(Int8(bitPattern: report[10])) / 127.0

    let serial: UInt32 =
        length >= 15
        ? UInt32(report[11]) | UInt32(report[12]) << 8
            | UInt32(report[13]) << 16 | UInt32(report[14]) << 24
        : 0
    let toolCode: UInt16 =
        length >= 17
        ? UInt16(report[15]) | UInt16(report[16]) << 8
        : 0

    let isEraser = (toolCode & 0x0008) != 0
    let isMouse = (toolCode & 0x000F) == 0x0006

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

public enum WirelessStatus {
    case active
    case lost
    case lowBattery
    case unknown(UInt8)
}

/// All mutable state shared between reports for a single decoder session.
/// Passed `inout` through every `decode` call so decoders can be pure structs.
public struct DecoderState {
    public var lastX: Int = 0
    public var lastY: Int = 0
    /// Serial number at the last tool-identity change.
    public var lastSerial: UInt32 = 0
    /// Tool code at the last tool-identity change (V2 change detection).
    public var lastToolCode: UInt16 = 0
    /// Currently active tool code.
    public var currentToolCode: UInt16 = 0
    /// Absolute scroll-position counter for mouse-tool reports (V2).
    public var lastScrollPos: UInt8 = 0
    public var prevInProximity: Bool = false
    public var isEraser: Bool = false
    public var toolIsMouse: Bool = false
    /// BT 0x80 container pad state — emit aux only on change.
    public var lastBTPadKeys: UInt8 = 0
    public var lastBTPadRing: UInt8 = 0x7F
    public var lastBTPadBtn: UInt8 = 0
    /// Consecutive frames/reports with low-confidence or out-of-range signal.
    /// Exit proximity only after this reaches exitThreshold, bridging transient
    /// boundary oscillations (confirmed: Art Pen rotation sensor causes these).
    /// Reset to 0 on any valid in-proximity frame.
    public var exitFrameCount: Int = 0
    public static let exitThreshold = 3
    /// Whether the current tool is supported on this device family.
    /// Used to show UI warnings for incompatible tools and adjust feature decoding.
    public var toolIsSupported: Bool = true
    /// Last valid rotation reading (Art Pen). Used to hold state during boundary-noise
    /// frames where !highConfidence (USB) or !inRange (BT). Reset to 0.0 on proximity exit.
    public var lastRotation: Double = 0.0
    /// True once at least one valid rotation frame has been decoded since tool-enter.
    /// Prevents emitting stale 0.0 during boundary oscillations at re-entry.
    public var hasValidRotationFrame: Bool = false
    public var hasValidTiltFrame: Bool = false
    /// Last valid tilt readings. Used to hold state during boundary-noise frames
    /// where !highConfidence (USB) or !inRange (BT) so that apps receive a continuous
    /// azimuth angle rather than a zero-snapped value on every low-confidence frame.
    /// Reset to 0.0 on proximity exit alongside lastRotation.
    public var lastTiltX: Double = 0.0
    public var lastTiltY: Double = 0.0
    /// Last raw battery byte seen (INTUOSP2_BT 361-byte path). 0xFF = not yet received.
    /// Used to suppress redundant .battery emissions on every pen report.
    public var lastBatteryByte: UInt8 = 0xFF

    public init() {}
}

public enum DecodeResult {
    case none
    case pen(TabletPoint)
    case toolEnter(ToolIdentity)
    case aux(AuxButtons)
    case wireless(WirelessStatus)
    /// Battery status from a BT device report.
    /// `percent` is 0–100 (direct, no lookup table). `charging` is true when the device is plugged in.
    case battery(percent: Int, charging: Bool)
    /// Tool compatibility warning: tool is present but not fully supported on this device.
    /// The associated string describes the limitation (e.g., "Rotation not supported").
    case toolCompatibility(String)
    /// Standard USB HID mouse report (Report ID 0x01, 4 bytes) from the mouse
    /// interface (usagePage=0x01) of an Intuos Pro tablet. Carries button state only;
    /// absolute position is delivered separately via the digitizer 0x10 stream.
    /// bit0 = left, bit1 = right, bit2 = middle.
    case mouseButton(UInt8)
    /// Relative-encoder wheel step from a device with physical scroll wheels
    /// (e.g. PTK-470/670/870 IntuosV3 side wheels).  `index` identifies the
    /// wheel (0 = left, 1 = right); `delta` is the signed per-frame step count
    /// (positive = clockwise / up, negative = counter-clockwise / down).
    /// Routed through `touchRingSlots[index]` in InputInjector so the user can
    /// configure scroll vs. key-press behaviour through the existing ring UI.
    case wheel(index: Int, delta: Int)
    /// Capacitive finger-touch contact frame.  One emission carries the full
    /// set of active contacts; an empty array signals "all fingers lifted".
    /// Coordinates are in the same device-units space as `TabletPoint`
    /// (decoder must scale to `spec.maxX`/`spec.maxY`).  See `TouchContact`.
    ///
    /// Currently emitted by no shipping decoder — Phase 1 plumbing for
    /// Cintiq Pro 27 (DTH-271), Movink 13 (DTH-135), Cintiq 16 (DTH-1320),
    /// Cintiq 24HD Touch (DTH-2400), Cintiq 22HD Touch (DTH-2200) once a
    /// real capture confirms the per-family byte layout.
    case touch([TouchContact])
}

/// A single capacitive contact point reported by a touch-capable Wacom display.
/// `id` is a per-contact tracking identifier reused across frames for the same
/// finger (typically 0–9 on 10-point devices).  `contactArea` is optional and
/// only populated on devices that report contact-major.
public struct TouchContact: Equatable {
    public let id: Int
    public let x: Int
    public let y: Int
    public let contactArea: Int?

    public init(id: Int, x: Int, y: Int, contactArea: Int?) {
        self.id = id
        self.x = x
        self.y = y
        self.contactArea = contactArea
    }
}

/// Vendor-neutral decoder protocol.  One per HID report family.
///
/// G3 publish surface for the `TabletKit` Swift package.  Implementors translate
/// a raw HID input report into a sequence of high-level `DecodeResult` events.
/// Stateless across calls except for the `inout DecoderState` the host owns.
public protocol TabletReportDecoder {
    /// Decode one raw HID report into zero or more results.
    /// Mutating to allow decoder structs with their own cached state if needed.
    /// - Parameter deviceFamily: The device family string (e.g., "intuosProGen2", "cintiq")
    ///   used to check tool compatibility and adjust feature decoding.
    mutating func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult]
}

/// Source-compatible alias for the pre-TabletKit name.  All existing decoders
/// inside this repo continue to compile against `WacomDecoder`; new code should
/// prefer `TabletReportDecoder`.  Will be removed once the published package
/// has shipped at least one minor release.
public typealias WacomDecoder = TabletReportDecoder

// MARK: - BLE HOGP Pad Report Decoder

/// Decode a BLE HOGP pad report (Report ID 0x03, 9 bytes) common to
/// Intuos Pro models when connected via BLE.
///
/// Layout (from §4.7):
/// [0] 0x03 Report ID
/// [1] Keys 1–8 bitmask
/// [2] bit 7 = ring active; bits 0–6 = ring position (0–71)
/// [3] bits 0–1 = ring mode
/// [4–8] Reserved
func decodeBLEPadReport(
    report: UnsafePointer<UInt8>,
    length: CFIndex
) -> AuxButtons? {
    guard length >= 3 else { return nil }
    let keys = report[1]
    let ringByte = report[2]
    let ringActive = (ringByte & 0x80) != 0
    let ringPos = ringByte & 0x7F

    return AuxButtons(
        buttons: (0..<8).map { (keys & (1 << $0)) != 0 },
        touchRingActive: ringActive,
        touchRingPosition: ringActive ? ringPos : 0x7F)
}

// MARK: - Tool compatibility checking

/// Emit a toolCompatibility warning if the tool code is not fully supported on the device.
/// Updates `state.toolIsSupported` and appends `.toolCompatibility(msg)` to results if needed.
func emitToolCompatibility(
    toolCode: UInt16,
    deviceFamily: String,
    state: inout DecoderState,
    results: inout [DecodeResult]
) {
    let caps = WacomToolCatalog.capabilities(forToolCode: toolCode, family: deviceFamily)
    state.toolIsSupported = caps.isSupported
    if !caps.isSupported {
        var limitations: [String] = []
        if !caps.hasPressure { limitations.append("pressure") }
        if !caps.hasTilt { limitations.append("tilt") }
        if !caps.hasRotation { limitations.append("rotation") }
        let msg = "Tool 0x\(String(format: "%04X", toolCode)) not fully supported on \(deviceFamily). Limited to: \(limitations.joined(separator: ", "))"
        results.append(.toolCompatibility(msg))
    }
}

// MARK: - Wireless status decoding (bit-0 protocol)

/// Decode wireless status for V1/Intuos3 dongles (ACK-4040 / basic protocol).
/// Protocol: report[1] bit 0 = connection state (1 = active, 0 = lost).
func decodeWirelessReport(report: UnsafePointer<UInt8>, length: CFIndex) -> [DecodeResult] {
    guard length >= 2 else { return [] }
    if (report[1] & 0x01) != 0 { return [.wireless(.active)] }
    return [.wireless(.lost)]
}
