// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

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

    /// `wacom_dtus_irq` layout (7+ bytes):
    ///   [0]     0x11  report ID
    ///   [1]     status byte:
    ///             bit 7 (0x80): proximity
    ///             bit 6 (0x40): pen button 2 (BTN_STYLUS2)
    ///             bit 5 (0x20): pen button 1 (BTN_STYLUS)
    ///             bits 4..3:    tool type — 1 = eraser, 2 = pen
    ///             bits 1..0:    pressure high bits
    ///   [2]     pressure low byte
    ///   [3..4]  X, BIG-endian u16
    ///   [5..6]  Y, BIG-endian u16
    ///
    /// Eraser identity is inferred per-frame from the tool-type bits;
    /// no serial or tool-code field exists in the wire format, so no
    /// `.toolEnter` events are produced.
    private func decodePenReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState
    ) -> [DecodeResult] {
        let status = report[1]
        let prox = (status & 0x80) != 0

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

        // BE16 — kernel uses get_unaligned_be16, which reads high byte first.
        let x = Int(UInt16(report[3]) << 8 | UInt16(report[4]))
        let y = Int(UInt16(report[5]) << 8 | UInt16(report[6]))
        let pressure = Int(UInt16(status & 0x03) << 8 | UInt16(report[2]))
        let toolType = (status >> 3) & 0x03  // 1 = eraser, 2 = pen
        let isEraser = toolType == 1

        state.prevInProximity = true
        state.lastX = x
        state.lastY = y

        return [
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,
                    penButton1: (status & 0x20) != 0,
                    penButton2: (status & 0x40) != 0,
                    eraser: isEraser,
                    inProximity: true,
                    hoverDistance: 0))
        ]
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
