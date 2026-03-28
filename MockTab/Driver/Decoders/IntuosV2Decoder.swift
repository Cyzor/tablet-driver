import Foundation

/// Decoder for the Wacom IntuosV2 HID report format.
///
/// Used by: PTH-460 (0x0356), PTH-660 (0x0357), PTH-860 (0x0358)
/// and any future tablet using the 192-byte IntuosV2 report layout.
///
/// Report ID routing:
///   0x01  BLE HOGP pen report (23 bytes)
///   0x03  BLE HOGP pad report (9 bytes)
///   0x10  Standard USB pen report (192 bytes) — main path
///   0x1E  Offset pen report (driver-compatibility mode)
///   0x11  Auxiliary (express key + touch ring) report
///   0x80  Wireless status report (ACK-40401 RF dongle)
struct IntuosV2Decoder: WacomDecoder {

    func decode(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState
    ) -> [DecodeResult] {
        guard length >= 2 else { return [] }
        switch report[0] {
        case 0x01:
            // The PTH-660/860 expose a standard USB HID mouse interface (usagePage=0x01)
            // that carries 4-byte button reports for cordless mouse accessories (KC-100).
            // BLE HOGP pen reports share Report ID 0x01 but are ≥ 23 bytes.
            // Distinguish by length: ≤ 8 bytes → USB mouse buttons; otherwise → BLE pen.
            if length <= 8 {
                // [0]=0x01  [1]=buttons(bit0=L,bit1=R,bit2=M)  [2]=relX  [3]=relY
                return [.mouseButton(report[1])]
            }
            return decodeBLEPen(report: report, length: length, spec: spec, state: &state)
        case 0x03:
            guard let aux = decodeBLEPadReport(report: report, length: length) else { return [] }
            return [.aux(aux)]
        case 0x10:
            guard length >= 12 else { return [] }
            return decodePenReport(report: report, length: length, spec: spec, state: &state)
        case 0x1E:
            return decodeOffsetPenReport(report: report, length: length, spec: spec)
        case 0x11:
            return decodeAuxReport(report: report, length: length)
        case 0x80:
            // Bluetooth-transport pen reports share report ID 0x80 with the RF-dongle
            // wireless status byte.  Distinguish by report[1]:
            //   0x02/0x05/0x06 → RF wireless status (active / lost / low-battery)
            //   anything else  → BT HID pen data (BLE-layout coordinates, different flag bits)
            if length >= 2 && (report[1] == 0x02 || report[1] == 0x05 || report[1] == 0x06) {
                return decodeWireless(report: report, length: length)
            }
            return decodeBTPen(report: report, length: length, spec: spec, state: &state)
        default:
            return []
        }
    }

    // MARK: - Standard pen report (0x10)

    private func decodePenReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState
    ) -> [DecodeResult] {
        let status = report[1]
        let highConfidence = (status & 0x20) != 0

        // Proximity-out: all position bytes zero and confidence lost.
        let allZero =
            report[2] == 0 && report[3] == 0 && report[4] == 0
            && report[5] == 0 && report[6] == 0 && report[7] == 0
        if allZero && !highConfidence {
            state.prevInProximity = false
            return [.pen(TabletPoint(
                x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                pressure: 0, maxPressure: spec.maxPressure,
                tiltX: 0, tiltY: 0, rotation: 0.0,
                penButton1: false, penButton2: false,
                eraser: false, inProximity: false, hoverDistance: 0))]
        }

        // NOTE: keep barrel-button and eraser bits from status — highConfidence is a
        // position-quality flag independent of which physical buttons are held.
        guard highConfidence else {
            state.prevInProximity = false
            return [.pen(TabletPoint(
                x: state.lastX, y: state.lastY, maxX: spec.maxX, maxY: spec.maxY,
                pressure: 0, maxPressure: spec.maxPressure,
                tiltX: 0, tiltY: 0, rotation: 0.0,
                penButton1: (status & 0x02) != 0,
                penButton2: (status & 0x04) != 0,
                eraser: (status & 0x08) != 0,
                inProximity: true, hoverDistance: 0))]
        }

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
            state.currentToolCode = toolCode

            let toolChanged = serial != 0
                ? serial != state.lastSerial
                : (toolCode != 0 && toolCode != state.lastToolCode)
            if toolChanged {
                state.lastSerial   = serial
                state.lastToolCode = toolCode
                let isMouse = (toolCode & 0x000F) == 0x0006
                state.toolIsMouse = isMouse
                // Seed scroll counter to avoid a large spurious delta on first mouse report.
                if isMouse { state.lastScrollPos = report[16] }
                results.append(.toolEnter(ToolIdentity(
                    serial: serial,
                    toolCode: toolCode,
                    isEraser: (toolCode & 0x0008) != 0,
                    isMouse: isMouse)))
            }
        }

        // IntuosV2 coordinate decode — 24-bit LE (2 bytes + 1-byte extension).
        let x = Int(UInt16(report[2]) | UInt16(report[3]) << 8) | (Int(report[4]) << 16)
        let y = Int(UInt16(report[5]) | UInt16(report[6]) << 8) | (Int(report[7]) << 16)
        state.lastX = x
        state.lastY = y

        // ── Mouse path ─────────────────────────────────────────────────────────
        // Byte [16] is an absolute 8-bit counter that wraps at 255.  Signed delta
        // via Int8(bitPattern:) handles wrap-around correctly (255→0 = +1 step).
        if (state.currentToolCode & 0x000F) == 0x0006 && state.currentToolCode != 0 {
            let scrollPos = report[16]
            let wheelDelta = Int(Int8(bitPattern: scrollPos &- state.lastScrollPos))
            state.lastScrollPos = scrollPos
            results.append(.pen(TabletPoint(
                x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
                pressure: 0, maxPressure: spec.maxPressure,
                tiltX: 0, tiltY: 0, rotation: 0.0,
                penButton1: (status & 0x02) != 0,
                penButton2: (status & 0x04) != 0,
                eraser: false, inProximity: true, hoverDistance: 0,
                mouseMiddleButton: (report[9] & 0x02) != 0,
                mouseWheelDelta: wheelDelta)))
            return results
        }

        // ── Pen path ───────────────────────────────────────────────────────────
        let pressure = Int(UInt16(report[8]) | UInt16(report[9]) << 8)
        let tiltX = Double(Int8(bitPattern: report[10])) / 127.0
        let tiltY = Double(Int8(bitPattern: report[11])) / 127.0

        // Rotation (Twist): Bytes 12–13, signed 16-bit, scaled by 10 (e.g. 1800 = 180.0°).
        // Only valid for Art Pen (0x0804); other pens report garbage/defaults.
        let isArtPen = (state.currentToolCode & 0x0FF6) == 0x0804
        let rawRot = Int16(bitPattern: UInt16(report[12]) | UInt16(report[13]) << 8)
        var rotation = isArtPen ? Double(rawRot) / 10.0 : 0.0
        if rotation < 0 { rotation += 360.0 }

        results.append(.pen(TabletPoint(
            x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
            pressure: pressure, maxPressure: spec.maxPressure,
            tiltX: tiltX, tiltY: tiltY, rotation: rotation,
            penButton1: (status & 0x02) != 0,
            penButton2: (status & 0x04) != 0,
            eraser: (status & 0x08) != 0,
            inProximity: true,
            hoverDistance: Int(report[16]))))
        return results
    }

    // MARK: - Offset pen report (0x1E, driver-compatibility mode)

    private func decodeOffsetPenReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec
    ) -> [DecodeResult] {
        guard length >= 13 else { return [] }
        let status = report[2]
        let x = Int(UInt16(report[3]) | UInt16(report[4]) << 8) | (Int(report[5]) << 16)
        let y = Int(UInt16(report[6]) | UInt16(report[7]) << 8) | (Int(report[8]) << 16)
        let pressure = Int(UInt16(report[9]) | UInt16(report[10]) << 8)
        let tiltX = Double(Int8(bitPattern: report[11])) / 127.0
        let tiltY = Double(Int8(bitPattern: report[12])) / 127.0
        return [.pen(TabletPoint(
            x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
            pressure: pressure, maxPressure: spec.maxPressure,
            tiltX: tiltX, tiltY: tiltY, rotation: 0.0,
            penButton1: (status & 0x02) != 0,
            penButton2: (status & 0x04) != 0,
            eraser: (status & 0x08) != 0,
            inProximity: (status & 0x20) != 0,
            hoverDistance: 0))]
    }

    // MARK: - BLE HOGP pen (0x01)

    private func decodeBLEPen(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState
    ) -> [DecodeResult] {
        guard let result = decodeBLEPenReport(
            report: report, length: length, spec: spec,
            lastX: &state.lastX, lastY: &state.lastY
        ) else { return [] }

        var results: [DecodeResult] = []
        if result.toolCode != 0
            && (result.serial != state.lastSerial || result.toolCode != state.lastToolCode)
        {
            state.lastSerial      = result.serial
            state.lastToolCode    = result.toolCode
            state.currentToolCode = result.toolCode
            state.toolIsMouse     = result.isMouse
            results.append(.toolEnter(ToolIdentity(
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
    //   bit7 (0x80) = inProximity  (confirmed: 0x00 = no pen, 0xC0 = hovering)
    //   bit6 (0x40) = frame-valid / "digitizer active" — always set during proximity,
    //                 NOT a button. Masking it out fixes spurious middle-click on hover.
    //   bit5 (0x20) = button assignment TBD — tentatively barrel1
    //   bit4 (0x10) = button assignment TBD — tentatively barrel2
    //   bit3 (0x08) = TBD (eraser?)
    // TODO: confirm bit4–5 assignments from live capture with buttons pressed.

    private func decodeBTPen(
        report: UnsafePointer<UInt8>,
        length: CFIndex,
        spec: DigitizerSpec,
        state: inout DecoderState
    ) -> [DecodeResult] {
        guard length >= 6 else { return [] }

        let flags       = report[1]
        let inProximity = (flags & 0x80) != 0
        // Confirmed bit layout from live capture:
        //   bit7 (0x80) = inProximity
        //   bit6 (0x40) = frame-valid (always 1 during proximity, not a button)
        //   bit5 (0x20) = high-confidence / signal-stable (0 on first frame, 1 after)
        //   bit2 (0x04) = barrel2 / upper button (BTN_STYLUS2) — same mask as USB 0x10
        //   bit1 (0x02) = barrel1 / lower button (BTN_STYLUS)  — same mask as USB 0x10
        //   bit0 (0x01) = tip touching surface (redundant with pressure > 0)
        let barrel1     = (flags & 0x02) != 0
        let barrel2     = (flags & 0x04) != 0

        let x        = Int(UInt16(report[2]) | UInt16(report[3]) << 8)
        let y        = Int(UInt16(report[4]) | UInt16(report[5]) << 8)
        let pressure: Int = length >= 8 ? Int(UInt16(report[6]) | UInt16(report[7]) << 8) : 0
        let distance: Int = length >= 9  ? Int(report[8])                              : 0
        let tiltX: Double = length >= 10 ? Double(Int8(bitPattern: report[9]))  / 127.0 : 0
        let tiltY: Double = length >= 11 ? Double(Int8(bitPattern: report[10])) / 127.0 : 0

        // Serial and toolCode byte positions are unconfirmed for the BT 0x80 container.
        // Bytes [11–14] appear to encode hover distance (counts down as pen moves), not serial.
        // Bytes [15–16] appear to be flags/X of an embedded second sub-report, not toolCode.
        // Setting both to 0 suppresses spurious toolEnter events on every frame until
        // we confirm the correct offsets from a live capture.
        let serial: UInt32   = 0
        let toolCode: UInt16 = 0

        let isEraser = false
        let isMouse  = false

        if inProximity {
            state.lastX = x
            state.lastY = y
        }

        var results: [DecodeResult] = []

        if toolCode != 0 && (serial != state.lastSerial || toolCode != state.lastToolCode) {
            state.lastSerial      = serial
            state.lastToolCode    = toolCode
            state.currentToolCode = toolCode
            state.toolIsMouse     = isMouse
            results.append(.toolEnter(ToolIdentity(
                serial: serial, toolCode: toolCode,
                isEraser: isEraser, isMouse: isMouse)))
        }

        results.append(.pen(TabletPoint(
            x: inProximity ? x : state.lastX,
            y: inProximity ? y : state.lastY,
            maxX: spec.maxX, maxY: spec.maxY,
            pressure: inProximity ? pressure : 0,
            maxPressure: spec.maxPressure,
            tiltX: tiltX, tiltY: tiltY, rotation: 0.0,
            penButton1: barrel1,
            penButton2: barrel2,
            eraser: isEraser,
            inProximity: inProximity,
            hoverDistance: distance)))

        // Pad sub-report is embedded at a fixed offset in the 361-byte 0x80 container.
        // Confirmed from live capture (2026-03-27):
        //   byte[281] = center button (0x40 when pressed, 0x00 otherwise)
        //   byte[282] = key first-frame only (transition; prefer byte[283] for state)
        //   byte[283] = express key bitmask (bit0=key1 ... bit7=key8; direct, no shift)
        //   byte[284] = 0x58 (constant pad-type marker)
        //   byte[285] = ring byte: bit7=ring active, bits0-6=position (0–71); 0x7F=no touch
        if length >= 286 {
            let keyByte = report[283]
            let ringByte = report[285]
            let btnByte  = report[281]
            if keyByte != state.lastBTPadKeys
                || ringByte != state.lastBTPadRing
                || btnByte  != state.lastBTPadBtn
            {
                state.lastBTPadKeys = keyByte
                state.lastBTPadRing = ringByte
                state.lastBTPadBtn  = btnByte
                let buttons    = (0..<8).map { (keyByte & (1 << $0)) != 0 }
                let ringActive = ringByte != 0x7F
                results.append(.aux(AuxButtons(
                    buttons: buttons,
                    touchRingActive: ringActive,
                    touchRingButtonDown: btnByte != 0,
                    touchRingPosition: ringActive ? (ringByte & 0x7F) : 0x7F)))
            }
        }

        return results
    }

    // MARK: - Aux / express key report (0x11)

    /// Report layout (9 bytes, confirmed by capture):
    ///   [0]  0x11  report ID
    ///   [1]  mechanical click state (use this — physical press required)
    ///   [2]  capacitive touch state (too sensitive; fires on lightest contact)
    ///   [3]  touch-ring center button (non-zero while center button is pressed)
    ///   [4]  touch-ring position, 0–71 (5° resolution); 0x7F = no contact
    ///   [5–8] reserved
    ///
    /// Note: ring contact is indicated by posByte != 0x7F, NOT by ringByte.
    /// ringByte is the center button click, which is independent of ring touch.
    private func decodeAuxReport(
        report: UnsafePointer<UInt8>,
        length: CFIndex
    ) -> [DecodeResult] {
        guard length >= 3 else { return [] }
        let auxByte  = report[1]
        let ringByte: UInt8 = length >= 5 ? report[3] : 0
        let posByte:  UInt8 = length >= 5 ? report[4] : 0x7F
        let buttons        = (0..<8).map { bit in (auxByte & (1 << bit)) != 0 }
        let ringActive     = posByte != 0x7F   // finger on ring (position valid)
        let ringButtonDown = ringByte != 0     // center button pressed
        return [.aux(AuxButtons(
            buttons: buttons,
            touchRingActive: ringActive,
            touchRingButtonDown: ringButtonDown,
            touchRingPosition: ringActive ? posByte : 0x7F))]
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
        default:   return [.wireless(.unknown(report[1]))]
        }
    }
}
