// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

// PanScrollTrackerTests.swift — Standalone checks for Scroll Drag release
// velocity, in particular the backdated-release path that Xencelabs barrel
// buttons depend on.
//
// The app has no XCTest target, so these run as a small executable compiled
// against the real PanScrollTracker.swift. Run via
// tools/pan-scroll-tracker-tests/run.sh. Exits non-zero on the first failure.

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

private let frameDt = 0.005

/// Drive a straight vertical flick: `frames` frames of `perFrame` points each.
/// Returns the tracker mid-gesture, still engaged.
private func flick(
    frames: Int = 8, perFrame: Double = 10
) -> PanScrollTracker {
    var t = PanScrollTracker()
    _ = t.engage(reverse: false, speed: 1.0)
    var y = 0.0
    // First frame only anchors; deltas start on the second.
    _ = t.process(screen: CGPoint(x: 0, y: y), dt: frameDt)
    for _ in 0..<frames {
        y += perFrame
        _ = t.process(screen: CGPoint(x: 0, y: y), dt: frameDt)
    }
    return t
}

/// Feed stationary frames, as the pen streams during a deferred button release.
private func holdStill(_ t: inout PanScrollTracker, seconds: Double) {
    let last = CGPoint(x: 0, y: 1_000_000)
    var elapsed = 0.0
    // Park at a fixed point; the first call establishes it, the rest are idle.
    _ = t.process(screen: last, dt: frameDt)
    while elapsed < seconds {
        _ = t.process(screen: last, dt: frameDt)
        elapsed += frameDt
    }
}

private func speed(_ v: CGVector) -> Double { hypot(v.dx, v.dy) }

// MARK: - Checks

/// Baseline: an immediate release right after a flick coasts. This is the
/// Wacom path, which fires its button-up with no deferral.
private func testImmediateReleaseKeepsMomentum() {
    var t = flick()
    _ = t.disengage()
    expect(speed(t.releaseVelocity) > 100,
           "an immediate post-flick release must seed momentum, got \(t.releaseVelocity)")
}

/// The case that motivated `disengage(backdate:)` — and the honest limit of it.
///
/// A *dead stop* at the release edge (velocity to exactly zero, no follow
/// through at all) is the only shape where the 0.05 s barrel-button debounce
/// costs momentum. It is not physically reachable with a real pen; the
/// realistic shapes are covered by `testFollowThroughSurvivesDeferralUnaided`
/// below, which is why the backdate is hardening rather than a bug fix.
private func testDeadStopLosesMomentumWithoutBackdate() {
    let debounce = PanScrollTracker.momentumRecencyWindow + 0.005
    var t = flick()
    holdStill(&t, seconds: debounce)
    _ = t.disengage()
    expect(speed(t.releaseVelocity) == 0,
           "a dead stop through the deferral scores as a brake without backdate")
}

/// The same dead stop, judged as of the physical edge, keeps its coast.
private func testDeadStopRecoveredByBackdate() {
    let debounce = PanScrollTracker.momentumRecencyWindow + 0.005
    var t = flick()
    holdStill(&t, seconds: debounce)
    _ = t.disengage(backdate: debounce)
    expect(speed(t.releaseVelocity) > 100,
           "a backdated deferred release must recover the flick, got \(t.releaseVelocity)")
}

/// Guards the claim in `disengage(backdate:)`'s doc comment: with any real
/// follow-through — including deceleration sharp enough to halt the pen inside
/// the debounce window — the un-backdated release already keeps full momentum.
/// If this ever starts failing, the "hardening, not a fix" framing is wrong and
/// the deferral has become user-visible.
private func testFollowThroughSurvivesDeferralUnaided() {
    for decel in [0.0, 10_000.0, 40_000.0] {
        var t = flick()
        var v = 2000.0
        var y = 1000.0
        var elapsed = 0.0
        while elapsed < PanScrollTracker.momentumRecencyWindow + 0.005 {
            v = max(0, v - decel * frameDt)
            y += v * frameDt
            _ = t.process(screen: CGPoint(x: 0, y: y), dt: frameDt)
            elapsed += frameDt
        }
        _ = t.disengage()
        expect(speed(t.releaseVelocity) > 100,
               "follow-through at decel \(decel) must coast unaided, got \(t.releaseVelocity)")
    }
}

/// The fix must not defeat genuine brake detection: a user who deliberately
/// holds still before releasing still gets no momentum, backdate or not.
private func testDeliberateBrakeStillSuppressesMomentum() {
    var t = flick()
    holdStill(&t, seconds: 0.30)
    _ = t.disengage(backdate: 0.05)
    expect(speed(t.releaseVelocity) == 0,
           "a deliberate brake must suppress momentum even with a backdate")
}

/// A backdate longer than `maxBackdate` is clamped rather than reaching past
/// the retained sample history into garbage.
private func testOversizedBackdateIsClamped() {
    var t = flick()
    holdStill(&t, seconds: 0.30)
    _ = t.disengage(backdate: 5.0)
    expect(speed(t.releaseVelocity) == 0,
           "an absurd backdate must clamp, not resurrect a stale flick")
}

@main
enum PanScrollTrackerTestRunner {
    static func main() {
        testImmediateReleaseKeepsMomentum()
        testDeadStopLosesMomentumWithoutBackdate()
        testDeadStopRecoveredByBackdate()
        testFollowThroughSurvivesDeferralUnaided()
        testDeliberateBrakeStillSuppressesMomentum()
        testOversizedBackdateIsClamped()

        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        }
        FileHandle.standardError.write(Data("\(failures) of \(checks) checks failed\n".utf8))
        exit(1)
    }
}
