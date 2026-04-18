// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026 This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab. If not, see <https://www.gnu.org/licenses/>.

import AppKit
import SwiftUI

struct TabletColorTheme {
    /// Returns a subtle appearance-aware background tint color for a given tablet productID.
    /// Colors are deterministic: same tablet always gets the same hue.
    /// Blends a barely-visible tint (6% opacity) onto the system control background,
    /// automatically adapting to light mode, dark mode, and high contrast appearances.
    static func barBackgroundColor(for productID: Int?) -> Color {
        guard let pid = productID else {
            return Color(NSColor.controlBackgroundColor)
        }

        let hue = CGFloat(abs(pid.hashValue) % 360) / 360.0

        let nsColor = NSColor(
            name: nil,
            dynamicProvider: { appearance in
                // Get control background in the current appearance context
                let controlBG = NSColor.controlBackgroundColor

                // Create tint color: desaturated hue at full brightness
                let tintColor = NSColor(hue: hue, saturation: 0.08, brightness: 1.0, alpha: 1.0)

                // Blend tint at 6% opacity onto the control background
                return blendColors(background: controlBG, tint: tintColor, alpha: 0.08)
            })

        return Color(nsColor)
    }

    /// Blends a tint color onto a background using alpha composition.
    /// result = tint * alpha + background * (1 - alpha)
    private static func blendColors(background: NSColor, tint: NSColor, alpha: CGFloat) -> NSColor {
        // Convert catalog colors to concrete RGB colorspace for component extraction
        let bgRGB = background.usingColorSpace(.sRGB) ?? background
        let tintRGB = tint.usingColorSpace(.sRGB) ?? tint

        var bgR: CGFloat = 0
        var bgG: CGFloat = 0
        var bgB: CGFloat = 0
        var bgA: CGFloat = 0
        var tR: CGFloat = 0
        var tG: CGFloat = 0
        var tB: CGFloat = 0
        var tA: CGFloat = 0

        bgRGB.getRed(&bgR, green: &bgG, blue: &bgB, alpha: &bgA)
        tintRGB.getRed(&tR, green: &tG, blue: &tB, alpha: &tA)

        let resultR = tR * alpha + bgR * (1 - alpha)
        let resultG = tG * alpha + bgG * (1 - alpha)
        let resultB = tB * alpha + bgB * (1 - alpha)

        return NSColor(red: resultR, green: resultG, blue: resultB, alpha: bgA)
    }
}
