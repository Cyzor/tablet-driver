// SPDX-License-Identifier: GPL-3.0-or-later
//
// MockTab — native macOS driver for supported drawing tablets
// Copyright (C) 2026
//
// This file is part of MockTab. MockTab is free software: you can
// redistribute it and/or modify it under the terms of the GNU General
// Public License as published by the Free Software Foundation, either
// version 3 of the License, or (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
// for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab. If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

// MARK: - Orientation picker

/// Orientation selector with vertical radio button layout (buttons on left).
/// Each orientation is rendered as a separate form row.
struct OrientationPickerView: View {
    @ObservedObject var settings: TabletSettings

    var body: some View {
        ForEach(TabletOrientation.allCases, id: \.rawValue) { orientation in
            orientationRow(orientation)
        }
    }

    // MARK: - Row builder

    @ViewBuilder
    private func orientationRow(_ orientation: TabletOrientation) -> some View {
        let isSelected = settings.tabletOrientation == orientation
        Button(action: { selectOrientation(orientation) }) {
            HStack(spacing: 10) {
                RadioButton(isSelected: isSelected)
                OrientationGlyph(orientation: orientation)
                    .frame(width: 50, height: 50)
                Text(orientation.pickerLabel)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Action

    private func selectOrientation(_ orientation: TabletOrientation) {
        let oldValue = settings.tabletOrientation
        settings.tabletOrientation = orientation
        settings.record("Orientation") {
            settings.tabletOrientation = oldValue
        }
    }
}

// MARK: - Radio button control

private struct RadioButton: View {
    let isSelected: Bool

    var body: some View {
        Circle()
            .strokeBorder(Color.secondary, lineWidth: 1.5)
            .frame(width: 16, height: 16)
            .overlay(
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .opacity(isSelected ? 1 : 0)
            )
            .animation(.easeOut(duration: 0.07), value: isSelected)
    }
}

// MARK: - Orientation label extension

extension TabletOrientation {
    /// Short label shown next to each radio button.
    var pickerLabel: String {
        switch self {
        case .landscape:        return "Landscape"
        case .portrait:         return "Portrait"
        case .landscapeFlipped: return "Landscape (Flipped)"
        case .portraitFlipped:  return "Portrait (Flipped)"
        }
    }
}

// MARK: - Orientation glyph

/// Small tablet icon for each orientation radio button.
/// The landscape SVG is rotated by the orientation's angle to produce all four variants.
/// No fixed frame is applied here — the caller controls the display size.
struct OrientationGlyph: View {
    let orientation: TabletOrientation

    var body: some View {
        Image("TabletOrientation")
            .resizable()
            .scaledToFit()
            .rotationEffect(Angle(radians: orientation.rotationAngle))
    }
}
