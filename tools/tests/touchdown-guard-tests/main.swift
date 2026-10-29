// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// main.swift — Checks for the touchdown click guard (issue #26: taps turning
// into drags). Run via tools/tests/touchdown-guard-tests/run.sh.

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

private let guardOn = TouchdownGuard(radiusMM: 0.7)

// Settling: 2.5× the radius (1.75 mm) for the first 150 ms.
expect(guardOn.holds(elapsed: 0.05, travelMM: 1.5), "a wobble within 1.75 mm just after contact is held")
expect(guardOn.holds(elapsed: 0.05, travelMM: 1.75), "travel exactly at the settling radius is held")
expect(!guardOn.holds(elapsed: 0.05, travelMM: 1.8), "travel past the settling radius lets the drag go")

// Settled: the radius itself.
expect(guardOn.holds(elapsed: 0.5, travelMM: 0.6), "a small wobble later is held")
expect(guardOn.holds(elapsed: 0.5, travelMM: 0.7), "travel exactly at the radius is held")
expect(!guardOn.holds(elapsed: 0.5, travelMM: 1.0), "travel past the settled radius lets the drag go")
expect(!guardOn.holds(elapsed: 0.150, travelMM: 1.0), "at exactly 150 ms the settled radius applies")
expect(guardOn.holds(elapsed: 0.149, travelMM: 1.0), "just before 150 ms the settling radius applies")

// Off.
let guardOff = TouchdownGuard(radiusMM: 0)
expect(!guardOff.holds(elapsed: 0, travelMM: 0), "radius 0 never holds")
expect(!TouchdownGuard(radiusMM: -1).holds(elapsed: 0, travelMM: 0), "a negative radius never holds")

// Travel on the tablet, from area fractions.
let graphire = (width: 127.0, height: 93.0)  // Graphire 3 (4×5)
let across = TouchdownGuard.travelMM(from: (0.5, 0.5), to: (0.51, 0.5), areaMM: graphire)
expect(abs(across - 1.27) < 1e-9, "1% of a 127 mm area is 1.27 mm, got \(across)")
let diagonal = TouchdownGuard.travelMM(from: (0, 0), to: (3.0 / 127, 4.0 / 93), areaMM: graphire)
expect(abs(diagonal - 5) < 1e-9, "travel combines both axes, got \(diagonal)")
expect(TouchdownGuard.travelMM(from: (0.2, 0.3), to: (0.2, 0.3), areaMM: graphire) == 0, "no travel is 0 mm")

if failures == 0 {
    print("touchdown-guard-tests: \(checks) checks passed")
    exit(0)
}
FileHandle.standardError.write(Data("touchdown-guard-tests: \(failures) of \(checks) checks failed\n".utf8))
exit(1)
