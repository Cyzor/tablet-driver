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
    // PTH-850: 325×203 mm surface.
    static func testTouchAspectFollowsOrientation() {
        let full = (x: 0.0, y: 0.0, w: 1.0, h: 1.0)
        expectClose(
            DisplayMapper.orientedCropAspect(
                widthMM: 325, heightMM: 203, crop: full, orientation: .landscape),
            325.0 / 203.0, 1e-9, "landscape keeps the surface aspect")
        for orientation in [TabletOrientation.portrait, .portraitFlipped] {
            expectClose(
                DisplayMapper.orientedCropAspect(
                    widthMM: 325, heightMM: 203, crop: full, orientation: orientation),
                203.0 / 325.0, 1e-9, "\(orientation) inverts the surface aspect")
        }
    }

    static func testTouchAspectFollowsCrop() {
        // Left half of a landscape surface, turned portrait: the crop is
        // already oriented, so it's the top half of a 203×325 surface.
        let crop = DisplayMapper.orientedCropRect(
            areaX: 0, areaY: 0, areaWidth: 0.5, areaHeight: 1, orientation: .portrait)
        expectClose(
            DisplayMapper.orientedCropAspect(
                widthMM: 325, heightMM: 203, crop: crop, orientation: .portrait),
            203.0 / 162.5, 1e-9, "portrait crop uses the cropped physical size")
    }

    // tablet-driver#17: two spanned displays with unaligned bottoms. The left
    // one is 2560×1440; the right one is 1920×1080 and sits 200 pt lower, so
    // its bottom is 160 pt above the union's.
    static func testEdgePinningFollowsEachDisplay() {
        let left = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let right = CGRect(x: 2560, y: 200, width: 1920, height: 1080)
        let members = [left, right]
        let union = left.union(right)
        let inset = DisplayMapper.edgePinInset
        func pin(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            DisplayMapper.pinNearEdges(CGPoint(x: x, y: y), in: union, members: members)
        }

        // The tablet's bottom edge maps to the union's bottom. Under the
        // shorter display that's empty space; it must land on that display's
        // own bottom edge, all the way along it.
        for x: CGFloat in [2600, 3500, 4400] {
            let p = pin(x, 1440)
            expectClose(p.y, 1280 - inset, 1e-9, "x=\(x): pinned to the right display's bottom")
            expectClose(p.x, x, 1e-9, "x=\(x): sideways position kept")
        }
        expectClose(pin(1000, 1440).y, 1440 - inset, 1e-9, "left display keeps its own bottom")

        // The edge between the two displays never pins, so crossing is free.
        expectClose(pin(2559.5, 700).x, 2559.5, 1e-9, "shared edge, left side: no pin")
        expectClose(pin(2561, 700).x, 2561, 1e-9, "shared edge, right side: no pin")
        expectClose(pin(2561, 1279).x, 2561, 1e-9, "shared edge at the bottom corner: no x pin")
        expectClose(pin(2561, 1279).y, 1280 - inset, 1e-9, "…but the bottom still pins")

        // Outer edges still pin, including the top of the lower display.
        expectClose(pin(4479, 700).x, 4480 - inset, 1e-9, "right outer edge pins")
        expectClose(pin(3000, 100).y, 200 + inset, 1e-9, "gap above: lands on the display's top edge")

        // A skipped display in the middle of a span is still a surface: the
        // cursor crosses it, and the selected displays' inner edges don't pin.
        let a = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let skipped = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let c = CGRect(x: 3840, y: 0, width: 1920, height: 1080)
        let row = [a, skipped, c]
        let across = DisplayMapper.pinNearEdges(
            CGPoint(x: 2800, y: 500), in: a.union(c), members: row)
        expect(across == CGPoint(x: 2800, y: 500), "skipped display: cursor crosses it")
        expectClose(DisplayMapper.pinNearEdges(
            CGPoint(x: 1919, y: 500), in: a.union(c), members: row).x,
            1919, 1e-9, "skipped display: edge next to it doesn't pin")

        // One display: unchanged, no clamping.
        let single = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let p = DisplayMapper.pinNearEdges(CGPoint(x: 1919, y: 1079), in: single, members: [])
        expectClose(p.x, 1920 - inset, 1e-9, "single display: right edge pins")
        expectClose(p.y, 1080 - inset, 1e-9, "single display: bottom edge pins")
        let mid = DisplayMapper.pinNearEdges(CGPoint(x: 900, y: 500), in: single, members: [])
        expect(mid == CGPoint(x: 900, y: 500), "single display: interior untouched")
    }

    /// A recorded UUID outranks list position; without one, the index decides.
    static func testSpecificDisplayResolution() {
        let main = CGMainDisplayID()
        expect(DisplayMapper.specificDisplay(index: 2, uuid: "", in: [11, 22]) == 22,
               "no UUID: index picks by list position")
        expect(DisplayMapper.specificDisplay(index: 1, uuid: "0-0-0", in: [11, 22]) == 11,
               "unreliable UUID: index picks by list position")
        expect(DisplayMapper.specificDisplay(index: 5, uuid: "", in: [11, 22]) == main,
               "index past the list: main display")
        expect(DisplayMapper.specificDisplay(index: 1, uuid: "5-6-7", in: [11, 22]) == main,
               "recorded display unplugged: main display, not the index")
        let mainUUID = CalibrationKey.uuidString(for: main)
        if CalibrationKey.isReliable(mainUUID) {
            expect(DisplayMapper.specificDisplay(index: 1, uuid: mainUUID, in: [11, main]) == main,
                   "recorded display found at a new list position")
        }
    }

    static func main() {
        testDefaultRegionIsWholeDisplay()
        testPartialRegionNarrowsIntoSubRect()
        testOffsetRegionTranslatesOrigin()
        testRegionRespectsNonZeroDisplayOrigin()
        testCacheInvalidatesOnRegionChangeAlone()
        testTouchAspectFollowsOrientation()
        testTouchAspectFollowsCrop()
        testEdgePinningFollowsEachDisplay()
        testSpecificDisplayResolution()

        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        }
        FileHandle.standardError.write(Data("\(failures) of \(checks) checks failed\n".utf8))
        exit(1)
    }
}
