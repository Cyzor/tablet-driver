// SPDX-License-Identifier: GPL-3.0-or-later
//
// IntuosV2 USB-path decoder fixtures.
//
// Covers the report IDs the Bluetooth tests don't:
//   • 0x10 — standard USB pen report (192 bytes; the main path for PTH-660/860 over USB)
//   • 0x11 — aux / express-key + touch-ring report
//   • 0x1E — offset pen report (driver-compatibility mode)
//   • 0x01 — short cordless-mouse button report (length ≤ 8)
//
// The proximity-exit state machine on the 0x10 path differs from the 0x80 BT path
// (status bits 6 and 5, not frame-flag bit 7/6/5), and the existing BT fixtures
// don't exercise it. These tests lock in the dispatch, the genuine vs boundary
// exit behaviour, and the pen / mouse / aux sub-paths.
import XCTest
@testable import MockTabDecoders

final class IntuosV2USBDecoderTests: XCTestCase {

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

    /// Build a 192-byte USB pen report (Report ID 0x10) with `status` in byte 1
    /// and `toolCode` written at bytes [21:22]. Caller mutates further.
    private func make0x10(status: UInt8 = 0x60, toolCode: UInt16 = 0x0842) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 192)
        bytes[0] = 0x10
        bytes[1] = status
        bytes[21] = UInt8(toolCode & 0xFF)
        bytes[22] = UInt8((toolCode >> 8) & 0xFF)
        return bytes
    }

    // MARK: - Dispatch

    func testShort0x10ReportRejected() {
        var state = DecoderState()
        var bytes = [UInt8](repeating: 0, count: 11)
        bytes[0] = 0x10
        XCTAssertTrue(decode(bytes, state: &state).isEmpty)
    }

    func testShort0x01EmitsMouseButton() {
        // Report ID 0x01 with length ≤ 8 is the cordless-mouse button report.
        var state = DecoderState()
        let bytes: [UInt8] = [0x01, 0x05, 0, 0]  // L + M buttons down
        let results = decode(bytes, state: &state)
        guard case .mouseButton(let mask)? = results.first else {
            return XCTFail("Expected .mouseButton, got \(results)")
        }
        XCTAssertEqual(mask, 0x05)
    }

    // MARK: - 0x10 pen path: tool identity

    func testToolEnterOnFirstSightOfToolCode() {
        var state = DecoderState()
        // Need length >= 27 for tool extraction; default make0x10 gives 192.
        // Set a serial so the toolChanged branch picks up the serial path.
        var bytes = make0x10(status: 0x60, toolCode: 0x0842)
        bytes[17] = 0x12; bytes[18] = 0x34; bytes[19] = 0x56; bytes[20] = 0x78
        let results = decode(bytes, state: &state)

        let toolEnter = results.compactMap { r -> ToolIdentity? in
            if case .toolEnter(let t) = r { return t } else { return nil }
        }.first
        XCTAssertEqual(toolEnter?.toolCode, 0x0842)
        XCTAssertEqual(toolEnter?.serial, 0x78563412)
        XCTAssertFalse(toolEnter?.isEraser ?? true)
        XCTAssertFalse(toolEnter?.isMouse ?? true)
        XCTAssertEqual(state.lastToolCode, 0x0842)
    }

    func testArtPen0x1108NotMisclassifiedAsEraser() {
        var state = DecoderState()
        let bytes = make0x10(status: 0x60, toolCode: 0x1108)
        let results = decode(bytes, state: &state)
        let toolEnter = results.compactMap { r -> ToolIdentity? in
            if case .toolEnter(let t) = r { return t } else { return nil }
        }.first
        XCTAssertNotNil(toolEnter)
        XCTAssertFalse(toolEnter?.isEraser ?? true, "Art Pen 0x1108 must not be flagged eraser despite bit3")
    }

    // MARK: - 0x10 pen path: coordinate + pressure decode

    func testPenCoordinatesPressureAndButtonsDecoded() {
        var state = DecoderState()
        state.lastToolCode = 0x0842  // skip toolEnter
        state.currentToolCode = 0x0842
        state.prevInProximity = true

        var bytes = make0x10(status: 0x66, toolCode: 0x0842)  // prox + conf + btn1 + btn2
        bytes[2] = 0xD0; bytes[3] = 0x07; bytes[4] = 0x00  // x = 2000 (24-bit LE)
        bytes[5] = 0xB8; bytes[6] = 0x0B; bytes[7] = 0x00  // y = 3000
        bytes[8] = 0xFF; bytes[9] = 0x07                    // pressure = 0x7FF = 2047
        bytes[10] = 64                                       // tiltX = 64/127 ≈ 0.504
        bytes[11] = UInt8(bitPattern: -64)                   // tiltY ≈ -0.504

        let results = decode(bytes, state: &state)
        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.x, 2000)
        XCTAssertEqual(pen?.y, 3000)
        XCTAssertEqual(pen?.pressure, 2047)
        XCTAssertEqual(pen?.penButton1, true)
        XCTAssertEqual(pen?.penButton2, true)
        XCTAssertEqual(pen?.inProximity, true)
        XCTAssertEqual(pen?.tiltX ?? 0, 64.0 / 127.0, accuracy: 0.001)
        XCTAssertEqual(pen?.tiltY ?? 0, -64.0 / 127.0, accuracy: 0.001)
    }

    func testEraserBitFromStatusEmittedOnPen() {
        var state = DecoderState()
        state.lastToolCode = 0x0842
        state.currentToolCode = 0x0842

        let bytes = make0x10(status: 0x68, toolCode: 0x0842)  // prox + conf + eraser
        let results = decode(bytes, state: &state)
        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.eraser, true)
    }

    // MARK: - 0x10 pen path: proximity exit state machine

    func testGenuineProximityExitPreservesCachedTiltAndRotation() {
        // status = 0x00 (neither prox nor highConf set) → kernel "genuine exit" signal.
        // Cached lastTiltX/Y/Rotation should ride along on the exit event so the
        // app's last frame doesn't snap to (0,0)/0°.
        var state = DecoderState()
        state.prevInProximity = true
        state.lastX = 12345
        state.lastY = 6789
        state.lastTiltX = 0.5
        state.lastTiltY = -0.25
        state.lastRotation = 137.0
        state.lastToolCode = 0x1108  // Art Pen so rotation is meaningful

        let bytes = make0x10(status: 0x00, toolCode: 0)  // zero toolCode → no overwrite
        let results = decode(bytes, state: &state)

        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertNotNil(pen)
        XCTAssertEqual(pen?.inProximity, false)
        XCTAssertEqual(pen?.pressure, 0)
        XCTAssertEqual(pen?.x, 12345)
        XCTAssertEqual(pen?.y, 6789)
        XCTAssertEqual(pen?.tiltX ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(pen?.tiltY ?? 0, -0.25, accuracy: 0.001)
        XCTAssertEqual(pen?.rotation ?? 0, 137.0, accuracy: 0.001)
        XCTAssertFalse(state.prevInProximity)
        XCTAssertEqual(state.lastTiltX, 0.0, "Cached tilt must be cleared after exit")
        XCTAssertEqual(state.lastRotation, 0.0)
    }

    func testBoundaryNoiseBelowThresholdPassesThroughCachedTilt() {
        // status = 0x40 (prox=1, highConf=0) is Art Pen rotation-sensor oscillation.
        // Below exit threshold, the decoder should emit cached tilt/rotation so the
        // azimuth doesn't snap to 0° on every low-confidence frame.
        var state = DecoderState()
        state.prevInProximity = true
        state.exitFrameCount = 0
        state.hasValidTiltFrame = true
        state.lastTiltX = 0.3
        state.lastTiltY = 0.4
        state.lastRotation = 90.0
        state.lastX = 1000
        state.lastY = 2000
        state.lastToolCode = 0x0842

        let bytes = make0x10(status: 0x40, toolCode: 0)
        let results = decode(bytes, state: &state)

        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertNotNil(pen, "Below-threshold boundary frames should still emit a pen event")
        XCTAssertEqual(pen?.inProximity, true)
        XCTAssertEqual(pen?.pressure, 0)
        XCTAssertEqual(pen?.x, 1000)
        XCTAssertEqual(pen?.tiltX ?? 0, 0.3, accuracy: 0.001, "Cached tiltX must survive boundary noise")
        XCTAssertEqual(pen?.tiltY ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(pen?.rotation ?? 0, 90.0, accuracy: 0.001)
        XCTAssertTrue(state.prevInProximity, "Single boundary frame must not exit proximity")
        XCTAssertEqual(state.exitFrameCount, 1)
    }

    func testBoundaryNoiseExitsAtThreshold() {
        // Three 0x40 frames in a row should trigger the proximity exit on the third.
        var state = DecoderState()
        state.prevInProximity = true
        state.exitFrameCount = 0
        state.hasValidTiltFrame = true
        state.lastToolCode = 0x0842

        let bytes = make0x10(status: 0x40, toolCode: 0)
        _ = decode(bytes, state: &state)
        XCTAssertTrue(state.prevInProximity)
        _ = decode(bytes, state: &state)
        XCTAssertTrue(state.prevInProximity)
        _ = decode(bytes, state: &state)
        XCTAssertFalse(state.prevInProximity, "Third consecutive boundary frame should exit proximity")
    }

    // MARK: - 0x10 mouse path

    func testCordlessMousePathEmitsWheelDeltaFromByte16() {
        // Mouse tool codes have low nibble = 0x6 (per kernel + decoder comment).
        // 0x0007 is not a mouse; 0x0806 (5-button mouse) is. Use that.
        var state = DecoderState()
        var bytes = make0x10(status: 0x60, toolCode: 0x0806)
        bytes[17] = 0x99  // serial
        bytes[16] = 0x05  // initial scroll position
        _ = decode(bytes, state: &state)
        XCTAssertEqual(state.lastScrollPos, 0x05)
        XCTAssertEqual(state.toolIsMouse, true)

        bytes[16] = 0x08  // moved 3 ticks forward
        let results = decode(bytes, state: &state)
        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.mouseWheelDelta, 3)
    }

    func testMouseWheelDeltaWrapsCorrectlyAcrossByteBoundary() {
        // 254 → 1 should read as +3 (signed delta via Int8(bitPattern:)).
        var state = DecoderState()
        var bytes = make0x10(status: 0x60, toolCode: 0x0806)
        bytes[17] = 0x99
        bytes[16] = 254
        _ = decode(bytes, state: &state)
        bytes[16] = 1
        let results = decode(bytes, state: &state)
        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.mouseWheelDelta, 3, "Wheel counter wrap should produce +3, not -253")
    }

    // MARK: - 0x11 aux report

    func testAuxRingPositionDecodedAndCenterButtonReported() {
        // Layout: [0]=0x11 [1]=mechanical keys [3]=center button [4]=ring position (0x7F = none).
        var state = DecoderState()
        let bytes: [UInt8] = [
            0x11,
            0x01,  // mechanical key 0 pressed
            0x00,
            0x42,  // center button down (non-zero)
            0x10,  // ring position 16 (active)
            0, 0, 0, 0,
        ]
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

    func testAuxRingInactiveWhenPosition0x7F() {
        var state = DecoderState()
        let bytes: [UInt8] = [0x11, 0x00, 0x00, 0x00, 0x7F, 0, 0, 0, 0]
        let results = decode(bytes, state: &state)
        let aux = results.compactMap { r -> AuxButtons? in
            if case .aux(let a) = r { return a } else { return nil }
        }.first
        XCTAssertEqual(aux?.touchRingActive, false)
    }

    // MARK: - 0x1E offset pen report

    func testOffsetPenReportCoordinatesPressureAndProximity() {
        // 0x1E layout: status at [2], x at [3..5], y at [6..8], pressure at [9..10].
        var state = DecoderState()
        var bytes = [UInt8](repeating: 0, count: 17)
        bytes[0] = 0x1E
        bytes[2] = 0x22                                  // prox bit (0x20) only
        bytes[3] = 0xD0; bytes[4] = 0x07; bytes[5] = 0x00  // x = 2000
        bytes[6] = 0xB8; bytes[7] = 0x0B; bytes[8] = 0x00  // y = 3000
        bytes[9] = 0xFF; bytes[10] = 0x07                  // pressure = 2047

        let results = decode(bytes, state: &state)
        let pen = results.compactMap { r -> TabletPoint? in
            if case .pen(let p) = r { return p } else { return nil }
        }.first
        XCTAssertEqual(pen?.x, 2000)
        XCTAssertEqual(pen?.y, 3000)
        XCTAssertEqual(pen?.pressure, 2047)
        XCTAssertEqual(pen?.inProximity, true)
        XCTAssertEqual(pen?.penButton1, true, "Status bit1 set → button 1 down")
    }
}
