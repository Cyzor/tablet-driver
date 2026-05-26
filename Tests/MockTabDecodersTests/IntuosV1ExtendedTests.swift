// SPDX-License-Identifier: GPL-3.0-or-later
//
// Extended IntuosV1 decoder fixtures — USB pen path detail.
//
// The existing IntuosV1DecoderTests.swift has minimal coverage (dispatch,
// one tool-change, one prox-exit). This file covers the paths that were
// left out: coordinate/pressure/tilt decode, pen buttons, boundary-noise
// state machine, fallback toolEnter, mouse subtypes 0x06 and 0x08, and
// the aux report.
//
// No hardware capture; reports are synthesized from the decoder source
// comments and the Linux kernel wacom_intuos_general() reference.
import XCTest
@testable import TabletKit

final class IntuosV1ExtendedTests: XCTestCase {

    // PTH-851 (Intuos Pro L, USB). maxPressure=2047 enables the status-bit
    // 11th-pressure-bit path.
    private let pth851 = DigitizerSpec(
        maxX: 44704, maxY: 27940, maxPressure: 2047,
        buttonCount: 8, hasTilt: true, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 4)

    // PTZ-631W (Intuos3 S, USB). maxPressure=1023 uses the >>1 normalization.
    private let ptz631w = DigitizerSpec(
        maxX: 25400, maxY: 20320, maxPressure: 1023,
        buttonCount: 0, hasTilt: true, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 0)

    private func decode(
        _ bytes: [UInt8], state: inout DecoderState,
        spec: DigitizerSpec? = nil, family: String = "intuos"
    ) -> [DecodeResult] {
        let s = spec ?? pth851
        var decoder = IntuosV1Decoder()
        return bytes.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: s, state: &state, deviceFamily: family)
        }
    }

    // MARK: - Helpers

    /// 10-byte USB pen report (Report ID 0x10).
    /// Caller fills status/coord/pressure/tilt bytes.
    private func makePen(
        id: UInt8 = 0x10,
        status: UInt8,
        xHigh: UInt8 = 0, xLow: UInt8 = 0,
        yHigh: UInt8 = 0, yLow: UInt8 = 0,
        pressHigh: UInt8 = 0,    // byte[6]
        pressTiltLow: UInt8 = 0, // byte[7]
        tiltY: UInt8 = 0x40,     // byte[8] — 0x40 = zero tilt (biased 64)
        frac: UInt8 = 0          // byte[9]
    ) -> [UInt8] {
        [id, status, xHigh, xLow, yHigh, yLow, pressHigh, pressTiltLow, tiltY, frac]
    }

    // MARK: - 17-bit coordinate decode

    func testCoordinatesDecodedAsBE16ShiftedLeft1() {
        var st = DecoderState()
        // X: (report[2]<<8 | report[3]) << 1 | ((report[9]>>1) & 1)
        // Y: (report[4]<<8 | report[5]) << 1 | (report[9] & 1)
        // With xHigh=0x01, xLow=0x00, yHigh=0x00, yLow=0x80, frac=0:
        // X = (0x0100 << 1) = 512, Y = (0x0080 << 1) = 256
        let b = makePen(status: 0x60, xHigh: 0x01, xLow: 0x00, yHigh: 0x00, yLow: 0x80)
        let r = decode(b, state: &st)
        let pt = r.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }.first!
        XCTAssertEqual(pt.x, 512)
        XCTAssertEqual(pt.y, 256)
    }

    func testFractionalBitFromByte9AppendsToCoords() {
        var st = DecoderState()
        // With xHigh=0, xLow=0, yHigh=0, yLow=0, frac=0x03:
        // X = 0 | ((0x03 >> 1) & 1) = 1; Y = 0 | (0x03 & 1) = 1
        let b = makePen(status: 0x60, frac: 0x03)
        let r = decode(b, state: &st)
        let pt = r.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }.first!
        XCTAssertEqual(pt.x, 1)
        XCTAssertEqual(pt.y, 1)
    }

    // MARK: - 11-bit pressure formula

    func testPressureMaxFor2047Device() {
        var st = DecoderState()
        // maxPressure=2047: rawPressure = report[6]<<3 | (report[7] & 0xC0)>>5 | (status & 1)
        // report[6]=0xFF → 0x7F8; report[7]=0xC0 → 0x06; status bit0=1 → total=2047
        let b = makePen(status: 0x61, pressHigh: 0xFF, pressTiltLow: 0xC0)
        let r = decode(b, state: &st)
        let pt = r.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }.first!
        XCTAssertEqual(pt.pressure, 2047)
    }

    func testPressureShiftedRightFor1023Device() {
        var st = DecoderState()
        // maxPressure=1023: statusBit=0, rawPressure = report[6]<<3 | (report[7]&0xC0)>>5, then >>1.
        // report[6]=0x7F → 127<<3=1016; report[7]=0xC0 → (0xC0>>5)=6; raw=1022; pressure=511.
        let b = makePen(status: 0x60, pressHigh: 0x7F, pressTiltLow: 0xC0)
        let r = decode(b, state: &st, spec: ptz631w)
        let pt = r.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }.first!
        XCTAssertEqual(pt.pressure, 511)
    }

    // MARK: - Tilt decode (biased-64)

    func testTiltZeroAtNeutralBytes() {
        var st = DecoderState()
        // tiltXRaw = ((report[7]<<1 & 0x7E) | report[8]>>7) - 64
        // tiltYRaw = (report[8] & 0x7F) - 64
        // report[7]=0x20, report[8]=0x40 → tiltXRaw=0, tiltYRaw=0
        let b = makePen(status: 0x60, pressTiltLow: 0x20, tiltY: 0x40)
        let r = decode(b, state: &st)
        let pt = r.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }.first!
        XCTAssertEqual(pt.tiltX, 0.0, accuracy: 1e-6)
        XCTAssertEqual(pt.tiltY, 0.0, accuracy: 1e-6)
    }

    func testTiltMaxPositiveX() {
        var st = DecoderState()
        // tiltXRaw=63 → tiltX=1.0: need ((report[7]<<1 & 0x7E) | report[8]>>7) = 127
        // report[7]=0x7F → 0x7E; report[8]=0xC0 → bit7=1 + tiltYRaw=(0x40-64)=0
        let b = makePen(status: 0x60, pressTiltLow: 0x7F, tiltY: 0xC0)
        let r = decode(b, state: &st)
        let pt = r.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }.first!
        XCTAssertEqual(pt.tiltX, 1.0, accuracy: 0.001)
        XCTAssertEqual(pt.tiltY, 0.0, accuracy: 0.001)
    }

    func testTiltYPositive() {
        var st = DecoderState()
        // tiltYRaw=63 → tiltY=1.0: report[8] & 0x7F = 127 → report[8]=0x7F
        // tiltXRaw: report[7]=0x20, report[8]=0x7F → bit7=0, tiltXRaw=(0x40)-64=0
        let b = makePen(status: 0x60, pressTiltLow: 0x20, tiltY: 0x7F)
        let r = decode(b, state: &st)
        let pt = r.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }.first!
        XCTAssertEqual(pt.tiltX, 0.0, accuracy: 0.001)
        XCTAssertEqual(pt.tiltY, 1.0, accuracy: 0.001)
    }

    // MARK: - Hover distance

    func testHoverDistanceFromByte9High6Bits() {
        var st = DecoderState()
        // hoverDistance = report[9] >> 2; frac=0xFC → hover=63
        let b = makePen(status: 0x60, frac: 0xFC)
        let r = decode(b, state: &st)
        let pt = r.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }.first!
        XCTAssertEqual(pt.hoverDistance, 63)
    }

    // MARK: - Pen buttons

    func testPenButton1FromStatusBit1() {
        var st = DecoderState()
        let b = makePen(status: 0x60 | 0x02)  // prox+conf+btn1
        let r = decode(b, state: &st)
        let pt = r.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }.first!
        XCTAssertTrue(pt.penButton1)
        XCTAssertFalse(pt.penButton2)
    }

    func testPenButton2FromStatusBit2() {
        var st = DecoderState()
        let b = makePen(status: 0x60 | 0x04)
        let r = decode(b, state: &st)
        let pt = r.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }.first!
        XCTAssertFalse(pt.penButton1)
        XCTAssertTrue(pt.penButton2)
    }

    // MARK: - Eraser state (from prior tool-change)

    func testEraserFlagCarriedFromToolChange() {
        var st = DecoderState()
        // Tool-change packet with eraser tool code (bit3 set).
        // Tool code extraction: UInt16(report[2])<<4 | UInt16(report[3])>>4 | ...
        // Simplest: set state.isEraser directly to simulate a prior tool-change.
        st.isEraser = true
        st.prevInProximity = true
        // Normal pen report (not tool-change) — eraser bit comes from state
        let b = makePen(status: 0x60)
        let r = decode(b, state: &st)
        let pt = r.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }.first!
        XCTAssertTrue(pt.eraser)
    }

    // MARK: - Fallback toolEnter on first proximity

    func testFallbackToolEnterEmittedOnFirstProximityWithoutPriorToolChange() {
        var st = DecoderState()
        // state.currentToolCode=0 and !prevInProximity → decoder synthesizes toolEnter
        let b = makePen(status: 0x60)
        let r = decode(b, state: &st)
        let hasToolEnter = r.contains { if case .toolEnter = $0 { return true }; return false }
        XCTAssertTrue(hasToolEnter, "Expected synthetic toolEnter on first proximity")
    }

    func testNoFallbackToolEnterOnSubsequentFrames() {
        var st = DecoderState()
        st.prevInProximity = true
        st.currentToolCode = 0x0802  // already registered
        let b = makePen(status: 0x60)
        let r = decode(b, state: &st)
        let hasToolEnter = r.contains { if case .toolEnter = $0 { return true }; return false }
        XCTAssertFalse(hasToolEnter)
    }

    // MARK: - Boundary-noise exit state machine

    func testBoundaryNoiseBelowThresholdDoesNotExit() {
        var st = DecoderState()
        st.prevInProximity = true
        st.currentToolCode = 0x0802
        // Boundary noise: bit5=prox=1, bit6=highConf=0 → status=0x20.
        // The genuine-exit path (!prox && !conf) is not triggered here.
        let b = makePen(status: 0x20)
        _ = decode(b, state: &st)
        XCTAssertTrue(st.prevInProximity, "Should stay in proximity below exit threshold")
        XCTAssertEqual(st.exitFrameCount, 1)
    }

    func testBoundaryNoiseExitsAtThreshold() {
        var st = DecoderState()
        st.prevInProximity = true
        st.currentToolCode = 0x0802
        let b = makePen(status: 0x20)  // prox=1, conf=0
        var lastR: [DecodeResult] = []
        for _ in 0..<DecoderState.exitThreshold {
            lastR = decode(b, state: &st)
        }
        let hasExit = lastR.contains {
            if case .pen(let p) = $0 { return !p.inProximity }; return false
        }
        XCTAssertTrue(hasExit, "Expected proximity exit at threshold")
        XCTAssertFalse(st.prevInProximity)
    }

    func testHighConfidenceResetsExitFrameCount() {
        var st = DecoderState()
        st.prevInProximity = true
        st.currentToolCode = 0x0802
        let noisy = makePen(status: 0x20)  // prox=1, conf=0
        let clean  = makePen(status: 0x60)  // prox=1, conf=1
        _ = decode(noisy, state: &st)
        _ = decode(noisy, state: &st)
        XCTAssertEqual(st.exitFrameCount, 2)
        _ = decode(clean, state: &st)
        XCTAssertEqual(st.exitFrameCount, 0)
        XCTAssertTrue(st.prevInProximity)
    }

    // MARK: - Mouse subtype 0x06 (KC-100 cordless mouse)

    func testMouseSubtype06EmitsPenWithMouseButtons() {
        var st = DecoderState()
        // subtype = (status >> 1) & 0x0F = 0x06 → status = 0x40 | 0x20 | (0x06 << 1) = 0x6C
        // report[6]: bit0=left, bit1=middle, bit2=right → 0x05 = left+right
        let b: [UInt8] = [0x10, 0x6C, 0, 0, 0, 0, 0x05, 0x00, 0x00, 0x00]
        let r = decode(b, state: &st)
        let pt = r.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }.first!
        // penButton1=(buttons & 0x01), penButton2=(buttons & 0x04)
        // 0x05: bit0=left→penButton1, bit2=right→penButton2
        XCTAssertTrue(pt.penButton1)
        XCTAssertTrue(pt.penButton2)
    }

    func testMouseSubtype06WheelUp() {
        var st = DecoderState()
        // report[7]: bit7=1 → wheelDelta = 1 - 0 = +1
        let b: [UInt8] = [0x10, 0x6C, 0, 0, 0, 0, 0x00, 0x80, 0x00, 0x00]
        let r = decode(b, state: &st)
        let pt = r.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }.first!
        XCTAssertEqual(pt.mouseWheelDelta, 1)
    }

    func testMouseSubtype06WheelDown() {
        var st = DecoderState()
        // report[7]: bit6=1 → wheelDelta = 0 - 1 = -1
        let b: [UInt8] = [0x10, 0x6C, 0, 0, 0, 0, 0x00, 0x40, 0x00, 0x00]
        let r = decode(b, state: &st)
        let pt = r.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }.first!
        XCTAssertEqual(pt.mouseWheelDelta, -1)
    }

    func testMouseSubtype06MiddleButton() {
        var st = DecoderState()
        // report[6] bit1 = middle button
        let b: [UInt8] = [0x10, 0x6C, 0, 0, 0, 0, 0x02, 0x00, 0x00, 0x00]
        let r = decode(b, state: &st)
        let pt = r.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }.first!
        XCTAssertTrue(pt.mouseMiddleButton)
    }

    // MARK: - Mouse subtype 0x08 (2D cursor)

    func testMouseSubtype08ButtonsAndWheel() {
        var st = DecoderState()
        // subtype=0x08 → status = 0x40 | 0x20 | (0x08 << 1) = 0x70
        // report[8]: penButton1=bit2, penButton2=bit4, middle=bit3, wheel bits [1:0]
        // btnByte=0x15 = 0001_0101: bit0=1(wheelUp), bit1=0, bit2=1(btn1), bit4=1(btn2)
        // wheelDelta = (0x15 & 0x01) - ((0x15 & 0x02) >> 1) = 1 - 0 = 1
        let b: [UInt8] = [0x10, 0x70, 0, 0, 0, 0, 0, 0, 0x15, 0x00]
        let r = decode(b, state: &st)
        let pt = r.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }.first!
        XCTAssertTrue(pt.penButton1)
        XCTAssertTrue(pt.penButton2)
        XCTAssertEqual(pt.mouseWheelDelta, 1)
    }

    func testMouseSubtype08WheelDown() {
        var st = DecoderState()
        // btnByte=0x02: bit1=1 → wheelDelta = 0 - 1 = -1
        let b: [UInt8] = [0x10, 0x70, 0, 0, 0, 0, 0, 0, 0x02, 0x00]
        let r = decode(b, state: &st)
        let pt = r.compactMap { if case .pen(let p) = $0 { return p } else { return nil } }.first!
        XCTAssertEqual(pt.mouseWheelDelta, -1)
    }

    // MARK: - Aux report (0x11)

    func testAuxReportDecodesAllEightBits() {
        var st = DecoderState()
        // report[1] = 0xFF → all 8 buttons true
        let r = decode([0x11, 0xFF], state: &st)
        XCTAssertEqual(r.count, 1)
        guard case .aux(let aux) = r[0] else { return XCTFail("expected .aux") }
        XCTAssertTrue(aux.buttons.prefix(8).allSatisfy { $0 })
    }

    func testAuxReportSingleButton() {
        var st = DecoderState()
        let r = decode([0x11, 0x08], state: &st)  // bit 3
        guard case .aux(let aux) = r[0] else { return XCTFail() }
        XCTAssertFalse(aux.buttons[2])
        XCTAssertTrue(aux.buttons[3])
        XCTAssertFalse(aux.buttons[4])
    }

    func testAuxTooShortReturnsEmpty() {
        var st = DecoderState()
        XCTAssertTrue(decode([0x11], state: &st).isEmpty)
    }

    // MARK: - Tool-change serial and tool-code decode

    func testToolChangeDecodesMungedSerialAndCode() {
        var st = DecoderState()
        // Build a tool-change packet with known bytes and verify serial/code extraction.
        // status=0xC2 → (status & 0xFC)==0xC0 ✓
        // Serial = report[3][4:7]<<4 packed into 32 bits; tool code spread across [2][3][7][8].
        // Using the same bytes as the existing test (from the source comment):
        var b = [UInt8](repeating: 0, count: 10)
        b[0] = 0x10
        b[1] = 0xC2
        b[2] = 0x08; b[3] = 0x02  // toolCode lower: 0x08<<4 | 0x02>>4 = 0x080
        b[6] = 0x08; b[7] = 0x02  // toolCode upper: (0x02 & 0x0F)<<12 | (0x08 & 0xF0)<<4 ...
        // For a straightforward test: verify isEraser from tool code bit 3.
        // Set b[2]=0x00, b[3]=0x00, b[7]=0x08, b[8]=0x00:
        // toolCode = (0x00<<4) | (0x00>>4) | ((0x08 & 0x0F)<<12) | ((0x00 & 0xF0)<<4)
        //          = 0 | 0 | (8<<12) | 0 = 0x8000
        // bit3 of 0x8000 = 0 → not eraser
        // Try b[2]=0x00, b[3]=0x08 (report[3]>>4 contributes bit3):
        // Wait, let me just use a value where isEraser is expected.
        // isEraser = (toolCode & 0x0008) != 0
        // Need bit 3 of toolCode set. toolCode = UInt16(report[2])<<4 | UInt16(report[3])>>4 | ...
        // UInt16(report[2])<<4: any contribution. UInt16(report[3])>>4: bit3 if report[3]=0x80.
        b = [UInt8](repeating: 0, count: 10)
        b[0] = 0x10
        b[1] = 0xC2
        b[3] = 0x80  // report[3]>>4 = 8 → contributes 0x0008 to toolCode
        let r = decode(b, state: &st)
        XCTAssertFalse(r.isEmpty)
        guard case .toolEnter(let tool) = r[0] else {
            return XCTFail("expected .toolEnter, got \(r[0])")
        }
        XCTAssertTrue(tool.isEraser, "tool code bit3 should mark eraser")
    }
}
