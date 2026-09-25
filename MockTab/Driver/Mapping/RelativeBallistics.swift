// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pointer ballistics for relative mode.
///
/// Input is each report's movement as absolute mode would draw it, in screen
/// points, so crop, display region and non-uniform proportions all carry
/// over, the way touch does. Slow motion moves `speed` times that far; faster
/// motion is multiplied up by up to `accelFast` more. A fixed
/// high gain amplified sensor noise and hand tremor about 4x, which read as
/// jitter. Physical travel in millimetres drives speed and rest detection.
struct RelativeBallistics {
    /// Multiplier on absolute-mode movement when slow.
    static let speed = 0.5
    /// Extra multiplier at full speed, on top of `speed`.
    static let accelFast = 2.5
    /// Pen speeds (mm/s) where acceleration starts and where it tops out.
    /// Hand tremor peaks near 15 mm/s; a deliberate sweep runs 200+.
    static let speedSlow = 20.0
    static let speedFast = 200.0
    /// Speed smoothing time constant, seconds.
    static let speedTau = 0.03
    /// Travel from rest (mm) before the cursor moves: about 4x the measured
    /// frame-to-frame sensor noise on PTH-850 and PTK-870.
    static let breakaway = 0.15
    /// Below this speed (mm/s) for `restDelay` seconds, the pen is at rest.
    static let restSpeed = 3.0
    static let restDelay = 0.12

    private var penSpeed = 0.0
    private var resting = true
    private var restX = 0.0
    private var restY = 0.0
    private var restPointsX = 0.0
    private var restPointsY = 0.0
    private var slowFor = 0.0

    mutating func reset() {
        penSpeed = 0
        resting = true
        restX = 0
        restY = 0
        restPointsX = 0
        restPointsY = 0
        slowFor = 0
    }

    /// Cursor displacement (points) for one report: the pen's travel in mm,
    /// the same travel as absolute mode would move the cursor, and elapsed
    /// seconds.
    mutating func cursorDelta(
        dxMM: Double, dyMM: Double, dxPoints: Double, dyPoints: Double, dt: Double
    ) -> (dx: Double, dy: Double) {
        // Clamped so a stalled report can't read as a crawl, nor a burst as a
        // teleport.
        let step = Swift.min(Swift.max(dt, 0.001), 0.05)
        let alpha = 1 - exp(-step / Self.speedTau)
        penSpeed += alpha * ((dxMM * dxMM + dyMM * dyMM).squareRoot() / step - penSpeed)

        var dx = dxPoints
        var dy = dyPoints
        if resting {
            restX += dxMM
            restY += dyMM
            restPointsX += dxPoints
            restPointsY += dyPoints
            let r = (restX * restX + restY * restY).squareRoot()
            guard r > Self.breakaway else { return (0, 0) }
            // Only the travel past the threshold moves the cursor, so leaving
            // rest never jumps.
            let excess = (r - Self.breakaway) / r
            dx = restPointsX * excess
            dy = restPointsY * excess
            resting = false
            slowFor = 0
            restX = 0
            restY = 0
            restPointsX = 0
            restPointsY = 0
        } else if penSpeed < Self.restSpeed {
            slowFor += step
            if slowFor >= Self.restDelay { resting = true }
        } else {
            slowFor = 0
        }
        let m = Self.speed * Self.acceleration(forSpeed: penSpeed)
        return (dx * m, dy * m)
    }

    /// Smoothstep from 1 to `accelFast`.
    static func acceleration(forSpeed v: Double) -> Double {
        let t = Swift.min(Swift.max((v - speedSlow) / (speedFast - speedSlow), 0), 1)
        return 1 + (accelFast - 1) * t * t * (3 - 2 * t)
    }
}
