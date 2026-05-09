// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tests for the shared wireless-status helper used by the IntuosV1 family
// over the ACK-40401 RF dongle.
import XCTest
@testable import MockTabDecoders

final class WirelessReportTests: XCTestCase {

    private func decode(_ bytes: [UInt8]) -> [DecodeResult] {
        bytes.withUnsafeBufferPointer { buf in
            decodeWirelessReport(report: buf.baseAddress!, length: bytes.count)
        }
    }

    func testShortReportReturnsEmpty() {
        XCTAssertTrue(decode([]).isEmpty)
        XCTAssertTrue(decode([0x80]).isEmpty)
    }

    func testActiveBitSetEmitsActive() {
        let results = decode([0x80, 0x01])
        guard case .wireless(let s)? = results.first, case .active = s else {
            return XCTFail("Expected .wireless(.active), got \(results)")
        }
    }

    func testActiveBitClearEmitsLost() {
        let results = decode([0x80, 0x00])
        guard case .wireless(let s)? = results.first, case .lost = s else {
            return XCTFail("Expected .wireless(.lost), got \(results)")
        }
    }
}
