// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

// TouchStateTrackerTests.swift — Standalone checks for touch gesture intent.
//
// The app has no XCTest target, so these run as a small executable compiled
// against the real TouchStateTracker.swift. Run via
// tools/touch-state-tracker-tests/run.sh. Exits non-zero on the first failure.

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
        now: time
    )
}

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
                .zoomMagnify(magnification: 0, phase: .began),
                "distance-dominant motion commits to pinch and opens the envelope")
    expectEqual(process(&tracker, contacts(distance: 45), at: 0.03),
                .zoomMagnify(magnification: 15.0 / 30.0, phase: .changed),
                "spreading fingers emits the exact relative growth since last frame")
    expectEqual(process(&tracker, contacts(distance: 30), at: 0.04),
                .zoomMagnify(magnification: -15.0 / 45.0, phase: .changed),
                "closing fingers emits negative relative growth")
    expectEqual(process(&tracker, [], at: 0.05),
                .zoomMagnify(magnification: 0, phase: .ended),
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

@main
enum TouchStateTrackerTestRunner {
    static func main() {
        testPinchMagnifyEnvelope()
        testPreCommitLiftHasNoScrollEnd()
        testSingleContactFrameDoesNotCommitPan()
        testPalmRejectionOnCalibratedFamily()
        testPalmFilteringIsFamilySpecific()

        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        }
        FileHandle.standardError.write(Data("\(failures) of \(checks) checks failed\n".utf8))
        exit(1)
    }
}
