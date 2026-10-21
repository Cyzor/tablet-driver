// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// Relative mode must be calm at rest and at slow speeds, and still cross the
// screen on a quick sweep. `RelativeBallistics.swift` is compiled into this
// bundle, so the app isn't launched.

import Foundation
import Testing

/// Pen positions (mm) and timestamps (s) fed through the ballistics, the way
/// `DisplayMapper` does: rounded output, float position carried.
private struct Run {
    var travel = 0.0        // total cursor path, points
    var flickers = 0        // rounded-position changes
    var minX = 0.0, maxX = 0.0, minY = 0.0, maxY = 0.0
}

/// Absolute mode's scale on a large tablet mapped to a laptop display.
private let absolutePointsPerMM = 4.8
private let rate = 200.0

private func drive(_ samples: [(t: Double, x: Double, y: Double)], fixedGain: Double? = nil) -> Run {
    var b = RelativeBallistics()
    var run = Run()
    var px = 0.0, py = 0.0
    var last = (x: 0.0, y: 0.0)
    for (prev, cur) in zip(samples, samples.dropFirst()) {
        let dx = cur.x - prev.x, dy = cur.y - prev.y
        let d: (dx: Double, dy: Double) =
            fixedGain.map { (dx * $0, dy * $0) }
            ?? b.cursorDelta(
                dxMM: dx, dyMM: dy,
                dxPoints: dx * absolutePointsPerMM, dyPoints: dy * absolutePointsPerMM,
                dt: cur.t - prev.t)
        px += d.dx
        py += d.dy
        run.travel += (d.dx * d.dx + d.dy * d.dy).squareRoot()
        let r = (x: px.rounded(), y: py.rounded())
        if r != last { run.flickers += 1; last = r }
        run.minX = min(run.minX, px); run.maxX = max(run.maxX, px)
        run.minY = min(run.minY, py); run.maxY = max(run.maxY, py)
    }
    return run
}

private func gaussian(_ sigma: Double) -> Double {
    let u1 = Double.random(in: Double.ulpOfOne..<1)
    let u2 = Double.random(in: 0..<1)
    return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
}

@Suite("Relative mode ballistics")
struct RelativeBallisticsTests {

    @Test("Sensor noise at rest doesn't move the cursor")
    func stillPen() {
        // 15 µm σ for 5 s.
        let still = (0..<Int(5 * rate)).map { i in
            (t: Double(i) / rate, x: gaussian(0.015), y: gaussian(0.015))
        }
        #expect(drive(still).flickers == 0)
    }

    @Test("Hand tremor wobbles no more than absolute mode")
    func tremor() {
        // 0.3 mm at 8 Hz plus noise.
        let tremor = (0..<Int(3 * rate)).map { i -> (t: Double, x: Double, y: Double) in
            let t = Double(i) / rate
            return (t, 0.3 * sin(2 * .pi * 8 * t) + gaussian(0.015), gaussian(0.015))
        }
        let run = drive(tremor)
        #expect(run.maxX - run.minX <= 0.6 * absolutePointsPerMM * 1.2)
    }

    @Test("A quick sweep crosses a 1512 pt screen")
    func flick() {
        // 300 mm in 1 s.
        let flick = (0...Int(1.0 * rate)).map { i -> (t: Double, x: Double, y: Double) in
            let t = Double(i) / rate
            return (t, 300 * t * t * (3 - 2 * t), 0)
        }
        #expect(drive(flick).maxX >= 1512)
    }

    @Test("Slow positioning moves a small, steady amount")
    func slow() {
        // 5 mm at 10 mm/s.
        let slow = (0...Int(0.5 * rate)).map { i in (t: Double(i) / rate, x: Double(i) / rate * 10, y: 0.0) }
        #expect((8...16).contains(drive(slow).maxX))
    }

    @Test("Leaving rest doesn't jump")
    func leavingRest() {
        var b = RelativeBallistics()
        var firstMove = 0.0
        for _ in 1...100 where firstMove == 0 {
            firstMove = b.cursorDelta(dxMM: 0.01, dyMM: 0, dxPoints: 0.048, dyPoints: 0, dt: 1 / rate).dx
        }
        #expect(firstMove > 0 && firstMove < 1)
    }

    @Test("Gain curve endpoints")
    func gainEndpoints() {
        #expect(RelativeBallistics.acceleration(forSpeed: 0) == 1)
        #expect(RelativeBallistics.acceleration(forSpeed: 1000) == RelativeBallistics.accelFast)
    }

    @Test("A squashed mapping's proportions carry through")
    func proportions() {
        var b = RelativeBallistics()
        _ = b.cursorDelta(dxMM: 0.2, dyMM: 0.2, dxPoints: 2, dyPoints: 1, dt: 0.005)
        let d = b.cursorDelta(dxMM: 0.02, dyMM: 0.02, dxPoints: 0.2, dyPoints: 0.1, dt: 0.005)
        #expect(abs(d.dx / d.dy - 2) < 1e-9)
    }
}
