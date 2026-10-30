// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Loads and caches help content from a bundled Markdown file.
///
/// Each language has a `Help.md` in its `.lproj` folder under `MockTab/Help/`,
/// and `Bundle` picks the one matching the rest of the UI. Each file uses
/// `[section-id]` lines as section delimiters, where the id matches a
/// `HelpSection.rawValue`.
///
/// `HelpContent` is loaded once at first access. Call `reload()` to re-read
/// the file from disk — useful during development with a running app.
final class HelpContent {

    nonisolated(unsafe) static let shared = HelpContent()  // main-only

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
        guard let url = Bundle.main.url(forResource: "Help", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        parse(text)
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
