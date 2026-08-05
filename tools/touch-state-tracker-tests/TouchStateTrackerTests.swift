// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
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

private func testPinchZoomStepDirection() {
    var tracker = TouchStateTracker()
    _ = process(&tracker, [(id: 1, screen: .zero)], at: 0)
    expectEqual(process(&tracker, contacts(distance: 20), at: 0.01), .none,
                "two-finger pinch waits for a decisive motion")
    expectEqual(process(&tracker, contacts(distance: 30), at: 0.02), .none,
                "distance-dominant motion commits to pinch silently — no envelope to open")
    // pinchZoomStepDistance is 90 points; a 90-point spread crosses exactly one
    // step. Frames are spaced >= minZoomStepInterval apart so rate-limiting
    // doesn't interact with this test.
    expectEqual(process(&tracker, contacts(distance: 120), at: 0.20),
                .zoomStep(count: 1),
                "spreading fingers by a full step emits one ⌘+Keypad-Plus")
    expectEqual(process(&tracker, contacts(distance: 30), at: 0.40),
                .zoomStep(count: -1),
                "closing fingers by a full step emits one ⌘+Keypad-Minus")
}

/// A pinch that crosses a full step twice within `minZoomStepInterval` must
/// not double-fire — real menu-command zoom (Preview, Safari, browsers)
/// isn't built to absorb keystrokes at HID report rate, and hardware testing
/// without this cap showed a visible backlog draining after the pinch had
/// already stopped.
private func testZoomStepsAreRateLimited() {
    var tracker = TouchStateTracker()
    _ = process(&tracker, [(id: 1, screen: .zero)], at: 1.00)
    _ = process(&tracker, contacts(distance: 20), at: 1.01)
    expectEqual(process(&tracker, contacts(distance: 30), at: 1.02), .none,
                "distance-dominant motion commits to pinch silently")
    expectEqual(process(&tracker, contacts(distance: 120), at: 1.03),
                .zoomStep(count: 1),
                "first full step emits immediately")
    expectEqual(process(&tracker, contacts(distance: 210), at: 1.05),
                .none,
                "a second full step within minZoomStepInterval is rate-limited, not dropped")
    expectEqual(process(&tracker, contacts(distance: 210), at: 1.16),
                .zoomStep(count: 1),
                "the rate-limited step fires once the interval reopens, not as a double-fire")
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

/// A pinch that moves well under one `pinchZoomStepDistance` per frame must
/// still cross a whole step eventually — the remainder has to accumulate
/// across frames or a slow pinch never emits a keystroke at all.
private func testSlowPinchAccumulatesPartialSteps() {
    var tracker = TouchStateTracker()
    _ = process(&tracker, [(id: 1, screen: .zero)], at: 0)
    _ = process(&tracker, contacts(distance: 20), at: 0.01)
    expectEqual(process(&tracker, contacts(distance: 30), at: 0.02), .none,
                "distance-dominant motion commits to pinch silently")
    // Four frames of +22.5 pt (0.25 of a 90-pt step each), spaced well past
    // minZoomStepInterval so rate-limiting isn't a factor here: each alone
    // rounds to zero steps, together they cross one whole step on the fourth.
    for (i, d) in [52.5, 75.0, 97.5].enumerated() {
        expectEqual(process(&tracker, contacts(distance: d), at: 0.10 + 0.01 * Double(i)),
                    .none,
                    "partial-step pinch frame \(i) accumulates instead of emitting")
    }
    expectEqual(process(&tracker, contacts(distance: 120.0), at: 0.13),
                .zoomStep(count: 1),
                "accumulated partial-step pinch motion emits one whole zoom step")
}

@main
enum TouchStateTrackerTestRunner {
    static func main() {
        testPinchZoomStepDirection()
        testZoomStepsAreRateLimited()
        testPreCommitLiftHasNoScrollEnd()
        testSingleContactFrameDoesNotCommitPan()
        testSlowPinchAccumulatesPartialSteps()

        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        }
        FileHandle.standardError.write(Data("\(failures) of \(checks) checks failed\n".utf8))
        exit(1)
    }
}
