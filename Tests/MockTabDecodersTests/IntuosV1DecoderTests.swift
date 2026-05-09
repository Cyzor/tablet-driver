// SPDX-License-Identifier: GPL-3.0-or-later
//
// First snapshot tests for the IntuosV1 decoder family.
// These exist to catch regressions in dispatch and proximity-state logic;
// they are NOT exhaustive coverage. Add cases as bugs are discovered or
// new behaviors are added.
import XCTest
@testable import MockTabDecoders

final class IntuosV1DecoderTests: XCTestCase {

    // PTH-851 dimensions (intuosV1 family). Doesn't need to be exact for these tests.
    private let pth851 = DigitizerSpec(
        maxX: 31920, maxY: 19950, maxPressure: 2047,
        buttonCount: 8, hasTilt: true, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 4)

    private func decode(
        _ bytes: [UInt8], state: inout DecoderState,
        family: String = "intuos"
    ) -> [DecodeResult] {
        var decoder = IntuosV1Decoder()
        return bytes.withUnsafeBufferPointer { buf -> [DecodeResult] in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: pth851, state: &state, deviceFamily: family)
        }
    }

    // MARK: - Dispatch & rejection

    func testEmptyReportReturnsNoResults() {
        var state = DecoderState()
        XCTAssertTrue(decode([], state: &state).isEmpty)
        XCTAssertTrue(decode([0x10], state: &state).isEmpty)
    }

    func testWrongLengthUSBPenReportIsRejected() {
        // 0x02 with length != 10 must be ignored — PTH-850 Interface 1 emits a
        // 63-byte vendor-specific touch payload using the same report ID; the
        // decoder must not interpret those bytes as pen coordinates.
        var state = DecoderState()
        let touchSizedPayload = [UInt8](repeating: 0xAA, count: 63)
        XCTAssertTrue(decode([0x02] + touchSizedPayload.dropFirst(), state: &state).isEmpty)
    }

    // MARK: - Tool-change packet

    func testToolChangePacketEmitsToolEnter() {
        // status & 0xFC == 0xC0 marks a tool-identity packet.
        // Layout (per Linux wacom_intuos_inout): byte 1 = 0xC0..0xC3 (entering),
        // bytes 2..5 hold the 32-bit serial, bytes 6..7 hold the tool code.
        var state = DecoderState()
        var bytes = [UInt8](repeating: 0, count: 10)
        bytes[0] = 0x10
        bytes[1] = 0xC2          // tool entering, low bits 0x02
        bytes[2] = 0x12; bytes[3] = 0x34; bytes[4] = 0x56; bytes[5] = 0x78  // serial
        bytes[6] = 0x08; bytes[7] = 0x02  // tool code 0x0802 (standard pen)

        let results = decode(bytes, state: &state)
        guard case .toolEnter(let tool)? = results.first else {
            return XCTFail("Expected .toolEnter as first result, got \(results)")
        }
        XCTAssertFalse(tool.isEraser)
    }

    // MARK: - Proximity exit

    func testProximityExitEmitsInProximityFalse() {
        // After the pen has been in proximity, a status byte with both prox (bit 5)
        // and confidence (bit 6) clear must produce a final .pen with inProximity=false
        // and pressure 0 — the kernel "wacom out" model.
        var state = DecoderState()
        state.prevInProximity = true
        state.lastX = 1000
        state.lastY = 2000

        let bytes: [UInt8] = [0x10, 0x00, 0, 0, 0, 0, 0, 0, 0, 0]
        let results = decode(bytes, state: &state)

        guard case .pen(let p)? = results.first else {
            return XCTFail("Expected .pen result on proximity exit, got \(results)")
        }
        XCTAssertFalse(p.inProximity)
        XCTAssertEqual(p.pressure, 0)
        XCTAssertFalse(state.prevInProximity)
    }
}
