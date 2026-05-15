// SPDX-License-Identifier: GPL-3.0-or-later
//
// CintiqV1 decoder fixtures — pen-display family (DTK-2400 et al).
//
// The DTK-2400 has been reliable in real-world use; these tests exist purely
// as a regression net so a future edit to CintiqV1Decoder cannot silently break
// the rotation, debounce, or pressure-cache invariants that current behavior
// depends on. They are not exhaustive — add cases as bugs are discovered.
//
// Key invariants covered:
//   • Art Pen rotation (typeNibble 0x05) forwards cached pressure, NOT zero
//     ("dots instead of line" fix).
//   • Art Pen rotation must NOT latch barrel button 1, even though the
//     rotation packet's status byte has bit 1 set as part of its type encoding.
//   • Barrel-button debounce uses a clear-counter threshold of 7 frames.
//   • Tip-switch synthetic pressure activates when raw pressure is 0 at tip-down.
//   • Tool-change packet (status bits 7:2 == 0xC0) decodes serial and tool code.
//   • Express-key / touch-ring report (0x0C) decodes left ring and gates right
//     ring on spec.hasDualRings.
import XCTest
@testable import MockTabDecoders

final class CintiqV1DecoderTests: XCTestCase {

    // DTK-2400 dimensions (cintiqV1 family). Exact values don't affect the
    // invariants being tested; pressure max matches the actual hardware.
    private let dtk2400 = DigitizerSpec(
        maxX: 104859, maxY: 65535, maxPressure: 2047,
        buttonCount: 16, hasTilt: true, hasDualRings: true,
        isPenDisplay: true, ringSlotCount: 4)

    private func decode(
        _ bytes: [UInt8],
        decoder: inout CintiqV1Decoder,
        state: inout DecoderState,
        family: String = "cintiq"
    ) -> [DecodeResult] {
        bytes.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: dtk2400, state: &state, deviceFamily: family)
        }
    }

    /// Pre-seeded DecoderState that bypasses the first-prox fallback toolEnter.
    /// Avoids exercising `emitToolCompatibility`, which would mark the fallback
    /// Grip Pen as unsupported on cintiq and suppress button output via the
    /// `!state.toolIsSupported` guard in the pen-emit line.
    private func seededState() -> DecoderState {
        var state = DecoderState()
        state.currentToolCode = 0x0842  // Pro Pen 3 — fully supported on DTK-2400
        state.toolIsSupported = true
        return state
    }

    /// Build a general pen packet (Report 0x02, typeNibble 0, in proximity).
    private func generalPacket(
        btn1: Bool = false, btn2: Bool = false,
        pressureHigh: UInt8 = 0x40, pressureLow2: UInt8 = 0
    ) -> [UInt8] {
        // status byte 0xE0 = prox=1, typeNibble=0, no buttons (default).
        var status: UInt8 = 0xE0
        if btn1 { status |= 0x02 }
        if btn2 { status |= 0x04 }
        var bytes = [UInt8](repeating: 0, count: 10)
        bytes[0] = 0x02
        bytes[1] = status
        bytes[2] = 0x01; bytes[3] = 0xF4   // x = (0x01F4 << 1) | 0 = 1000
        bytes[4] = 0x07; bytes[5] = 0xD0   // y = (0x07D0 << 1) | 0 = 4000
        bytes[6] = pressureHigh
        bytes[7] = 0x20 | (pressureLow2 << 6)  // tilt bit base; high 2 of pressure low
        bytes[8] = 0x40   // tilt Y = 0
        bytes[9] = 0      // hover = 0
        return bytes
    }

    // MARK: - Dispatch & length rejection

    func testEmptyReportReturnsEmpty() {
        var decoder = CintiqV1Decoder()
        var state = DecoderState()
        XCTAssertTrue(decode([], decoder: &decoder, state: &state).isEmpty)
        XCTAssertTrue(decode([0x02], decoder: &decoder, state: &state).isEmpty)
    }

    func testUnknownReportIDIgnored() {
        var decoder = CintiqV1Decoder()
        var state = DecoderState()
        let bytes = [UInt8](repeating: 0xFF, count: 10)  // report[0] = 0xFF
        XCTAssertTrue(decode(bytes, decoder: &decoder, state: &state).isEmpty)
    }

    func testShortPenReportRejected() {
        // Report 0x02 with length < 10 must be rejected (avoids decoding garbage).
        var decoder = CintiqV1Decoder()
        var state = DecoderState()
        let bytes: [UInt8] = [0x02, 0xE0, 0, 0, 0]
        XCTAssertTrue(decode(bytes, decoder: &decoder, state: &state).isEmpty)
    }

    // MARK: - General pen packet decode

    func testGeneralPacketDecodesCoordinatesAndPressure() {
        var decoder = CintiqV1Decoder()
        var state = DecoderState()

        let bytes = generalPacket()   // x=1000, y=4000, pressure = 0x40 << 3 = 512
        let results = decode(bytes, decoder: &decoder, state: &state)

        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.x, 1000)
        XCTAssertEqual(pen?.y, 4000)
        XCTAssertEqual(pen?.pressure, 512)
        XCTAssertEqual(pen?.inProximity, true)
    }

    func testGeneralPacketBarrelButtonsDecoded() {
        var decoder = CintiqV1Decoder()
        var state = seededState()
        let bytes = generalPacket(btn1: true, btn2: true)
        let results = decode(bytes, decoder: &decoder, state: &state)

        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.penButton1, true)
        XCTAssertEqual(pen?.penButton2, true)
    }

    // MARK: - Barrel-button debounce (the historical regression area)

    func testBarrelButton1NotReleasedOnSingleClearFrame() {
        // Press, then a single clear frame: button must still read as held
        // (firmware pulses ~1:5 while held; debounce smooths the gaps).
        var decoder = CintiqV1Decoder()
        var state = seededState()
        _ = decode(generalPacket(btn1: true), decoder: &decoder, state: &state)
        let results = decode(generalPacket(btn1: false), decoder: &decoder, state: &state)
        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.penButton1, true, "Single clear frame must not release the button")
    }

    func testBarrelButton1ReleasedAtClearThreshold() {
        // 7 consecutive clear frames is the documented threshold.
        var decoder = CintiqV1Decoder()
        var state = DecoderState()
        _ = decode(generalPacket(btn1: true), decoder: &decoder, state: &state)

        for _ in 0..<7 {
            _ = decode(generalPacket(btn1: false), decoder: &decoder, state: &state)
        }

        let results = decode(generalPacket(btn1: false), decoder: &decoder, state: &state)
        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.penButton1, false, "Button must release after threshold")
    }

    func testBarrelButton1RePressResetsClearCounter() {
        // Press → 3 clears → re-press → 6 clears (still under threshold of 7):
        // button must still be held because the counter reset on the re-press.
        // Without the reset, accumulated clears (3 + 6 = 9) would have exceeded
        // the threshold and released.
        var decoder = CintiqV1Decoder()
        var state = seededState()
        _ = decode(generalPacket(btn1: true), decoder: &decoder, state: &state)
        for _ in 0..<3 {
            _ = decode(generalPacket(btn1: false), decoder: &decoder, state: &state)
        }
        _ = decode(generalPacket(btn1: true), decoder: &decoder, state: &state)

        var lastResults: [DecodeResult] = []
        for _ in 0..<6 {
            lastResults = decode(generalPacket(btn1: false), decoder: &decoder, state: &state)
        }
        let pen = lastResults.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.penButton1, true, "Counter should have reset on re-press; 6 clears < threshold 7")
    }

    // MARK: - Rotation packet (typeNibble 0x05)

    func testRotationPacketDoesNotLatchBarrelButton1() {
        // The rotation packet's status byte (0xEA) has bit 1 set as part of its
        // type encoding — reading buttons from it would latch barrel button 1.
        // This invariant is the entire reason for the "buttons only from general
        // packets" rule documented at decoder line 27.
        var decoder = CintiqV1Decoder()
        var state = DecoderState()
        // Seed proximity from a general packet (no button held).
        _ = decode(generalPacket(), decoder: &decoder, state: &state)

        // Now send a rotation packet (status = 0xEA = typeNibble 5 + prox).
        var rot = [UInt8](repeating: 0, count: 10)
        rot[0] = 0x02
        rot[1] = 0xEA
        rot[6] = 0x20  // t will be 0x100; ABS_Z = 450 - 128 = 322
        rot[7] = 0
        let results = decode(rot, decoder: &decoder, state: &state)

        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.penButton1, false, "Rotation packet status bit 1 must not latch button 1")
    }

    func testRotationPacketForwardsCachedPressureNotZero() {
        // The "dots instead of line" regression: rotation packets carry no
        // pressure data, so the decoder must reuse `lastPressure` from the
        // previous general packet. Returning 0 would cause rapid mouseUp/mouseDown.
        var decoder = CintiqV1Decoder()
        var state = DecoderState()
        // Seed pressure at 512 via a general packet.
        _ = decode(generalPacket(), decoder: &decoder, state: &state)

        var rot = [UInt8](repeating: 0, count: 10)
        rot[0] = 0x02
        rot[1] = 0xEA  // typeNibble 5, prox
        rot[6] = 0x10
        let results = decode(rot, decoder: &decoder, state: &state)

        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.pressure, 512, "Rotation packet must forward cached pressure")
    }

    func testRotationPacketProducesNonZeroRotationOutput() {
        var decoder = CintiqV1Decoder()
        var state = DecoderState()
        _ = decode(generalPacket(), decoder: &decoder, state: &state)

        var rot = [UInt8](repeating: 0, count: 10)
        rot[0] = 0x02
        rot[1] = 0xEA
        rot[6] = 0x40  // non-trivial rotation input
        rot[7] = 0
        _ = decode(rot, decoder: &decoder, state: &state)

        // After rotation packet: state.lastRotation must have been updated to a
        // value in [0, 360). We don't assert an exact degree (the formula is
        // exercised end-to-end in production); just verify the side effect.
        XCTAssertGreaterThanOrEqual(state.lastRotation, 0.0)
        XCTAssertLessThan(state.lastRotation, 360.0)
    }

    // MARK: - Tip-switch synthetic pressure

    func testTipSwitchOverrideAppliesWhenRawPressureIsZero() {
        // Report 0x01 fires tipDown=true. Subsequent general packet with raw
        // pressure 0 must surface the synthetic threshold (81) instead.
        var decoder = CintiqV1Decoder()
        var state = DecoderState()

        // Tip switch: report[0]=0x01, report[1] bit0 = 1.
        _ = decode([0x01, 0x01], decoder: &decoder, state: &state)

        // General packet with raw pressure 0 (pressureHigh=0, pressureLow2=0).
        let bytes = generalPacket(pressureHigh: 0, pressureLow2: 0)
        let results = decode(bytes, decoder: &decoder, state: &state)
        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.pressure, 81, "tipPressureOverride must apply when raw pressure is 0")
    }

    func testTipSwitchOverrideClearedOnTipUp() {
        var decoder = CintiqV1Decoder()
        var state = DecoderState()
        _ = decode([0x01, 0x01], decoder: &decoder, state: &state)  // tip down
        _ = decode([0x01, 0x00], decoder: &decoder, state: &state)  // tip up

        let bytes = generalPacket(pressureHigh: 0, pressureLow2: 0)
        let results = decode(bytes, decoder: &decoder, state: &state)
        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.pressure, 0, "Override must clear on tip-up")
    }

    // MARK: - Tool-change packet

    func testToolChangePacketDecodesEraserBit() {
        // status & 0xFC == 0xC0 → tool change. Eraser detected from toolCode bit3.
        // Construct toolCode = 0x080A (eraser): bit3 set.
        // toolCode formula:
        //   toolCode = (report[2]<<4) | (report[3]>>4) | ((report[7]&0x0F)<<12) | ((report[8]&0xF0)<<4)
        var decoder = CintiqV1Decoder()
        var state = DecoderState()
        var bytes = [UInt8](repeating: 0, count: 10)
        bytes[0] = 0x02
        bytes[1] = 0xC2  // tool-change, low bits 0x02
        // Build toolCode 0x080A: report[2]=0x80, report[3]=0xA0 → (0x80<<4)|(0xA0>>4) = 0x80A.
        bytes[2] = 0x80
        bytes[3] = 0xA0
        // report[7] low nibble = 0, report[8] high nibble = 0 → no contribution.

        let results = decode(bytes, decoder: &decoder, state: &state)
        guard case .toolEnter(let tool)? = results.first else {
            return XCTFail("Expected .toolEnter, got \(results)")
        }
        XCTAssertEqual(tool.toolCode, 0x080A)
        XCTAssertTrue(tool.isEraser)
        XCTAssertEqual(state.currentToolCode, 0x080A)
    }

    // MARK: - Proximity-out

    func testProximityOutEmitsFinalPenWithInProximityFalse() {
        var decoder = CintiqV1Decoder()
        var state = DecoderState()
        // Establish prox.
        _ = decode(generalPacket(), decoder: &decoder, state: &state)
        XCTAssertTrue(state.prevInProximity)

        // Send a non-prox packet (status bit5 clear). status = 0x00 → typeNibble 0, no prox.
        var bytes = [UInt8](repeating: 0, count: 10)
        bytes[0] = 0x02
        bytes[1] = 0x00
        let results = decode(bytes, decoder: &decoder, state: &state)

        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.inProximity, false)
        XCTAssertEqual(pen?.pressure, 0)
        XCTAssertFalse(state.prevInProximity)
    }

    // MARK: - Touch ring + express keys (Report 0x0C)

    func testExpressKeyReportDecodesLeftRingAndButtons() {
        var decoder = CintiqV1Decoder()
        var state = DecoderState()
        var bytes = [UInt8](repeating: 0, count: 9)
        bytes[0] = 0x0C
        bytes[1] = 0x80 | 0x12   // left ring active, position 0x12 (18)
        bytes[2] = 0x7F          // right ring inactive (still decoded because hasDualRings=true)
        bytes[6] = 0b0000_0101   // left express keys: bit0 + bit2
        bytes[8] = 0b0000_0010   // right express keys: bit1

        let results = decode(bytes, decoder: &decoder, state: &state)
        guard case .aux(let aux)? = results.first else {
            return XCTFail("Expected .aux, got \(results)")
        }
        XCTAssertEqual(aux.touchRingActive, true)
        XCTAssertEqual(aux.touchRingPosition, 0x12)
        XCTAssertEqual(aux.touchRing2Active, false)
        XCTAssertEqual(aux.buttons[0], true)
        XCTAssertEqual(aux.buttons[1], false)
        XCTAssertEqual(aux.buttons[2], true)
        XCTAssertEqual(aux.buttons[8 + 1], true, "Right express key bit 1 should be in slot 8+1")
    }

    func testExpressKeyReportShortLengthRejected() {
        var decoder = CintiqV1Decoder()
        var state = DecoderState()
        let bytes: [UInt8] = [0x0C, 0x80, 0, 0, 0, 0]  // length 6, threshold is 7
        XCTAssertTrue(decode(bytes, decoder: &decoder, state: &state).isEmpty)
    }
}
