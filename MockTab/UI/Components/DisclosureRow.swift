// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A full-width disclosure header that shows/hides `content` when tapped.
/// Chevron sits on the right; clicking anywhere on the header row toggles expansion.
struct DisclosureRow<Content: View>: View {
    let label: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isExpanded.toggle() } label: {
                HStack {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? -180 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isExpanded)
                        .appFont(.settingsLabel)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(label)
                        .appFont(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(
                isExpanded
                    ? Text(LocalizedStringKey("Expanded"))
                    : Text(LocalizedStringKey("Collapsed"))
            )

            if isExpanded {
                content()
                    .transition(.opacity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isExpanded)
            }
        }
    }
}
