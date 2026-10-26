// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later


import AppKit
import SwiftUI

// MARK: - Wacom pen display panel (DDC/CI)

/// Brightness and contrast for a Wacom pen display, sent over its video
/// cable. Shown for every Wacom pen display and enabled only once the panel
/// answers, so a Mac or adapter that can't reach it just grays it out.
struct CintiqPanelSection: View {
    @StateObject private var panel: CintiqPanelControl

    init(modelName: String) {
        _panel = StateObject(wrappedValue: CintiqPanelControl(modelName: modelName))
    }

    #if DEBUG
    init(preview panel: CintiqPanelControl) {
        _panel = StateObject(wrappedValue: panel)
    }
    #endif

    var body: some View {
        Section {
            Group {
                row(String(localized: "Brightness"), symbol: "sun.max",
                    value: panel.brightness, set: panel.setBrightness)
                    .help("Backlight brightness of the tablet's built-in display.")
                row(String(localized: "Contrast"), symbol: "circle.lefthalf.filled",
                    value: panel.contrast, set: panel.setContrast)
                    .help("Contrast of the tablet's built-in display.")
            }
            .opacity(panel.state == .ready ? 1 : 0.5)
        } header: {
            Text("Built-in Display").appFont(.headline)
        } footer: {
            Text(footer)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .help(footerHelp)
        }
        .disabled(panel.state != .ready)
        .onAppear { panel.probe() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification)) { _ in panel.probe() }
    }

    private var footer: String {
        switch panel.state {
        case .probing:
            String(localized: "Checking the display…")
        case .noDisplay:
            String(localized: "Available when the display is connected to this Mac's video output.")
        case .noReply:
            String(localized: "Not available for this display.")
        case .ready:
            String(localized: "Experimental.", comment: "Footer under the Built-in Display controls")
        }
    }

    private var footerHelp: String {
        guard panel.state == .ready else { return "" }
        return panel.writeOnly
            ? String(localized: "Changes the display's own settings over its video cable. This display doesn't report its settings, so the sliders start where you last set them.")
            : String(localized: "Changes the display's own settings over its video cable.")
    }

    private func row(_ title: String, symbol: String,
                     value: CintiqPanelControl.Value?, set: @escaping (Int) -> Void) -> some View {
        HStack {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .scaledFrame(width: 20)
                .accessibilityHidden(true)
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            // While probing the value is unknown, not unavailable: show a bare
            // track so no knob claims a setting we haven't read.
            Group {
                if panel.state == .probing {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 4)
                } else {
                    Slider(
                        value: Binding(
                            get: { Double(value?.current ?? 50) },
                            set: { set(Int($0.rounded())) }),
                        in: 0...Double(max(value?.max ?? 100, 1)))
                    .labelsHidden()
                    .accessibilityLabel(title)
                }
            }
            .scaledFrame(width: 200)
            Text(value.map { "\($0.current * 100 / max($0.max, 1))%" } ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .scaledFrame(width: 48, alignment: .trailing)
        }
        .disabled(value == nil)
    }
}

#if DEBUG
#Preview("Built-in Display") {
    Form {
        CintiqPanelSection(preview: CintiqPanelControl(
            previewState: .ready,
            brightness: .init(current: 70, max: 100),
            contrast: .init(current: 50, max: 100)))
        CintiqPanelSection(preview: CintiqPanelControl(
            previewState: .ready, brightness: .init(current: 40, max: 100)))
        CintiqPanelSection(preview: CintiqPanelControl(previewState: .probing))
        CintiqPanelSection(preview: CintiqPanelControl(previewState: .noDisplay))
        CintiqPanelSection(preview: CintiqPanelControl(previewState: .noReply))
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 900)
}
#endif
