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

import Foundation

/// One entry in the help panel sidebar, matching the app's tab order.
///
/// Help content is sourced from `en.md` (or the best-match language file) in
/// the app bundle via `HelpContent`. To revise help text, edit the `.md` file
/// directly — no recompile needed. To add a language, add a matching `.md`
/// file to the Help group and the Copy Bundle Resources build phase.
enum HelpSection: String, CaseIterable, Identifiable {
    case tabletArea
    case penFeel
    case buttons
    case display
    case devices
    case profiles
    case scratchpad
    case info

    var id: String { rawValue }

    /// Index into `SettingsWindowController.tabLabels` / tab bar.
    var tabIndex: Int { HelpSection.allCases.firstIndex(of: self)! }

    var title: String {
        switch self {
        case .tabletArea: String(localized: "Tablet Area",  comment: "Help section title")
        case .penFeel:    String(localized: "Pen Feel",     comment: "Help section title")
        case .buttons:    String(localized: "Buttons",      comment: "Help section title")
        case .display:    String(localized: "Display",      comment: "Help section title")
        case .devices:    String(localized: "Devices",      comment: "Help section title")
        case .profiles:   String(localized: "Profiles",     comment: "Help section title")
        case .scratchpad: String(localized: "Scratchpad",   comment: "Help section title")
        case .info:       String(localized: "Info",         comment: "Help section title")
        }
    }

    var systemImage: String {
        switch self {
        case .tabletArea: "rectangle.dashed"
        case .penFeel:    "scribble.variable"
        case .buttons:    "square.grid.2x2.fill"
        case .display:    "display"
        case .devices:    "rectangle.on.rectangle"
        case .profiles:   "star.circle"
        case .scratchpad: "pencil.and.outline"
        case .info:       "info.circle"
        }
    }


    /// Markdown source for this section, loaded from the bundled language file.
    var markdownSource: String { HelpContent.shared.body(for: self) }
}
