// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - TabletOrientation

/// Physical rotation of the tablet relative to the default landscape position.
/// The raw value is the number of 90° clockwise quarter-turns.
enum TabletOrientation: Int, CaseIterable {
    case landscape = 0  // default  — USB port at bottom
    case portrait = 1  // 90° CCW  — USB port at right
    case landscapeFlipped = 2  // 180°     — USB port at top
    case portraitFlipped = 3  // 90° CW   — USB port at left

    /// Whether this orientation swaps the X and Y hardware axes.
    var swapsAxes: Bool { self == .portrait || self == .portraitFlipped }

    /// Turned a half turn from Landscape or Portrait, so whatever ran up the
    /// tablet now runs down it.
    var isHalfTurn: Bool { self == .landscapeFlipped || self == .portraitFlipped }

    /// Quarter turns counterclockwise from Landscape, as the tablet looks on
    /// the desk. Drawings of the tablet turn by this much.
    var counterclockwiseTurns: Int {
        switch self {
        case .landscape: return 0
        case .portrait: return 1
        case .landscapeFlipped: return 2
        case .portraitFlipped: return 3
        }
    }

    /// Adjusts a raw-space aspect ratio (width/height) for this orientation —
    /// swapped for `portrait`/`portraitFlipped`, unchanged otherwise. Shared
    /// by `TabletAreaView` and `TouchView`'s crop-editor preview boxes so
    /// both rotate their displayed shape in step with this setting.
    func applying(toAspectRatio aspectRatio: Double) -> Double {
        swapsAxes ? 1.0 / aspectRatio : aspectRatio
    }

    /// The orientation that undoes this one's rotation. `landscape` and
    /// `landscapeFlipped` (180°) are each their own inverse; `portrait` and
    /// `portraitFlipped` (±90°) invert each other. Used to convert a rect
    /// already in oriented space back to raw storage space (see
    /// `DisplayMapper.orientedCropRect`).
    var inverse: TabletOrientation {
        switch self {
        case .landscape: return .landscape
        case .portrait: return .portraitFlipped
        case .landscapeFlipped: return .landscapeFlipped
        case .portraitFlipped: return .portrait
        }
    }

    var label: String {
        switch self {
        case .landscape:
            return String(localized: "Landscape", comment: "Tablet orientation: default landscape")
        case .portrait:
            return String(localized: "Portrait", comment: "Tablet orientation: rotated 90° CCW")
        case .landscapeFlipped:
            return String(
                localized: "Landscape Flipped", comment: "Tablet orientation: rotated 180°")
        case .portraitFlipped:
            return String(
                localized: "Portrait Flipped", comment: "Tablet orientation: rotated 90° CW")
        }
    }
}
