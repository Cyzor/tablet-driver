// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Wacom DTU HID report format.
///
/// Used by: DTU-2231 (0x00CE), DTU-1631 (0x00F0). Ported from input-wacom's
/// `wacom_dtu_irq` (`Notes/Scratch/upstream/input-wacom/4.18/wacom_wac.c`, ~L276).
///
/// Report ID routing:
/// 0x02  Pen report (WACOM_REPORT_PENABLED), 8 bytes — LE16 X/Y, 9-bit pressure.
///       The kernel function does not gate on report ID; dispatch is by device
///       type. Only one report stream is expected from these devices.
///
/// No pad buttons, no tilt, no rotation, no hover distance, no serial number.
/// Eraser vs. pen is inferred from tool-type bits in the flags byte, latched
/// on proximity entry and held until the next out-of-proximity event.
///
/// Key differences from DTUSDecoder: coordinates are little-endian (not BE),
/// pressure is 9-bit (`(data[7] & 0x01) << 8 | data[6]`), and there is no
/// pad report.
///
/// Experimental: not yet validated on hardware.
struct DTUDecoder: WacomDecoder {

    func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        guard length >= 8 else { return [] }
        return decodePenReport(report: report, length: length, spec: spec, state: &state)
    }

    // MARK: - Pen report

    /// `wacom_dtu_irq` layout (8+ bytes):
    ///   [0]     report ID (WACOM_REPORT_PENABLED = 0x02; not checked by kernel)
    ///   [1]     flags byte:
    ///             bit 5 (0x20): proximity
    ///             bit 4 (0x10): BTN_STYLUS2 (barrel button 2)
    ///             bits 3–2 (0x0C): tool type — non-zero = eraser
    ///             bit 1 (0x02): BTN_STYLUS (barrel button 1)
    ///   [2–3]   X coordinate, LITTLE-endian u16
    ///   [4–5]   Y coordinate, LITTLE-endian u16
    ///   [6]     pressure LSB (8 bits)
    ///   [7]     bit 0: pressure MSB → 9-bit total (0–511)
    private func decodePenReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState
    ) -> [DecodeResult] {
        let flags = report[1]
        let prox = (flags & 0x20) != 0

        if !prox {
            guard state.prevInProximity else { return [] }
            state.prevInProximity = false
            return [
                .pen(
                    TabletPoint(
                        x: state.lastX, y: state.lastY,
                        maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0, rotation: 0.0,
                        penButton1: false, penButton2: false,
                        eraser: false, inProximity: false, hoverDistance: 0))
            ]
        }

        let x = Int(UInt16(report[2]) | UInt16(report[3]) << 8)
        let y = Int(UInt16(report[4]) | UInt16(report[5]) << 8)
        let pressure = Int(UInt16(report[6]) | UInt16(report[7] & 0x01) << 8)
        let isEraser = (flags & 0x0C) != 0

        state.prevInProximity = true
        state.lastX = x
        state.lastY = y

        return [
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,
                    penButton1: (flags & 0x02) != 0,
                    penButton2: (flags & 0x10) != 0,
                    eraser: isEraser,
                    inProximity: true,
                    hoverDistance: 0))
        ]
    }
}
