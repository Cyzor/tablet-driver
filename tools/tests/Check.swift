// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// Assertion helpers shared by the standalone test harnesses. lib.sh's
// swift_test compiles this file into every harness. A failed check prints
// where it failed and the run keeps going; `finish` reports the totals and
// sets the exit status.

import Foundation

var checks = 0
var failures = 0

func expect(
    _ condition: Bool, _ message: @autoclosure () -> String,
    file: StaticString = #file, line: UInt = #line
) {
    checks += 1
    guard !condition else { return }
    failures += 1
    FileHandle.standardError.write(Data("FAIL (\(file):\(line)): \(message())\n".utf8))
}

func expectClose(
    _ a: Double, _ b: Double, _ tolerance: Double = 1e-9,
    _ message: @autoclosure () -> String,
    file: StaticString = #file, line: UInt = #line
) {
    expect(abs(a - b) <= tolerance, "\(message()) — got \(a), expected \(b) (±\(tolerance))",
           file: file, line: line)
}

func expectEqual<T: Equatable>(
    _ actual: T, _ expected: T, _ message: @autoclosure () -> String,
    file: StaticString = #file, line: UInt = #line
) {
    expect(actual == expected, "\(message()) — got \(actual), expected \(expected)",
           file: file, line: line)
}

/// Prints the totals and exits: 0 when every check passed, 1 otherwise.
func finish() -> Never {
    if failures == 0 {
        print("ok — \(checks) checks passed")
        exit(0)
    }
    FileHandle.standardError.write(Data("\(failures) of \(checks) checks failed\n".utf8))
    exit(1)
}
