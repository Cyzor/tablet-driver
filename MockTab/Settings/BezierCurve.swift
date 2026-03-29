// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026  This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab.  If not, see <https://www.gnu.org/licenses/>.

import Foundation

/// A cubic Bezier curve mapping input pressure (0..1) to output pressure (0..1).
/// Control points P0=(0,0) and P3=(1,1) are fixed; P1 and P2 are user-adjustable.
struct BezierCurve: Codable, Equatable {

    /// Intermediate control point 1 (x and y in 0..1).
    var p1: CGPoint
    /// Intermediate control point 2 (x and y in 0..1).
    var p2: CGPoint

    static let linear = BezierCurve(
        p1: CGPoint(x: 0.25, y: 0.25),
        p2: CGPoint(x: 0.75, y: 0.75))
    static let soft = BezierCurve(
        p1: CGPoint(x: 0.05, y: 0.5),
        p2: CGPoint(x: 0.5, y: 1.0))
    static let firm = BezierCurve(
        p1: CGPoint(x: 0.5, y: 0.0),
        p2: CGPoint(x: 0.95, y: 0.5))

    // MARK: - Evaluation

    /// Evaluate the curve at a given normalized pressure t ∈ [0, 1].
    /// Uses numerical root-finding (bisection) to invert the parametric x → t mapping,
    /// then reads the y value.
    func evaluate(_ input: Double) -> Double {
        let t = findT(for: Swift.min(Swift.max(input, 0), 1))
        return Swift.min(Swift.max(bezierY(t: t), 0), 1)
    }

    // MARK: - Precomputed lookup table (256 entries)

    func buildLookupTable() -> [Double] {
        (0..<256).map { i in
            evaluate(Double(i) / 255.0)
        }
    }

    // MARK: - Private helpers

    /// Find parametric t such that bezierX(t) ≈ x, using bisection.
    private func findT(for x: Double) -> Double {
        var lo: Double = 0
        var hi: Double = 1
        for _ in 0..<32 {
            let mid = (lo + hi) / 2
            let bx = bezierX(t: mid)
            if bx < x { lo = mid } else { hi = mid }
            if hi - lo < 1e-7 { break }
        }
        return (lo + hi) / 2
    }

    private func bezierX(t: Double) -> Double {
        cubic(t: t, p0: 0, p1: p1.x, p2: p2.x, p3: 1)
    }

    private func bezierY(t: Double) -> Double {
        cubic(t: t, p0: 0, p1: p1.y, p2: p2.y, p3: 1)
    }

    private func cubic(t: Double, p0: Double, p1: Double, p2: Double, p3: Double) -> Double {
        let u = 1 - t
        return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
    }
}
