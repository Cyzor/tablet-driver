// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import TabletKit

/// One entry in a device light's factory palette: the LED-calibrated bytes
/// the hardware expects plus the perceptual sRGB color the swatch shows —
/// they differ (the Xencelabs "white" is warm-compensated on the wire), and
/// showing the wire bytes as sRGB would render white as salmon.
struct LEDSwatch {
    let name: String
    let display: Color
    let wire: (r: UInt8, g: UInt8, b: UInt8)
}

extension LEDSwatch {
    /// Xencelabs' 8-color factory palette (bezel LED and dial LED share the
    /// same light hardware family). Wire values from `XencelabsControl`,
    /// display colors and names matching the vendor UI's swatch row.
    static let xencelabsPalette: [LEDSwatch] = {
        let names: [(String, Color)] = [
            (String(localized: "White", comment: "LED swatch name"), .white),
            (String(localized: "Magenta", comment: "LED swatch name"), Color(red: 1, green: 0, blue: 0.6)),
            (String(localized: "Blue", comment: "LED swatch name"), .blue),
            (String(localized: "Cyan", comment: "LED swatch name"), .cyan),
            (String(localized: "Green", comment: "LED swatch name"), .green),
            (String(localized: "Yellow", comment: "LED swatch name"), .yellow),
            (String(localized: "Orange", comment: "LED swatch name"), .orange),
            (String(localized: "Red", comment: "LED swatch name"), .red),
        ]
        return zip(names, XencelabsControl.ledPalette).map {
            LEDSwatch(name: $0.0, display: $0.1, wire: $1)
        }
    }()
}

/// Coalesces a burst of light edits (a color-panel drag, a brightness-slider
/// drag, rapid swatch clicks) into one undo entry, registered once the
/// control goes quiet — same TextEdit-style pattern the dial wells used.
/// Reference type so the snapshot and timer survive view re-renders;
/// `@State` preserves the instance.
@MainActor private final class LEDUndoCoalescer {
    private var snapshot: ControlSlot.LEDColor?
    private var hasSnapshot = false
    private var pending: DispatchWorkItem?

    func noteChange(
        settings: TabletSettings, label: String,
        current: ControlSlot.LEDColor?, restore: @escaping (ControlSlot.LEDColor?) -> Void
    ) {
        if !hasSnapshot {
            snapshot = current
            hasSnapshot = true
        }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self, weak settings] in
            MainActor.assumeIsolated {
                guard let self, let settings, self.hasSnapshot else { return }
                let snap = self.snapshot
                self.hasSnapshot = false
                self.snapshot = nil
                settings.record(label) { restore(snap) }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}

/// Opens the shared `NSColorPanel` for the custom well and forwards live
/// color changes back — TextEdit-style. The panel retargets whenever
/// another well opens it, so the last-opened well owns it, like text views
/// sharing the font panel.
@MainActor private final class ColorPanelBridge: NSObject {
    private var onChange: ((NSColor) -> Void)?

    func open(initial: NSColor, onChange: @escaping (NSColor) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = initial
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}

/// The shared editor for a device's RGB light (Quick Keys dial LED, pen
/// display bezel backlight): a row of factory swatches HIG accent-color
/// style, a trailing multicolor well for free choice, and an explicit
/// brightness slider. `.inline` embeds the whole editor in a form row;
/// `.well` shows a compact color dot that opens the same editor in a
/// popover, for tight rows like the dial's mode slots.
///
/// The bound value follows the app's light convention: `nil` means the user
/// never touched this light (the hardware keeps its own color), the alpha
/// is the brightness (premultiplied into the RGB on the way to the device),
/// and the RGB bytes are wire values for swatches or raw sRGB for custom
/// picks. Undo is coalesced internally — callers pass a plain binding.
struct LEDColorControl: View, Equatable {
    enum Style { case inline, well }

    /// Equatable over the displayed values so `.equatable()` call sites skip
    /// re-rendering during the pane's ~16 Hz hover invalidations. The
    /// binding and settings references are ignored — recreated identical
    /// each parent evaluation, always targeting the same stored value.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.style == rhs.style
            && lhs.color == rhs.color
            && lhs.defaultWire == rhs.defaultWire
            && lhs.undoLabel == rhs.undoLabel
    }

    let style: Style
    @Binding var color: ControlSlot.LEDColor?
    /// Shown (at full brightness) while `color` is nil, without writing:
    /// the light's factory/default color.
    let defaultWire: (r: UInt8, g: UInt8, b: UInt8)
    let undoLabel: String
    let settings: TabletSettings
    var palette: [LEDSwatch] = LEDSwatch.xencelabsPalette

    @State private var coalescer = LEDUndoCoalescer()
    @State private var panelBridge = ColorPanelBridge()
    @State private var popoverShown = false

    var body: some View {
        switch style {
        case .inline:
            editor
        case .well:
            Button {
                popoverShown.toggle()
            } label: {
                wellDot(currentDisplayColor, selected: false)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $popoverShown, arrowEdge: .bottom) {
                editor.padding(12)
            }
            .accessibilityLabel("LED color")
        }
    }

    // MARK: - Editor (shared by both styles)

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                ForEach(palette.indices, id: \.self) { i in
                    let swatch = palette[i]
                    Button {
                        setColor(ControlSlot.LEDColor(
                            r: swatch.wire.r, g: swatch.wire.g, b: swatch.wire.b,
                            a: color?.a ?? 255))
                    } label: {
                        wellDot(swatch.display, selected: isSelected(swatch))
                    }
                    .buttonStyle(.plain)
                    .help(swatch.name)
                    .accessibilityLabel(swatch.name)
                }
                customWell
            }
            HStack(spacing: 6) {
                Image(systemName: "sun.min")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Slider(value: brightnessBinding, in: 0...1) {
                    // An explicit empty label — the label-less initializer
                    // still reserves leading space for one on macOS, which
                    // squeezed the track into half the row.
                    EmptyView()
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                    .help("Brightness of the light.")
                    .accessibilityLabel("LED brightness")
                Image(systemName: "sun.max")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            // Same width as the swatch row above, so the slider visually
            // complements the swatches instead of picking its own length.
            .frame(width: swatchRowWidth)
        }
    }

    /// Width of the swatch row: each dot is 16 pt + 2 pt padding a side,
    /// plus the custom well, with 7 pt spacing between them.
    private var swatchRowWidth: CGFloat {
        let dots = CGFloat(palette.count + 1)
        return dots * 20 + (dots - 1) * 7
    }

    /// The trailing free-choice well: a round multicolor button (HIG
    /// accent-color style) that opens the system color panel directly —
    /// the native ColorPicker's rectangular well clashed with the swatch
    /// row. Selecting any color there stores raw sRGB bytes (no LED
    /// calibration — the swatches are the calibrated path); brightness
    /// stays on the slider.
    private var customWell: some View {
        Button {
            panelBridge.open(initial: NSColor(customBinding.wrappedValue)) { picked in
                customBinding.wrappedValue = Color(picked)
            }
        } label: {
            wellDot(nil, selected: isCustomSelected)
        }
        .buttonStyle(.plain)
        .help("Custom color")
        .accessibilityLabel("Custom color")
    }

    /// One round swatch. `nil` color renders the multicolor wheel.
    private func wellDot(_ fill: Color?, selected: Bool) -> some View {
        ZStack {
            if let fill {
                Circle().fill(fill)
            } else {
                Circle().fill(
                    AngularGradient(
                        colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                        center: .center))
            }
            Circle().strokeBorder(.quaternary, lineWidth: 1)
        }
        .frame(width: 16, height: 16)
        .padding(2)
        .overlay(
            Circle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(selected ? 1 : 0)
        )
        .contentShape(Circle())
    }

    // MARK: - Selection and bindings

    private func isSelected(_ swatch: LEDSwatch) -> Bool {
        guard let c = color else { return false }
        return c.r == swatch.wire.r && c.g == swatch.wire.g && c.b == swatch.wire.b
    }

    private var isCustomSelected: Bool {
        guard let c = color else { return false }
        return !palette.contains { $0.wire.r == c.r && $0.wire.g == c.g && $0.wire.b == c.b }
    }

    /// What the compact well shows: the matching swatch's perceptual color
    /// when a factory color is stored (so warm-compensated white reads as
    /// white), the raw sRGB for custom picks, the default wire color while
    /// untouched.
    private var currentDisplayColor: Color {
        Self.displayColor(for: color, defaultWire: defaultWire, palette: palette)
    }

    /// The perceptual color a stored light value should render as — shared
    /// with read-only indicators (mode-list summary dots) so they agree with
    /// the editor's wells.
    static func displayColor(
        for color: ControlSlot.LEDColor?,
        defaultWire: (r: UInt8, g: UInt8, b: UInt8),
        palette: [LEDSwatch] = LEDSwatch.xencelabsPalette
    ) -> Color {
        if let c = color {
            if let swatch = palette.first(where: {
                $0.wire.r == c.r && $0.wire.g == c.g && $0.wire.b == c.b
            }) {
                return swatch.display.opacity(Double(c.a) / 255)
            }
            return Color(
                red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255,
                opacity: Double(c.a) / 255)
        }
        if let swatch = palette.first(where: {
            $0.wire.r == defaultWire.r && $0.wire.g == defaultWire.g && $0.wire.b == defaultWire.b
        }) {
            return swatch.display
        }
        return Color(
            red: Double(defaultWire.r) / 255, green: Double(defaultWire.g) / 255,
            blue: Double(defaultWire.b) / 255)
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { Double(color?.a ?? 255) / 255 },
            set: { newValue in
                // Moving the slider on an untouched light materializes the
                // default color — brightness alone is meaningless to send.
                let base = color ?? ControlSlot.LEDColor(
                    r: defaultWire.r, g: defaultWire.g, b: defaultWire.b, a: 255)
                setColor(ControlSlot.LEDColor(
                    r: base.r, g: base.g, b: base.b,
                    a: UInt8((newValue * 255).rounded())))
            }
        )
    }

    private var customBinding: Binding<Color> {
        Binding(
            get: {
                guard let c = color, isCustomSelected else { return .white }
                return Color(
                    red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
            },
            set: { newValue in
                guard let rgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                setColor(ControlSlot.LEDColor(
                    r: UInt8((rgb.redComponent * 255).rounded()),
                    g: UInt8((rgb.greenComponent * 255).rounded()),
                    b: UInt8((rgb.blueComponent * 255).rounded()),
                    a: color?.a ?? 255))
            }
        )
    }

    private func setColor(_ newValue: ControlSlot.LEDColor?) {
        coalescer.noteChange(
            settings: settings, label: undoLabel, current: color,
            restore: { self.color = $0 })
        color = newValue
    }
}
