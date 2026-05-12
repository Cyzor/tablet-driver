// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

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
