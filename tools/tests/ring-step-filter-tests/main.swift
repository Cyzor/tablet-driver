// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// main.swift — Checks for telling a finger on a touch ring from a resting
// hand. Run via tools/tests/ring-step-filter-tests/run.sh.

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

/// Ring positions through the filter the way the injector feeds it, with
/// 72 positions and wraparound; returns the steps it applied.
private func applied(_ positions: [Int]) -> [Int] {
    var filter = RingStepFilter()
    var accepted: Int?
    var steps: [Int] = []
    for p in positions {
        guard let from = accepted else { accepted = p; continue }
        var delta = p - from
        if delta > 36 { delta -= 72 }
        if delta < -36 { delta += 72 }
        if filter.accepts(delta) {
            if delta != 0 { steps.append(delta) }
            accepted = p
        }
    }
    return steps
}

// A turn passes through untouched.
expect(applied([10, 11, 12, 14, 15]) == [1, 1, 2, 1], "a steady turn")
expect(applied([70, 71, 0, 1]) == [1, 1, 1], "a turn across the wrap")

// A reversal waits one report, then applies the whole distance.
let reversal = applied([10, 12, 14, 13, 11, 9])
expect(reversal == [2, 2, -3, -2], "a real reversal loses nothing, got \(reversal)")
expect(reversal.reduce(0, +) == -1, "the turn ends where the finger did")

// A resting hand: the position flips between two spots.
let flicker = applied([33, 37, 33, 37, 33, 37, 33, 37, 33, 37])
expect(flicker == [4], "a two-spot flicker scrolls once, got \(flicker)")
let small = applied([16, 17, 16, 17, 16, 17, 16, 17])
expect(small == [1], "a one-step flicker scrolls once, got \(small)")

// Returning to the accepted spot clears a pending reversal.
let bounce = applied([20, 22, 21, 22, 23])
expect(bounce == [2, 1], "a dip that comes back holds, got \(bounce)")

// Lifting forgets the direction.
var filter = RingStepFilter()
expect(filter.accepts(3), "a first step counts")
expect(!filter.accepts(-3), "a reversal waits")
filter.reset()
expect(filter.accepts(-3), "after a lift, either direction counts at once")

if failures == 0 {
    print("ring-step-filter-tests: \(checks) checks passed")
    exit(0)
}
FileHandle.standardError.write(Data("ring-step-filter-tests: \(failures) of \(checks) checks failed\n".utf8))
exit(1)
