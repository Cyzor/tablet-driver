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

/// Data-driven tablet driver backed by a `WacomDecoder` selected at init time.
///
/// Replaces per-device Swift classes for any product in `WacomDeviceRegistry`
/// whose parser family has a live decoder (IntuosV1, IntuosV2, Intuos3).
/// Supports both USB and Bluetooth transports; BLE/BT skips USB feature inits.
final class WacomUniversalDevice: TabletDevice {

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

    private var decoder: any WacomDecoder
    private var state = DecoderState()
    private var reportBuffer: [UInt8]
    private var isBluetooth = false

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
        onMouseButton: ((UInt8) -> Void)? = nil
    ) {
        self.isWireless = isWireless
        self.device = device
        self.deviceSpec = deviceSpec
        self.seize = seize
        self.onTablet = onTablet
        self.onAux = onAux
        self.onToolEnter = onToolEnter
        self.onMouseButton = onMouseButton

        self.spec = DigitizerSpec(
            maxX: deviceSpec.maxX,
            maxY: deviceSpec.maxY,
            maxPressure: deviceSpec.maxPressure,
            buttonCount: deviceSpec.buttonCount)

        switch deviceSpec.parser {
        case .intuosV2:
            self.decoder = IntuosV2Decoder()
        case .intuos3:
            self.decoder = Intuos3Decoder()
        case .bamboo:
            self.decoder = BambooDecoder()
        case .intuosV1, .graphire:
            // graphire should not reach here — caller checks hasLiveDecoder.
            self.decoder = IntuosV1Decoder()
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

        let options =
            seize
            ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            : IOOptionBits(kIOHIDOptionsTypeNone)
        let ret = IOHIDDeviceOpen(device, options)
        guard ret == kIOReturnSuccess else {
            let pid = String(deviceSpec.productID, radix: 16, uppercase: true)
            print(
                "\(deviceSpec.name) (0x\(pid)): failed to open (seize=\(seize)) — \(ret). "
                    + "Is another tablet driver running?")
            return
        }

        print("\(deviceSpec.name): opened (transport=\(transport))")

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
        }

        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count,
            WacomUniversalDevice.reportCallback, ctx)
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)
    }

    /// Register an additional IOHIDDevice (interface) for report delivery.
    /// Used for multi-interface devices (e.g. ACK-40401 wireless dongle) that
    /// enumerate separate IOHIDDevices for each interface (digitizer, wireless status, etc).
    func registerDevice(_ device: IOHIDDevice) {
        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count,
            WacomUniversalDevice.reportCallback, ctx)
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)
        let transport =
            IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        print("\(deviceSpec.name): registered interface (transport=\(transport))")
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(
            device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Send feature init to activate the digitizer endpoint.
    /// Assumes caller is on the main thread (IOHIDDeviceSetReport is not thread-safe).
    private func sendFeatureInit() {
        guard var bytes = deviceSpec.featureInit else { return }
        let reportID = CFIndex(bytes[0])
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, reportID, &bytes, bytes.count)
    }

    // MARK: - C callback

    private static let reportCallback: IOHIDReportCallback = { ctx, _, _, _, _, report, length in
        guard let ctx else { return }
        Unmanaged<WacomUniversalDevice>.fromOpaque(ctx).takeUnretainedValue()
            .handleReport(report: report, length: length)
    }

    // MARK: - Report dispatch

    private func handleReport(report: UnsafePointer<UInt8>, length: CFIndex) {
        HIDCapture.shared.record(tag: deviceSpec.name, report: report, length: length)

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
                        print("\(deviceSpec.name): wireless link active")
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
                        print("\(deviceSpec.name): wireless link lost")
                        wirelessLinkConfirmed = false
                    }
                    wirelessReady = false
                    state = DecoderState()
                case .lowBattery:
                    print("\(deviceSpec.name): battery critically low")
                case .unknown:
                    break
                }
            case .mouseButton(let mask):
                onMouseButton?(mask)
            case .toolCompatibility(let message):
                print("\(deviceSpec.name): \(message)")
            }
        }
    }
}
