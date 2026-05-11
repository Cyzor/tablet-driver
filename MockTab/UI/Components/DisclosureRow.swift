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
                        .font(.settingsLabel)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(label)
                        .font(.headline)
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
