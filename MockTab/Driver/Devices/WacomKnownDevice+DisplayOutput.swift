// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid
import OSLog
import TabletKit

// Same category as WacomKnownDevice.swift's; `private` is file-scoped, and
// each sibling driver file declares its own the same way.
private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "driver")

// Per-key OLED and LED output. Split out of WacomKnownDevice.swift, which had
// accumulated every vendor output path; the class and its behavior are
// unchanged. Stored state stays in the main file — extensions can't hold it.

extension WacomKnownDevice {

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
                // Sent to whichever registered interface actually declares Feature
                // reports (see `hasAnyFeatureReport`) — on a multi-interface unit
                // like PTH-850, `device` itself may be the touch/vendor interface,
                // which doesn't. Before that interface is known, `resyncActiveDriverDisplayState()`
                // can call this on connect and race ahead of it (confirmed live
                // 2026-08-25: the touch interface won primary, this fired against
                // it and failed, then `registerDevice()`'s retry corrected it 23ms
                // later once the pen interface registered) — downgrade to
                // best-effort in that specific window so the expected, self-correcting
                // miss doesn't log as an `.error`.
                let llv: UInt8 = 0x14
                let hlv: UInt8 = 0x01
                var buf = [UInt8](repeating: 0, count: 9)
                buf[0] = 0x20  // WAC_CMD_LED_CONTROL
                buf[1] = (llv & 0x1f) | (UInt8(index & 0x07) << 5)
                buf[2] = hlv & 0x1f
                hidSetReport(intuosV1CapableDevice ?? device, reportID: CFIndex(buf[0]), bytes: &buf,
                             tag: "\(name) IntuosV1 LED slot=\(index)",
                             severity: intuosV1CapableDevice == nil ? .bestEffort : .required, log: logger)
            }

        case .xencelabs:
            // Quick Keys dial LED: vendor output report 0xB4 sub-op 0x01 with
            // literal RGB (see XencelabsOutputProtocol). Colors follow Xencelabs'
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
                XencelabsOutputProtocol.orientationPayload(rotationSteps: 0, address: address),
                tag: "screen orientation upright")
            let colors = XencelabsOutputProtocol.defaultSlotColors
            let custom = dialSlotColors.indices.contains(index) ? dialSlotColors[index] : nil
            let c = custom ?? colors[((index % colors.count) + colors.count) % colors.count]
            sendXencelabsOutput(
                XencelabsOutputProtocol.dialColorPayload(r: c.r, g: c.g, b: c.b, address: address),
                tag: "dial LED slot=\(index)")
            // The native driver always pairs a dial-color write with a
            // sensitivity write (0xB4 sub-op 0x04); we'd never sent this one
            // before. Default matches the vendor default of 3.
            sendXencelabsOutput(
                XencelabsOutputProtocol.dialSensitivityPayload(3, address: address),
                tag: "dial sensitivity slot=\(index)")

        default:
            break
        }
    }
}
