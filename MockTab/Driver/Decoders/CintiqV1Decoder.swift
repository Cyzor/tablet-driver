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

/// Decoder for Wacom Cintiq pen-display tablets using the WACOM_24HD HID report layout.
///
/// Handles all old Cintiq models (`.cintiqV1` parser family):
///   DTK-2400 (0x00F4) ✓ confirmed live, DTH-2400 (0x00F8),
///   DTK-2200 (0x00FA/0x00F9), DTZ-2100B (0x00FB), DTZ-2100 (0x00CC),
///   Cintiq 20WSX (0x00C0), Cintiq 13HD (0x00C4/0x0304), Cintiq 12WX (0x00C6).
///
/// **Report routing:**
///   0x01 — tip-switch (mouse-compatible collection; requires device seizure to suppress
///           the OS's native left-click interpretation)
///   0x02 — pen digitizer (10-byte IntuosV1, WACOM_24HD typeNibble dispatch)
///   0x0C — touch rings + express keys (Linux kernel WACOM_24HD pad layout)
///
/// **Pen report type-nibble dispatch: `(status >> 1) & 0x0F`**
///   0x00–0x03: general pen packet (position, pressure, tilt, barrel buttons)
///   0x05:      Art Pen / Marker Pen rotation (ABS_Z kernel formula)
///   0x0A:      Airbrush second packet (not yet decoded; cached state forwarded)
///
/// **Barrel button debounce:**
/// Buttons are read from general packets (typeNibble 0–3) only.  The rotation
/// sub-frame (typeNibble 5, status 0xEA) has bit 1 permanently set as part of its
/// type encoding — reading buttons from it would latch barrel button 1 forever.
/// Hardware pulses the button bit ~1:5 while held; clear-counter threshold 7
/// survives up to 6 consecutive clear frames (~54 ms at 133 Hz) before releasing.
///
/// **Tip-switch synthetic pressure:**
/// When Report 0x01 fires (tip physically down) but the concurrent 0x02 pressure
/// reads zero (Grip Pen hardware limitation on some Cintiqs), `tipPressureOverride`
/// injects a minimum contact pressure so apps register a click.
struct CintiqV1Decoder: WacomDecoder {

    // ── Barrel button debounce state ──────────────────────────────────────────
    private var lastButton1: Bool = false
    private var lastButton2: Bool = false
    private var btn1ClearCount = 0
    private var btn2ClearCount = 0
    private static let buttonClearThreshold = 7

    // ── Tip-switch state (shared across Report 0x01 and Report 0x02) ─────────
    // tipPressureOverride: synthetic pressure injected when rawPressure == 0 at tip-down.
    // Set to tipContactThreshold (81) on tip-down; cleared on tip-up.
    private var tipSwitchActive: Bool = false
    private var tipPressureOverride: Int = 0
    private static let tipContactThreshold = 81

    mutating func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        guard length >= 2 else { return [] }
        let id = report[0]

        if id == 0x01 {
            return decodeTipSwitch(report: report)
        }
        if id == 0x0C {
            return decodeExpressKeys(report: report, length: length, spec: spec)
        }
        guard (id == 0x02 || id == 0x10) && length >= 10 else { return [] }
        return decodePen(
            report: report, spec: spec, state: &state, deviceFamily: deviceFamily)
    }

    // MARK: - Report 0x01: physical tip-switch

    private mutating func decodeTipSwitch(report: UnsafePointer<UInt8>) -> [DecodeResult] {
        let tipDown = (report[1] & 0x01) != 0
        guard tipDown != tipSwitchActive else { return [.none] }
        tipSwitchActive = tipDown
        tipPressureOverride = tipDown ? Self.tipContactThreshold : 0
        return [.none]
    }

    // MARK: - Report 0x02/0x10: pen digitizer

    private mutating func decodePen(
        report: UnsafePointer<UInt8>,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        let status = report[1]

        // Tool-change packet: status bits 7:2 == 0xC0.
        if (status & 0xFC) == 0xC0 {
            return decodeToolChange(report: report, state: &state, deviceFamily: deviceFamily)
        }

        let inProximity = (status & 0x20) != 0

        // Proximity-out.
        if !inProximity {
            if state.prevInProximity {
                resetProximityState(state: &state)
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
            return []
        }

        // Packet type nibble: (status >> 1) & 0x0F — from wacom_intuos_general().
        let typeNibble = (Int(status) >> 1) & 0x0F

        if typeNibble == 0x05 {
            // Art Pen / Marker Pen rotation packet.
            // Kernel formula (wacom_intuos_general, type 0x05):
            //   t = (d[6]<<3) | ((d[7]>>5) & 7)
            //   ABS_Z = (d[7]&0x20) ? ((t>900) ? (t-1)/2-1350 : (t-1)/2+450) : 450-t/2
            // ABS_Z range: -900..+899 in 0.5° steps; negate direction, shift to [0, 1799], scale to 0–360°.
            // Negated so clockwise twist → increasing degrees, matching macOS kCGTabletEventRotation.
            let t = (Int(report[6]) << 3) | ((Int(report[7]) >> 5) & 7)
            let absZ: Int
            if (report[7] & 0x20) != 0 {
                absZ = (t > 900) ? ((t - 1) / 2 - 1350) : ((t - 1) / 2 + 450)
            } else {
                absZ = 450 - t / 2
            }
            var degrees = Double(900 - absZ) / 1800.0 * 360.0
            if degrees < 0 { degrees += 360.0 }
            if degrees >= 360 { degrees -= 360.0 }
            state.lastRotation = degrees

        } else if typeNibble <= 0x03 {
            // General pen packet: position, pressure, tilt, and barrel buttons.
            //
            // Barrel buttons are read ONLY from general packets (typeNibble 0–3).
            // Bit 1 of the status byte has a different meaning in rotation frames
            // (typeNibble 5): it is part of the type encoding and is always set,
            // so reading it there would permanently latch barrel button 1.
            // The device pulses the button bit ~1:5 while held; debounce with clear-counter.
            let curBtn1 = (status & 0x02) != 0
            let curBtn2 = (status & 0x04) != 0
            if curBtn1 {
                btn1ClearCount = 0
                lastButton1 = true
            } else {
                btn1ClearCount += 1
                if btn1ClearCount >= Self.buttonClearThreshold { lastButton1 = false }
            }
            if curBtn2 {
                btn2ClearCount = 0
                lastButton2 = true
            } else {
                btn2ClearCount += 1
                if btn2ClearCount >= Self.buttonClearThreshold { lastButton2 = false }
            }

            // Coordinate decode: 16-bit BE with 1-bit fractional extension from byte 9.
            // Kernel: X = (BE16(d2:d3)<<1) | ((d9>>1)&1) — 17-bit.
            state.lastX = ((Int(report[3]) | Int(report[2]) << 8) << 1) | ((Int(report[9]) >> 1) & 1)
            state.lastY = ((Int(report[5]) | Int(report[4]) << 8) << 1) | (Int(report[9]) & 1)

            // Tilt (kernel, signed ±63):
            //   tiltX = (((d7<<1) & 0x7E) | (d8>>7)) - 64
            //   tiltY = (d8 & 0x7F) - 64
            state.lastTiltX = Double((((Int(report[7]) << 1) & 0x7E) | (Int(report[8]) >> 7)) - 64) / 63.0
            state.lastTiltY = Double((Int(report[8]) & 0x7F) - 64) / 63.0
        }
        // typeNibble 0x0A (airbrush wheel): not yet decoded; falls through with cached state.

        // Pressure: kernel (wacom_intuos_general): (d6<<3) | ((d7&0xC0)>>5) | (d1&1) — 11-bit.
        // Only valid for general pen packets (typeNibble 0–3); rotation frames don't carry pressure.
        // Apply tip-switch override: if raw pressure is 0 but tip-switch fired, use the
        // minimum contact threshold so apps register the click.
        let pressure: Int
        if typeNibble <= 0x03 {
            let raw = (Int(report[6]) << 3) | ((Int(report[7]) & 0xC0) >> 5) | (Int(status) & 1)
            pressure = (raw == 0 && tipPressureOverride > 0) ? tipPressureOverride : raw
        } else {
            pressure = 0
        }

        // Fallback onToolEnter on first proximity entry (no prior tool-change packet).
        var results: [DecodeResult] = []
        if !state.prevInProximity {
            state.prevInProximity = true
            if state.currentToolCode == 0 {
                let fallbackCode: UInt16 = state.isEraser ? 0x080A : 0x0802
                results.append(
                    .toolEnter(
                        ToolIdentity(
                            serial: 0, toolCode: fallbackCode,
                            isEraser: state.isEraser, isMouse: false)))
                emitToolCompatibility(
                    toolCode: fallbackCode, deviceFamily: deviceFamily,
                    state: &state, results: &results)
            }
        }

        let hoverDist = typeNibble <= 0x03 ? Int(report[9]) >> 2 : 0

        results.append(
            .pen(
                TabletPoint(
                    x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: state.lastTiltX,
                    tiltY: state.lastTiltY,
                    rotation: state.lastRotation,
                    penButton1: lastButton1 && !(!state.toolIsSupported && pressure > 0),
                    penButton2: lastButton2,
                    eraser: state.isEraser,
                    inProximity: true,
                    hoverDistance: hoverDist)))
        return results
    }

    // MARK: - Tool-change packet (status bits 7:2 == 0xC0)

    private func decodeToolChange(
        report: UnsafePointer<UInt8>,
        state: inout DecoderState,
        deviceFamily: String
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
        state.toolIsMouse = false

        var results: [DecodeResult] = [
            .toolEnter(
                ToolIdentity(
                    serial: serial, toolCode: toolCode,
                    isEraser: state.isEraser, isMouse: false))
        ]
        emitToolCompatibility(
            toolCode: toolCode, deviceFamily: deviceFamily,
            state: &state, results: &results)
        return results
    }

    // MARK: - Report 0x0C: touch rings + express keys
    //
    // Confirmed layout (live capture + Linux kernel wacom_wac.c WACOM_24HD):
    //   byte[1] — left  touch ring: bit 7 = active (1 = finger present), bits [6:0] = position 0–71
    //   byte[2] — right touch ring: same encoding (present on dual-ring models only)
    //   byte[6] — left  express key bits 0–7
    //   byte[8] — right express key bits 0–7  (kernel formula: (data[8]<<8)|data[6])
    //
    // Right ring (byte[2]) is only decoded when spec.hasDualRings is true.

    private func decodeExpressKeys(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec
    ) -> [DecodeResult] {
        guard length >= 7 else { return [] }

        let leftRingRaw = report[1]
        let leftRingActive = (leftRingRaw & 0x80) != 0
        let leftRingPos = leftRingActive ? (leftRingRaw & 0x7F) : UInt8(0x7F)

        var rightRingActive = false
        var rightRingPos = UInt8(0x7F)
        if spec.hasDualRings && length >= 3 {
            let rightRingRaw = report[2]
            rightRingActive = (rightRingRaw & 0x80) != 0
            rightRingPos = rightRingActive ? (rightRingRaw & 0x7F) : UInt8(0x7F)
        }

        let leftByte = report[6]
        let rightByte = length >= 9 ? report[8] : 0
        let buttons =
            (0..<8).map { bit in (leftByte & (1 << bit)) != 0 }
            + (0..<8).map { bit in (rightByte & (1 << bit)) != 0 }

        return [
            .aux(
                AuxButtons(
                    buttons: buttons,
                    touchRingActive: leftRingActive,
                    touchRingPosition: leftRingPos,
                    touchRing2Active: rightRingActive,
                    touchRing2Position: rightRingPos))
        ]
    }

    // MARK: - State reset on proximity-out

    private mutating func resetProximityState(state: inout DecoderState) {
        state.prevInProximity = false
        state.lastRotation = 0.0
        state.lastTiltX = 0.0
        state.lastTiltY = 0.0
        lastButton1 = false
        lastButton2 = false
        btn1ClearCount = 0
        btn2ClearCount = 0
        tipSwitchActive = false
        tipPressureOverride = 0
    }
}
