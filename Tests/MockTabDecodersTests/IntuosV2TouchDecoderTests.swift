// SPDX-License-Identifier: GPL-3.0-or-later
//
// IntuosV2 finger-touch decoder fixtures (Report ID 0x21).
//
// Format confirmed by live capture from PTH-860 (PID 0x0358) 2026-05-21.
// 44-byte report: [0]=0x21 [1]=contact count, then 5 × 8-byte fixed slots.
// Slot layout: [0]=slot_id [1]=status(0x01=down,0x00=lift) [2..3]=X LE16
//              [4..5]=Y LE16 [6]=touch major [7]=reserved
// Coordinate range: X 0–12439, Y 0–8639 (PTH-860).
import XCTest
@testable import MockTabDecoders

final class IntuosV2TouchDecoderTests: XCTestCase {

    private let pth860 = DigitizerSpec(
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
                spec: pth860, state: &state, deviceFamily: family)
        }
    }

    /// Build a 44-byte 0x21 touch report.  `slots` is an array of
    /// (slot_id, status, x, y, major) tuples; up to 5 are written.
    private func make0x21(count: UInt8, slots: [(UInt8, UInt8, UInt16, UInt16, UInt8)]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 44)
        bytes[0] = 0x21
        bytes[1] = count
        for (i, s) in slots.prefix(5).enumerated() {
            let base = 2 + i * 8
            bytes[base + 0] = s.0                      // slot_id
            bytes[base + 1] = s.1                      // status
            bytes[base + 2] = UInt8(s.2 & 0xFF)        // X low
            bytes[base + 3] = UInt8((s.2 >> 8) & 0xFF) // X high
            bytes[base + 4] = UInt8(s.3 & 0xFF)        // Y low
            bytes[base + 5] = UInt8((s.3 >> 8) & 0xFF) // Y high
            bytes[base + 6] = s.4                      // touch major
        }
        return bytes
    }

    // MARK: - Dispatch

    func testTooShortRejected() {
        var s = DecoderState()
        // 9 bytes — guard length >= 10
        let bytes: [UInt8] = [0x21, 0x01, 0x02, 0x01, 0x64, 0x00, 0x20, 0x00, 0x18]
        XCTAssertTrue(decode(bytes, state: &s).isEmpty)
    }

    func testZeroContactCountReturnsEmptyTouch() {
        var s = DecoderState()
        let bytes = make0x21(count: 0, slots: [])
        let results = decode(bytes, state: &s)
        XCTAssertEqual(results.count, 1)
        if case .touch(let contacts) = results[0] {
            XCTAssertTrue(contacts.isEmpty)
        } else {
            XCTFail("expected .touch, got \(results[0])")
        }
    }

    // MARK: - Single contact

    func testSingleFingerDown() {
        var s = DecoderState()
        // Slot 2 active at X=3456, Y=2048, major=28
        let bytes = make0x21(count: 1, slots: [(2, 0x01, 3456, 2048, 28)])
        let results = decode(bytes, state: &s)
        XCTAssertEqual(results.count, 1)
        guard case .touch(let contacts) = results[0] else {
            XCTFail("expected .touch"); return
        }
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts[0].id, 2)
        XCTAssertEqual(contacts[0].x, 3456)
        XCTAssertEqual(contacts[0].y, 2048)
        XCTAssertEqual(contacts[0].contactArea, 28)
    }

    func testLiftFrameStatusZeroProducesEmptyContact() {
        var s = DecoderState()
        // status=0x00 on the only slot → lift frame → contacts empty
        let bytes = make0x21(count: 1, slots: [(2, 0x00, 3456, 2048, 28)])
        let results = decode(bytes, state: &s)
        XCTAssertEqual(results.count, 1)
        if case .touch(let contacts) = results[0] {
            XCTAssertTrue(contacts.isEmpty, "lift frame must yield no active contacts")
        } else {
            XCTFail("expected .touch, got \(results[0])")
        }
    }

    // MARK: - Multi-contact

    func testTwoFingersDown() {
        var s = DecoderState()
        let bytes = make0x21(count: 2, slots: [
            (2, 0x01, 1000, 800, 20),
            (3, 0x01, 9000, 6000, 22)
        ])
        let results = decode(bytes, state: &s)
        guard case .touch(let contacts) = results.first else {
            XCTFail("expected .touch"); return
        }
        XCTAssertEqual(contacts.count, 2)
        XCTAssertEqual(contacts[0].id, 2)
        XCTAssertEqual(contacts[0].x, 1000)
        XCTAssertEqual(contacts[0].y, 800)
        XCTAssertEqual(contacts[1].id, 3)
        XCTAssertEqual(contacts[1].x, 9000)
        XCTAssertEqual(contacts[1].y, 6000)
    }

    func testMixedActiveAndLiftSlotsOnlyReturnsActive() {
        var s = DecoderState()
        // Slot 2 active, slot 3 lifting
        let bytes = make0x21(count: 2, slots: [
            (2, 0x01, 4000, 3000, 24),
            (3, 0x00, 9000, 6000, 22)
        ])
        let results = decode(bytes, state: &s)
        guard case .touch(let contacts) = results.first else {
            XCTFail("expected .touch"); return
        }
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts[0].id, 2)
    }

    func testFiveFingers() {
        var s = DecoderState()
        let bytes = make0x21(count: 5, slots: [
            (2, 0x01,   100,  100, 18),
            (3, 0x01, 12300, 8500, 20),
            (4, 0x01,  6200, 4300, 22),
            (5, 0x01,  3000, 2000, 19),
            (6, 0x01,  9000, 6000, 21)
        ])
        let results = decode(bytes, state: &s)
        guard case .touch(let contacts) = results.first else {
            XCTFail("expected .touch"); return
        }
        XCTAssertEqual(contacts.count, 5)
    }

    // MARK: - Coordinate extremes

    func testTopLeftCorner() {
        var s = DecoderState()
        let bytes = make0x21(count: 1, slots: [(2, 0x01, 0, 0, 18)])
        let results = decode(bytes, state: &s)
        guard case .touch(let contacts) = results.first else { XCTFail(); return }
        XCTAssertEqual(contacts[0].x, 0)
        XCTAssertEqual(contacts[0].y, 0)
    }

    func testBottomRightCorner() {
        var s = DecoderState()
        // PTH-860 hardware-reported max: X=12439, Y=8639
        let bytes = make0x21(count: 1, slots: [(2, 0x01, 12439, 8639, 18)])
        let results = decode(bytes, state: &s)
        guard case .touch(let contacts) = results.first else { XCTFail(); return }
        XCTAssertEqual(contacts[0].x, 12439)
        XCTAssertEqual(contacts[0].y, 8639)
    }

    // MARK: - count clamped to 5

    func testCountFieldCappedAtFive() {
        var s = DecoderState()
        // Declare count=7 but only 5 slots fit in 44 bytes; decoder caps at min(count,5)
        let bytes = make0x21(count: 7, slots: [
            (2, 0x01,  100,  100, 18),
            (3, 0x01,  200,  200, 19),
            (4, 0x01,  300,  300, 20),
            (5, 0x01,  400,  400, 21),
            (6, 0x01,  500,  500, 22)
        ])
        let results = decode(bytes, state: &s)
        guard case .touch(let contacts) = results.first else { XCTFail(); return }
        XCTAssertEqual(contacts.count, 5)
    }
}
