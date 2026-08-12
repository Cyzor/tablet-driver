// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// ConflictDetectionTests.swift — Standalone checks for
// ConflictProcessMatcher, the name-matching used by the Conflicts row in
// the Info tab.
//
// The app has no XCTest target (by design — see the project's test
// conventions), so these run as a small executable compiled against the
// real ConflictDetection.swift, seeded with synthetic process-name sets.
// Run via tools/conflict-detection-tests/run.sh. Exits non-zero on the
// first failure.

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

// MARK: - Regressions matching used to get wrong

/// NSWorkspace can report a process with localizedName == "" (not nil, so
/// it survives compactMap). "x".hasPrefix("") was vacuously true for every
/// x, which used to make an empty name match the first competingProcesses
/// entry regardless of what was actually running.
private func testEmptyNameNeverMatches() {
    let found = ConflictProcessMatcher.matchedLabels(liveNames: [""])
    expect(found.isEmpty, "empty-string process name produced a false-positive finding")
}

/// "Xencelabs" (a harmless UI helper) is a literal prefix of
/// "XencelabsDriver" (the actual driver process). Prefix matching used to
/// flag the harmless helper as the driver conflict.
private func testHelperProcessThatPrefixesADriverNameDoesNotMatch() {
    let found = ConflictProcessMatcher.matchedLabels(liveNames: ["Xencelabs"])
    expect(found.isEmpty, "a helper process whose name prefixes a real driver name should not match")
}

private func testUnrelatedRunningAppsProduceNoFindings() {
    let liveNames: Set<String> = [
        "Finder", "com.apple.finder", "Safari", "com.apple.Safari",
        "Xcode", "com.apple.dt.Xcode", "",
    ]
    let found = ConflictProcessMatcher.matchedLabels(liveNames: liveNames)
    expect(found.isEmpty, "unrelated running apps produced findings: \(found)")
}

// MARK: - Real matches still fire

private func testExactNameMatches() {
    let found = ConflictProcessMatcher.matchedLabels(liveNames: ["WacomTabletDriver"])
    expectEqual(found, ["Wacom Tablet Driver"], "exact process name should match")
}

private func testXencelabsDriverMatchesButHelpersDoNot() {
    // XencelabsAgent and Xencelabs (UI helpers) are deliberately excluded —
    // only the actual driver process is a real conflict risk.
    let found = ConflictProcessMatcher.matchedLabels(liveNames: ["XencelabsDriver"])
    expectEqual(found, ["Xencelabs Driver"], "Xencelabs driver process should match")

    let helpersOnly = ConflictProcessMatcher.matchedLabels(liveNames: ["XencelabsAgent", "Xencelabs"])
    expect(helpersOnly.isEmpty, "Xencelabs UI helpers should not be flagged as conflicts")
}

private func testMultipleDistinctProcessesAllReported() {
    let liveNames: Set<String> = ["WacomTabletDriver", "OpenTabletDriver.UX", ""]
    let found = ConflictProcessMatcher.matchedLabels(liveNames: liveNames)
    expectEqual(Set(found), ["Wacom Tablet Driver", "OpenTabletDriver UX"],
                "distinct competing processes should each be reported")
}

// MARK: - Runner

@main
enum ConflictDetectionTestRunner {
    static func main() {
        testEmptyNameNeverMatches()
        testHelperProcessThatPrefixesADriverNameDoesNotMatch()
        testUnrelatedRunningAppsProduceNoFindings()
        testExactNameMatches()
        testXencelabsDriverMatchesButHelpersDoNot()
        testMultipleDistinctProcessesAllReported()

        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("\(failures) of \(checks) checks failed\n".utf8))
            exit(1)
        }
    }
}
