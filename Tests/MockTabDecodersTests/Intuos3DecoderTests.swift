// SPDX-License-Identifier: GPL-3.0-or-later
//
// Intuos3 decoder fixtures (PTZ-631W and family).
//
// No hardware capture is available; all reports are synthesized from the
// byte-layout comments in Intuos3Decoder.swift.
//
// Focus: features that differ from IntuosV1Decoder (already tested):
//   • Proximity bit is bit 6 (0x40) not bit 5 (0x20)
//   • Proximity exit does NOT guard on prevInProximity — always emits
//   • 0x03 aux report: 8 keys packed in byte 4
//   • 0x0C pad report: touch strips (BE16 one-hot), express keys (4+4 nibble split)
//
// Report IDs covered:
//   • 0x10 / 0x02 — USB pen report (10 bytes), same coord layout as IntuosV1
//   • 0x03        — aux report (10 bytes), 8 express keys in byte 4
//   • 0x0C        — pad report (5–10 bytes), touch strips + express keys
import XCTest
@testable import TabletKit

final class Intuos3DecoderTests: XCTestCase {

    private let ptz631w = DigitizerSpec(
        maxX: 25400, maxY: 20320, maxPressure: 1023,
        buttonCount: 8, hasTilt: true, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 0)

    private func decode(
        _ bytes: [UInt8], state: inout DecoderState,
        family: String = "intuos3"
    ) -> [DecodeResult] {
        var decoder = Intuos3Decoder()
        return bytes.withUnsafeBufferPointer { buf in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: ptz631w, state: &state, deviceFamily: family)
        }
    }

    /// 10-byte USB pen report for Intuos3.
    /// [0]=0x10, [1]=status, [2..3]=X BE16 *halved* (decoder shifts << 1 | frac),
    /// [4..5]=Y BE16, [6]=pressHigh, [7]=pressTiltLow, [8]=tiltY, [9]=frac.
    private func makePen(
        id: UInt8 = 0x10,
        status: UInt8,
        xHigh: UInt8 = 0, xLow: UInt8 = 0,
        yHigh: UInt8 = 0, yLow: UInt8 = 0,
        pressHigh: UInt8 = 0,
        pressTiltLow: UInt8 = 0,
        tiltY: UInt8 = 0x40,  // 0x40 = 64 → (64 & 0x7F) - 64 = 0 (zero tilt)
        frac: UInt8 = 0
    ) -> [UInt8] {
        [id, status, xHigh, xLow, yHigh, yLow, pressHigh, pressTiltLow, tiltY, frac]
    }

    // MARK: - Length guard

    func testTooShortReturnsEmpty() {
        var st = DecoderState()
        XCTAssertTrue(decode([0x10], state: &st).isEmpty)
    }

    // MARK: - Proximity bit is bit 6 (0x40)

    func testBit6IsProximityBit() {
        var st = DecoderState()
        // status=0x40 → bit 6 set → in proximity
        let b = makePen(status: 0x40)
        let r = decode(b, state: &st)
        XCTAssertFalse(r.isEmpty)
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail("expected .pen") }
        XCTAssertTrue(pt.inProximity)
    }

    func testBit5DoesNotMeanProximity() {
        var st = DecoderState()
        // status=0x20 → bit 5 set but NOT bit 6 → Intuos3 treats this as out-of-proximity
        // Decoder will emit a proximity-exit frame (even with prevInProximity=false)
        let b = makePen(status: 0x20)
        let r = decode(b, state: &st)
        // Result should be an exit frame (inProximity=false), not an in-proximity frame
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail("expected .pen exit") }
        XCTAssertFalse(pt.inProximity)
    }

    // MARK: - Proximity exit: no guard on prevInProximity

    func testProximityExitAlwaysEmitsFrameEvenWhenPrevInProximityFalse() {
        var st = DecoderState()
        XCTAssertFalse(st.prevInProximity)
        // Out-of-proximity with prevInProximity=false — Intuos3 still emits exit frame.
        let b = makePen(status: 0x00)
        let r = decode(b, state: &st)
        XCTAssertFalse(r.isEmpty, "Intuos3 should emit exit frame even without prior prox entry")
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail() }
        XCTAssertFalse(pt.inProximity)
    }

    // MARK: - USB pen: prox entry emits .pen(inProximity:true)

    func testUSBPenProxEntryEmitsPenInProximity() {
        var st = DecoderState()
        let b = makePen(status: 0x40)
        let r = decode(b, state: &st)
        let pen = r.first { if case .pen = $0 { return true }; return false }
        guard case .pen(let pt) = pen else { return XCTFail() }
        XCTAssertTrue(pt.inProximity)
        XCTAssertTrue(st.prevInProximity)
    }

    // MARK: - Tool-change packet

    func testToolChangePacketEmitsToolEnter() {
        var st = DecoderState()
        // Tool-change: status & 0xFC == 0xC0 → status = 0xC0 (bits 7:2 = 0b110000)
        // Craft a minimal valid tool-change packet: all-zero data bytes are fine for
        // the serial/toolCode decode — we just check that .toolEnter is emitted.
        var b = [UInt8](repeating: 0, count: 10)
        b[0] = 0x10
        b[1] = 0xC0  // status: (0xC0 & 0xFC) == 0xC0 → tool-change path
        let r = decode(b, state: &st)
        let enter = r.first { if case .toolEnter = $0 { return true }; return false }
        XCTAssertNotNil(enter, "tool-change packet should emit .toolEnter")
    }

    // MARK: - 0x03 aux report (8 express keys in byte 4)

    func test0x03AuxShortReturnsEmpty() {
        var st = DecoderState()
        // Need length >= 10; 9 bytes should be rejected
        let b = [UInt8](repeating: 0, count: 9)
        XCTAssertTrue(decode([0x03] + Array(b.dropFirst()), state: &st).isEmpty)
    }

    func test0x03AuxAllEightKeysSet() {
        var st = DecoderState()
        // byte 4 = 0xFF → all 8 keys
        var b = [UInt8](repeating: 0, count: 10)
        b[0] = 0x03
        b[4] = 0xFF
        let r = decode(b, state: &st)
        XCTAssertFalse(r.isEmpty)
        guard case .aux(let aux) = r[0] else { return XCTFail("expected .aux") }
        for i in 0..<8 {
            XCTAssertTrue(aux.buttons[i], "button \(i) should be true")
        }
    }

    func test0x03AuxSingleKeyButton3() {
        var st = DecoderState()
        // byte 4 = 0x08 = bit 3 → only button[3]
        var b = [UInt8](repeating: 0, count: 10)
        b[0] = 0x03
        b[4] = 0x08
        let r = decode(b, state: &st)
        guard case .aux(let aux) = r[0] else { return XCTFail("expected .aux") }
        XCTAssertFalse(aux.buttons[0])
        XCTAssertFalse(aux.buttons[1])
        XCTAssertFalse(aux.buttons[2])
        XCTAssertTrue(aux.buttons[3])
        XCTAssertFalse(aux.buttons[4])
    }

    // MARK: - 0x0C pad report: touch strips

    func test0x0CTouchStripLeftPosition0() {
        var st = DecoderState()
        // leftRaw = (bytes[1] << 8) | bytes[2] = 0x0001 → bit 0 set → position = trailingZeroBitCount(1) = 0
        var b: [UInt8] = [0x0C, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        let r = decode(b, state: &st)
        guard case .aux(let aux) = r[0] else { return XCTFail("expected .aux") }
        XCTAssertTrue(aux.touchStrip1Active)
        XCTAssertEqual(aux.touchStrip1Position, 0)
    }

    func test0x0CTouchStripLeftPosition5() {
        var st = DecoderState()
        // leftRaw = 0x0020 = bit 5 set → position = trailingZeroBitCount(0x20) = 5
        var b: [UInt8] = [0x0C, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00]
        let r = decode(b, state: &st)
        guard case .aux(let aux) = r[0] else { return XCTFail("expected .aux") }
        XCTAssertTrue(aux.touchStrip1Active)
        XCTAssertEqual(aux.touchStrip1Position, 5)
    }

    func test0x0CTouchStripLeftInactive() {
        var st = DecoderState()
        // leftRaw = 0x0000 → inactive, position=0xFF
        let b: [UInt8] = [0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let r = decode(b, state: &st)
        guard case .aux(let aux) = r[0] else { return XCTFail("expected .aux") }
        XCTAssertFalse(aux.touchStrip1Active)
        XCTAssertEqual(aux.touchStrip1Position, 0xFF)
    }

    // MARK: - 0x0C pad report: express keys

    func test0x0CExpressKeysLowNibbleAllSet() {
        var st = DecoderState()
        // bytes[5] = 0x0F → buttons[0..3] all true
        let b: [UInt8] = [0x0C, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x00]
        let r = decode(b, state: &st)
        guard case .aux(let aux) = r[0] else { return XCTFail("expected .aux") }
        XCTAssertTrue(aux.buttons[0])
        XCTAssertTrue(aux.buttons[1])
        XCTAssertTrue(aux.buttons[2])
        XCTAssertTrue(aux.buttons[3])
        XCTAssertFalse(aux.buttons[4])
    }

    func test0x0CExpressKeysHighNibbleAllSet() {
        var st = DecoderState()
        // bytes[6] = 0x0F → buttons[4..7] all true
        let b: [UInt8] = [0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F]
        let r = decode(b, state: &st)
        guard case .aux(let aux) = r[0] else { return XCTFail("expected .aux") }
        XCTAssertFalse(aux.buttons[3])
        XCTAssertTrue(aux.buttons[4])
        XCTAssertTrue(aux.buttons[5])
        XCTAssertTrue(aux.buttons[6])
        XCTAssertTrue(aux.buttons[7])
    }

    func test0x0CExpressKeysAbsentWhenLengthUnder7() {
        var st = DecoderState()
        // length=5 → no bytes[5..6] → all buttons false
        let b: [UInt8] = [0x0C, 0x00, 0x00, 0x00, 0x00]
        let r = decode(b, state: &st)
        guard case .aux(let aux) = r[0] else { return XCTFail("expected .aux") }
        for i in 0..<8 {
            XCTAssertFalse(aux.buttons[i], "button \(i) should be false when length < 7")
        }
    }

    func test0x0CShortUnder5BytesRejected() {
        var st = DecoderState()
        let b: [UInt8] = [0x0C, 0x00, 0x00, 0x00]
        XCTAssertTrue(decode(b, state: &st).isEmpty)
    }
}
