// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Drag Threshold: holds a contact's drags for its first moments, so a quick
/// tap whose nib wobbles still clicks where it touched down.
///
/// Measured in screen points, as apps tell a click from a drag, so the most
/// the cursor waits behind the pen is the radius on any mapping.
///
/// The hold ends at whichever comes first, the radius or `holdSeconds`, so a
/// drag or stroke never waits longer than that. The guard loses nothing the
/// pen does while it holds: a stroke replays the held samples where and when
/// they happened, and a tap posts their pressure where it touched down.
///
/// Free of AppKit and TabletKit so the checks can compile it.
struct TouchdownGuard {
    /// Radius in points. 0 turns the guard off.
    var radius: Double
    /// Longest a contact holds, however little it travels.
    static let holdSeconds: Double = 0.150
    /// Drag Threshold's default, in points.
    static let defaultRadius: Double = 5

    /// Whether a contact `elapsed` seconds old, `travel` points from its
    /// touchdown point, should still hold its drags.
    func holds(elapsed: Double, travel: Double) -> Bool {
        radius > 0 && elapsed < Self.holdSeconds && travel <= radius
    }
}
