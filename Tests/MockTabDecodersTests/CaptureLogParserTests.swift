// SPDX-License-Identifier: MPL-2.0
//
// Tests for the capture-log parser plus one end-to-end smoke test that
// replays a real PTH-860 log excerpt through `IntuosV2Decoder`.  The
// smoke test is the template for any "user submitted a log against
// hardware we don't own" regression test we'll add later.

import XCTest
@testable import TabletKit

final class CaptureLogParserTests: XCTestCase {

    // MARK: - Parser unit tests

    /// Headerless excerpts are accepted with `requireHeader: false` —
    /// the mode tests use to embed sample data without a full file header.
    func testParsesSingleBodyLineWithoutHeader() throws {
        let log = "[00:00.003] Intuos Pro L (PTH-86 ID=10 len=4    10 60 F2 69"
        let records = try CaptureLogParser.parse(log, requireHeader: false)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.timestampMs, 3)
        XCTAssertEqual(r.deviceTag, "Intuos Pro L (PTH-86")
        XCTAssertEqual(r.reportID, 0x10)
        XCTAssertEqual(r.length, 4)
        XCTAssertEqual(r.bytes, [0x10, 0x60, 0xF2, 0x69])
    }

    func testTimestampMinutesAndSecondsAndMillis() throws {
        let log = "[02:34.567] tag ID=01 len=1    01"
        let records = try CaptureLogParser.parse(log, requireHeader: false)
        XCTAssertEqual(records[0].timestampMs, ((2 * 60) + 34) * 1000 + 567)
    }

    func testRequireHeaderRejectsHeaderlessInput() {
        let log = "[00:00.003] tag ID=10 len=1    10"
        XCTAssertThrowsError(try CaptureLogParser.parse(log)) { error in
            XCTAssertEqual(error as? CaptureLogParseError, .missingHeader)
        }
    }

    func testRequireHeaderAcceptsRealHeader() throws {
        let log = """
            MockTab HID Capture
            Started : 2026-03-27 23:28:26 +0000
            Reports : 1
            Format  : [mm:ss.ms] <device-tag>            ID=<hex> len=<n>  <hex bytes>
            ──────────────────────────────────────────────────────────────────────────
            [00:00.003] Intuos Pro L (PTH-86 ID=10 len=2    10 60
            """
        let records = try CaptureLogParser.parse(log)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].bytes, [0x10, 0x60])
    }

    func testBlankLinesAndCommentsSkipped() throws {
        let log = """

            # this is a note
            [00:00.003] tag ID=10 len=1    10

            [00:00.005] tag ID=11 len=1    11
            """
        let records = try CaptureLogParser.parse(log, requireHeader: false)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].reportID, 0x10)
        XCTAssertEqual(records[1].reportID, 0x11)
    }

    func testLengthMismatchThrows() {
        let log = "[00:00.003] tag ID=10 len=4    10 60"  // declared 4, only 2 bytes
        XCTAssertThrowsError(try CaptureLogParser.parse(log, requireHeader: false)) { error in
            guard case .lengthMismatch(_, let declared, let actual) = error as? CaptureLogParseError
            else { return XCTFail("Expected .lengthMismatch, got \(error)") }
            XCTAssertEqual(declared, 4)
            XCTAssertEqual(actual, 2)
        }
    }

    func testInvalidHexByteThrows() {
        let log = "[00:00.003] tag ID=10 len=2    10 ZZ"
        XCTAssertThrowsError(try CaptureLogParser.parse(log, requireHeader: false)) { error in
            guard case .invalidHexByte(_, let token) = error as? CaptureLogParseError
            else { return XCTFail("Expected .invalidHexByte, got \(error)") }
            XCTAssertEqual(token, "ZZ")
        }
    }

    func testMalformedTimestampThrows() {
        let log = "[bad-ts] tag ID=10 len=1    10"
        XCTAssertThrowsError(try CaptureLogParser.parse(log, requireHeader: false)) { error in
            guard case .malformedLine = error as? CaptureLogParseError
            else { return XCTFail("Expected .malformedLine, got \(error)") }
        }
    }

    /// Long device tags run straight into `ID=` with no whitespace — the parser
    /// must still anchor correctly.  Real example from the Bluetooth capture
    /// where the device tag "Creaky Black Wacom I" was followed immediately by
    /// "ID=80".
    func testLongDeviceTagAdjacentToIDMarker() throws {
        let log = "[00:00.366] Creaky Black Wacom I ID=80 len=3    80 00 00"
        let records = try CaptureLogParser.parse(log, requireHeader: false)
        XCTAssertEqual(records[0].deviceTag, "Creaky Black Wacom I")
        XCTAssertEqual(records[0].reportID, 0x80)
    }

    // MARK: - End-to-end replay against a real decoder

    /// Six contiguous frames from the PTH-860 USB Works capture (2026-03-27).
    /// All Report ID 0x10 pen-hover events; bytes [21:22] = 0x0842 (Wacom
    /// "Intuos Pro 2 pen" tool code).  The decoder should:
    ///   • emit one `.toolEnter` on the first frame (tool ID newly seen),
    ///   • emit `.point` updates with proximity true on every frame,
    ///   • not crash on any frame.
    private static let pth860SampleLog = """
        [00:00.003] Intuos Pro L (PTH-86 ID=10 len=27    10 60 F2 69 00 A8 62 00 00 00 21 0D 00 00 00 00 09 B7 A5 80 14 42 08 10 00 42 08
        [00:00.008] Intuos Pro L (PTH-86 ID=10 len=27    10 60 ED 69 00 A8 62 00 00 00 21 0D 00 00 00 00 0A B7 A5 80 14 42 08 10 00 42 08
        [00:00.010] Intuos Pro L (PTH-86 ID=10 len=27    10 60 EA 69 00 A8 62 00 00 00 21 0D 00 00 00 00 0B B7 A5 80 14 42 08 10 00 42 08
        [00:00.016] Intuos Pro L (PTH-86 ID=10 len=27    10 60 E4 69 00 A7 62 00 00 00 21 0D 00 00 00 00 0C B7 A5 80 14 42 08 10 00 42 08
        [00:00.022] Intuos Pro L (PTH-86 ID=10 len=27    10 60 DF 69 00 A8 62 00 00 00 21 0D 00 00 00 00 0E B7 A5 80 14 42 08 10 00 42 08
        [00:00.032] Intuos Pro L (PTH-86 ID=10 len=27    10 60 DB 69 00 A9 62 00 00 00 21 0D 00 00 00 00 0F B7 A5 80 14 42 08 10 00 42 08
        """

    private let pth860 = DigitizerSpec(
        maxX: 62200, maxY: 43200, maxPressure: 8191,
        buttonCount: 8, hasTilt: true, hasDualRings: false,
        isPenDisplay: false, ringSlotCount: 4)

    func testReplayPTH860SampleThroughIntuosV2Decoder() throws {
        let records = try CaptureLogParser.parse(
            Self.pth860SampleLog, requireHeader: false)
        XCTAssertEqual(records.count, 6, "All six sample frames should parse")

        var decoder = IntuosV2Decoder()
        var state   = DecoderState()
        var allResults: [DecodeResult] = []
        for record in records {
            let results = record.bytes.withUnsafeBufferPointer { buf -> [DecodeResult] in
                decoder.decode(
                    report: buf.baseAddress!, length: record.length,
                    spec: pth860, state: &state, deviceFamily: "intuosProGen2")
            }
            allResults.append(contentsOf: results)
        }

        // Exactly one `.toolEnter` across the whole replay (first frame only).
        let toolEnters = allResults.filter {
            if case .toolEnter = $0 { return true } else { return false }
        }
        XCTAssertEqual(toolEnters.count, 1,
                       "Tool identity should be reported once, on first sight")

        // At least one `.pen` event must be emitted — proves the decoder
        // actually consumed the replayed bytes rather than no-op'ing.
        let penCount = allResults.filter {
            if case .pen = $0 { return true } else { return false }
        }.count
        XCTAssertGreaterThan(penCount, 0,
                             "Replay produced no .pen events — decoder didn't run?")
    }

    // MARK: - hid-recorder format

    /// Minimal hid-recorder dump shape — three event lines plus the metadata
    /// lines that real `hid-recorder` output always carries.  Modelled on the
    /// format documented at https://man.archlinux.org/man/hid-recorder.1.en
    /// (verified 2026-05-26).
    private static let hidRecorderSample = """
        # hid-recorder
        # Recorded on Tue 26 May 2026 10:00:00 AM
        N: Wacom Intuos Pro M
        P: usb-0000:00:14.0-3/input0
        I: 3 056a 0357
        R: 18 05 0d 09 02 a1 01 85 10 09 20 a1 00 09 32 81 02 c0 c0
        E: 000000.000123 27 10 60 f2 69 00 a8 62 00 00 00 21 0d 00 00 00 00 09 b7 a5 80 14 42 08 10 00 42 08
        E: 000000.005678 27 10 60 ed 69 00 a8 62 00 00 00 21 0d 00 00 00 00 0a b7 a5 80 14 42 08 10 00 42 08
        E: 000000.010234 27 10 60 ea 69 00 a8 62 00 00 00 21 0d 00 00 00 00 0b b7 a5 80 14 42 08 10 00 42 08
        """

    func testHidRecorderParsesEventLines() throws {
        let records = try CaptureLogParser.parseHidRecorder(Self.hidRecorderSample)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].reportID, 0x10)
        XCTAssertEqual(records[0].length, 27)
        XCTAssertEqual(records[0].bytes.first, 0x10)
        XCTAssertEqual(records[0].bytes.last, 0x08)
    }

    func testHidRecorderCapturesDeviceTagFromNLine() throws {
        let records = try CaptureLogParser.parseHidRecorder(Self.hidRecorderSample)
        XCTAssertEqual(records[0].deviceTag, "Wacom Intuos Pro M")
        // Every record should carry the same deviceTag (single-device dump).
        XCTAssertTrue(records.allSatisfy { $0.deviceTag == "Wacom Intuos Pro M" })
    }

    func testHidRecorderNormalisesTimestampToZeroOrigin() throws {
        // Source timestamps: 0.000123, 0.005678, 0.010234 seconds.
        // After normalisation: 0 ms, 5 ms (truncated from 5.555), 10 ms.
        let records = try CaptureLogParser.parseHidRecorder(Self.hidRecorderSample)
        XCTAssertEqual(records[0].timestampMs, 0)
        XCTAssertEqual(records[1].timestampMs, 5)
        XCTAssertEqual(records[2].timestampMs, 10)
    }

    func testHidRecorderSkipsNonEventLines() throws {
        // No E: lines at all — should produce zero records, not throw.
        let metadataOnly = """
            # comment
            N: Some Device
            P: some-path
            I: 3 256c 006d
            R: 4 05 01 09 02
            """
        XCTAssertEqual(try CaptureLogParser.parseHidRecorder(metadataOnly).count, 0)
    }

    /// End-to-end replay: feed an embedded hid-recorder dump for a PTH-660
    /// (Wacom) device through `IntuosV2Decoder` and assert that the decoder
    /// produces the same shape of output it would on the in-app log format.
    /// This is the canonical pattern for converting a future user-submitted
    /// hid-recorder dump into a regression test.
    func testHidRecorderReplayThroughIntuosV2Decoder() throws {
        let records = try CaptureLogParser.parseHidRecorder(Self.hidRecorderSample)
        XCTAssertEqual(records.count, 3)

        var decoder = IntuosV2Decoder()
        var state   = DecoderState()
        var results: [DecodeResult] = []
        for record in records {
            let r = record.bytes.withUnsafeBufferPointer { buf -> [DecodeResult] in
                decoder.decode(
                    report: buf.baseAddress!, length: record.length,
                    spec: pth860, state: &state, deviceFamily: "intuosProGen2")
            }
            results.append(contentsOf: r)
        }
        let penCount = results.filter {
            if case .pen = $0 { return true } else { return false }
        }.count
        XCTAssertGreaterThan(penCount, 0,
                             "hid-recorder → CaptureRecord → IntuosV2Decoder pipeline produced no .pen events")
    }

    // MARK: - hid-recorder parser error cases

    func testHidRecorderMalformedTimestampThrows() {
        let bad = "E: not-a-timestamp 1 10"
        XCTAssertThrowsError(try CaptureLogParser.parseHidRecorder(bad)) { error in
            guard case .malformedLine = error as? CaptureLogParseError
            else { return XCTFail("Expected .malformedLine, got \(error)") }
        }
    }

    func testHidRecorderLengthMismatchThrows() {
        let bad = "E: 0.000000 4 10 60"  // declared 4, supplied 2
        XCTAssertThrowsError(try CaptureLogParser.parseHidRecorder(bad)) { error in
            guard case .lengthMismatch(_, let declared, let actual) = error as? CaptureLogParseError
            else { return XCTFail("Expected .lengthMismatch, got \(error)") }
            XCTAssertEqual(declared, 4)
            XCTAssertEqual(actual, 2)
        }
    }
}
