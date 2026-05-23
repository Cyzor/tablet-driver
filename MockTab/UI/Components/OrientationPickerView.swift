// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

// MARK: - Orientation picker

/// Orientation selector with a native radio button on the left of each row.
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
        Button(action: { selectOrientation(orientation) }) {
            HStack(spacing: 10) {
                NativeRadioIndicator(isSelected: settings.tabletOrientation == orientation)
                    .frame(width: 18, height: 18)
                    .allowsHitTesting(false)
                OrientationGlyph(orientation: orientation)
                    .frame(width: 50, height: 50)
                Text(orientation.pickerLabel)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(orientation.helpText)
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

// MARK: - Native radio button indicator

/// Display-only native macOS radio circle drawn via NSButtonCell.
/// Position (circle left, label right) is controlled by the enclosing HStack.
/// Interaction is handled by the parent — this view ignores hit-testing.
struct NativeRadioIndicator: NSViewRepresentable {
    let isSelected: Bool

    func makeNSView(context: Context) -> RadioIndicatorView { RadioIndicatorView() }

    func updateNSView(_ view: RadioIndicatorView, context: Context) {
        view.isSelected = isSelected
    }

    final class RadioIndicatorView: NSView {
        var isSelected = false { didSet { needsDisplay = true } }

        private let cell: NSButtonCell = {
            let c = NSButtonCell()
            c.setButtonType(.radio)
            c.title = ""
            c.imagePosition = .imageOnly
            c.isBordered = false
            return c
        }()

        override func draw(_ dirtyRect: NSRect) {
            cell.isEnabled = true
            cell.state = isSelected ? .on : .off
            cell.draw(withFrame: bounds, in: self)
        }
    }
}

// MARK: - Orientation label extension

extension TabletOrientation {
    /// Short label shown next to each radio button.
    var pickerLabel: LocalizedStringKey {
        switch self {
        case .landscape:        return LocalizedStringKey("Landscape")
        case .portrait:         return LocalizedStringKey("Portrait")
        case .landscapeFlipped: return LocalizedStringKey("Landscape Flipped")
        case .portraitFlipped:  return LocalizedStringKey("Portrait Flipped")
        }
    }

    /// Tooltip shown on hover.
    var helpText: LocalizedStringKey {
        switch self {
        case .landscape:        return LocalizedStringKey("Standard orientation — tablet's long edge is horizontal.")
        case .portrait:         return LocalizedStringKey("Rotate the active surface 90° clockwise. Hold the tablet in portrait orientation.")
        case .landscapeFlipped: return LocalizedStringKey("Flip 180° — useful for left-handed use or reversed cable routing.")
        case .portraitFlipped:  return LocalizedStringKey("Rotate the active surface 90° counter-clockwise.")
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
            // Orientation is redundantly conveyed by the parent radio row's
            // localised text label, so the rotated glyph is decorative.
            .accessibilityHidden(true)
    }
}
