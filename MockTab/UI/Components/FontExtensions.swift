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

import SwiftUI

//extension Font {
//    /// Secondary label text: setting names, descriptions, status lines, footnotes.
//    /// Usage: `Text("Setting name").font(.settingsLabel)`
//    static var settingsLabel: Font { .caption }
//
//    /// Tertiary label: count badges, secondary status, help text, secondary information.
//    /// Usage: `Text("5 overrides").font(.settingsBadge)`
//    static var settingsBadge: Font { .caption2 }
//
//    /// Overlay badge title: device/app names on canvas, emphasized labels.
//    /// Usage: `Text("Intuos Pro M").font(.badgeTitle)`
//    static var badgeTitle: Font { .caption2 }
//
//    /// Overlay badge subtitle: model numbers, secondary badges, coordinates.
//    /// Usage: `Text("PTH-660").font(.badgeSubtitle)`
//    static var badgeSubtitle: Font { .caption2 }
//
//    /// Monospaced variant for numbers, codes, and technical readouts.
//    /// Usage: `Text("(1024, 2048)").font(.monospaced)`
//    static var monospaced: Font { .system(.caption, design: .monospaced) }
//}


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
