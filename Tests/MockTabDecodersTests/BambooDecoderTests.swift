// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bamboo decoder fixtures (CTH-470, CTL-470).
//
// No hardware capture is available; all reports are synthesized from the
// byte-layout comments in BambooDecoder.swift and the input-wacom
// wacom_bpt_pen / wacom_bpt_pad source.
//
// Report IDs covered:
//   • 0x10 — pen/eraser/mouse report, 10 bytes (BE16 X/Y, 11-bit pressure,
//             4-bit tilt, tool-type field, pad buttons when not in proximity)
import XCTest
@testable import TabletKit

final class BambooDecoderTests: XCTestCase {

    // CTH-470: 4 express keys, hasTilt, maxPressure=1023
    private let cth470 = DigitizerSpec(
        maxX: 21648, maxY: 13530, maxPressure: 1023,
        buttonCount: 4, hasTilt: true, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 0)

    // CTL-470: 2 express keys, no tilt, maxPressure=1023
    private let ctl470 = DigitizerSpec(
        maxX: 15200, maxY: 9500, maxPressure: 1023,
        buttonCount: 2, hasTilt: false, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 0)

    // CTT-460: no pad buttons, no pen (touch-only), no tilt
    private let ctt460 = DigitizerSpec(
        maxX: 15200, maxY: 9500, maxPressure: 1023,
        buttonCount: 0, hasTilt: false, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 0)

    private func decode(
        _ bytes: [UInt8], state: inout DecoderState,
        spec: DigitizerSpec? = nil, family: String = "bamboo"
    ) -> [DecodeResult] {
        var decoder = BambooDecoder()
        let s = spec ?? cth470
        return bytes.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: s, state: &state, deviceFamily: family)
        }
    }

    /// Build a minimal valid 10-byte 0x10 report.
    private func makePen(
        status: UInt8,
        xHigh: UInt8 = 0, xLow: UInt8 = 0,
        yHigh: UInt8 = 0, yLow: UInt8 = 0,
        pressHigh: UInt8 = 0,   // byte[6]
        pressLow: UInt8 = 0,    // byte[7]
        tiltX: UInt8 = 0x08,    // byte[8]: centre=8 → tilt=0.0
        tiltY: UInt8 = 0x08     // byte[9]: centre=8 → tilt=0.0
    ) -> [UInt8] {
        [0x10, status, xHigh, xLow, yHigh, yLow, pressHigh, pressLow, tiltX, tiltY]
    }

    // MARK: - Report gating

    func testWrongReportIDReturnsEmpty() {
        var st = DecoderState()
        // report[0]=0x11, but decoder requires 0x10
        let b = [UInt8](repeating: 0, count: 10)
        XCTAssertTrue(decode([0x11] + Array(b.dropFirst()), state: &st).isEmpty)
    }

    func testTooShortReturnsEmpty() {
        var st = DecoderState()
        XCTAssertTrue(decode([0x10, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], state: &st).isEmpty)
    }

    // MARK: - Coordinate decode (BE16)

    func testBE16XYDecoded() {
        var st = DecoderState()
        // X: high byte in report[2], low in report[3] → 0x1234 = 4660
        // Y: high byte in report[4], low in report[5] → 0x5678 = 22136
        let b = makePen(status: 0x80, xHigh: 0x12, xLow: 0x34, yHigh: 0x56, yLow: 0x78)
        let r = decode(b, state: &st)
        XCTAssertFalse(r.isEmpty)
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail("expected .pen") }
        XCTAssertEqual(pt.x, 0x1234)
        XCTAssertEqual(pt.y, 0x5678)
    }

    // MARK: - 11-bit pressure (>>1 for 1023 devices)

    func test11BitPressureRightShiftedForMaxPressure1023() {
        var st = DecoderState()
        // rawPressure = (d6 << 3) | (d7 >> 5)
        // d6=0xFF → 0xFF << 3 = 2040; d7=0xE0 → 0xE0 >> 5 = 7
        // rawPressure = 2047; >> 1 = 1023 (max for 1023-device)
        let b = makePen(status: 0x80, pressHigh: 0xFF, pressLow: 0xE0)
        let r = decode(b, state: &st)
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail() }
        XCTAssertEqual(pt.pressure, 1023)
    }

    func testZeroPressure() {
        var st = DecoderState()
        let b = makePen(status: 0x80, pressHigh: 0x00, pressLow: 0x00)
        let r = decode(b, state: &st)
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail() }
        XCTAssertEqual(pt.pressure, 0)
    }

    // MARK: - Tool enter

    func testToolEnterEmittedOnFirstProximityEntryPen() {
        var st = DecoderState()
        // toolType bits 4:3 = 0 (status >> 3) & 0x03 == 0 → pen
        let b = makePen(status: 0x80)  // bit7=prox, bits 4:3=0 → pen
        let r = decode(b, state: &st)
        let enter = r.first { if case .toolEnter = $0 { return true }; return false }
        guard case .toolEnter(let id) = enter else { return XCTFail("expected .toolEnter") }
        XCTAssertEqual(id.toolCode, 0x0802)
        XCTAssertFalse(id.isEraser)
    }

    func testToolEnterEmittedForEraser() {
        var st = DecoderState()
        // toolType = 1 → status bits 4:3 = 0b001 → (1 << 3) = 0x08
        let b = makePen(status: 0x80 | 0x08)
        let r = decode(b, state: &st)
        let enter = r.first { if case .toolEnter = $0 { return true }; return false }
        guard case .toolEnter(let id) = enter else { return XCTFail("expected .toolEnter") }
        XCTAssertEqual(id.toolCode, 0x080A)
        XCTAssertTrue(id.isEraser)
    }

    func testNoToolEnterOnSubsequentFrame() {
        var st = DecoderState()
        let b = makePen(status: 0x80)
        _ = decode(b, state: &st)  // first frame — emits toolEnter
        let r = decode(b, state: &st)  // second frame — no toolEnter
        let enter = r.first { if case .toolEnter = $0 { return true }; return false }
        XCTAssertNil(enter)
    }

    // MARK: - Tilt

    func testTiltDecodedWhenHasTiltTrue() {
        var st = DecoderState()
        // tiltX byte = 0x0F → (0x0F & 0x0F) = 15; (15-8)/8.0 = 0.875
        // tiltY byte = 0x08 → (0x08 & 0x0F) = 8;  (8-8)/8.0  = 0.0
        let b = makePen(status: 0x80, tiltX: 0x0F, tiltY: 0x08)
        let r = decode(b, state: &st, spec: cth470)
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail() }
        XCTAssertEqual(pt.tiltX, 0.875, accuracy: 0.001)
        XCTAssertEqual(pt.tiltY, 0.0, accuracy: 0.001)
    }

    func testTiltIsZeroWhenHasTiltFalse() {
        var st = DecoderState()
        // Non-zero tilt bytes, but CTL-470 has hasTilt=false → both should be 0.0
        let b = makePen(status: 0x80, tiltX: 0x0F, tiltY: 0x0F)
        let r = decode(b, state: &st, spec: ctl470)
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail() }
        XCTAssertEqual(pt.tiltX, 0.0)
        XCTAssertEqual(pt.tiltY, 0.0)
    }

    // MARK: - Pen buttons

    func testPenButton1FromBit1() {
        var st = DecoderState()
        // status bit 1 = 0x02 | prox bit 7
        let b = makePen(status: 0x80 | 0x02)
        let r = decode(b, state: &st)
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail() }
        XCTAssertTrue(pt.penButton1)
        XCTAssertFalse(pt.penButton2)
    }

    func testPenButton2FromBit2() {
        var st = DecoderState()
        // status bit 2 = 0x04 | prox bit 7
        let b = makePen(status: 0x80 | 0x04)
        let r = decode(b, state: &st)
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail() }
        XCTAssertFalse(pt.penButton1)
        XCTAssertTrue(pt.penButton2)
    }

    // MARK: - Proximity exit

    func testProximityExitEmitsPenOutAndPad() {
        var st = DecoderState()
        // Enter proximity.
        _ = decode(makePen(status: 0x80, xHigh: 0x10, xLow: 0x00, yHigh: 0x08, yLow: 0x00), state: &st, spec: cth470)
        XCTAssertTrue(st.prevInProximity)

        // Exit: bit 7 clear, pad byte = 0x00 (no buttons)
        let exit: [UInt8] = [0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let r = decode(exit, state: &st, spec: cth470)

        // Expect .pen(inProximity:false) followed by .aux
        let penResult = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = penResult else { return XCTFail("expected .pen exit") }
        XCTAssertFalse(pt.inProximity)
        XCTAssertEqual(pt.pressure, 0)

        let auxResult = r.first { if case .aux = $0 { return true }; return false }
        XCTAssertNotNil(auxResult, "expected .aux (pad) after pen exit")
    }

    // MARK: - Pad button layouts

    func testPad4ButtonLayout() {
        var st = DecoderState()
        // padByte = report[7]: 0x08=btn0, 0x20=btn1, 0x10=btn2, 0x40=btn3
        // All four set: 0x08|0x20|0x10|0x40 = 0x78
        let b: [UInt8] = [0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x78, 0x00, 0x00]
        let r = decode(b, state: &st, spec: cth470)
        let auxResult = r.first { if case .aux = $0 { return true }; return false }
        guard case .aux(let aux) = auxResult else { return XCTFail("expected .aux") }
        XCTAssertTrue(aux.buttons[0])  // 0x08
        XCTAssertTrue(aux.buttons[1])  // 0x20
        XCTAssertTrue(aux.buttons[2])  // 0x10
        XCTAssertTrue(aux.buttons[3])  // 0x40
    }

    func testPad2ButtonLayout() {
        var st = DecoderState()
        // CTL-470: padByte=0x03 → btn0=(0x01), btn1=(0x02)
        let b: [UInt8] = [0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00]
        let r = decode(b, state: &st, spec: ctl470)
        let auxResult = r.first { if case .aux = $0 { return true }; return false }
        guard case .aux(let aux) = auxResult else { return XCTFail("expected .aux") }
        XCTAssertTrue(aux.buttons[0])  // 0x01
        XCTAssertTrue(aux.buttons[1])  // 0x02
    }

    func testNoPadWhenButtonCountZero() {
        var st = DecoderState()
        // CTT-460 has buttonCount=0 → no pad even when not in proximity
        let b: [UInt8] = [0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00]
        let r = decode(b, state: &st, spec: ctt460)
        let auxResult = r.first { if case .aux = $0 { return true }; return false }
        XCTAssertNil(auxResult, "CTT-460 should produce no pad event")
    }
}
