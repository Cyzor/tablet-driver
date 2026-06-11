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
            dynamicProvider: { _ in
                let controlBG = NSColor.controlBackgroundColor
                let tintColor = NSColor(hue: hue, saturation: 0.08, brightness: 1.0, alpha: 1.0)
                // Resolve the catalog color to sRGB first; blended(withFraction:of:)
                // returns nil for unconvertible color spaces.
                let bgRGB = controlBG.usingColorSpace(.sRGB) ?? controlBG
                return bgRGB.blended(withFraction: 0.08, of: tintColor) ?? controlBG
            })

        return Color(nsColor)
    }
}
