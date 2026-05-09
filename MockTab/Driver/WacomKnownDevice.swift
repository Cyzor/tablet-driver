// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026  This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab.  If not, see <https://www.gnu.org/licenses/>.

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
        onHardwareSerial: ((UInt32) -> Void)? = nil
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

        self.spec = DigitizerSpec(
            maxX: deviceSpec.maxX,
            maxY: deviceSpec.maxY,
            maxPressure: deviceSpec.maxPressure,
            buttonCount: deviceSpec.buttonCount,
            hasTilt: deviceSpec.hasTilt,
            hasDualRings: deviceSpec.hasDualRings,
            isPenDisplay: deviceSpec.isPenDisplay,
            ringSlotCount: deviceSpec.ringSlotCount)

        // Parser → decoder dispatch. Each parser family corresponds to a wire
        // format (report ID, byte layout, coordinate encoding, pressure depth);
        // see `ReportParser` in WacomDeviceRegistry.swift for per-family details.
        // To add support for a new model: add an entry to `WacomDeviceRegistry`
        // pointing at the matching parser — no change here unless the model
        // introduces a genuinely new wire format.
        switch deviceSpec.parser {
        case .intuosV2:  self.decoder = IntuosV2Decoder()   // PTH-460/660/860, BLE HOGP
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

        // Feature inits activate the digitizer endpoint over USB.  Not needed for BLE.
        // For wireless dongles, the feature init is sent immediately on open to tell the
        // dongle to begin searching for the tablet.  It may be silently discarded if the
        // RF link is not yet established, so it is re-sent when 0x80/0x02 confirms link-up.
        if !isBluetooth {
            // IntuosV1 / Intuos3: feature init. First byte is the report ID.
            sendFeatureInit()

            // Intuos3 two-stage init: second feature report after a brief delay.
            if var bytes2 = deviceSpec.featureInit2 {
                let reportID2 = CFIndex(bytes2[0])
                let delay = deviceSpec.featureInit2Delay
                let dev = device
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    IOHIDDeviceSetReport(
                        dev, kIOHIDReportTypeFeature, reportID2, &bytes2, bytes2.count)
                }
            }

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
            // LED report for intuosV2 USB. Observed behavior:
            //   PTH-660 USB: 0x11 works (LEDs track slot changes).
            //   PTH-860 USB: 0x11 accepted by IOKit but firmware ignores it (LEDs static).
            //   Both models work via the BT path below (report 0x82).
            // Notably 0x11 is also PTH-860's pad *input* report ID — likely collision.
            // 0xCC (WAC_CMD_LED_CONTROL_GENERIC) actively breaks pen input — do not use.
            // 0x20 (WAC_CMD_LED_CONTROL) also silently ignored.
            // TODO(PTH-860 USB LED): diagnose by (a) logging IOHIDDeviceSetReport ret here,
            //   (b) checking Linux wacom_sys.c wacom_led_control() for the INTUOSP2 USB
            //   report ID, (c) considering an LED-enable feature-init (report 0x0A) or a
            //   companion-interface route (see ledCompanionPID / cintiqV1 branch).
            let ledBits = (UInt8(1) << 2) | UInt8(index & 0x03)
            var buf = [UInt8](repeating: 0, count: 9)
            buf[0] = 0x11
            buf[1] = ledBits
            let ret = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(buf[0]), &buf, buf.count)
            // logger.debug("\(name, privacy: .public): setRingLED USB slot=\(index) ledBits=0x\(String(ledBits, radix: 16)) ret=\(ret, privacy: .public)")

        case .intuosV2 where isBluetooth:
            // Linux wacom_sys.c wacom_led_control(), WAC_CMD_WL_INTUOSP2 BT path:
            //   WAC_CMD_WL_INTUOSP2 = 0x82, 51-byte buffer
            //   buf[9]  = llv (luminance)
            //   buf[10] = ring_led (select & 0x03)
            var buf = [UInt8](repeating: 0, count: 51)
            buf[0] = 0x82  // WAC_CMD_WL_INTUOSP2
            buf[9]  = 0x40  // llv: moderate brightness
            buf[10] = UInt8(index & 0x03)
            let ret = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(buf[0]), &buf, buf.count)
            // logger.debug("\(name, privacy: .public): setRingLED BT slot=\(index) buf[10]=\(index) ret=\(ret, privacy: .public)")

        case .cintiqV1:
            // LED control targets the companion interface (ledDevice), not the digitizer.
            // Linux wacom_sys.c wacom_led_control(), WACOM_24HD path:
            //   WAC_CMD_LED_CONTROL = 0x20
            //   buf[1] = (group0.select | 0x4) | ((group1.select << 4) | 0x40)
            //   buf[2] = llv, buf[3] = hlv
            // Ring 2 (group 1) independent index not yet tracked; stays at slot 0.
            guard let led = ledDevice else {
                logger.warning("\(name, privacy: .public): setRingLED CintiqV1 slot=\(index) — ledDevice is nil, skipping")
                break
            }
            let ledByte = UInt8(index & 0x03) | 0x44  // 0x04 = group0 enable, 0x40 = group1 at slot 0
            var buf = [UInt8](repeating: 0, count: 9)
            buf[0] = 0x20  // WAC_CMD_LED_CONTROL
            buf[1] = ledByte
            buf[2] = 0x40  // llv: moderate brightness
            buf[3] = 0x40  // hlv: moderate brightness
            let ret = IOHIDDeviceSetReport(led, kIOHIDReportTypeFeature, CFIndex(buf[0]), &buf, buf.count)
            // logger.debug("\(name, privacy: .public): setRingLED CintiqV1 slot=\(index) ledByte=0x\(String(ledByte, radix: 16)) ret=\(ret, privacy: .public)")

        default:
            break
        }
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

    /// Send feature init to activate the digitizer endpoint.
    /// Assumes caller is on the main thread (IOHIDDeviceSetReport is not thread-safe).
    private func sendFeatureInit() {
        sendFeatureInit(to: device)
    }

    private func sendFeatureInit(to target: IOHIDDevice) {
        guard var bytes = deviceSpec.featureInit else { return }
        let reportID = CFIndex(bytes[0])
        IOHIDDeviceSetReport(target, kIOHIDReportTypeFeature, reportID, &bytes, bytes.count)
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
                    buttonCount: pairedSpec.buttonCount)
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
                        // Send feature init now that the RF link is confirmed.
                        // Must be dispatched to main thread — HID callbacks are background.
                        Task { @MainActor in
                            self.sendFeatureInit()
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
            case .toolCompatibility(let message):
                logger.info("\(name, privacy: .public): \(message, privacy: .public)")
            }
        }
    }
}
