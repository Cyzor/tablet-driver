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

    /// OTD IntuosV3Report.cs layout (14+ bytes):
    ///   [0]     = 0x1F  report ID
    ///   [1]     = 0x01  sub-type discriminator (other values are unknown)
    ///   [2]     pen status: bit1=button1, bit2=button2, bit5=eraser, bit6=prox
    ///   [3..4]  X coordinate, LE u16
    ///   [5..6]  Y coordinate, LE u16
    ///   [7..8]  pressure, LE u16
    ///   [9]     tilt X, signed byte
    ///   [10]    unused/padding
    ///   [11]    tilt Y, signed byte
    ///   [12]    unused/padding
    ///   [13]    hover distance
    ///
    /// OTD does not document a tool-enter / serial field for this family, so
    /// we cannot emit `.toolEnter` events — downstream tool compatibility
    /// checks won't fire. The IntuosV3Decoder targets unverified hardware
    /// (PTK-470/670/870); without a capture we can't fill that gap.
    private func decodePenReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        let status = report[2]
        let prox = (status & 0x40) != 0

        if !prox {
            // Pen left proximity. Emit a synthetic exit frame so downstream
            // doesn't leave a phantom in-proximity state.
            guard state.prevInProximity else { return [] }
            state.prevInProximity = false
            return [
                .pen(
                    TabletPoint(
                        x: state.lastX, y: state.lastY,
                        maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: state.lastTiltX, tiltY: state.lastTiltY,
                        rotation: 0.0,
                        penButton1: false, penButton2: false,
                        eraser: false, inProximity: false, hoverDistance: 0))
            ]
        }

        let x = Int(UInt16(report[3]) | UInt16(report[4]) << 8)
        let y = Int(UInt16(report[5]) | UInt16(report[6]) << 8)
        let pressure = Int(UInt16(report[7]) | UInt16(report[8]) << 8)
        let tiltX = Double(Int8(bitPattern: report[9])) / 127.0
        let tiltY = Double(Int8(bitPattern: report[11])) / 127.0
        let hoverDistance = Int(report[13])

        state.prevInProximity = true
        state.lastX = x
        state.lastY = y
        state.lastTiltX = tiltX
        state.lastTiltY = tiltY
        state.hasValidTiltFrame = true

        return [
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: tiltX, tiltY: tiltY, rotation: 0.0,
                    penButton1: (status & 0x02) != 0,
                    penButton2: (status & 0x04) != 0,
                    eraser: (status & 0x20) != 0,
                    inProximity: true,
                    hoverDistance: hoverDistance))
        ]
    }

    // MARK: - 0x1E extended pen report (24-bit XY)

    /// OTD IntuosV3ExtendedReport.cs layout (20+ bytes):
    ///   [0]       = 0x1E  report ID
    ///   [2]       pen status: bit1=button1, bit2=button2, bit3=button3,
    ///                        bit5=eraser, bit6=prox
    ///   [3..5]    X coordinate, 24-bit (LE u16 at [3..4] | byte[5] << 16)
    ///   [6..8]    Y coordinate, 24-bit (LE u16 at [6..7] | byte[8] << 16)
    ///   [9..10]   pressure, LE u16
    ///   [11..12]  tilt X, signed LE i16
    ///   [13..14]  tilt Y, signed LE i16
    ///   [19]      hover distance
    ///
    /// Same report ID as IntuosV2's "offset" report, but the byte layout is
    /// completely different. Per-decoder dispatch keeps the two separate.
    private func decodeExtendedPenReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        let status = report[2]
        let prox = (status & 0x40) != 0

        if !prox {
            guard state.prevInProximity else { return [] }
            state.prevInProximity = false
            return [
                .pen(
                    TabletPoint(
                        x: state.lastX, y: state.lastY,
                        maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: state.lastTiltX, tiltY: state.lastTiltY,
                        rotation: 0.0,
                        penButton1: false, penButton2: false,
                        eraser: false, inProximity: false, hoverDistance: 0))
            ]
        }

        let x = Int(UInt16(report[3]) | UInt16(report[4]) << 8) | (Int(report[5]) << 16)
        let y = Int(UInt16(report[6]) | UInt16(report[7]) << 8) | (Int(report[8]) << 16)
        let pressure = Int(UInt16(report[9]) | UInt16(report[10]) << 8)
        let rawTiltX = Int16(bitPattern: UInt16(report[11]) | UInt16(report[12]) << 8)
        let rawTiltY = Int16(bitPattern: UInt16(report[13]) | UInt16(report[14]) << 8)
        // Without a Wacom-published full-scale value for the 16-bit tilt range,
        // normalize against Int16.max so apps see a consistent [-1, 1] scale.
        // May need re-tuning once a real PTK-x70 capture is available.
        let tiltX = Double(rawTiltX) / Double(Int16.max)
        let tiltY = Double(rawTiltY) / Double(Int16.max)
        let hoverDistance = Int(report[19])

        state.prevInProximity = true
        state.lastX = x
        state.lastY = y
        state.lastTiltX = tiltX
        state.lastTiltY = tiltY
        state.hasValidTiltFrame = true

        var point = TabletPoint(
            x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
            pressure: pressure, maxPressure: spec.maxPressure,
            tiltX: tiltX, tiltY: tiltY, rotation: 0.0,
            penButton1: (status & 0x02) != 0,
            penButton2: (status & 0x04) != 0,
            eraser: (status & 0x20) != 0,
            inProximity: true,
            hoverDistance: hoverDistance)
        // IntuosV3 extended reports carry a third pen barrel button at bit 3
        // of the status byte. The 0x1F standard report has no equivalent.
        point.penButton3 = (status & 0x08) != 0
        return [.pen(point)]
    }

    // MARK: - 0x11 aux report (express keys + two relative wheels)

    /// OTD IntuosV3AuxReport.cs layout:
    ///   [0]   = 0x11 report ID
    ///   [1]   = primary express-key byte (8 buttons)
    ///   [3]   = secondary express-key byte (bits 0 and 1 supply two
    ///           extra buttons, interleaved into OTD's 10-button array
    ///           at positions 4 and 9)
    ///   [4]   = left wheel raw 7-bit signed delta
    ///   [5]   = right wheel raw 7-bit signed delta
    ///
    /// OTD's interleave order:
    ///   buttons[0..3] = primary bits 0..3
    ///   buttons[4]    = secondary bit 0
    ///   buttons[5..8] = primary bits 4..7
    ///   buttons[9]    = secondary bit 1
    ///
    /// The two relative-step scroll wheels are still dropped — our aux
    /// pipeline has no relative-encoder path, and routing the deltas
    /// blind without a real PTK-x70 capture is more risk than value.
    private func decodeAuxReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex
    ) -> [DecodeResult] {
        guard length >= 2 else { return [] }
        let primary = report[1]
        let secondary: UInt8 = length >= 4 ? report[3] : 0
        let buttons: [Bool] = [
            (primary   & 0x01) != 0,
            (primary   & 0x02) != 0,
            (primary   & 0x04) != 0,
            (primary   & 0x08) != 0,
            (secondary & 0x01) != 0,
            (primary   & 0x10) != 0,
            (primary   & 0x20) != 0,
            (primary   & 0x40) != 0,
            (primary   & 0x80) != 0,
            (secondary & 0x02) != 0,
        ]
        // mechanicalMask is UInt8 (8 bits); the two interleaved-from-
        // secondary bits at positions 4 and 9 cant be carried through
        // here. Rapid re-press detection on those two buttons is the
        // only thing affected — normal up/down still works.
        return [
            .aux(
                AuxButtons(
                    buttons: buttons,
                    mechanicalMask: primary))
        ]
    }
}
