// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

// Bluetooth-side decoders for the IntuosV2 family. Split out from
// `IntuosV2Decoder.swift` to keep each file under ~500 lines and to group
// the shared per-frame helper next to the only callers that use it.
//
// Covers:
//   • 0x80 / 361-byte container — PTH-660 BT Classic (single frame + pad + battery)
//   • 0x80 / 99-byte container  — PTH-860 BT Classic (7 packed pen frames)
//   • 0x80 RF wireless status   — ACK-40401 dongle
//
// USB and BLE paths remain in `IntuosV2Decoder.swift`.

import Foundation

extension IntuosV2Decoder {

    // MARK: - BT frame coordinate/pressure/tilt helper

    /// Decode coordinate, pressure, and tilt from a BT per-frame buffer (used by both
    /// 361-byte and 99-byte BT paths). Offsets and interpretation are identical in both formats.
    /// Pressure formula is canonical (mask high byte first).
    func decodeBTFrame(_ f: UnsafePointer<UInt8>)
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

    // MARK: - BT Wireless pen (0x80, Bluetooth Classic/LE transport variant)
    //
    // Coordinates and pressure use the same LE uint16 layout as the BLE HOGP 0x01 report.
    // Per-frame flag byte (frame[0]) — confirmed against kernel wacom_intuos_pro2_bt_pen()
    // (drivers/hid/wacom_wac.c, INTUOSP2_BT branch):
    //   0x80 = valid frame
    //   0x40 = proximity
    //   0x20 = range (in-range vs hover/contact distinction)
    //   0x10 = invert (selects BTN_TOOL_RUBBER vs BTN_TOOL_PEN at first-in-range)
    //   0x09 = BTN_TOUCH mask (kernel reports tip as bit0 OR bit3)
    //   0x04 = BTN_STYLUS2 (barrel button 2)
    //   0x02 = BTN_STYLUS (barrel button 1)
    //
    // Note: bits 4 and 5 are NOT additional buttons (earlier comment speculated they
    // were — kernel confirms otherwise). Per-frame eraser detection below reads bit 3
    // (0x08); this is empirically correct for IntuosV2 BT and consistent with the
    // kernel's tip-mask logic, since the eraser end's contact bit lights up bit 3.
    // The toolEnter event independently establishes eraser-ness from the tool code at
    // bytes 103:104, so downstream consumers see the correct tool regardless.

    func decodeBTPen(
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
            // Each frame is 14 bytes; body reads through f[13] (hoverDistance).
            // Stop early if the report is truncated mid-frame. Bounds-check
            // spirit of upstream input-wacom 09bc480.
            guard frameOffset + 14 <= length else { break }
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
                    // Invert direction to match USB path: clockwise twist → increasing degrees.
                    var r = rawRot
                    if r < 0 { r += 3600 }
                    state.lastRotation = Double((3600 - r) % 3600) / 10.0  // degrees [0, 360)
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

    // MARK: - BT finger touch (embedded in 0x80 / 361-byte container)
    //
    // Touch data is woven into the same 361-byte 0x80 report as the pen:
    //   [109..280] = 4 frames × 43 bytes
    // Layout matches `wacom_intuos_pro2_bt_touch()` in
    // drivers/hid/wacom_wac.c (Linux kernel, INTUOSP2_BT branch).
    //
    // Per frame (43 bytes):
    //   [0] = bit7 frame-valid, bits 0..6 = total contact count for the set
    //         (only the first valid frame in a set carries a non-zero count;
    //         the kernel state-machines this across frames to support >5
    //         contacts.  PTH-660/660/860 max 5 fingers, so for V1 we treat
    //         each frame independently and ignore count==0 frames.)
    //   [1..]: up to 5 contacts, 8 bytes each
    //
    // Per contact (8 bytes):
    //   [0] = slot_id  (stable across frames per finger)
    //   [1] = status   (bit0 = down; 0 = lift)
    //   [2..3] = X LE16
    //   [4..5] = Y LE16
    //   [6] = touch major (w)
    //   [7] = touch minor (h)
    //
    // Emits one `.touch` per valid frame so `TouchStateTracker` sees per-time-
    // slice snapshots, mirroring the cadence of the USB 0x21 path (one frame
    // per report there).  Lift contacts (status & 0x01 == 0) are filtered at
    // the decoder boundary, matching the USB decoder; the tracker recovers
    // the lift by seeing the absence on the next emission.
    func decodeBTTouch(
        report: UnsafePointer<UInt8>,
        length: CFIndex
    ) -> [DecodeResult] {
        let frameBase = 109
        let frameLen = 43
        let frameCount = 4
        guard length >= frameBase + frameLen * frameCount else { return [] }

        var results: [DecodeResult] = []
        for i in 0 ..< frameCount {
            let off = frameBase + i * frameLen
            let header = report[off]
            guard (header & 0x80) != 0 else { continue }      // frame-valid bit
            let count = Int(header & 0x7F)
            guard count > 0 else { continue }                  // continuation frame; V1 ignores
            let slots = Swift.min(count, 5)
            var contacts: [TouchContact] = []
            contacts.reserveCapacity(slots)
            for j in 0 ..< slots {
                let cOff = off + 1 + j * 8
                guard (report[cOff + 1] & 0x01) != 0 else { continue }  // lift → drop
                let x = Int(report[cOff + 2]) | (Int(report[cOff + 3]) << 8)
                let y = Int(report[cOff + 4]) | (Int(report[cOff + 5]) << 8)
                let major = Int(report[cOff + 6])
                contacts.append(TouchContact(
                    id: Int(report[cOff]), x: x, y: y, contactArea: major))
            }
            results.append(.touch(contacts))
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

    func decodeBTClassicFrames(
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

    // MARK: - Wireless status (0x80)

    func decodeWireless(
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
