// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Holds a tap's drags until the pen travels away from where it touched
/// down, so a nib that wobbles on contact still clicks.
///
/// Measured on the tablet, in millimeters, so it holds the same however small
/// the area or large the display: on a small tablet mapped to a big screen,
/// a fraction of a millimeter is many points. The nib wobbles most just after
/// contact, so the radius is wider then.
///
/// Free of AppKit and TabletKit so the checks can compile it.
struct TouchdownGuard {
    /// Settled radius in millimeters. 0 turns the guard off.
    var radiusMM: Double
    /// How long after contact the wider radius applies.
    static let settleSeconds: Double = 0.150
    /// How much wider the radius is while the nib settles.
    static let settlingFactor: Double = 2.5
    /// Radius when the defaults key isn't set.
    static let defaultRadiusMM: Double = 0.7

    /// Whether a contact `elapsed` seconds old, `travelMM` from its touchdown
    /// point, should still hold its drags.
    func holds(elapsed: Double, travelMM: Double) -> Bool {
        guard radiusMM > 0 else { return false }
        let radius = elapsed < Self.settleSeconds ? radiusMM * Self.settlingFactor : radiusMM
        return travelMM <= radius
    }

    /// Pen travel in millimeters between two tablet positions, each a
    /// fraction (0...1) of the active area, given its size.
    static func travelMM(
        from start: (x: Double, y: Double), to end: (x: Double, y: Double),
        areaMM: (width: Double, height: Double)
    ) -> Double {
        let dx = (end.x - start.x) * areaMM.width
        let dy = (end.y - start.y) * areaMM.height
        return (dx * dx + dy * dy).squareRoot()
    }
}
