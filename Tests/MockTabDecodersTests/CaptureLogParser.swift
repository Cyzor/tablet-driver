// SPDX-License-Identifier: MPL-2.0
//
// Parser for the in-app HID capture log format.
//
// The capture flow (`DataCaptureLogs/*.txt` in the companion notes repo) emits
// timestamped raw HID reports as plain text.  This parser turns those files
// into `[CaptureRecord]` so test cases can replay real-world traffic against
// the live decoders without hand-translating hex strings.
//
// Workflow for adding a regression test from a user-submitted log:
//
//     let log = try String(contentsOf: url, encoding: .utf8)
//     let records = try CaptureLogParser.parse(log)
//     var decoder = IntuosV2Decoder()
//     var state   = DecoderState()
//     for r in records {
//         let results = r.bytes.withUnsafeBufferPointer { buf in
//             decoder.decode(report: buf.baseAddress!, length: r.length,
//                            spec: spec, state: &state, deviceFamily: "...")
//         }
//         // assert on results …
//     }
//
// Format (from the file header):
//
//     [mm:ss.ms] <device-tag>            ID=<hex> len=<n>  <hex bytes>
//
// The device-tag field is space-padded to a fixed width and may run straight
// into `ID=` when the device name is long — the parser anchors on `ID=` /
// `len=` markers rather than column positions.

import Foundation

/// One HID report extracted from a capture log.
public struct CaptureRecord: Equatable {
    /// Milliseconds since the capture started.
    public let timestampMs: Int
    /// Device tag exactly as it appeared in the log (trailing spaces trimmed).
    /// May be truncated — the in-app emitter pads to a fixed width.
    public let deviceTag: String
    /// HID report ID (first byte of the report, also the `ID=` field value).
    public let reportID: UInt8
    /// Length declared by the `len=` field.  Equals `bytes.count` when the log
    /// is well-formed; the parser raises `.lengthMismatch` if they disagree.
    public let length: Int
    /// Full report bytes including the leading report ID.
    public let bytes: [UInt8]
}

/// Errors raised by `CaptureLogParser.parse`.
public enum CaptureLogParseError: Error, Equatable {
    /// The header `MockTab HID Capture` marker was expected but not found.
    /// Non-fatal: callers can use `parse(_:requireHeader: false)` to allow
    /// headerless excerpts (useful for embedded test fixtures).
    case missingHeader
    /// A non-blank body line didn't match the `[mm:ss.ms] … ID=NN len=N  …` shape.
    case malformedLine(lineNumber: Int, content: String)
    /// `len=` declared one length but the hex-byte payload was a different count.
    case lengthMismatch(lineNumber: Int, declared: Int, actual: Int)
    /// A hex byte couldn't be parsed (non-hex character, bad width, etc).
    case invalidHexByte(lineNumber: Int, token: String)
}

public enum CaptureLogParser {

    /// Parse a capture log into records.
    ///
    /// - Parameters:
    ///   - text: Full log file contents (typically read via `String(contentsOf:)`).
    ///   - requireHeader: When `true` (default), the `MockTab HID Capture` line
    ///     must be present.  Set `false` to accept body-only excerpts — useful
    ///     when embedding sample data directly in a test fixture.
    /// - Throws: `CaptureLogParseError` if a record line is malformed.
    public static func parse(_ text: String, requireHeader: Bool = true) throws -> [CaptureRecord] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var inBody = !requireHeader
        var sawHeader = false
        var records: [CaptureRecord] = []

        for (idx, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Header / separator handling.
            if !inBody {
                if trimmed.hasPrefix("MockTab HID Capture") { sawHeader = true }
                // The `──────…` rule line marks the end of the header block.
                if trimmed.first == "\u{2500}" {        // box-drawings light horizontal
                    inBody = true
                }
                continue
            }

            // Body: skip blank lines.
            if trimmed.isEmpty { continue }

            // Records start with `[`; anything else in the body is unexpected
            // (a stray comment, perhaps) — skip rather than throw, so log
            // authors can interleave notes.
            guard trimmed.first == "[" else { continue }

            records.append(try parseRecord(line: trimmed, lineNumber: idx + 1))
        }

        if requireHeader && !sawHeader {
            throw CaptureLogParseError.missingHeader
        }
        return records
    }

    // MARK: - Line parsing

    private static func parseRecord(line: String, lineNumber: Int) throws -> CaptureRecord {
        // Expected shape:
        //   [mm:ss.ms] <device-tag>… ID=<hex> len=<n>  <hex bytes>
        //
        // We anchor on `]`, `ID=`, and `len=` to be robust against the
        // variable-width device-tag column.

        guard let tsEnd = line.firstIndex(of: "]"),
              line.first == "[" else {
            throw CaptureLogParseError.malformedLine(lineNumber: lineNumber, content: line)
        }
        let tsField = line[line.index(after: line.startIndex)..<tsEnd]
        guard let timestampMs = parseTimestamp(String(tsField)) else {
            throw CaptureLogParseError.malformedLine(lineNumber: lineNumber, content: line)
        }

        let afterTs = line[line.index(after: tsEnd)...]

        guard let idRange = afterTs.range(of: "ID="),
              let lenRange = afterTs.range(of: "len="),
              idRange.upperBound < lenRange.lowerBound else {
            throw CaptureLogParseError.malformedLine(lineNumber: lineNumber, content: line)
        }

        // Device tag is everything between the timestamp and `ID=`, trimmed.
        let deviceTag = afterTs[..<idRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)

        // ID field value: everything from `ID=` up to the next whitespace.
        let idStart = idRange.upperBound
        guard let idEnd = afterTs[idStart...].firstIndex(where: { $0.isWhitespace }) else {
            throw CaptureLogParseError.malformedLine(lineNumber: lineNumber, content: line)
        }
        let idToken = String(afterTs[idStart..<idEnd])
        guard let reportID = UInt8(idToken, radix: 16) else {
            throw CaptureLogParseError.invalidHexByte(lineNumber: lineNumber, token: idToken)
        }

        // Length field value: everything from `len=` up to the next whitespace.
        let lenStart = lenRange.upperBound
        guard let lenEnd = afterTs[lenStart...].firstIndex(where: { $0.isWhitespace }) else {
            throw CaptureLogParseError.malformedLine(lineNumber: lineNumber, content: line)
        }
        let lenToken = String(afterTs[lenStart..<lenEnd])
        guard let length = Int(lenToken) else {
            throw CaptureLogParseError.malformedLine(lineNumber: lineNumber, content: line)
        }

        // Bytes: everything after the `len=` token, split on whitespace.
        let bytePart = afterTs[lenEnd...]
        var bytes: [UInt8] = []
        bytes.reserveCapacity(length)
        for token in bytePart.split(whereSeparator: { $0.isWhitespace }) {
            guard let byte = UInt8(token, radix: 16) else {
                throw CaptureLogParseError.invalidHexByte(
                    lineNumber: lineNumber, token: String(token))
            }
            bytes.append(byte)
        }
        guard bytes.count == length else {
            throw CaptureLogParseError.lengthMismatch(
                lineNumber: lineNumber, declared: length, actual: bytes.count)
        }

        return CaptureRecord(
            timestampMs: timestampMs, deviceTag: deviceTag,
            reportID: reportID, length: length, bytes: bytes)
    }

    /// Parse a `mm:ss.ms` timestamp string into total milliseconds.
    private static func parseTimestamp(_ s: String) -> Int? {
        // Split on `:` then on `.` — `mm:ss.fff`.
        let colonParts = s.split(separator: ":", maxSplits: 1)
        guard colonParts.count == 2,
              let minutes = Int(colonParts[0]) else { return nil }
        let dotParts = colonParts[1].split(separator: ".", maxSplits: 1)
        guard dotParts.count == 2,
              let seconds = Int(dotParts[0]),
              let millis  = Int(dotParts[1]) else { return nil }
        return ((minutes * 60) + seconds) * 1000 + millis
    }

    // MARK: - hid-recorder adapter

    /// Parse a `hid-recorder` text dump (the format produced by
    /// https://github.com/hidutils/hid-recorder and the older `hid-tools`).
    ///
    /// The line types recognised:
    ///
    ///     E: <secs>.<usecs> <size> <hex bytes…>   ← event (a HID report)
    ///     N: <device name>                        ← captured as deviceTag
    ///     # …                                     ← comment, ignored
    ///     R: / P: / I: / D: …                     ← skipped (metadata)
    ///
    /// Timestamps in the source file are wall-clock-ish seconds with
    /// microsecond resolution.  This parser normalises so that the first
    /// returned record has `timestampMs == 0`, matching the convention of
    /// the in-app capture format.
    ///
    /// Unlocks the OpenTabletDriver / DIGImend / kernel-bugzilla corpus as
    /// regression fixtures — paste any user-submitted hid-recorder dump
    /// into a test, call this parser, replay the records through the
    /// relevant decoder.
    public static func parseHidRecorder(_ text: String) throws -> [CaptureRecord] {
        struct Raw { let usecs: Int64; let reportID: UInt8; let length: Int; let bytes: [UInt8] }
        var raws: [Raw] = []
        var deviceTag = ""

        for (idx, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("N:") {
                deviceTag = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            // R: / P: / I: / D: are metadata we don't need for replay.
            if line.hasPrefix("R:") || line.hasPrefix("P:")
                || line.hasPrefix("I:") || line.hasPrefix("D:") { continue }

            guard line.hasPrefix("E:") else { continue }

            // E: <secs>.<usecs> <size> <hex bytes…>
            let payload = line.dropFirst(2)
            let tokens = payload.split(whereSeparator: { $0.isWhitespace })
            guard tokens.count >= 2 else {
                throw CaptureLogParseError.malformedLine(lineNumber: idx + 1, content: line)
            }

            // Timestamp: seconds.microseconds → total microseconds.
            let tsToken = tokens[0]
            let tsParts = tsToken.split(separator: ".", maxSplits: 1)
            guard tsParts.count == 2,
                  let secs  = Int64(tsParts[0]),
                  let usecs = Int64(tsParts[1].padding(toLength: 6, withPad: "0", startingAt: 0))
            else {
                throw CaptureLogParseError.malformedLine(lineNumber: idx + 1, content: line)
            }
            let totalUsecs = secs * 1_000_000 + usecs

            guard let length = Int(tokens[1]) else {
                throw CaptureLogParseError.malformedLine(lineNumber: idx + 1, content: line)
            }

            var bytes: [UInt8] = []
            bytes.reserveCapacity(length)
            for token in tokens.dropFirst(2) {
                guard let b = UInt8(token, radix: 16) else {
                    throw CaptureLogParseError.invalidHexByte(
                        lineNumber: idx + 1, token: String(token))
                }
                bytes.append(b)
            }
            guard bytes.count == length else {
                throw CaptureLogParseError.lengthMismatch(
                    lineNumber: idx + 1, declared: length, actual: bytes.count)
            }
            guard let reportID = bytes.first else {
                throw CaptureLogParseError.malformedLine(lineNumber: idx + 1, content: line)
            }

            raws.append(Raw(usecs: totalUsecs, reportID: reportID,
                            length: length, bytes: bytes))
        }

        // Normalise timestamps so the first record is t=0 (matches mockTab format).
        guard let base = raws.first?.usecs else { return [] }
        return raws.map { r in
            CaptureRecord(
                timestampMs: Int((r.usecs - base) / 1000),
                deviceTag: deviceTag,
                reportID: r.reportID,
                length: r.length,
                bytes: r.bytes)
        }
    }
}
