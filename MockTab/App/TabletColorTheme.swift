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

import AppKit

/// Generates deterministic, subtle color tints for per-tablet window identification.
///
/// Each tablet's productID hashes to a consistent hue; low saturation (15%) and
/// high brightness (95%) keep the tint understated and readable while providing
/// clear visual distinction across multiple tablet windows.
struct TabletColorTheme {

    /// Returns a subtle background tint color for a given tablet productID.
    /// Colors are deterministic: same tablet always gets the same hue.
    /// Returns system control accent color for generic (no-device) windows.
    static func backgroundColor(for productID: Int?) -> NSColor {
        guard let pid = productID else {
            return NSColor.controlBackgroundColor
        }

        // Hash productID to a hue in range [0, 360)
        let hue = CGFloat(abs(pid.hashValue) % 360) / 360.0

        // Very low saturation (15%) and high brightness (95%) for subtle effect
        return NSColor(hue: hue, saturation: 0.15, brightness: 0.95, alpha: 1.0)
    }
}
