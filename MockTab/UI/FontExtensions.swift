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

extension Font {
    /// Secondary label text: setting names, descriptions, status lines, footnotes.
    /// Usage: `Text("Setting name").font(.settingsLabel)`
    static var settingsLabel: Font { .caption }

    /// Tertiary label: count badges, secondary status, help text, secondary information.
    /// Usage: `Text("5 overrides").font(.settingsBadge)`
    static var settingsBadge: Font { .caption2 }

    /// Overlay badge title: device/app names on canvas, emphasized labels.
    /// Usage: `Text("Intuos Pro M").font(.badgeTitle)`
    static var badgeTitle: Font { .caption2 }

    /// Overlay badge subtitle: model numbers, secondary badges, coordinates.
    /// Usage: `Text("PTH-660").font(.badgeSubtitle)`
    static var badgeSubtitle: Font { .caption2 }

    /// Monospaced variant for numbers, codes, and technical readouts.
    /// Usage: `Text("(1024, 2048)").font(.monospaced)`
    static var monospaced: Font { .system(.caption, design: .monospaced) }
}
