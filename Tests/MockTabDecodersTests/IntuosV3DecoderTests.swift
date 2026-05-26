// SPDX-License-Identifier: GPL-3.0-or-later
//
// IntuosV3 decoder fixtures (PTK-470/670/870 — Intuos Pro gen3).
//
// No hardware capture is available; all reports are synthesized from the
// byte-layout comments in IntuosV3Decoder.swift and the OTD source tables.
// These tests lock in the existing behaviour so a future refactor or
// hardware-informed correction shows up as a test failure rather than silent
// drift.
//
// Report IDs covered:
//   • 0x1F — standard pen report, 16-bit XY (gated on data[1] == 0x01)
//   • 0x1E — extended pen report, 24-bit XY, 16-bit tilt, penButton3
//   • 0x11 — aux report: 10-button interleave + two 7-bit relative wheels
import XCTest
@testable import TabletKit

final class IntuosV3DecoderTests: XCTestCase {

    private let ptk670 = DigitizerSpec(
        maxX: 44704, maxY: 27940, maxPressure: 8191,
        buttonCount: 8, hasTilt: true, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 4)

    private func decode(
        _ bytes: [UInt8], state: inout DecoderState,
        family: String = "intuosV3"
    ) -> [DecodeResult] {
        var decoder = IntuosV3Decoder()
        return bytes.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: ptk670, state: &state, deviceFamily: family)
        }
    }

    // MARK: - Helpers

    /// 14-byte 0x1F standard pen report.
    /// [0]=0x1F [1]=0x01 [2]=status [3..4]=X LE16 [5..6]=Y LE16
    /// [7..8]=pressure LE16 [9]=tiltX [11]=tiltY [13]=hoverDist
    private func make0x1F(
        status: UInt8,
        x: UInt16 = 0,
        y: UInt16 = 0,
        pressure: UInt16 = 0,
        tiltX: Int8 = 0,
        tiltY: Int8 = 0,
        hover: UInt8 = 0
    ) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 14)
        b[0] = 0x1F
        b[1] = 0x01
        b[2] = status
        b[3] = UInt8(x & 0xFF); b[4] = UInt8(x >> 8)
        b[5] = UInt8(y & 0xFF); b[6] = UInt8(y >> 8)
        b[7] = UInt8(pressure & 0xFF); b[8] = UInt8(pressure >> 8)
        b[9]  = UInt8(bitPattern: tiltX)
        b[11] = UInt8(bitPattern: tiltY)
        b[13] = hover
        return b
    }

    /// 20-byte 0x1E extended pen report.
    /// [0]=0x1E [2]=status [3..5]=X 24-bit LE [6..8]=Y 24-bit LE
    /// [9..10]=pressure LE16 [11..12]=tiltX LE i16 [13..14]=tiltY LE i16
    /// [19]=hoverDist
    private func make0x1E(
        status: UInt8,
        x: Int = 0,
        y: Int = 0,
        pressure: UInt16 = 0,
        tiltX: Int16 = 0,
        tiltY: Int16 = 0,
        hover: UInt8 = 0
    ) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 20)
        b[0] = 0x1E
        b[2] = status
        b[3] = UInt8(x & 0xFF); b[4] = UInt8((x >> 8) & 0xFF); b[5] = UInt8((x >> 16) & 0xFF)
        b[6] = UInt8(y & 0xFF); b[7] = UInt8((y >> 8) & 0xFF); b[8] = UInt8((y >> 16) & 0xFF)
        b[9]  = UInt8(pressure & 0xFF); b[10] = UInt8(pressure >> 8)
        b[11] = UInt8(UInt16(bitPattern: tiltX) & 0xFF)
        b[12] = UInt8(UInt16(bitPattern: tiltX) >> 8)
        b[13] = UInt8(UInt16(bitPattern: tiltY) & 0xFF)
        b[14] = UInt8(UInt16(bitPattern: tiltY) >> 8)
        b[19] = hover
        return b
    }

    // MARK: - 0x1F gating

    func testShort0x1FRejected() {
        var st = DecoderState()
        let r = decode([0x1F, 0x01, 0x40], state: &st)
        XCTAssertTrue(r.isEmpty)
    }

    func testWrong0x1FSubtypeRejected() {
        var st = DecoderState()
        // data[1] must be 0x01; other values are unknown.
        var b = make0x1F(status: 0x40)
        b[1] = 0x02
        let r = decode(b, state: &st)
        XCTAssertTrue(r.isEmpty)
    }

    // MARK: - 0x1F pen report: coordinates, pressure, tilt, buttons

    func test0x1FCoordinatesAndPressureDecoded() {
        var st = DecoderState()
        // X=0x1234=4660, Y=0x5678=22136, pressure=0x1FFF=8191
        let b = make0x1F(
            status: 0x40, x: 0x1234, y: 0x5678, pressure: 0x1FFF)
        let r = decode(b, state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen(let pt) = r[0] else { return XCTFail("expected .pen") }
        XCTAssertEqual(pt.x, 0x1234)
        XCTAssertEqual(pt.y, 0x5678)
        XCTAssertEqual(pt.pressure, 8191)
        XCTAssertTrue(pt.inProximity)
    }

    func test0x1FTiltNormalizedAgainst127() {
        var st = DecoderState()
        // tiltX = 127 → 1.0; tiltY = -127 → -1.0 (close enough)
        let b = make0x1F(status: 0x40, tiltX: 127, tiltY: -127)
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertEqual(pt.tiltX, 1.0, accuracy: 0.001)
        XCTAssertEqual(pt.tiltY, -1.0, accuracy: 0.001)
    }

    func test0x1FPenButtons() {
        var st = DecoderState()
        // bit1=penButton1, bit2=penButton2; both set alongside prox (bit6)
        let b = make0x1F(status: 0x40 | 0x02 | 0x04)
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertTrue(pt.penButton1)
        XCTAssertTrue(pt.penButton2)
    }

    func test0x1FEraserBit() {
        var st = DecoderState()
        // eraser = status bit 5 (0x20), prox bit 6 (0x40)
        let b = make0x1F(status: 0x40 | 0x20)
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertTrue(pt.eraser)
    }

    func test0x1FHoverDistanceDecoded() {
        var st = DecoderState()
        let b = make0x1F(status: 0x40, hover: 42)
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertEqual(pt.hoverDistance, 42)
    }

    // MARK: - 0x1F proximity-exit state machine

    func test0x1FProximityExitEmitsCachedStateAndClearsFlag() {
        var st = DecoderState()
        // Enter proximity at a known position.
        let enter = make0x1F(status: 0x40, x: 1000, y: 2000, tiltX: 64, tiltY: -32)
        _ = decode(enter, state: &st)
        XCTAssertTrue(st.prevInProximity)

        // Exit frame: prox bit clear → synthetic exit using cached coords.
        let exit = make0x1F(status: 0x00)
        let r = decode(exit, state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertFalse(pt.inProximity)
        XCTAssertEqual(pt.x, 1000)
        XCTAssertEqual(pt.y, 2000)
        XCTAssertFalse(st.prevInProximity)

        // Second exit frame is suppressed.
        let r2 = decode(exit, state: &st)
        XCTAssertTrue(r2.isEmpty)
    }

    // MARK: - 0x1E extended pen report: 24-bit XY, 16-bit tilt, penButton3

    func testShort0x1ERejected() {
        var st = DecoderState()
        let r = decode([0x1E] + [UInt8](repeating: 0, count: 18), state: &st)
        XCTAssertTrue(r.isEmpty)
    }

    func test0x1E24BitXYDecoded() {
        var st = DecoderState()
        // X = 0x123456, Y = 0xABCDEF
        let b = make0x1E(status: 0x40, x: 0x123456, y: 0x0ABCDE)
        let r = decode(b, state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertEqual(pt.x, 0x123456)
        XCTAssertEqual(pt.y, 0x0ABCDE)
    }

    func test0x1ETiltNormalizedAgainstInt16Max() {
        var st = DecoderState()
        let b = make0x1E(status: 0x40, tiltX: Int16.max, tiltY: Int16.min + 1)
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertEqual(pt.tiltX, 1.0, accuracy: 0.001)
        // Int16.min+1 / Int16.max ≈ -1.0 (avoids UB at exact min)
        XCTAssertLessThan(pt.tiltY, -0.99)
    }

    func test0x1EPenButton3FromBit3() {
        var st = DecoderState()
        // bit3 = 0x08 alongside prox bit6
        let b = make0x1E(status: 0x40 | 0x08)
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertTrue(pt.penButton3)
        XCTAssertFalse(pt.penButton1)
        XCTAssertFalse(pt.penButton2)
    }

    func test0x1EHoverDistanceFromByte19() {
        var st = DecoderState()
        let b = make0x1E(status: 0x40, hover: 17)
        let r = decode(b, state: &st)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertEqual(pt.hoverDistance, 17)
    }

    func test0x1EProximityExitCachedCoords() {
        var st = DecoderState()
        _ = decode(make0x1E(status: 0x40, x: 55000, y: 30000), state: &st)
        let r = decode(make0x1E(status: 0x00), state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .pen(let pt) = r[0] else { return XCTFail() }
        XCTAssertFalse(pt.inProximity)
        XCTAssertEqual(pt.x, 55000)
        XCTAssertEqual(pt.y, 30000)
    }

    // MARK: - 0x11 aux report

    func testAuxShortRejectd() {
        var st = DecoderState()
        let r = decode([0x11], state: &st)
        XCTAssertTrue(r.isEmpty)
    }

    func testAuxPrimaryEightButtonsDecoded() {
        var st = DecoderState()
        // All 8 primary bits set (secondary = 0)
        let r = decode([0x11, 0xFF, 0x00, 0x00, 0x00, 0x00], state: &st)
        XCTAssertFalse(r.isEmpty)
        guard case .aux(let aux) = r[0] else { return XCTFail() }
        // positions 0..3 and 5..8 come from primary; 4 and 9 from secondary
        XCTAssertTrue(aux.buttons[0])
        XCTAssertTrue(aux.buttons[1])
        XCTAssertTrue(aux.buttons[2])
        XCTAssertTrue(aux.buttons[3])
        XCTAssertFalse(aux.buttons[4])  // secondary bit 0, not set
        XCTAssertTrue(aux.buttons[5])
        XCTAssertTrue(aux.buttons[6])
        XCTAssertTrue(aux.buttons[7])
        XCTAssertTrue(aux.buttons[8])
        XCTAssertFalse(aux.buttons[9])  // secondary bit 1, not set
    }

    func testAuxSecondaryBitsInterleavedAtPositions4And9() {
        var st = DecoderState()
        // primary = 0, secondary = 0x03 (both extra bits set)
        let r = decode([0x11, 0x00, 0x00, 0x03, 0x00, 0x00], state: &st)
        guard case .aux(let aux) = r[0] else { return XCTFail() }
        XCTAssertFalse(aux.buttons[0])
        XCTAssertTrue(aux.buttons[4])   // secondary bit 0
        XCTAssertTrue(aux.buttons[9])   // secondary bit 1
    }

    func testAuxLeftWheelPositiveDelta() {
        var st = DecoderState()
        // Left wheel byte[4] = 3 → delta +3
        let r = decode([0x11, 0x00, 0x00, 0x00, 0x03, 0x00], state: &st)
        XCTAssertEqual(r.count, 2)
        guard case .wheel(let idx, let delta) = r[1] else { return XCTFail() }
        XCTAssertEqual(idx, 0)
        XCTAssertEqual(delta, 3)
    }

    func testAuxRightWheelPositiveDelta() {
        var st = DecoderState()
        // Right wheel byte[5] = 5 → delta +5
        let r = decode([0x11, 0x00, 0x00, 0x00, 0x00, 0x05], state: &st)
        XCTAssertEqual(r.count, 2)
        guard case .wheel(let idx, let delta) = r[1] else { return XCTFail() }
        XCTAssertEqual(idx, 1)
        XCTAssertEqual(delta, 5)
    }

    func testAuxWheelNegativeDeltaSign7BitExtension() {
        var st = DecoderState()
        // 7-bit sign extension: (Int8(bitPattern: byte) << 1) >> 1
        // 0xFE → Int8 == -2, << 1 == -4 (Int8), >> 1 == -2 (arithmetic shift).
        // So a raw byte of 0xFE yields delta == -2.
        let r = decode([0x11, 0x00, 0x00, 0x00, 0xFE, 0x00], state: &st)
        guard let wheelResult = r.first(where: { if case .wheel = $0 { return true }; return false }),
              case .wheel(let idx, let delta) = wheelResult else { return XCTFail() }
        XCTAssertEqual(idx, 0)
        XCTAssertEqual(delta, -2)
    }

    func testAuxWheelZeroDeltaSuppressed() {
        var st = DecoderState()
        // Both wheels at 0 → no .wheel results; only .aux
        let r = decode([0x11, 0x00, 0x00, 0x00, 0x00, 0x00], state: &st)
        XCTAssertEqual(r.count, 1)
        if case .aux = r[0] { } else { XCTFail("expected .aux") }
    }

    func testAuxBothWheelsInSameReport() {
        var st = DecoderState()
        let r = decode([0x11, 0x00, 0x00, 0x00, 0x02, 0x03], state: &st)
        // .aux + two .wheel results
        XCTAssertEqual(r.count, 3)
        let wheels = r.compactMap { r -> (Int, Int)? in
            if case .wheel(let i, let d) = r { return (i, d) }; return nil
        }
        XCTAssertEqual(wheels.count, 2)
        XCTAssertTrue(wheels.contains { $0 == (0, 2) })
        XCTAssertTrue(wheels.contains { $0 == (1, 3) })
    }

    // MARK: - Unknown report IDs

    func testUnknownReportIDReturnsEmpty() {
        var st = DecoderState()
        let r = decode([0x10, 0x00, 0x40] + [UInt8](repeating: 0, count: 20), state: &st)
        XCTAssertTrue(r.isEmpty)
    }
}
