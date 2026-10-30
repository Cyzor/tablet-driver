// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later


import SwiftUI
import TabletKit

// The Display pane's Built-in Display section for Xencelabs pen displays:
// brightness, color mode, contrast, and gamma.
extension DisplayView {
    /// True when the selected tablet is a pen display whose panel brightness
    /// the driver can set (Xencelabs). Decided from the device spec, not the
    /// live connection, so the section stays visible — disabled — while the
    /// display is unplugged or asleep.
    var hasBrightnessControl: Bool {
        guard let pid = productID else { return false }
        return TabletManager.staticSpec(forProductID: pid)?.offeredControls.contains(.displayPanel) == true
    }

    /// Model name of a Wacom pen display, whose panel may answer DDC/CI
    /// over its video cable. Nil for everything else, Xencelabs included:
    /// its vendor-HID brightness is the same register.
    var cintiqPanelModelName: String? {
        guard !hasBrightnessControl, let pid = productID,
              let spec = WacomDeviceRegistry.spec(for: pid), spec.isPenDisplay
        else { return nil }
        return spec.name
    }

    var brightnessDeviceConnected: Bool {
        guard let ctx = tabletManager.context(forKey: instanceKey) else { return false }
        return ctx.isConnected
    }

    /// True only once the user has explicitly picked Custom/User Mode —
    /// contrast/gamma stay hidden under the parked default (a named preset)
    /// since writing them there corrupts the preset's own color transform.
    var isCustomColorModeSelected: Bool {
        settings.displayColorMode == TabletSettings.displayColorModeCustomIndex
    }

    var brightnessSection: some View {
        Section {
            // Dimmed on the content only, never the whole Section:
            // `.disabled()` by itself leaves labels and readouts at full
            // strength (AppKit only drops the controls' accent tint), so
            // without this the section reads as available. Putting the
            // opacity on the Section instead would fade the footer too —
            // and that footer is what explains *why* this is unavailable,
            // so it has to stay the most legible thing here.
            Group {
                HStack {
                    Image(systemName: "sun.max")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Brightness")
                    Slider(
                        value: settings.recordingBinding(
                            String(localized: "Display Brightness", comment: "Undo action name: display calibration/mapping control in the Displays pane"),
                            // Before the user ever touches the slider (-1), park
                            // the knob at the vendor default without sending.
                            get: { Double(settings.displayBrightness >= 0 ? settings.displayBrightness : 75) },
                            set: { settings.displayBrightness = Int($0.rounded()) }),
                        in: 0...100)
                    .accessibilityLabel(Text("Brightness"))
                    Text(settings.displayBrightness >= 0 ? settings.displayBrightness.formatted(.percent) : "—")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .scaledFrame(width: 48, alignment: .trailing)
                }
                .help("Backlight brightness of the tablet's built-in display. The hardware keeps its own value until you move the slider.")

                HStack {
                    Image(systemName: "paintpalette")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Color Space")
                    Spacer()
                    Picker("Color Space", selection: settings.recordingBinding(
                        String(localized: "Display Color Space", comment: "Undo action name: display calibration/mapping control in the Displays pane"),
                        get: { settings.displayColorMode >= 0 ? settings.displayColorMode : 0 },
                        set: { settings.displayColorMode = $0 })) {
                        ForEach(colorModeChoices.indices, id: \.self) { i in
                            Text(colorModeChoices[i].name).tag(i)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .help(colorModeChoices[
                    settings.displayColorMode >= 0 && settings.displayColorMode < colorModeChoices.count
                        ? settings.displayColorMode : 0
                ].description)

                // Contrast/gamma are only meaningful in Custom mode; named
                // presets (Adobe RGB, sRGB, etc.) own these internally.
                if isCustomColorModeSelected {
                    HStack {
                        Image(systemName: "circle.lefthalf.filled")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Contrast")
                        Slider(
                            value: settings.recordingBinding(
                                String(localized: "Display Contrast", comment: "Undo action name: display calibration/mapping control in the Displays pane"),
                                get: { Double(settings.displayContrast >= 0 ? settings.displayContrast : 50) },
                                set: { settings.displayContrast = Int($0.rounded()) }),
                            in: 0...100)
                        Text(settings.displayContrast >= 0 ? settings.displayContrast.formatted(.percent) : "—")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .scaledFrame(width: 48, alignment: .trailing)
                    }
                    .help("Contrast of the tablet's built-in display. The hardware keeps its own value until you change it.")

                    HStack {
                        Image(systemName: "circle.dotted")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Gamma")
                        Spacer()
                        Picker("Gamma", selection: settings.recordingBinding(
                            String(localized: "Display Gamma", comment: "Undo action name: display calibration/mapping control in the Displays pane"),
                            get: { settings.displayGamma >= 0 ? settings.displayGamma : 22 },
                            set: { settings.displayGamma = $0 })) {
                            ForEach(gammaChoices, id: \.self) { value in
                                Text(gammaLabel(value)).tag(value)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .help("Display gamma. The hardware keeps its own value until you change it.")
                }
            }
            .opacity(brightnessDeviceConnected ? 1 : 0.5)
        } header: {
            Text("Built-in Display").appFont(.headline)
        } footer: {
            Text(brightnessDeviceConnected
                ? "Changes the display's appearance. Feature support may vary."
                : "Available when the display is connected.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .disabled(!brightnessDeviceConnected)
    }

    /// Format a gamma-×10 value as its decimal label (22 → "2.2").
    func gammaLabel(_ timesTen: Int) -> String {
        (Double(timesTen) / 10.0).formatted(.number.precision(.fractionLength(1)))
    }
}
