// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

// PanScrollTrackerTests.swift — Standalone checks for Scroll Drag release
// velocity, in particular the backdated-release path that Xencelabs barrel
// buttons depend on.
//
// The app has no XCTest target, so these run as a small executable compiled
// against the real PanScrollTracker.swift. Run via
// tools/tests/pan-scroll-tracker-tests/run.sh. Exits non-zero on the first failure.

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

/// AppKit hands a gesture to the nested scroll view matching the `.began`
/// delta's dominant axis, so `.began` must wait for motion and carry it. A
/// zero-delta `.began` reads as vertical and strands horizontal pans in
/// Finder's column view.
private func testBeganCarriesFirstMotion() {
    var t = PanScrollTracker()
    expect(t.engage(reverse: false, speed: 1.0) == .scroll(dx: 0, dy: 0, phase: .mayBegin),
           "engage must post .mayBegin, as a trackpad touch does")
    var x = 0.0
    var intents: [PanScrollTracker.Intent] = []
    _ = t.process(screen: CGPoint(x: x, y: 0), dt: frameDt)
    for _ in 0..<10 {
        x += 6
        let intent = t.process(screen: CGPoint(x: x, y: 0), dt: frameDt)
        if intent != .none { intents.append(intent) }
    }
    guard case .scroll(let dx, let dy, let phase)? = intents.first else {
        expect(false, "a horizontal pan must emit scroll intents")
        return
    }
    expect(phase == .began, "the first motion must be .began, got \(phase)")
    expect(abs(dx) > abs(dy), "the .began delta must be horizontal, got (\(dx), \(dy))")
    expect(intents.dropFirst().allSatisfy {
        if case .scroll(_, _, .changed) = $0 { return true }
        return false
    }, "motion after .began must be .changed")
    expect(t.disengage() == .scroll(dx: 0, dy: 0, phase: .ended),
           "release after motion must end the gesture")
}

/// Sums the scroll intents' deltas.
private func totals(_ intents: [PanScrollTracker.Intent]) -> (dx: Double, dy: Double) {
    intents.reduce((0, 0)) {
        guard case .scroll(let dx, let dy, _) = $1 else { return $0 }
        return ($0.0 + dx, $0.1 + dy)
    }
}

/// With Require Contact the pan starts at tip-down, whose jolt must not set
/// the `.began` axis and strand a horizontal pan in Finder's column view.
private func testContactJoltDoesNotSetBeganAxis() {
    var t = PanScrollTracker()
    _ = t.engage(reverse: false, speed: 1.0)
    var intents: [PanScrollTracker.Intent] = []
    for point in [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 3), CGPoint(x: 0, y: 3), CGPoint(x: 0, y: 1)] {
        intents.append(t.process(screen: point, dt: frameDt))
    }
    for i in 1...10 {
        intents.append(t.process(screen: CGPoint(x: Double(i) * 3, y: 1), dt: frameDt))
    }
    guard case .scroll(let dx, let dy, .began)? = intents.first(where: { $0 != .none }) else {
        expect(false, "the pan must open with .began")
        return
    }
    expect(abs(dx) > abs(dy), "a touchdown jolt must not make .began vertical, got (\(dx), \(dy))")
}

/// Drives a gesture through `points` (screen positions, one per frame) and
/// returns every intent after the anchor frame.
private func pan(_ points: [CGPoint]) -> [PanScrollTracker.Intent] {
    var t = PanScrollTracker()
    _ = t.engage(reverse: false, speed: 1.0)
    return points.enumerated().compactMap { i, p in
        let intent = t.process(screen: p, dt: frameDt)
        return i == 0 ? nil : intent
    }
}

/// Points along a straight line from `start`, `step` apart at `degrees` from
/// the positive Y axis.
private func line(from start: CGPoint, degrees: Double, step: Double, count: Int) -> [CGPoint] {
    let r = degrees * .pi / 180
    return (1...count).map {
        CGPoint(x: start.x + sin(r) * step * Double($0), y: start.y + cos(r) * step * Double($0))
    }
}

/// A hand-drawn vertical stroke slants a little; it locks and leaks no
/// sideways scroll for Firefox to take as a swipe.
private func testSlantedVerticalStrokeStaysLocked() {
    let points = [CGPoint.zero] + line(from: .zero, degrees: 10, step: 4, count: 100)
    let leaked = totals(Array(pan(points).dropFirst(5))).dx
    expect(leaked == 0, "a 10-degree vertical stroke must stay locked, leaked \(leaked)")
}

/// Side-to-side wobble during a vertical scroll stays locked out.
private func testWobbleDuringVerticalScrollStaysLocked() {
    let points = (0...100).map { CGPoint(x: $0 % 2 == 0 ? 0 : 3, y: Double($0) * 4) }
    let leaked = totals(Array(pan(points).dropFirst(5))).dx
    expect(leaked.magnitude <= 1, "wobble in a vertical scroll must stay locked, leaked \(leaked)")
}

/// A flick released while locked coasts along the locked axis only.
private func testLockedFlickCoastsOnAxis() {
    var t = PanScrollTracker()
    _ = t.engage(reverse: false, speed: 1.0)
    for p in [CGPoint.zero] + line(from: .zero, degrees: 15, step: 10, count: 10) {
        _ = t.process(screen: p, dt: frameDt)
    }
    _ = t.disengage()
    expect(t.releaseVelocity.dx == 0 && t.releaseVelocity.dy > 0,
           "a locked vertical flick must coast vertically only, got \(t.releaseVelocity)")
}

/// A diagonal start stays free for the whole gesture.
private func testDiagonalStartStaysFree() {
    let points = [CGPoint.zero] + line(from: .zero, degrees: 40, step: 4, count: 30)
    let t = totals(pan(points))
    expect(t.dx >= 50 && t.dy >= 50, "a diagonal pan must move both axes, got \(t)")
}

/// A pan that starts vertical follows a deliberate turn sideways.
private func testTurnAfterVerticalStartScrollsSideways() {
    let down = [CGPoint.zero] + line(from: .zero, degrees: 0, step: 4, count: 20)
    let across = line(from: down.last!, degrees: 90, step: 4, count: 30)
    let sideways = totals(Array(pan(down + across).dropFirst(20))).dx
    expect(sideways >= 60, "a turn after a vertical start must scroll sideways, got \(sideways)")
}

/// The phases a pan posted, with each `.began`'s delta.
private func phases(_ intents: [PanScrollTracker.Intent]) -> [(phase: PanScrollTracker.ScrollPhase, dx: Double, dy: Double)] {
    intents.compactMap {
        guard case .scroll(let dx, let dy, let phase) = $0 else { return nil }
        return (phase, dx, dy)
    }
}

/// AppKit keeps a gesture on the view its `.began` picked, so a vertical start
/// that turns sideways ends and begins again, now horizontal (Finder's column
/// view scrolled nothing sideways otherwise).
private func testTurnSidewaysRestartsGesture() {
    let down = [CGPoint.zero] + line(from: .zero, degrees: 0, step: 4, count: 20)
    let across = line(from: down.last!, degrees: 90, step: 4, count: 30)
    let seen = phases(pan(down + across))
    let began = seen.filter { $0.phase == .began }
    expect(seen.filter { $0.phase == .ended }.count == 1, "one restart, got \(seen.map(\.phase))")
    expect(began.count == 2, "a second .began after the turn, got \(began.count)")
    if began.count == 2 {
        expect(abs(began[0].dy) > abs(began[0].dx), "the first .began is vertical: \(began[0])")
        expect(abs(began[1].dx) > abs(began[1].dy), "the second .began is horizontal: \(began[1])")
    }
    if let i = seen.firstIndex(where: { $0.phase == .ended }) {
        expect(seen[(i + 1)...].first(where: { $0.dx != 0 || $0.dy != 0 })?.phase == .began,
               "motion after the restart opens with .began")
    }
}

/// The same for a sideways start that turns vertical.
private func testTurnVerticalRestartsGesture() {
    let across = [CGPoint.zero] + line(from: .zero, degrees: 90, step: 4, count: 20)
    let down = line(from: across.last!, degrees: 0, step: 4, count: 30)
    let began = phases(pan(across + down)).filter { $0.phase == .began }
    expect(began.count == 2 && abs(began[1].dy) > abs(began[1].dx),
           "a sideways start turning vertical begins again vertically, got \(began)")
}

/// A diagonal start that AppKit took as vertical restarts when it settles sideways.
private func testDiagonalStartThenSidewaysRestarts() {
    let slant = [CGPoint.zero] + line(from: .zero, degrees: 40, step: 4, count: 6)
    let across = line(from: slant.last!, degrees: 90, step: 4, count: 30)
    let began = phases(pan(slant + across)).filter { $0.phase == .began }
    expect(began.count == 2 && abs(began[1].dx) > abs(began[1].dy),
           "a near-diagonal start settling sideways begins again horizontally, got \(began)")
}

/// Panning diagonally, or wobbling along one axis, never restarts: canvas
/// apps see one gesture.
private func testDiagonalAndWobblyPansDontRestart() {
    let diagonal = [CGPoint.zero] + line(from: .zero, degrees: 40, step: 4, count: 80)
    expect(!phases(pan(diagonal)).contains { $0.phase == .ended }, "a diagonal pan stays one gesture")
    let wobble = (0...100).map { CGPoint(x: $0 % 2 == 0 ? 0 : 3, y: Double($0) * 4) }
    expect(!phases(pan(wobble)).contains { $0.phase == .ended }, "a wobbly vertical pan stays one gesture")
    let curve = [CGPoint.zero] + line(from: .zero, degrees: 25, step: 4, count: 40)
        + line(from: line(from: .zero, degrees: 25, step: 4, count: 40).last!, degrees: -20, step: 4, count: 40)
    expect(!phases(pan(curve)).contains { $0.phase == .ended }, "a gentle curve stays one gesture")
    let drift = [CGPoint.zero] + line(from: .zero, degrees: 40, step: 4, count: 20)
        + line(from: line(from: .zero, degrees: 40, step: 4, count: 20).last!, degrees: 50, step: 4, count: 40)
    expect(!phases(pan(drift)).contains { $0.phase == .ended }, "drifting across 45 degrees stays one gesture")
}

/// The new `.began` waits for real travel along the new axis, so fine,
/// jittery frames after the turn can't hand AppKit a vertical-looking one.
private func testRestartWaitsForTravel() {
    let down = [CGPoint.zero] + line(from: .zero, degrees: 0, step: 4, count: 20)
    let across = (1...80).map { CGPoint(x: down.last!.x + Double($0), y: down.last!.y + ($0 % 2 == 0 ? 0 : 1.5)) }
    let began = phases(pan(down + across)).filter { $0.phase == .began }
    expect(began.count == 2 && abs(began[1].dx) > abs(began[1].dy) && abs(began[1].dx) >= 3,
           "after the turn, .began carries sideways travel, got \(began)")
}

/// A first move exactly diagonal reads as vertical to AppKit, so a sideways
/// turn after it still restarts.
private func testExactDiagonalStartCountsAsVertical() {
    let start = [CGPoint.zero] + (1...3).map { CGPoint(x: Double($0) * 2, y: Double($0) * 2) }
    let across = line(from: start.last!, degrees: 90, step: 4, count: 30)
    let began = phases(pan(start + across)).filter { $0.phase == .began }
    expect(began.first.map { abs($0.dx) == abs($0.dy) } == true, "the first .began is an exact diagonal: \(began)")
    expect(began.count == 2 && abs(began[1].dx) > abs(began[1].dy),
           "a tie reads as vertical, so the sideways turn begins again, got \(began)")
}

/// Released between the restart and the next `.began`: the old gesture
/// already ended, so nothing more goes out and nothing coasts.
private func testReleaseRightAfterRestartPostsNothing() {
    var t = PanScrollTracker()
    _ = t.engage(reverse: false, speed: 1.0)
    let down = [CGPoint.zero] + line(from: .zero, degrees: 0, step: 4, count: 20)
    var restarted = false
    var p = down.last!
    for q in down { _ = t.process(screen: q, dt: frameDt) }
    for _ in 0..<40 where !restarted {
        p.x += 4
        if t.process(screen: p, dt: frameDt) == .scroll(dx: 0, dy: 0, phase: .ended) { restarted = true }
    }
    expect(restarted, "the turn restarts the gesture")
    expect(t.disengage() == .none, "a release before the next .began posts nothing")
    expect(speed(t.releaseVelocity) == 0, "and seeds no coast")
}

/// A press and release without motion opened no gesture, so the release
/// cancels the `.mayBegin` and nothing coasts.
private func testReleaseWithoutMotionCancels() {
    var t = PanScrollTracker()
    _ = t.engage(reverse: false, speed: 1.0)
    // Sub-pixel jitter: raw velocity, but no whole-pixel delta.
    for i in 0..<10 {
        let intent = t.process(screen: CGPoint(x: Double(i % 2) * 0.2, y: 0), dt: frameDt)
        expect(intent == .none, "sub-pixel jitter must not open a gesture")
    }
    expect(t.disengage() == .scroll(dx: 0, dy: 0, phase: .cancelled),
           "release without a .began must cancel the .mayBegin")
    expect(speed(t.releaseVelocity) == 0, "release without a .began must not coast")
}

@main
enum PanScrollTrackerTestRunner {
    static func main() {
        testBeganCarriesFirstMotion()
        testReleaseWithoutMotionCancels()
        testContactJoltDoesNotSetBeganAxis()
        testSlantedVerticalStrokeStaysLocked()
        testWobbleDuringVerticalScrollStaysLocked()
        testLockedFlickCoastsOnAxis()
        testDiagonalStartStaysFree()
        testTurnAfterVerticalStartScrollsSideways()
        testTurnSidewaysRestartsGesture()
        testTurnVerticalRestartsGesture()
        testDiagonalStartThenSidewaysRestarts()
        testDiagonalAndWobblyPansDontRestart()
        testReleaseRightAfterRestartPostsNothing()
        testExactDiagonalStartCountsAsVertical()
        testRestartWaitsForTravel()
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
