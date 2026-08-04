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

    /// Clockwise rotation angle in radians used for Canvas transforms.
    var rotationAngle: Double {
        switch self {
        case .landscape: return 0
        case .portrait: return 3 * .pi / 2  // 270° (swapped from 90°)
        case .landscapeFlipped: return .pi  // 180°
        case .portraitFlipped: return .pi / 2  // 90° (swapped from 270°)
        }
    }

    /// Whether this orientation swaps the X and Y hardware axes.
    var swapsAxes: Bool { self == .portrait || self == .portraitFlipped }

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
