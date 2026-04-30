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

/// Loads and caches help content from a bundled Markdown file.
///
/// Files live at `<Bundle>/en.md`, `<Bundle>/de.md`, etc. Each file uses
/// `[section-id]` lines as section delimiters, where the id matches a
/// `HelpSection.rawValue`. To add a new language, drop the appropriately
/// named `.md` file into the Help group and add it to Copy Bundle Resources.
///
/// `HelpContent` is loaded once at first access. Call `reload()` to re-read
/// the file from disk — useful during development with a running app.
final class HelpContent {

    static let shared = HelpContent()

    private var sections: [String: String] = [:]

    private init() { load() }

    /// Returns the Markdown body for `section`, or an empty string if not found.
    func body(for section: HelpSection) -> String {
        sections[section.rawValue] ?? ""
    }

    /// Re-reads the file from the bundle. Useful during authoring without relaunch.
    func reload() {
        sections = [:]
        load()
    }

    // MARK: - Private

    private func load() {
        // Prefer languages in the order the user has configured them in System Settings.
        let codes = Locale.preferredLanguages.compactMap {
            Locale(identifier: $0).language.languageCode?.identifier
        }
        for code in codes + ["en"] {
            if let url = Bundle.main.url(forResource: code, withExtension: "md"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                parse(text)
                return
            }
        }
    }

    /// Splits the file at `[section-id]` marker lines and trims surrounding blank lines.
    private func parse(_ text: String) {
        var currentID: String? = nil
        var lines: [String] = []

        func flush() {
            guard let id = currentID else { return }
            sections[id] = lines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lines = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A marker is a single bracketed token with no internal spaces.
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), !trimmed.contains(" ") {
                flush()
                currentID = String(trimmed.dropFirst().dropLast())
            } else {
                lines.append(line)
            }
        }
        flush()
    }
}
