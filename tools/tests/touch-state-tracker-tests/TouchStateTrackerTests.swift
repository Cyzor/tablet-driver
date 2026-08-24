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

/// A dropped report mid-drag (e.g. a capacitive signal dropout) must not
/// discard the drag's position — the cursor should resume from where it
/// was, not jump/reset, once the finger reappears within the grace window.
private func testPointerDragBridgesShortDropout() {
    var tracker = TouchStateTracker()
    _ = process(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = process(&tracker, [(id: 1, screen: CGPoint(x: 20, y: 0))], at: 0.13)  // crosses onsetDelay
    _ = process(&tracker, [(id: 1, screen: CGPoint(x: 40, y: 0))], at: 0.14)
    expectEqual(process(&tracker, [], at: 0.15), .none,
                "a dropped report mid-drag must not be treated as a lift")
    expectEqual(process(&tracker, [(id: 1, screen: CGPoint(x: 50, y: 0))], at: 0.17),
                .pointerMove(dx: 10, dy: 0),
                "the drag resumes from its last known position, not the reappearance point")
}

/// If the finger really did lift, the bridge must not hold forever — once
/// the grace window elapses the sequence tears down and a later touch-down
/// starts fresh (re-arming the onset delay) instead of resuming.
private func testPointerDragTearsDownAfterGraceExpires() {
    var tracker = TouchStateTracker()
    _ = process(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = process(&tracker, [(id: 1, screen: CGPoint(x: 20, y: 0))], at: 0.13)
    _ = process(&tracker, [(id: 1, screen: CGPoint(x: 40, y: 0))], at: 0.14)
    _ = process(&tracker, [], at: 0.15)
    expectEqual(process(&tracker, [], at: 0.21), .none,
                "grace expiry with no reappearance just finalizes the lift silently")
    _ = process(&tracker, [(id: 2, screen: CGPoint(x: 40, y: 0))], at: 0.30)
    expectEqual(process(&tracker, [(id: 2, screen: CGPoint(x: 41, y: 0))], at: 0.31), .none,
                "a genuinely new sequence re-arms the onset delay instead of resuming")
}

/// The dropout bridge only holds a drag (past `tapMaxDistance`) — a tap that
/// happens to have already crossed into `.pointer` mode without real motion
/// must still resolve the instant it lifts.
private func testPointerModeTapNotDelayedByDropoutBridge() {
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

@main
enum TouchStateTrackerTestRunner {
    static func main() {
        testPinchMagnifyEnvelope()
        testPreCommitLiftHasNoScrollEnd()
        testSingleContactFrameDoesNotCommitPan()
        testPointerDragBridgesShortDropout()
        testPointerDragTearsDownAfterGraceExpires()
        testPointerModeTapNotDelayedByDropoutBridge()
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

        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        }
        FileHandle.standardError.write(Data("\(failures) of \(checks) checks failed\n".utf8))
        exit(1)
    }
}
