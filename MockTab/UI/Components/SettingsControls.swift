// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared building blocks for the settings panes: the standard pane
// scaffold, section headers, toggle/slider row shapes, undo-recording
// bindings, and battery indicator mapping.

import SwiftUI

// MARK: - Undo-recording bindings

extension TabletSettings {
    /// Creates a binding that registers an undo entry for each change.
    ///
    /// Undo is always recorded against this `TabletSettings` — its
    /// `undoManager` is reliably wired by `SettingsWindowController`,
    /// whereas `ToolSettings.undoManager` can be nil (e.g. before
    /// proximity entry) and would drop the registration silently.
    /// For bindings that mutate a `ToolSettings`, pass `toolOwned: true`
    /// so `objectWillChange` propagates — tool mutations don't reach
    /// `settings.objectWillChange` automatically.
    func recordingBinding<T>(
        _ name: String,
        toolOwned: Bool = false,
        get: @escaping () -> T,
        set: @escaping (T) -> Void
    ) -> Binding<T> {
        Binding(
            get: get,
            set: { newValue in
                let oldValue = get()
                set(newValue)
                if toolOwned { self.objectWillChange.send() }
                self.record(name) {
                    set(oldValue)
                    if toolOwned { self.objectWillChange.send() }
                }
            }
        )
    }

    /// Equatable overload — skips the write and the undo registration when
    /// the value didn't change (sliders and pickers re-set freely).
    func recordingBinding<T: Equatable>(
        _ name: String,
        toolOwned: Bool = false,
        get: @escaping () -> T,
        set: @escaping (T) -> Void
    ) -> Binding<T> {
        Binding(
            get: get,
            set: { newValue in
                let oldValue = get()
                guard newValue != oldValue else { return }
                set(newValue)
                if toolOwned { self.objectWillChange.send() }
                self.record(name) {
                    set(oldValue)
                    if toolOwned { self.objectWillChange.send() }
                }
            }
        )
    }
}

// MARK: - SettingsPane

/// Standard scaffold for Form-based settings panes: optional app-override
/// chip bar on top, a grouped Form, and the live device status bar pinned
/// beneath.
struct SettingsPane<Content: View>: View {
    @ObservedObject var settings: TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    var productID: Int?
    var overrideKeys: Set<String>?
    @ViewBuilder let content: () -> Content

    init(settings: TabletSettings,
         tabletManager: TabletManager,
         registry: DeviceRegistry,
         productID: Int?,
         overrideKeys: Set<String>? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.settings = settings
        self.tabletManager = tabletManager
        self.registry = registry
        self.productID = productID
        self.overrideKeys = overrideKeys
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            if let overrideKeys {
                AppOverrideBar(settings: settings, domainKeys: overrideKeys, productID: productID)
            }
            Form { content() }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            DeviceStatusBar(
                settings: settings, tabletManager: tabletManager, registry: registry,
                productID: productID ?? 0)
        }
    }
}

// MARK: - PaneSectionHeader

/// Section header: headline title with a live device/tool caption beneath.
struct PaneSectionHeader<Subtitle: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let subtitle: () -> Subtitle

    init(_ title: LocalizedStringKey, @ViewBuilder subtitle: @escaping () -> Subtitle) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).appFont(.headline)
            subtitle()
        }
    }
}

// MARK: - DescribedToggle

/// Settings row: toggle whose label is a title with a secondary
/// description line beneath — the standard MockTab toggle shape.
/// The description builder allows composed Text (icons, dynamic state);
/// use the convenience initializer for a plain string.
struct DescribedToggle<Description: View>: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    @ViewBuilder let description: () -> Description

    init(_ title: LocalizedStringKey,
         isOn: Binding<Bool>,
         @ViewBuilder description: @escaping () -> Description) {
        self.title = title
        self._isOn = isOn
        self.description = description
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                description()
                    .appFont(.settingsLabel)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension DescribedToggle where Description == Text {
    init(_ title: LocalizedStringKey, isOn: Binding<Bool>, description: LocalizedStringKey) {
        self.init(title, isOn: isOn) { Text(description) }
    }
}

// MARK: - SettingSliderRow

/// Settings row: label with trailing value readout above a slider,
/// optionally followed by a secondary caption line.
struct SettingSliderRow: View {
    let label: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let valueText: String
    var caption: LocalizedStringKey?

    init(_ label: LocalizedStringKey,
         value: Binding<Double>,
         in range: ClosedRange<Double>,
         step: Double? = nil,
         valueText: String,
         caption: LocalizedStringKey? = nil) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.valueText = valueText
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .appFont(.subheadline)
                Spacer()
                Text(verbatim: valueText)
                    .appFont(.settingsLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let step {
                Slider(value: $value, in: range, step: step)
                    .labelsHidden()
            } else {
                Slider(value: $value, in: range)
                    .labelsHidden()
            }
            if let caption {
                Text(caption)
                    .appFont(.settingsLabel)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - BatteryIndicator

/// Percent → SF Symbol / tint mapping shared by the device status bar and
/// the Info pane's status table.
enum BatteryIndicator {
    static func symbolName(pct: Int, charging: Bool) -> String {
        guard !charging else { return "battery.100percent.bolt" }
        switch pct {
        case 0..<13: return "battery.0percent"
        case 13..<38: return "battery.25percent"
        case 38..<63: return "battery.50percent"
        case 63..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// `healthy` is the tint above 50%: the slim status bar stays neutral
    /// (`.secondary`); the Info table affirms with `.green`.
    static func tint(pct: Int, charging: Bool, healthy: Color) -> Color {
        if charging { return .green }
        if pct < 20 { return .red }
        if pct < 50 { return .orange }
        return healthy
    }
}
