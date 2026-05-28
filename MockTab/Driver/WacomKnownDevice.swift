// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid
import OSLog

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "driver")

/// Data-driven tablet driver backed by a `WacomDecoder` selected at init time.
///
/// Replaces per-device Swift classes for any product in `WacomDeviceRegistry`
/// whose parser family has a live decoder (IntuosV1, IntuosV2, Intuos3).
/// Supports both USB and Bluetooth transports; BLE/BT skips USB feature inits.
final class WacomKnownDevice: TabletDevice {

    var spec: DigitizerSpec

    private let device: IOHIDDevice
    private var deviceSpec: WacomDeviceSpec
    /// True when this interface must be seized (kIOHIDOptionsTypeSeizeDevice).
    /// Only set by TabletManager when the interface is the standard HID-mouse
    /// interface (usagePage=0x01) AND the device spec requires seizure.
    private let seize: Bool
    private let onTablet: (TabletPoint) -> Void
    private let onAux: ((AuxButtons) -> Void)?
    private let onToolEnter: ((ToolIdentity) -> Void)?
    /// Called when a USB HID mouse button report (0x01, 4 bytes) arrives from the
    /// standard mouse interface (usagePage=0x01).  Carries button bitmask only;
    /// absolute position is routed separately through the digitizer interface.
    private let onMouseButton: ((UInt8) -> Void)?
    private let onBattery: ((Int, Bool) -> Void)?
    private let onWheel: ((Int, Int) -> Void)?
    /// Called once per touch frame for devices that report capacitive finger
    /// touch.  No decoder produces these yet — wired so the integration
    /// surface is ready when a per-family touch decoder lands.
    private let onTouch: (([TouchContact]) -> Void)?
    /// Called when the hardware serial is successfully queried from a WACOM_REPORT_USB
    /// (Report ID 0x03) feature report on USB/dongle connections. Serial is 0 if the
    /// query fails or the device does not support the feature report.
    private let onHardwareSerial: ((UInt32) -> Void)?

    private var decoder: any WacomDecoder
    private var state = DecoderState()
    private var reportBuffer: [UInt8]
    private var isBluetooth = false

    // ── LED companion interface ───────────────────────────────────────────────
    // Some composite devices (e.g. DTK-2400) expose LED control on a separate
    // USB interface with its own PID. That IOHIDDevice is handed to us via
    // registerLEDDevice() once TabletManager enumerates it.
    private var ledDevice: IOHIDDevice?
    /// Secondary interface (e.g. usagePage=0x01 digitizer on PTH-660/860).
    /// Stored in registerDevice() so LED commands can be routed to it when
    /// the primary (0xFF00) interface doesn't declare the control reports.
    private var secondaryDevice: IOHIDDevice?
    /// Last index requested via setRingLED. Applied immediately when ledDevice
    /// is registered so the LED syncs even if the companion connects after init.
    private var pendingLEDIndex: Int = 0

    // ── Wireless dongle (ACK-40401) support ──────────────────────────────────
    // When isWireless is true, pen events are suppressed until the RF link is
    // confirmed by a 0x80 wireless status report (d[1] bit 0 set = connected).
    // On link-up the decoder state is reset and the feature init is re-sent once.
    // On link-lost the gate closes again so stale reports from a dropped connection are not forwarded.
    private let isWireless: Bool
    private var wirelessReady: Bool = false
    /// True after the first .active status for this RF link session.
    /// Prevents resending feature init on subsequent status reports.
    private var wirelessLinkConfirmed: Bool = false

    init(
        device: IOHIDDevice,
        deviceSpec: WacomDeviceSpec,
        seize: Bool = false,
        isWireless: Bool = false,
        onTablet: @escaping (TabletPoint) -> Void,
        onAux: ((AuxButtons) -> Void)? = nil,
        onToolEnter: ((ToolIdentity) -> Void)? = nil,
        onMouseButton: ((UInt8) -> Void)? = nil,
        onBattery: ((Int, Bool) -> Void)? = nil,
        onHardwareSerial: ((UInt32) -> Void)? = nil,
        onWheel: ((Int, Int) -> Void)? = nil,
        onTouch: (([TouchContact]) -> Void)? = nil
    ) {
        self.isWireless = isWireless
        self.device = device
        self.deviceSpec = deviceSpec
        self.seize = seize
        self.onTablet = onTablet
        self.onAux = onAux
        self.onToolEnter = onToolEnter
        self.onMouseButton = onMouseButton
        self.onBattery = onBattery
        self.onHardwareSerial = onHardwareSerial
        self.onWheel = onWheel
        self.onTouch = onTouch

        self.spec = DigitizerSpec(
            maxX: deviceSpec.maxX,
            maxY: deviceSpec.maxY,
            maxPressure: deviceSpec.maxPressure,
            buttonCount: deviceSpec.buttonCount,
            hasTilt: deviceSpec.hasTilt,
            hasDualRings: deviceSpec.hasDualRings,
            isPenDisplay: deviceSpec.isPenDisplay,
            ringSlotCount: deviceSpec.ringSlotCount,
            hasFingerTouch: deviceSpec.hasFingerTouch,
            maxTouchContacts: deviceSpec.maxTouchContacts)

        // Parser → decoder dispatch. Each parser family corresponds to a wire
        // format (report ID, byte layout, coordinate encoding, pressure depth);
        // see `ReportParser` in WacomDeviceRegistry.swift for per-family details.
        // To add support for a new model: add an entry to `WacomDeviceRegistry`
        // pointing at the matching parser — no change here unless the model
        // introduces a genuinely new wire format.
        switch deviceSpec.parser {
        case .intuosV2:  self.decoder = IntuosV2Decoder()   // PTH-460/660/860, BLE HOGP
        case .intuosV3:  self.decoder = IntuosV3Decoder()   // PTK-470/670/870 (experimental)
        case .dtus:      self.decoder = DTUSDecoder()        // DTK-1651, DTU-1031/1141 (experimental)
        case .dtu:       self.decoder = DTUDecoder()         // DTU-1631, DTU-2231 (experimental)
        case .intuos3:   self.decoder = Intuos3Decoder()    // PTZ-xxx (2003–2006)
        case .bamboo:    self.decoder = BambooDecoder()     // CTL/CTH-xxx (stub)
        case .cintiqV1:  self.decoder = CintiqV1Decoder()   // Cintiq pen-displays
        case .graphire:  self.decoder = GraphireDecoder()   // Graphire/PenPartner (experimental)
        case .intuosV1:  self.decoder = IntuosV1Decoder()   // Intuos 1–5, PTK-xxx, PTH-851
        }

        // Use at least 192 bytes so both IntuosV1 (10-byte pen, 64-byte BLE)
        // and IntuosV2 (192-byte) reports always fit.
        let maxSize = hidIntProperty(device, kIOHIDMaxInputReportSizeKey)
        reportBuffer = [UInt8](repeating: 0, count: Swift.max(maxSize, 192))
    }

    // MARK: - Open / Close

    func open() {
        let transport =
            IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        isBluetooth = transport.lowercased().contains("bluetooth")
        let name = deviceSpec.name

        let options =
            seize
            ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            : IOOptionBits(kIOHIDOptionsTypeNone)
        let ret = IOHIDDeviceOpen(device, options)
        guard ret == kIOReturnSuccess else {
            let pid = String(deviceSpec.productID, radix: 16, uppercase: true)
            let didSeize = seize
            logger.error("\(name, privacy: .public) (0x\(pid, privacy: .public)): failed to open (seize=\(didSeize, privacy: .public)) — \(ret, privacy: .public). Is another tablet driver running?")
            return
        }

        logger.info("\(name, privacy: .public): opened (transport=\(transport, privacy: .public))")

        // IntuosV2 USB: mode-switch activates full tablet mode.
        // BLE: GATT is always active; writing InputMode suppresses pen data — skip.
        if deviceSpec.parser == .intuosV2 && !isBluetooth {
            sendWacomInputModeInit(device, tag: deviceSpec.name)
        }

        // Execute the device's init sequence (USB/dongle only — not needed for BLE).
        // For wireless dongles this fires on open to start the RF search; it may be
        // silently discarded until the link is up, so it is re-run when 0x80/0x02
        // confirms link-up (see the wireless-ready handler below).
        if !isBluetooth {
            executeInitSteps()

            // Query hardware serial from WACOM_REPORT_USB (Report ID 0x03) for device
            // unification: same physical tablet via USB, BT, or dongle has the same serial.
            queryHardwareSerial()
        }

        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count,
            WacomKnownDevice.reportCallback, ctx)
        IOHIDDeviceScheduleWithRunLoop(
            device, HIDThread.shared.runLoop, RunLoop.Mode.common.rawValue as CFString)
    }

    /// Register an additional IOHIDDevice (interface) for report delivery.
    /// Used for multi-interface devices (e.g. ACK-40401 wireless dongle) that
    /// enumerate separate IOHIDDevices for each interface (digitizer, wireless status, etc).
    func registerDevice(_ device: IOHIDDevice) {
        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count,
            WacomKnownDevice.reportCallback, ctx)
        IOHIDDeviceScheduleWithRunLoop(
            device, HIDThread.shared.runLoop, RunLoop.Mode.common.rawValue as CFString)
        let transport =
            IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        let name = deviceSpec.name
        logger.info("\(name, privacy: .public): registered interface (transport=\(transport, privacy: .public))")
        if secondaryDevice == nil {
            // Do NOT seize here — seizing 0x01 causes the PTH-660/860 firmware to stop
            // sending pen reports entirely. The IOHIDManager already holds the device open
            // for input delivery; that same open is sufficient for IOHIDDeviceSetReport.
            secondaryDevice = device
        }
        // The InputMode element may be on either interface depending on arrival order.
        // Attempt init on every registered interface; skips gracefully if not present.
        if deviceSpec.parser == .intuosV2 && !isBluetooth {
            sendWacomInputModeInit(device, tag: name)
            // Secondary interface just arrived — apply any LED slot that was requested
            // before it was available (mirrors the registerLEDDevice pattern).
            setRingLED(index: pendingLEDIndex)
        }
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(
            device, HIDThread.shared.runLoop, RunLoop.Mode.common.rawValue as CFString)
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if let led = ledDevice {
            IOHIDDeviceClose(led, IOOptionBits(kIOHIDOptionsTypeNone))
            ledDevice = nil
        }
        if let sec = secondaryDevice {
            IOHIDDeviceUnscheduleFromRunLoop(sec, HIDThread.shared.runLoop, RunLoop.Mode.common.rawValue as CFString)
            IOHIDDeviceRegisterInputReportCallback(sec, &reportBuffer, reportBuffer.count, nil, nil)
            IOHIDDeviceClose(sec, IOOptionBits(kIOHIDOptionsTypeNone))
            secondaryDevice = nil
        }
    }

    // MARK: - LED control

    /// Update the ring LED to reflect the active slot index.
    /// IntuosV2 (USB) and CintiqV1 families only — other families are no-ops.
    func setRingLED(index: Int) {
        pendingLEDIndex = index
        let name = deviceSpec.name
        switch deviceSpec.parser {
        case .intuosV2 where !isBluetooth:
            // USB ring LED: reports 0x31 (brightness) + 0x32 (slot selection), both sent
            // to the primary device. Format confirmed by USB capture against official
            // Wacom driver (6.3.46-2) on PTH-660 (PID 0x0357) and PTH-860 (PID 0x0356):
            //   Report 0x31 (6 bytes): [0x31, 0x46, 0x46, 0x46, 0x46, 0x46]
            //     — sets brightness for all ring LED channels (0x46 = 70, max observed)
            //   Report 0x32 (3 bytes): [0x32, 0x46, slot]
            //     — selects active ring LED slot (0–3); 0x46 byte is a fixed preamble
            // The pair is sent every time the slot changes (including at init).
            //
            // Hardware LED byte 0 = BL, 1 = TL, 2 = TR, 3 = BR.  Our slot 0 is TL
            // (Mode 1 = upper-left), so we add 1 for quarterly rings before sending.
            let ledByte = UInt8((index + (deviceSpec.ringSlotCount == 4 ? 1 : 0)) & 0x03)
            var r31: [UInt8] = [0x31, 0x46, 0x46, 0x46, 0x46, 0x46]
            hidSetReport(device, reportID: CFIndex(0x31), bytes: &r31,
                         tag: "\(name) USB LED brightness", severity: .bestEffort, log: logger)
            var r32: [UInt8] = [0x32, 0x46, ledByte]
            hidSetReport(device, reportID: CFIndex(0x32), bytes: &r32,
                         tag: "\(name) USB LED slot=\(index)", log: logger)

        case .intuosV2 where isBluetooth:
            // BT ring LED: report 0x82 (WAC_CMD_WL_INTUOSP2), 51-byte feature report.
            // Format confirmed by USB capture against official Wacom driver (6.3.46-2)
            // on PTH-660 (Intuos Pro M, PID 0x0357) over Bluetooth:
            //   buf[0]    = 0x82
            //   buf[1]    = 0x02  (fixed preamble — 0x00 is wrong)
            //   buf[4..9] = 0x46 each  (brightness for all 6 channels)
            //   buf[10]   = ring LED slot (0–3)
            //   buf[11..] = 0x00
            // The GetReport response carries current state in the same layout;
            // the serial number occupies buf[11..18] in the device's reply but
            // we clear those bytes on write (official driver does the same).
            let ledByteBT = UInt8((index + (deviceSpec.ringSlotCount == 4 ? 1 : 0)) & 0x03)
            var buf = [UInt8](repeating: 0, count: 51)
            buf[0]  = 0x82
            buf[1]  = 0x02
            buf[4]  = 0x46; buf[5] = 0x46; buf[6] = 0x46
            buf[7]  = 0x46; buf[8] = 0x46; buf[9] = 0x46
            buf[10] = ledByteBT
            hidSetReport(device, reportID: CFIndex(buf[0]), bytes: &buf,
                         tag: "\(name) BT LED ring slot=\(index)", log: logger)

        case .cintiqV1:
            // LED control via WAC_CMD_LED_CONTROL (0x20), 9-byte feature report.
            //
            // Format confirmed by USB capture against official Wacom driver (6.3.46-2):
            //   buf[0] = 0x20
            //   buf[1] = 0x44 | (rightRingSlot & 0x03) | ((leftRingSlot & 0x03) << 4)
            //     bit2 (0x04) = right ring enabled
            //     bit6 (0x40) = left  ring enabled
            //     bits[1:0]   = right ring LED slot (0–2)  ← confirmed by live hardware test
            //     bits[5:4]   = left  ring LED slot (0–2)
            //   buf[2..8] = 0x00  (official driver sends no brightness bytes)
            //
            // On DTK-2400 (0x00F4) the report descriptor declares 0x20 on the single
            // digitizer interface — ledCompanionPID 0x0056 does not appear on the bus.
            // Fall back to the primary device when ledDevice is absent.
            //
            // Both rings currently share touchRingActiveSlotIndex (single settings slot).
            // Mirror the same slot to both rings so both LEDs track mode changes.
            // TODO: independent left/right ring tracking requires touchRing2ActiveSlotIndex,
            // new .ring2SelectSlot action type, and a second DeviceContext observer.
            let ledTarget = ledDevice ?? device
            let slot = UInt8(index & 0x03)
            var buf = [UInt8](repeating: 0, count: 9)
            buf[0] = 0x20  // WAC_CMD_LED_CONTROL
            buf[1] = 0x44 | slot | (slot << 4)  // mirror: both rings track same slot
            hidSetReport(ledTarget, reportID: CFIndex(buf[0]), bytes: &buf,
                         tag: "\(name) CintiqV1 LED slot=\(slot) (both rings)", log: logger)

        case .intuosV1:
            // USB LED control via WAC_CMD_LED_CONTROL (0x20), 9-byte feature report.
            // Format confirmed by USB capture against official Wacom driver (6.3.46-2)
            // on PTH-850 (Intuos5 L, PID 0x0028):
            //   buf[0] = 0x20
            //   buf[1] = (llv & 0x1f) | ((ringSelect & 0x07) << 5)
            //     bits[4:0] = llv luminance (0–31)
            //     bits[7:5] = ring LED slot (0–3 for 4-slot; 0–2 for 3-slot devices)
            //   buf[2] = hlv & 0x1f  (high-luminance value, 0–31)
            //   buf[3..8] = 0x00
            // Official driver observed values: llv=0x14 (20), hlv=0x01 — used as defaults.
            // Sent to primary device (no companion interface on Intuos5 USB).
            let llv: UInt8 = 0x14
            let hlv: UInt8 = 0x01
            var buf = [UInt8](repeating: 0, count: 9)
            buf[0] = 0x20  // WAC_CMD_LED_CONTROL
            buf[1] = (llv & 0x1f) | (UInt8(index & 0x07) << 5)
            buf[2] = hlv & 0x1f
            hidSetReport(device, reportID: CFIndex(buf[0]), bytes: &buf,
                         tag: "\(name) IntuosV1 LED slot=\(index)", log: logger)

        default:
            break
        }
    }

    /// Enable or disable capacitive finger touch on the hardware.
    ///
    /// Wacom touch-capable devices accept a feature report (Linux notes cite
    /// Report ID 0x0A with `[0, 0, 0, 1]` to enable, `[0, 0, 0, 0]` to
    /// disable), but the exact bytes have not been verified against a real
    /// macOS-shipped DTH-* device.  Until a capture confirms the wire
    /// format this method only logs the request — the in-app `touchEnabled`
    /// setting still gates `InputInjector.injectTouch`, so users can turn
    /// touch off without any hardware cooperation.
    ///
    /// TODO: once a real capture confirms the feature-report bytes for one
    /// of DTH-271 / DTH-135 / DTH-1320 / DTH-2400 / DTH-2200, populate the
    /// payload below and remove the early-return log.
    func setTouchEnabled(_ enabled: Bool) {
        guard deviceSpec.hasFingerTouch else { return }
        logger.info("\(self.deviceSpec.name, privacy: .public): setTouchEnabled(\(enabled, privacy: .public)) requested — hardware feature-report unverified, in-app touchEnabled gate is authoritative")
        // var payload: [UInt8] = [0x0A, 0x00, 0x00, 0x00, enabled ? 0x01 : 0x00]
        // hidSetReport(device, reportID: CFIndex(0x0A), bytes: &payload,
        //              tag: "\(deviceSpec.name) touchEnabled=\(enabled)",
        //              severity: .bestEffort, log: logger)
    }

    /// Register the companion LED controller interface for this device.
    /// Called by TabletManager when a no-digitizer Wacom interface is matched
    /// to this device via `WacomDeviceSpec.ledCompanionPID`.
    func registerLEDDevice(_ device: IOHIDDevice) {
        let ret = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        ledDevice = device
        logger.info("\(self.deviceSpec.name, privacy: .public): LED companion interface registered (open ret=\(ret, privacy: .public))")
        // Apply any pending LED index that was requested before this interface arrived.
        setRingLED(index: pendingLEDIndex)
    }

    /// Execute the device's init sequence (`deviceSpec.initSteps`) from `index` onward.
    ///
    /// Runs synchronously until a `.delay` step is encountered; at that point the
    /// remaining steps are scheduled on the main queue and this call returns.
    /// Callers must be on the main thread — `IOHIDDeviceSetReport` is not thread-safe.
    private func executeInitSteps(from index: Int = 0) {
        let steps = deviceSpec.initSteps
        guard index < steps.count else { return }
        switch steps[index] {
        case .featureReport(var bytes):
            let reportID = CFIndex(bytes[0])
            hidSetReport(device, reportID: reportID, bytes: &bytes,
                         tag: "\(deviceSpec.name) initStep[\(index)]", log: logger)
            executeInitSteps(from: index + 1)
        case .outputReport:
            // Not yet wired up (Xencelabs); advance to keep the sequence moving.
            executeInitSteps(from: index + 1)
        case .delay(let seconds):
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.executeInitSteps(from: index + 1)
            }
        case .stringDescriptor:
            // Not yet wired up (Huion); advance to keep the sequence moving.
            executeInitSteps(from: index + 1)
        }
    }

    /// Query the hardware serial number from WACOM_REPORT_USB (Report ID 0x03) feature report.
    ///
    /// The serial is transport-agnostic (same physical tablet returns the same serial
    /// over USB, BT, or wireless dongle). Used for device unification and distinguishing
    /// multiple same-model tablets.
    ///
    /// Report format (from Linux wacom_sys.c):
    ///   Byte 0:   Report ID (0x03)
    ///   Bytes 1-3: Firmware version (typically ASCII)
    ///   Bytes 4-7: Device serial (LE uint32, hardware-burned)
    ///
    /// Runs on the main thread (IOHIDDeviceGetReport is synchronous, not thread-safe).
    /// Assumes device is already opened. Called from open() on USB/dongle only (never BT).
    private func queryHardwareSerial() {
        var buf = [UInt8](repeating: 0, count: 64)
        var bufSize = CFIndex(buf.count)
        let reportID = CFIndex(0x03)

        let result = IOHIDDeviceGetReport(
            device, kIOHIDReportTypeFeature, reportID, &buf, &bufSize)

        guard result == kIOReturnSuccess && bufSize >= 8 else {
            // Device does not support or failed to respond to Report ID 0x03.
            // Call the callback with serial=0 to indicate unknown/unavailable.
            onHardwareSerial?(0)
            return
        }

        // Extract serial from bytes 4–7 (LE uint32)
        let serial =
            UInt32(buf[4])
            | UInt32(buf[5]) << 8
            | UInt32(buf[6]) << 16
            | UInt32(buf[7]) << 24

        guard serial != 0 else {
            // Serial bytes are zero (unprogrammed or reserved); treat as unavailable.
            onHardwareSerial?(0)
            return
        }

        let pidHex = String(deviceSpec.productID, radix: 16, uppercase: true)
        let name = deviceSpec.name
        logger.info("\(name, privacy: .public) (0x\(pidHex, privacy: .public)): hardware serial received")
        onHardwareSerial?(serial)
    }

    // MARK: - C callback

    private static let reportCallback: IOHIDReportCallback = { ctx, _, _, _, _, report, length in
        guard let ctx else { return }
        Unmanaged<WacomKnownDevice>.fromOpaque(ctx).takeUnretainedValue()
            .handleReport(report: report, length: length)
    }

    // MARK: - Report dispatch

    private func handleReport(report: UnsafePointer<UInt8>, length: CFIndex) {
        let name = deviceSpec.name
        HIDCapture.shared.record(tag: name, report: report, length: length)
        // Delta capture — only fires when CaptureEngine.isRunning is true.
        if CaptureEngine._isRunningNonisolated {
            let r0 = report[0]
            let bytes = [UInt8](UnsafeBufferPointer(start: report, count: length))
            Task { @MainActor in
                bytes.withUnsafeBufferPointer {
                    CaptureEngine.shared.recordSample(
                        reportID: r0, report: $0.baseAddress!, length: length)
                }
            }
        }
        // For wireless dongles, extract paired tablet PID from 0x80 status report and
        // use its spec for accurate coordinate ranges (instead of fallback guesses).
        if isWireless && length >= 8 && report[0] == 0x80 && (report[1] & 0x01) != 0 {
            let pairedTabletPID = Int(UInt16(report[7]) | UInt16(report[6]) << 8)  // Big-endian
            if pairedTabletPID > 0,
                let pairedSpec = WacomDeviceRegistry.spec(for: pairedTabletPID),
                pairedSpec.maxX > 0 && pairedSpec.maxY > 0
            {
                // Update our spec with the paired tablet's actual dimensions
                spec = DigitizerSpec(
                    maxX: pairedSpec.maxX,
                    maxY: pairedSpec.maxY,
                    maxPressure: pairedSpec.maxPressure,
                    buttonCount: pairedSpec.buttonCount,
                    hasFingerTouch: pairedSpec.hasFingerTouch,
                    maxTouchContacts: pairedSpec.maxTouchContacts)
                //                print("\(deviceSpec.name): using paired tablet spec (PID 0x\(String(pairedTabletPID, radix: 16, uppercase: true))) — maxX=\(spec.maxX) maxY=\(spec.maxY) maxPressure=\(spec.maxPressure)")
            }
        }

        let results = decoder.decode(
            report: report, length: length, spec: spec, state: &state,
            deviceFamily: deviceSpec.family)
        for result in results {
            switch result {
            case .none:
                break
            case .pen(let point):
                // Wireless dongle: suppress pen events until RF link is confirmed active.
                guard !isWireless || wirelessReady else { break }
                onTablet(point)
            case .toolEnter(let identity):
                guard !isWireless || wirelessReady else { break }
                onToolEnter?(identity)
            case .aux(let buttons):
                onAux?(buttons)
            case .wireless(let ws):
                switch ws {
                case .active:
                    // Only transition once per RF link session. Multiple .active reports
                    // are normal (dongle may send status reports frequently); don't resend
                    // feature init or reset state on every one, as that disrupts the link.
                    if !wirelessLinkConfirmed {
                        logger.info("\(name, privacy: .public): wireless link active")
                        // Reset decoder state so stale coordinates/tool identity from
                        // before link-up are not forwarded on the first live report.
                        state = DecoderState()
                        wirelessReady = true
                        wirelessLinkConfirmed = true
                        // Re-run init steps now that the RF link is confirmed.
                        // Must be dispatched to main thread — HID callbacks are background.
                        Task { @MainActor in
                            self.executeInitSteps()
                        }
                    }
                case .lost:
                    if wirelessLinkConfirmed {
                        logger.info("\(name, privacy: .public): wireless link lost")
                        wirelessLinkConfirmed = false
                    }
                    wirelessReady = false
                    state = DecoderState()
                case .lowBattery:
                    logger.warning("\(name, privacy: .public): battery critically low")
                case .unknown:
                    break
                }
            case .battery(let pct, let chg):
                onBattery?(pct, chg)
            case .mouseButton(let mask):
                onMouseButton?(mask)
            case .wheel(let index, let delta):
                onWheel?(index, delta)
            case .touch(let contacts):
                onTouch?(contacts)
            case .toolCompatibility(let message):
                logger.info("\(name, privacy: .public): \(message, privacy: .public)")
            }
        }
    }
}
