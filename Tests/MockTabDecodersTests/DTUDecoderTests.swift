// SPDX-License-Identifier: GPL-3.0-or-later
//
// DTU decoder fixtures (DTU-1631, DTU-2231).
//
// No hardware capture is available; all reports are synthesized from the
// byte-layout comments in DTUDecoder.swift and the input-wacom
// wacom_dtu_irq source (4.18/wacom_wac.c ~L276).
//
// Report ID is NOT checked by this decoder — dispatch is by device type.
// Only one report stream is expected from these devices (8-byte minimum).
//
// Features covered:
//   • length guard (< 8 bytes rejected)
//   • LE16 X/Y coordinate assembly
//   • 9-bit pressure: (data[7] & 0x01) << 8 | data[6]
//   • Eraser from flags bits 3:2 (0x0C)
//   • penButton1 from flags bit 1 (0x02)
//   • penButton2 from flags bit 4 (0x10)
//   • Proximity exit: emits cached coords, pressure=0
//   • Second exit frame suppressed by prevInProximity guard
//   • Report ID not checked — arbitrary [0] byte still decoded
import XCTest
@testable import TabletKit

final class DTUDecoderTests: XCTestCase {

    private let dtu1631 = DigitizerSpec(
        maxX: 34623, maxY: 19448, maxPressure: 511,
        buttonCount: 0, hasTilt: false, hasDualRings: false,
        isPenDisplay: true, ringSlotCount: 0)

    private func decode(
        _ bytes: [UInt8], state: inout DecoderState,
        family: String = "dtu"
    ) -> [DecodeResult] {
        let decoder = DTUDecoder()
        return bytes.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: dtu1631, state: &state, deviceFamily: family)
        }
    }

    // MARK: - Length guard

    func testTooShortReturnsEmpty() {
        var st = DecoderState()
        XCTAssertTrue(decode([0x02, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00], state: &st).isEmpty)
    }

    func testExactlyEightBytesAccepted() {
        var st = DecoderState()
        // flags=0x20 (prox bit only), zero coords and pressure
        let b: [UInt8] = [0x02, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let r = decode(b, state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen = r[0] else { return XCTFail("expected .pen") }
    }

    // MARK: - Coordinate decode (LE16)

    func testLE16XYDecoded() {
        var st = DecoderState()
        // X = 0x1234 = 4660 (low byte first), Y = 0x5678 = 22136
        // flags=0x20 (prox), no pressure
        let b: [UInt8] = [0x02, 0x20, 0x34, 0x12, 0x78, 0x56, 0x00, 0x00]
        let r = decode(b, state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen(let pt) = r[0] else { return XCTFail("expected .pen") }
        XCTAssertEqual(pt.x, 0x1234)
        XCTAssertEqual(pt.y, 0x5678)
    }

    // MARK: - 9-bit pressure

    func test9BitPressureFullScale() {
        var st = DecoderState()
        // report[6]=0xFF (low 8 bits), report[7]=0x01 (bit 0 = MSB) → 0x1FF = 511
        let b: [UInt8] = [0x02, 0x20, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x01]
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertEqual(pt.pressure, 511)
    }

    func test9BitPressureLowByteOnly() {
        var st = DecoderState()
        // report[6]=0xAA, report[7]=0x00 → pressure=0xAA=170
        let b: [UInt8] = [0x02, 0x20, 0x00, 0x00, 0x00, 0x00, 0xAA, 0x00]
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertEqual(pt.pressure, 0xAA)
    }

    func test9BitPressureHighBitIgnoredAboveBit0() {
        var st = DecoderState()
        // report[7]=0xFE — only bit 0 contributes; 0xFE has bit 0 clear → no MSB
        // so pressure = report[6] only = 0x10 = 16
        let b: [UInt8] = [0x02, 0x20, 0x00, 0x00, 0x00, 0x00, 0x10, 0xFE]
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertEqual(pt.pressure, 0x10)
    }

    // MARK: - Eraser (flags bits 3:2 = 0x0C)

    func testEraserBit2Set() {
        var st = DecoderState()
        // flags = 0x20 | 0x04 = 0x24 → bit 2 of 0x0C mask set → isEraser
        let b: [UInt8] = [0x02, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertTrue(pt.eraser)
    }

    func testEraserBit3Set() {
        var st = DecoderState()
        // flags = 0x20 | 0x08 = 0x28 → bit 3 of 0x0C mask set → isEraser
        let b: [UInt8] = [0x02, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertTrue(pt.eraser)
    }

    func testPenNotEraser() {
        var st = DecoderState()
        // flags = 0x20 only → bits 3:2 clear → pen (not eraser)
        let b: [UInt8] = [0x02, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertFalse(pt.eraser)
    }

    // MARK: - Pen buttons

    func testPenButton1FromBit1() {
        var st = DecoderState()
        // flags = 0x20 | 0x02 = 0x22
        let b: [UInt8] = [0x02, 0x22, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertTrue(pt.penButton1)
        XCTAssertFalse(pt.penButton2)
    }

    func testPenButton2FromBit4() {
        var st = DecoderState()
        // flags = 0x20 | 0x10 = 0x30
        let b: [UInt8] = [0x02, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertFalse(pt.penButton1)
        XCTAssertTrue(pt.penButton2)
    }

    // MARK: - Proximity exit state machine

    func testProximityExitEmitsCachedCoordsAndPressureZero() {
        var st = DecoderState()
        // Enter at known position.
        let enter: [UInt8] = [0x02, 0x20, 0x00, 0x10, 0x00, 0x08, 0xFF, 0x01]
        _ = decode(enter, state: &st)
        XCTAssertTrue(st.prevInProximity)

        // Exit: prox bit (0x20) clear.
        let exit: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let r = decode(exit, state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertFalse(pt.inProximity)
        XCTAssertEqual(pt.x, 0x1000)
        XCTAssertEqual(pt.y, 0x0800)
        XCTAssertEqual(pt.pressure, 0)
        XCTAssertFalse(st.prevInProximity)
    }

    func testSecondExitFrameSuppressed() {
        var st = DecoderState()
        _ = decode([0x02, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], state: &st)
        let exit: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        _ = decode(exit, state: &st)
        // Second exit frame should be suppressed.
        XCTAssertTrue(decode(exit, state: &st).isEmpty)
    }

    // MARK: - Report ID not checked

    func testArbitraryReportIDDecodedWhenLengthSufficient() {
        var st = DecoderState()
        // report[0]=0x99 — DTUDecoder does not gate on report ID.
        // flags=0x20 (prox), coords=0x1234/0x5678, pressure=0
        let b: [UInt8] = [0x99, 0x20, 0x34, 0x12, 0x78, 0x56, 0x00, 0x00]
        let r = decode(b, state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen(let pt) = r[0] else { return XCTFail("expected .pen") }
        XCTAssertEqual(pt.x, 0x1234)
        XCTAssertEqual(pt.y, 0x5678)
        XCTAssertTrue(pt.inProximity)
    }
}
