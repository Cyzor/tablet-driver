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

/// Decoder for the Wacom Bamboo consumer HID report format.
///
/// Used by: CTT-460, CTH-460/461/470/480/490, CTL-460/470/660, and related
/// consumer Bamboo / Wacom One series.
///
/// All pen models use **Report ID 0x10, 10 bytes** — same report ID as IntuosV2
/// but an entirely different, shorter layout with no tool-serial negotiation.
///
/// **CTT-460 (0x00D0) is touch-only** — it has no pen interface.  Reports will
/// never fire (maxPressure = 0, buttonCount = 0 → decoder silently returns []).
///
/// **Touch on CTH models** (CTH-460/470/480/490) arrives on a separate USB
/// interface as a 20-byte multitouch Report ID 0x02 stream.  This decoder
/// handles the pen interface only; touch is out of scope.
///
/// ---
///
/// **Report layout (pen in proximity):**
/// ```
/// [0]  0x10   Report ID
/// [1]  status — see below
/// [2:3] X     BE16
/// [4:5] Y     BE16
/// [6:7] pressure: (d6 << 3) | (d7 >> 5) — 11-bit
///              → right-shift by 1 if maxPressure ≤ 1023 (10-bit hardware)
/// [8]  reserved (tilt X on CTH-480/490 only — not decoded, requires hasTilt flag)
/// [9]  reserved (tilt Y on CTH-480/490 only — not decoded)
/// ```
///
/// **Status byte d1:**
/// ```
/// bit 7    in proximity
/// bits 4:3 tool type: 0 = pen,  1 = eraser,  2 = mouse
/// bit 2    BTN_STYLUS2 (barrel button 2)
/// bit 1    BTN_STYLUS  (barrel button 1)
/// bit 0    BTN_TOUCH   (tip contact)
/// ```
///
/// Eraser is identified directly from the tool-type field — no prior
/// enter-prox packet or serial number exchange (ABS_MISC not present).
///
/// **Pad report (when pen NOT in proximity, d7 byte):**
/// - CTH-460/470/480/490 (buttonCount ≥ 4): 0x08=btn0, 0x20=btn1, 0x10=btn2, 0x40=btn3
/// - CTL-460/470/660    (buttonCount ≥ 2): 0x01=btn0, 0x02=btn1
/// - CTT-460            (buttonCount = 0): no buttons, no output
///
/// Pad proximity signal (ABS_MISC = PAD_DEVICE_ID) fires when any button bit
/// is non-zero; clears on all-zero.  We emit `AuxButtons` every time since
/// InputInjector handles idempotent button state.
struct BambooDecoder: WacomDecoder {

    mutating func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        guard length >= 10, report[0] == 0x10 else { return [] }

        let status = report[1]
        let inProximity = (status & 0x80) != 0

        if !inProximity {
            var results: [DecodeResult] = []
            // Emit pen-out on proximity falling edge.
            if state.prevInProximity {
                state.prevInProximity = false
                results.append(
                    .pen(
                        TabletPoint(
                            x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                            pressure: 0, maxPressure: spec.maxPressure,
                            tiltX: 0, tiltY: 0, rotation: 0.0,
                            penButton1: false, penButton2: false,
                            eraser: state.isEraser, inProximity: false, hoverDistance: 0)))
            }
            // Decode pad buttons (only when device has express keys).
            if spec.buttonCount > 0 {
                results.append(contentsOf: decodePad(report: report, spec: spec))
            }
            return results
        }

        // ── Pen / eraser in proximity ─────────────────────────────────────────
        let toolType = (status >> 3) & 0x03  // 0=pen, 1=eraser, 2=mouse
        let isEraser = toolType == 1

        var results: [DecodeResult] = []

        // Fire toolEnter on proximity rising edge.
        if !state.prevInProximity {
            state.isEraser = isEraser
            state.prevInProximity = true
            results.append(
                .toolEnter(
                    ToolIdentity(
                        serial: 0,
                        toolCode: isEraser ? 0x080A : 0x0802,
                        isEraser: isEraser,
                        isMouse: false)))
        }

        let x = Int(UInt16(report[3]) | UInt16(report[2]) << 8)
        let y = Int(UInt16(report[5]) | UInt16(report[4]) << 8)
        state.lastX = x
        state.lastY = y

        // 11-bit pressure; right-shift for 10-bit (maxPressure ≤ 1023) devices.
        let rawPressure = (Int(report[6]) << 3) | (Int(report[7]) >> 5)
        let pressure = spec.maxPressure <= 1023 ? rawPressure >> 1 : rawPressure

        // Tilt is 4-bit signed (report[8]/report[9]) on CTH-480/490 only.
        // Suppressed until a hasTilt flag is added to DigitizerSpec to avoid
        // garbage readings on non-tilt models (zero byte → (0 & 0x0F) - 8 = -8).

        results.append(
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,
                    penButton1: (status & 0x02) != 0,
                    penButton2: (status & 0x04) != 0,
                    eraser: isEraser,
                    inProximity: true,
                    hoverDistance: 0)))

        return results
    }

    // MARK: - Pad buttons

    private func decodePad(
        report: UnsafePointer<UInt8>,
        spec: DigitizerSpec
    ) -> [DecodeResult] {
        let padByte = report[7]
        let buttons: [Bool]
        if spec.buttonCount >= 4 {
            // CTH-460/470/480/490 four-button layout (kernel wacom_bpt_pad).
            buttons = [
                (padByte & 0x08) != 0,  // BTN_0 (top-left)
                (padByte & 0x20) != 0,  // BTN_1
                (padByte & 0x10) != 0,  // BTN_2
                (padByte & 0x40) != 0,  // BTN_3 (bottom-left)
            ]
        } else {
            // CTL-460/470/660 two-button layout.
            buttons = [
                (padByte & 0x01) != 0,  // BTN_0
                (padByte & 0x02) != 0,  // BTN_1
            ]
        }
        return [.aux(AuxButtons(buttons: buttons))]
    }
}
