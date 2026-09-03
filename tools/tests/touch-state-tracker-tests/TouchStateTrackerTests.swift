// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

// TouchStateTrackerTests.swift — Standalone checks for touch gesture intent.
//
// The app has no XCTest target, so these run as a small executable compiled
// against the real TouchStateTracker.swift. Run via
// tools/tests/touch-state-tracker-tests/run.sh. Exits non-zero on the first failure.

import Foundation

private var failures = 0
private var checks = 0

private func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: @autoclosure () -> String,
    file: StaticString = #file,
    line: UInt = #line
) {
    checks += 1
    guard actual != expected else { return }
    failures += 1
    FileHandle.standardError.write(
        Data("FAIL (\(file):\(line)): \(message()) — got \(actual), expected \(expected)\n".utf8)
    )
}

private func contacts(distance: Double) -> [(id: Int, screen: CGPoint)] {
    [(id: 1, screen: CGPoint(x: -distance / 2, y: 0)),
     (id: 2, screen: CGPoint(x: distance / 2, y: 0))]
}

private func process(
    _ tracker: inout TouchStateTracker,
    _ contacts: [(id: Int, screen: CGPoint)],
    at time: CFAbsoluteTime
) -> TouchStateTracker.Intent {
    tracker.process(
        contacts: contacts,
        tapToClick: false,
        twoFingerScroll: true,
        reverseScrollDirection: false,
        sensitivity: 1,
        pinchZoom: true,
        smartZoom: true,
        now: time
    )
}

private func processAbsolute(
    _ tracker: inout TouchStateTracker,
    _ contacts: [(id: Int, screen: CGPoint)],
    at time: CFAbsoluteTime,
    tapToClick: Bool = true
) -> TouchStateTracker.Intent {
    tracker.process(
        contacts: contacts,
        tapToClick: tapToClick,
        twoFingerScroll: true,
        reverseScrollDirection: false,
        sensitivity: 1,
        pinchZoom: true,
        smartZoom: true,
        absoluteTouch: true,
        now: time
    )
}

/// Shorthand for a `.twoFingerGesture` with only a magnify component —
/// most pinch-only test expectations don't care about a concurrent rotate.
private func magnify(_ value: Double, phase: TouchStateTracker.ScrollPhase) -> TouchStateTracker.Intent {
    .twoFingerGesture(magnify: TouchStateTracker.GestureDelta(value: value, phase: phase), rotate: nil)
}

/// Shorthand for a `.twoFingerGesture` with only a rotate component.
private func rotateOnly(_ value: Double, phase: TouchStateTracker.ScrollPhase) -> TouchStateTracker.Intent {
    .twoFingerGesture(magnify: nil, rotate: TouchStateTracker.GestureDelta(value: value, phase: phase))
}

/// Like `process`, but with rotate enabled and raw device-unit positions
/// supplied for the separation gate.
private func rprocess(
    _ tracker: inout TouchStateTracker,
    _ contacts: [(id: Int, screen: CGPoint)],
    rawPositions: [Int: CGPoint],
    touchDiagonal: Double,
    at time: CFAbsoluteTime
) -> TouchStateTracker.Intent {
    tracker.process(
        contacts: contacts,
        tapToClick: false,
        twoFingerScroll: true,
        reverseScrollDirection: false,
        sensitivity: 1,
        pinchZoom: true,
        rotate: true,
        rawPositions: rawPositions,
        touchDiagonal: touchDiagonal,
        now: time
    )
}

/// Assert `intent` is a `.twoFingerGesture` with a rotate component at
/// `phase: .changed` and a magnitude at least `minMagnitude`, without
/// pinning an exact Double — angle values here pass through `atan2`, so
/// bit-exact equality against a hand-computed expectation would be fragile.
/// Sign/phase/magnitude is what actually matters for this test.
private func expectRotateChanged(
    _ intent: TouchStateTracker.Intent,
    minMagnitude: Double = 0.05,
    _ message: @autoclosure () -> String,
    file: StaticString = #file,
    line: UInt = #line
) {
    checks += 1
    guard case let .twoFingerGesture(_, .some(rotate)) = intent,
        rotate.phase == .changed, abs(rotate.value) >= minMagnitude
    else {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL (\(file):\(line)): \(message()) — got \(intent)\n".utf8)
        )
        return
    }
}

/// Two contacts on a circle of `radius` around the origin, diametrically
/// opposite — centroid and inter-finger distance stay fixed as `angle`
/// varies, isolating pure rotation from the other two candidates.
private func circleContacts(radius: Double, angle: Double) -> [(id: Int, screen: CGPoint)] {
    let a = CGPoint(x: radius * cos(angle), y: radius * sin(angle))
    return [(id: 1, screen: a), (id: 2, screen: CGPoint(x: -a.x, y: -a.y))]
}

/// One contact fixed at `anchor`, the other arcing around it at fixed
/// `radius` — the anchored-finger-arc case: real centroid translation *and*
/// real angle change at once, with magnitudes that stay comparable (neither
/// dominates the other) for the modest angles these tests use.
private func anchoredArcContacts(anchor: CGPoint, radius: Double, angle: Double) -> [(id: Int, screen: CGPoint)] {
    let b = CGPoint(x: anchor.x + radius * cos(angle), y: anchor.y + radius * sin(angle))
    return [(id: 1, screen: anchor), (id: 2, screen: b)]
}

/// Raw device-unit positions `distance` apart, as a fraction of a 4095-unit
/// touch diagonal (PTH-850-scale) — same helper shape as `contacts(distance:)`.
private func rawPositions(distance: Double) -> [Int: CGPoint] {
    [1: CGPoint(x: -distance / 2, y: 0), 2: CGPoint(x: distance / 2, y: 0)]
}
private let testTouchDiagonal = 4095.0

/// The full magnify envelope: silent commit (no Began until pinch wins),
/// then Changed frames carrying the exact relative growth of inter-finger
/// distance since the previous frame — spreading positive, closing negative
/// — then an Ended bracket on lift.
private func testPinchMagnifyEnvelope() {
    var tracker = TouchStateTracker()
    _ = process(&tracker, [(id: 1, screen: .zero)], at: 0)
    expectEqual(process(&tracker, contacts(distance: 20), at: 0.01), .none,
                "two-finger pinch waits for a decisive motion")
    expectEqual(process(&tracker, contacts(distance: 30), at: 0.02),
                magnify(0, phase: .began),
                "distance-dominant motion commits to pinch and opens the envelope")
    expectEqual(process(&tracker, contacts(distance: 45), at: 0.03),
                magnify(15.0 / 30.0, phase: .changed),
                "spreading fingers emits the exact relative growth since last frame")
    expectEqual(process(&tracker, contacts(distance: 30), at: 0.04),
                magnify(-15.0 / 45.0, phase: .changed),
                "closing fingers emits negative relative growth")
    expectEqual(process(&tracker, [], at: 0.05),
                magnify(0, phase: .ended),
                "lifting fingers closes the magnify envelope")
}

private func testPreCommitLiftHasNoScrollEnd() {
    var tracker = TouchStateTracker()
    _ = process(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = process(&tracker, contacts(distance: 20), at: 0.01)
    expectEqual(process(&tracker, [], at: 0.02), .none,
                "a pinch that never commits must not emit a scroll end")
}

/// A finger lifting mid-gesture collapses the centroid onto the surviving
/// contact — roughly half the finger separation from the two-finger anchor.
/// That must not read as translation and commit a pan.
private func testSingleContactFrameDoesNotCommitPan() {
    var tracker = TouchStateTracker()
    _ = process(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = process(&tracker, contacts(distance: 40), at: 0.01)
    expectEqual(process(&tracker, [(id: 2, screen: CGPoint(x: 20, y: 0))], at: 0.02),
                .none,
                "a 1-contact frame while undecided must not commit a phantom pan")
}

/// Regression guard: a real lift must reset tracking immediately (no
/// deferred/bridged teardown — tried once, reverted, see git history), so a
/// later touch at a completely different location starts a fresh relative
/// sequence instead of computing its first delta against the old drag's
/// stale position. A bridged design that holds `.pointer` mode open past a
/// genuine lift (waiting for a report that may never come, since a real
/// lift produces no further reports until the *next*, unrelated touch)
/// reproduces exactly this: the next touch-down, especially if it reuses
/// the same contact id (a small slot-id range makes that likely), jumps the
/// cursor by the distance between the two unrelated locations — reported as
/// tapping in different spots "teleporting" the cursor, absolute-position-
/// style.
private func testNewTouchAfterLiftDoesNotJumpFromOldPosition() {
    var tracker = TouchStateTracker()
    _ = process(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = process(&tracker, [(id: 1, screen: CGPoint(x: 20, y: 0))], at: 0.13)
    _ = process(&tracker, [(id: 1, screen: CGPoint(x: 300, y: 300))], at: 0.14)
    _ = process(&tracker, [], at: 0.15)  // a real lift
    // A brand-new touch far away, reusing the same contact id.
    _ = process(&tracker, [(id: 1, screen: CGPoint(x: -900, y: -900))], at: 1.0)
    _ = process(&tracker, [(id: 1, screen: CGPoint(x: -895, y: -900))], at: 1.14)  // crosses onsetDelay
    expectEqual(process(&tracker, [(id: 1, screen: CGPoint(x: -890, y: -900))], at: 1.15),
                .pointerMove(dx: 5, dy: 0),
                "a fresh touch after a real lift must not jump from the previous location")
}

/// A tap must resolve the instant it lifts, whether or not it already
/// crossed into `.pointer` mode.
private func testTapResolvesImmediatelyOnLift() {
    var tracker = TouchStateTracker()
    _ = tracker.process(
        contacts: [(id: 1, screen: .zero)], tapToClick: true, twoFingerScroll: true,
        reverseScrollDirection: false, sensitivity: 1, now: 0)
    _ = tracker.process(
        contacts: [(id: 1, screen: CGPoint(x: 1, y: 0))], tapToClick: true, twoFingerScroll: true,
        reverseScrollDirection: false, sensitivity: 1, now: 0.13)
    expectEqual(
        tracker.process(
            contacts: [], tapToClick: true, twoFingerScroll: true,
            reverseScrollDirection: false, sensitivity: 1, now: 0.14),
        .tapClick,
        "a tap that crossed into .pointer mode without real drag motion must still resolve immediately")
}

/// Two fingers a fixed distance apart, both shifted by `offset` — pure
/// translation, no scale or angle change, to test the pan fallback in
/// isolation from pinch/rotate.
private func sweepPan(offset: Double) -> [(id: Int, screen: CGPoint)] {
    [(id: 1, screen: CGPoint(x: offset - 20, y: 0)), (id: 2, screen: CGPoint(x: offset + 20, y: 0))]
}

/// Scroll, pinch, and rotate are independent toggles, not scroll-gated
/// features: a pinch must still commit even with two-finger scroll off.
private func testPinchCommitsWithTwoFingerScrollDisabled() {
    var tracker = TouchStateTracker()
    _ = tracker.process(
        contacts: [(id: 1, screen: .zero)], tapToClick: false, twoFingerScroll: false,
        reverseScrollDirection: false, sensitivity: 1, pinchZoom: true, now: 0)
    _ = tracker.process(
        contacts: contacts(distance: 20), tapToClick: false, twoFingerScroll: false,
        reverseScrollDirection: false, sensitivity: 1, pinchZoom: true, now: 0.01)
    expectEqual(
        tracker.process(
            contacts: contacts(distance: 30), tapToClick: false, twoFingerScroll: false,
            reverseScrollDirection: false, sensitivity: 1, pinchZoom: true, now: 0.02),
        magnify(0, phase: .began),
        "pinch must commit even when two-finger scroll is disabled")
}

/// With two-finger scroll off, pan is not a candidate at all — pure
/// translation (which would otherwise fall back to pan) must stay silent
/// indefinitely rather than ever emit a scroll, even with pinch enabled and
/// clearly not winning.
private func testPanStaysSilentWithTwoFingerScrollDisabled() {
    var tracker = TouchStateTracker()
    _ = tracker.process(
        contacts: [(id: 1, screen: .zero)], tapToClick: false, twoFingerScroll: false,
        reverseScrollDirection: false, sensitivity: 1, pinchZoom: true, now: 0)
    _ = tracker.process(
        contacts: sweepPan(offset: 0), tapToClick: false, twoFingerScroll: false,
        reverseScrollDirection: false, sensitivity: 1, pinchZoom: true, now: 0.01)
    expectEqual(
        tracker.process(
            contacts: sweepPan(offset: 30), tapToClick: false, twoFingerScroll: false,
            reverseScrollDirection: false, sensitivity: 1, pinchZoom: true, now: 0.03),
        .none,
        "pure translation must not fall back to pan when two-finger scroll is disabled")
    expectEqual(
        tracker.process(
            contacts: sweepPan(offset: 60), tapToClick: false, twoFingerScroll: false,
            reverseScrollDirection: false, sensitivity: 1, pinchZoom: true, now: 0.05),
        .none,
        "continued translation still must not fall back to pan")
}

/// Rotate must also commit on its own with two-finger scroll off.
private func testRotateCommitsWithTwoFingerScrollDisabled() {
    var tracker = TouchStateTracker()
    let wide = rawPositions(distance: 700)
    _ = tracker.process(
        contacts: [(id: 1, screen: .zero)], tapToClick: false, twoFingerScroll: false,
        reverseScrollDirection: false, sensitivity: 1, rotate: true,
        rawPositions: wide, touchDiagonal: testTouchDiagonal, now: 0)
    _ = tracker.process(
        contacts: circleContacts(radius: 40, angle: 0), tapToClick: false, twoFingerScroll: false,
        reverseScrollDirection: false, sensitivity: 1, rotate: true,
        rawPositions: wide, touchDiagonal: testTouchDiagonal, now: 0.01)
    expectEqual(
        tracker.process(
            contacts: circleContacts(radius: 40, angle: 0.30), tapToClick: false, twoFingerScroll: false,
            reverseScrollDirection: false, sensitivity: 1, rotate: true,
            rawPositions: wide, touchDiagonal: testTouchDiagonal, now: 0.10),
        rotateOnly(0, phase: .began),
        "rotate must commit even when two-finger scroll is disabled")
}

private func rawContact(
    id: Int, major: Int?, minor: Int? = nil
) -> (id: Int, major: Int?, minor: Int?) {
    (id: id, major: major, minor: minor)
}

/// PTH-660 and PTH-860 share the same IntuosV2 touch report layout — the
/// registry's own touchMaxX/Y for PTH-660 are estimated from PTH-860's
/// confirmed values — so both PIDs go through the calibrated palm filter.
private func testPalmRejectionOnCalibratedFamily() {
    for productID in [0x0357, 0x0358] {
        var rejector = TouchPalmRejector()

        let initial = rejector.filter(
            contacts: [rawContact(id: 1, major: 6, minor: 7), rawContact(id: 2, major: 2, minor: 3)],
            productID: productID)
        expectEqual(initial.acceptedIDs, Set([2]),
                    "a palm must be dropped while a simultaneous finger remains usable")
        expectEqual(initial.newlyRejectedIDs, [1],
                    "the live palm-sized contact must be classified as a palm")

        let stillRejected = rejector.filter(
            contacts: [rawContact(id: 1, major: 4, minor: 4), rawContact(id: 2, major: 2, minor: 3)],
            productID: productID)
        expectEqual(stillRejected.acceptedIDs, Set([2]),
                    "hysteresis must keep a palm rejected between thresholds")

        let accepted = rejector.filter(
            contacts: [rawContact(id: 1, major: 3, minor: 3)], productID: productID)
        expectEqual(accepted.acceptedIDs, Set([1]),
                    "a contact below the lower threshold can return as a finger")
        expectEqual(accepted.newlyAcceptedIDs, [1],
                    "the hysteresis release must be observable for logging")
    }
}

private func testPalmFilteringIsFamilySpecific() {
    var rejector = TouchPalmRejector()
    let result = rejector.filter(
        contacts: [rawContact(id: 1, major: 41)], productID: 0x0317)
    expectEqual(result.acceptedIDs, Set([1]),
                "un-calibrated tablet families must keep their contacts unchanged")
}

/// A brief, stationary two-finger touch counts as one Smart Zoom tap; two of
/// them close together in time trigger the double-tap.
private func testSmartZoomDoubleTap() {
    var tracker = TouchStateTracker()
    _ = process(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = process(&tracker, contacts(distance: 20), at: 0.02)
    expectEqual(process(&tracker, [], at: 0.10), .none,
                "a lone two-finger tap must not fire Smart Zoom by itself")
    _ = process(&tracker, [(id: 3, screen: .zero)], at: 0.20)
    _ = process(&tracker, contacts(distance: 20), at: 0.22)
    expectEqual(process(&tracker, [], at: 0.28), .smartZoom,
                "a second two-finger tap within the gap must fire Smart Zoom")
}

private func testSmartZoomRequiresGap() {
    var tracker = TouchStateTracker()
    _ = process(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = process(&tracker, contacts(distance: 20), at: 0.02)
    _ = process(&tracker, [], at: 0.10)
    _ = process(&tracker, [(id: 3, screen: .zero)], at: 1.0)
    _ = process(&tracker, contacts(distance: 20), at: 1.02)
    expectEqual(process(&tracker, [], at: 1.08), .none,
                "a second tap outside the gap must not fire Smart Zoom")
}

private func testSmartZoomRequiresBriefHold() {
    var tracker = TouchStateTracker()
    _ = process(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = process(&tracker, contacts(distance: 20), at: 0.02)
    expectEqual(process(&tracker, [], at: 1.0), .none,
                "a held two-finger contact must not count as a Smart Zoom tap")
    _ = process(&tracker, [(id: 3, screen: .zero)], at: 1.10)
    _ = process(&tracker, contacts(distance: 20), at: 1.12)
    expectEqual(process(&tracker, [], at: 1.18), .none,
                "a held contact followed by a real tap must not retroactively pair into Smart Zoom")
}

/// Wide-apart two fingers swiveling about their centroid, with raw
/// separation clearing the eligibility gate, must resolve `.rotate` — the
/// full envelope: a dwell-gated silent commit, a nonzero `.changed` with the
/// corrected sign, then `.ended` on lift.
private func testRotateWideSwivelResolvesRotate() {
    var tracker = TouchStateTracker()
    let wide = rawPositions(distance: 700)  // ≈17% of testTouchDiagonal, clears the 15% gate
    _ = rprocess(&tracker, [(id: 1, screen: .zero)], rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0)
    _ = rprocess(&tracker, circleContacts(radius: 40, angle: 0), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.01)
    // Cumulative angle already clears `decide` here (0.15 rad * 40 = 6.0),
    // but elapsed time since escalation (0.04s) has not yet cleared
    // `rotateMinDwell` (0.07s), and neither translation nor scale change is
    // large enough to bypass the wait — must still be undecided.
    expectEqual(
        rprocess(&tracker, circleContacts(radius: 40, angle: 0.15), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.05),
        .none,
        "a rotate-eligible sequence must not commit before its dwell window elapses")
    // Elapsed time is now past the dwell window.
    expectEqual(
        rprocess(&tracker, circleContacts(radius: 40, angle: 0.30), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.10),
        rotateOnly(0, phase: .began),
        "a wide two-finger swivel clearing both the decide threshold and the dwell window must commit to rotate")
    let changed = rprocess(&tracker, circleContacts(radius: 40, angle: 0.50), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.12)
    expectRotateChanged(changed, "continued swiveling must emit a nonzero rotate delta")
    // `circleContacts`' angle increased (raw atan2 terms, i.e. counter-
    // clockwise in math convention) — screen coordinates are y-down, which
    // hardware testing 2026-08-08 confirmed flips the perceived direction,
    // so the emitted, corrected value must be negative here.
    if case let .twoFingerGesture(_, .some(rotate)) = changed {
        expectEqual(rotate.value < 0, true, "an increasing raw angle must emit a negative (sign-corrected) rotation")
    }
    expectEqual(
        rprocess(&tracker, [], rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.13),
        rotateOnly(0, phase: .ended),
        "lifting fingers must close the rotate envelope, not a stray scroll end")
}

/// A real pinch with some incidental angle wobble, wide enough apart for
/// rotate to be geometrically eligible, must still resolve pinch-only — the
/// regression `companionSuppressionRatio` exists to prevent (scale change
/// 30 vs tangential motion 11 here, ratio 0.37, below the 0.5 suppression
/// bar). Scale change here is well past `rotateDwellBypassDistance`, so this
/// also exercises the dwell bypass for a fast, obvious gesture.
private func testRotateEnabledDoesNotRegressPinch() {
    var tracker = TouchStateTracker()
    let wide = rawPositions(distance: 700)
    func tilted(distance: Double, tilt: Double) -> [(id: Int, screen: CGPoint)] {
        let half = distance / 2
        let d = CGPoint(x: half * cos(tilt), y: half * sin(tilt))
        return [(id: 1, screen: CGPoint(x: -d.x, y: -d.y)), (id: 2, screen: d)]
    }
    _ = rprocess(&tracker, [(id: 1, screen: .zero)], rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0)
    _ = rprocess(&tracker, tilted(distance: 80, tilt: 0.05), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.01)
    expectEqual(
        rprocess(&tracker, tilted(distance: 110, tilt: 0.25), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.02),
        magnify(0, phase: .began),
        "a real pinch with incidental twist wobble must still resolve pinch-only when rotate is enabled")
}

/// The actual point of the redesign: comparable spread and twist at once
/// must commit to *both* — a real trackpad's "magnify and rotate together"
/// case, which the old exclusive design couldn't represent at all. Scale
/// change 30 vs tangential motion 16.5 (ratio 0.55) both clear their own
/// floor and sit above `companionSuppressionRatio`, so neither suppresses
/// the other.
private func testConcurrentPinchAndRotate() {
    var tracker = TouchStateTracker()
    let wide = rawPositions(distance: 700)
    func spreadAndTwist(distance: Double, tilt: Double) -> [(id: Int, screen: CGPoint)] {
        let half = distance / 2
        let d = CGPoint(x: half * cos(tilt), y: half * sin(tilt))
        return [(id: 1, screen: CGPoint(x: -d.x, y: -d.y)), (id: 2, screen: d)]
    }
    _ = rprocess(&tracker, [(id: 1, screen: .zero)], rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0)
    _ = rprocess(&tracker, spreadAndTwist(distance: 80, tilt: 0), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.01)
    // Past the dwell window (elapsed 0.09s), so this tests the qualify/
    // suppression math, not the dwell gate.
    expectEqual(
        rprocess(&tracker, spreadAndTwist(distance: 110, tilt: 0.3), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.10),
        .twoFingerGesture(
            magnify: TouchStateTracker.GestureDelta(value: 0, phase: .began),
            rotate: TouchStateTracker.GestureDelta(value: 0, phase: .began)),
        "comparable spread and twist must commit to both pinch and rotate at once")
    let changed = rprocess(&tracker, spreadAndTwist(distance: 130, tilt: 0.5), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.11)
    guard case let .twoFingerGesture(magnify, rotate) = changed else {
        failures += 1; checks += 1
        FileHandle.standardError.write(Data("FAIL: expected a concurrent twoFingerGesture, got \(changed)\n".utf8))
        return
    }
    checks += 1
    if magnify == nil || rotate == nil {
        failures += 1
        FileHandle.standardError.write(Data("FAIL: continued concurrent motion must report both components, got magnify=\(String(describing: magnify)) rotate=\(String(describing: rotate))\n".utf8))
    }
    expectEqual(
        rprocess(&tracker, [], rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.12),
        .twoFingerGesture(
            magnify: TouchStateTracker.GestureDelta(value: 0, phase: .ended),
            rotate: TouchStateTracker.GestureDelta(value: 0, phase: .ended)),
        "lifting fingers must close both envelopes at once")
}

/// A wide, diagonally-held pair translating together (the thumb-and-index
/// posture people actually scroll with) must still resolve pan, even though
/// it's geometrically rotate-eligible — orientation alone isn't the gate,
/// motion shape is. Translation here is well past `rotateDwellBypassDistance`.
private func testRotateEnabledDoesNotRegressDiagonalPan() {
    var tracker = TouchStateTracker()
    let wide = rawPositions(distance: 700)
    func diagonalPair(offset: CGPoint) -> [(id: Int, screen: CGPoint)] {
        let d = CGPoint(x: 40 * cos(0.7), y: 40 * sin(0.7))
        return [(id: 1, screen: CGPoint(x: offset.x - d.x, y: offset.y - d.y)),
                (id: 2, screen: CGPoint(x: offset.x + d.x, y: offset.y + d.y))]
    }
    _ = rprocess(&tracker, [(id: 1, screen: .zero)], rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0)
    _ = rprocess(&tracker, diagonalPair(offset: .zero), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.01)
    expectEqual(
        rprocess(&tracker, diagonalPair(offset: CGPoint(x: 20, y: 20)), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.02),
        .scrollDelta(dx: 0, dy: 0, phase: .began),
        "a wide diagonal pair translating together must resolve pan, not rotate")
}

/// Close-together two fingers (raw separation below the eligibility gate)
/// sweeping together in one direction must resolve pan, even with rotate
/// enabled — the gate, not the dominance math, is what's doing the work here.
private func testRotateCloseTogetherSweepResolvesPan() {
    var tracker = TouchStateTracker()
    let narrow = rawPositions(distance: 100)  // ≈2.4% of testTouchDiagonal, well under the 15% gate
    func sweep(offset: Double) -> [(id: Int, screen: CGPoint)] {
        [(id: 1, screen: CGPoint(x: offset, y: 0)), (id: 2, screen: CGPoint(x: offset + 80, y: 0))]
    }
    _ = rprocess(&tracker, [(id: 1, screen: .zero)], rawPositions: narrow, touchDiagonal: testTouchDiagonal, at: 0)
    _ = rprocess(&tracker, sweep(offset: 0), rawPositions: narrow, touchDiagonal: testTouchDiagonal, at: 0.01)
    expectEqual(
        rprocess(&tracker, sweep(offset: 20), rawPositions: narrow, touchDiagonal: testTouchDiagonal, at: 0.03),
        .scrollDelta(dx: 0, dy: 0, phase: .began),
        "a close-together sweep below the separation gate must resolve pan, never rotate")
}

/// One finger anchored, the other arcing around it — real translation *and*
/// real angle change at once, magnitudes deliberately kept comparable so
/// neither dominates. Subordination rule in action: pan wins. A real user
/// rotating this way gets pan instead of rotate; documented limitation.
private func testRotateAnchoredArcResolvesPan() {
    var tracker = TouchStateTracker()
    let wide = rawPositions(distance: 700)
    let anchor = CGPoint(x: 100, y: 100)
    _ = rprocess(&tracker, [(id: 1, screen: .zero)], rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0)
    _ = rprocess(&tracker, anchoredArcContacts(anchor: anchor, radius: 40, angle: 0), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.01)
    // Past the dwell window (elapsed 0.09s) so the outcome tests the
    // dominance math, not the dwell gate.
    expectEqual(
        rprocess(&tracker, anchoredArcContacts(anchor: anchor, radius: 40, angle: 0.5), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.10),
        .scrollDelta(dx: 0, dy: 0, phase: .began),
        "an anchored-finger arc must resolve pan — translation and rotation are too close to call")
}

/// A plain pan (no pinch/rotate/smartZoom, so `twoFingerKind` commits to
/// `.pan` immediately) that drops to one contact keeps scrolling only until
/// `scrollSingleContactGrace` elapses, then emits a single `.ended` and goes
/// quiet — a lingering single finger, or a later unrelated one-finger touch,
/// must not keep scrolling the view.
private func panProcess(
    _ tracker: inout TouchStateTracker,
    _ contacts: [(id: Int, screen: CGPoint)],
    at time: CFAbsoluteTime
) -> TouchStateTracker.Intent {
    tracker.process(
        contacts: contacts, tapToClick: false, twoFingerScroll: true,
        reverseScrollDirection: false, sensitivity: 1, now: time)
}

private func testPanDropToOneContactWindsDownAfterGrace() {
    var tracker = TouchStateTracker()
    _ = panProcess(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = panProcess(&tracker, sweepPan(offset: 0), at: 0.01)
    // Commit the pan with real translation.
    _ = panProcess(&tracker, sweepPan(offset: 20), at: 0.02)
    _ = panProcess(&tracker, sweepPan(offset: 40), at: 0.03)
    // One finger lifts at 0.05 (drop recorded here). Inside the grace window:
    // no scroll from the lone finger.
    expectEqual(
        panProcess(&tracker, [(id: 1, screen: CGPoint(x: 100, y: 0))], at: 0.05),
        .none,
        "a lone finger inside the grace window must not scroll")
    // Past the grace window (>= 0.1s since the drop at 0.05): close the envelope.
    expectEqual(
        panProcess(&tracker, [(id: 1, screen: CGPoint(x: 160, y: 0))], at: 0.16),
        .scrollDelta(dx: 0, dy: 0, phase: .ended),
        "the pan must wind down with a single .ended once the grace elapses")
    // Still one finger, still moving — must stay silent (no resurrection).
    expectEqual(
        panProcess(&tracker, [(id: 1, screen: CGPoint(x: 220, y: 0))], at: 0.18),
        .none,
        "a wound-down scroll must not resume from a lingering finger")
    // A fresh unrelated single-finger touch after full lift is a pointer move,
    // not a scroll.
    _ = panProcess(&tracker, [], at: 0.20)
    _ = panProcess(&tracker, [(id: 5, screen: CGPoint(x: 500, y: 500))], at: 1.0)
    _ = panProcess(&tracker, [(id: 5, screen: CGPoint(x: 505, y: 500))], at: 1.13)
    expectEqual(
        panProcess(&tracker, [(id: 5, screen: CGPoint(x: 510, y: 500))], at: 1.14),
        .pointerMove(dx: 5, dy: 0),
        "a new single-finger touch after wind-down moves the pointer, not scroll")
}

/// The lingering-finger flick must still coast: `releaseVelocity` is captured
/// at the 2→1 drop (samples still fresh), not recomputed at wind-down (by when
/// every sample is older than `peakVelocityWindow` and a recompute yields zero).
private func testPanWindDownPreservesReleaseVelocity() {
    var tracker = TouchStateTracker()
    _ = panProcess(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = panProcess(&tracker, sweepPan(offset: 0), at: 0.01)
    // Fast pan: 60 pts in 20ms per frame = 3000 pts/s.
    _ = panProcess(&tracker, sweepPan(offset: 60), at: 0.03)
    _ = panProcess(&tracker, sweepPan(offset: 120), at: 0.05)
    // Drop to one contact at 0.06 — snapshot happens here.
    _ = panProcess(&tracker, [(id: 1, screen: CGPoint(x: 100, y: 0))], at: 0.06)
    // Wind down past the grace window.
    _ = panProcess(&tracker, [(id: 1, screen: CGPoint(x: 100, y: 0))], at: 0.17)
    let v = tracker.releaseVelocity
    checks += 1
    if hypot(v.dx, v.dy) < 100 {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: wind-down lost the flick velocity — got \(v)\n".utf8))
    }
}

/// The wound-down hold must not depend on an all-fingers-lifted frame ever
/// arriving: a contact set that no longer overlaps the wound-down gesture
/// clears the hold and starts a fresh sequence.
private func testPanWindDownClearsWithoutEmptyFrame() {
    var tracker = TouchStateTracker()
    _ = panProcess(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = panProcess(&tracker, sweepPan(offset: 0), at: 0.01)
    _ = panProcess(&tracker, sweepPan(offset: 20), at: 0.02)
    _ = panProcess(&tracker, sweepPan(offset: 40), at: 0.03)
    _ = panProcess(&tracker, [(id: 1, screen: CGPoint(x: 20, y: 0))], at: 0.05)
    _ = panProcess(&tracker, [(id: 1, screen: CGPoint(x: 20, y: 0))], at: 0.16)  // wound down
    // No empty frame. A completely new contact id well past onsetDelay must
    // resume as a normal pointer move, proving the hold cleared.
    _ = panProcess(&tracker, [(id: 9, screen: CGPoint(x: 400, y: 400))], at: 0.30)
    _ = panProcess(&tracker, [(id: 9, screen: CGPoint(x: 405, y: 400))], at: 0.43)
    expectEqual(
        panProcess(&tracker, [(id: 9, screen: CGPoint(x: 410, y: 400))], at: 0.44),
        .pointerMove(dx: 5, dy: 0),
        "a new contact set must clear the wound-down hold without an empty frame")
}

/// A burst frame — one delivered microseconds after the previous, as a
/// Bluetooth batch flush does — must not seed the momentum velocity: `delta/dt`
/// on a sub-millisecond `dt` is 10–100× the real finger speed and `peak` is a
/// max, so an unfiltered burst sample makes the coast fly.
private func testBurstFrameDoesNotPoisonReleaseVelocity() {
    var tracker = TouchStateTracker()
    _ = panProcess(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = panProcess(&tracker, sweepPan(offset: 0), at: 0.01)
    // Steady, moderate pan: 20 pts per 10ms frame = 2000 pts/s.
    _ = panProcess(&tracker, sweepPan(offset: 20), at: 0.02)
    _ = panProcess(&tracker, sweepPan(offset: 40), at: 0.03)
    _ = panProcess(&tracker, sweepPan(offset: 60), at: 0.04)
    // A burst frame 100µs later carrying a big jump — dt below minVelocityDt.
    _ = panProcess(&tracker, sweepPan(offset: 150), at: 0.0401)
    // Lift immediately.
    _ = panProcess(&tracker, [], at: 0.045)
    let v = tracker.releaseVelocity
    let mag = hypot(v.dx, v.dy)
    checks += 1
    // The real pan was ~2000 pts/s; the burst frame would imply ~900000. Any
    // value near the real speed is fine; anything above a sane flick is the bug.
    if mag > 8000 {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: burst frame poisoned release velocity — got \(mag) pts/s\n".utf8))
    }
}

/// A Bluetooth delivery stall right before lift — frames stop arriving for
/// ~200 ms while the finger keeps flicking — must still coast. The plain
/// recency gate would see "no motion in 200 ms" and suppress it as a brake;
/// the gap-tolerant path recognises `frameGap ≈ motionGap` (both grew, so
/// frames stopped, not the finger) and seeds from the last good pre-stall
/// sample. This is the `project_bt_scroll_stuck_and_nocoast` bug B fix.
private func testDeliveryGapStillCoasts() {
    var tracker = TouchStateTracker()
    _ = panProcess(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = panProcess(&tracker, sweepPan(offset: 0), at: 0.01)
    // Fast flick: 60 pts / 20 ms = 3000 pts/s, sustained.
    _ = panProcess(&tracker, sweepPan(offset: 60), at: 0.03)
    _ = panProcess(&tracker, sweepPan(offset: 120), at: 0.05)
    _ = panProcess(&tracker, sweepPan(offset: 180), at: 0.07)
    // Delivery stall: next frame is the lift, 200 ms later. No frames in
    // between — frameGap and motionGap both ≈ 0.2s.
    _ = panProcess(&tracker, [], at: 0.27)
    let v = tracker.releaseVelocity
    checks += 1
    if hypot(v.dx, v.dy) < 1000 {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: a delivery-gap lift lost the coast — got \(v)\n".utf8))
    }
    checks += 1
    if !tracker.releaseSuppressedByRecency {
        // releaseSuppressedByRecency should be false here — the coast fired.
    } else {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: delivery gap still flagged as recency-suppressed\n".utf8))
    }
}

/// A *short* flick into a delivery stall: 3 frames of decelerating motion
/// (fast then easing), then a 200 ms stall, then lift. Under a peak-over-the-
/// widened-window seed this would pick the fastest early frame; the coast
/// should instead seed from the newest good sample — how fast the finger was
/// actually moving when reports stopped — which on a decelerating flick is
/// slower than the peak. Guards the delivery-gap branch's newest-non-zero
/// rule against regressing to `peak`.
private func testShortDeliveryGapSeedsFromNewestNotPeak() {
    var tracker = TouchStateTracker()
    _ = panProcess(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = panProcess(&tracker, sweepPan(offset: 0), at: 0.01)
    // Frame 1: 90 pts / 15 ms = 6000 pts/s (the peak).
    _ = panProcess(&tracker, sweepPan(offset: 90), at: 0.025)
    // Frame 2: 45 pts / 15 ms = 3000 pts/s (easing).
    _ = panProcess(&tracker, sweepPan(offset: 135), at: 0.040)
    // Frame 3: 15 pts / 15 ms = 1000 pts/s (nearly stopped — the release speed).
    _ = panProcess(&tracker, sweepPan(offset: 150), at: 0.055)
    // 200 ms stall, then lift.
    _ = panProcess(&tracker, [], at: 0.255)
    let mag = hypot(tracker.releaseVelocity.dx, tracker.releaseVelocity.dy)
    checks += 1
    // It must still coast (not zero), but seeded from ~1000, not the ~6000
    // peak. Anything at/above the peak means it regressed to max-over-window.
    if mag < 200 || mag > 3500 {
        failures += 1
        let msg = "FAIL: short delivery-gap flick seeded wrong — got \(mag) pts/s "
            + "(want ~1000, the newest sample, not ~6000 the peak)\n"
        FileHandle.standardError.write(Data(msg.utf8))
    }
}

/// A deliberate brake — fingers held still on the surface for 200 ms, frames
/// still arriving the whole time — must still suppress the coast. Here only
/// `motionGap` grows; `frameGap` stays at the frame cadence, so the
/// gap-tolerant path does not fire and the recency gate zeroes the velocity.
private func testDeliberateBrakeStillSuppresses() {
    var tracker = TouchStateTracker()
    _ = panProcess(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = panProcess(&tracker, sweepPan(offset: 0), at: 0.01)
    _ = panProcess(&tracker, sweepPan(offset: 60), at: 0.03)
    _ = panProcess(&tracker, sweepPan(offset: 120), at: 0.05)
    // Fingers stop but stay down — frames keep coming at ~15 ms cadence,
    // same position, for 200 ms.
    var t = 0.065
    while t < 0.25 {
        _ = panProcess(&tracker, sweepPan(offset: 120), at: t)
        t += 0.015
    }
    _ = panProcess(&tracker, [], at: 0.26)
    let v = tracker.releaseVelocity
    checks += 1
    if hypot(v.dx, v.dy) > 1 {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: a deliberate brake still coasted — got \(v)\n".utf8))
    }
}

/// A gap longer than `releaseGapPlausibleMax` (1 s) — the ~1 Hz Bluetooth
/// housekeeping event, or true inter-gesture idle — must NOT be treated as a
/// recoverable delivery stall: `frameGap` reads -1 there, so `deliveryGap`
/// is false and the normal recency gate applies.
private func testTooLongGapDoesNotCoast() {
    var tracker = TouchStateTracker()
    _ = panProcess(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = panProcess(&tracker, sweepPan(offset: 0), at: 0.01)
    _ = panProcess(&tracker, sweepPan(offset: 60), at: 0.03)
    _ = panProcess(&tracker, sweepPan(offset: 120), at: 0.05)
    // Lift 1.4 s later — past releaseGapPlausibleMax.
    _ = panProcess(&tracker, [], at: 1.45)
    let v = tracker.releaseVelocity
    checks += 1
    if hypot(v.dx, v.dy) > 1 {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: a >1s gap was treated as a recoverable stall — got \(v)\n".utf8))
    }
}

/// Backstop clear (same finger still down past `scrollWoundDownBackstop`) must
/// resume as a plain pointer, never re-arm the tap clock — otherwise
/// pan → lift-one → rest → lift fires a phantom click with tap-to-click on.
private func testPanWindDownBackstopDoesNotFireTap() {
    var tracker = TouchStateTracker()
    let tapProc: (inout TouchStateTracker, [(id: Int, screen: CGPoint)], CFAbsoluteTime)
        -> TouchStateTracker.Intent = { t, c, time in
            t.process(
                contacts: c, tapToClick: true, twoFingerScroll: true,
                reverseScrollDirection: false, sensitivity: 1, now: time)
        }
    _ = tapProc(&tracker, [(id: 1, screen: .zero)], 0)
    _ = tapProc(&tracker, sweepPan(offset: 0), 0.01)
    _ = tapProc(&tracker, sweepPan(offset: 20), 0.02)
    _ = tapProc(&tracker, sweepPan(offset: 40), 0.03)
    // Finger 2 lifts at 0.05; wind down at 0.16.
    _ = tapProc(&tracker, [(id: 1, screen: CGPoint(x: 20, y: 0))], 0.05)
    _ = tapProc(&tracker, [(id: 1, screen: CGPoint(x: 20, y: 0))], 0.16)
    // Same finger held way past the 2s backstop, then lifted.
    _ = tapProc(&tracker, [(id: 1, screen: CGPoint(x: 20, y: 0))], 2.5)
    expectEqual(
        tapProc(&tracker, [], 2.6),
        .none,
        "a lingering finger released after the backstop must not fire a tap click")
}

/// A momentary one-contact frame (palm filter churn) shorter than the grace
/// window must not wind the pan down — the second finger returning resumes the
/// scroll cleanly.
private func testPanBriefOneContactFrameDoesNotWindDown() {
    var tracker = TouchStateTracker()
    _ = panProcess(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = panProcess(&tracker, sweepPan(offset: 0), at: 0.01)
    _ = panProcess(&tracker, sweepPan(offset: 20), at: 0.02)
    _ = panProcess(&tracker, sweepPan(offset: 40), at: 0.03)
    // One frame with a single contact, well inside the grace window.
    _ = panProcess(&tracker, [(id: 1, screen: CGPoint(x: 20, y: 0))], at: 0.04)
    // Second finger back; pan continues (a Changed scroll, not an Ended).
    guard case .scrollDelta(_, _, .changed) =
        panProcess(&tracker, sweepPan(offset: 60), at: 0.05)
    else {
        failures += 1
        checks += 1
        FileHandle.standardError.write(
            Data("FAIL: a brief 1-contact frame must not wind the pan down\n".utf8))
        return
    }
    checks += 1
}

// MARK: - Dominant-axis lock (committed .pan)

/// Two fingers 40pt apart, both translated `(dx, dy)` from origin — a
/// straight sweep in an arbitrary direction, for the axis-lock tests.
private func sweep(dx: Double, dy: Double) -> [(id: Int, screen: CGPoint)] {
    [(id: 1, screen: CGPoint(x: dx - 20, y: dy)),
     (id: 2, screen: CGPoint(x: dx + 20, y: dy))]
}

/// A near-vertical two-finger scroll (tiny horizontal drift) must lock to the
/// vertical axis and zero the horizontal component for the rest of the
/// gesture — the failure mode is that drift bleeding into a phase-free stream
/// and being swallowed by a nested column view.
private func testNearVerticalScrollLocksOutHorizontalDrift() {
    // Commit the pan, then keep sweeping down with a small +x drift each frame.
    let frames: [(t: CFAbsoluteTime, c: [(id: Int, screen: CGPoint)])] = [
        (0, [(id: 1, screen: .zero)]),
        (0.01, sweep(dx: 0, dy: 0)),
        (0.02, sweep(dx: 1, dy: 12)),   // commit — mostly vertical
        (0.03, sweep(dx: 2, dy: 24)),
        (0.04, sweep(dx: 3, dy: 36)),
        (0.05, sweep(dx: 4, dy: 48)),
        (0.06, sweep(dx: 5, dy: 60)),
    ]
    var tracker = TouchStateTracker()
    var sawLock = false
    for (i, f) in frames.enumerated() {
        let intent = panProcess(&tracker, f.c, at: f.t)
        // After the lock window (26pt+ of travel by ~frame 4), horizontal
        // must be exactly zero even though the fingers keep drifting +x.
        if i >= 5, case let .scrollDelta(dx, _, _) = intent {
            sawLock = true
            expectEqual(dx, 0.0,
                "near-vertical scroll must zero horizontal drift once axis-locked")
        }
    }
    checks += 1
    if !sawLock {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: near-vertical scroll never produced a post-lock scroll frame\n".utf8))
    }
}

/// Symmetric: a near-horizontal scroll locks out vertical drift. This is the
/// case that was actually broken — horizontal column-view scroll swallowed
/// because it carried a vertical component.
private func testNearHorizontalScrollLocksOutVerticalDrift() {
    var tracker = TouchStateTracker()
    let frames: [(t: CFAbsoluteTime, c: [(id: Int, screen: CGPoint)])] = [
        (0, [(id: 1, screen: .zero)]),
        (0.01, sweep(dx: 0, dy: 0)),
        (0.02, sweep(dx: 12, dy: 1)),
        (0.03, sweep(dx: 24, dy: 2)),
        (0.04, sweep(dx: 36, dy: 3)),
        (0.05, sweep(dx: 48, dy: 4)),
        (0.06, sweep(dx: 60, dy: 5)),
    ]
    var sawLock = false
    for (i, f) in frames.enumerated() {
        let intent = panProcess(&tracker, f.c, at: f.t)
        if i >= 5, case let .scrollDelta(_, dy, _) = intent {
            sawLock = true
            expectEqual(dy, 0.0,
                "near-horizontal scroll must zero vertical drift once axis-locked")
        }
    }
    checks += 1
    if !sawLock {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: near-horizontal scroll never produced a post-lock scroll frame\n".utf8))
    }
}

/// A genuinely diagonal two-finger drag (roughly 45°, well inside the 2:1
/// ratio on both axes) must NOT lock — both components keep flowing, the way
/// a native Hand-tool free pan does. This is the regression the lock could
/// introduce.
private func testDiagonalScrollStaysOmnidirectional() {
    var tracker = TouchStateTracker()
    let frames: [(t: CFAbsoluteTime, c: [(id: Int, screen: CGPoint)])] = [
        (0, [(id: 1, screen: .zero)]),
        (0.01, sweep(dx: 0, dy: 0)),
        (0.02, sweep(dx: 10, dy: 10)),
        (0.03, sweep(dx: 20, dy: 20)),
        (0.04, sweep(dx: 30, dy: 30)),
        (0.05, sweep(dx: 40, dy: 40)),
        (0.06, sweep(dx: 50, dy: 50)),
        (0.07, sweep(dx: 60, dy: 60)),
    ]
    var checkedPostWindow = false
    for (i, f) in frames.enumerated() {
        let intent = panProcess(&tracker, f.c, at: f.t)
        if i >= 5, case let .scrollDelta(dx, dy, _) = intent {
            checkedPostWindow = true
            checks += 1
            if abs(dx) < 0.001 || abs(dy) < 0.001 {
                failures += 1
                FileHandle.standardError.write(
                    Data("FAIL: diagonal drag got pinned to one axis — got (\(dx), \(dy))\n".utf8))
            }
        }
    }
    checks += 1
    if !checkedPostWindow {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: diagonal drag never produced a post-window scroll frame\n".utf8))
    }
}

/// The unlocked prefix is bounded: a pure-vertical scroll's *first* few
/// frames (before the lock window fills) still pass horizontal through
/// unchanged — there just isn't any here, so the guarantee to check is that
/// the lock commits within `scrollAxisLockWindow` of travel, not that early
/// frames are altered.
private func testAxisLockCommitsWithinWindow() {
    var tracker = TouchStateTracker()
    _ = panProcess(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = panProcess(&tracker, sweep(dx: 0, dy: 0), at: 0.01)
    _ = panProcess(&tracker, sweep(dx: 0, dy: 10), at: 0.02)   // commit
    // ~20pt of vertical travel by now — well past scrollAxisLockWindow (8pt).
    // A frame with a large horizontal jump must have its dx zeroed by the lock.
    _ = panProcess(&tracker, sweep(dx: 0, dy: 20), at: 0.03)
    if case let .scrollDelta(dx, _, _) = panProcess(&tracker, sweep(dx: 40, dy: 30), at: 0.04) {
        expectEqual(dx, 0.0,
            "once past scrollAxisLockWindow of vertical travel, a horizontal jump must be zeroed")
    } else {
        checks += 1
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: expected a scroll frame after the lock window\n".utf8))
    }
}

/// A contact id swapping mid-stroke (finger re-landed, or palm filtering
/// churned the set) gives a frame with `current.count == 2` but only one
/// tracked contact. The lock decision skips such frames (`tracked.count >= 2`
/// guard) — this pins that an id swap in the pre-lock prefix doesn't disturb
/// an otherwise-clean near-vertical scroll's lock. The single-tracked-contact
/// centroid is consistent old-vs-new so it wouldn't inject a jump either way;
/// this is the only test that exercises churn through the lock path at all.
private func testAxisLockIgnoresContactChurnFrame() {
    var tracker = TouchStateTracker()
    _ = panProcess(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = panProcess(&tracker, sweep(dx: 0, dy: 0), at: 0.01)
    _ = panProcess(&tracker, sweep(dx: 0, dy: 6), at: 0.02)    // commit, mostly vertical
    _ = panProcess(&tracker, sweep(dx: 0, dy: 12), at: 0.03)
    // Churn frame: both fingers present but id 2 → id 3, positions unchanged.
    // `tracked` drops to {1}; centroid collapses toward x = -20.
    _ = panProcess(&tracker,
        [(id: 1, screen: CGPoint(x: -20, y: 12)), (id: 3, screen: CGPoint(x: 20, y: 12))],
        at: 0.04)
    // Continue the vertical sweep with the new id pair.
    _ = panProcess(&tracker,
        [(id: 1, screen: CGPoint(x: -20, y: 20)), (id: 3, screen: CGPoint(x: 20, y: 20))],
        at: 0.05)
    if case let .scrollDelta(dx, dy, _) = panProcess(&tracker,
        [(id: 1, screen: CGPoint(x: -18, y: 34)), (id: 3, screen: CGPoint(x: 22, y: 34))],
        at: 0.06)
    {
        // Locked vertical: the small +x drift is zeroed, dy flows.
        expectEqual(dx, 0.0,
            "a churn frame must not pin a near-vertical scroll to the horizontal axis")
        checks += 1
        if dy == 0.0 {
            failures += 1
            FileHandle.standardError.write(
                Data("FAIL: vertical component lost after churn frame\n".utf8))
        }
    } else {
        checks += 1
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: expected a scroll frame after the churn frame\n".utf8))
    }
}

// MARK: - Onset delay

/// Pin the shipped default. `touchOnsetDelayMs` (settings, no UI) defaults to
/// 40 ms and feeds this via `InjectionSnapshot`; the injector plumbing isn't
/// reachable from this harness, so this at least catches an accidental edit to
/// the constant the whole feature is calibrated around.
private func testOnsetDelayDefaultIsFortyMs() {
    expectEqual(TouchStateTracker.onsetDelay, 0.04,
                "shipped onsetDelay default must stay 40 ms unless deliberately retuned")
}

/// The onset window withholds *pointer motion*, not gesture escalation. A
/// second finger landing after the window has closed (sequence already in
/// `.pointer`) must still escalate to a scroll — the cost is only that the
/// first finger emitted a little cursor drift first, and that drift must stay
/// small.
private func testSecondFingerAfterOnsetStillEscalatesWithBoundedDrift() {
    var tracker = TouchStateTracker()
    // Finger 1 lands, then drifts slowly for longer than the 40 ms default
    // onset window — it is in `.pointer` by the time finger 2 arrives.
    _ = process(&tracker, [(id: 1, screen: .zero)], at: 0)
    var drift = 0.0
    for (i, t) in stride(from: 0.02, through: 0.10, by: 0.02).enumerated() {
        let x = Double(i + 1) * 3  // 3 pts/frame
        if case let .pointerMove(dx, _) = process(
            &tracker, [(id: 1, screen: CGPoint(x: x, y: 0))], at: t)
        {
            drift += abs(dx)
        }
    }
    checks += 1
    if drift > 20 {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: pre-escalation drift \(drift) pts exceeds bound\n".utf8))
    }
    // Second finger lands — must escalate (a Began scroll or a committed
    // gesture), not keep pointer-tracking finger 1.
    let escalated = process(
        &tracker,
        [(id: 1, screen: CGPoint(x: 15, y: 0)), (id: 2, screen: CGPoint(x: 55, y: 0))],
        at: 0.12)
    checks += 1
    switch escalated {
    case .scrollDelta, .twoFingerGesture, .none:
        // `.none` is fine here: an undecided two-finger sequence emits nothing
        // until it commits. What matters is the next frame producing a scroll.
        break
    default:
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: second finger after onset did not escalate — got \(escalated)\n".utf8))
    }
    // Translate both fingers far enough to commit the pan; the first committed
    // frame is a `.began`, subsequent ones `.changed`.
    _ = process(
        &tracker,
        [(id: 1, screen: CGPoint(x: 15, y: 40)), (id: 2, screen: CGPoint(x: 55, y: 40))],
        at: 0.14)
    if case .scrollDelta(_, _, .changed) = process(
        &tracker,
        [(id: 1, screen: CGPoint(x: 15, y: 80)), (id: 2, screen: CGPoint(x: 55, y: 80))],
        at: 0.16)
    {
        checks += 1
    } else {
        failures += 1
        checks += 1
        FileHandle.standardError.write(
            Data("FAIL: two-finger pan after onset did not scroll\n".utf8))
    }
}

/// A tap that lands and lifts entirely inside the onset window must still
/// register as a click.
private func testTapInsideOnsetWindowStillClicks() {
    var tracker = TouchStateTracker()
    _ = tracker.process(
        contacts: [(id: 1, screen: .zero)], tapToClick: true, twoFingerScroll: true,
        reverseScrollDirection: false, sensitivity: 1, now: 0)
    // Lift at 0.03 — inside the 40 ms window, negligible drift.
    expectEqual(
        tracker.process(
            contacts: [], tapToClick: true, twoFingerScroll: true,
            reverseScrollDirection: false, sensitivity: 1, now: 0.03),
        .tapClick,
        "a tap wholly inside the onset window must still click")
}

/// The `onsetDelay:` parameter overrides the static default: a value longer
/// than the default keeps the sequence silent past where the default would
/// have advanced it to `.pointer`.
private func testOnsetDelayParameterIsHonored() {
    var tracker = TouchStateTracker()
    let longDelay: CFAbsoluteTime = 0.20
    _ = tracker.process(
        contacts: [(id: 1, screen: .zero)], tapToClick: false, twoFingerScroll: true,
        reverseScrollDirection: false, sensitivity: 1, onsetDelay: longDelay, now: 0)
    // At 0.08 the default (0.04) would already be in `.pointer` and emit motion.
    expectEqual(
        tracker.process(
            contacts: [(id: 1, screen: CGPoint(x: 30, y: 0))], tapToClick: false,
            twoFingerScroll: true, reverseScrollDirection: false, sensitivity: 1,
            onsetDelay: longDelay, now: 0.08),
        .none,
        "a longer onsetDelay must keep the sequence silent past the default window")
    // The frame that crosses the delay flips to `.pointer` but emits nothing
    // (motion is measured from that anchor); the frame after it moves the
    // cursor.
    _ = tracker.process(
        contacts: [(id: 1, screen: CGPoint(x: 35, y: 0))], tapToClick: false,
        twoFingerScroll: true, reverseScrollDirection: false, sensitivity: 1,
        onsetDelay: longDelay, now: 0.22)
    if case .pointerMove = tracker.process(
        contacts: [(id: 1, screen: CGPoint(x: 40, y: 0))], tapToClick: false,
        twoFingerScroll: true, reverseScrollDirection: false, sensitivity: 1,
        onsetDelay: longDelay, now: 0.24)
    {
        checks += 1
    } else {
        failures += 1
        checks += 1
        FileHandle.standardError.write(
            Data("FAIL: motion did not resume after the custom onsetDelay elapsed\n".utf8))
    }
}

// MARK: - Tap stabilization

/// An omitted `tapStabilizationPt:` (every production call) must hold a
/// barely-moving finger past onset; an explicit `0` must restore passthrough.
/// Guards the shipped default and the `> 0` disable short-circuit.
private func testTapStabilizationShippedDefaultHoldsAndZeroDisables() {
    // Sanity: the constant the whole feature is calibrated around.
    checks += 1
    if TouchStateTracker.tapStabilizationPt <= 0 || TouchStateTracker.tapStabilizationPt > 4 {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: shipped tapStabilizationPt \(TouchStateTracker.tapStabilizationPt) outside the sane 0<x<=4 band\n".utf8))
    }

    // A finger that creeps ~0.2 pt/frame stays inside the ~1.5 pt default
    // tolerance well past the 40 ms onset (frame 6 reaches only 1.2 pt).
    // Omitted param — the production call shape.
    var held = TouchStateTracker()
    _ = held.process(
        contacts: [(id: 1, screen: .zero)], tapToClick: false, twoFingerScroll: true,
        reverseScrollDirection: false, sensitivity: 1, now: 0)
    for i in 1...6 {
        expectEqual(
            held.process(
                contacts: [(id: 1, screen: CGPoint(x: Double(i) * 0.2, y: 0))],
                tapToClick: false, twoFingerScroll: true, reverseScrollDirection: false,
                sensitivity: 1, now: Double(i) * 0.01),
            .none,
            "frame \(i): shipped default should still be holding a sub-tolerance creep")
    }

    // Explicit 0: same creep must move the cursor the frame after onset.
    var raw = TouchStateTracker()
    _ = raw.process(
        contacts: [(id: 1, screen: .zero)], tapToClick: false, twoFingerScroll: true,
        reverseScrollDirection: false, sensitivity: 1, tapStabilizationPt: 0, now: 0)
    _ = raw.process(  // 0.05 s: crosses onset, commits, emits nothing
        contacts: [(id: 1, screen: CGPoint(x: 0.3, y: 0))], tapToClick: false,
        twoFingerScroll: true, reverseScrollDirection: false, sensitivity: 1,
        tapStabilizationPt: 0, now: 0.05)
    checks += 1
    if case .pointerMove = raw.process(
        contacts: [(id: 1, screen: CGPoint(x: 0.6, y: 0))], tapToClick: false,
        twoFingerScroll: true, reverseScrollDirection: false, sensitivity: 1,
        tapStabilizationPt: 0, now: 0.06) {
        // ok
    } else {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: explicit tapStabilizationPt 0 did not restore raw passthrough\n".utf8))
    }
}

/// A stabilization hold keeps the sequence in `.pending`, so a second finger
/// landing must still escalate to scroll — rest one finger, drop the second to
/// scroll. Sibling test covers this only from `.pointer` (stab = 0).
private func testSecondFingerEscalatesWhileStabilizationHolds() {
    var tracker = TouchStateTracker()
    let stab = 8.0
    _ = tracker.process(
        contacts: [(id: 1, screen: .zero)], tapToClick: false, twoFingerScroll: true,
        reverseScrollDirection: false, sensitivity: 1, tapStabilizationPt: stab, now: 0)
    // Hold finger 1 nearly still, well past the 40 ms onset — it stays in
    // `.pending` because drift never leaves the 8 pt radius.
    for i in 1...10 {
        expectEqual(
            tracker.process(
                contacts: [(id: 1, screen: CGPoint(x: Double(i) * 0.3, y: 0))],
                tapToClick: false, twoFingerScroll: true, reverseScrollDirection: false,
                sensitivity: 1, tapStabilizationPt: stab, now: Double(i) * 0.008),
            .none,
            "frame \(i): held finger should stay silent")
    }
    // Finger 2 lands at 0.10 s.
    _ = tracker.process(
        contacts: [(id: 1, screen: CGPoint(x: 3, y: 0)), (id: 2, screen: CGPoint(x: 43, y: 0))],
        tapToClick: false, twoFingerScroll: true, reverseScrollDirection: false,
        sensitivity: 1, tapStabilizationPt: stab, now: 0.10)
    // Translate both fingers to commit the pan.
    _ = tracker.process(
        contacts: [(id: 1, screen: CGPoint(x: 3, y: 40)), (id: 2, screen: CGPoint(x: 43, y: 40))],
        tapToClick: false, twoFingerScroll: true, reverseScrollDirection: false,
        sensitivity: 1, tapStabilizationPt: stab, now: 0.12)
    let scrolled = tracker.process(
        contacts: [(id: 1, screen: CGPoint(x: 3, y: 80)), (id: 2, screen: CGPoint(x: 43, y: 80))],
        tapToClick: false, twoFingerScroll: true, reverseScrollDirection: false,
        sensitivity: 1, tapStabilizationPt: stab, now: 0.14)
    checks += 1
    if case .scrollDelta(_, _, .changed) = scrolled {
        // ok
    } else {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: second finger during stabilization hold did not escalate to scroll — got \(scrolled)\n".utf8))
    }
}

/// A finger held inside the tolerance stays pinned past onset; once it clears
/// the tolerance, the first motion frame carries only that frame's delta — no
/// catch-up jump spanning the held travel.
private func testTapStabilizationHoldsThenReleasesWithoutJump() {
    var tracker = TouchStateTracker()
    let stab = 6.0
    _ = tracker.process(
        contacts: [(id: 1, screen: .zero)], tapToClick: false, twoFingerScroll: true,
        reverseScrollDirection: false, sensitivity: 1,
        tapStabilizationPt: stab, now: 0)
    // Creep 1 pt/frame for 100 ms — past the 40 ms onset, but always inside
    // the 6 pt tolerance. Every frame must stay silent.
    for i in 1...12 {
        let t = Double(i) * 0.008
        expectEqual(
            tracker.process(
                contacts: [(id: 1, screen: CGPoint(x: Double(i) * 0.4, y: 0))],
                tapToClick: false, twoFingerScroll: true, reverseScrollDirection: false,
                sensitivity: 1, tapStabilizationPt: stab, now: t),
            .none,
            "frame \(i): cursor moved while still inside the stabilization radius")
    }
    // Now jump the finger to x = 10 (drift 10 > 6): this frame crosses the
    // tolerance and commits to `.pointer`, but — like the onset commit frame —
    // emits nothing itself.
    expectEqual(
        tracker.process(
            contacts: [(id: 1, screen: CGPoint(x: 10, y: 0))],
            tapToClick: false, twoFingerScroll: true, reverseScrollDirection: false,
            sensitivity: 1, tapStabilizationPt: stab, now: 0.104),
        .none,
        "the frame that crosses the tolerance should commit silently")
    // The next frame moves the cursor. Its delta must be ~this frame's travel
    // (2 pts, times gain), NOT the ~10 pts the finger covered since landing.
    let moved = tracker.process(
        contacts: [(id: 1, screen: CGPoint(x: 12, y: 0))],
        tapToClick: false, twoFingerScroll: true, reverseScrollDirection: false,
        sensitivity: 1, tapStabilizationPt: stab, now: 0.112)
    checks += 1
    if case let .pointerMove(dx, _) = moved {
        // 2 pt raw × low-speed gain (≥ 0.85) ⇒ well under 5; a catch-up jump
        // would be ≥ 10.
        if abs(dx) > 5 {
            failures += 1
            FileHandle.standardError.write(
                Data("FAIL: first post-release delta \(dx) looks like a catch-up jump\n".utf8))
        }
    } else {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: cursor did not resume after the tolerance was exceeded — got \(moved)\n".utf8))
    }
}

/// Absolute mode ignores `tapStabilizationPt`: it warps to the finger every
/// frame regardless, and the commit stays purely time-based.
private func testTapStabilizationDoesNotAffectAbsoluteMode() {
    var tracker = TouchStateTracker()
    let stab = 20.0
    // Land, then hold nearly still well past the onset window.
    _ = tracker.process(
        contacts: [(id: 1, screen: CGPoint(x: 100, y: 100))], tapToClick: false,
        twoFingerScroll: true, reverseScrollDirection: false, sensitivity: 1,
        absoluteTouch: true, tapStabilizationPt: stab, now: 0)
    // A tiny move at 0.10 (past onset). Absolute mode must warp to it, not
    // withhold it the way a stabilizing relative sequence would.
    let intent = tracker.process(
        contacts: [(id: 1, screen: CGPoint(x: 103, y: 100))], tapToClick: false,
        twoFingerScroll: true, reverseScrollDirection: false, sensitivity: 1,
        absoluteTouch: true, tapStabilizationPt: stab, now: 0.10)
    checks += 1
    if case .pointerWarp(let to) = intent, to == CGPoint(x: 103, y: 100) {
        // ok
    } else {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: absolute mode should warp to the finger regardless of tapStabilizationPt — got \(intent)\n".utf8))
    }
}

// MARK: - Late join (a component entering an already-committed gesture)

/// Fingers spread cleanly first (pinch commits alone), then twist. The twist
/// must join the gesture in progress rather than being locked out for the
/// rest of the sequence — the behaviour that made simultaneous zoom-and-
/// rotate nearly impossible to invoke before 2026-08-27.
private func testRotateJoinsACommittedPinch() {
    var tracker = TouchStateTracker()
    let wide = rawPositions(distance: 700)
    func pair(distance: Double, tilt: Double) -> [(id: Int, screen: CGPoint)] {
        let half = distance / 2
        let d = CGPoint(x: half * cos(tilt), y: half * sin(tilt))
        return [(id: 1, screen: CGPoint(x: -d.x, y: -d.y)), (id: 2, screen: d)]
    }
    _ = rprocess(&tracker, [(id: 1, screen: .zero)], rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0)
    _ = rprocess(&tracker, pair(distance: 80, tilt: 0), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.01)
    // Pure spread, no tilt: pinch alone commits.
    expectEqual(
        rprocess(&tracker, pair(distance: 130, tilt: 0), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.10),
        .twoFingerGesture(
            magnify: TouchStateTracker.GestureDelta(value: 0, phase: .began),
            rotate: nil),
        "a clean spread must commit to pinch alone")
    // Now twist, holding the spread. Tangential motion has to clear
    // `rotateNoiseFloor` and half the scale change (`companionSuppressionRatio`),
    // so this is a deliberate turn, not a wobble.
    var joined = false
    for (i, tilt) in [0.35, 0.7, 1.05, 1.4].enumerated() {
        let out = rprocess(
            &tracker, pair(distance: 130, tilt: tilt),
            rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.11 + 0.01 * Double(i))
        if case let .twoFingerGesture(_, r) = out, r?.phase == .began { joined = true; break }
    }
    checks += 1
    if !joined {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: a twist added to a committed pinch never joined the gesture\n".utf8))
    }
    // Latch-on only: rotate must still be live at teardown, so the lift closes
    // both envelopes rather than just the pinch's.
    expectEqual(
        rprocess(&tracker, [], rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.20),
        .twoFingerGesture(
            magnify: TouchStateTracker.GestureDelta(value: 0, phase: .ended),
            rotate: TouchStateTracker.GestureDelta(value: 0, phase: .ended)),
        "a joined component must stay in the gesture until the fingers lift")
}

/// The late-join test above must not mean *any* long pinch eventually grows a
/// rotate. A steady spread carrying only incidental angle wobble stays
/// pinch-only for the whole sequence — `companionSuppressionRatio` is what
/// separates the two cases, and this is its regression guard.
private func testSteadyPinchWithWobbleNeverJoinsRotate() {
    var tracker = TouchStateTracker()
    let wide = rawPositions(distance: 700)
    func pair(distance: Double, tilt: Double) -> [(id: Int, screen: CGPoint)] {
        let half = distance / 2
        let d = CGPoint(x: half * cos(tilt), y: half * sin(tilt))
        return [(id: 1, screen: CGPoint(x: -d.x, y: -d.y)), (id: 2, screen: d)]
    }
    _ = rprocess(&tracker, [(id: 1, screen: .zero)], rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0)
    _ = rprocess(&tracker, pair(distance: 80, tilt: 0), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.01)
    _ = rprocess(&tracker, pair(distance: 130, tilt: 0), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.10)
    // Keep spreading hard; tilt only jitters by ±0.02 rad.
    var sawRotate = false
    for i in 0..<20 {
        let tilt = (i % 2 == 0) ? 0.02 : -0.02
        let out = rprocess(
            &tracker, pair(distance: 140 + Double(i) * 10, tilt: tilt),
            rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.11 + 0.01 * Double(i))
        if case let .twoFingerGesture(_, r) = out, r != nil { sawRotate = true }
    }
    checks += 1
    if sawRotate {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: incidental angle wobble during a pinch spawned a rotate\n".utf8))
    }
}


/// The join bar must not climb with the gesture's own duration. A twist added
/// to a pinch that has already been running a long time has to join on about
/// the same amount of turn as one added right after commit — that's the whole
/// reason the late-join test measures a trailing window instead of the
/// commit's cumulative-since-origin totals (a since-origin version needed ~46°
/// here versus ~20° right after commit; probed 2026-08-27).
private func testRotateJoinsALongRunningPinch() {
    var tracker = TouchStateTracker()
    let wide = rawPositions(distance: 700)
    func pair(distance: Double, tilt: Double) -> [(id: Int, screen: CGPoint)] {
        let half = distance / 2
        let d = CGPoint(x: half * cos(tilt), y: half * sin(tilt))
        return [(id: 1, screen: CGPoint(x: -d.x, y: -d.y)), (id: 2, screen: d)]
    }
    _ = rprocess(&tracker, [(id: 1, screen: .zero)], rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0)
    _ = rprocess(&tracker, pair(distance: 80, tilt: 0), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.01)
    _ = rprocess(&tracker, pair(distance: 130, tilt: 0), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.10)
    // A long clean spread first: 130 -> 400 over 27 frames.
    var t = 0.11
    for i in 0..<27 {
        _ = rprocess(&tracker, pair(distance: 130 + Double(i) * 10, tilt: 0),
                     rawPositions: wide, touchDiagonal: testTouchDiagonal, at: t)
        t += 0.01
    }
    // Then a deliberate twist at a held separation.
    var joinTilt: Double?
    for i in 0..<40 {
        let tilt = Double(i + 1) * 0.05
        let out = rprocess(&tracker, pair(distance: 400, tilt: tilt),
                           rawPositions: wide, touchDiagonal: testTouchDiagonal, at: t)
        t += 0.01
        if case let .twoFingerGesture(_, r) = out, r?.phase == .began { joinTilt = tilt; break }
    }
    checks += 1
    // 0.6 rad ~= 34 degrees. Generous next to the ~0.45 measured, tight enough
    // to catch a regression back to since-origin totals (~0.8).
    guard let joinTilt, joinTilt <= 0.6 else {
        failures += 1
        FileHandle.standardError.write(Data(
            "FAIL: twist joining a long-running pinch needed \(joinTilt.map { String($0) } ?? "no join") rad; the bar is climbing with gesture duration\n".utf8))
        return
    }
}

/// The wobble guard's complement: a *monotonic* slow drift in finger angle
/// during a long pinch (as opposed to a cancelling jitter) must also not spawn
/// a rotate. Cumulative tracking would let this cross the noise floor on its
/// own given enough time; the trailing window plus companion suppression is
/// what keeps it out.
private func testMonotonicAngleDriftDuringPinchNeverJoinsRotate() {
    var tracker = TouchStateTracker()
    let wide = rawPositions(distance: 700)
    func pair(distance: Double, tilt: Double) -> [(id: Int, screen: CGPoint)] {
        let half = distance / 2
        let d = CGPoint(x: half * cos(tilt), y: half * sin(tilt))
        return [(id: 1, screen: CGPoint(x: -d.x, y: -d.y)), (id: 2, screen: d)]
    }
    _ = rprocess(&tracker, [(id: 1, screen: .zero)], rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0)
    _ = rprocess(&tracker, pair(distance: 80, tilt: 0), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.01)
    _ = rprocess(&tracker, pair(distance: 130, tilt: 0), rawPositions: wide, touchDiagonal: testTouchDiagonal, at: 0.10)
    var sawRotate = false
    var t = 0.11
    // Steady spread with a 0.15 deg/frame drift — 9 degrees total over 60
    // frames, the shape of a hand slowly rolling during a zoom.
    for i in 0..<60 {
        let out = rprocess(&tracker, pair(distance: 140 + Double(i) * 8, tilt: Double(i) * 0.0026),
                           rawPositions: wide, touchDiagonal: testTouchDiagonal, at: t)
        t += 0.01
        if case let .twoFingerGesture(_, r) = out, r != nil { sawRotate = true }
    }
    checks += 1
    if sawRotate {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: slow monotonic angle drift during a pinch spawned a rotate\n".utf8))
    }
}

/// Locks the shape of `pointerGain(forSpeed:)`: floor below the low knee,
/// flat through the midrange (where "1.00x" continues to mean what the
/// Cursor Speed caption says), ceiling above the high knee, and continuous
/// at both knees (no jump when crossing them).
private func testPointerGainCurveShape() {
    let low = TouchStateTracker.pointerGainLowSpeed
    let high = TouchStateTracker.pointerGainHighSpeed
    checks += 1
    if TouchStateTracker.pointerGain(forSpeed: 0) != TouchStateTracker.pointerGainFloor {
        failures += 1
        FileHandle.standardError.write(Data("FAIL: pointerGain(0) must equal the floor\n".utf8))
    }
    expectEqual(TouchStateTracker.pointerGain(forSpeed: 500), 1.0,
                "midrange speed must be flat, un-accelerated gain")
    expectEqual(TouchStateTracker.pointerGain(forSpeed: high + 2000), TouchStateTracker.pointerGainCeiling,
                "far past the high knee must clamp at the ceiling, not keep climbing")
    expectEqual(TouchStateTracker.pointerGain(forSpeed: low), 1.0,
                "exactly at the low knee must already read as flat")
    expectEqual(TouchStateTracker.pointerGain(forSpeed: high), 1.0,
                "exactly at the high knee must still read as flat")
}

/// A slow, deliberate drag (well under the low knee) must come out damped —
/// this is the whole point of the curve, and nothing else in this file
/// exercises a sub-knee speed.
private func testSlowDragIsDamped() {
    var tracker = TouchStateTracker()
    _ = process(&tracker, [(id: 1, screen: .zero)], at: 0)
    // Cross onsetDelay AND the tap-stabilization tolerance (default 1.5 pt),
    // then take one more frame so a prior `.pointer` speed sample exists for
    // the damping EMA to work from.
    _ = process(&tracker, [(id: 1, screen: CGPoint(x: 4, y: 0))], at: 0.14)  // commits, emits nothing
    _ = process(&tracker, [(id: 1, screen: CGPoint(x: 4.2, y: 0))], at: 0.15)  // first .pointer frame
    // 0.2 points per 20ms frame = 10 pts/s, well under pointerGainLowSpeed (30).
    guard case let .pointerMove(dx, _) = process(&tracker, [(id: 1, screen: CGPoint(x: 4.4, y: 0))], at: 0.16)
    else {
        failures += 1
        checks += 1
        FileHandle.standardError.write(Data("FAIL: expected a pointerMove\n".utf8))
        return
    }
    checks += 1
    if dx >= 0.2 {
        failures += 1
        FileHandle.standardError.write(
            Data("FAIL: slow drag was not damped — got dx=\(dx), expected < 0.2\n".utf8))
    }
}

/// The very first pointer-mode frame of a sequence has no prior sample to
/// measure speed from. It must not be treated as slow — that would damp
/// every fresh touch-and-drag's opening frame regardless of actual speed,
/// which is the general form of the bug the initial implementation had
/// (caught by three pre-existing tests expecting flat gain on their first
/// post-onset frame).
private func testFirstPointerFrameIsNotDamped() {
    var tracker = TouchStateTracker()
    _ = process(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = process(&tracker, [(id: 1, screen: CGPoint(x: 5, y: 0))], at: 0.14)  // crosses onsetDelay
    expectEqual(process(&tracker, [(id: 1, screen: CGPoint(x: 10, y: 0))], at: 0.15),
                .pointerMove(dx: 5, dy: 0),
                "the first .pointer-mode frame must use flat gain, not the low-speed floor")
}

/// In absolute mode, a single-finger touch must warp the cursor to the
/// finger's own screen position, not drag it by delta — no gain, no
/// smoothing, direct 1:1 mapping.
private func testAbsoluteTouchWarpsToPosition() {
    var tracker = TouchStateTracker()
    _ = processAbsolute(&tracker, [(id: 1, screen: CGPoint(x: 100, y: 200))], at: 0)
    expectEqual(
        processAbsolute(&tracker, [(id: 1, screen: CGPoint(x: 150, y: 220))], at: 0.14),
        .pointerWarp(to: CGPoint(x: 150, y: 220)),
        "absolute mode must warp directly to the contact's screen position")
}

/// A tap that lifts entirely inside the onset window (never reaching
/// `.pointer` mode) must still have warped the cursor to the tap's own
/// position, so `.tapClick`'s "click at the current cursor position"
/// resolves in the right place. This is the bug relative mode's own
/// zero-delta/emit-nothing-in-.pending behavior would cause if reused
/// as-is for absolute mode: the cursor would still be sitting wherever it
/// was before the tap.
private func testAbsoluteTapClicksAtTapPosition() {
    var tracker = TouchStateTracker()
    expectEqual(
        processAbsolute(&tracker, [(id: 1, screen: CGPoint(x: 300, y: 400))], at: 0),
        .pointerWarp(to: CGPoint(x: 300, y: 400)),
        "absolute mode must warp even in .pending, before onset elapses")
    // Lift at 0.03 — inside the 40ms onset window, never reaches .pointer.
    expectEqual(
        processAbsolute(&tracker, [], at: 0.03),
        .tapClick,
        "a tap wholly inside the onset window must still click, now that the cursor is at the right spot")
}

/// A still finger in absolute mode must warp once (so a motionless tap
/// still resolves at the right position — see
/// testAbsoluteTapClicksAtTapPosition) and then go silent, not re-warp to
/// the same position every frame. An unguarded repeat-warp would post
/// ~100 identical .mouseMoved CGEvents/sec for a finger just resting on
/// the tablet — the same class of waste the scroll case's dead-frame skip
/// exists to avoid.
private func testAbsoluteTouchDoesNotRewarpAMotionlessFinger() {
    var tracker = TouchStateTracker()
    expectEqual(
        processAbsolute(&tracker, [(id: 1, screen: CGPoint(x: 50, y: 60))], at: 0),
        .pointerWarp(to: CGPoint(x: 50, y: 60)),
        "the first frame of a sequence must always warp")
    // Crosses onsetDelay into .pointer, finger hasn't moved.
    expectEqual(
        processAbsolute(&tracker, [(id: 1, screen: CGPoint(x: 50, y: 60))], at: 0.14),
        .none,
        "a motionless finger must not re-warp to the position it's already at")
    expectEqual(
        processAbsolute(&tracker, [(id: 1, screen: CGPoint(x: 50, y: 60))], at: 0.20),
        .none,
        "repeated motionless frames must stay silent, not post a warp each time")
}

/// If the driving finger lifts while a second finger lingers (or contact
/// ids otherwise reorder), absolute mode must not re-derive "the" contact
/// from `.first` and teleport to it — the sequence stays pinned to
/// whichever contact id started it.
private func testAbsoluteTouchIgnoresContactAfterPrimaryLifts() {
    var tracker = TouchStateTracker()
    _ = processAbsolute(&tracker, [(id: 1, screen: CGPoint(x: 0, y: 0))], at: 0)
    _ = processAbsolute(&tracker, [(id: 1, screen: CGPoint(x: 10, y: 0))], at: 0.14)
    // id 1 (the primary) lifts; a different id 2 is now contacts.first.
    // Must not warp to id 2's position — the primary is gone, so no target.
    expectEqual(
        processAbsolute(&tracker, [(id: 2, screen: CGPoint(x: 900, y: 900))], at: 0.16),
        .none,
        "a non-primary contact surviving after the primary lifts must not steal the warp")
}

@main
enum TouchStateTrackerTestRunner {
    static func main() {
        testPinchMagnifyEnvelope()
        testPanDropToOneContactWindsDownAfterGrace()
        testPanBriefOneContactFrameDoesNotWindDown()
        testNearVerticalScrollLocksOutHorizontalDrift()
        testNearHorizontalScrollLocksOutVerticalDrift()
        testDiagonalScrollStaysOmnidirectional()
        testAxisLockCommitsWithinWindow()
        testAxisLockIgnoresContactChurnFrame()
        testPanWindDownPreservesReleaseVelocity()
        testPanWindDownClearsWithoutEmptyFrame()
        testPanWindDownBackstopDoesNotFireTap()
        testBurstFrameDoesNotPoisonReleaseVelocity()
        testDeliveryGapStillCoasts()
        testShortDeliveryGapSeedsFromNewestNotPeak()
        testDeliberateBrakeStillSuppresses()
        testTooLongGapDoesNotCoast()
        testPreCommitLiftHasNoScrollEnd()
        testSingleContactFrameDoesNotCommitPan()
        testNewTouchAfterLiftDoesNotJumpFromOldPosition()
        testTapResolvesImmediatelyOnLift()
        testPinchCommitsWithTwoFingerScrollDisabled()
        testPanStaysSilentWithTwoFingerScrollDisabled()
        testRotateCommitsWithTwoFingerScrollDisabled()
        testPalmRejectionOnCalibratedFamily()
        testPalmFilteringIsFamilySpecific()
        testSmartZoomDoubleTap()
        testSmartZoomRequiresGap()
        testSmartZoomRequiresBriefHold()
        testRotateWideSwivelResolvesRotate()
        testRotateCloseTogetherSweepResolvesPan()
        testRotateAnchoredArcResolvesPan()
        testRotateEnabledDoesNotRegressPinch()
        testRotateEnabledDoesNotRegressDiagonalPan()
        testConcurrentPinchAndRotate()
        testRotateJoinsACommittedPinch()
        testSteadyPinchWithWobbleNeverJoinsRotate()
        testRotateJoinsALongRunningPinch()
        testMonotonicAngleDriftDuringPinchNeverJoinsRotate()
        testOnsetDelayDefaultIsFortyMs()
        testSecondFingerAfterOnsetStillEscalatesWithBoundedDrift()
        testTapInsideOnsetWindowStillClicks()
        testOnsetDelayParameterIsHonored()
        testTapStabilizationShippedDefaultHoldsAndZeroDisables()
        testTapStabilizationHoldsThenReleasesWithoutJump()
        testTapStabilizationDoesNotAffectAbsoluteMode()
        testSecondFingerEscalatesWhileStabilizationHolds()
        testPointerGainCurveShape()
        testSlowDragIsDamped()
        testFirstPointerFrameIsNotDamped()
        testAbsoluteTouchWarpsToPosition()
        testAbsoluteTapClicksAtTapPosition()
        testAbsoluteTouchDoesNotRewarpAMotionlessFinger()
        testAbsoluteTouchIgnoresContactAfterPrimaryLifts()

        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        }
        FileHandle.standardError.write(Data("\(failures) of \(checks) checks failed\n".utf8))
        exit(1)
    }
}
