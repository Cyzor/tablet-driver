// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

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

    // BT-side decoders (0x80 in its many shapes) and the shared per-frame
    // helper live in `IntuosV2Decoder+BT.swift`.

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
        let rawRot = Int16(bitPattern: UInt16(report[12]) | UInt16(report[13]) << 8)
        // Rotation: signed Int16 with +/-900 range. Kernel formula: (raw + 900) / 5.
        // Negated here so clockwise twist produces increasing degrees, matching what
        // macOS apps (Photoshop, Krita, Illustrator) expect from a native Wacom driver.
        var rotation = isArtPen ? (900.0 - Double(rawRot)) / 5.0 : 0.0
        if rotation < 0 { rotation += 360.0 }
        if rotation >= 360 { rotation -= 360.0 }
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

}
