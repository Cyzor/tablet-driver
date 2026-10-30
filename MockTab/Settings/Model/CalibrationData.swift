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
    /// Stable hardware identity for the target display: `"vendor-model-serial"` from
    /// `CGDisplayVendorNumber`/`CGDisplayModelNumber`/`CGDisplaySerialNumber`.
    /// Stable across reconnects and reboots, unlike `CGDirectDisplayID`.
    let displayUUID: String

    init(orientation: Int, displayUUID: String) {
        self.orientation = orientation
        self.displayUUID = displayUUID
    }

    // MARK: Codable — reads both new (displayUUID) and legacy (displayID) JSON.

    private enum CodingKeys: String, CodingKey {
        case orientation, displayUUID, displayID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orientation = try c.decode(Int.self, forKey: .orientation)
        if let uuid = try c.decodeIfPresent(String.self, forKey: .displayUUID), !uuid.isEmpty {
            displayUUID = uuid
        } else if let legacyID = try c.decodeIfPresent(UInt32.self, forKey: .displayID) {
            displayUUID = CalibrationKey.uuidString(for: legacyID)
        } else {
            displayUUID = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(orientation, forKey: .orientation)
        try c.encode(displayUUID, forKey: .displayUUID)
    }

    // MARK: Display UUID helpers

    /// Returns a stable hardware-identity string for a display, or "" if unavailable.
    /// Built from vendor/model/serial numbers — stable across reconnects and reboots,
    /// unlike `CGDirectDisplayID` which macOS can reassign after a cable unplug.
    static func uuidString(for displayID: CGDirectDisplayID) -> String {
        guard displayID != 0 else { return "" }
        let vendor = CGDisplayVendorNumber(displayID)
        guard vendor != 0xFFFF_FFFF else { return "" }  // sentinel for invalid display
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        return "\(vendor)-\(model)-\(serial)"
    }

    /// "0-0-0" (all-zero vendor/model/serial, seen on some no-EDID adapters)
    /// isn't unique per display — treat it as unreliable like the empty string.
    nonisolated static func isReliable(_ uuid: String) -> Bool {
        !uuid.isEmpty && uuid != "0-0-0"
    }
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
    /// 8-parameter homography: [h0…h7], with h8 = 1 (normalized). Only
    /// calibrations saved before 0.4.0 hold one.
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

// MARK: - Scale + Translation Fitting (default, robust model)

extension CalibrationEntry {

    /// Sane range for a per-axis calibration scale factor. A factor outside this
    /// band means the taps were too noisy to trust; the axis falls back to unit
    /// scale (translation only).
    static let scaleBounds = 0.5...2.0

    /// Fit a per-axis scale + translation transform from calibration samples.
    ///
    /// This is the default model for a pen display whose surface is physically
    /// coincident with the screen: the honest degrees of freedom are translation
    /// and scale, not rotation or shear. Each axis is solved independently by
    /// 1-D least squares, and any scale factor outside `scaleBounds` is rejected
    /// in favor of 1.0 (keeping the translation term), so an imprecise tap can
    /// never skew the mapping the way a full affine or homography fit can.
    ///
    /// Returns affine coefficients [sx, 0, tx, 0, sy, ty] — a restricted affine,
    /// so it flows through the same apply/residual path — or nil if < 2 samples.
    static func fitScaleTranslate(samples: [CalibrationSample]) -> [Double]? {
        guard samples.count >= 2 else { return nil }
        let (sx, tx) = fitAxis(obs: samples.map(\.observedX), target: samples.map(\.targetX))
        let (sy, ty) = fitAxis(obs: samples.map(\.observedY), target: samples.map(\.targetY))
        return [sx, 0, tx, 0, sy, ty]
    }

    /// 1-D least-squares fit of `target ≈ scale * obs + offset`, with an outlier
    /// clamp: a degenerate spread or an out-of-range scale collapses to unit
    /// scale, preserving the (dominant) translation correction.
    private static func fitAxis(obs: [Double], target: [Double]) -> (scale: Double, offset: Double) {
        let n = Double(obs.count)
        let meanO = obs.reduce(0, +) / n
        let meanT = target.reduce(0, +) / n
        var cov = 0.0, varO = 0.0
        for i in obs.indices {
            let dO = obs[i] - meanO
            cov += dO * (target[i] - meanT)
            varO += dO * dO
        }
        guard varO > 1e-12 else { return (1.0, meanT - meanO) }
        let scale = cov / varO
        guard scale.isFinite, scaleBounds.contains(scale) else {
            return (1.0, meanT - meanO)
        }
        return (scale, meanT - scale * meanO)
    }
}

// MARK: - Calibration Pipeline

extension CalibrationEntry {

    /// Fit the transform for the given samples: the constrained per-axis
    /// scale + translation, which can't pick up the shear or perspective that
    /// imprecise taps put into a full fit.
    static func fitBest(samples: [CalibrationSample]) -> CalibrationTransform {
        fitScaleTranslate(samples: samples).map { .affine(coefficients: $0) } ?? .none
    }
}
