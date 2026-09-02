// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid
import OSLog
import TabletKit

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "driver")

/// Generic fallback driver for any unrecognised Wacom tablet (vendor 0x056A).
///
/// Tries a descriptor-derived pen decoder first — see `penDecoders` — for any
/// report ID the device's own descriptor explains field by field. Modern
/// Wacom hardware does this on its vendor page using the standard Digitizer
/// usage numbers, confirmed against a real Cintiq Pro 24 (DTH-2420)
/// descriptor. Classic Wacom descriptors declare no such fields, so those
/// devices fall through unchanged to the family guess below.
///
/// For any report ID the descriptor does not explain, auto-detects the HID
/// report family based on `MaxInputReportSize`:
///   - **IntuosV1** (≤ 64 bytes): 10-byte reports with Report ID 0x02/0x10.
///     Coordinate decode matches PTH-851 / PTZ-631W / DTK-2400.
///   - **IntuosV2** (> 64 bytes): 27+ byte reports with Report ID 0x10.
///     Coordinate decode matches PTH-660 / PTH-860.
/// This proxy is why the descriptor path is tried first rather than used to
/// pick a family: a modern Cintiq's ~26-byte pen report is closer in size to
/// the decade-older IntuosV1 format than to the IntuosV2 layout it needs, so
/// report size alone would misclassify exactly the hardware this exists for.
///
/// Queries HID descriptor elements for physical maxX, maxY, and maxPressure
/// so calibration adapts automatically.  Falls back to conservative defaults
/// if the descriptor doesn't expose them.
///
/// Provides:  cursor tracking, pressure, left-click (tip), right-click (barrel
/// button 1), middle-click (barrel button 2 / mouse middle), eraser detection,
/// tool-change packets (IntuosV1), pen serial (IntuosV2), express keys.
///
/// Does NOT provide:  EA/E0 button debounce (DTK-2400 specific), Art Pen
/// rotation, touch ring, or device seizure.  For full-fidelity support,
/// create a dedicated `*Device.swift`.
final class WacomFallbackDevice: TabletDevice {

    // Populated at init from HID descriptor query.
    let spec: DigitizerSpec

    /// Parsed HID report descriptor, captured once at init for diagnostic display.
    let parsedDescriptor: HIDDescriptorReader.Parsed

    private let device: IOHIDDevice
    private let onTablet: (TabletPoint) -> Void
    private let onAux: ((AuxButtons) -> Void)?
    private let onToolEnter: ((ToolIdentity) -> Void)?
    private var reportBuffer: [UInt8]
    private let maxReportSize: Int

    /// Which report family this device uses — the guess `penDecoders` exists
    /// to make unnecessary wherever it can.
    private enum ReportFamily { case intuosV1, intuosV2 }
    private let family: ReportFamily

    /// Descriptor-derived pen decoders, keyed by report ID.
    ///
    /// `family` above decides the byte layout by `MaxInputReportSize` alone —
    /// a proxy that fails on modern hardware: a Cintiq Pro's ~26-byte pen
    /// report is closer in size to the decade-older IntuosV1 format than to
    /// the IntuosV2 layout it actually needs. A device whose descriptor
    /// declares its pen fields does not need that guess at all; `handleReport`
    /// checks this dictionary before falling through to the family switch, so
    /// any report ID covered here bypasses the guess entirely rather than
    /// merely correcting it.
    ///
    /// Empty on every classic Wacom descriptor, which declares its fields as
    /// an unnamed vendor blob — those devices are unaffected and take the
    /// family-guess path exactly as before.
    ///
    /// Known gap: decoding here does not emit `onToolEnter`, so `activeToolSerial`
    /// stays 0 and `activeToolCode` stays at its default for a device that
    /// lands here. Eraser detection is unaffected — `TabletPoint.eraser` is
    /// read directly from the report's own Invert/Eraser bits, which
    /// `InputInjector` already treats as a defense-in-depth source independent
    /// of tool identity.
    private let penDecoders: [UInt8: GenericPenDecoder]

    private var lastX = 0
    private var lastY = 0
    private var prevInProximity = false

    // ── Tool identity ─────────────────────────────────────────────────────
    private var currentSerial: UInt32 = 0
    private var currentToolCode: UInt16 = 0
    private var isEraser: Bool = false
    private var toolIsMouse: Bool = false
    /// True once the critical-battery warning has been logged for this RF
    /// link session. The dongle may repeat status 0x06 for as long as the
    /// condition holds, and that line logs at `.warning`, which the unified
    /// log persists to disk — ungated it could write continuously. Cleared
    /// on a link transition.
    private var batteryWarningLogged: Bool = false
    /// True after the first 0x02 (link active) status for this RF link
    /// session. The dongle may send 0x02 repeatedly; without this gate every
    /// one reset decoder state and resent feature init, and a rejected write
    /// logs at `.error` — a level the unified log persists to disk, so a
    /// dongle that keeps refusing the write produced unbounded disk writes.
    /// Mirrors `wirelessLinkConfirmed` in `WacomKnownDevice`, whose comment
    /// notes that resending init on every status report also disrupts the
    /// link. Cleared on 0x05 (link lost).
    private var wirelessLinkConfirmed: Bool = false

    // ── IntuosV2 tool tracking ────────────────────────────────────────────
    private var lastSerial: UInt32 = 0
    private var lastToolCode: UInt16 = 0
    private var lastScrollPos: UInt8 = 0

    // ── Probe / calibration logging ───────────────────────────────────────
    // First 30 seconds of connection: track running maxima so that users can
    // verify calibration simply by sweeping all corners + pressing hard.
    private var peakX = 0
    private var peakY = 0
    private var peakP = 0
    private var sampleCount = 0
    private var probeDeadline: CFAbsoluteTime = 0

    private let tag: String

    // MARK: - Init

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

        let pid = hidIntProperty(device, kIOHIDProductIDKey)
        let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        tag = productName ?? "Wacom-0x\(String(pid, radix: 16, uppercase: true))"

        // Detect report family from max input report size.
        maxReportSize = hidIntProperty(device, kIOHIDMaxInputReportSizeKey)
        family = maxReportSize > 64 ? .intuosV2 : .intuosV1
        reportBuffer = [UInt8](repeating: 0, count: Swift.max(maxReportSize, 10))

        // Query HID descriptor for coordinate and pressure ranges.
        spec = Self.querySpec(device: device, family: family)
        // Two reads of the same descriptor: the parsed field model for
        // diagnostic display, and the raw hex for decoder derivation.
        parsedDescriptor = HIDDescriptorReader.read(device)
        penDecoders = Self.derivePenDecoders(from: device)
    }

    /// Builds a descriptor-driven pen decoder for every pen report the
    /// device's own descriptor declares. Empty when the descriptor cannot be
    /// parsed or declares no pen fields, which is the ordinary answer for
    /// classic Wacom hardware.
    private static func derivePenDecoders(
        from device: IOHIDDevice
    ) -> [UInt8: GenericPenDecoder] {
        guard let hex = hidReportDescriptorHex(device),
            let layout = try? HIDReportDescriptorParser.parse(hex: hex)
        else { return [:] }

        var decoders: [UInt8: GenericPenDecoder] = [:]
        for penLayout in GenericPenLayout.derive(from: layout) {
            decoders[penLayout.reportID] = GenericPenDecoder(layout: penLayout)
        }
        return decoders
    }

    // MARK: - HID descriptor query

    /// Reads logical-maximum from HID descriptor elements for X, Y, and
    /// Tip Pressure.  Returns a `DigitizerSpec` with the best values found,
    /// falling back to conservative defaults.
    private static func querySpec(device: IOHIDDevice, family: ReportFamily) -> DigitizerSpec {
        var maxX = 0
        var maxY = 0
        var maxP = 0

        // Query all input elements — cheaper than multiple targeted queries.
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) else {
            return fallbackSpec(family: family)
        }

        let count = CFArrayGetCount(elements)
        for i in 0..<count {
            guard let rawPtr = CFArrayGetValueAtIndex(elements, i) else { continue }
            let elem = Unmanaged<IOHIDElement>.fromOpaque(rawPtr).takeUnretainedValue()
            let page = IOHIDElementGetUsagePage(elem)
            let usage = IOHIDElementGetUsage(elem)
            let logMax = IOHIDElementGetLogicalMax(elem)

            // Generic Desktop: X (0x30), Y (0x31)
            if page == 0x01 {
                if usage == 0x30 && logMax > maxX { maxX = logMax }
                if usage == 0x31 && logMax > maxY { maxY = logMax }
            }
            // Digitizer: Tip Pressure (0x30)
            if page == 0x0D && usage == 0x30 && logMax > maxP {
                maxP = logMax
            }
        }

        // Sanity: if the descriptor gave us zeros, fall back.
        if maxX == 0 || maxY == 0 {
            let fb = fallbackSpec(family: family)
            if maxX == 0 { maxX = fb.maxX }
            if maxY == 0 { maxY = fb.maxY }
            if maxP == 0 { maxP = fb.maxPressure }
        }
        if maxP == 0 { maxP = family == .intuosV2 ? 8191 : 1023 }

        return DigitizerSpec(maxX: maxX, maxY: maxY, maxPressure: maxP)
    }

    private static func fallbackSpec(family: ReportFamily) -> DigitizerSpec {
        switch family {
        case .intuosV1:
            // Conservative defaults matching Intuos5 range.
            return DigitizerSpec(maxX: 44704, maxY: 27940, maxPressure: 1023)
        case .intuosV2:
            return DigitizerSpec(maxX: 44800, maxY: 29600, maxPressure: 8191)
        }
    }

    // MARK: - Open / Close

    /// Callback-context retain; created in open(), released in close().
    private var selfRetain: Unmanaged<WacomFallbackDevice>?

    /// Feature and mode inits are USB-only.  Over BLE the GATT digitizer is
    /// always active; writing the InputMode characteristic suppresses pen data.
    private func sendFeatureInit() {
        // Ask the descriptor which report carries the mode switch before
        // falling back to the legacy one.
        //
        // This matters most for the devices that land here: an unrecognized
        // modern Wacom boots emitting a reduced stream until the host writes
        // this, and the report ID carrying it varies per device. The legacy
        // 0x02 below is correct on classic hardware and happens to be correct
        // on some modern hardware too, but only by coincidence — where it is
        // wrong, the tablet stays half-awake and looks like it "reports no
        // tilt" rather than like a missing init.
        //
        // Classic Wacom and Xencelabs descriptors declare no such usage, so
        // they take the legacy path exactly as before; this adds a case rather
        // than changing one.
        var reportID: CFIndex = 0x02
        var derived = false
        if let hex = parsedDescriptor.rawHex,
            let layout = try? HIDReportDescriptorParser.parse(hex: hex),
            let declared = layout.modeSwitchFeatureReportID()
        {
            reportID = CFIndex(declared)
            derived = true
        }

        // Value 2 selects full reporting for both the vendor and the standard
        // control — see `DescriptorLayout.modeSwitchUsages`.
        var payload: [UInt8] = [UInt8(reportID), 0x02]
        hidSetReport(
            device, reportID: reportID, bytes: &payload,
            tag: "\(tag) featureInit(\(derived ? "descriptor" : "legacy"))", log: logger)
        if derived {
            logger.info(
                "\(self.tag, privacy: .public): mode switch on descriptor-declared report 0x\(String(format: "%02X", Int(reportID)), privacy: .public)"
            )
        }

        // IntuosV2 InputMode init (no-op if element not present).
        if family == .intuosV2 {
            sendWacomInputModeInit(device, tag: tag)
        }
    }

    /// Re-runs the feature/mode init on demand — see the `TabletDevice`
    /// protocol doc. Same idempotent write `open()` already sends once;
    /// safe to call again on an already-correctly-initialized device.
    func reawaken() {
        let transport =
            IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        guard !transport.lowercased().contains("bluetooth") else { return }
        sendFeatureInit()
    }

    func open() {
        let transport =
            IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        let isBluetooth = transport.lowercased().contains("bluetooth")
        let t = tag

        let ret = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard ret == kIOReturnSuccess else {
            logger.error("\(t, privacy: .public): failed to open — \(ret, privacy: .public). Is another tablet driver running?")
            return
        }

        if !isBluetooth {
            sendFeatureInit()
        }

        probeDeadline = CFAbsoluteTimeGetCurrent() + 30.0

        // Retain backing the callback context; balanced in close() after the
        // callback is unregistered. Both run on the scheduling thread, so an
        // in-flight callback cannot outlive the release. (Previously leaked —
        // one immortal driver per connect/disconnect cycle.)
        let retain = Unmanaged.passRetained(self)
        selfRetain = retain
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count,
            WacomFallbackDevice.reportCallback, retain.toOpaque())
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)

        let familyName = family == .intuosV1 ? "IntuosV1" : "IntuosV2"
        let maxX = spec.maxX; let maxY = spec.maxY; let maxP = spec.maxPressure
        logger.info("\(t, privacy: .public): generic driver attached (\(familyName, privacy: .public), maxX=\(maxX, privacy: .public) maxY=\(maxY, privacy: .public) maxP=\(maxP, privacy: .public))")

        let summary = HIDDescriptorReader.summarize(parsedDescriptor)
        logger.info("\(t, privacy: .public):\n\(summary, privacy: .public)")
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(
            device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)
        IOHIDDeviceRegisterInputReportCallback(device, &reportBuffer, reportBuffer.count, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        selfRetain?.release()
        selfRetain = nil

        if sampleCount > 0 {
            let t = tag
            let x = peakX; let y = peakY; let p = peakP; let n = sampleCount
            logger.info("\(t, privacy: .public): disconnected — observed peaks X=\(x, privacy: .public) Y=\(y, privacy: .public) P=\(p, privacy: .public) (\(n, privacy: .public) samples)")
        }
    }

    // MARK: - C callback

    private static let reportCallback: IOHIDReportCallback = {
        ctx, _, _, _, reportID, report, length in
        guard let ctx else { return }
        Unmanaged<WacomFallbackDevice>.fromOpaque(ctx).takeUnretainedValue()
            .handleReport(reportID: reportID, report: report, length: length)
    }

    // MARK: - Report dispatch

    private func handleReport(reportID: UInt32, report: UnsafePointer<UInt8>, length: CFIndex) {
        HIDCapture.shared.record(tag: tag, report: report, length: length)
        // Device-data collection. No-ops when no session is running, and never
        // hops off this thread or copies the report — see CaptureEngine.
        CaptureEngine.recordRaw(device: device, reportID: reportID, pointer: report, length: length)
        guard length >= 2 else { return }
        let id = report[0]

        // ── BLE HOGP pen report (Report ID 0x01, ≥11 bytes) ────────────
        // Fires for any Intuos Pro connected via BLE, regardless of family.
        if id == 0x01 && length >= 11 {
            handleBLEPen(report: report, length: length)
            return
        }

        // ── Wireless status report (Report ID 0x80) ──────────────────────
        // ACK-40401 RF dongle: byte[1] = 0x02 active, 0x05 lost, 0x06 low battery.
        // On the first 0x02 (link active) of a session, clear decoder state and
        // re-send feature init to ensure the digitizer is in Wacom mode.  This
        // handles the case where MockTab starts while the wireless module is
        // absent: the init sent on open is silently discarded by the dongle, so we
        // resend it when the RF link is confirmed established.  Subsequent 0x02
        // reports are ignored until a 0x05 (link lost) closes the session.
        if id == 0x80 {
            if length >= 2 {
                let t = tag
                let status = report[1]
                switch status {
                case 0x02:
                    // Only transition once per RF link session. Repeated 0x02
                    // reports are normal; resetting state and resending init on
                    // every one disrupts the link and, when the write is
                    // rejected, logs a disk-persisted error per report.
                    if !wirelessLinkConfirmed {
                        wirelessLinkConfirmed = true
                        logger.info("\(t, privacy: .public): wireless link active — clearing state and re-sending feature init")
                        // Reset decoder state to sync with wireless link-up
                        lastX = 0
                        lastY = 0
                        prevInProximity = false
                        currentSerial = 0
                        currentToolCode = 0
                        isEraser = false
                        toolIsMouse = false
                        lastSerial = 0
                        lastToolCode = 0
                        batteryWarningLogged = false

                        // Send feature init safely from main thread (not from HID callback)
                        Task { @MainActor in
                            var init1: [UInt8] = [0x02, 0x02]
                            hidSetReport(device, reportID: 0x02, bytes: &init1, tag: "\(t) wireless re-init", log: logger)
                        }
                    }
                case 0x05:
                    logger.info("\(t, privacy: .public): wireless link lost (tablet out of range or off)")
                    wirelessLinkConfirmed = false
                    batteryWarningLogged = false
                case 0x06:
                    if !batteryWarningLogged {
                        logger.warning("\(t, privacy: .public): battery critically low")
                        batteryWarningLogged = true
                    }
                default: break
                }
            }
            return
        }

        // ── Express keys: try all common USB report IDs ──────────────────
        if id == 0x11 || id == 0x0C {
            handleExpressKeys(id: id, report: report, length: length)
            return
        }

        // ── BLE HOGP pad report (Report ID 0x03, ≥3 bytes) ──────────────
        if id == 0x03 && length >= 3 {
            if let aux = decodeBLEPadReport(report: report, length: length) {
                onAux?(aux)
            } else {
                // Fall back to IntuosV1 express key decode (0x03 also used by PTZ-631W).
                handleExpressKeys(id: id, report: report, length: length)
            }
            return
        }

        // ── Descriptor-derived pen decode ─────────────────────────────────
        // Checked before the family guess below: a report ID this device's
        // own descriptor explains does not need `family` to decide its byte
        // layout, and should not go through a guess when it does not need one.
        if let decoder = penDecoders[id] {
            if let point = decoder.decode(report: Array(UnsafeBufferPointer(start: report, count: length))) {
                onTablet(point)
            }
            return
        }

        switch family {
        case .intuosV1:
            guard id == 0x02 || id == 0x10 else { return }
            guard length >= 10 else { return }
            handleIntuosV1(report: report, length: length)

        case .intuosV2:
            switch id {
            case 0x10:
                guard length >= 12 else { return }
                handleIntuosV2(report: report, length: length)
            case 0x1E:
                handleIntuosV2Offset(report: report, length: length)
            default:
                break
            }
        }
    }

    // MARK: - IntuosV1 decode (10-byte reports)

    private func handleIntuosV1(report: UnsafePointer<UInt8>, length: CFIndex) {
        let status = report[1]

        // ── Tool-change packet ────────────────────────────────────────────
        if (status & 0xFC) == 0xC0 {
            handleToolChangeV1(report: report)
            return
        }

        let inProximity = (status & 0x20) != 0
        let highConfidence = (status & 0x40) != 0
        let subtype = (status >> 1) & 0x0F

        // Proximity-out.
        if !inProximity {
            prevInProximity = false
            toolIsMouse = false
            onTablet(
                TabletPoint(
                    x: lastX, y: lastY, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: 0, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,
                    penButton1: false, penButton2: false,
                    eraser: isEraser, inProximity: false, hoverDistance: 0))
            return
        }

        // Low confidence — keep last position, zero pressure.
        guard highConfidence else {
            onTablet(
                TabletPoint(
                    x: lastX, y: lastY, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: 0, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,
                    penButton1: !toolIsMouse && (status & 0x02) != 0,
                    penButton2: !toolIsMouse && (status & 0x04) != 0,
                    eraser: isEraser, inProximity: true, hoverDistance: 0))
            return
        }

        // First-proximity fallback onToolEnter.
        if !prevInProximity {
            let isMouse = subtype == 0x06 || subtype == 0x08
            toolIsMouse = isMouse
            if currentToolCode == 0 {
                let code: UInt16 =
                    isMouse
                    ? (subtype == 0x06 ? 0x0806 : 0x0016)
                    : (isEraser ? 0x080A : 0x0802)
                onToolEnter?(
                    ToolIdentity(
                        serial: 0, toolCode: code,
                        isEraser: isEraser, isMouse: isMouse))
            }
        }
        prevInProximity = true

        // Coordinate decode.
        let x = ((Int(report[3]) | Int(report[2]) << 8) << 1) | ((Int(report[9]) >> 1) & 1)
        let y = ((Int(report[5]) | Int(report[4]) << 8) << 1) | (Int(report[9]) & 1)
        lastX = x
        lastY = y

        // Mouse subtype 0x06 (Intuos4 mouse / KC-100).
        if subtype == 0x06 {
            let buttons = report[6]
            let whlByte = report[7]
            let wheelDelta = Int((whlByte & 0x80) >> 7) - Int((whlByte & 0x40) >> 6)
            onTablet(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: 0, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,
                    penButton1: (buttons & 0x01) != 0,
                    penButton2: (buttons & 0x04) != 0,
                    eraser: false, inProximity: true, hoverDistance: 0,
                    mouseMiddleButton: (buttons & 0x02) != 0,
                    mouseWheelDelta: wheelDelta))
            probePeak(x: x, y: y, p: 0)
            return
        }

        // Mouse subtype 0x08 (2D mouse / Intuos 1–3).
        if subtype == 0x08 {
            let btnByte = report[8]
            let wheelDelta = Int(btnByte & 0x01) - Int((btnByte & 0x02) >> 1)
            onTablet(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: 0, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,
                    penButton1: (btnByte & 0x04) != 0,
                    penButton2: (btnByte & 0x10) != 0,
                    eraser: false, inProximity: true, hoverDistance: 0,
                    mouseMiddleButton: (btnByte & 0x08) != 0,
                    mouseWheelDelta: wheelDelta))
            probePeak(x: x, y: y, p: 0)
            return
        }

        // Pen path.
        let pressure = (Int(report[6]) << 3) | ((Int(report[7] & 0xC0)) >> 5) | (Int(status) & 1)
        let tiltXRaw = (((Int(report[7]) << 1) & 0x7E) | (Int(report[8]) >> 7)) - 64
        let tiltYRaw = (Int(report[8]) & 0x7F) - 64

        probePeak(x: x, y: y, p: pressure)

        onTablet(
            TabletPoint(
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

    // MARK: - IntuosV2 decode (27+ byte reports)

    private func handleIntuosV2(report: UnsafePointer<UInt8>, length: CFIndex) {
        let status = report[1]
        let highConfidence = (status & 0x20) != 0

        // Proximity-out: all position bytes zero and confidence lost.
        let allZero =
            report[2] == 0 && report[3] == 0 && report[4] == 0
            && report[5] == 0 && report[6] == 0 && report[7] == 0
        if allZero && !highConfidence {
            prevInProximity = false
            onTablet(
                TabletPoint(
                    x: lastX, y: lastY, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: 0, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,
                    penButton1: false, penButton2: false,
                    eraser: false, inProximity: false, hoverDistance: 0))
            return
        }

        // Low confidence — zero pressure, keep buttons/eraser.
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

        prevInProximity = true

        // Tool serial + code (bytes 17–22).
        if length >= 27 {
            let serial =
                UInt32(report[17]) | UInt32(report[18]) << 8
                | UInt32(report[19]) << 16 | UInt32(report[20]) << 24
            let toolCode = UInt16(report[21]) | UInt16(report[22]) << 8
            currentToolCode = toolCode

            let toolChanged =
                serial != 0
                ? serial != lastSerial
                : (toolCode != 0 && toolCode != lastToolCode)
            if toolChanged {
                lastSerial = serial
                lastToolCode = toolCode
                let isMouse = (toolCode & 0x000F) == 0x0006
                toolIsMouse = isMouse
                if isMouse { lastScrollPos = report[16] }
                onToolEnter?(
                    ToolIdentity(
                        serial: serial, toolCode: toolCode,
                        isEraser: (toolCode & 0x0008) != 0,
                        isMouse: isMouse))
            }
        }

        // Coordinate decode.
        let x = Int(UInt16(report[2]) | UInt16(report[3]) << 8) | (Int(report[4]) << 16)
        let y = Int(UInt16(report[5]) | UInt16(report[6]) << 8) | (Int(report[7]) << 16)
        lastX = x
        lastY = y

        // Mouse path.
        if toolIsMouse && currentToolCode != 0 {
            let scrollPos = report[16]
            let wheelDelta = Int(Int8(bitPattern: scrollPos &- lastScrollPos))
            lastScrollPos = scrollPos
            onTablet(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: 0, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,
                    penButton1: (status & 0x02) != 0,
                    penButton2: (status & 0x04) != 0,
                    eraser: false, inProximity: true, hoverDistance: 0,
                    mouseMiddleButton: (report[9] & 0x02) != 0,
                    mouseWheelDelta: wheelDelta))
            probePeak(x: x, y: y, p: 0)
            return
        }

        // Pen path.
        let pressure = Int(UInt16(report[8]) | UInt16(report[9]) << 8)
        let tiltX = Double(Int8(bitPattern: report[10])) / 127.0
        let tiltY = Double(Int8(bitPattern: report[11])) / 127.0

        probePeak(x: x, y: y, p: pressure)

        onTablet(
            TabletPoint(
                x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                pressure: pressure, maxPressure: spec.maxPressure,
                tiltX: tiltX, tiltY: tiltY, rotation: 0.0,
                penButton1: (status & 0x02) != 0,
                penButton2: (status & 0x04) != 0,
                eraser: (status & 0x10) != 0,
                inProximity: true,
                hoverDistance: Int(report[16])))
    }

    // MARK: - BLE HOGP pen decode

    /// BLE pen report (Report ID 0x01, 23 bytes).
    private func handleBLEPen(report: UnsafePointer<UInt8>, length: CFIndex) {
        guard
            let result = decodeBLEPenReport(
                report: report, length: length, spec: spec,
                lastX: &lastX, lastY: &lastY
            )
        else { return }

        if result.toolCode != 0
            && (result.serial != currentSerial || result.toolCode != currentToolCode)
        {
            currentSerial = result.serial
            currentToolCode = result.toolCode
            isEraser = result.point.eraser
            toolIsMouse = result.isMouse
            onToolEnter?(
                ToolIdentity(
                    serial: result.serial,
                    toolCode: result.toolCode,
                    isEraser: result.point.eraser,
                    isMouse: result.isMouse))
        }

        probePeak(x: result.point.x, y: result.point.y, p: result.point.pressure)
        onTablet(result.point)
    }

    /// Offset pen report (Report ID 0x1E) — IntuosV2 driver-compatibility mode.
    private func handleIntuosV2Offset(report: UnsafePointer<UInt8>, length: CFIndex) {
        guard length >= 13 else { return }
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
                hoverDistance: 0))
    }

    // MARK: - IntuosV1 tool-change

    private func handleToolChangeV1(report: UnsafePointer<UInt8>) {
        let serial =
            UInt32(report[3] & 0x0F) << 28
            | UInt32(report[4]) << 20
            | UInt32(report[5]) << 12
            | UInt32(report[6]) << 4
            | UInt32(report[7]) >> 4
        let toolCode =
            UInt16(report[2]) << 4
            | UInt16(report[3]) >> 4
            | UInt16(report[7] & 0x0F) << 12
            | UInt16(report[8] & 0xF0) << 4

        currentSerial = serial
        currentToolCode = toolCode
        isEraser = (toolCode & 0x000F) == 0x000A
        toolIsMouse = (toolCode & 0x000F) == 0x0006

        onToolEnter?(
            ToolIdentity(
                serial: serial, toolCode: toolCode,
                isEraser: isEraser, isMouse: toolIsMouse))
    }

    // MARK: - Express keys (multiple report formats)

    private func handleExpressKeys(id: UInt8, report: UnsafePointer<UInt8>, length: CFIndex) {
        guard let onAux else { return }

        switch id {
        case 0x11:
            // IntuosV2 (Intuos Pro): [1]=mechanical click, [2]=capacitive touch.
            // IntuosV1 (Intuos 5):   [1] and [2] identical (purely mechanical keys).
            // Use [1] for both — click-only on IntuosV2, identical on IntuosV1.
            guard length >= 3 else { return }
            let auxByte = report[1]
            let ringByte: UInt8 = length >= 5 ? report[3] : 0
            let posByte: UInt8 = length >= 5 ? report[4] : 0x7F
            let ringActive = ringByte != 0
            onAux(
                AuxButtons(
                    buttons: (0..<8).map { (auxByte & (1 << $0)) != 0 },
                    touchRingActive: ringActive,
                    touchRingPosition: ringActive ? posByte : 0x7F))

        case 0x0C:
            // Intuos3/4 style: byte 1 = keys 1–8, OR bytes 5–6 = 4+4.
            // Try byte[1] first (DTK-2400 format); if [5] is nonzero, use Intuos3 layout.
            if length >= 7 && (report[5] != 0 || report[6] != 0) {
                let lo = report[5]
                let hi = report[6]
                onAux(
                    AuxButtons(
                        buttons: (0..<4).map { (lo & (1 << $0)) != 0 }
                            + (0..<4).map { (hi & (1 << $0)) != 0 }))
            } else if length >= 2 {
                let keyByte = report[1]
                onAux(AuxButtons(buttons: (0..<8).map { (keyByte & (1 << $0)) != 0 }))
            }

        case 0x03:
            // IntuosV1 pad: byte 4 = 8 keys.
            guard length >= 5 else { return }
            let byte = report[4]
            onAux(AuxButtons(buttons: (0..<8).map { (byte & (1 << $0)) != 0 }))

        default:
            break
        }
    }

    // MARK: - Probe peak tracking

    /// During the first 30 seconds, track running maxima and log when they change.
    /// Helps users verify calibration on unknown tablets.
    private func probePeak(x: Int, y: Int, p: Int) {
        sampleCount += 1
        guard CFAbsoluteTimeGetCurrent() < probeDeadline else { return }

        var updated = false
        if x > peakX {
            peakX = x
            updated = true
        }
        if y > peakY {
            peakY = y
            updated = true
        }
        if p > peakP {
            peakP = p
            updated = true
        }

        if updated {
            let t = tag
            let px = peakX; let py = peakY; let pp = peakP
            let sx = spec.maxX; let sy = spec.maxY; let sp = spec.maxPressure
            logger.debug("\(t, privacy: .public): peak X=\(px, privacy: .public) Y=\(py, privacy: .public) P=\(pp, privacy: .public) (spec: \(sx, privacy: .public) × \(sy, privacy: .public) × \(sp, privacy: .public))")
        }
    }
}
