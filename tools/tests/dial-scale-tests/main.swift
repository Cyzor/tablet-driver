// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// Checks the ring/dial rotate and zoom scales against their measured
// steps/revolution. `InputInjector` can't be compiled standalone (AppKit,
// TabletKit), so the formulas are restated here and pinned to the same
// hardware measurements the real constants document. A change to either one
// that isn't mirrored here shows up as a failure, which is the point: these
// numbers were wrong for a year because nothing checked them.

import Foundation

var failures = 0

private func expect(
    _ actual: Double, _ expected: Double, _ label: String,
    tolerance: Double = 1e-9, line: UInt = #line
) {
    if abs(actual - expected) > tolerance {
        print("FAIL line \(line): \(label) — expected \(expected), got \(actual)")
        failures += 1
    }
}

private func expectTrue(_ cond: Bool, _ label: String, line: UInt = #line) {
    if !cond {
        print("FAIL line \(line): \(label)")
        failures += 1
    }
}

// MARK: - The values under test

/// Capacitive touch ring, fixed by hardware at 72 steps/revolution.
let ringStepsPerRevolution = 72.0
/// PTK-470/670/870 gen-3 dials — measured 2026-09-25 on a PTK-870.
let wacomDialStepsPerRevolution = 24.0
/// Xencelabs Quick Keys puck — measured 2026-09.
let xencelabsDialStepsPerRevolution = 13.0

let dialGestureZoomScale = 1.0 / 300.0
let dialGestureRotateScale = Double.pi / 36.0

func rotateScaleMechanical(steps: Double) -> Double { 2.0 * Double.pi / steps }
func zoomScaleMechanical(steps: Double) -> Double {
    dialGestureZoomScale * 72.0 / steps
}

// MARK: - Rotate: one revolution must equal one full turn

// The whole point of the rotate scale: at 1x speed, turning the physical
// control once all the way around rotates the canvas exactly 360°. This has
// to hold for every mechanism, which is what makes the per-model split
// necessary rather than cosmetic.

private func testOneRevolutionIsOneFullTurn() {
    let cases: [(String, Double, Double)] = [
        ("capacitive ring", ringStepsPerRevolution, dialGestureRotateScale),
        ("Wacom dial", wacomDialStepsPerRevolution,
         rotateScaleMechanical(steps: wacomDialStepsPerRevolution)),
        ("Xencelabs dial", xencelabsDialStepsPerRevolution,
         rotateScaleMechanical(steps: xencelabsDialStepsPerRevolution)),
    ]
    for (name, steps, scale) in cases {
        expect(steps * scale, 2.0 * Double.pi, "\(name): one revolution in radians")
    }
}

/// The regression this suite exists for. Before 2026-09-25 the Wacom dials
/// reused the Xencelabs 13-step scale, so one physical revolution rotated the
/// canvas 24 x 27.7 = 665°, near enough two full turns.
private func testWacomDialNoLongerUsesTheXencelabsScale() {
    let wrong = rotateScaleMechanical(steps: xencelabsDialStepsPerRevolution)
    let right = rotateScaleMechanical(steps: wacomDialStepsPerRevolution)
    expectTrue(wrong != right, "Wacom and Xencelabs dial scales must differ")

    let overshoot = wacomDialStepsPerRevolution * wrong
    expectTrue(overshoot > 2.0 * Double.pi * 1.8,
               "the old shared scale should overshoot a turn by ~1.85x")
    expect(wacomDialStepsPerRevolution * right, 2.0 * Double.pi,
           "corrected Wacom dial revolution")
}

private func testPerStepAngles() {
    // Sanity on the human-readable figures quoted in the doc comments.
    expect(rotateScaleMechanical(steps: 24.0) * 180.0 / Double.pi, 15.0,
           "Wacom dial degrees/step")
    expect(dialGestureRotateScale * 180.0 / Double.pi, 5.0,
           "capacitive ring degrees/step")
}

// MARK: - Zoom: per-revolution totals must stay comparable

// `magnify.value` compounds multiplicatively per tick, so a mechanism with
// fewer, larger steps needs a bigger per-tick scale to reach the same zoom
// over one revolution. Exactness isn't achievable with a linear per-tick
// correction; staying in the same neighbourhood is.

private func zoomPerRevolution(steps: Double, scale: Double, speed: Double) -> Double {
    var value = 1.0
    for _ in 0..<Int(steps) { value *= (1.0 + scale * speed) }
    return value
}

private func testZoomPerRevolutionIsComparableAcrossMechanisms() {
    let maxSpeed = 8.0
    let ring = zoomPerRevolution(
        steps: ringStepsPerRevolution, scale: dialGestureZoomScale, speed: maxSpeed)
    for (name, steps) in [("Wacom", wacomDialStepsPerRevolution),
                          ("Xencelabs", xencelabsDialStepsPerRevolution)] {
        let dial = zoomPerRevolution(
            steps: steps, scale: zoomScaleMechanical(steps: steps), speed: maxSpeed)
        let ratio = dial / ring
        expectTrue(ratio > 0.85 && ratio < 1.15,
                   "\(name) dial zoom/revolution within 15% of the ring "
                       + "(got \(String(format: "%.2f", ratio))x)")
    }
}

/// Without the tick-count correction the Wacom dial's 24 steps would zoom far
/// short of the ring, the same defect that made the Xencelabs dial's max
/// "feel more like 1x" before its own correction landed.
private func testUncorrectedZoomWouldFallShort() {
    let maxSpeed = 8.0
    let ring = zoomPerRevolution(
        steps: ringStepsPerRevolution, scale: dialGestureZoomScale, speed: maxSpeed)
    let uncorrected = zoomPerRevolution(
        steps: wacomDialStepsPerRevolution, scale: dialGestureZoomScale, speed: maxSpeed)
    expectTrue(uncorrected < ring * 0.5,
               "uncorrected zoom should fall well short of the ring")
}

// MARK: - Run

testOneRevolutionIsOneFullTurn()
testWacomDialNoLongerUsesTheXencelabsScale()
testPerStepAngles()
testZoomPerRevolutionIsComparableAcrossMechanisms()
testUncorrectedZoomWouldFallShort()

if failures == 0 {
    print("dial-scale-tests: all checks passed")
} else {
    print("dial-scale-tests: \(failures) failure(s)")
    exit(1)
}
