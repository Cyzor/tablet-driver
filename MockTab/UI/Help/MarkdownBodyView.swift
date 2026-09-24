// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Renders a subset of Markdown as a SwiftUI VStack.
///
/// Handles: `##` headings, `- ` bullet list items, blank-line-separated
/// paragraphs, and inline `**bold**` / `*italic*` via AttributedString.
/// SwiftUI's `Text` cannot render block-level Markdown structure on its own,
/// so this view parses the source line-by-line and emits typed subviews.
struct MarkdownBodyView: View {

    let source: String
    var fontSizeStep: Int = 0

    // Base sizes at step 0. Each step adds 1pt.
    private static let bodyBase:    CGFloat = 13
    private static let headingBase: CGFloat = 15  // ~headline weight above body

    private var bodySize:    CGFloat { Self.bodyBase    + CGFloat(fontSizeStep) }
    private var headingSize: CGFloat { Self.headingBase + CGFloat(fontSizeStep) }

    // Gaps track the type size so the text-size control doesn't crowd the
    // layout at the top of its range.
    private var paragraphGap: CGFloat { bodySize * 0.6 }
    private var bulletGap:    CGFloat { bodySize * 0.3 }
    private var headingGap:   CGFloat { bodySize * 3.0 }

    @Environment(\.colorScheme) private var colorScheme

    /// Headings take the system accent so help matches the rest of the UI.
    /// Pale accents (yellow, orange) are unreadable as light-mode body text,
    /// so mix toward black there.
    private var headingColor: Color {
        guard colorScheme == .light else { return .accentColor }
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .controlAccentColor
        return Color(nsColor: accent.blended(withFraction: 0.45, of: .black) ?? accent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, index: index)
            }
        }
    }

    // MARK: - Block model

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(text: String)
        case bullet(text: String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var pendingLines: [String] = []

        func flush() {
            let joined = pendingLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { result.append(.paragraph(text: joined)) }
            pendingLines = []
        }

        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("## ") {
                flush()
                result.append(.heading(level: 2, text: String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flush()
                result.append(.heading(level: 1, text: String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") {
                flush()
                result.append(.bullet(text: String(line.dropFirst(2))))
            } else {
                pendingLines.append(line)
            }
        }
        flush()
        return result
    }

    // MARK: - Rendering

    @ViewBuilder
    private func blockView(_ block: Block, index: Int) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(.system(size: headingSize + (level == 1 ? 2 : 0), weight: .semibold))
                .foregroundStyle(headingColor)
                .padding(.top, index == 0 ? 0 : headingGap * (level == 1 ? 1.15 : 1))
                .padding(.bottom, bodySize * 0.35)

        case .paragraph(let text):
            inlineText(text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, paragraphGap)

        case .bullet(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.system(size: bodySize))
                    .foregroundStyle(.secondary)
                inlineText(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, bulletGap)
        }
    }

    private func inlineText(_ raw: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if var attr = try? AttributedString(markdown: raw, options: opts) {
            // Apply scaled body size; bold/italic runs keep their relative weight.
            attr.font = .system(size: bodySize)
            return Text(attr)
        }
        return Text(raw).font(.system(size: bodySize))
    }
}
