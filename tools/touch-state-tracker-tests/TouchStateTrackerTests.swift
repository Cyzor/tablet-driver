// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// TouchStateTrackerTests.swift — Standalone checks for touch gesture intent.
//
// The app has no XCTest target, so these run as a small executable compiled
// against the real TouchStateTracker.swift. Run via
// tools/touch-state-tracker-tests/run.sh. Exits non-zero on the first failure.

import Foundation
import TabletKit

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

private func rawContact(
    id: Int, major: Int?, minor: Int? = nil
) -> (id: Int, major: Int?, minor: Int?) {
    (id: id, major: major, minor: minor)
}

private func testPTH660PalmRejection() {
    var rejector = TouchPalmRejector()

    let initial = rejector.filter(
        contacts: [rawContact(id: 1, major: 6, minor: 7), rawContact(id: 2, major: 2, minor: 3)],
        productID: 0x0357)
    expectEqual(initial.acceptedIDs, Set([2]),
                "a palm must be dropped while a simultaneous finger remains usable")
    expectEqual(initial.newlyRejectedIDs, [1],
                "the live palm-sized PTH-660 contact must be classified as a palm")

    let stillRejected = rejector.filter(
        contacts: [rawContact(id: 1, major: 4, minor: 4), rawContact(id: 2, major: 2, minor: 3)],
        productID: 0x0357)
    expectEqual(stillRejected.acceptedIDs, Set([2]),
                "hysteresis must keep a palm rejected between thresholds")

    let accepted = rejector.filter(
        contacts: [rawContact(id: 1, major: 3, minor: 3)], productID: 0x0357)
    expectEqual(accepted.acceptedIDs, Set([1]),
                "a contact below the lower threshold can return as a finger")
    expectEqual(accepted.newlyAcceptedIDs, [1],
                "the hysteresis release must be observable for logging")
}

private func testPalmFilteringIsPTH660Specific() {
    var rejector = TouchPalmRejector()
    let result = rejector.filter(
        contacts: [rawContact(id: 1, major: 41)], productID: 0x0358)
    expectEqual(result.acceptedIDs, Set([1]),
                "un-calibrated tablet families must keep their contacts unchanged")
}

private func testPinchWheelDirection() {
    var tracker = TouchStateTracker()
    _ = process(&tracker, [(id: 1, screen: .zero)], at: 0)
    expectEqual(process(&tracker, contacts(distance: 20), at: 0.01), .none,
                "two-finger pinch waits for a decisive motion")
    expectEqual(process(&tracker, contacts(distance: 30), at: 0.02),
                .zoomDelta(dy: 0, phase: .began),
                "distance-dominant motion commits to pinch")
    expectEqual(process(&tracker, contacts(distance: 34), at: 0.03),
                .zoomDelta(dy: 4, phase: .changed),
                "spreading fingers emits positive Ctrl-wheel for zoom-in")
    expectEqual(process(&tracker, contacts(distance: 28), at: 0.04),
                .zoomDelta(dy: -6, phase: .changed),
                "closing fingers emits negative Ctrl-wheel for zoom-out")
}

private func testPreCommitLiftHasNoScrollEnd() {
    var tracker = TouchStateTracker()
    _ = process(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = process(&tracker, contacts(distance: 20), at: 0.01)
    expectEqual(process(&tracker, [], at: 0.02), .none,
                "a pinch that never commits must not emit a scroll end")
}

@main
enum TouchStateTrackerTestRunner {
    static func main() {
        testPinchWheelDirection()
        testPreCommitLiftHasNoScrollEnd()
        testPTH660PalmRejection()
        testPalmFilteringIsPTH660Specific()

        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        }
        FileHandle.standardError.write(Data("\(failures) of \(checks) checks failed\n".utf8))
        exit(1)
    }
}
