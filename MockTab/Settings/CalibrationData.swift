// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// CalibrationData.swift — Pen-display parallax calibration model and math

import Foundation
import CoreGraphics

// MARK: - Data Model

/// Composite key identifying which (orientation, display) configuration a calibration applies to.
struct CalibrationKey: Codable, Hashable, Equatable {
    /// `TabletOrientation.rawValue` (0 = landscape, 1 = portrait, 2 = landscapeFlipped, 3 = portraitFlipped).
    let orientation: Int
    /// `CGDirectDisplayID` of the target display.
    let displayID: UInt32
}

/// A single calibration observation: where the crosshair was shown vs. where the pen actually tapped.
/// All coordinates are normalized 0–1 within the display bounds.
struct CalibrationSample: Codable, Equatable {
    let targetX: Double
    let targetY: Double
    let observedX: Double
    let observedY: Double
}

/// A fitted coordinate transform derived from calibration samples.
enum CalibrationTransform: Codable, Equatable {
    /// No transform — identity pass-through.
    case none
    /// 6-parameter affine: [a, b, tx, c, d, ty].
    ///   correctedX = a * obsX + b * obsY + tx
    ///   correctedY = c * obsX + d * obsY + ty
    case affine(coefficients: [Double])
    /// 8-parameter homography: [h0…h7], with h8 = 1 (normalized).
    ///   w = h6*obsX + h7*obsY + 1
    ///   correctedX = (h0*obsX + h1*obsY + h2) / w
    ///   correctedY = (h3*obsX + h4*obsY + h5) / w
    case homography(coefficients: [Double])
}

/// Full calibration data for one (device, orientation, display) configuration.
struct CalibrationEntry: Codable, Equatable {
    var key: CalibrationKey
    var samples: [CalibrationSample]
    var transform: CalibrationTransform
    var calibratedAt: Date
    /// Maximum per-sample Euclidean error in normalized coordinates after fitting.
    var maxResidual: Double
}

// MARK: - Standard Target Layouts

extension CalibrationEntry {

    /// 4-point targets inset 10% from display edges.
    static let fourPointTargets: [(Double, Double)] = [
        (0.1, 0.1),  // top-left
        (0.9, 0.1),  // top-right
        (0.9, 0.9),  // bottom-right
        (0.1, 0.9),  // bottom-left
    ]

    /// 9-point targets: 3×3 grid at 10%/50%/90%.
    static let ninePointTargets: [(Double, Double)] = [
        (0.1, 0.1), (0.5, 0.1), (0.9, 0.1),
        (0.1, 0.5), (0.5, 0.5), (0.9, 0.5),
        (0.1, 0.9), (0.5, 0.9), (0.9, 0.9),
    ]
}

// MARK: - Transform Application

extension CalibrationEntry {

    /// Apply an affine transform to a normalized coordinate pair.
    /// Coefficients: [a, b, tx, c, d, ty].
    static func applyAffine(_ c: [Double], to point: (Double, Double)) -> (Double, Double) {
        let (x, y) = point
        return (c[0] * x + c[1] * y + c[2],
                c[3] * x + c[4] * y + c[5])
    }

    /// Apply a homography transform to a normalized coordinate pair.
    /// Coefficients: [h0…h7], h8 = 1.
    static func applyHomography(_ h: [Double], to point: (Double, Double)) -> (Double, Double) {
        let (x, y) = point
        let w = h[6] * x + h[7] * y + 1.0
        guard abs(w) > 1e-12 else { return point }
        return ((h[0] * x + h[1] * y + h[2]) / w,
                (h[3] * x + h[4] * y + h[5]) / w)
    }

    /// Apply this entry's transform to a normalized coordinate pair.
    func apply(to point: (Double, Double)) -> (Double, Double) {
        switch transform {
        case .none:
            return point
        case .affine(let c):
            return Self.applyAffine(c, to: point)
        case .homography(let h):
            return Self.applyHomography(h, to: point)
        }
    }
}

// MARK: - Residual Computation

extension CalibrationEntry {

    /// Compute per-sample Euclidean residuals (in normalized coordinates) for a given transform.
    static func residuals(transform: CalibrationTransform, samples: [CalibrationSample]) -> [Double] {
        samples.map { s in
            let corrected: (Double, Double)
            switch transform {
            case .none:
                corrected = (s.observedX, s.observedY)
            case .affine(let c):
                corrected = applyAffine(c, to: (s.observedX, s.observedY))
            case .homography(let h):
                corrected = applyHomography(h, to: (s.observedX, s.observedY))
            }
            let dx = corrected.0 - s.targetX
            let dy = corrected.1 - s.targetY
            return (dx * dx + dy * dy).squareRoot()
        }
    }

    /// Maximum residual across all samples.
    static func maxResidual(transform: CalibrationTransform, samples: [CalibrationSample]) -> Double {
        residuals(transform: transform, samples: samples).max() ?? 0
    }
}

// MARK: - Affine Least-Squares Fitting

extension CalibrationEntry {

    /// Fit a 6-parameter affine transform from calibration samples using least-squares.
    /// Needs ≥ 3 non-collinear points. Returns [a, b, tx, c, d, ty] or nil if degenerate.
    ///
    /// Solves independently for X and Y:
    ///   targetX = a * obsX + b * obsY + tx
    ///   targetY = c * obsX + d * obsY + ty
    /// via normal equations (A^T A) x = A^T b on the 3×3 system.
    static func fitAffine(samples: [CalibrationSample]) -> [Double]? {
        guard samples.count >= 3 else { return nil }

        // Build A^T A (3×3, symmetric) and A^T b for X and Y targets.
        var ata = [Double](repeating: 0, count: 9)  // row-major 3×3
        var atbX = [Double](repeating: 0, count: 3)
        var atbY = [Double](repeating: 0, count: 3)

        for s in samples {
            let ox = s.observedX, oy = s.observedY
            let row = [ox, oy, 1.0]
            for i in 0..<3 {
                for j in 0..<3 {
                    ata[i * 3 + j] += row[i] * row[j]
                }
                atbX[i] += row[i] * s.targetX
                atbY[i] += row[i] * s.targetY
            }
        }

        guard let solX = solve3x3(ata, atbX),
              let solY = solve3x3(ata, atbY) else { return nil }

        // [a, b, tx, c, d, ty]
        return [solX[0], solX[1], solX[2], solY[0], solY[1], solY[2]]
    }

    /// Solve a 3×3 linear system Ax = b via Gaussian elimination with partial pivoting.
    /// `a` is row-major [9], `b` is [3]. Returns solution [3] or nil if singular.
    private static func solve3x3(_ a: [Double], _ b: [Double]) -> [Double]? {
        // Augmented matrix [A|b], 3 rows × 4 cols
        var m = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 3)
        for i in 0..<3 {
            for j in 0..<3 { m[i][j] = a[i * 3 + j] }
            m[i][3] = b[i]
        }

        // Forward elimination with partial pivoting
        for col in 0..<3 {
            // Find pivot
            var maxVal = abs(m[col][col])
            var maxRow = col
            for row in (col + 1)..<3 {
                if abs(m[row][col]) > maxVal {
                    maxVal = abs(m[row][col])
                    maxRow = row
                }
            }
            if maxVal < 1e-14 { return nil }  // singular
            if maxRow != col { m.swapAt(col, maxRow) }

            // Eliminate below
            for row in (col + 1)..<3 {
                let factor = m[row][col] / m[col][col]
                for j in col..<4 {
                    m[row][j] -= factor * m[col][j]
                }
            }
        }

        // Back substitution
        var x = [Double](repeating: 0, count: 3)
        for i in stride(from: 2, through: 0, by: -1) {
            if abs(m[i][i]) < 1e-14 { return nil }
            var sum = m[i][3]
            for j in (i + 1)..<3 { sum -= m[i][j] * x[j] }
            x[i] = sum / m[i][i]
        }
        return x
    }
}

// MARK: - Homography Fitting (DLT)

extension CalibrationEntry {

    /// Fit an 8-parameter homography from calibration samples using the Direct Linear Transform.
    /// Needs ≥ 4 points. Returns [h0…h7] (h8 = 1) or nil if degenerate.
    ///
    /// Each sample (obs → target) contributes two equations:
    ///   targetX * (h6*obsX + h7*obsY + 1) = h0*obsX + h1*obsY + h2
    ///   targetY * (h6*obsX + h7*obsY + 1) = h3*obsX + h4*obsY + h5
    /// Rearranged into Ah = b form with h = [h0…h7], h8 = 1.
    static func fitHomography(samples: [CalibrationSample]) -> [Double]? {
        guard samples.count >= 4 else { return nil }
        let cols = 8

        // Build the overdetermined system: (2n × 8) A, (2n) b
        // For least-squares, we solve (A^T A) h = A^T b, which is 8×8.
        var ata = [Double](repeating: 0, count: cols * cols)
        var atb = [Double](repeating: 0, count: cols)

        for s in samples {
            let ox = s.observedX, oy = s.observedY
            let tx = s.targetX, ty = s.targetY

            // Row for X equation:
            //   h0*ox + h1*oy + h2 + 0 + 0 + 0 - tx*h6*ox - tx*h7*oy = tx
            let rowX: [Double] = [ox, oy, 1, 0, 0, 0, -tx * ox, -tx * oy]
            let rhsX = tx

            // Row for Y equation:
            //   0 + 0 + 0 + h3*ox + h4*oy + h5 - ty*h6*ox - ty*h7*oy = ty
            let rowY: [Double] = [0, 0, 0, ox, oy, 1, -ty * ox, -ty * oy]
            let rhsY = ty

            // Accumulate A^T A and A^T b
            for i in 0..<cols {
                for j in 0..<cols {
                    ata[i * cols + j] += rowX[i] * rowX[j] + rowY[i] * rowY[j]
                }
                atb[i] += rowX[i] * rhsX + rowY[i] * rhsY
            }
        }

        return solve8x8(ata, atb)
    }

    /// Solve an 8×8 linear system via Gaussian elimination with partial pivoting.
    /// `a` is row-major [64], `b` is [8]. Returns solution [8] or nil if singular.
    private static func solve8x8(_ a: [Double], _ b: [Double]) -> [Double]? {
        let n = 8
        // Augmented matrix [A|b], n rows × (n+1) cols
        var m = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n)
        for i in 0..<n {
            for j in 0..<n { m[i][j] = a[i * n + j] }
            m[i][n] = b[i]
        }

        // Forward elimination with partial pivoting
        for col in 0..<n {
            var maxVal = abs(m[col][col])
            var maxRow = col
            for row in (col + 1)..<n {
                if abs(m[row][col]) > maxVal {
                    maxVal = abs(m[row][col])
                    maxRow = row
                }
            }
            if maxVal < 1e-14 { return nil }
            if maxRow != col { m.swapAt(col, maxRow) }

            for row in (col + 1)..<n {
                let factor = m[row][col] / m[col][col]
                for j in col..<(n + 1) {
                    m[row][j] -= factor * m[col][j]
                }
            }
        }

        // Back substitution
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            if abs(m[i][i]) < 1e-14 { return nil }
            var sum = m[i][n]
            for j in (i + 1)..<n { sum -= m[i][j] * x[j] }
            x[i] = sum / m[i][i]
        }
        return x
    }
}

// MARK: - Calibration Pipeline

extension CalibrationEntry {

    /// Threshold for escalating from affine to homography (normalized coords).
    /// ~4 pixels on a 1080p display.
    static let homographyEscalationThreshold = 0.004

    /// Fit the best transform for the given samples.
    /// Tries affine first; escalates to homography if corner residuals exceed threshold.
    static func fitBest(samples: [CalibrationSample]) -> CalibrationTransform {
        guard let affineCoeffs = fitAffine(samples: samples) else { return .none }
        let affineTransform = CalibrationTransform.affine(coefficients: affineCoeffs)
        let affineMax = maxResidual(transform: affineTransform, samples: samples)

        if affineMax <= homographyEscalationThreshold {
            return affineTransform
        }

        // Affine wasn't good enough — try homography
        if let homoCoeffs = fitHomography(samples: samples) {
            let homoTransform = CalibrationTransform.homography(coefficients: homoCoeffs)
            let homoMax = maxResidual(transform: homoTransform, samples: samples)
            // Only use homography if it's actually better
            if homoMax < affineMax {
                return homoTransform
            }
        }

        // Fall back to affine even if it's imperfect
        return affineTransform
    }
}
