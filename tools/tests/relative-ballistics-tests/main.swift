// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// main.swift — Replays real stationary captures through relative mode, when
// MOCKTAB_STATIONARY_CAPTURES names some (they stay local). The synthetic
// checks live in MockTabTests/RelativeBallisticsTests.swift.

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

// MARK: - Real stationary captures (optional)

// Set MOCKTAB_STATIONARY_CAPTURES to a colon-separated list of capture logs
// of a pen held still. Without it, these checks are skipped.
let stationaryCaptures = (ProcessInfo.processInfo.environment["MOCKTAB_STATIONARY_CAPTURES"] ?? "")
    .split(separator: ":").map(String.init)

private func loadFrames(_ path: String, reportID: String) -> [(Double, [UInt8])] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
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

func real(_ path: String, reportID: String, unitsPerMM: Double,
          _ xy: ([UInt8]) -> (Int, Int)?) {
    let name = (path as NSString).lastPathComponent
    let samples = loadFrames(path, reportID: reportID).compactMap { f -> (t: Double, x: Double, y: Double)? in
        guard f.1.count >= 10, let p = xy(f.1) else { return nil }
        return (f.0, Double(p.0) / unitsPerMM, Double(p.1) / unitsPerMM)
    }
    guard samples.count > 100 else { return }
    let old = drive(samples, fixedGain: 20)
    let new = drive(samples)
    print("  \(name): flickers \(old.flickers) → \(new.flickers), wobble \(Int(old.maxX - old.minX))×\(Int(old.maxY - old.minY)) → \(Int(new.maxX - new.minX))×\(Int(new.maxY - new.minY)) pt")
    expect(new.flickers <= old.flickers / 4, "\(name): rest flicker not reduced enough")
}

for path in stationaryCaptures {
    // Intuos5 (report 0x02, through the wireless receiver).
    real(path, reportID: "02", unitsPerMM: 65024 / 325.1) { b in
        let s = b[1]
        guard s & 0xFC != 0xC0, s & 0x20 != 0, s & 0xFE != 0x20 else { return nil }
        return ((Int(b[3]) | Int(b[2]) << 8) << 1, (Int(b[5]) | Int(b[4]) << 8) << 1)
    }
    // Intuos Pro gen 3 over Bluetooth (report 0x1A).
    real(path, reportID: "1a", unitsPerMM: 69800 / 311.0) { b in
        guard b[1] & 0x0F != 0x01, b[3] & 0x80 != 0 else { return nil }
        return (Int(b[4]) | Int(b[5]) << 8 | Int(b[6] & 0x0F) << 16,
                Int(b[6] >> 4) | Int(b[7]) << 4 | Int(b[8]) << 12)
    }
}

if stationaryCaptures.isEmpty {
    print("relative-ballistics-tests: no MOCKTAB_STATIONARY_CAPTURES set, skipped")
    exit(0)
}
if failures == 0 {
    print("relative-ballistics-tests: \(checks) checks passed")
    exit(0)
}
FileHandle.standardError.write(Data("relative-ballistics-tests: \(failures) of \(checks) checks failed\n".utf8))
exit(1)
