// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import XCTest

@testable import MockTabDecoders

final class CursorSmootherTests: XCTestCase {

    // MARK: - Smoothing

    func testFirstReportAdoptsRawPointVerbatim() {
        var s = CursorSmoother()
        s.smoothingAlpha = 0.3
        let out = s.applySmoothing(rawPoint: CGPoint(x: 100, y: 50), enteringProximity: true)
        XCTAssertEqual(out.x, 100, accuracy: 1e-9)
        XCTAssertEqual(out.y, 50, accuracy: 1e-9)
        XCTAssertTrue(s.hasSmoothedPoint)
    }

    func testEnteringProximityResetsToRawEvenWithExistingSmoothedPoint() {
        var s = CursorSmoother()
        s.smoothingAlpha = 0.3
        _ = s.applySmoothing(rawPoint: CGPoint(x: 0, y: 0), enteringProximity: true)
        _ = s.applySmoothing(rawPoint: CGPoint(x: 100, y: 100), enteringProximity: false)
        // Now re-enter proximity at a new spot: should snap, not slide.
        let out = s.applySmoothing(rawPoint: CGPoint(x: 500, y: 500), enteringProximity: true)
        XCTAssertEqual(out, CGPoint(x: 500, y: 500))
    }

    func testEMAConvergesAtConfiguredAlpha() {
        var s = CursorSmoother()
        s.smoothingAlpha = 0.5
        _ = s.applySmoothing(rawPoint: CGPoint(x: 0, y: 0), enteringProximity: true)
        // Step to (100, 0); each tick should halve remaining distance.
        let p1 = s.applySmoothing(rawPoint: CGPoint(x: 100, y: 0), enteringProximity: false)
        XCTAssertEqual(p1.x, 50, accuracy: 1e-9)
        let p2 = s.applySmoothing(rawPoint: CGPoint(x: 100, y: 0), enteringProximity: false)
        XCTAssertEqual(p2.x, 75, accuracy: 1e-9)
        let p3 = s.applySmoothing(rawPoint: CGPoint(x: 100, y: 0), enteringProximity: false)
        XCTAssertEqual(p3.x, 87.5, accuracy: 1e-9)
    }

    func testAlphaOneIsPassThrough() {
        var s = CursorSmoother()
        s.smoothingAlpha = 1.0
        _ = s.applySmoothing(rawPoint: CGPoint(x: 0, y: 0), enteringProximity: true)
        let out = s.applySmoothing(rawPoint: CGPoint(x: 42, y: -17), enteringProximity: false)
        XCTAssertEqual(out, CGPoint(x: 42, y: -17))
    }

    // MARK: - Jitter window

    func testJitterLevelZeroBelowMinSamples() {
        var s = CursorSmoother()
        // Need 10 samples before jitterLevel reports anything.
        for i in 0..<9 {
            s.observeHoverRaw(CGPoint(x: CGFloat(i) * 10, y: 0))
        }
        XCTAssertEqual(s.jitterLevel, 0)
        XCTAssertFalse(s.isJittery)
    }

    func testJitterLevelAveragesRecentDeltas() {
        var s = CursorSmoother()
        // 11 samples spaced 5 pts apart => 10 deltas of 5.0.
        // jitterLevel = sum / count = 50 / 10 = 5.0
        for i in 0...10 {
            s.observeHoverRaw(CGPoint(x: CGFloat(i) * 5, y: 0))
        }
        XCTAssertEqual(s.jitterLevel, 5.0, accuracy: 1e-9)
        XCTAssertTrue(s.isJittery)  // > 3.0
    }

    func testJitterRingWrapsAndEvictsOldestSample() {
        var s = CursorSmoother()
        // Fill the 60-sample window with steady 1-pt deltas → average 1.0.
        // First call seeds lastRawPoint (no delta added); next 60 each
        // contribute a delta of 1.
        for i in 0...60 {
            s.observeHoverRaw(CGPoint(x: CGFloat(i), y: 0))
        }
        XCTAssertEqual(s.jitterLevel, 1.0, accuracy: 1e-9)
        // Drop a 100-pt spike. Previous raw was x=60, so use x=160.
        // Ring is full, so adding evicts one 1.0 sample. Sum: 60 - 1 + 100 = 159.
        s.observeHoverRaw(CGPoint(x: 160, y: 0))
        XCTAssertEqual(s.jitterLevel, 159.0 / 60.0, accuracy: 1e-9)
        // 60 more 1-pt steps fully rotate the spike out of the ring.
        for i in 1...60 {
            s.observeHoverRaw(CGPoint(x: 160 + CGFloat(i), y: 0))
        }
        XCTAssertEqual(s.jitterLevel, 1.0, accuracy: 1e-9)
    }

    func testEndHoverClearsJitterAccumulator() {
        var s = CursorSmoother()
        for i in 0...20 {
            s.observeHoverRaw(CGPoint(x: CGFloat(i) * 5, y: 0))
        }
        XCTAssertGreaterThan(s.jitterLevel, 0)
        s.endHover()
        XCTAssertEqual(s.jitterLevel, 0)
        // Subsequent samples should seed a fresh series, not continue the old one.
        for i in 0..<5 {
            s.observeHoverRaw(CGPoint(x: 1000 + CGFloat(i), y: 0))
        }
        // Below the 10-sample floor, jitterLevel stays 0.
        XCTAssertEqual(s.jitterLevel, 0)
    }

    // MARK: - Velocity ring

    func testRecentVelocityAveragesLastFourDeltas() {
        var s = CursorSmoother()
        s.recordMoveDelta(0)
        s.recordMoveDelta(2)
        s.recordMoveDelta(4)
        s.recordMoveDelta(6)
        // (0 + 2 + 4 + 6) / 4 = 3
        XCTAssertEqual(s.recentVelocity, 3.0, accuracy: 1e-9)
    }

    func testVelocityRingWrapsAtFour() {
        var s = CursorSmoother()
        // Fill, then overwrite the oldest with a fifth value.
        for d in [10, 10, 10, 10] as [CGFloat] {
            s.recordMoveDelta(d)
        }
        XCTAssertEqual(s.recentVelocity, 10.0, accuracy: 1e-9)
        s.recordMoveDelta(2)  // overwrites first 10
        // ring now [2, 10, 10, 10] → avg 8
        XCTAssertEqual(s.recentVelocity, 8.0, accuracy: 1e-9)
    }

    // MARK: - Proximity-exit reset

    func testResetOnProximityExitClearsEverythingExceptAlpha() {
        var s = CursorSmoother()
        s.smoothingAlpha = 0.42
        _ = s.applySmoothing(rawPoint: CGPoint(x: 50, y: 50), enteringProximity: true)
        for i in 0...20 {
            s.observeHoverRaw(CGPoint(x: CGFloat(i) * 7, y: 0))
        }
        for d in [5, 5, 5, 5] as [CGFloat] { s.recordMoveDelta(d) }
        XCTAssertTrue(s.hasSmoothedPoint)
        XCTAssertGreaterThan(s.jitterLevel, 0)
        XCTAssertGreaterThan(s.recentVelocity, 0)

        s.resetOnProximityExit()

        XCTAssertFalse(s.hasSmoothedPoint)
        XCTAssertEqual(s.jitterLevel, 0)
        XCTAssertEqual(s.recentVelocity, 0)
        // Alpha is intentionally preserved; re-set on next proximity entry.
        XCTAssertEqual(s.smoothingAlpha, 0.42)
    }
}
