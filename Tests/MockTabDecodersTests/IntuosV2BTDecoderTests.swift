// SPDX-License-Identifier: GPL-3.0-or-later
//
// IntuosV2 Bluetooth Classic decoder fixtures.
//
// Two BT payloads share Report ID 0x80:
//   • 361-byte container — PTH-660 BT Classic
//     (1 byte header + 7 × 14-byte pen frames + device metadata + pad + battery)
//   • 99-byte container  — PTH-860 BT Classic
//     (1 byte header + 7 × 14-byte pen frames; no metadata, pad, or battery)
//
// These tests exist to lock in dispatch, the proximity-exit state machine
// (the area flagged in Architecture-Improvement-Plan.md as the most under-tested
// code), and the eraser / barrel-button / battery / pad sub-paths in the 361-byte
// container. They are not exhaustive — add cases as bugs are discovered.
import XCTest
@testable import MockTabDecoders

final class IntuosV2BTDecoderTests: XCTestCase {

    // PTH-660 / PTH-860 dimensions (intuosV2 family). Exact values don't affect
    // dispatch/state-machine tests; pressure max matches PTH-660 BT firmware.
    private let pth660 = DigitizerSpec(
        maxX: 62200, maxY: 43200, maxPressure: 8191,
        buttonCount: 8, hasTilt: true, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 4)

    private func decode(
        _ bytes: [UInt8], state: inout DecoderState,
        family: String = "intuosProGen2"
    ) -> [DecodeResult] {
        var decoder = IntuosV2Decoder()
        return bytes.withUnsafeBufferPointer { buf -> [DecodeResult] in
            decoder.decode(
                report: buf.baseAddress!, length: bytes.count,
                spec: pth660, state: &state, deviceFamily: family)
        }
    }

    /// Build a 361-byte BT container with a single valid frame at frame index 0,
    /// trailing frames flagged invalid, and the device-metadata tool code written
    /// at bytes [103:104]. Caller can mutate the returned buffer further.
    private func make361(toolCode: UInt16 = 0x0842, frame0Flags: UInt8 = 0xE0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 361)
        bytes[0] = 0x80
        bytes[1] = frame0Flags  // valid + prox + inRange by default
        bytes[103] = UInt8(toolCode & 0xFF)
        bytes[104] = UInt8((toolCode >> 8) & 0xFF)
        return bytes
    }

    /// Build a 99-byte BT container with one valid frame at index 0 and the rest invalid.
    private func make99(frame0Flags: UInt8 = 0xE0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 99)
        bytes[0] = 0x80
        bytes[1] = frame0Flags
        return bytes
    }

    // MARK: - Dispatch & length rejection

    func testWirelessStatusDispatchTakesPrecedenceOver361() {
        // report[0]=0x80, report[1]=0x02 → wireless active, not BT pen.
        var state = DecoderState()
        var bytes = [UInt8](repeating: 0, count: 361)
        bytes[0] = 0x80
        bytes[1] = 0x02
        let results = decode(bytes, state: &state)
        guard case .wireless(.active)? = results.first else {
            return XCTFail("Expected .wireless(.active), got \(results)")
        }
    }

    func testShort80ReportRejected() {
        // Length < 15 → BT pen path bails before reading frames.
        var state = DecoderState()
        let bytes: [UInt8] = [0x80, 0xE0]
        XCTAssertTrue(decode(bytes, state: &state).isEmpty)
    }

    func test99ByteShortReportRejected() {
        // 99-byte path requires length >= 99 exactly.
        var state = DecoderState()
        var bytes = [UInt8](repeating: 0, count: 98)
        bytes[0] = 0x80
        XCTAssertTrue(decode(bytes, state: &state).isEmpty)
    }

    // MARK: - 361-byte path: tool identity

    func testToolEnterEmittedOnFirstSightOfToolCode() {
        var state = DecoderState()
        // 0x0842 = Pro Pen 3 (non-eraser, non-mouse).
        var bytes = make361(toolCode: 0x0842)
        // Coordinate bytes so the .pen result has decodable point data.
        bytes[2] = 0xD0; bytes[3] = 0x07   // x = 2000
        bytes[4] = 0xB8; bytes[5] = 0x0B   // y = 3000
        bytes[6] = 0x10; bytes[7] = 0x00   // pressure = 16 (low only)

        let results = decode(bytes, state: &state)

        // First result should be a tool-enter, with no eraser / mouse flags.
        guard case .toolEnter(let tool)? = results.first else {
            return XCTFail("Expected .toolEnter as first result, got \(results)")
        }
        XCTAssertEqual(tool.toolCode, 0x0842)
        XCTAssertFalse(tool.isEraser)
        XCTAssertFalse(tool.isMouse)
        XCTAssertEqual(state.lastToolCode, 0x0842)
    }

    func testArtPenToolCodeWithBit3SetIsNotMisclassifiedAsEraser() {
        // 0x1108 has bit3 set but is an Art Pen variant, not an eraser.
        var state = DecoderState()
        let bytes = make361(toolCode: 0x1108)
        let results = decode(bytes, state: &state)

        let toolEnter = results.compactMap { result -> ToolIdentity? in
            if case .toolEnter(let t) = result { return t } else { return nil }
        }.first
        XCTAssertNotNil(toolEnter)
        XCTAssertFalse(toolEnter?.isEraser ?? true, "Art Pen 0x1108 must not be flagged eraser")
    }

    // MARK: - 361-byte path: proximity exit state machine

    func testGenuineProximityExitOnFirstFrameEmitsInProximityFalse() {
        // Flag pattern 0x80: valid + neither prox nor inRange — the kernel "exit" condition.
        // With state already in-proximity, this should produce a single .pen with
        // inProximity=false and pressure=0.
        var state = DecoderState()
        state.prevInProximity = true
        state.lastX = 1234
        state.lastY = 5678

        let bytes = make361(toolCode: 0x0842, frame0Flags: 0x80)
        let results = decode(bytes, state: &state)

        let pen = results.compactMap { result -> TabletPoint? in
            if case .pen(let p) = result { return p } else { return nil }
        }.first
        XCTAssertNotNil(pen)
        XCTAssertFalse(pen?.inProximity ?? true)
        XCTAssertEqual(pen?.pressure, 0)
        XCTAssertFalse(state.prevInProximity)
    }

    func testBoundaryNoiseDoesNotExitBelowThreshold() {
        // 0xC0 frame (prox=1, inRange=0) is boundary noise — must NOT exit unless
        // exitFrameCount reaches DecoderState.exitThreshold (3). Following frames
        // are valid in-range (0xE0) so they don't push the counter further.
        var state = DecoderState()
        state.prevInProximity = true
        state.exitFrameCount = 0
        state.lastToolCode = 0x0842  // suppress toolEnter so we count pen-only results

        var bytes = make361(toolCode: 0x0842, frame0Flags: 0xC0)
        // Frames 1..6 valid + prox + inRange — reset the boundary counter cleanly.
        for i in 1..<7 { bytes[1 + i * 14] = 0xE0 }

        let results = decode(bytes, state: &state)

        XCTAssertTrue(state.prevInProximity, "Single boundary frame must not exit proximity")
        // Decode still emits the boundary-noise point (the comment is "don't suppress
        // output on boundary noise"). The last good frame's inProximity should also be true.
        let lastPenInProx = results.compactMap { result -> Bool? in
            if case .pen(let p) = result { return p.inProximity } else { return nil }
        }.last
        XCTAssertEqual(lastPenInProx, true, "Frames during boundary noise should still emit .pen with inProximity=true")
    }

    func testBoundaryNoiseExitsAtThreshold() {
        // Three consecutive 0xC0 frames in one report should trigger exit at the third.
        var state = DecoderState()
        state.prevInProximity = true
        state.exitFrameCount = 0
        state.lastToolCode = 0x0842

        var bytes = make361(toolCode: 0x0842, frame0Flags: 0xC0)
        // Set frames 1 and 2 to 0xC0 as well (each frame is 14 bytes starting at offset 1).
        bytes[1 + 14] = 0xC0
        bytes[1 + 28] = 0xC0

        _ = decode(bytes, state: &state)
        XCTAssertFalse(state.prevInProximity, "Three boundary frames should exit proximity")
    }

    // MARK: - 361-byte path: eraser and barrel buttons

    func testEraserBitSetInFrameFlagsEmittedOnPen() {
        var state = DecoderState()
        state.lastToolCode = 0x0842  // already in tool; skip toolEnter

        // 0xE8: valid + prox + inRange + eraser (bit3).
        let bytes = make361(toolCode: 0x0842, frame0Flags: 0xE8)
        let results = decode(bytes, state: &state)

        let pen = results.compactMap { result -> TabletPoint? in
            if case .pen(let p) = result { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.eraser, true)
    }

    func testBarrelButtonsDecodedFromFrameFlags() {
        var state = DecoderState()
        state.lastToolCode = 0x0842
        // 0xE6: valid + prox + inRange + barrel1 (bit1) + barrel2 (bit2).
        let bytes = make361(toolCode: 0x0842, frame0Flags: 0xE6)
        let results = decode(bytes, state: &state)
        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.penButton1, true)
        XCTAssertEqual(pen?.penButton2, true)
    }

    // MARK: - 361-byte path: battery and pad sub-report

    func testBatteryEmittedOnChange() {
        var state = DecoderState()
        state.lastToolCode = 0x0842
        state.lastBatteryByte = 0xFF  // sentinel: nothing seen yet

        var bytes = make361(toolCode: 0x0842)
        bytes[284] = 0x80 | 75  // charging + 75%

        let results = decode(bytes, state: &state)
        let battery = results.compactMap { r -> (Int, Bool)? in
            if case .battery(let pct, let charging) = r { return (pct, charging) } else { return nil }
        }.first
        XCTAssertEqual(battery?.0, 75)
        XCTAssertEqual(battery?.1, true)
        XCTAssertEqual(state.lastBatteryByte, 0x80 | 75)
    }

    func testPadCenterButtonAndRingEmittedOnChange() {
        var state = DecoderState()
        state.lastToolCode = 0x0842
        state.lastBTPadKeys = 0
        state.lastBTPadBtn = 0
        state.lastBTPadRing = 0x7F  // sentinel: ring inactive

        var bytes = make361(toolCode: 0x0842)
        bytes[281] = 0x40  // center button down
        bytes[282] = 0x01  // mechanical key 0 click pulse
        bytes[283] = 0x00
        bytes[285] = 0x10  // ring position 16, active (≠ 0x7F)

        let results = decode(bytes, state: &state)
        let aux = results.compactMap { r -> AuxButtons? in
            if case .aux(let a) = r { return a } else { return nil }
        }.first
        XCTAssertNotNil(aux)
        XCTAssertEqual(aux?.touchRingButtonDown, true)
        XCTAssertEqual(aux?.touchRingActive, true)
        XCTAssertEqual(aux?.touchRingPosition, 0x10)
        XCTAssertEqual(aux?.buttons.first, true, "Mechanical key 0 should be set")
    }

    // MARK: - 99-byte path

    func test99ByteFrameWithInvalidFlagsSkipped() {
        // frame0 flags = 0x00 (bit7 clear) → skipped entirely; no results.
        var state = DecoderState()
        let bytes = make99(frame0Flags: 0x00)
        XCTAssertTrue(decode(bytes, state: &state).isEmpty)
    }

    func test99BytePathDecodesValidFrameCoordinates() {
        var state = DecoderState()
        var bytes = make99(frame0Flags: 0xE0)  // valid + prox + inRange
        // Frame 0 starts at offset 1: f[1..2]=x LE, f[3..4]=y LE, f[5..6]=pressure (bit5 mask).
        bytes[2] = 0xE8; bytes[3] = 0x03   // x = 1000
        bytes[4] = 0xD0; bytes[5] = 0x07   // y = 2000
        bytes[6] = 0xFF; bytes[7] = 0x00   // pressure = 255 (low byte only)

        let results = decode(bytes, state: &state)
        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.x, 1000)
        XCTAssertEqual(pen?.y, 2000)
        XCTAssertEqual(pen?.pressure, 255)
        XCTAssertEqual(pen?.inProximity, true)
    }

    func test99BytePathProximityExitOnAllZeroFlags() {
        // Flag 0x80 alone: valid + neither prox nor inRange — kernel exit signal.
        var state = DecoderState()
        state.prevInProximity = true
        state.lastX = 100
        state.lastY = 200

        let bytes = make99(frame0Flags: 0x80)
        let results = decode(bytes, state: &state)

        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.inProximity, false)
        XCTAssertEqual(pen?.pressure, 0)
        XCTAssertFalse(state.prevInProximity)
    }
}
