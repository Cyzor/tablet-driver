// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Decoder for the Wacom IntuosV3 HID report format.
///
/// Used by: PTK-470 (0x03F5), PTK-670 (0x03F7), PTK-870 (0x03F9) — the
/// current-generation Intuos Pro. Ported from OpenTabletDriver's
/// `IntuosV3ReportParser` and the three associated report structs.
///
/// Report ID routing:
/// 0x1F  Pen report, 16-bit XY (gated on data[1] == 0x01) — main path
/// 0x1E  Extended pen report, 24-bit XY  (note: collides with IntuosV2's
///       offset-pen ID; dispatch is per-decoder so this is fine)
/// 0x11  Aux report — 10 express keys + two relative-step scroll wheels
///
/// Byte layout differs from IntuosV2: the pen-status byte sits at [2]
/// instead of [1], pressure is at [7..8] instead of [8..9], and bit
/// positions for eraser (5 vs 4) and proximity (6 vs 5) are shifted.
/// See `Notes/Scratch/Upstream-Sync-2026-05-15.md` for the full diff
/// table.
///
/// Experimental: not yet validated on hardware.
struct IntuosV3Decoder: WacomDecoder {

    func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        guard length >= 2 else { return [] }
        switch report[0] {
        case 0x1F:
            // OTD gates on data[1] == 0x01; other 0x1F payloads are unknown.
            guard length >= 14, report[1] == 0x01 else { return [] }
            return decodePenReport(
                report: report, length: length, spec: spec, state: &state,
                deviceFamily: deviceFamily)
        case 0x1E:
            guard length >= 20 else { return [] }
            return decodeExtendedPenReport(
                report: report, length: length, spec: spec, state: &state,
                deviceFamily: deviceFamily)
        case 0x11:
            return decodeAuxReport(report: report, length: length)
        default:
            return []
        }
    }

    // MARK: - 0x1F standard pen report (16-bit XY)

    private func decodePenReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        // TODO(task #3): implement per OTD IntuosV3Report.cs
        return []
    }

    // MARK: - 0x1E extended pen report (24-bit XY)

    private func decodeExtendedPenReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        // TODO(task #4): implement per OTD IntuosV3ExtendedReport.cs
        return []
    }

    // MARK: - 0x11 aux report (express keys + two relative wheels)

    private func decodeAuxReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex
    ) -> [DecodeResult] {
        // TODO(task #5): implement per OTD IntuosV3AuxReport.cs
        return []
    }
}
