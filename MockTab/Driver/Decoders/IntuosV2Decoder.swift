// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026 This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab. If not, see <https://www.gnu.org/licenses/>.

import Foundation

/// Decoder for the Wacom IntuosV2 HID report format.
///
/// Used by: PTH-460 (0x0356), PTH-660 (0x0357), PTH-860 (0x0358)
/// and any future tablet using the 192-byte IntuosV2 report layout.
///
/// Report ID routing:
/// 0x01 BLE HOGP pen report (23 bytes)
/// 0x03 BLE HOGP pad report (9 bytes)
/// 0x10 Standard USB pen report (192 bytes) — main path
/// 0x1E Offset pen report (driver-compatibility mode)
/// 0x11 Auxiliary (express key + touch ring) report
/// 0x80 Wireless status report (ACK-40401 RF dongle)
struct IntuosV2Decoder: WacomDecoder {

    func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        guard length >= 2 else { return [] }
        switch report[0] {
        case 0x01:
            // The PTH-660/860 expose a standard USB HID mouse interface (usagePage=0x01)
            // that carries 4-byte button reports for cordless mouse accessories (KC-100).
            // BLE HOGP pen reports share Report ID 0x01 but are ≥ 23 bytes.
            // Distinguish by length: ≤ 8 bytes → USB mouse buttons; otherwise → BLE pen.
            if length <= 8 {
                // [0]=0x01 [1]=buttons(bit0=L,bit1=R,bit2=M) [2]=relX [3]=relY
                return [.mouseButton(report[1])]
            }
            return decodeBLEPen(
                report: report, length: length, spec: spec, state: &state,
                deviceFamily: deviceFamily)
        case 0x03:
            guard let aux = decodeBLEPadReport(report: report, length: length) else { return [] }
            return [.aux(aux)]
        case 0x10:
            guard length >= 12 else { return [] }
            return decodePenReport(
                report: report, length: length, spec: spec, state: &state,
                deviceFamily: deviceFamily)
        case 0x1E:
            return decodeOffsetPenReport(report: report, length: length, spec: spec, state: &state)
        case 0x11:
            return decodeAuxReport(report: report, length: length)
        case 0x80:
            // Report ID 0x80 is shared by three distinct payloads:
            // • RF wireless status (report[1] = 0x02/0x05/0x06)
            // • PTH-860 BT Classic: 99 bytes — 1 header + 7 × 14-byte pen frames
            //   (wacom_intuos_pro2_bt_irq / INTUOSP2_BT kernel type)
            // • PTH-660 BT Classic: 361 bytes — single pen sub-report + pad at offset 281
            if length >= 2 && (report[1] == 0x02 || report[1] == 0x05 || report[1] == 0x06) {
                return decodeWireless(report: report, length: length)
            }
            if length == 99 {
                return decodeBTClassicFrames(
                    report: report, length: length, spec: spec, state: &state,
                    deviceFamily: deviceFamily)
            }
            return decodeBTPen(
                report: report, length: length, spec: spec, state: &state,
                deviceFamily: deviceFamily)
        default:
            return []
        }
    }

    // MARK: - BT frame coordinate/pressure/tilt helper

    /// Decode coordinate, pressure, and tilt from a BT per-frame buffer (used by both
    /// 361-byte and 99-byte BT paths). Offsets and interpretation are identical in both formats.
    /// Pressure formula is canonical (mask high byte first).
    private func decodeBTFrame(_ f: UnsafePointer<UInt8>)
        -> (x: Int, y: Int, pressure: Int, tiltX: Double, tiltY: Double, hoverDistance: Int)
    {
        let x = Int(UInt16(f[1]) | UInt16(f[2]) << 8)
        let y = Int(UInt16(f[3]) | UInt16(f[4]) << 8)
        let pressure = Int(UInt16(f[5]) | (UInt16(f[6] & 0x1F) << 8))
        let tiltX = Double(Int8(bitPattern: f[7])) / 127.0
        let tiltY = Double(Int8(bitPattern: f[8])) / 127.0
        let hoverDistance = Int(f[13])
        return (x, y, pressure, tiltX, tiltY, hoverDistance)
    }

    // MARK: - Standard pen report (0x10)

    private func decodePenReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        let status = report[1]
        // USB IntuosV2 status byte: bit6=proximity, bit5=highConfidence.
        // Kernel model (wacom_intuos_pro_irq): exit when !prox && !conf (status < 0x20).
        // Sequence at boundary: 0x60 (prox=1, conf=1) → 0x40 (prox=1, conf=0) → 0x00 (both=0).
        // Art Pen rotation sensor causes transient oscillations (0x60 ↔ 0x40) that are NOT
        // genuine exits. Only exit when BOTH bits clear.
        let prox = (status & 0x40) != 0
        let highConfidence = (status & 0x20) != 0
        let isExitSignal = !prox && !highConfidence

        if isExitSignal {
            // Genuine firmware exit signal — both proximity and confidence lost.
            // Don't threshold this; kernel fires it immediately.
            if state.prevInProximity {
                state.exitFrameCount = 0
                state.prevInProximity = false
                state.lastSerial = 0  // force toolEnter on re-entry
                state.lastToolCode = 0
                // FIX: capture cached values before zeroing them so the exit event
                // carries the pen's last known orientation rather than 0° / (0,0).
                let exitRotation = state.lastRotation
                let exitTiltX = state.lastTiltX
                let exitTiltY = state.lastTiltY
                state.lastRotation = 0.0
                state.lastTiltX = 0.0
                state.lastTiltY = 0.0
                state.hasValidRotationFrame = false
            state.hasValidTiltFrame = false
                return [
                    .pen(
                        TabletPoint(
                            x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                            pressure: 0, maxPressure: spec.maxPressure,
                            tiltX: exitTiltX, tiltY: exitTiltY, rotation: exitRotation,
                            penButton1: false, penButton2: false,
                            eraser: false, inProximity: false, hoverDistance: 0))  // Exit event
                ]
            }
            return []
        }

        // Boundary noise: prox=1 but highConfidence=0 (status = 0x40).
        // The Art Pen's rotation sensor causes these oscillations during active motion —
        // confirmed by code comment and live captures. Pass through last cached state
        // instead of returning [] so apps see continuous data rather than a gap that
        // resolves to a 0° snap when the exit threshold fires.
        if !highConfidence {
            state.exitFrameCount += 1
            if state.exitFrameCount >= DecoderState.exitThreshold && state.prevInProximity {
                state.exitFrameCount = 0
                state.prevInProximity = false
                state.lastSerial = 0  // force toolEnter on re-entry
                state.lastToolCode = 0
                // FIX: capture cached values before zeroing — same mutation-before-use
                // correction as the isExitSignal path above.
                let exitRotation = state.lastRotation
                let exitTiltX = state.lastTiltX
                let exitTiltY = state.lastTiltY
                state.lastRotation = 0.0
                state.lastTiltX = 0.0
                state.lastTiltY = 0.0
                state.hasValidRotationFrame = false
            state.hasValidTiltFrame = false
                return [
                    .pen(
                        TabletPoint(
                            x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                            pressure: 0, maxPressure: spec.maxPressure,
                            tiltX: exitTiltX, tiltY: exitTiltY, rotation: exitRotation,
                            penButton1: false, penButton2: false,
                            eraser: false, inProximity: false, hoverDistance: 0))
                ]
            }

            // Below threshold — pen still likely in contact. Emit last known state so
            // apps (Rebelle, Krita) see stable rotation rather than a dropped frame.
            // Only use cached values if we've received at least one valid frame since
            // tool-enter; at re-entry, skip this pass-through until the first good frame.
            // FIX: use cached lastTiltX/lastTiltY instead of hardcoded 0 so that the
            // azimuth angle (atan2 of tilt components) doesn't snap to 0° on every
            // low-confidence frame — the primary cause of wobbly strokes in Rebelle.
            // For low-confidence frames, report 0 hover (no valid measurement during noise).
            if state.prevInProximity && state.hasValidTiltFrame {
                return [
                    .pen(
                        TabletPoint(
                            x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                            pressure: 0, maxPressure: spec.maxPressure,
                            tiltX: state.lastTiltX, tiltY: state.lastTiltY,
                            rotation: state.lastRotation,
                            penButton1: false, penButton2: false,
                            eraser: false, inProximity: true, hoverDistance: 0))
                ]
            }
            return []
        }

        state.exitFrameCount = 0
        state.prevInProximity = true

        var results: [DecodeResult] = []

        // Extract pen serial (bytes 17–20 LE) and tool code (bytes 21–22 LE).
        // Fire toolEnter whenever the active tool changes — either by serial (pens)
        // or by toolCode alone when serial = 0 (some mouse accessories).
        if length >= 27 {
            let serial =
                UInt32(report[17])
                | UInt32(report[18]) << 8
                | UInt32(report[19]) << 16
                | UInt32(report[20]) << 24
            let toolCode = UInt16(report[21]) | UInt16(report[22]) << 8
            // Boundary-noise frames (0x40) carry zero tool code. Don't overwrite the
            // valid code from the last good frame.
            if toolCode != 0 {
                state.currentToolCode = toolCode

                let toolChanged =
                    serial != 0
                    ? serial != state.lastSerial
                    : (toolCode != 0 && toolCode != state.lastToolCode)
                if toolChanged {
                    state.lastSerial = serial
                    state.lastToolCode = toolCode
                    let isMouse = (toolCode & 0x000F) == 0x0006
                    state.toolIsMouse = isMouse
                    // Seed scroll counter to avoid a large spurious delta on first mouse report.
                    if isMouse { state.lastScrollPos = report[16] }
                    // Eraser: standard Wacom bit3 convention, but exclude Art Pen
                    // variants (0x0804, 0x1108) that happen to have bit3 set.
                    let artPen = toolCode == 0x0804 || toolCode == 0x1108
                    results.append(
                        .toolEnter(
                            ToolIdentity(
                                serial: serial,
                                toolCode: toolCode,
                                isEraser: !artPen && (toolCode & 0x0008) != 0,
                                isMouse: isMouse)))

                    // Check tool compatibility and emit warning if unsupported
                    emitToolCompatibility(
                        toolCode: toolCode, deviceFamily: deviceFamily,
                        state: &state, results: &results)
                }
            }
        }

        // IntuosV2 coordinate decode — 24-bit LE (2 bytes + 1-byte extension).
        let x = Int(UInt16(report[2]) | UInt16(report[3]) << 8) | (Int(report[4]) << 16)
        let y = Int(UInt16(report[5]) | UInt16(report[6]) << 8) | (Int(report[7]) << 16)
        state.lastX = x
        state.lastY = y

        // ── Mouse path ─────────────────────────────────────────────────────────
        // Byte [16] is an absolute 8-bit counter that wraps at 255. Signed delta
        // via Int8(bitPattern:) handles wrap-around correctly (255→0 = +1 step).
        if (state.currentToolCode & 0x000F) == 0x0006 && state.currentToolCode != 0 {
            let scrollPos = report[16]
            let wheelDelta = Int(Int8(bitPattern: scrollPos &- state.lastScrollPos))
            state.lastScrollPos = scrollPos
            results.append(
                .pen(
                    TabletPoint(
                        x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: 0, maxPressure: spec.maxPressure,
                        tiltX: 0, tiltY: 0, rotation: 0.0,
                        penButton1: (status & 0x02) != 0,
                        penButton2: (status & 0x04) != 0,
                        eraser: false, inProximity: true, hoverDistance: 0,  // Not reported by mouse
                        mouseMiddleButton: (report[9] & 0x02) != 0,
                        mouseWheelDelta: wheelDelta)))
            return results
        }

        // ── Pen path ───────────────────────────────────────────────────────────
        // Pressure: 13-bit value (d[8] + lower 5 bits of d[9]) per kernel spec.
        let pressure = Int(UInt16(report[8]) | (UInt16(report[9] & 0x1F) << 8))
        let tiltX = Double(Int8(bitPattern: report[10])) / 127.0
        let tiltY = Double(Int8(bitPattern: report[11])) / 127.0

        // Cache tilt so that !highConfidence passthrough frames can hold the last
        // real value instead of emitting (0, 0) and snapping Rebelle's azimuth to 0°.
        state.lastTiltX = tiltX
        state.lastTiltY = tiltY
        state.hasValidTiltFrame = true

        // Rotation (Twist): Bytes 12–13, signed 16-bit, scaled by 10 (e.g. 1800 = 180.0°).
        // Only valid for Art Pen variants (0x0804, 0x1108); other pens report garbage/defaults.
        // Cache in state.lastRotation so boundary-noise frames can hold the last real value.
        let isArtPen = state.currentToolCode == 0x0804 || state.currentToolCode == 0x1108
        let toolIsEraser = !isArtPen && (state.currentToolCode & 0x0008) != 0
        let rawRot = Int16(bitPattern: UInt16(report[12]) | UInt16(report[13]) << 8)
        // Negate raw rotation so clockwise barrel twist produces an increasing angle,
        // matching the geometric convention apps expect (0°=natural grip, CW=positive).
        var rotation = isArtPen ? Double(rawRot) / 10.0 : 0.0
        if rotation < 0 { rotation += 360.0 }
        if isArtPen {
            state.lastRotation = rotation
            state.hasValidRotationFrame = true
        }

        // Proximity distance (hover height): Byte 16, 0-63 scale.
        // 0 = tip in contact, 1-63 = hover height (kernel: features.distance_max = 63).
        // When the pen approaches the tablet, distance decreases toward 0.
        let hoverDistance = Int(report[16])

        results.append(
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: tiltX, tiltY: tiltY, rotation: rotation,
                    penButton1: (status & 0x02) != 0,
                    penButton2: (status & 0x04) != 0,
                    eraser: (status & 0x08) != 0,
                    inProximity: true,
                    hoverDistance: hoverDistance)))

        return results
    }

    // MARK: - Offset pen report (0x1E, driver-compatibility mode)

    private func decodeOffsetPenReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState
    ) -> [DecodeResult] {
        guard length >= 17 else { return [] }
        let status = report[2]
        let x = Int(UInt16(report[3]) | UInt16(report[4]) << 8) | (Int(report[5]) << 16)
        let y = Int(UInt16(report[6]) | UInt16(report[7]) << 8) | (Int(report[8]) << 16)
        // Pressure: 13-bit value (d[9] + lower 5 bits of d[10]) per kernel spec.
        let pressure = Int(UInt16(report[9]) | (UInt16(report[10] & 0x1F) << 8))
        let tiltX = Double(Int8(bitPattern: report[11])) / 127.0
        let tiltY = Double(Int8(bitPattern: report[12])) / 127.0
        // Hover distance: same absolute position as 0x10 per kernel spec.
        let hoverDistance = Int(report[16])
        let isArtPen = state.currentToolCode == 0x0804 || state.currentToolCode == 0x1108
        let toolIsEraser = !isArtPen && (state.currentToolCode & 0x0008) != 0

        return [
            .pen(
                TabletPoint(
                    x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: pressure, maxPressure: spec.maxPressure,
                    tiltX: tiltX, tiltY: tiltY,
                    rotation: isArtPen ? state.lastRotation : 0.0,
                    penButton1: (status & 0x02) != 0,
                    penButton2: (status & 0x04) != 0,
                    eraser: (status & 0x08) != 0,
                    inProximity: (status & 0x20) != 0,
                    hoverDistance: hoverDistance))]
    }

    // MARK: - BLE HOGP pen (0x01)

    private func decodeBLEPen(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        guard
            let result = decodeBLEPenReport(
                report: report, length: length, spec: spec,
                lastX: &state.lastX, lastY: &state.lastY)
        else { return [] }

        var results: [DecodeResult] = []
        if result.toolCode != 0
            && (result.serial != state.lastSerial || result.toolCode != state.lastToolCode)
        {
            state.lastSerial = result.serial
            state.lastToolCode = result.toolCode
            state.currentToolCode = result.toolCode
            state.toolIsMouse = result.isMouse
            results.append(
                .toolEnter(
                    ToolIdentity(
                        serial: result.serial,
                        toolCode: result.toolCode,
                        isEraser: result.point.eraser,
                        isMouse: result.isMouse)))
        }

        results.append(.pen(result.point))
        return results
    }

    // MARK: - BT Wireless pen (0x80, Bluetooth Classic/LE transport variant)
    //
    // Coordinates and pressure use the same LE uint16 layout as the BLE HOGP 0x01 report.
    // report[1] flag byte differs from the HOGP spec:
    // bit7 (0x80) = inProximity (confirmed: 0x00 = no pen, 0xC0 = hovering)
    // bit6 (0x40) = frame-valid / "digitizer active" — always set during proximity,
    //     NOT a button. Masking it out fixes spurious middle-click on hover.
    // bit5 (0x20) = button assignment TBD — tentatively barrel1
    // bit4 (0x10) = button assignment TBD — tentatively barrel2
    // bit3 (0x08) = TBD (eraser?)
    // TODO: confirm bit4–5 assignments from live capture with buttons pressed.

    private func decodeBTPen(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        guard length >= 15 else { return [] }

        var results: [DecodeResult] = []

        // PTH-660 BT 361-byte report layout (0-indexed bytes):
        // [0] = 0x80 (report ID)
        // [1..98] = up to 7 × 14-byte pen frames (oldest first)
        // [99] = would-be frame 7 flags byte — always 0x00, acts as sentinel
        // [100] = 0xCE (device metadata marker, constant)
        // [100..109] = device capability block:
        //      [100] = 0xCE marker
        //      [104:105]= tool code LE (e.g., 0x0804 = Art Pen)
        // [281..285] = pad sub-report (center button, express keys, touch ring)
        //
        // Per-frame flag byte (f[0]):
        // 0x80 = frame valid / pen in proximity (0 = empty frame, break loop)
        // 0x40 = digitizer active (set when pen is hovering or touching)
        // 0x20 = pen in range (set while hovering or touching)
        // 0x08 = eraser tool
        // 0x04 = BTN_STYLUS2 (barrel button 2)
        // 0x02 = BTN_STYLUS (barrel button 1)

        // Tool identity: tool code at bytes [103:104] LE (confirmed from live BT captures).
        let toolCode: UInt16 = length >= 105 ? UInt16(report[103]) | UInt16(report[104]) << 8 : 0
        let isMouse = (toolCode & 0x000F) == 0x0006
        // Art Pen variants: 0x0804, 0x1108 (confirmed 2026-04-01).
        // Note: 0x1108 has bit3 set, so the standard (toolCode & 0x0008) eraser test
        // would misclassify it as eraser. Use per-frame flags bit3 for eraser instead;
        // toolEnter isEraser is only for known eraser tool codes.
        let isArtPen = toolCode == 0x0804 || toolCode == 0x1108
        // Eraser detection for toolEnter: standard Wacom convention is bit3 of toolCode,
        // but exclude known Art Pen codes that happen to have bit3 set.
        let toolIsEraser = !isArtPen && (toolCode & 0x0008) != 0

        if toolCode != 0 && toolCode != state.lastToolCode {
            state.lastToolCode = toolCode
            state.currentToolCode = toolCode
            state.toolIsMouse = isMouse
            results.append(
                .toolEnter(
                    ToolIdentity(
                        serial: 0, toolCode: toolCode,
                        isEraser: toolIsEraser,
                        isMouse: isMouse)))

            emitToolCompatibility(
                toolCode: toolCode, deviceFamily: deviceFamily,
                state: &state, results: &results)
        }

        // Process up to 7 pen frames (oldest first). Each frame is 14 bytes.
        //
        // Proximity exit detection: The Art Pen's rotation sensor causes extended signal
        // loss at the detection boundary, sending streams of invalid frames (flags=0x00)
        // that are firmware "nothing to report" signals, not real exits. The kernel model
        // would emit an immediate exit on frame[0]=0x00, but that permanently kills
        // proximity because the pen's recovery doesn't trigger a re-entry event.
        //
        // Solution: threshold both types of bad frames (invalid bit7 and !inRange) using
        // the same exitFrameCount. Only emit a real exit after N consecutive packets with
        // no valid data or no range. Reset the counter on any good frame.
        for i in 0..<7 {
            let frameOffset = 1 + i * 14
            guard frameOffset + 1 <= length else { break }
            let f = report.advanced(by: frameOffset)
            let flags = f[0]

            // Invalid frame (bit7=0) — either transient "nothing to report" or a real exit.
            // At the detection boundary (especially with Art Pen), we get bursts of 0x00.
            // Apply the same threshold as the !inRange path: require N consecutive bad
            // packets before confirming exit.
            if (flags & 0x80) == 0 {
                state.exitFrameCount += 1
                if i == 0 && state.exitFrameCount >= DecoderState.exitThreshold
                    && state.prevInProximity
                {
                    state.exitFrameCount = 0
                    state.prevInProximity = false
                    state.lastTiltX = 0.0
                    state.lastTiltY = 0.0
                    state.hasValidTiltFrame = false
                    state.lastRotation = 0.0
                    state.hasValidRotationFrame = false
                    state.lastToolCode = 0  // force toolEnter on re-entry
                    results.append(
                        .pen(
                            TabletPoint(
                                x: state.lastX, y: state.lastY,
                                maxX: spec.maxX, maxY: spec.maxY,
                                pressure: 0, maxPressure: spec.maxPressure,
                                tiltX: 0, tiltY: 0, rotation: 0.0,
                                penButton1: false, penButton2: false,
                                eraser: false, inProximity: false, hoverDistance: 0)))
                }
                break
            }

            // Valid frame — check for firmware proximity-exit signal.
            // Kernel model (wacom_intuos_pro2_bt_irq): exit when !prox && !inRange.
            // At the detection boundary, inRange (bit5) drops first; prox (bit6) follows.
            // Flag sequence: 0xE0 → 0xC0 (inRange=0 but prox=1) → 0x80 (both clear).
            // The Art Pen's rotation sensor causes transient oscillations (0xC0 ↔ 0xE0)
            // that are NOT genuine exits. Only exit when BOTH bits clear.
            let prox = (flags & 0x40) != 0
            let inRange = (flags & 0x20) != 0
            let isExitSignal = !prox && !inRange

            if isExitSignal {
                // Genuine firmware exit signal — both wireless and digitizer range lost.
                // Don't threshold this; kernel fires it immediately.
                if state.prevInProximity {
                    state.exitFrameCount = 0
                    state.prevInProximity = false
                    state.lastTiltX = 0.0
                    state.lastTiltY = 0.0
                    state.hasValidTiltFrame = false
                    state.lastRotation = 0.0
                    state.hasValidRotationFrame = false
                    state.lastToolCode = 0  // force toolEnter on re-entry
                    results.append(
                        .pen(
                            TabletPoint(
                                x: state.lastX, y: state.lastY,
                                maxX: spec.maxX, maxY: spec.maxY,
                                pressure: 0, maxPressure: spec.maxPressure,
                                tiltX: 0, tiltY: 0, rotation: 0.0,
                                penButton1: false, penButton2: false,
                                eraser: false, inProximity: false, hoverDistance: 0)))
                }
                break
            }

            // Boundary noise: prox=1 but inRange=0 (0xC0). Oscillations here should not
            // trigger exit. Wait for a sustained bad state (N consecutive frames) before
            // treating it as a disconnect. Reset counter on any frame with inRange=1.
            // NOTE: Do NOT break here — we must still decode and send the point data
            // even during boundary noise. Only suppress the proximity exit.
            if !inRange {
                state.exitFrameCount += 1
                if state.exitFrameCount >= DecoderState.exitThreshold && state.prevInProximity {
                    state.exitFrameCount = 0
                    state.prevInProximity = false
                    state.lastTiltX = 0.0
                    state.lastTiltY = 0.0
                    state.hasValidTiltFrame = false
                    state.lastRotation = 0.0
                    state.hasValidRotationFrame = false
                    state.lastToolCode = 0  // force toolEnter on re-entry
                    results.append(
                        .pen(
                            TabletPoint(
                                x: state.lastX, y: state.lastY,
                                maxX: spec.maxX, maxY: spec.maxY,
                                pressure: 0, maxPressure: spec.maxPressure,
                                tiltX: 0, tiltY: 0, rotation: 0.0,
                                penButton1: false, penButton2: false,
                                eraser: false, inProximity: false, hoverDistance: 0)))
                    break
                }
                // Continue to decode point data below — don't break on boundary noise
            } else {
                // Good frame (inRange=1) — reset boundary counter and record entry if needed.
                state.exitFrameCount = 0
                state.prevInProximity = true
            }

            // Eraser detection: flags bit3 (0x08) directly indicates eraser, same as USB path.
            // Toolcode-based detection (toolIsEraser) only updates on tool change; reading
            // flags bit3 ensures correct state on every frame (handles tool flip without proximity gap).
            let isEraser = (flags & 0x08) != 0
            let barrel1 = (flags & 0x02) != 0
            let barrel2 = (flags & 0x04) != 0

            let (x, y, pressure, rawTiltX, rawTiltY, hoverDistance) = decodeBTFrame(f)
                let tiltX = inRange ? rawTiltX : state.lastTiltX
                let tiltY = inRange ? rawTiltY : state.lastTiltY
                if inRange {
                    state.lastTiltX = tiltX
                    state.lastTiltY = tiltY
                    state.hasValidTiltFrame = true
                }

            // Rotation: f[9:10], signed LE16, Art Pen only.
            // Kernel patches for wacom_intuos_pro2_bt_pen() confirm Art-Pen-specific rotation
            // handling in BT frames with alignment correction: userspace expects 0° at left,
            // but raw hardware has a +90° offset baked in. Subtract 900 (90° × 10), wrap to
            // [0, 3600). Non-Art-Pen tools carry garbage in these bytes — gate strictly.
            // Confirmed working (2026-04-02, PTH-660 BT + Art Pen).
            //
            // Gate on inRange: boundary-noise frames (0xC0, !inRange) have f[9:10]=0x00.
            // Use the last valid reading from an inRange=1 frame to suppress oscillation.
            var rotation = 0.0
            if isArtPen {
                if inRange {
                    let rawRot = Int(Int16(bitPattern: UInt16(f[9]) | UInt16(f[10]) << 8))
                    // Negate so clockwise twist increases angle, matching USB path.
                    // No centering offset — 0° = natural grip on both BT and USB.
                    var r = rawRot
                    if r < 0 { r += 3600 }
                    state.lastRotation = Double(r) / 10.0  // degrees [0, 360)
                }
                rotation = state.lastRotation
            }

            state.lastX = x
            state.lastY = y

            results.append(
                .pen(
                    TabletPoint(
                        x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: pressure, maxPressure: spec.maxPressure,
                        tiltX: tiltX, tiltY: tiltY, rotation: rotation,
                        penButton1: barrel1,
                        penButton2: barrel2,
                        eraser: isEraser,
                        inProximity: true,
                        hoverDistance: hoverDistance)))
        }

        // Pad sub-report is embedded at a fixed offset in the 361-byte 0x80 container (byte 281).
        // Confirmed from live capture (2026-03-27):
        // byte[281] = center button (0x40 when pressed, 0x00 otherwise)
        // byte[282] = mechanical click pulse — set for exactly one frame on physical press
        // byte[283] = capacitive touch state — set whenever finger rests on key (too sensitive alone)
        // byte[284] = battery: bit7=charging, bits6:0=capacity 0–100 (direct %)
        //             (kernel: wacom_intuos_pro2_bt_battery(), data[284])
        // byte[285] = ring byte: bit7=ring active, bits0-6=position (0–71); 0x7F=no touch
        if length >= 286 {
            let mechanicalByte = report[282]   // one-frame click pulse (rising edge)
            let ringByte = report[285]
            let btnByte = report[281]
            if mechanicalByte != state.lastBTPadKeys   // catches both press (0→n) and release (n→0)
                || ringByte != state.lastBTPadRing
                || btnByte != state.lastBTPadBtn
            {
                state.lastBTPadKeys = mechanicalByte
                state.lastBTPadRing = ringByte
                state.lastBTPadBtn = btnByte
                let buttons = (0..<8).map { (mechanicalByte & (1 << $0)) != 0 }
                let ringActive = ringByte != 0x7F
                results.append(
                    .aux(
                        AuxButtons(
                            buttons: buttons,
                            mechanicalMask: mechanicalByte,
                            touchRingActive: ringActive,
                            touchRingButtonDown: (btnByte & 0x40) != 0,
                            touchRingPosition: ringActive ? (ringByte & 0x7F) : 0x7F)))
            }
        }

        // Battery byte is at offset 284 in the 361-byte BT container.
        // Kernel source: wacom_intuos_pro2_bt_battery(), wacom_wac.c ~line 1503.
        // bit7 = charging flag; bits6:0 = battery percentage (0–100, direct value).
        // Only emit on change to avoid flooding with redundant events.
        if length >= 285 {
            let batByte = report[284]
            if batByte != state.lastBatteryByte {
                state.lastBatteryByte = batByte
                results.append(
                    .battery(percent: Int(batByte & 0x7F), charging: (batByte & 0x80) != 0))
            }
        }

        return results
    }

    // MARK: - BT Classic pen (0x80, length == 99, PTH-860)
    //
    // The PTH-860 uses Bluetooth Classic (advertised as "BT IntuosPro L").
    // The kernel handler wacom_intuos_pro2_bt_irq (INTUOSP2_BT) packs 7 pen frames
    // per packet to compensate for lower BT bandwidth vs USB.
    //
    // Packet layout: [0]=header, [1..14]=frame0, [15..28]=frame1, ..., [85..98]=frame6
    //
    // Per-frame flag byte (f[0]):
    // 0x80 = frame valid — skip entire frame if clear
    // 0x40 = pen in prox — set on proximity entry
    // 0x20 = pen in range — set while hovering or touching
    // 0x08 = eraser tool
    // 0x04 = BTN_STYLUS2 (barrel 2)
    // 0x02 = BTN_STYLUS (barrel 1)
    // 0x01 = BTN_TOUCH
    //
    // Note: tilt bytes are signed two's-complement; a kernel bug (reading unsigned)
    // was patched — we always cast via Int8(bitPattern:).
    // Pad reports over BT Classic use a separate sub-report embedded in the container
    // at an unverified offset; pad decoding is deferred until hardware is available.

    private func decodeBTClassicFrames(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState,
        deviceFamily: String
    ) -> [DecodeResult] {
        guard length >= 99 else { return [] }

        var results: [DecodeResult] = []

        for i in 0..<7 {
            let f = report.advanced(by: 1 + i * 14)

            guard (f[0] & 0x80) != 0 else { continue }  // frame not valid — skip

            let inProx = (f[0] & 0x40) != 0
            let inRange = (f[0] & 0x20) != 0
            let eraser = (f[0] & 0x08) != 0
            let barrel2 = (f[0] & 0x04) != 0
            let barrel1 = (f[0] & 0x02) != 0

            // Genuine firmware exit signal — both prox and inRange lost.
            // Kernel model: exit immediately when !prox && !inRange (0x80).
            if !inProx && !inRange {
                if state.prevInProximity {
                    state.exitFrameCount = 0
                    state.prevInProximity = false
                    state.lastTiltX = 0.0
                    state.lastTiltY = 0.0
                    state.hasValidTiltFrame = false
                    state.lastRotation = 0.0
                    state.hasValidRotationFrame = false
                    results.append(
                        .pen(
                            TabletPoint(
                                x: state.lastX, y: state.lastY,
                                maxX: spec.maxX, maxY: spec.maxY,
                                pressure: 0, maxPressure: spec.maxPressure,
                                tiltX: 0, tiltY: 0, rotation: 0.0,
                                penButton1: false, penButton2: false,
                                eraser: false, inProximity: false, hoverDistance: 0)))
                }
                break
            }

            // Boundary noise: prox=1 but inRange=0 (0xC0). Count consecutive bad frames;
            // exit after exitThreshold to bridge transient oscillations at detection edge.
            if !inRange {
                state.exitFrameCount += 1
                if state.exitFrameCount >= DecoderState.exitThreshold && state.prevInProximity {
                    state.exitFrameCount = 0
                    state.prevInProximity = false
                    state.lastTiltX = 0.0
                    state.lastTiltY = 0.0
                    state.hasValidTiltFrame = false
                    state.lastRotation = 0.0
                    state.hasValidRotationFrame = false
                    results.append(
                        .pen(
                            TabletPoint(
                                x: state.lastX, y: state.lastY,
                                maxX: spec.maxX, maxY: spec.maxY,
                                pressure: 0, maxPressure: spec.maxPressure,
                                tiltX: 0, tiltY: 0, rotation: 0.0,
                                penButton1: false, penButton2: false,
                                eraser: false, inProximity: false, hoverDistance: 0)))
                    break
                }
                // Continue to decode point data — don't suppress output on boundary noise
            } else {
                state.exitFrameCount = 0  // good frame — reset boundary counter
                state.prevInProximity = true
            }

            let (x, y, pressure, rawTiltX, rawTiltY, hoverDistance) = decodeBTFrame(f)
                let tiltX = inRange ? rawTiltX : state.lastTiltX
                let tiltY = inRange ? rawTiltY : state.lastTiltY
                if inRange {
                    state.lastTiltX = tiltX
                    state.lastTiltY = tiltY
                    state.hasValidTiltFrame = true
                }
            // Rotation is NOT available over BT Classic — kernel does not decode
            // f[9:13] (reserved). Rotation only exists in USB Report ID 0x10.

            state.lastX = x
            state.lastY = y

            results.append(
                .pen(
                    TabletPoint(
                        x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                        pressure: pressure, maxPressure: spec.maxPressure,
                        tiltX: tiltX, tiltY: tiltY, rotation: 0.0,
                        penButton1: barrel1, penButton2: barrel2,
                        eraser: eraser, inProximity: true, hoverDistance: hoverDistance)))
        }

        return results
    }

    // MARK: - Aux / express key report (0x11)

    /// Report layout (9 bytes, confirmed by capture):
    /// [0] 0x11 report ID
    /// [1] mechanical click state (use this — physical press required)
    /// [2] capacitive touch state (too sensitive; fires on lightest contact)
    /// [3] touch-ring center button (non-zero while center button is pressed)
    /// [4] touch-ring position, 0–71 (5° resolution); 0x7F = no contact
    /// [5–8] reserved
    ///
    /// Note: ring contact is indicated by posByte != 0x7F, NOT by ringByte.
    /// ringByte is the center button click, which is independent of ring touch.
    private func decodeAuxReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex
    ) -> [DecodeResult] {
        guard length >= 3 else { return [] }
        let mechanicalByte = report[1]
        let ringByte: UInt8 = length >= 5 ? report[3] : 0
        let posByte: UInt8 = length >= 5 ? report[4] : 0x7F
        let buttons = (0..<8).map { bit in (mechanicalByte & (1 << bit)) != 0 }
        let ringActive = posByte != 0x7F  // finger on ring (position valid)
        let ringButtonDown = ringByte != 0  // center button pressed
        return [
            .aux(
                AuxButtons(
                    buttons: buttons,
                    mechanicalMask: mechanicalByte,
                    touchRingActive: ringActive,
                    touchRingButtonDown: ringButtonDown,
                    touchRingPosition: ringActive ? posByte : 0x7F))
        ]
    }

    // MARK: - Wireless status (0x80)

    private func decodeWireless(
        report: UnsafePointer<UInt8>,
        length: CFIndex
    ) -> [DecodeResult] {
        guard length >= 2 else { return [] }
        switch report[1] {
        case 0x02: return [.wireless(.active)]
        case 0x05: return [.wireless(.lost)]
        case 0x06: return [.wireless(.lowBattery)]
        default: return [.wireless(.unknown(report[1]))]
        }
    }
}
