// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Decoder for the Wacom DTUS HID report format.
///
/// Used by: DTK-1651 (0x0343), DTU-1031 (0x00FB), DTU-1031X (0x032F),
/// DTU-1141 (0x0336). Ported from input-wacom's `wacom_dtus_irq`
/// (`Notes/Scratch/upstream/input-wacom/4.18/wacom_wac.c`, ~L306).
///
/// Report ID routing:
/// 0x11  Pen report, 7 bytes — BE16 X/Y, 10-bit pressure split across
///       status byte and pressure byte. Same ID as IntuosV2's aux
///       report, but dispatch is per-decoder so the collision is fine.
/// 0x15  Pad report, 2 bytes — four express keys in the low nibble.
///
/// No tilt, no rotation, no hover distance, no serial number, no
/// tool-code field. Eraser vs. pen is inferred from tool-type bits in
/// the status byte each frame.
///
/// Experimental: not yet validated on hardware.
struct DTUSDecoder: WacomDecoder {

    func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        guard length >= 2 else { return [] }
        switch report[0] {
        case 0x11:
            guard length >= 7 else { return [] }
            return decodePenReport(
                report: report, length: length, spec: spec, state: &state)
        case 0x15:
            return decodePadReport(report: report, length: length)
        default:
            return []
        }
    }

    // MARK: - 0x11 pen report

    private func decodePenReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState
    ) -> [DecodeResult] {
        // TODO(task #10): implement per wacom_dtus_irq
        return []
    }

    // MARK: - 0x15 pad report

    private func decodePadReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex
    ) -> [DecodeResult] {
        guard length >= 2 else { return [] }
        let mechanicalByte = report[1] & 0x0F
        let buttons = (0..<4).map { bit in (mechanicalByte & (1 << bit)) != 0 }
            + Array(repeating: false, count: 4)
        return [
            .aux(
                AuxButtons(
                    buttons: buttons,
                    mechanicalMask: mechanicalByte))
        ]
    }
}
