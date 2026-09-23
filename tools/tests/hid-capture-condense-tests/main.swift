// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

// HIDCaptureCondenseTests.swift — Standalone checks for HIDCapture.Condenser,
// the run-collapse/transition-preservation logic behind the "Record Raw Data…"
// capture tool.
//
// The app has no XCTest target, so this runs as a small executable compiled
// against the real HIDCapture.swift. Run via
// tools/tests/hid-capture-condense-tests/run.sh. Exits non-zero on the first
// failure.

import Foundation
import TabletKit

private var failures = 0
private var checks = 0

private func expect(
    _ condition: Bool,
    _ message: @autoclosure () -> String,
    file: StaticString = #file,
    line: UInt = #line
) {
    checks += 1
    guard !condition else { return }
    failures += 1
    FileHandle.standardError.write(
        Data("FAIL (\(file):\(line)): \(message())\n".utf8)
    )
}

// MARK: - Sample builders

private func penPoint(
    x: Int, y: Int, pressure: Int = 0, inProximity: Bool = true, eraser: Bool = false,
    penButton1: Bool = false, rotation: Double = 0, hoverDistance: Int = 0
) -> TabletPoint {
    var point = TabletPoint(
        x: x, y: y, maxX: 15200, maxY: 9500, pressure: pressure, maxPressure: 4095,
        tiltX: 0, tiltY: 0, penButton1: penButton1, penButton2: false, eraser: eraser,
        inProximity: inProximity, hoverDistance: hoverDistance)
    point.rotation = rotation
    return point
}

private func sample(
    at elapsed: TimeInterval, id: UInt8 = 0x1F, x: Int, y: Int, pressure: Int = 0,
    inProximity: Bool = true, eraser: Bool = false, penButton1: Bool = false,
    rotation: Double = 0, hoverDistance: Int = 0,
    decoded: [DecodeResult]? = nil
) -> HIDCapture.Sample {
    let results = decoded ?? [.pen(penPoint(x: x, y: y, pressure: pressure, inProximity: inProximity, eraser: eraser, penButton1: penButton1, rotation: rotation, hoverDistance: hoverDistance))]
    return HIDCapture.Sample(
        elapsed: elapsed, tag: "Test Device", reportID: id, length: 18,
        hex: "1F 01 00 \(x) 00 \(y)", decoded: results,
        signature: HIDCapture.signature(for: results))
}

/// Matches the old one-shot `HIDCapture.condense(_:)` this file's tests were
/// originally written against: feed everything in one batch, then close out
/// whatever run is still open. Most tests don't care about flush boundaries,
/// so this keeps them simple; the flush-continuity tests below call
/// `feed`/`finish` directly across multiple batches instead.
private func condenseAll(_ samples: [HIDCapture.Sample]) -> [String] {
    var condenser = HIDCapture.Condenser()
    var lines = condenser.feed(samples)
    lines.append(contentsOf: condenser.finish())
    return lines
}

// MARK: - Tests

// A run of steady-state samples (same proximity/button/eraser state, only
// position/pressure moving) collapses to one line, not one per sample.
do {
    let samples = (0..<50).map { i in
        sample(at: TimeInterval(i) * 0.01, x: 1000 + i * 10, y: 2000 + i * 5)
    }
    let lines = condenseAll(samples)
    expect(lines.count == 1, "expected steady-state run of 50 to collapse to 1 line, got \(lines.count)")
    expect(lines.first?.contains("×50") == true, "collapsed line should report the run count: \(lines.first ?? "")")
    expect(lines.first?.contains("x:1000-1490") == true, "collapsed line should carry the observed X range: \(lines.first ?? "")")
}

// A proximity transition (pen lifts) must break the run and appear verbatim,
// not get folded into either the run before or after it.
do {
    var samples = (0..<10).map { i in sample(at: TimeInterval(i) * 0.01, x: 1000, y: 2000, inProximity: true) }
    samples.append(sample(at: 0.11, x: 1000, y: 2000, inProximity: false))
    samples.append(contentsOf: (0..<10).map { i in sample(at: 0.12 + TimeInterval(i) * 0.01, x: 1000, y: 2000, inProximity: true) })
    let lines = condenseAll(samples)
    // Both the exit (true→false) and the re-entry (false→true) are
    // transitions in their own right: run, exit-line, enter-line, run.
    expect(lines.count == 4, "expected run, exit, enter, run (4 lines), got \(lines.count): \(lines)")
    if lines.count == 4 {
        expect(lines[0].contains("×10"), "first run should show ×10: \(lines[0])")
        expect(!lines[1].contains("×"), "proximity-exit transition line must be verbatim (no × count): \(lines[1])")
        expect(!lines[2].contains("×"), "proximity-enter transition line must be verbatim (no × count): \(lines[2])")
        expect(lines[3].contains("×9"), "second run should show ×9 (one sample consumed by the enter transition): \(lines[3])")
    }
}

// A button-down edge must break the run even though position is unchanged.
do {
    var samples = (0..<5).map { i in sample(at: TimeInterval(i) * 0.01, x: 1000, y: 2000, penButton1: false) }
    samples.append(sample(at: 0.06, x: 1000, y: 2000, penButton1: true))
    samples.append(contentsOf: (0..<5).map { i in sample(at: 0.07 + TimeInterval(i) * 0.01, x: 1000, y: 2000, penButton1: true) })
    let lines = condenseAll(samples)
    expect(lines.count == 3, "expected run, button-down transition, run (3 lines), got \(lines.count): \(lines)")
}

// A one-shot event (toolEnter) is always a transition, even if the pen
// signature fields didn't change from the previous sample.
do {
    var samples = [sample(at: 0.0, x: 1000, y: 2000)]
    samples.append(
        HIDCapture.Sample(
            elapsed: 0.01, tag: "Test Device", reportID: 0x1F, length: 18, hex: "1F 01",
            decoded: [.toolEnter(ToolIdentity(serial: 12345, toolCode: 0x0842, isEraser: false, isMouse: false))],
            signature: HIDCapture.signature(for: [
                .toolEnter(ToolIdentity(serial: 12345, toolCode: 0x0842, isEraser: false, isMouse: false))
            ])))
    samples.append(sample(at: 0.02, x: 1000, y: 2000))
    let lines = condenseAll(samples)
    expect(lines.count == 3, "toolEnter must force a standalone verbatim line, got \(lines.count): \(lines)")
}

// Interleaved report IDs (e.g. a pen stream and a periodic status report)
// must not reset each other's run just because delivery order alternates.
do {
    var samples: [HIDCapture.Sample] = []
    for i in 0..<20 {
        samples.append(sample(at: TimeInterval(i) * 0.01, id: 0x1F, x: 1000 + i, y: 2000))
        if i % 5 == 0 {
            samples.append(
                HIDCapture.Sample(
                    elapsed: TimeInterval(i) * 0.01 + 0.001, tag: "Test Device", reportID: 0x13, length: 9,
                    hex: "13 50 00", decoded: [.battery(percent: 80, charging: false)],
                    signature: HIDCapture.signature(for: [.battery(percent: 80, charging: false)])))
        }
    }
    let lines = condenseAll(samples)
    let penLines = lines.filter { $0.contains("ID=1F") }
    expect(penLines.count == 1, "interleaved 0x13 status reports must not fragment the 0x1F run, got \(penLines.count) pen lines: \(penLines)")
}

// Undecoded reports (decoded == nil) never collapse into "the same steady
// state" as each other — no meaning is assumed for their bytes, so every one
// stays a distinct single-sample run rather than silently merging.
do {
    let samples = (0..<5).map { i in
        HIDCapture.Sample(
            elapsed: TimeInterval(i) * 0.01, tag: "Test Device", reportID: 0x37, length: 10,
            hex: "37 00 00", decoded: nil, signature: HIDCapture.signature(for: nil))
    }
    let lines = condenseAll(samples)
    expect(lines.count == 5, "undecoded reports must not be collapsed together, got \(lines.count) lines for 5 samples")
}

// Two different tags reporting the same report ID (a device with more than
// one registered HID interface — see WacomKnownDevice's captureTag) must
// get independent runs, not merge into one just because the report ID
// matches. This is the interleaved-interface case: real, simultaneous,
// unrelated traffic, not a duplicate.
do {
    var samples: [HIDCapture.Sample] = []
    for i in 0..<10 {
        samples.append(sample(at: TimeInterval(i) * 0.01, id: 0x02, x: 1000 + i, y: 2000))
        samples.append(
            HIDCapture.Sample(
                elapsed: TimeInterval(i) * 0.01 + 0.001, tag: "Test Device [iface2]", reportID: 0x02,
                length: 8, hex: "02 FF FF FF", decoded: nil, signature: HIDCapture.signature(for: nil)))
    }
    let lines = condenseAll(samples)
    let secondaryLines = lines.filter { $0.contains("[iface2]") }
    expect(!secondaryLines.isEmpty, "second interface's traffic must appear in the output at all: \(lines)")
    expect(
        lines.contains(where: { $0.contains("×10") && !$0.contains("[iface2]") }),
        "primary interface's 0x02 stream should still collapse to one run despite interleaving with iface2: \(lines)")
}

// Output must be in chronological order overall, not grouped by
// (tag, reportID) emission/flush order.
do {
    let samples: [HIDCapture.Sample] = [
        HIDCapture.Sample(
            elapsed: 0.0, tag: "A", reportID: 0x01, length: 4, hex: "01 00",
            decoded: [.battery(percent: 10, charging: false)],
            signature: HIDCapture.signature(for: [.battery(percent: 10, charging: false)])),
        HIDCapture.Sample(
            elapsed: 0.5, tag: "B", reportID: 0x01, length: 4, hex: "01 00",
            decoded: [.battery(percent: 20, charging: false)],
            signature: HIDCapture.signature(for: [.battery(percent: 20, charging: false)])),
        HIDCapture.Sample(
            elapsed: 0.2, tag: "A", reportID: 0x02, length: 4, hex: "02 00",
            decoded: [.battery(percent: 30, charging: false)],
            signature: HIDCapture.signature(for: [.battery(percent: 30, charging: false)])),
    ]
    let lines = condenseAll(samples)
    // Extract each line's leading [mm:ss.ms] and confirm non-decreasing order.
    let timestamps = lines.compactMap { line -> String? in
        guard line.hasPrefix("["), let end = line.firstIndex(of: "]") else { return nil }
        return String(line[line.index(after: line.startIndex)..<end])
    }
    expect(timestamps == timestamps.sorted(), "condensed output must be in chronological order, got: \(timestamps)")
}

// Two identical reports (same tag, same reportID, same elapsed, same hex)
// must collapse to one line — the double-dispatch/relay case seen on a real
// Xencelabs dongle capture, not two distinct events.
do {
    let a = HIDCapture.Sample(
        elapsed: 1.0, tag: "Test Device", reportID: 0x02, length: 4, hex: "02 AA BB CC",
        decoded: [.toolEnter(ToolIdentity(serial: 1, toolCode: 0x0842, isEraser: false, isMouse: false)), .pen(penPoint(x: 100, y: 200))],
        signature: HIDCapture.signature(for: [.toolEnter(ToolIdentity(serial: 1, toolCode: 0x0842, isEraser: false, isMouse: false))]))
    let b = HIDCapture.Sample(
        elapsed: 1.0, tag: "Test Device", reportID: 0x02, length: 4, hex: "02 AA BB CC",
        decoded: [.pen(penPoint(x: 100, y: 200))],
        signature: HIDCapture.signature(for: [.pen(penPoint(x: 100, y: 200))]))
    let lines = condenseAll([a, b])
    expect(lines.count == 1, "identical same-instant reports must collapse to 1 line, got \(lines.count): \(lines)")
    expect(lines.first?.contains("toolEnter") == true, "the surviving line should keep the richer (toolEnter) annotation from the first copy: \(lines.first ?? "")")
}

// A run spanning a flush boundary (two separate `feed(_:)` batches) must
// still read as one collapsed line, not be cut into two by the boundary —
// this is the core guarantee that makes periodic disk flushing safe to add
// without changing what a steady sweep looks like in the saved file.
do {
    var condenser = HIDCapture.Condenser()
    let batch1 = (0..<20).map { i in sample(at: TimeInterval(i) * 0.01, x: 1000 + i, y: 2000) }
    let batch2 = (20..<40).map { i in sample(at: TimeInterval(i) * 0.01, x: 1000 + i, y: 2000) }

    let out1 = condenser.feed(batch1)
    expect(out1.isEmpty, "a run still open at the end of a batch must not be emitted yet, got \(out1)")

    let out2 = condenser.feed(batch2)
    expect(out2.isEmpty, "the run continues through batch 2 uninterrupted (no transition), so still nothing should flush: \(out2)")

    let final = condenser.finish()
    expect(final.count == 1, "the whole 40-sample run should close as exactly one line at finish(), got \(final.count): \(final)")
    expect(final.first?.contains("×40") == true, "finish()'s line should report the full run count across both batches: \(final.first ?? "")")
}

// A transition arriving in a later batch must still close out a run that
// was left open from an earlier batch — the carried-forward run must be
// visible to the next feed(_:) call, not reset.
do {
    var condenser = HIDCapture.Condenser()
    let batch1 = (0..<10).map { i in sample(at: TimeInterval(i) * 0.01, x: 1000, y: 2000, inProximity: true) }
    let batch2 = [sample(at: 0.11, x: 1000, y: 2000, inProximity: false)]

    let out1 = condenser.feed(batch1)
    expect(out1.isEmpty, "run open at end of batch 1, nothing to emit yet: \(out1)")

    let out2 = condenser.feed(batch2)
    expect(out2.count == 2, "batch 2's proximity-exit transition should close batch 1's run AND emit itself verbatim: \(out2)")
    if out2.count == 2 {
        expect(out2[0].contains("×10"), "the closed run from batch 1 should show all 10 samples: \(out2[0])")
        expect(!out2[1].contains("×"), "the transition itself stays verbatim: \(out2[1])")
    }
}

// A single implausible jump inside an otherwise steady run must surface as
// its own verbatim line, not get silently absorbed into the run's x/y
// range — a min/max range across thousands of samples can hide exactly the
// kind of discontinuity (sign flip, coordinate wraparound, decoder bug)
// this tool exists to catch. Motion here is steady ~10 units/sample; one
// sample jumps 5000 units, an order of magnitude past anything the run has
// established as normal.
do {
    var samples = (0..<20).map { i in sample(at: TimeInterval(i) * 0.01, x: 1000 + i * 10, y: 2000) }
    samples.append(sample(at: 0.21, x: 6200, y: 2000))  // the outlier: +5000 from the last sample
    samples.append(contentsOf: (0..<20).map { i in sample(at: 0.22 + TimeInterval(i) * 0.01, x: 6200 + i * 10, y: 2000) })
    let lines = condenseAll(samples)
    expect(lines.count == 3, "expected run, outlier, run (3 lines), got \(lines.count): \(lines)")
    if lines.count == 3 {
        expect(lines[0].contains("×20"), "first run (before the jump) should show ×20: \(lines[0])")
        expect(!lines[1].contains("×"), "the outlier sample itself must be verbatim, not folded into a range: \(lines[1])")
        expect(lines[1].contains("x=6200"), "the outlier line should show the actual jumped-to value: \(lines[1])")
        expect(lines[2].contains("×20"), "second run (after the jump, motion resumes at the new position) should show ×20: \(lines[2])")
    }
}

// Ordinary pen motion — even fast strokes with naturally varying step
// sizes — must NOT trip the outlier detector. Only a jump an order of
// magnitude past the run's own established range should break it; normal
// speed variance (a flick after a slow stroke) is expected pen behavior,
// not a decoder bug.
do {
    // Steps ranging 5-50 units, well within the 5x-of-max-seen tolerance
    // relative to each other (max ratio here is 10x from smallest to
    // largest step, but each individual step is compared against the
    // *running* max-seen, which grows to absorb legitimate speed changes).
    var x = 1000
    let steps = [10, 12, 15, 20, 18, 14, 11, 25, 30, 22, 16, 13, 19, 21, 17, 24, 28, 15, 12, 10]
    var samples: [HIDCapture.Sample] = []
    for (i, step) in steps.enumerated() {
        x += step
        samples.append(sample(at: TimeInterval(i) * 0.01, x: x, y: 2000))
    }
    let lines = condenseAll(samples)
    expect(lines.count == 1, "gradually-varying normal pen motion must stay one run, got \(lines.count) lines: \(lines)")
}

// The watermark: a run that stays open across MANY feed() calls (not just
// two) must hold back every other stream's newer transition lines until it
// finally closes — this is the second real-capture bug, distinct from the
// grace-window one below. A long, genuinely continuous steady sweep on one
// report ID can outlive many flush intervals while a busier stream (e.g.
// periodic wireless status) keeps producing transition lines throughout;
// releasing those transitions immediately, as the pre-watermark design did,
// writes them to disk before the slow stream's earlier-starting run closes
// and catches up — confirmed on a real capture where a run starting at
// 00:09 never closed until end-of-session, by which point several newer
// ACK-40401 lines (up to 00:11) had already been flushed ahead of it.
do {
    var condenser = HIDCapture.Condenser()

    // Stream B's run opens at t=0 and never transitions — genuinely
    // continuous across every feed() call below.
    var allOut: [String] = []
    for batchStart in stride(from: 0, to: 100, by: 10) {
        var batch = (batchStart..<(batchStart + 10)).map { i in
            sample(at: TimeInterval(i) * 0.1, id: 0x02, x: 1000 + i, y: 2000)
        }
        // Stream A fires one transition (battery report) partway through
        // each batch, always newer than stream B's run start (0.0).
        batch.append(
            HIDCapture.Sample(
                elapsed: TimeInterval(batchStart) * 0.1 + 0.05, tag: "StreamA", reportID: 0x13,
                length: 4, hex: "13 00",
                decoded: [.battery(percent: batchStart, charging: false)],
                signature: HIDCapture.signature(for: [.battery(percent: batchStart, charging: false)])))
        batch.sort { $0.elapsed < $1.elapsed }
        allOut.append(contentsOf: condenser.feed(batch))
    }

    expect(
        allOut.isEmpty,
        "every StreamA transition arrived after StreamB's still-open run started, so none should release before the run closes or finish() is called — got \(allOut.count) early: \(allOut)")

    let final = condenser.finish()
    let batteryLines = final.filter { $0.contains("ID=13") }
    expect(batteryLines.count == 10, "all 10 held-back StreamA transitions should release at finish(), got \(batteryLines.count)")
    let timestamps = final.compactMap { line -> String? in
        guard line.hasPrefix("["), let end = line.firstIndex(of: "]") else { return nil }
        return String(line[line.index(after: line.startIndex)..<end])
    }
    expect(timestamps == timestamps.sorted(), "finish()'s combined output (closed run + all held-back transitions) must be in chronological order, got: \(timestamps)")
}

// splitByGraceWindow: the exact real-capture bug this exists to prevent — a
// quiet stream's old samples must classify as "old" (flushable) even when
// the buffer also holds a much newer, high-volume stream's samples. Without
// this split, a naive "flush everything buffered" would write the quiet
// stream's decade-old-by-comparison samples in whatever position they
// happened to occupy in the array, landing chronologically out of order
// relative to already-flushed batches of the busy stream.
do {
    // Stream A (busy): samples every 0.5s from 0.0 to 44.5s (90 samples).
    let streamA = stride(from: 0.0, through: 44.5, by: 0.5).map { t in
        HIDCapture.Sample(
            elapsed: t, tag: "StreamA", reportID: 0x80, length: 4, hex: "80 00",
            decoded: nil, signature: HIDCapture.signature(for: nil))
    }
    // Stream B (quiet): one sample at 10.6s, then silent until the buffer
    // is flushed — this is the ×16848 Xencelabs run from the real capture,
    // reduced to its essential shape: old by elapsed, but present in the
    // same buffer as much newer stream-A samples at flush time.
    let streamB = [
        HIDCapture.Sample(
            elapsed: 10.6, tag: "StreamB", reportID: 0x02, length: 4, hex: "02 00",
            decoded: nil, signature: HIDCapture.signature(for: nil))
    ]
    let buffer = streamA + streamB  // interleaved arrival order, as record() would see it

    let split = HIDCapture.splitByGraceWindow(buffer, graceWindow: HIDCapture.graceWindow)
    expect(
        split.old.contains(where: { $0.tag == "StreamB" }),
        "stream B's old (10.6s) sample must be classified as flushable, not held back as 'recent', given the buffer's newest sample is 44.5s: \(split.old.map(\.tag))")
    expect(
        split.recent.contains(where: { $0.tag == "StreamA" && $0.elapsed > 44.5 - HIDCapture.graceWindow }),
        "stream A's newest samples (within graceWindow of the buffer's max) must stay held back, not flushed yet")
    expect(
        !split.old.contains(where: { $0.tag == "StreamA" && $0.elapsed > 44.5 - HIDCapture.graceWindow }),
        "no sample within graceWindow of the buffer's newest should be in 'old'")
}

// MARK: - Barrel rotation in condensed runs

// A condensed run used to drop rotation entirely, so a capture could show
// thousands of absorbed frames with no way to tell whether the Art Pen's one
// distinguishing axis was live. Pins both halves: present when it varies,
// absent when it never does.
do {
    let samples = (0..<8).map {
        sample(at: 1.0 + Double($0) * 0.01, x: 500 + $0, y: 600, rotation: 90.0 + Double($0))
    }
    let lines = condenseAll(samples)
    let run = lines.first { $0.contains("steady-state") }
    expect(run != nil, "eight same-signature samples should collapse into one run line")
    expect(
        run?.contains("rot:90.0-97.0") == true,
        "a condensed run must report the rotation range it absorbed, else an Art Pen capture hides its main axis: \(run ?? "<none>")")
}

do {
    // Every TabletPoint carries rotation (default 0), so a pen with no barrel
    // sensor would otherwise add a meaningless "rot:0.0-0.0" to every run.
    let samples = (0..<8).map {
        sample(at: 2.0 + Double($0) * 0.01, x: 700 + $0, y: 800)
    }
    let lines = condenseAll(samples)
    let run = lines.first { $0.contains("steady-state") }
    expect(run != nil, "eight same-signature samples should collapse into one run line")
    expect(
        run?.contains("rot:") == false,
        "an all-zero rotation run must omit the field entirely, so its presence means the sensor was live: \(run ?? "<none>")")
}

do {
    // Rotation on only some frames of a run: the range must still surface it
    // rather than dropping it for reading zero part of the time.
    let samples = (0..<8).map { i in
        sample(at: 3.0 + Double(i) * 0.01, x: 900 + i, y: 1000, rotation: i == 4 ? -252.0 : 0)
    }
    let lines = condenseAll(samples)
    let run = lines.first { $0.contains("steady-state") }
    expect(
        run?.contains("rot:-252.0-0.0") == true,
        "a run where only some frames carried rotation must still report it: \(run ?? "<none>")")
}

// MARK: - Rotation correlated with hover height

// The question `rotationRange` cannot answer: a run rendering
// `hover:20-122 rot:0-358` fits both rotation tracking the full height and
// rotation dying just off the surface. These pin the tally separating them.
do {
    // Rotation live near the surface, absent high up — the cutoff shape.
    let low = (0..<4).map { i in
        sample(at: 4.0 + Double(i) * 0.01, x: 500 + i, y: 600, rotation: 90.0 + Double(i), hoverDistance: 25)
    }
    let high = (0..<4).map { i in
        sample(at: 4.1 + Double(i) * 0.01, x: 510 + i, y: 600, rotation: 0, hoverDistance: 105)
    }
    let run = condenseAll(low + high).first { $0.contains("steady-state") }
    expect(
        run?.contains("20-39:4/4") == true,
        "every low-hover frame carried rotation, so its bucket must read 4/4: \(run ?? "<none>")")
    expect(
        run?.contains("100-119:0/4") == true,
        "no high-hover frame carried rotation, so its bucket must read 0/4 — this is the shape that would confirm a height cutoff: \(run ?? "<none>")")
}

do {
    // The opposite shape: rotation live at every height. Telling this from
    // the run above is the entire point of the field.
    let samples = (0..<6).map { i in
        sample(at: 5.0 + Double(i) * 0.01, x: 700 + i, y: 800, rotation: 45.0 + Double(i), hoverDistance: 25 + i * 20)
    }
    let run = condenseAll(samples).first { $0.contains("steady-state") }
    expect(
        run?.contains("20-39:1/1") == true && run?.contains("120-139:1/1") == true,
        "rotation present at both the lowest and highest bucket must show 1/1 at each, not a cutoff: \(run ?? "<none>")")
}

do {
    // A pen with no barrel sensor must not gain a rot@hover block, for the
    // same reason it gains no rot: range — presence has to mean something.
    let samples = (0..<6).map { i in
        sample(at: 6.0 + Double(i) * 0.01, x: 900 + i, y: 1000, hoverDistance: 30 + i)
    }
    let run = condenseAll(samples).first { $0.contains("steady-state") }
    expect(
        run?.contains("rot@hover") == false,
        "a run with no rotation at all must omit the bucket tally entirely: \(run ?? "<none>")")
}

if failures > 0 {
    FileHandle.standardError.write(Data("hid-capture-condense-tests: \(failures)/\(checks) checks FAILED\n".utf8))
    exit(1)
} else {
    print("ok — \(checks) checks passed")
}
