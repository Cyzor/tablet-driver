// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// main.swift — Checks for Drag Threshold's touchdown guard (issue #26: taps
// turning into drags). Run via tools/tests/touchdown-guard-tests/run.sh.

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

private let guardOn = TouchdownGuard(radius: 5)

// Within both limits: held.
expect(guardOn.holds(elapsed: 0, travel: 0), "a contact's first sample is held")
expect(guardOn.holds(elapsed: 0.1, travel: 4), "a small wobble during a tap is held")
expect(guardOn.holds(elapsed: 0.149, travel: 5), "travel exactly at the radius is held")

// Past the radius: lets go at once.
expect(!guardOn.holds(elapsed: 0.01, travel: 5.1), "travel past the radius lets the drag go")

// Past the hold time: lets go however little the pen moved.
expect(!guardOn.holds(elapsed: 0.150, travel: 0), "at exactly 150 ms a still pen lets go")
expect(!guardOn.holds(elapsed: 0.3, travel: 1), "a slow start isn't pinned after the hold time")
expect(!guardOn.holds(elapsed: 2, travel: 0), "a long press isn't pinned")
expect(TouchdownGuard.defaultRadius == 5, "Drag Threshold defaults to 5 pt")

// Off.
expect(!TouchdownGuard(radius: 0).holds(elapsed: 0, travel: 0), "radius 0 never holds")
expect(!TouchdownGuard(radius: -1).holds(elapsed: 0, travel: 0), "a negative radius never holds")

if failures == 0 {
    print("touchdown-guard-tests: \(checks) checks passed")
    exit(0)
}
FileHandle.standardError.write(Data("touchdown-guard-tests: \(failures) of \(checks) checks failed\n".utf8))
exit(1)
