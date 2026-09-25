// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// main.swift — Checks that relative mode is calm at rest and slow speeds and
// still crosses the screen on a quick sweep. Real stationary captures under
// Notes/ are used when present (they stay local); synthetic cases always run.

import Foundation

private var failures = 0
private var checks = 0

private func expect(
    _ condition: Bool, _ message: @autoclosure () -> String,
    file: StaticString = #file, line: UInt = #line
) {
    checks += 1
    guard !condition else { return }
    failures += 1
    FileHandle.standardError.write(Data("FAIL (\(file):\(line)): \(message())\n".utf8))
}

/// Pen positions (mm) and timestamps (s) fed through the ballistics, the way
/// `DisplayMapper` does: rounded output, float position carried.
struct Run {
    var travel = 0.0        // total cursor path, points
    var flickers = 0        // rounded-position changes
    var minX = 0.0, maxX = 0.0, minY = 0.0, maxY = 0.0
}

/// Absolute mode's scale on a large tablet mapped to a laptop display.
let absolutePointsPerMM = 4.8

func drive(_ samples: [(t: Double, x: Double, y: Double)], fixedGain: Double? = nil) -> Run {
    var b = RelativeBallistics()
    var run = Run()
    var px = 0.0, py = 0.0
    var last = (x: 0.0, y: 0.0)
    for (prev, cur) in zip(samples, samples.dropFirst()) {
        let dx = cur.x - prev.x, dy = cur.y - prev.y
        let d: (dx: Double, dy: Double) =
            fixedGain.map { (dx * $0, dy * $0) }
            ?? b.cursorDelta(
                dxMM: dx, dyMM: dy,
                dxPoints: dx * absolutePointsPerMM, dyPoints: dy * absolutePointsPerMM,
                dt: cur.t - prev.t)
        px += d.dx
        py += d.dy
        run.travel += (d.dx * d.dx + d.dy * d.dy).squareRoot()
        let r = (x: px.rounded(), y: py.rounded())
        if r != last { run.flickers += 1; last = r }
        run.minX = min(run.minX, px); run.maxX = max(run.maxX, px)
        run.minY = min(run.minY, py); run.maxY = max(run.maxY, py)
    }
    return run
}

private func gaussian(_ sigma: Double, _ g: inout SystemRandomNumberGenerator) -> Double {
    let u1 = Double.random(in: Double.ulpOfOne..<1, using: &g)
    let u2 = Double.random(in: 0..<1, using: &g)
    return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
}

var rng = SystemRandomNumberGenerator()
let rate = 200.0

// MARK: - Synthetic

// Sensor noise at rest: 15 µm σ, 5 s. Must not move the cursor at all.
let still = (0..<Int(5 * rate)).map { i in
    (t: Double(i) / rate, x: gaussian(0.015, &rng), y: gaussian(0.015, &rng))
}
let stillRun = drive(still)
expect(stillRun.flickers == 0, "sensor noise at rest moves the cursor (\(stillRun.flickers) flickers)")

// Hand tremor: 0.3 mm at 8 Hz plus noise. About what absolute mode shows.
let tremor = (0..<Int(3 * rate)).map { i -> (t: Double, x: Double, y: Double) in
    let t = Double(i) / rate
    return (t, 0.3 * sin(2 * .pi * 8 * t) + gaussian(0.015, &rng), gaussian(0.015, &rng))
}
let tremorRun = drive(tremor)
let tremorSpan = tremorRun.maxX - tremorRun.minX
expect(tremorSpan <= 0.6 * absolutePointsPerMM * 1.2, "tremor wobble \(tremorSpan) pt exceeds absolute mode's")

// A quick full-width sweep, 300 mm in 1 s, still crosses a 1512 pt screen.
let flick = (0...Int(1.0 * rate)).map { i -> (t: Double, x: Double, y: Double) in
    let t = Double(i) / rate
    return (t, 300 * t * t * (3 - 2 * t), 0)
}
let flickRun = drive(flick)
expect(flickRun.maxX >= 1512, "full-width sweep covers only \(Int(flickRun.maxX)) pt")

// Slow, deliberate positioning: 5 mm at 10 mm/s moves a small, steady amount.
let slow = (0...Int(0.5 * rate)).map { i in (t: Double(i) / rate, x: Double(i) / rate * 10, y: 0.0) }
let slowRun = drive(slow)
expect((8...16).contains(slowRun.maxX), "5 mm slow move gives \(slowRun.maxX) pt")

// Leaving rest doesn't jump: first nonzero output is sub-point.
var jb = RelativeBallistics()
var firstMove = 0.0
for i in 1...100 where firstMove == 0 {
    let d = jb.cursorDelta(dxMM: 0.01, dyMM: 0, dxPoints: 0.048, dyPoints: 0, dt: 1 / rate)
    firstMove = d.dx
    _ = i
}
expect(firstMove > 0 && firstMove < 1, "leaving rest jumps \(firstMove) pt")

// Gain curve endpoints.
expect(RelativeBallistics.acceleration(forSpeed: 0) == 1, "slow motion moves as absolute mode does")
expect(RelativeBallistics.acceleration(forSpeed: 1000) == RelativeBallistics.accelFast, "full acceleration")

// Proportions carry through: a squashed mapping's per-axis points pass
// through unchanged at slow speed.
var pb = RelativeBallistics()
_ = pb.cursorDelta(dxMM: 0.2, dyMM: 0.2, dxPoints: 2, dyPoints: 1, dt: 0.005)
let prop = pb.cursorDelta(dxMM: 0.02, dyMM: 0.02, dxPoints: 0.2, dyPoints: 0.1, dt: 0.005)
expect(abs(prop.dx / prop.dy - 2) < 1e-9, "x:y proportion is kept")

// MARK: - Real stationary captures (local only)

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let captureDir = root + "/Notes/Scratch/Device-Diagnostics/Internal-Discovery-Data-Capture/"

private func loadFrames(_ name: String, reportID: String) -> [(Double, [UInt8])] {
    guard let text = try? String(contentsOfFile: captureDir + name, encoding: .utf8) else { return [] }
    var out: [(Double, [UInt8])] = []
    for line in text.split(separator: "\n") where line.contains("[in id=0x\(reportID) ") {
        guard let tStart = line.range(of: "[t="), let tEnd = line.range(of: " dt="),
            let t = Double(line[tStart.upperBound..<tEnd.lowerBound]),
            let bytesStart = line.range(of: "] ", range: line.range(of: "len=")!.upperBound..<line.endIndex)
        else { continue }
        let bytes = line[bytesStart.upperBound...].split(separator: " ").compactMap { UInt8($0, radix: 16) }
        out.append((t / 1000, bytes))
    }
    return out
}

func real(_ name: String, reportID: String, unitsPerMM: Double,
          _ xy: ([UInt8]) -> (Int, Int)?) {
    let samples = loadFrames(name, reportID: reportID).compactMap { f -> (t: Double, x: Double, y: Double)? in
        guard f.1.count >= 10, let p = xy(f.1) else { return nil }
        return (f.0, Double(p.0) / unitsPerMM, Double(p.1) / unitsPerMM)
    }
    guard samples.count > 100 else { return }
    let old = drive(samples, fixedGain: 20)
    let new = drive(samples)
    print("  \(name): flickers \(old.flickers) → \(new.flickers), wobble \(Int(old.maxX - old.minX))×\(Int(old.maxY - old.minY)) → \(Int(new.maxX - new.minX))×\(Int(new.maxY - new.minY)) pt")
    expect(new.flickers <= old.flickers / 4, "\(name): rest flicker not reduced enough")
}

real("850-wireless-dongle-stationary-2026-09-25.txt", reportID: "02", unitsPerMM: 65024 / 325.1) { b in
    let s = b[1]
    guard s & 0xFC != 0xC0, s & 0x20 != 0, s & 0xFE != 0x20 else { return nil }
    return ((Int(b[3]) | Int(b[2]) << 8) << 1, (Int(b[5]) | Int(b[4]) << 8) << 1)
}
real("ptk-870-bt-art-pen-held-still.txt", reportID: "1a", unitsPerMM: 69800 / 311.0) { b in
    guard b[1] & 0x0F != 0x01, b[3] & 0x80 != 0 else { return nil }
    return (Int(b[4]) | Int(b[5]) << 8 | Int(b[6] & 0x0F) << 16,
            Int(b[6] >> 4) | Int(b[7]) << 4 | Int(b[8]) << 12)
}

if failures == 0 {
    print("relative-ballistics-tests: \(checks) checks passed")
    exit(0)
}
FileHandle.standardError.write(Data("relative-ballistics-tests: \(failures) of \(checks) checks failed\n".utf8))
exit(1)
