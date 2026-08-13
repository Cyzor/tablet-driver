// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// DiscoveryAccumulatorTests.swift — Standalone checks for the device-data
// collection accumulator (MockTab/Driver/Discovery/DiscoveryAccumulator.swift).
//
// This is where "Collect Device Data…" either produces meaningful data or
// quietly produces nonsense, and it can't be exercised without a tablet
// otherwise: the capture path now folds every report into fixed-size
// statistics on the HID callback thread and never retains a raw sample, so a
// classification bug is invisible until someone reads a submitted file.
//
// One case is replayed from real hardware — report 0xC0 of
// Notes/Scratch/Discovery-Data-Caputure/mocktab_discovery_0x033E_20260703_004619.json
// (Wacom CTH-690), whose four samples were all-constant with known values.
//
// The app has no XCTest target (by design — see the project's test
// conventions), so this runs as a small executable compiled against the real
// source file. Run via tools/tests/discovery-accumulator-tests/run.sh.
// Exits non-zero on the first failure.

import Foundation

// MARK: - Tiny assertion harness

private var failures = 0
private var checks = 0

private func expect(_ condition: Bool, _ message: @autoclosure () -> String,
                    file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition {
        failures += 1
        FileHandle.standardError.write(Data("FAIL (\(file):\(line)): \(message())\n".utf8))
    }
}

private func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: @autoclosure () -> String,
                                       file: StaticString = #file, line: UInt = #line) {
    expect(a == b, "\(message()) — got \(a), expected \(b)", file: file, line: line)
}

// MARK: - Helpers

/// Feed one report to the accumulator the way a driver's IOKit callback does.
private func feed(_ acc: DiscoveryAccumulator, _ reportID: UInt8, _ bytes: [UInt8]) {
    bytes.withUnsafeBufferPointer { buf in
        acc.record(reportID: reportID, pointer: buf.baseAddress!, length: buf.count)
    }
}

private func stats(_ acc: DiscoveryAccumulator, _ reportID: UInt8)
    -> DiscoveryAccumulator.ReportStats?
{
    acc.snapshot().reports[reportID]
}

// The three published byte lists come straight from `byteRoles()`, so these
// helpers exercise the same partition the capture file is built from.

private func varying(_ s: DiscoveryAccumulator.ReportStats) -> [Int] {
    s.byteRoles().filter { $0.role == .varying }.map(\.index)
}

private func constant(_ s: DiscoveryAccumulator.ReportStats) -> [Int] {
    s.byteRoles().compactMap { if case .constant = $0.role { return $0.index } else { return nil } }
}

private func constantValues(_ s: DiscoveryAccumulator.ReportStats) -> [Int] {
    s.byteRoles().compactMap {
        if case .constant(let v) = $0.role { return Int(v) } else { return nil }
    }
}

private func optional(_ s: DiscoveryAccumulator.ReportStats) -> [Int] {
    s.byteRoles().filter { $0.role == .optional }.map(\.index)
}

/// Every byte position must be classified exactly once, with the constant
/// values list staying in step with the constant index list. `buildDiscoveryResult`
/// publishes these as three parallel arrays; if the partition ever leaks a
/// position or double-counts one, the capture file silently misdescribes the
/// device.
private func expectWellFormedPartition(_ s: DiscoveryAccumulator.ReportStats,
                                       _ label: String) {
    let roles = s.byteRoles()
    expectEqual(roles.count, s.maxLength, "\(label): every byte position is classified")
    expectEqual(roles.map(\.index), Array(0..<s.maxLength), "\(label): positions are in order")
    let all = varying(s) + constant(s) + optional(s)
    expectEqual(Set(all).count, s.maxLength, "\(label): positions classified exactly once")
    expectEqual(constant(s).count, constantValues(s).count,
                "\(label): constant indices and values stay in step")
    expectEqual(s.byteValues.count, s.maxLength, "\(label): byte statistics cover every position")
}

// MARK: - ByteValueSet

private func testByteValueSet() {
    var s = ByteValueSet()
    expect(s.isEmpty, "a fresh set is empty")
    expectEqual(s.count, 0, "empty count")
    expect(s.min == nil && s.max == nil, "empty set has no min/max")

    // Values straddling all four 64-bit words, including both extremes.
    for v: UInt8 in [0, 1, 63, 64, 127, 128, 191, 192, 255] { s.insert(v) }
    expectEqual(s.count, 9, "distinct count across word boundaries")
    expectEqual(s.min, 0, "min across word boundaries")
    expectEqual(s.max, 255, "max across word boundaries")
    expectEqual(s.values, [0, 1, 63, 64, 127, 128, 191, 192, 255], "values ascending")

    // Re-inserting must not change anything.
    s.insert(64)
    s.insert(0)
    expectEqual(s.count, 9, "re-insertion is idempotent")

    // A single value in the top word: exercises min/max scanning past empty words.
    var top = ByteValueSet()
    top.insert(200)
    expectEqual(top.count, 1, "single value count")
    expectEqual(top.min, 200, "min of a single high value")
    expectEqual(top.max, 200, "max of a single high value")

    // A single value in the *bottom* word, with every higher word empty. This
    // is the case that distinguishes a correct word index from one taken after
    // reversing: getting it wrong reports 197 (3 * 64 + 5) instead of 5.
    for v: UInt8 in [0, 5, 63] {
        var low = ByteValueSet()
        low.insert(v)
        expectEqual(low.min, v, "min of a lone value \(v) in the first word")
        expectEqual(low.max, v, "max of a lone value \(v) in the first word")
        expectEqual(low.values, [v], "values of a lone value \(v) in the first word")
    }

    // One value per word, to pin the index arithmetic at every boundary.
    for (v, label) in [(UInt8(1), "word 0"), (UInt8(65), "word 1"),
                       (UInt8(130), "word 2"), (UInt8(200), "word 3")] {
        var one = ByteValueSet()
        one.insert(v)
        expectEqual(one.min, v, "min in \(label)")
        expectEqual(one.max, v, "max in \(label)")
    }

    // Every possible value.
    var full = ByteValueSet()
    for v in UInt8.min...UInt8.max { full.insert(v) }
    expectEqual(full.count, 256, "full set counts every value")
    expectEqual(full.min, 0, "full set min")
    expectEqual(full.max, 255, "full set max")
    expectEqual(full.values.count, 256, "full set enumerates every value")
}

// MARK: - Gating

private func testGating() {
    let acc = DiscoveryAccumulator()

    // Reports before start() are dropped: drivers now call unconditionally.
    feed(acc, 0x10, [0x10, 1, 2])
    expectEqual(acc.sampleCount, 0, "reports before start() are ignored")
    expect(acc.snapshot().reports.isEmpty, "no stats accumulate before start()")

    acc.start()
    feed(acc, 0x10, [0x10, 1, 2])
    feed(acc, 0x10, [0x10, 1, 3])
    expectEqual(acc.sampleCount, 2, "reports during a session are counted")

    acc.stop()
    feed(acc, 0x10, [0x10, 9, 9])
    expectEqual(acc.sampleCount, 2, "reports after stop() are ignored")
    expect(stats(acc, 0x10) != nil, "stats survive stop() so the result can be built")

    // A second session must not inherit the first one's data.
    acc.start()
    expectEqual(acc.sampleCount, 0, "start() resets the sample count")
    expect(acc.snapshot().reports.isEmpty, "start() discards the previous session")
    expect(acc.snapshot().toolCodes.isEmpty, "start() discards previous tool codes")
}

// MARK: - Real-hardware replay

/// Report 0xC0 from the CTH-690 capture: 4 samples, no varying bytes, and
/// these exact constant values.
private func testCTH690ConstantReport() {
    let sample: [UInt8] = [0xC0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
    let acc = DiscoveryAccumulator()
    acc.start()
    for _ in 0..<4 { feed(acc, 0xC0, sample) }

    guard let s = stats(acc, 0xC0) else {
        expect(false, "report 0xC0 recorded")
        return
    }
    expectEqual(s.sampleCount, 4, "0xC0 sample count matches the capture")
    expectEqual(s.firstLength, 10, "0xC0 length matches the capture")
    expect(!s.lengthVaried, "0xC0 arrived at one length")
    expectEqual(varying(s), [], "0xC0 has no varying bytes, per the capture")
    expectEqual(constant(s), Array(0..<10), "every 0xC0 byte is constant")
    expectEqual(constantValues(s), sample.map(Int.init),
                "0xC0 constant values match the capture")
    expectEqual(optional(s), [], "0xC0 has no optional bytes")
    expectWellFormedPartition(s, "0xC0")
    expectEqual(s.firstSample, sample, "first sample is retained verbatim")
}

// MARK: - Value-range fidelity

/// The regression this file exists for: a byte's *ceiling* must survive.
///
/// The previous implementation sorted the observed values and kept
/// `prefix(20)`, so a pressure byte sweeping 0…255 was reported as having
/// taken the values 0…19 — the exact number a triager reads the capture for,
/// silently replaced by its opposite.
private func testPressureCeilingSurvives() {
    let acc = DiscoveryAccumulator()
    acc.start()
    for v in 0...255 {
        feed(acc, 0x10, [0x10, 0x00, UInt8(v)])
    }
    guard let s = stats(acc, 0x10) else {
        expect(false, "pressure report recorded")
        return
    }
    let pressure = s.byteValues[2]
    expectEqual(pressure.min, 0, "pressure floor observed")
    expectEqual(pressure.max, 255, "pressure ceiling observed")
    expectEqual(pressure.count, 256, "every pressure value observed")
    expectEqual(varying(s), [2], "only the pressure byte varies")
    expectEqual(constant(s), [0, 1], "report ID and the fixed byte stay constant")
    expectWellFormedPartition(s, "pressure sweep")

    // The capture file lists a bounded sample of the observed values. That
    // list must still show how high the byte went — this is the exact defect
    // the old `sorted().prefix(20)` had.
    let (listed, truncated) = pressure.sampledValues(cap: 24)
    expect(truncated, "256 values are reported as truncated")
    expectEqual(listed.count, 24, "the listed sample honors the cap")
    expectEqual(listed.first, 0, "the listed sample starts at the floor")
    expectEqual(listed.last, 255, "the listed sample reaches the ceiling")
    expect(listed.contains(255), "the ceiling appears in the value list")
    expectEqual(listed, listed.sorted(), "the listed sample stays ascending")
    expectEqual(Set(listed).count, listed.count, "the listed sample has no duplicates")

    // One more than the cap is the case where the low and high halves come
    // closest to meeting; they must still not overlap.
    var justOver = ByteValueSet()
    for v in 0...24 { justOver.insert(UInt8(v)) }
    let (edge, edgeTruncated) = justOver.sampledValues(cap: 24)
    expect(edgeTruncated, "one value over the cap is truncated")
    expectEqual(edge.count, 24, "one value over the cap still honors the cap")
    expectEqual(Set(edge).count, edge.count, "no duplicates at the truncation boundary")
    expectEqual(edge.first, 0, "floor kept at the truncation boundary")
    expectEqual(edge.last, 24, "ceiling kept at the truncation boundary")

    // Under the cap, nothing is dropped or flagged.
    var small = ByteValueSet()
    for v: UInt8 in [3, 9, 200] { small.insert(v) }
    let (allValues, smallTruncated) = small.sampledValues(cap: 24)
    expect(!smallTruncated, "a short value list is not marked truncated")
    expectEqual(allValues, [3, 9, 200], "a short value list is complete")

    // Exactly at the cap is still complete.
    var exact = ByteValueSet()
    for v in 0..<24 { exact.insert(UInt8(v)) }
    let (exactValues, exactTruncated) = exact.sampledValues(cap: 24)
    expect(!exactTruncated, "a value list exactly at the cap is not truncated")
    expectEqual(exactValues.count, 24, "a value list exactly at the cap is complete")
}

// MARK: - Variable-length reports

/// A report ID that arrives at more than one length must not have its extra
/// bytes silently dropped, nor be called constant on the strength of the
/// samples that happened to include them.
private func testVariableLength() {
    let acc = DiscoveryAccumulator()
    acc.start()
    feed(acc, 0x21, [0x21, 0x01, 0x02, 0x03])
    feed(acc, 0x21, [0x21, 0x01, 0x09, 0x03, 0xAA, 0xBB])
    feed(acc, 0x21, [0x21, 0x01, 0x07, 0x03])

    guard let s = stats(acc, 0x21) else {
        expect(false, "variable-length report recorded")
        return
    }
    expectEqual(s.firstLength, 4, "first length recorded")
    expectEqual(s.minLength, 4, "shortest length recorded")
    expectEqual(s.maxLength, 6, "longest length recorded")
    expect(s.lengthVaried, "length variation is flagged")
    expectEqual(s.byteValues.count, 6, "byte statistics cover the longest sample")
    expectEqual(varying(s), [2], "only byte 2 varies among always-present bytes")
    expectEqual(constant(s), [0, 1, 3], "always-present unchanging bytes are constant")
    expectEqual(constantValues(s), [0x21, 0x01, 0x03], "constant values match the stream")
    // Bytes 4 and 5 were present in only one sample: their values are recorded
    // but they are neither constant nor varying.
    expectEqual(optional(s), [4, 5], "bytes beyond the shortest sample are optional")
    expectEqual(s.byteValues[4].max, 0xAA, "optional byte 4 value retained")
    expectEqual(s.byteValues[5].max, 0xBB, "optional byte 5 value retained")
    expectWellFormedPartition(s, "variable-length report")

    // The reverse order (long first, then short) must reach the same conclusion.
    let acc2 = DiscoveryAccumulator()
    acc2.start()
    feed(acc2, 0x21, [0x21, 0x01, 0x09, 0x03, 0xAA, 0xBB])
    feed(acc2, 0x21, [0x21, 0x01, 0x02, 0x03])
    guard let s2 = stats(acc2, 0x21) else {
        expect(false, "reverse-order report recorded")
        return
    }
    expectEqual(s2.minLength, 4, "shortest length recorded regardless of order")
    expectEqual(s2.maxLength, 6, "longest length recorded regardless of order")
    expectEqual(s2.firstLength, 6, "first length is the first one actually seen")
    expect(s2.lengthVaried, "length variation flagged regardless of order")
}

// MARK: - Multiple streams

/// Interleaved report IDs must be kept apart. The old delta-capture path
/// conflated them; the accumulator keys everything by report ID.
private func testStreamsStaySeparate() {
    let acc = DiscoveryAccumulator()
    acc.start()
    for i in 0..<50 {
        feed(acc, 0x10, [0x10, UInt8(i % 7), 0x00])
        if i % 5 == 0 { feed(acc, 0x11, [0x11, 0xFF, 0xFF, 0xFF]) }
    }
    expectEqual(acc.sampleCount, 60, "every report is counted once")
    expectEqual(stats(acc, 0x10)?.sampleCount, 50, "pen stream count")
    expectEqual(stats(acc, 0x11)?.sampleCount, 10, "aux stream count")
    expectEqual(stats(acc, 0x10)?.maxLength, 3, "pen stream length")
    expectEqual(stats(acc, 0x11)?.maxLength, 4, "aux stream length")
    expectEqual(varying(stats(acc, 0x10)!), [1], "pen stream varying byte")
    expectEqual(varying(stats(acc, 0x11)!), [], "aux stream never changed")
}

// MARK: - Tool codes

private func testToolCodes() {
    let acc = DiscoveryAccumulator()
    acc.start()
    acc.noteToolCode(0x0802)
    acc.noteToolCode(0x080A)
    acc.noteToolCode(0x0802)
    expectEqual(acc.snapshot().toolCodes, [0x0802, 0x080A], "tool codes deduplicated")
}

// MARK: - Discriminated byte stats

/// The scenario this exists for: a GD-0608-U (Intuos 6×8) capture where
/// report 0x02 carries both ordinary pen packets and tool-change packets
/// (status byte, byte 1, in the 0xC0-masked range) at the same report ID and
/// length. Folded into one histogram, byte 2 (X high byte) looked like it
/// swept a range wide enough to span the tool-ID space — not because the pen
/// moved there, but because a handful of tool-change samples carrying serial/
/// type bytes at that position got mixed in with thousands of real position
/// samples. See Notes/Wacom-HID-GD‑0608‑U-Reference.md.
private func testDiscriminatorSeparatesPacketShapes() {
    let acc = DiscoveryAccumulator()
    acc.start()

    // 20 ordinary pen samples: status byte 0xA0 (in proximity), X high byte
    // (index 2) clustered tightly around 40.
    for i in 0..<20 {
        feed(acc, 0x02, [0x02, 0xA0, UInt8(38 + (i % 5)), 0x00, 0x1E, 0x00, 0x00, 0x00, 0x00, 0x00])
    }
    // 2 tool-change samples: status byte 0xC2, with a tool-ID value at byte 2
    // far outside the pen's real X range.
    feed(acc, 0x02, [0x02, 0xC2, 0x82, 0x29, 0x98, 0x00, 0x5E, 0x58, 0x00, 0xC0])
    feed(acc, 0x02, [0x02, 0xC2, 0x88, 0x2A, 0x98, 0x00, 0x5E, 0x58, 0x00, 0xC0])

    guard let s = stats(acc, 0x02) else {
        expect(false, "mixed-packet-shape report recorded")
        return
    }

    // The un-split view: exactly the bug. Byte 2's max is dragged up to 0x88
    // by two tool-change samples, even though the pen itself never went
    // above 42 in this capture.
    expectEqual(s.byteValues[2].max, 0x88, "un-split byte 2 max is dragged up by tool-change samples")

    // The discriminator buckets separate them cleanly.
    expectEqual(s.byDiscriminator.count, 2, "two distinct byte-1 values bucket separately")
    guard let penBucket = s.byDiscriminator[0xA0], let toolBucket = s.byDiscriminator[0xC2] else {
        expect(false, "both discriminator buckets present")
        return
    }
    expectEqual(s.discriminatorSampleCounts[0xA0], 20, "pen bucket sample count")
    expectEqual(s.discriminatorSampleCounts[0xC2], 2, "tool-change bucket sample count")
    expectEqual(penBucket[2].max, 42, "pen bucket's byte 2 max reflects only real pen samples")
    expectEqual(penBucket[2].min, 38, "pen bucket's byte 2 min reflects only real pen samples")
    expectEqual(toolBucket[2].min, 0x82, "tool-change bucket's byte 2 isolated from the pen samples")
    expectEqual(toolBucket[2].max, 0x88, "tool-change bucket's byte 2 isolated from the pen samples")
}

/// A report whose byte 1 never varies (the common case — most reports have a
/// single packet shape) must produce exactly one bucket, matching the whole
/// report's sample count. `CaptureEngine.discriminatedStats` is expected to
/// treat this as "nothing to split" and omit the field entirely, but that
/// gating lives in CaptureEngine.swift (which links against AppKit/IOKit and
/// isn't part of this standalone harness) — this only confirms the
/// accumulator side hands it a single, complete bucket to make that call from.
private func testDiscriminatorSingleBucketWhenByteOneConstant() {
    let acc = DiscoveryAccumulator()
    acc.start()
    for i in 0..<10 {
        feed(acc, 0x10, [0x10, 0x80, UInt8(i)])
    }
    guard let s = stats(acc, 0x10) else {
        expect(false, "constant-byte-1 report recorded")
        return
    }
    expectEqual(s.byDiscriminator.count, 1, "one discriminator bucket when byte 1 never varies")
    expectEqual(s.discriminatorSampleCounts[0x80], 10, "the single bucket covers every sample")
}

/// A report too short to have a byte 1 must not crash or fabricate a bucket.
private func testDiscriminatorSkippedForShortReports() {
    let acc = DiscoveryAccumulator()
    acc.start()
    feed(acc, 0x05, [0x05])
    guard let s = stats(acc, 0x05) else {
        expect(false, "one-byte report recorded")
        return
    }
    expect(s.byDiscriminator.isEmpty, "no discriminator bucket for a report with no byte 1")
}

// MARK: - Degenerate input

private func testEmptyReportIgnored() {
    let acc = DiscoveryAccumulator()
    acc.start()
    let empty: [UInt8] = [0]
    empty.withUnsafeBufferPointer { buf in
        acc.record(reportID: 0x10, pointer: buf.baseAddress!, length: 0)
    }
    expectEqual(acc.sampleCount, 0, "zero-length reports are ignored")
    expect(acc.snapshot().reports.isEmpty, "zero-length reports create no stats")
}

// MARK: - Runner

@main
enum DiscoveryAccumulatorTestRunner {
    static func main() {
        testByteValueSet()
        testGating()
        testCTH690ConstantReport()
        testPressureCeilingSurvives()
        testVariableLength()
        testStreamsStaySeparate()
        testToolCodes()
        testEmptyReportIgnored()
        testDiscriminatorSeparatesPacketShapes()
        testDiscriminatorSingleBucketWhenByteOneConstant()
        testDiscriminatorSkippedForShortReports()

        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("\(failures) of \(checks) checks failed\n".utf8))
            exit(1)
        }
    }
}
