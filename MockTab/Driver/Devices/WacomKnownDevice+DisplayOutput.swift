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

    /// Shows the active slot on the ring LED.
    func setRingLED(index: Int) {
        ThreadContract.expectPenThread()
        pendingLEDIndex = index
        let name = deviceSpec.name
        // `hidSetReport` only logs on failure, so a silent log can't tell a
        // write that succeeded from one that never happened. Record the
        // request itself: mode changes are user-paced, so this can't spam.
        logger.info(
            "\(name, privacy: .public): ring LED → slot \(index) (\(self.isBluetooth ? "BT" : "USB", privacy: .public))"
        )
        switch deviceSpec.format {
        case .intuosV2 where !isBluetooth:
            // Report 0x31 sets all LED channels' brightness (0x46), and 0x32
            // picks the slot after a fixed 0x46 byte. The hardware counts
            // from bottom left, so a four-slot ring adds 1 to put mode 1 at
            // top left.
            let ledByte = UInt8((index + (deviceSpec.ringSlotCount == 4 ? 1 : 0)) & 0x03)
            let r31: [UInt8] = [0x31, 0x46, 0x46, 0x46, 0x46, 0x46]
            queueSetReport(device, r31,
                           tag: "\(name) USB LED brightness", severity: .bestEffort)
            let r32: [UInt8] = [0x32, 0x46, ledByte]
            queueSetReport(device, r32,
                           tag: "\(name) USB LED slot=\(index)")

        case .intuosV2 where isBluetooth:
            // Report 0x82, 51 bytes: buf[1] = 0x02, buf[4...9] = channel
            // brightness, buf[10] = slot as over USB. A read returns the
            // serial in buf[11...18]; writes leave those zero.
            let ledByteBT = UInt8((index + (deviceSpec.ringSlotCount == 4 ? 1 : 0)) & 0x03)
            var buf = [UInt8](repeating: 0, count: 51)
            buf[0]  = 0x82
            buf[1]  = 0x02
            buf[4]  = 0x46; buf[5] = 0x46; buf[6] = 0x46
            buf[7]  = 0x46; buf[8] = 0x46; buf[9] = 0x46
            buf[10] = ledByteBT
            queueSetReport(device, buf,
                           tag: "\(name) BT LED ring slot=\(index)")

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
            queueSetReport(ledTarget, buf,
                           tag: "\(name) CintiqV1 LED slot=\(slot) (both rings)")

        case .intuosV1:
            if isWireless && pairedPID > 0 {
                // Through the ACK-40401: WAC_CMD_WL_LED_CONTROL (0x03), 13
                // bytes, Intuos5 packing in buf[4]. From the kernel; not
                // checked against a dongle, so best effort.
                let slot = UInt8(index & 0x03)
                var buf = [UInt8](repeating: 0, count: 13)
                buf[0] = 0x03
                buf[4] = (Self.intuos5CropLuminance << 4) | (Self.intuos5RingLuminance << 2) | slot
                queueSetReport(device, buf,
                               tag: "\(name) IntuosV1 WL LED slot=\(index)", severity: .bestEffort)
            } else if Self.intuos5PackedLEDProductIDs.contains(deviceSpec.productID) {
                // Intuos5 and Intuos Pro gen 1, wired: 0x20, 9 bytes,
                // buf[1] = crop luminance << 4 | ring luminance << 2 | slot.
                let slot = UInt8(index & 0x03)
                var buf = [UInt8](repeating: 0, count: 9)
                buf[0] = 0x20
                buf[1] = (Self.intuos5CropLuminance << 4) | (Self.intuos5RingLuminance << 2) | slot
                queueSetReport(capableInterfaceDevice ?? device, buf,
                               tag: "\(name) Intuos5 LED slot=\(index)",
                               severity: capableInterfaceDevice == nil ? .bestEffort : .required)
            } else {
                // Intuos4, wired: 0x20, 9 bytes, [0x20, 0x04 | slot, ring
                // luminance, pressed-key luminance, key OLED brightness, 0…],
                // with the kernel's defaults. A zero OLED brightness can
                // leave the key displays dark.
                //
                // Best effort until the interface that declares feature
                // reports registers: a connect-time resync can reach a
                // sibling first, and the retry in `registerDevice()` fixes it.
                var buf = [UInt8](repeating: 0, count: 9)
                buf[0] = 0x20
                buf[1] = 0x04 | UInt8(index & 0x03)
                buf[2] = Self.intuos4RingLuminance
                buf[3] = Self.intuos4PressedLuminance
                buf[4] = Self.intuos4OLEDBrightness
                queueSetReport(capableInterfaceDevice ?? device, buf,
                               tag: "\(name) Intuos4 LED slot=\(index)",
                               severity: capableInterfaceDevice == nil ? .bestEffort : .required)
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
            // route the write to — confirmed 2026-07-07 from captured
            // traffic: every 0xB4/0xB1 write sent over the dongle carries the
            // identity, none carry an all-zero address.
            let address = xencelabsDongleIdentity ?? []
            // Reassert screen orientation, as the vendor stack does during
            // its own reconnect init — omitting this write entirely lets the
            // OLED text drift back to upright (confirmed on hardware).
            //
            // Reasserts whatever the user last set, not a hardcoded upright:
            // this runs on every dial mode-cycle click, not just on relink
            // (it's `observeRingLED`'s `$touchRingActiveSlotIndex` sink), so
            // a hardcoded 0 here silently discarded the Buttons pane's
            // Rotation setting on every single click — confirmed against a
            // live capture 2026-09-08, where one dial-button press produced
            // an unrequested orientation-upright write. `-1` (never set)
            // still means upright, matching the device's power-on default.
            let orientationSteps = lastQuickKeysOrientation >= 0 ? lastQuickKeysOrientation : 0
            sendXencelabsOutput(
                XencelabsOutputProtocol.orientationPayload(
                    rotationSteps: orientationSteps, address: address),
                tag: "screen orientation \(orientationSteps)")
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
