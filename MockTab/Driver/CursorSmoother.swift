// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

/// Pure-state helpers for the pen cursor's per-report smoothing, jitter
/// estimation, and short-window velocity tracking. Extracted from
/// `InputInjector` so the math can be unit-tested directly.
///
/// All mutating methods are HIDThread-local from the caller's perspective —
/// the struct itself imposes no thread model. `InputInjector` holds one
/// instance and owns its lifecycle.
struct CursorSmoother {

    // MARK: - Jitter tracking
    //
    // Fixed ring buffer + running sum.
    // Eliminates O(n) Array.removeFirst() and a full reduce() on every jitterLevel read.

    static let jitterWindow = 60  // ~0.5 s at 133 Hz
    private var hoverRing = ContiguousArray<CGFloat>(repeating: 0, count: CursorSmoother.jitterWindow)
    private var hoverHead = 0
    private var hoverCount = 0
    private var hoverSum: CGFloat = 0
    private var lastRawPoint: CGPoint = .zero
    private var hasLastRawPoint = false

    // MARK: - EMA smoothing

    private(set) var smoothedPoint: CGPoint = .zero
    private(set) var hasSmoothedPoint = false
    /// Cached EMA alpha, recomputed at proximity entry from per-tool strength.
    /// 1.0 == raw (no smoothing); math collapses to smoothedPoint = rawPoint.
    var smoothingAlpha: Double = 1.0

    // MARK: - Short-window velocity (last 4 position deltas)

    private var recentDeltas = ContiguousArray<CGFloat>(repeating: 0, count: 4)
    private var recentDeltaHead = 0

    // MARK: - Reads

    /// Mean hover-position delta over the rolling window (points per sample).
    /// Spikes above ~3 pt/sample while hovering suggest RF interference.
    var jitterLevel: CGFloat {
        guard hoverCount >= 10 else { return 0 }
        return hoverSum / CGFloat(hoverCount)
    }

    var isJittery: Bool { jitterLevel > 3.0 }

    /// Rolling 4-sample velocity estimate in screen points per sample.
    var recentVelocity: CGFloat {
        recentDeltas.reduce(0, +) / CGFloat(recentDeltas.count)
    }

    // MARK: - Mutations

    /// Apply EMA smoothing to `rawPoint` and return the smoothed result.
    /// On proximity entry (or first ever call) the raw point is adopted
    /// as-is to avoid an initial slide-in from the previous smoothedPoint.
    mutating func applySmoothing(rawPoint: CGPoint, enteringProximity: Bool) -> CGPoint {
        if enteringProximity || !hasSmoothedPoint {
            smoothedPoint = rawPoint
            hasSmoothedPoint = true
        } else {
            smoothedPoint = CGPoint(
                x: smoothedPoint.x + smoothingAlpha * (rawPoint.x - smoothedPoint.x),
                y: smoothedPoint.y + smoothingAlpha * (rawPoint.y - smoothedPoint.y)
            )
        }
        return smoothedPoint
    }

    /// Feed a raw hover sample. Updates the rolling jitter window with the
    /// distance from the previous raw point (or seeds the previous point
    /// on first call).
    mutating func observeHoverRaw(_ rawPoint: CGPoint) {
        if hasLastRawPoint {
            addHoverDelta(
                hypot(rawPoint.x - lastRawPoint.x, rawPoint.y - lastRawPoint.y))
        }
        lastRawPoint = rawPoint
        hasLastRawPoint = true
    }

    /// Called when the pen is no longer hovering (tip is down): pauses
    /// jitter accumulation and discards the existing window.
    mutating func endHover() {
        hasLastRawPoint = false
        clearHoverDeltas()
    }

    /// Record a per-frame screen-space position delta (used by tip-up assist
    /// to gauge velocity at lift-off).
    mutating func recordMoveDelta(_ delta: CGFloat) {
        recentDeltas[recentDeltaHead] = delta
        recentDeltaHead = (recentDeltaHead + 1) % recentDeltas.count
    }

    /// Full reset for proximity exit: clears smoothed point, jitter ring,
    /// and velocity ring. Leaves `smoothingAlpha` untouched (re-set on
    /// next proximity entry).
    mutating func resetOnProximityExit() {
        hasSmoothedPoint = false
        hasLastRawPoint = false
        clearHoverDeltas()
        for i in recentDeltas.indices { recentDeltas[i] = 0 }
        recentDeltaHead = 0
    }

    // MARK: - Private helpers

    private mutating func addHoverDelta(_ delta: CGFloat) {
        if hoverCount == Self.jitterWindow {
            hoverSum -= hoverRing[hoverHead]
        } else {
            hoverCount += 1
        }
        hoverRing[hoverHead] = delta
        hoverSum += delta
        hoverHead = (hoverHead + 1) % Self.jitterWindow
    }

    private mutating func clearHoverDeltas() {
        guard hoverCount > 0 else { return }
        hoverCount = 0
        hoverSum = 0
    }
}
