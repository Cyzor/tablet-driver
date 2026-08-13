// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// CalibrationFitTests.swift — Standalone checks for the calibration fitting math.
//
// The app has no XCTest target (by design — see the project's test conventions),
// so these run as a small executable compiled against the real CalibrationData.swift.
// Run via tools/tests/calibration-tests/run.sh. Exits non-zero on the first failure.

import Foundation

// MARK: - Tiny assertion harness

private var failures = 0
private var checks = 0

private func expect(_ condition: Bool, _ message: @autoclosure () -> String,
                    file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition {
        failures += 1
        FileHandle.standardError.write(Data("FAIL (\(file):\(line)): \(message())\n".utf8))
    }
}

private func expectClose(_ a: Double, _ b: Double, _ tol: Double = 1e-9,
                         _ message: @autoclosure () -> String,
                         file: StaticString = #file, line: UInt = #line) {
    expect(abs(a - b) <= tol, "\(message()) — got \(a), expected \(b) (±\(tol))",
           file: file, line: line)
}

private func sample(_ tx: Double, _ ty: Double, _ ox: Double, _ oy: Double) -> CalibrationSample {
    CalibrationSample(targetX: tx, targetY: ty, observedX: ox, observedY: oy)
}

/// Pull [sx, b, tx, c, sy, ty] out of an affine transform, else fail.
private func affineCoeffs(_ t: CalibrationTransform, _ label: String,
                          file: StaticString = #file, line: UInt = #line) -> [Double] {
    if case .affine(let c) = t { return c }
    expect(false, "\(label): expected .affine, got \(t)", file: file, line: line)
    return [1, 0, 0, 0, 1, 0]
}

// MARK: - Tests

/// A clean uniform offset+scale should be recovered exactly on both axes.
private func testExactScaleTranslate() {
    // observed = target * 0.8 + 0.1 on both axes.
    let s = 0.8, off = 0.1
    let pts: [(Double, Double)] = [(0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9)]
    let samples = pts.map { sample($0.0, $0.1, $0.0 * s + off, $0.1 * s + off) }

    let t = CalibrationEntry.fitBest(samples: samples)          // simple path
    let c = affineCoeffs(t, "exactScaleTranslate")
    // Recover the inverse: correctedX = (obs - off)/s = obs*(1/s) - off/s.
    expectClose(c[0], 1.0 / s, 1e-9, "sx")
    expectClose(c[2], -off / s, 1e-9, "tx")
    expectClose(c[4], 1.0 / s, 1e-9, "sy")
    expectClose(c[5], -off / s, 1e-9, "ty")
    expect(c[1] == 0 && c[3] == 0, "cross terms must be zero in the constrained fit")

    let maxRes = CalibrationEntry.maxResidual(transform: t, samples: samples)
    expect(maxRes < 1e-9, "clean data should fit with ~zero residual, got \(maxRes)")
}

/// A wild per-axis scale (here ~5×, well outside scaleBounds) must be rejected in
/// favor of unit scale, while the translation term is still corrected.
private func testOutOfRangeScaleRejected() {
    // X axis: a runaway 5× scale (bad taps). Y axis: a sane, near-unit mapping.
    // Observed X barely moves while target spans wide → implied scale ~5.
    let samples = [
        sample(0.1, 0.1, 0.50, 0.10),
        sample(0.9, 0.1, 0.66, 0.10),
        sample(0.9, 0.9, 0.66, 0.90),
        sample(0.1, 0.9, 0.50, 0.90),
    ]
    let t = CalibrationEntry.fitBest(samples: samples)
    let c = affineCoeffs(t, "outOfRangeScale")

    // X scale rejected → 1.0, offset = meanTarget - meanObs.
    expectClose(c[0], 1.0, 1e-12, "rejected X scale falls back to 1.0")
    let meanTx = 0.5, meanOx = (0.50 + 0.66 + 0.66 + 0.50) / 4.0
    expectClose(c[2], meanTx - meanOx, 1e-9, "X keeps translation correction")

    // Y is a clean identity mapping → scale ~1, offset ~0, kept.
    expect(CalibrationEntry.scaleBounds.contains(c[4]), "Y scale stays in bounds: \(c[4])")
    expectClose(c[4], 1.0, 1e-9, "Y scale")
    expectClose(c[5], 0.0, 1e-9, "Y offset")
}

/// Degenerate spread on an axis (all taps share the same coordinate) must not blow
/// up: that axis collapses to unit scale + translation.
private func testDegenerateSpreadFallsBack() {
    // Every observed X is identical → zero variance on X.
    let samples = [
        sample(0.1, 0.1, 0.5, 0.1),
        sample(0.9, 0.1, 0.5, 0.1),   // note: same targetY too, but Y still has spread overall
        sample(0.9, 0.9, 0.5, 0.9),
        sample(0.1, 0.9, 0.5, 0.9),
    ]
    let t = CalibrationEntry.fitBest(samples: samples)
    let c = affineCoeffs(t, "degenerateSpread")
    expect(c[0].isFinite && c[2].isFinite, "degenerate X must not produce NaN/Inf")
    expectClose(c[0], 1.0, 1e-12, "degenerate X scale falls back to 1.0")
    // offset = meanTarget(0.5) - meanObs(0.5) = 0.
    expectClose(c[2], 0.0, 1e-9, "degenerate X offset")
}

/// Fewer than two samples cannot define a scale → no transform.
private func testTooFewSamples() {
    let t = CalibrationEntry.fitBest(samples: [sample(0.1, 0.1, 0.12, 0.12)])
    if case .none = t {} else { expect(false, "single sample should yield .none, got \(t)") }
}

/// The advanced path may still choose a full affine when asked; a sheared mapping
/// that the constrained model cannot represent should be recovered there.
private func testAdvancedAllowsAffineShear() {
    // observed = a genuine shear of target: obsX = tx + 0.2*ty, obsY = ty.
    let pts: [(Double, Double)] = [(0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9), (0.5, 0.5)]
    let samples = pts.map { sample($0.0, $0.1, $0.0 + 0.2 * $0.1, $0.1) }

    let simple = CalibrationEntry.fitBest(samples: samples, allowHigherOrder: false)
    let advanced = CalibrationEntry.fitBest(samples: samples, allowHigherOrder: true)

    let simpleRes = CalibrationEntry.maxResidual(transform: simple, samples: samples)
    let advancedRes = CalibrationEntry.maxResidual(transform: advanced, samples: samples)

    expect(simpleRes > 1e-6, "constrained model cannot cancel shear, residual should remain: \(simpleRes)")
    expect(advancedRes < 1e-6, "affine should recover the shear cleanly, got \(advancedRes)")
}

// MARK: - Runner

@main
enum CalibrationTestRunner {
    static func main() {
        testExactScaleTranslate()
        testOutOfRangeScaleRejected()
        testDegenerateSpreadFallsBack()
        testTooFewSamples()
        testAdvancedAllowsAffineShear()

        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("\(failures) of \(checks) checks failed\n".utf8))
            exit(1)
        }
    }
}
