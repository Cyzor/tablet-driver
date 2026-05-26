// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Decoder for the Wacom Graphire / PenPartner / Volito / early consumer line.
///
/// Status: **experimental.** Ported from the Linux input-wacom kernel driver
/// `wacom_graphire_irq()` (drivers/hid/wacom_wac.c) and not yet validated
/// against real hardware. Registry entries that route here should carry
/// `confidence: .experimental` so the UI can present an honest expectation
/// to users.
///
/// Scope (in):
///   • USB Graphire 2/3/4 — PIDs 0x0011..0x0017
///   • PenPartner 0x0003, original Graphire 0x0004/0x0010
///   • Volito / PenStation / Bamboo One CTF-430 (Graphire-protocol variants)
///
/// Scope (out):
///   • Graphire 1 (RS-232 serial) — pre-USB, irrelevant
///   • Graphire BT (CTE-630BT, RFCOMM/SPP) — not HID, separate transport stack
///   • WACOM_MO Manga series — distinct pad layout, deferred
///
/// **Report layout — Report ID 0x02 (kernel `WACOM_REPORT_PENABLED`), 8 bytes:**
/// ```
/// [0]  0x02   Report ID
/// [1]  status — see below
/// [2:3] X     LE16
/// [4:5] Y     LE16
/// [6]   pressure low byte / mouse wheel (signed) / G4 distance
/// [7]   pressure high (bits 0-1) / pad buttons (G4) / distance
/// ```
///
/// **Status byte d[1]:**
/// ```
/// bit 7  (0x80)  in proximity
/// bits 5..6 (0x60)  tool: 0=pen, 1=eraser, 2=mouse-with-wheel, 3=mouse
/// bit 2  (0x04)  BTN_STYLUS2 / mouse middle
/// bit 1  (0x02)  BTN_STYLUS  / mouse right
/// bit 0  (0x01)  BTN_TOUCH   / mouse left
/// ```
///
/// **Pressure** is 10-bit on pen tools: `d[6] | ((d[7] & 0x03) << 8)`.
/// Distance: `d[7] & 0x3F` (G4 also uses `d[6] & 0x3F`).
///
/// **Pad (G4 / Graphire 4 only)**, signalled when pen NOT in proximity:
///   d[7]: bit 6=BTN_BACK, bit 7=BTN_FORWARD, bits 3..5=wheel direction.
///
/// The kernel also handles GRAPHIRE_BT and WACOM_MO inside `wacom_graphire_irq`;
/// neither path is reproduced here. If a future RFCOMM-aware transport layer
/// lands, GraphireBT can be added as a sibling decoder.
struct GraphireDecoder: WacomDecoder {

    mutating func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        guard length >= 8, report[0] == 0x02 else { return [] }

        let status = report[1]
        let inProximity = (status & 0x80) != 0
        // Tool field: 0=pen, 1=eraser, 2=mouse w/wheel, 3=mouse no wheel.
        let toolField = (status >> 5) & 0x03
        let isMouse = toolField == 2 || toolField == 3
        let isEraser = toolField == 1

        var results: [DecodeResult] = []

        // ── Proximity exit ────────────────────────────────────────────────────
        if !inProximity {
            if state.prevInProximity {
                state.prevInProximity = false
                let exitEraser = state.isEraser
                state.isEraser = false
                results.append(
                    .pen(
                        TabletPoint(
                            x: state.lastX, y: state.lastY,
                            maxX: spec.maxX, maxY: spec.maxY,
                            pressure: 0, maxPressure: spec.maxPressure,
                            tiltX: 0, tiltY: 0, rotation: 0.0,
                            penButton1: false, penButton2: false,
                            eraser: exitEraser, inProximity: false, hoverDistance: 0)))
            }
            // Pad buttons (G4 only — buttonCount > 0 implies pad capability).
            if spec.buttonCount > 0 {
                results.append(contentsOf: decodePad(report: report, spec: spec))
            }
            return results
        }

        // ── Pen / eraser / mouse in proximity ────────────────────────────────
        // Fire toolEnter on rising edge.
        if !state.prevInProximity {
            state.prevInProximity = true
            state.isEraser = isEraser
            state.toolIsMouse = isMouse
            // Synthetic tool codes consistent with BambooDecoder:
            //   0x080A = eraser, 0x0802 = pen, 0x0007 = generic mouse.
            let toolCode: UInt16 = isMouse ? 0x0007 : (isEraser ? 0x080A : 0x0802)
            results.append(
                .toolEnter(
                    ToolIdentity(
                        serial: 0,
                        toolCode: toolCode,
                        isEraser: isEraser,
                        isMouse: isMouse)))
        }

        let x = Int(UInt16(report[2]) | UInt16(report[3]) << 8)
        let y = Int(UInt16(report[4]) | UInt16(report[5]) << 8)
        state.lastX = x
        state.lastY = y

        if isMouse {
            // Mouse path — left/right/middle clicks; pressure not reported.
            // Wheel: kernel uses -(signed char)d[6] for plain mouse; G4 has its own
            // wheel encoding in d[7] bits 3-5. Plain-mouse wheel covers the common
            // case for Graphire 2/3 mouse accessory.
            let wheelDelta = Int(Int8(bitPattern: report[6])) * -1
            results.append(
                .pen(
                    TabletPoint(
                        x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0, rotation: 0.0,
                        penButton1: (status & 0x02) != 0,  // right
                        penButton2: (status & 0x04) != 0,  // middle
                        eraser: false,
                        inProximity: true,
                        hoverDistance: 0,
                        mouseMiddleButton: (status & 0x04) != 0,
                        mouseWheelDelta: wheelDelta)))
            return results
        }

        // Pen / eraser path.
        // Pressure: 10-bit = d[6] | ((d[7] & 0x03) << 8). Cap at maxPressure
        // so devices with maxPressure==255 (PenPartner) aren't fed a 10-bit value.
        let rawPressure = Int(report[6]) | ((Int(report[7]) & 0x03) << 8)
        let pressure = min(rawPressure, spec.maxPressure)
        // Distance: 6-bit hover height in d[7] bits 0..5 (kernel masks 0x3F).
        // Bits 0..1 are also pressure-high; the kernel mask matches both uses.
        let hoverDistance = Int(report[7] & 0x3F)

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
                    hoverDistance: hoverDistance)))

        return results
    }

    // MARK: - Pad (Graphire 4 only)

    /// Decode the G4 pad buttons (back/forward + wheel) from d[7].
    /// Kernel reference: `wacom_graphire_irq()` WACOM_G4 branch.
    /// d[7] layout when in pad mode:
    ///   bit 6 (0x40) = BTN_BACK
    ///   bit 7 (0x80) = BTN_FORWARD
    ///   bits 3..5    = relative wheel
    private func decodePad(
        report: UnsafePointer<UInt8>,
        spec: DigitizerSpec
    ) -> [DecodeResult] {
        let padByte = report[7]
        // Two physical buttons on Graphire 4 — map to AuxButtons[0..1].
        let buttons = [
            (padByte & 0x40) != 0,   // BTN_BACK
            (padByte & 0x80) != 0,   // BTN_FORWARD
        ]
        return [.aux(AuxButtons(buttons: buttons))]
    }
}
