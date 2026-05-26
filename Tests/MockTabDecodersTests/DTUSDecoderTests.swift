// SPDX-License-Identifier: GPL-3.0-or-later
//
// DTUS decoder fixtures (DTK-1651, DTU-1031/1031X/1141).
//
// No hardware capture is available; reports are synthesized from the
// byte-layout comments in DTUSDecoder.swift and the input-wacom
// wacom_dtus_irq source (4.18/wacom_wac.c ~L306).
//
// Report IDs covered:
//   • 0x11 — pen report, 7 bytes (BE16 X/Y, 10-bit pressure split,
//             tool-type eraser inference, pen buttons)
//   • 0x15 — pad report, 2 bytes (4 express keys in low nibble)
import XCTest
@testable import TabletKit

final class DTUSDecoderTests: XCTestCase {

    private let dtk1651 = DigitizerSpec(
        maxX: 34623, maxY: 19448, maxPressure: 1023,
        buttonCount: 4, hasTilt: false, hasDualRings: false,
        isPenDisplay: true, ringSlotCount: 0)

    private func decode(
        _ bytes: [UInt8], state: inout DecoderState,
        family: String = "dtus"
    ) -> [DecodeResult] {
        let decoder = DTUSDecoder()
        return bytes.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: dtk1651, state: &state, deviceFamily: family)
        }
    }

    // MARK: - Report gating

    func testTooShortReturnsEmpty() {
        var st = DecoderState()
        XCTAssertTrue(decode([0x11], state: &st).isEmpty)
    }

    func testShort0x11UnderSevenBytesRejected() {
        var st = DecoderState()
        XCTAssertTrue(decode([0x11, 0x80, 0x00, 0x00], state: &st).isEmpty)
    }

    func testUnknownReportIDReturnsEmpty() {
        var st = DecoderState()
        XCTAssertTrue(decode([0x10, 0x80] + [UInt8](repeating: 0, count: 5), state: &st).isEmpty)
    }

    // MARK: - 0x11 pen report: coordinates and pressure

    func testBE16XYDecoded() {
        var st = DecoderState()
        // X = 0x1234 = 4660 (high byte first), Y = 0x5678 = 22136
        // status = 0x80 (prox only), pressure low = 0
        let b: [UInt8] = [0x11, 0x80, 0x00, 0x12, 0x34, 0x56, 0x78]
        let r = decode(b, state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen(let pt) = r[0] else { return XCTFail("expected .pen") }
        XCTAssertEqual(pt.x, 0x1234)
        XCTAssertEqual(pt.y, 0x5678)
    }

    func test10BitPressureSplitAcrossStatusAndPressureByte() {
        var st = DecoderState()
        // pressure = 10 bits: (status & 0x03) << 8 | pressureByte
        // status high bits = 0x03 → contributes 0x300 = 768
        // pressureByte = 0xFF = 255
        // total = 768 + 255 = 1023 (max for this spec)
        let status: UInt8 = 0x80 | 0x03  // prox + high pressure bits
        let b: [UInt8] = [0x11, status, 0xFF, 0x00, 0x00, 0x00, 0x00]
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertEqual(pt.pressure, 1023)
    }

    func testZeroPressureWhenBitsAllClear() {
        var st = DecoderState()
        let b: [UInt8] = [0x11, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00]
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertEqual(pt.pressure, 0)
    }

    // MARK: - 0x11 tool-type eraser inference

    func testToolType2IsPen() {
        var st = DecoderState()
        // tool type bits [4..3] = 2 (0x10 in status)
        let status: UInt8 = 0x80 | 0x10  // prox + pen tool
        let b: [UInt8] = [0x11, status, 0x00, 0x00, 0x00, 0x00, 0x00]
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertFalse(pt.eraser)
    }

    func testToolType1IsEraser() {
        var st = DecoderState()
        // tool type bits [4..3] = 1 → (1 << 3) = 0x08
        let status: UInt8 = 0x80 | 0x08  // prox + eraser tool
        let b: [UInt8] = [0x11, status, 0x00, 0x00, 0x00, 0x00, 0x00]
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertTrue(pt.eraser)
    }

    // MARK: - 0x11 pen buttons

    func testPenButton1FromBit5() {
        var st = DecoderState()
        let status: UInt8 = 0x80 | 0x20  // prox + BTN_STYLUS (bit 5)
        let b: [UInt8] = [0x11, status, 0x00, 0x00, 0x00, 0x00, 0x00]
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertTrue(pt.penButton1)
        XCTAssertFalse(pt.penButton2)
    }

    func testPenButton2FromBit6() {
        var st = DecoderState()
        let status: UInt8 = 0x80 | 0x40  // prox + BTN_STYLUS2 (bit 6)
        let b: [UInt8] = [0x11, status, 0x00, 0x00, 0x00, 0x00, 0x00]
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertFalse(pt.penButton1)
        XCTAssertTrue(pt.penButton2)
    }

    // MARK: - 0x11 proximity-exit state machine

    func testProximityExitEmitsCachedCoordsAndClearsFlag() {
        var st = DecoderState()
        // Enter proximity at a known location.
        let enter: [UInt8] = [0x11, 0x80, 0x00, 0x10, 0x00, 0x08, 0x00]
        _ = decode(enter, state: &st)
        XCTAssertTrue(st.prevInProximity)

        // Exit: prox bit (0x80) clear.
        let exit: [UInt8] = [0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let r = decode(exit, state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertFalse(pt.inProximity)
        XCTAssertEqual(pt.x, 0x1000)
        XCTAssertEqual(pt.y, 0x0800)
        XCTAssertFalse(st.prevInProximity)
    }

    func testSecondExitFrameSuppressed() {
        var st = DecoderState()
        _ = decode([0x11, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00], state: &st)
        let exit: [UInt8] = [0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        _ = decode(exit, state: &st)
        XCTAssertTrue(decode(exit, state: &st).isEmpty)
    }

    // MARK: - 0x15 pad report

    func testPadAllFourExpressKeysFired() {
        var st = DecoderState()
        // Low nibble = 0x0F → all four buttons
        let r = decode([0x15, 0x0F], state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .aux(let aux) = r[0] else { return XCTFail("expected .aux") }
        XCTAssertTrue(aux.buttons[0])
        XCTAssertTrue(aux.buttons[1])
        XCTAssertTrue(aux.buttons[2])
        XCTAssertTrue(aux.buttons[3])
    }

    func testPadHighNibbleIgnored() {
        var st = DecoderState()
        // High nibble set (0xF0) but low nibble clear → no buttons
        let r = decode([0x15, 0xF0], state: &st)
        guard case .aux(let aux) = r[0] else { return XCTFail() }
        XCTAssertFalse(aux.buttons[0])
        XCTAssertFalse(aux.buttons[1])
        XCTAssertFalse(aux.buttons[2])
        XCTAssertFalse(aux.buttons[3])
    }

    func testPadSingleButtonDecoded() {
        var st = DecoderState()
        let r = decode([0x15, 0x04], state: &st)  // bit 2 only
        guard case .aux(let aux) = r[0] else { return XCTFail() }
        XCTAssertFalse(aux.buttons[0])
        XCTAssertFalse(aux.buttons[1])
        XCTAssertTrue(aux.buttons[2])
        XCTAssertFalse(aux.buttons[3])
    }

    func testPadMechanicalMaskIsLowNibble() {
        var st = DecoderState()
        let r = decode([0x15, 0xF5], state: &st)  // high nibble 0xF ignored
        guard case .aux(let aux) = r[0] else { return XCTFail() }
        XCTAssertEqual(aux.mechanicalMask, 0x05)
    }
}
