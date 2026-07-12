// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid
import OSLog
import TabletKit

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "driver")

/// Data-driven tablet driver backed by a `TabletReportDecoder` selected at init time.
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
    /// Called once when the wireless dongle's 0x80 status report reveals the
    /// paired tablet's PID (e.g. 0x0316 for PTH-651). Fires once per RF link
    /// session on HIDThread.
    private let onPairedPID: ((Int) -> Void)?
    /// Called once per touch frame for devices that report capacitive finger
    /// touch.  No decoder produces these yet — wired so the integration
    /// surface is ready when a per-family touch decoder lands.
    private let onTouch: (([TouchContact]) -> Void)?
    /// Called when the hardware serial is successfully queried from a WACOM_REPORT_USB
    /// (Report ID 0x03) feature report on USB/dongle connections. Serial is 0 if the
    /// query fails or the device does not support the feature report.
    private let onHardwareSerial: ((UInt32) -> Void)?

    private var decoder: any TabletReportDecoder
    private var state = DecoderState()
    private var reportBuffer: [UInt8]
    private var isBluetooth = false

    // ── Callback-context lifetime ─────────────────────────────────────────────
    // One retain backs every IOHIDDeviceRegisterInputReportCallback context for
    // this driver. Created lazily at first registration, released on HIDThread
    // after close() has unregistered every interface — the release runs behind
    // any in-flight callback on the same run loop, so use-after-free is
    // impossible. Previously each registration called passRetained with no
    // balancing release, leaking the driver (and its buffers) on every
    // connect/disconnect cycle.
    private var selfRetain: Unmanaged<WacomKnownDevice>?
    /// Every interface handed to registerDevice(), so close() can unregister
    /// them all (it previously only handled the primary and one secondary).
    private var registeredInterfaces: [IOHIDDevice] = []

    private func callbackContext() -> UnsafeMutableRawPointer {
        if let retain = selfRetain { return retain.toOpaque() }
        let retain = Unmanaged.passRetained(self)
        selfRetain = retain
        return retain.toOpaque()
    }

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
    /// Per-slot custom dial colors pushed from settings via setRingLEDColors
    /// (Xencelabs Quick Keys only). nil entries fall back to the factory palette.
    private var dialSlotColors: [(r: UInt8, g: UInt8, b: UInt8)?] = []

    /// The Xencelabs Quick Keys/Pen Tablet family enumerates as several separate
    /// IOHIDDevices for one physical product (digitizer usage page 0x0D/0x02,
    /// generic-desktop mouse usage page 0x01/0x02, and the real vendor tunnel
    /// on usage page 0xFF0A — see XencelabsDecoder's header comment). Only the
    /// vendor-page interface ever carries real reports; the others sit in
    /// mouse-emulation/decorative-digitizer modes. `handleReport` doesn't know
    /// which physical interface delivered a report, so registering the decode
    /// callback on the non-vendor interfaces let their unrelated HID traffic
    /// (real mouse button/motion bytes) get run through XencelabsDecoder,
    /// which occasionally produced a report starting with byte 0x02 (the pen
    /// report ID) — misdecoded as an aux frame with an arbitrary express-key
    /// bit set, and never released since no matching "up" report ever arrives
    /// on that channel. Confirmed 2026-07-05: a modifier stuck permanently on
    /// with no corresponding physical press.
    private static let xencelabsVendorUsagePage = 0xFF0A

    private func acceptsReports(from candidate: IOHIDDevice) -> Bool {
        guard deviceSpec.parser == .xencelabs else { return true }
        return hidIntProperty(candidate, kIOHIDPrimaryUsagePageKey)
            == Self.xencelabsVendorUsagePage
    }

    // ── Wireless dongle (ACK-40401) support ──────────────────────────────────
    // When isWireless is true, pen events are suppressed until the RF link is
    // confirmed by a 0x80 wireless status report (d[1] bit 0 set = connected).
    // On link-up the decoder state is reset and the feature init is re-sent once.
    // On link-lost the gate closes again so stale reports from a dropped connection are not forwarded.
    private let isWireless: Bool
    private var wirelessReady: Bool = false
    /// PID of the dongle's paired tablet whose spec is currently applied.
    /// 0 until the first 0x80 status report identifies the tablet.
    private var pairedPID: Int = 0
    /// True after the first .active status for this RF link session.
    /// Prevents resending feature init on subsequent status reports.
    private var wirelessLinkConfirmed: Bool = false

    // ── Xencelabs wireless dongle (PID 0x5203) relink ────────────────────────
    // Confirmed 2026-07-06: the dongle only relays a paired puck's live 0xF0
    // aux data once the driver re-sends the tablet-mode init
    // ([0x02, 0xB0, 0x04]) with the puck's own 6-byte hardware identifier
    // appended at offset 10-15 — without it the dongle sits sending
    // connect-time status frames (tags 0xF8/0xF2) forever and never
    // upgrades to real button data. That identifier isn't available from any
    // GetReport call or from the dongle's own descriptors — but the puck
    // broadcasts it unprompted, unconditionally, in the trailer of every
    // single report it sends (status or real data alike, over the dongle
    // *and* direct USB), so we can read it off the wire instead of needing
    // any prior pairing record. One-shot per dongle connection.
    private var xencelabsDongleRelinked = false
    /// True once the OLED/dial-LED state has been resent after confirming
    /// the relink actually took (see the `.aux` case in `handleReport`).
    private var xencelabsPostRelinkResynced = false
    /// The puck's 6-byte identity read off the relink report, kept so the
    /// resync's label-reset write can address the same puck.
    private var xencelabsDongleIdentity: [UInt8]?

    /// Devices whose report-2 tunnel can relay a wireless Quick Keys puck and
    /// therefore need the relink/re-arm/resync handling: the standalone USB
    /// dongle, and the Pen Display — no radio of its own, but when the dongle
    /// sits in the display's USB slot the display firmware aggregates the
    /// puck traffic into its own vendor tunnel (confirmed 2026-07-08 via two
    /// discovery captures — 0xF8/0xF2 status frames with the puck's identity
    /// trailer, plus live 0xF0 aux data, all arriving on 0x520D).
    private static let xencelabsRelayProductIDs: Set<Int> = [0x5203, 0x520D]
    private static let xencelabsIdentityOffset = 10
    private static let xencelabsIdentityLength = 6

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
        onTouch: (([TouchContact]) -> Void)? = nil,
        onPairedPID: ((Int) -> Void)? = nil
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
        self.onPairedPID = onPairedPID

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
        case .bamboo:    self.decoder = BambooDecoder()     // CTL/CTH-xxx (experimental)
        case .cintiqV1:  self.decoder = CintiqV1Decoder()   // Cintiq pen-displays
        case .graphire:  self.decoder = GraphireDecoder()   // Graphire/PenPartner (experimental)
        case .xencelabs: self.decoder = XencelabsDecoder()  // Xencelabs Pen Tablet (experimental)
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
            // Wacom only — Xencelabs firmware never answers report 0x03, and the
            // synchronous IOHIDDeviceGetReport blocks the main thread ~4–5 s
            // (beachball on connect) waiting for the kernel HID timeout.
            if deviceSpec.parser != .xencelabs {
                queryHardwareSerial()
            } else {
                onHardwareSerial?(0)
            }
        }

        if acceptsReports(from: device) {
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                device, &reportBuffer, reportBuffer.count,
                WacomKnownDevice.reportCallback, callbackContext())
        } else {
            logger.info("\(name, privacy: .public): primary interface is not the vendor tunnel — decode disabled on it, waiting for the real interface via registerDevice()")
        }
        IOHIDDeviceScheduleWithRunLoop(
            device, HIDThread.shared.runLoop, RunLoop.Mode.common.rawValue as CFString)
    }

    /// Register an additional IOHIDDevice (interface) for report delivery.
    /// Used for multi-interface devices (e.g. ACK-40401 wireless dongle) that
    /// enumerate separate IOHIDDevices for each interface (digitizer, wireless status, etc).
    func registerDevice(_ device: IOHIDDevice) {
        registeredInterfaces.append(device)
        if acceptsReports(from: device) {
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                device, &reportBuffer, reportBuffer.count,
                WacomKnownDevice.reportCallback, callbackContext())
        }
        IOHIDDeviceScheduleWithRunLoop(
            device, HIDThread.shared.runLoop, RunLoop.Mode.common.rawValue as CFString)
        let transport =
            IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        let name = deviceSpec.name
        logger.info("\(name, privacy: .public): registered interface (transport=\(transport, privacy: .public))\(self.acceptsReports(from: device) ? "" : " — non-vendor interface, decode disabled on it")")
        // Xencelabs: only the vendor-tunnel interface should ever become
        // secondaryDevice, since that's the one hidSetReport (OLED/dial LED)
        // needs to target. Non-vendor interfaces are tracked for cleanup only.
        if deviceSpec.parser == .xencelabs {
            if acceptsReports(from: device) { secondaryDevice = device }
        } else if secondaryDevice == nil {
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

        // Xencelabs re-enumerates shortly after the initial connect (observed
        // 2026-07-01: ~5s after "opened", a second IOHIDDevice arrives for the
        // same PID and lands here instead of deviceConnected). The original
        // device's tablet-mode init was addressed to the now-superseded
        // handle, so the live interface never actually left mouse-emulation
        // mode. Re-run init against the interface that's actually live.
        if deviceSpec.parser == .xencelabs && !isBluetooth && acceptsReports(from: device) {
            executeInitSteps(on: device)
            // The fresh firmware state lost any OLED text and dial color the
            // superseded handle received. Re-apply the LED now; dropping the
            // text cache lets the next display push actually resend.
            xencelabsSentText.removeAll()
            setRingLED(index: pendingLEDIndex)
        }
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(
            device, HIDThread.shared.runLoop, RunLoop.Mode.common.rawValue as CFString)
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(
            device, &reportBuffer, reportBuffer.count, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if let led = ledDevice {
            IOHIDDeviceClose(led, IOOptionBits(kIOHIDOptionsTypeNone))
            ledDevice = nil
        }
        // Unregister every secondary interface (registerDevice may have been
        // called more than once for multi-interface devices).
        for sec in registeredInterfaces {
            IOHIDDeviceUnscheduleFromRunLoop(sec, HIDThread.shared.runLoop, RunLoop.Mode.common.rawValue as CFString)
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(sec, &reportBuffer, reportBuffer.count, nil, nil)
        }
        registeredInterfaces.removeAll()
        if let sec = secondaryDevice {
            IOHIDDeviceClose(sec, IOOptionBits(kIOHIDOptionsTypeNone))
            secondaryDevice = nil
        }
        // Balance the callback-context retain. Deferred to HIDThread so it runs
        // after any callback already executing there; nothing can re-enter the
        // callbacks afterwards because every registration was cleared above.
        if let retain = selfRetain {
            selfRetain = nil
            CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) {
                retain.release()
            }
            CFRunLoopWakeUp(HIDThread.shared.runLoop)
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
            // Wacom driver (6.3.46-2) on PTH-660 (PID 0x0357) and PTH-860 (PID 0x0358):
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
            // The Linux kernel's wacom_led_control() switches report format
            // once the device is reached through the ACK-40401 wireless
            // dongle rather than direct USB:
            //   - Wired:    Report ID 0x20 (WAC_CMD_LED_CONTROL), 9 bytes.
            //   - Wireless: Report ID 0x03 (WAC_CMD_WL_LED_CONTROL), 13 bytes.
            // Only the wired format has been confirmed against real hardware
            // (see below); the wireless branch is unverified against a real
            // ACK-40401 dongle and sent best-effort so a rejected report
            // can't surface as a user-facing error.
            if isWireless && pairedPID > 0 {
                // Wireless dongle: WAC_CMD_WL_LED_CONTROL, 13-byte feature report.
                // Format from kernel wacom_sys.c (INTUOS5 branch), unverified here:
                //   buf[0] = 0x03
                //   buf[4] = (cropLum << 4) | (ringLum << 2) | ringSlot
                //     bits[1:0] = ring LED slot (0–3)
                //     bits[3:2] = ring luminance (0=low … 3=off)
                //     bits[5:4] = crop-mark luminance (same encoding, usually 0)
                let slot = UInt8(index & 0x03)
                let ringLum: UInt8 = 1  // medium
                var buf = [UInt8](repeating: 0, count: 13)
                buf[0] = 0x03  // WAC_CMD_WL_LED_CONTROL
                buf[4] = (ringLum << 2) | slot
                hidSetReport(device, reportID: CFIndex(buf[0]), bytes: &buf,
                             tag: "\(name) IntuosV1 WL LED slot=\(index)", severity: .bestEffort, log: logger)
            } else {
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
            }

        case .xencelabs:
            // Quick Keys dial LED: vendor output report 0xB4 sub-op 0x01 with
            // literal RGB (see XencelabsControl). Colors follow Xencelabs'
            // own per-mode factory palette so the ring reads the same way it
            // does under their software. Best-effort: the Pen Display has no
            // dial and ignores/rejects the write harmlessly.
            //
            // Dongle-relayed dongle/puck traffic must carry the puck's 6-byte
            // identity in the address field or the dongle has nothing to
            // route the write to — confirmed 2026-07-07 via dtrace on
            // XencelabsDriver: every 0xB4/0xB1 write it sends over the dongle
            // carries the identity, none carry an all-zero address.
            let address = xencelabsDongleIdentity ?? []
            // Reassert upright screen orientation, as the vendor stack does
            // during its own reconnect init. Sending anything else here
            // visibly rotates the OLED text (confirmed on hardware).
            sendXencelabsOutput(
                XencelabsControl.orientationPayload(rotationSteps: 0, address: address),
                tag: "screen orientation upright")
            let colors = XencelabsControl.defaultSlotColors
            let custom = dialSlotColors.indices.contains(index) ? dialSlotColors[index] : nil
            let c = custom ?? colors[((index % colors.count) + colors.count) % colors.count]
            sendXencelabsOutput(
                XencelabsControl.dialColorPayload(r: c.r, g: c.g, b: c.b, address: address),
                tag: "dial LED slot=\(index)")
            // The native driver always pairs a dial-color write with a
            // sensitivity write (0xB4 sub-op 0x04); we'd never sent this one
            // before. Default matches the vendor default of 3.
            sendXencelabsOutput(
                XencelabsControl.dialSensitivityPayload(3, address: address),
                tag: "dial sensitivity slot=\(index)")

        default:
            break
        }
    }

    // MARK: - Xencelabs OLED / dial output

    /// Last text pushed per OLED field+index, to suppress redundant writes —
    /// the settings pipeline re-fires on every settings change, and the OLED
    /// only needs traffic when something it shows actually changed.
    private var xencelabsSentText: [String: String] = [:]

    /// Adopt per-slot custom dial colors (nil = factory palette) and re-send
    /// the active slot's color if anything changed. Deduped here because the
    /// settings pipeline re-fires this on every settings change.
    func setRingLEDColors(_ colors: [(r: UInt8, g: UInt8, b: UInt8)?]) {
        guard deviceSpec.parser == .xencelabs else { return }
        guard !dialSlotColors.elementsEqual(colors, by: { a, b in
            a?.r == b?.r && a?.g == b?.g && a?.b == b?.b
        }) else { return }
        dialSlotColors = colors
        setRingLED(index: pendingLEDIndex)
    }

    /// Show the active dial mode's name on the Quick Keys OLED mode line.
    func setRingModeLabel(_ label: String) {
        guard deviceSpec.parser == .xencelabs else { return }
        guard xencelabsSentText["mode"] != label else { return }
        xencelabsSentText["mode"] = label
        for payload in XencelabsControl.textPayloads(
            field: .modeName, text: label, address: xencelabsDongleIdentity ?? [])
        {
            sendXencelabsOutput(payload, tag: "OLED mode label")
        }
    }

    /// Sync per-key labels (labels[0] = key 1) to the Quick Keys OLED.
    func setAuxKeyLabels(_ labels: [String]) {
        guard deviceSpec.parser == .xencelabs else { return }
        let joined = labels.joined(separator: "\u{1F}")
        guard xencelabsSentText["keys"] != joined else { return }
        xencelabsSentText["keys"] = joined
        for payload in XencelabsControl.keyLabelPayloads(labels, address: xencelabsDongleIdentity ?? []) {
            sendXencelabsOutput(payload, tag: "OLED key labels")
        }
    }

    /// Panel brightness is exposed on Xencelabs pen displays via the vendor
    /// 0xB5 display-control frame family (see XencelabsControl).
    var hasDisplayBrightnessControl: Bool {
        deviceSpec.parser == .xencelabs && deviceSpec.isPenDisplay
    }

    /// Last panel brightness sent, to suppress redundant writes while a
    /// slider drags.
    private var lastDisplayBrightness: Int = -1

    /// Set the pen display's panel backlight brightness (0–100).
    func setDisplayBrightness(_ percent: Int) {
        guard hasDisplayBrightnessControl else { return }
        let clamped = min(max(percent, 0), 100)
        guard clamped != lastDisplayBrightness else { return }
        lastDisplayBrightness = clamped
        sendXencelabsOutput(
            XencelabsControl.displayBrightnessPayload(
                UInt8(clamped), address: xencelabsDongleIdentity ?? []),
            tag: "panel brightness \(clamped)")
    }

    /// Last panel contrast sent, to suppress redundant writes during a drag.
    private var lastDisplayContrast: Int = -1

    /// Set the pen display's panel contrast (0–100). Same 0xB5 control family
    /// as brightness (see XencelabsControl.DisplayControl).
    func setDisplayContrast(_ percent: Int) {
        guard hasDisplayBrightnessControl else { return }
        let clamped = min(max(percent, 0), 100)
        guard clamped != lastDisplayContrast else { return }
        lastDisplayContrast = clamped
        sendXencelabsOutput(
            XencelabsControl.displayContrastPayload(
                UInt8(clamped), address: xencelabsDongleIdentity ?? []),
            tag: "panel contrast \(clamped)")
    }

    /// Last gamma sent (as gamma × 10), to suppress redundant writes.
    private var lastDisplayGamma: Int = -1

    /// Set the pen display's gamma, passed as gamma × 10 (e.g. 22 = 2.2).
    func setDisplayGamma(_ gammaTimesTen: Int) {
        guard hasDisplayBrightnessControl else { return }
        let clamped = min(max(gammaTimesTen, 0), 255)
        guard clamped != lastDisplayGamma else { return }
        lastDisplayGamma = clamped
        sendXencelabsOutput(
            XencelabsControl.displayGammaPayload(
                UInt8(clamped), address: xencelabsDongleIdentity ?? []),
            tag: "panel gamma \(clamped)")
    }

    /// Last color-mode index sent, to suppress redundant writes.
    private var lastColorMode: Int = -1

    /// Select one of the panel's built-in color-space presets (Adobe RGB,
    /// sRGB, REC 709, DCI-P3, REC 2020, Pantone, Custom), by row index (0 =
    /// Adobe RGB ... 6 = Custom, matching `DisplayMappingView.colorModeChoices`).
    ///
    /// Empirically confirmed 2026-07-12 by cycling MockTab's list against the
    /// vendor driver's own preset selector on the same panel: wire byte 0
    /// isn't a valid preset (it produced the original "too dark/warm" Adobe
    /// RGB bug), and every named preset is one byte higher than its row
    /// index — Adobe RGB=1, sRGB=2, REC 709=3, DCI-P3=4, REC 2020=5,
    /// Pantone=6, Custom presumed=7 (untested — one past anything we'd sent
    /// before this fix, consistent with never having matched Pantone).
    ///
    /// Followed by the apply-batch commit frame the vendor also sends after
    /// a preset switch — without it, a prior stray gamma/contrast write can
    /// linger on the panel instead of being reset to the new preset's own
    /// stored values (found 2026-07-12 comparing against the vendor driver).
    func setColorMode(_ index: Int) {
        guard hasDisplayBrightnessControl else { return }
        guard index != lastColorMode else { return }
        lastColorMode = index
        let address = xencelabsDongleIdentity ?? []
        sendXencelabsOutput(
            XencelabsControl.colorModePayload(UInt8(index + 1), address: address),
            tag: "panel color mode \(index)")
        sendXencelabsOutput(
            XencelabsControl.displayCommitPayload(address: address),
            tag: "panel color mode commit")
    }

    /// Send the tablet-mode relink handshake ([0x02, 0xB0, 0x04] with the
    /// puck's identity appended) to the dongle's vendor interface, padded to
    /// the declared output size. Used at first sight of the puck and again
    /// after its ~5 s wake window (see the relink block in `handleReport`).
    @discardableResult
    private func sendXencelabsRelink(identity: [UInt8]) -> IOReturn {
        let target = secondaryDevice ?? device
        var relink: [UInt8] = [0x02, 0xB0, 0x04, 0, 0, 0, 0, 0, 0, 0] + identity
        let declared = hidIntProperty(target, kIOHIDMaxOutputReportSizeKey)
        if declared > relink.count {
            relink += [UInt8](repeating: 0, count: declared - relink.count)
        }
        paceXencelabsWrite()
        return hidSetReport(
            target, type: kIOHIDReportTypeOutput, reportID: CFIndex(relink[0]),
            bytes: &relink, tag: "\(deviceSpec.name) dongle relink", log: logger)
    }

    /// Resend the ring LED and OLED labels once a dongle relink is confirmed
    /// live. `setRingLED` has no dedup, so it's safe to call as-is; the OLED
    /// label setters dedup against `xencelabsSentText`, so that cache is
    /// cleared first to force the resend of whatever was last requested.
    private func resyncXencelabsOutputsAfterRelink() {
        // What captures showed as a "reset labels" write here (0xB1 0x01)
        // is really the screen orientation command set to upright —
        // `setRingLED` below reasserts it, so no separate write is needed.
        // The three extra opcodes in every native resync capture turned
        // out to be status GET polls (0xB4 0x08 sleep time, 0xB4 0x10
        // battery, 0xB1 0x0A OLED brightness; byte 3 = 0x01 set / 0x00
        // get) — decoded 2026-07-10 from the vendor agent's disassembly.
        // Replaying them is kept: they're cheap, present in every native
        // capture, and may double as wake pokes during the reconnect
        // window.
        if let identity = xencelabsDongleIdentity {
            sendXencelabsOutput([0x02, 0xB4, 0x08, 0, 0, 0, 0, 0, 0, 0] + identity, tag: "sleep-time poll")
            sendXencelabsOutput([0x02, 0xB4, 0x10, 0, 0, 0, 0, 0, 0, 0] + identity, tag: "battery poll")
            sendXencelabsOutput([0x02, 0xB1, 0x0A, 0, 0, 0, 0, 0, 0, 0] + identity, tag: "OLED brightness poll")
        }
        let ledIndex = pendingLEDIndex
        let modeLabel = xencelabsSentText["mode"]
        let keysJoined = xencelabsSentText["keys"]
        xencelabsSentText.removeAll()
        setRingLED(index: ledIndex)
        if let modeLabel { setRingModeLabel(modeLabel) }
        if let keysJoined { setAuxKeyLabels(keysJoined.components(separatedBy: "\u{1F}")) }
    }

    /// Uptime of the most recent Xencelabs vendor write, for pacing.
    private var lastXencelabsWriteUptime: UInt64 = 0

    /// Space vendor writes at least 3 ms apart. The vendor stack sleeps
    /// after every frame it sends (3 ms in its driver's color path, 1.3 ms
    /// between OLED label chunks, 10 ms between the color/sensitivity/label
    /// blocks on an app change — confirmed 2026-07-10 by disassembling
    /// XencelabsAgent/XencelabsDriver). The firmware silently drops output
    /// reports that arrive while it is busy repainting, and the transport
    /// still returns success, so back-to-back writes "succeed" without ever
    /// reaching the display.
    private func paceXencelabsWrite() {
        let gap: UInt64 = 3_000_000  // 3 ms in nanoseconds
        let now = DispatchTime.now().uptimeNanoseconds
        if lastXencelabsWriteUptime != 0 {
            let elapsed = now &- lastXencelabsWriteUptime
            if elapsed < gap {
                usleep(UInt32((gap - elapsed) / 1_000))
            }
        }
        lastXencelabsWriteUptime = DispatchTime.now().uptimeNanoseconds
    }

    /// Send a Xencelabs vendor output report, zero-padded to the device's
    /// declared MaxOutputReportSize (short writes return success but are
    /// silently ignored by this firmware — same rule as the init path).
    private func sendXencelabsOutput(_ bytes: [UInt8], tag: String) {
        // `device` is fixed at construction to whichever interface arrived
        // first — for Quick Keys that's usually the decorative digitizer
        // interface, not the vendor tunnel (0xFF0A). `secondaryDevice` is
        // updated in registerDevice() to the vendor interface once it's seen
        // (see acceptsReports(from:)), so prefer it here; this was still
        // pointed at the wrong interface even after that fix landed, which is
        // why OLED/dial-LED writes kept failing with 0xe0005000. Confirmed
        // 2026-07-05.
        let target = (deviceSpec.parser == .xencelabs ? secondaryDevice : nil) ?? device
        let declared = hidIntProperty(target, kIOHIDMaxOutputReportSizeKey)
        var padded = bytes
        if declared > padded.count {
            padded += [UInt8](repeating: 0, count: declared - padded.count)
        }
        paceXencelabsWrite()
        hidSetReport(target, type: kIOHIDReportTypeOutput,
                     reportID: CFIndex(padded[0]), bytes: &padded,
                     tag: "\(deviceSpec.name) \(tag)", severity: .bestEffort, log: logger)
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
    private func executeInitSteps(from index: Int = 0, on target: IOHIDDevice? = nil) {
        let device = target ?? self.device
        let steps = deviceSpec.initSteps
        guard index < steps.count else { return }
        switch steps[index] {
        case .featureReport(var bytes):
            let reportID = CFIndex(bytes[0])
            hidSetReport(device, reportID: reportID, bytes: &bytes,
                         tag: "\(deviceSpec.name) initStep[\(index)]", log: logger)
            executeInitSteps(from: index + 1, on: target)
        case .outputReport(var bytes):
            // Vendor tablet-mode init over the HID output pipe (Xencelabs:
            // [0x02, 0xB0, 0x04]). Confirmed 2026-07-01 on a Pen Display: a
            // raw short write reports kIOReturnSuccess at the transport level
            // but the firmware silently ignores it — no report ID 7 ever
            // arrives afterward. Pad to the device's declared
            // MaxOutputReportSize up front rather than treating that as a
            // fallback-on-failure retry, since a successful-but-ignored write
            // never triggers the retry path.
            let reportID = CFIndex(bytes[0])
            let declared = hidIntProperty(device, kIOHIDMaxOutputReportSizeKey)
            let name = deviceSpec.name
            let ret: IOReturn
            if declared > bytes.count {
                var padded = bytes + [UInt8](repeating: 0, count: declared - bytes.count)
                ret = hidSetReport(
                    device, type: kIOHIDReportTypeOutput, reportID: reportID,
                    bytes: &padded,
                    tag: "\(name) initStep[\(index)] output padded to \(declared)",
                    log: logger)
            } else {
                ret = hidSetReport(
                    device, type: kIOHIDReportTypeOutput, reportID: reportID,
                    bytes: &bytes, tag: "\(name) initStep[\(index)] output",
                    log: logger)
            }
            // hidSetReport only logs on failure — log the outcome unconditionally
            // here, since "no error" has been ambiguous with "never ran."
            let hex = String(format: "0x%08x", ret)
            logger.info("\(name, privacy: .public): initStep[\(index, privacy: .public)] output report result=\(hex, privacy: .public)")
            executeInitSteps(from: index + 1, on: target)
        case .delay(let seconds):
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.executeInitSteps(from: index + 1, on: target)
            }
        case .stringDescriptor:
            // Not yet wired up (Huion); advance to keep the sequence moving.
            executeInitSteps(from: index + 1, on: target)
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

    private static let reportCallback: IOHIDReportWithTimeStampCallback = { ctx, _, sender, _, _, report, length, timestamp in
        guard let ctx else { return }
        // Kernel-receipt → here. Spikes mean the scheduler starved HIDThread.
        LatencyProbe.shared.record(kernelTimestamp: timestamp)
        let senderDevice = sender.map { Unmanaged<IOHIDDevice>.fromOpaque($0).takeUnretainedValue() }
        Unmanaged<WacomKnownDevice>.fromOpaque(ctx).takeUnretainedValue()
            .handleReport(report: report, length: length, sender: senderDevice)
    }

    // MARK: - Report dispatch

    private func handleReport(report: UnsafePointer<UInt8>, length: CFIndex, sender: IOHIDDevice? = nil) {
        let name = deviceSpec.name
        HIDCapture.shared.record(tag: name, report: report, length: length)
        // Delta capture — only fires when CaptureEngine.isRunning is true.
        if CaptureEngine._isRunningNonisolated {
            let r0 = report[0]
            let bytes = [UInt8](UnsafeBufferPointer(start: report, count: length))
            Task { @MainActor in
                CaptureEngine.shared.recordSample(reportID: r0, data: bytes)
            }
        }
        // For wireless dongles, extract paired tablet PID from 0x80 status report and
        // use its spec for accurate coordinate ranges (instead of fallback guesses).
        if isWireless && length >= 8 && report[0] == 0x80 && (report[1] & 0x01) != 0 {
            let pairedTabletPID = Int(UInt16(report[7]) | UInt16(report[6]) << 8)  // Big-endian
            if pairedTabletPID > 0, pairedTabletPID != pairedPID,
                let pairedSpec = WacomDeviceRegistry.spec(for: pairedTabletPID),
                pairedSpec.maxX > 0 && pairedSpec.maxY > 0
            {
                // Update our spec with the paired tablet's actual dimensions
                spec = DigitizerSpec(
                    maxX: pairedSpec.maxX,
                    maxY: pairedSpec.maxY,
                    maxPressure: pairedSpec.maxPressure,
                    buttonCount: pairedSpec.buttonCount,
                    hasTilt: pairedSpec.hasTilt,
                    hasDualRings: pairedSpec.hasDualRings,
                    isPenDisplay: pairedSpec.isPenDisplay,
                    ringSlotCount: pairedSpec.ringSlotCount,
                    hasFingerTouch: pairedSpec.hasFingerTouch,
                    maxTouchContacts: pairedSpec.maxTouchContacts)
                pairedPID = pairedTabletPID
                onPairedPID?(pairedTabletPID)
                logger.info("\(name, privacy: .public): paired tablet 0x\(String(pairedTabletPID, radix: 16, uppercase: true), privacy: .public) — maxX=\(pairedSpec.maxX, privacy: .public) maxY=\(pairedSpec.maxY, privacy: .public) maxPressure=\(pairedSpec.maxPressure, privacy: .public)")
            }
        }

        // Puck power-cycle detection: the dongle emits status frames (tags
        // 0xF8/0xF2) only while a paired puck is present but not yet upgraded
        // to live aux data — the state a puck lands in when its power switch
        // is cycled while the dongle stays enumerated. Seeing one *after* a
        // successful relink therefore means the puck restarted and lost the
        // tablet-mode handshake (and its OLED/LED state); re-arm the one-shot
        // latches so the block below re-sends both. Without this, only
        // reseating the dongle (fresh WacomKnownDevice, fresh latches)
        // recovered the puck — the power switch alone left it dead.
        if deviceSpec.parser == .xencelabs, Self.xencelabsRelayProductIDs.contains(deviceSpec.productID),
            xencelabsDongleRelinked, length >= 2, report[0] == 0x02,
            report[1] == 0xF8 || report[1] == 0xF2
        {
            logger.info("\(name, privacy: .public): dongle status frame after relink (tag=0x\(String(report[1], radix: 16), privacy: .public)) — puck restarted, re-arming relink")
            xencelabsDongleRelinked = false
            xencelabsPostRelinkResynced = false
        }

        // Xencelabs wireless dongle relink: send the tablet-mode init once
        // with the puck's own identifier appended, read straight off this
        // report's trailer (see the property doc above). Any report ID 0x02
        // frame of at least this length carries it once a puck is paired,
        // including the connect-time status frames that arrive before real
        // aux data flows.
        if deviceSpec.parser == .xencelabs, Self.xencelabsRelayProductIDs.contains(deviceSpec.productID),
            !xencelabsDongleRelinked, length >= Self.xencelabsIdentityOffset + Self.xencelabsIdentityLength,
            report[0] == 0x02  // XencelabsDecoder.penReportID (internal, not visible here)
        {
            let identity = (0..<Self.xencelabsIdentityLength).map {
                report[Self.xencelabsIdentityOffset + $0]
            }
            if identity.contains(where: { $0 != 0 }) {
                xencelabsDongleRelinked = true
                xencelabsDongleIdentity = identity
                let ret = sendXencelabsRelink(identity: identity)
                logger.info("\(name, privacy: .public): dongle relink sent, result=0x\(String(ret, radix: 16), privacy: .public)")
                // Previously this waited for the first real aux frame to prove
                // the link was live before resending OLED/LED state, because
                // those writes went out unaddressed and had nowhere reliable
                // to land. Now that they carry the puck's identity (see
                // XencelabsControl call sites above), a successful relink
                // write is enough — resyncing here means the display is
                // correct immediately instead of only after the user
                // happens to press a button. Confirmed 2026-07-07: still
                // one-shot per dongle connection via xencelabsPostRelinkResynced.
                if ret == kIOReturnSuccess, !xencelabsPostRelinkResynced {
                    xencelabsPostRelinkResynced = true
                    resyncXencelabsOutputsAfterRelink()
                    // A power-cycled puck accepts the relink while its firmware
                    // is still waking (measured ~5.25 s to logo + "Please
                    // connect" text), so the immediate handshake and resync
                    // above land in the void — buttons come back but the puck
                    // still believes it's unconnected and shows a stale
                    // display, looking like a failed handshake. Repeat the
                    // *full* relink + display resync after the wake window
                    // passes (all writes addressed and idempotent; at
                    // dongle-connect time, when the puck is already awake,
                    // the repeats are harmless).
                    for delay in [6.5, 10.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self, self.xencelabsPostRelinkResynced,
                                let identity = self.xencelabsDongleIdentity else { return }
                            let ret = self.sendXencelabsRelink(identity: identity)
                            logger.info("\(self.deviceSpec.name, privacy: .public): post-wake relink retry (+\(delay, privacy: .public)s), result=0x\(String(ret, radix: 16), privacy: .public)")
                            self.resyncXencelabsOutputsAfterRelink()
                        }
                    }
                }
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
                // Diagnostic for the Xencelabs stuck-Command investigation (2026-07-05):
                // log which physical device/PID produced this aux frame and the raw
                // bytes that decoded to it, so a phantom button-down can be traced back
                // to its source instead of guessed at. Remove once resolved.
                if deviceSpec.parser == .xencelabs {
                    let hex = (0..<length).map { String(format: "%02x", report[$0]) }.joined(separator: " ")
                    let mask = (0..<16).map { buttons[$0] ? "1" : "0" }.joined()
                    let pidHex = String(deviceSpec.productID, radix: 16, uppercase: true)
                    let usagePage = sender.map { String(hidIntProperty($0, kIOHIDPrimaryUsagePageKey), radix: 16) } ?? "?"
                    logger.notice("\(name, privacy: .public) (0x\(pidHex, privacy: .public)) usagePage=0x\(usagePage, privacy: .public): aux decode — bytes=[\(hex, privacy: .public)] mask=\(mask, privacy: .public) mech=0x\(String(buttons.mechanicalMask, radix: 16), privacy: .public)")
                }
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
