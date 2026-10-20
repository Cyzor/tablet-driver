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

    /// Whether the ExpressKey column runs the other way on screen. A 180° flip
    /// swaps its ends, so a list ordered top-to-bottom has to be read from the
    /// far end to stay top-to-bottom on the tablet. The ±90° orientations move
    /// the column to a different edge rather than reversing it, so they're
    /// excluded.
    var reversesExpressKeyOrder: Bool { self == .landscapeFlipped }

    /// Index in a top-to-bottom settings list that drives the physical key at
    /// `index`. `count` is the number of ExpressKeys on the tablet: entries
    /// past the column (bezel keys, unused padding) keep their own index.
    /// Identity unless this orientation reverses the column.
    func expressKeySourceIndex(_ index: Int, count: Int) -> Int {
        guard reversesExpressKeyOrder, index >= 0, index < count else { return index }
        return count - 1 - index
    }

    /// `values` reordered into physical key order: the first `count` entries
    /// are the ExpressKey column and reverse together, the rest are untouched.
    /// For display-side lists; the injection hot path calls
    /// `expressKeySourceIndex` to avoid the copy.
    func expressKeys<T>(inOrder values: [T], count: Int) -> [T] {
        guard reversesExpressKeyOrder, count > 0, count <= values.count else { return values }
        return values.indices.map { values[expressKeySourceIndex($0, count: count)] }
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
