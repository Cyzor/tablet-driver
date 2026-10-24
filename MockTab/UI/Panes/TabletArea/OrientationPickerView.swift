// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

// MARK: - Orientation picker

/// Orientation selector with a native radio button on the left of each row.
struct OrientationPickerView: View {
    @ObservedObject var settings: TabletSettings
    /// The bound tablet, drawn turned to each orientation.
    let figure: TabletFigure
    /// Its ring has a lamp at each corner; see `TabletControlMap.ringLampsTurn`.
    var ringLampsTurn = false

    @State private var windowRef = WindowRef()
    @State private var keyMonitor: Any?

    var body: some View {
        ForEach(TabletOrientation.allCases, id: \.rawValue) { orientation in
            orientationRow(orientation)
        }
        .background(WindowReader(ref: windowRef))
        .onAppear(perform: startShortcuts)
        .onDisappear(perform: stopShortcuts)
    }

    // MARK: - Shortcuts

    /// ⌘⌥1–4 pick the rows in order, a quick way back from a wrong pick. A
    /// key monitor, because SwiftUI drops keyboard shortcuts on buttons in
    /// form rows. Matched by physical key, so layouts that need Shift for
    /// digits work too.
    private static let digitKeys: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4]

    private func startShortcuts() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [windowRef] event in
            guard event.window === windowRef.window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .option],
                  let number = Self.digitKeys[event.keyCode]
            else { return event }
            selectOrientation(TabletOrientation.allCases[number - 1])
            return nil
        }
    }

    private func stopShortcuts() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: - Row builder

    @ViewBuilder
    private func orientationRow(_ orientation: TabletOrientation) -> some View {
        Button(action: { selectOrientation(orientation) }) {
            HStack(spacing: 10) {
                NativeRadioIndicator(isSelected: settings.tabletOrientation == orientation)
                    .frame(width: 18, height: 18)
                    .allowsHitTesting(false)
                // Decorative: the row's label already names the orientation.
                TabletGlyphView(figure: figure.oriented(orientation),
                                isSelected: settings.tabletOrientation == orientation)
                    .equatable()
                    .frame(width: 50, height: 50)
                Text(orientation.pickerLabel)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(orientation.helpText) + Text(verbatim: "  ⌘⌥\(shortcutNumber(orientation))"))
        // VoiceOver reads the shortcut on its own; the hint stays in words.
        .accessibilityHint(Text(orientation.helpText))
    }

    private func shortcutNumber(_ orientation: TabletOrientation) -> Int {
        (TabletOrientation.allCases.firstIndex(of: orientation) ?? 0) + 1
    }

    // MARK: - Action

    /// Turning the tablet moves its assignments with it, so every place keeps
    /// its action; undo reverts both.
    private func selectOrientation(_ orientation: TabletOrientation) {
        settings.turn(to: orientation) { [figure, ringLampsTurn] old, new in
            figure.turnCarry(from: old, to: new, ringLampsTurn: ringLampsTurn)
        }
    }
}

// MARK: - Orientation label extension

extension TabletOrientation {
    /// Short label shown next to each radio button.
    var pickerLabel: LocalizedStringKey {
        switch self {
        case .landscape:        return "Landscape"
        case .portrait:         return "Portrait"
        case .landscapeFlipped: return "Landscape Flipped"
        case .portraitFlipped:  return "Portrait Flipped"
        }
    }

    /// Tooltip shown on hover.
    var helpText: LocalizedStringKey {
        switch self {
        case .landscape:        return "Standard orientation, with the tablet's long edge horizontal."
        case .portrait:         return "Rotate the active surface 90° clockwise. Hold the tablet in portrait orientation."
        case .landscapeFlipped: return "Rotate the active surface 180°, with the tablet's long edge horizontal."
        case .portraitFlipped:  return "Rotate the active surface 90° counter-clockwise."
        }
    }
}
