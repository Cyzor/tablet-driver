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

/// Decoder for the Wacom Intuos3 HID report format (PTZ-xxx, 2003–2006).
///
/// Covers: PTZ-431, PTZ-631, PTZ-631W (0x00B5), PTZ-930, PTZ-1231, PTZ-1231W, PTZ-431W.
///
/// **Differs from IntuosV1Decoder (PTH-851/Intuos5) in three ways:**
///
/// 1. Proximity bit — `status & 0x40` (bit 6) instead of bit 5.
///    Bit 6 is the sole proximity indicator; there is no separate high-confidence
///    bit, so the low-confidence path used by IntuosV1 does not apply here.
///
/// 2. Aux report IDs:
///    - `0x03` (10-byte): 8 express keys packed in byte 4. *Not* a BLE pad report.
///    - `0x0C` (7-byte): 4+4 express key split — low nibble of byte 5 (keys 0–3)
///      and low nibble of byte 6 (keys 4–7).
///
/// 3. No BLE HOGP support — Intuos3 is USB-only (pre-Bluetooth hardware).
///    Report IDs 0x01 and 0x11 are not used by this family.
///
/// Everything else (USB pen coordinates, pressure, tilt, tool-change packets,
/// wireless status, mouse subtypes) is identical to IntuosV1Decoder.
struct Intuos3Decoder: WacomDecoder {

    func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState
    ) -> [DecodeResult] {
        guard length >= 2 else { return [] }
        let id = report[0]

        // Intuos3 express key — 8 keys in byte 4.
        if id == 0x03 {
            guard length >= 10 else { return [] }
            let byte = report[4]
            return [.aux(AuxButtons(buttons: (0..<8).map { (byte & (1 << $0)) != 0 }))]
        }

        // Intuos3 pad report (report ID 0x0C, up to 10 bytes).
        //
        // Two layouts share this ID:
        //   PTZ-631W (WS, 10-byte): touch strip positions in bytes 1–4; bytes 5–6 unused.
        //   Other Intuos3 (7-byte): express keys only; 4 keys per nibble in bytes 5–6.
        //
        // Touch strip encoding (PTZ-631W, bytes 1–4):
        //   left  strip = (bytes[1] << 8) | bytes[2] — 16-bit big-endian one-hot bitmask.
        //   right strip = (bytes[3] << 8) | bytes[4] — same encoding.
        //   Bit N set → finger is in zone N (0 = bottom, higher = farther up the strip).
        //   All-zero → no contact.
        if id == 0x0C {
            guard length >= 5 else { return [] }

            // Touch strips — bytes 1–4.
            let leftRaw = (UInt16(report[1]) << 8) | UInt16(report[2])
            let rightRaw = (UInt16(report[3]) << 8) | UInt16(report[4])
            let leftActive = leftRaw != 0
            let rightActive = rightRaw != 0

            // Express keys (4+4 split variant) — bytes 5–6.  Zero on PTZ-631W.
            var buttons = [Bool](repeating: false, count: 8)
            if length >= 7 {
                let lo = report[5]
                let hi = report[6]
                buttons =
                    (0..<4).map { (lo & (1 << $0)) != 0 }
                    + (0..<4).map { (hi & (1 << $0)) != 0 }
            }

            return [
                .aux(
                    AuxButtons(
                        buttons: buttons,
                        touchStrip1Active: leftActive,
                        touchStrip1Position: leftActive
                            ? UInt8(leftRaw.trailingZeroBitCount) : 0xFF,
                        touchStrip2Active: rightActive,
                        touchStrip2Position: rightActive
                            ? UInt8(rightRaw.trailingZeroBitCount) : 0xFF))
            ]
        }

        if id == 0x80 {
            return decodeWireless(report: report, length: length)
        }

        guard (id == 0x02 || id == 0x10) && length >= 10 else { return [] }
        return decodeUSBPen(report: report, length: length, spec: spec, state: &state)
    }

    // MARK: - USB pen report (10-byte IntuosV1 format, Intuos3 status layout)

    private func decodeUSBPen(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState
    ) -> [DecodeResult] {
        let status = report[1]

        // Tool-change packet: status bits 7:2 == 0xC0.
        // Same pre-check as IntuosV1 — must fire before proximity test.
        if (status & 0xFC) == 0xC0 {
            return decodeToolChange(report: report, state: &state)
        }

        // Intuos3 proximity: bit 6 (0x40). No separate high-confidence bit.
        let inProximity = (status & 0x40) != 0
        let subtype = (status >> 1) & 0x0F

        if !inProximity {
            state.prevInProximity = false
            state.toolIsMouse = false
            return [
                .pen(
                    TabletPoint(
                        x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0, rotation: 0.0,
                        penButton1: false, penButton2: false,
                        eraser: state.isEraser, inProximity: false, hoverDistance: 0))
            ]
        }

        var results: [DecodeResult] = []

        // Fallback onToolEnter on first proximity entry (no prior tool-change packet).
        if !state.prevInProximity {
            let isMouse = subtype == 0x06 || subtype == 0x08
            state.toolIsMouse = isMouse
            if state.currentToolCode == 0 {
                let fallbackCode: UInt16 =
                    isMouse
                    ? (subtype == 0x06 ? 0x0806 : 0x0016)
                    : (state.isEraser ? 0x080A : 0x0802)
                results.append(
                    .toolEnter(
                        ToolIdentity(
                            serial: 0, toolCode: fallbackCode,
                            isEraser: state.isEraser, isMouse: isMouse)))
            }
        }
        state.prevInProximity = true

        // IntuosV1 coordinate decode: 16-bit BE with 1-bit fractional extension from byte 9.
        let x = ((Int(report[3]) | Int(report[2]) << 8) << 1) | ((Int(report[9]) >> 1) & 1)
        let y = ((Int(report[5]) | Int(report[4]) << 8) << 1) | (Int(report[9]) & 1)
        state.lastX = x
        state.lastY = y

        // Mouse subtype 0x06 (KC-100 cordless mouse / Intuos3 cursor).
        if subtype == 0x06 {
            let buttons = report[6]
            let whlByte = report[7]
            let wheelDelta = Int((whlByte & 0x80) >> 7) - Int((whlByte & 0x40) >> 6)
            results.append(
                .pen(
                    TabletPoint(
                        x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0, rotation: 0.0,
                        penButton1: (buttons & 0x01) != 0,
                        penButton2: (buttons & 0x04) != 0,
                        eraser: false, inProximity: true, hoverDistance: 0,
                        mouseMiddleButton: (buttons & 0x02) != 0,
                        mouseWheelDelta: wheelDelta)))
            return results
        }

        // Mouse subtype 0x08 (2D cursor / 4D mouse).
        if subtype == 0x08 {
            let btnByte = report[8]
            let wheelDelta = Int(btnByte & 0x01) - Int((btnByte & 0x02) >> 1)
            results.append(
                .pen(
                    TabletPoint(
                        x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0, rotation: 0.0,
                        penButton1: (btnByte & 0x04) != 0,
                        penButton2: (btnByte & 0x10) != 0,
                        eraser: false, inProximity: true, hoverDistance: 0,
                        mouseMiddleButton: (btnByte & 0x08) != 0,
                        mouseWheelDelta: wheelDelta)))
            return results
        }

        // Pen path — same pressure/tilt encoding as IntuosV1.
        // 11-bit pressure; right-shift for 10-bit (maxPressure ≤ 1023) devices per kernel spec.
        // Intuos5 devices (PTH-850, maxPressure=2047) include status bit 0 as 11th bit.
        let statusBit = (spec.maxPressure == 2047) ? (Int(status) & 1) : 0
        let rawPressure = (Int(report[6]) << 3) | ((Int(report[7] & 0xC0)) >> 5) | statusBit
        let pressure = spec.maxPressure <= 1023 ? rawPressure >> 1 : rawPressure
        let tiltXRaw = (((Int(report[7]) << 1) & 0x7E) | (Int(report[8]) >> 7)) - 64
        let tiltYRaw = (Int(report[8]) & 0x7F) - 64

        results.append(
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: Double(tiltXRaw) / 63.0,
                    tiltY: Double(tiltYRaw) / 63.0,
                    rotation: 0.0,
                    penButton1: (status & 0x02) != 0,
                    penButton2: (status & 0x04) != 0,
                    eraser: state.isEraser,
                    inProximity: true,
                    hoverDistance: (Int(report[9]) >> 2))))
        return results
    }

    // MARK: - Tool-change packet (identical to IntuosV1Decoder)

    private func decodeToolChange(
        report: UnsafePointer<UInt8>,
        state: inout DecoderState
    ) -> [DecodeResult] {
        let serial =
            UInt32(report[3] & 0x0F) << 28
            | UInt32(report[4]) << 20
            | UInt32(report[5]) << 12
            | UInt32(report[6]) << 4
            | UInt32(report[7]) >> 4
        let toolCode =
            UInt16(report[2]) << 4
            | UInt16(report[3]) >> 4
            | UInt16(report[7] & 0x0F) << 12
            | UInt16(report[8] & 0xF0) << 4

        state.lastSerial = serial
        state.currentToolCode = toolCode
        state.isEraser = (toolCode & 0x0008) != 0
        state.toolIsMouse = (toolCode & 0x000F) == 0x0006

        return [
            .toolEnter(
                ToolIdentity(
                    serial: serial, toolCode: toolCode,
                    isEraser: state.isEraser, isMouse: state.toolIsMouse))
        ]
    }

    // MARK: - Wireless status (identical to IntuosV1Decoder)

    private func decodeWireless(
        report: UnsafePointer<UInt8>,
        length: CFIndex
    ) -> [DecodeResult] {
        guard length >= 2 else { return [] }
        if (report[1] & 0x01) != 0 { return [.wireless(.active)] }
        return [.wireless(.lost)]
    }
}
