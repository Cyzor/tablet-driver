// SPDX-License-Identifier: GPL-3.0-or-later
//
// Graphire decoder fixtures (Graphire 4, PenPartner).
//
// No hardware capture is available; all reports are synthesized from the
// byte-layout comments in GraphireDecoder.swift and the input-wacom
// wacom_graphire_irq source.
//
// Report ID covered:
//   • 0x02 — pen/eraser/mouse report, 8 bytes (LE16 X/Y, 10-bit pressure,
//             mouse wheel, hover distance, G4 pad buttons in d[7])
import XCTest
@testable import TabletKit

final class GraphireDecoderTests: XCTestCase {

    // Graphire 4 — 2 pad buttons, maxPressure=511
    private let graphire4 = DigitizerSpec(
        maxX: 10206, maxY: 7422, maxPressure: 511,
        buttonCount: 2, hasTilt: false, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 0)

    // PenPartner — no pad, maxPressure=255
    private let penPartner = DigitizerSpec(
        maxX: 5040, maxY: 3780, maxPressure: 255,
        buttonCount: 0, hasTilt: false, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 0)

    private func decode(
        _ bytes: [UInt8], state: inout DecoderState,
        spec: DigitizerSpec? = nil, family: String = "graphire"
    ) -> [DecodeResult] {
        var decoder = GraphireDecoder()
        let s = spec ?? graphire4
        return bytes.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: s, state: &state, deviceFamily: family)
        }
    }

    /// Build a minimal valid 8-byte 0x02 report.
    private func makePen(
        status: UInt8,
        xLow: UInt8 = 0, xHigh: UInt8 = 0,
        yLow: UInt8 = 0, yHigh: UInt8 = 0,
        byte6: UInt8 = 0,   // pressure LSB / wheel
        byte7: UInt8 = 0    // pressure[1:0] & 0x03 / pad / distance
    ) -> [UInt8] {
        [0x02, status, xLow, xHigh, yLow, yHigh, byte6, byte7]
    }

    // MARK: - Report gating

    func testWrongReportIDReturnsEmpty() {
        var st = DecoderState()
        // report[0]=0x01 — decoder requires 0x02
        let b: [UInt8] = [0x01, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertTrue(decode(b, state: &st).isEmpty)
    }

    func testTooShortReturnsEmpty() {
        var st = DecoderState()
        XCTAssertTrue(decode([0x02, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00], state: &st).isEmpty)
    }

    // MARK: - Coordinate decode (LE16)

    func testLE16XYDecoded() {
        var st = DecoderState()
        // X = 0x1234 = 4660 (low byte first), Y = 0x5678 = 22136
        let b = makePen(status: 0x80, xLow: 0x34, xHigh: 0x12, yLow: 0x78, yHigh: 0x56)
        let r = decode(b, state: &st)
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail("expected .pen") }
        XCTAssertEqual(pt.x, 0x1234)
        XCTAssertEqual(pt.y, 0x5678)
    }

    // MARK: - Pressure (10-bit pen path)

    func test10BitPressureAssembled() {
        var st = DecoderState()
        // rawPressure = d[6] | ((d[7] & 0x03) << 8)
        // d[6]=0xFF, d[7]=0x01 → 0xFF | (0x01 << 8) = 0x1FF = 511
        let b = makePen(status: 0x80, byte6: 0xFF, byte7: 0x01)
        let r = decode(b, state: &st)
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail() }
        XCTAssertEqual(pt.pressure, 511)
    }

    func testPressureCappedAtMaxPressure() {
        var st = DecoderState()
        // PenPartner: maxPressure=255; d[6]=0xFF, d[7]=0x03 → raw=0x3FF=1023, capped to 255
        let b = makePen(status: 0x80, byte6: 0xFF, byte7: 0x03)
        let r = decode(b, state: &st, spec: penPartner)
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail() }
        XCTAssertEqual(pt.pressure, 255)
    }

    // MARK: - Tool enter

    func testToolEnterEmittedForPenOnFirstProximity() {
        var st = DecoderState()
        // toolField = (status >> 5) & 0x03; status=0x80 → toolField=0 → pen
        let b = makePen(status: 0x80)
        let r = decode(b, state: &st)
        let enter = r.first { if case .toolEnter = $0 { return true }; return false }
        guard case .toolEnter(let id) = enter else { return XCTFail("expected .toolEnter") }
        XCTAssertEqual(id.toolCode, 0x0802)
        XCTAssertFalse(id.isEraser)
        XCTAssertFalse(id.isMouse)
    }

    func testToolEnterForEraser() {
        var st = DecoderState()
        // toolField = 1 → status bits 6:5 = 0b01 → status = 0x80 | 0x20
        let b = makePen(status: 0x80 | 0x20)
        let r = decode(b, state: &st)
        let enter = r.first { if case .toolEnter = $0 { return true }; return false }
        guard case .toolEnter(let id) = enter else { return XCTFail("expected .toolEnter") }
        XCTAssertEqual(id.toolCode, 0x080A)
        XCTAssertTrue(id.isEraser)
    }

    func testToolEnterForMouseWithWheel() {
        var st = DecoderState()
        // toolField = 2 (mouse w/wheel) → status bits 6:5 = 0b10 → status = 0x80 | 0x40
        let b = makePen(status: 0x80 | 0x40)
        let r = decode(b, state: &st)
        let enter = r.first { if case .toolEnter = $0 { return true }; return false }
        guard case .toolEnter(let id) = enter else { return XCTFail("expected .toolEnter") }
        XCTAssertEqual(id.toolCode, 0x0007)
        XCTAssertTrue(id.isMouse)
    }

    // MARK: - Mouse wheel

    func testMouseWheelPositiveByte() {
        var st = DecoderState()
        // toolField=2 → mouse path; d[6]=0x01 → Int8(bitPattern:0x01)=1, * -1 = -1
        let b = makePen(status: 0x80 | 0x40, byte6: 0x01)
        let r = decode(b, state: &st)
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail() }
        XCTAssertEqual(pt.mouseWheelDelta, -1)
    }

    func testMouseWheelNegativeByte() {
        var st = DecoderState()
        // d[6]=0xFF → Int8(bitPattern:0xFF) = -1, * -1 = +1
        let b = makePen(status: 0x80 | 0x40, byte6: 0xFF)
        let r = decode(b, state: &st)
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail() }
        XCTAssertEqual(pt.mouseWheelDelta, 1)
    }

    // MARK: - Hover distance

    func testHoverDistanceFromByte7Low6Bits() {
        var st = DecoderState()
        // hoverDistance = d[7] & 0x3F; d[7]=0x2A=0b00101010 → 0x2A & 0x3F = 0x2A = 42
        let b = makePen(status: 0x80, byte7: 0x2A)
        let r = decode(b, state: &st)
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail() }
        XCTAssertEqual(pt.hoverDistance, 0x2A)
    }

    // MARK: - Proximity exit

    func testProximityExitEmitsCachedCoords() {
        var st = DecoderState()
        // Enter at known position.
        _ = decode(makePen(status: 0x80, xLow: 0x34, xHigh: 0x12, yLow: 0x78, yHigh: 0x56), state: &st)
        XCTAssertTrue(st.prevInProximity)

        // Exit: prox bit (0x80) clear.
        let exit = makePen(status: 0x00)
        let r = decode(exit, state: &st)
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail("expected exit .pen") }
        XCTAssertFalse(pt.inProximity)
        XCTAssertEqual(pt.x, 0x1234)
        XCTAssertEqual(pt.y, 0x5678)
        XCTAssertEqual(pt.pressure, 0)
    }

    // MARK: - G4 pad buttons

    func testG4PadBothButtonsSet() {
        var st = DecoderState()
        // d[7]: bit 6=BTN_BACK, bit 7=BTN_FORWARD → 0xC0 sets both
        let b = makePen(status: 0x00, byte7: 0xC0)
        let r = decode(b, state: &st, spec: graphire4)
        let auxResult = r.first { if case .aux = $0 { return true }; return false }
        guard case .aux(let aux) = auxResult else { return XCTFail("expected .aux") }
        XCTAssertTrue(aux.buttons[0])   // BTN_BACK (0x40)
        XCTAssertTrue(aux.buttons[1])   // BTN_FORWARD (0x80)
    }

    func testG4PadSingleButtonBack() {
        var st = DecoderState()
        // Only bit 6 set
        let b = makePen(status: 0x00, byte7: 0x40)
        let r = decode(b, state: &st, spec: graphire4)
        let auxResult = r.first { if case .aux = $0 { return true }; return false }
        guard case .aux(let aux) = auxResult else { return XCTFail("expected .aux") }
        XCTAssertTrue(aux.buttons[0])
        XCTAssertFalse(aux.buttons[1])
    }

    func testNoPadOnPenPartner() {
        var st = DecoderState()
        // PenPartner has buttonCount=0 → no pad even when not in proximity
        let b = makePen(status: 0x00, byte7: 0xC0)
        let r = decode(b, state: &st, spec: penPartner)
        let auxResult = r.first { if case .aux = $0 { return true }; return false }
        XCTAssertNil(auxResult, "PenPartner should produce no pad event")
    }
}
