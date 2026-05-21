// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

extension Font {
    // Body-level: setting names, descriptions, toggle labels, status lines.
    // Usage: .font(.settingsLabel) — replaces previous .caption assignment.
    static var settingsLabel: Font { .body }

    // Secondary: count badges, overridden-key counts, active/inactive chips.
    // Usage: .font(.settingsBadge)
    static var settingsBadge: Font { .footnote }

    // Tertiary: canvas overlay titles — device/app names.
    // Usage: .font(.badgeTitle)
    static var badgeTitle: Font { .callout }

    // Quaternary: canvas overlay subtitles — model numbers, coordinates.
    // Usage: .font(.badgeSubtitle)
    static var badgeSubtitle: Font { .caption }

    // Explicit caption tier for any view that legitimately needs 10pt text.
    // Views currently broken by the .settingsLabel bump should migrate here
    // only if the tiny size was intentional.
    static var settingsCaption: Font { .caption2 }

    // Monospaced technical readouts — coordinates, hex codes.
    static var monospaced: Font { .system(.body, design: .monospaced) }
}
