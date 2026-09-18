// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// DisplayRegionTests.swift — Standalone checks for DisplayMapper's display
// sub-region mapping (tablet-driver#15): mapping the full tablet active area
// onto a rectangular sub-region of a display instead of the whole display.
//
// The app has no XCTest target, so these run as a small executable compiled
// against the real DisplayMapper.swift plus a hand-written stand-in for
// InjectionSnapshot (see TabletSettingsStub.swift for why). Run via
// tools/tests/display-region-tests/run.sh. Exits non-zero on the first failure.

import CoreGraphics
import Foundation

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

private func expectClose(
    _ a: Double, _ b: Double, _ tol: Double = 1e-9,
    _ message: @autoclosure () -> String,
    file: StaticString = #file, line: UInt = #line
) {
    expect(abs(a - b) <= tol, "\(message()) — got \(a), expected \(b) (±\(tol))",
           file: file, line: line)
}

// MARK: - applyDisplayRegion

/// Default region fields (0,0,1,1) must be a no-op, so every build predating
/// this feature keeps behaving exactly as before.
private func testDefaultRegionIsWholeDisplay() {
    let bounds = CGRect(x: 100, y: 200, width: 3440, height: 1440)
    let snapshot = InjectionSnapshot.fixture()
    let narrowed = DisplayMapper.applyDisplayRegion(bounds, snapshot: snapshot)
    expect(narrowed == bounds, "default region fields must leave the display's bounds untouched")
}

/// The reporter's actual scenario: map onto the left 2/3 of an ultrawide.
private func testPartialRegionNarrowsIntoSubRect() {
    let bounds = CGRect(x: 0, y: 0, width: 3440, height: 1440)
    let snapshot = InjectionSnapshot.fixture(
        displayRegionX: 0, displayRegionY: 0,
        displayRegionWidth: 2.0 / 3.0, displayRegionHeight: 1.0)
    let narrowed = DisplayMapper.applyDisplayRegion(bounds, snapshot: snapshot)
    expectClose(Double(narrowed.minX), 0, 1e-9, "left edge of a left-aligned region stays at the display's left edge")
    expectClose(Double(narrowed.width), 3440 * 2.0 / 3.0, 1e-6, "width narrows to the configured fraction")
    expectClose(Double(narrowed.height), 1440, 1e-9, "height is untouched when only width is narrowed")
}

/// A region offset away from the display's origin — e.g. the *right* portion
/// of the display rather than the left — must translate, not just resize.
private func testOffsetRegionTranslatesOrigin() {
    let bounds = CGRect(x: 0, y: 0, width: 3000, height: 1000)
    let snapshot = InjectionSnapshot.fixture(
        displayRegionX: 0.5, displayRegionY: 0.25,
        displayRegionWidth: 0.5, displayRegionHeight: 0.5)
    let narrowed = DisplayMapper.applyDisplayRegion(bounds, snapshot: snapshot)
    expectClose(Double(narrowed.minX), 1500, 1e-9, "region x-offset scales by display width and adds to its origin")
    expectClose(Double(narrowed.minY), 250, 1e-9, "region y-offset scales by display height and adds to its origin")
    expectClose(Double(narrowed.width), 1500, 1e-9, "width narrows to the configured fraction")
    expectClose(Double(narrowed.height), 500, 1e-9, "height narrows to the configured fraction")
}

/// A display whose origin isn't (0,0) — the common case for a secondary
/// monitor in a multi-display layout — must have the region resolved
/// relative to ITS origin, not the global origin.
private func testRegionRespectsNonZeroDisplayOrigin() {
    let bounds = CGRect(x: 1920, y: -300, width: 1920, height: 1080)
    let snapshot = InjectionSnapshot.fixture(
        displayRegionX: 0.25, displayRegionY: 0,
        displayRegionWidth: 0.5, displayRegionHeight: 1.0)
    let narrowed = DisplayMapper.applyDisplayRegion(bounds, snapshot: snapshot)
    expectClose(Double(narrowed.minX), 1920 + 1920 * 0.25, 1e-6, "x narrowing is relative to the display's own minX")
    expectClose(Double(narrowed.minY), -300, 1e-9, "y is untouched, still anchored at the display's own minY")
}

// MARK: - displayBounds(for:) cache invalidation

/// A display-region-only change (index unchanged) must still invalidate the
/// cache — this was a real bug in the first cut of this feature, where
/// cachedDisplayIndex alone gated the cache and a region edit silently had
/// no effect until some unrelated event (e.g. a display reconfiguration)
/// happened to also change the index.
private func testCacheInvalidatesOnRegionChangeAlone() {
    var mapper = DisplayMapper()
    let wide = InjectionSnapshot.fixture(targetDisplayIndex: 0)
    let first = mapper.displayBounds(for: wide)

    let narrowed = InjectionSnapshot.fixture(
        targetDisplayIndex: 0,  // same index as `wide`
        displayRegionWidth: 0.5)
    let second = mapper.displayBounds(for: narrowed)

    expect(first.width != second.width,
           "changing only the display region (index held constant) must invalidate the bounds cache")
    expectClose(Double(second.width), Double(first.width) * 0.5, 1e-6,
                "the re-resolved bounds must reflect the new region, not a stale cached rect")
}

@main
enum DisplayRegionTestRunner {
    static func main() {
        testDefaultRegionIsWholeDisplay()
        testPartialRegionNarrowsIntoSubRect()
        testOffsetRegionTranslatesOrigin()
        testRegionRespectsNonZeroDisplayOrigin()
        testCacheInvalidatesOnRegionChangeAlone()

        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        }
        FileHandle.standardError.write(Data("\(failures) of \(checks) checks failed\n".utf8))
        exit(1)
    }
}
