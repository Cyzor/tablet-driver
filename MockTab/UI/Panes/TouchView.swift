// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Capacitive finger-touch settings.
///
/// Only registered as a sidebar tab on devices whose `WacomDeviceSpec` has
/// `hasFingerTouch == true`.  See `SettingsWindowController` for the gate.
///
/// What this pane *can* do via macOS-supported public APIs:
///   • Cursor motion from a single finger
///   • Smooth two-finger scrolling (with trackpad-style phase + rubber-band)
///   • Optional tap-to-click
///
/// What it *cannot* do without Apple-issued private entitlements — and what
/// users will reasonably expect from a tablet driver:
///   • Mission Control / Spaces / Launchpad gestures
///   • App Exposé three- and four-finger gestures
///   • Native multi-touch `NSTouch` events that apps like Final Cut consume
///
/// Those last three require posting into the WindowServer MultitouchSupport
/// pipeline, which is read-only for third-party processes.  The disclaimer
/// at the bottom of the pane is the truthful description of the ceiling.
struct TouchView: View {

    @ObservedObject var settings: TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    var productID: Int?

    private var spec: WacomDeviceSpec? {
        productID.flatMap { WacomDeviceRegistry.spec(for: $0) }
    }

    private var hasFingerTouch: Bool { spec?.hasFingerTouch == true }
    private var maxTouchContacts: Int { spec?.maxTouchContacts ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if hasFingerTouch {
                    enableSection
                    pointerSection
                    if maxTouchContacts > 1 {
                        scrollSection
                    }
                    areaSection
                    disclaimerSection
                } else {
                    Section {
                        Text(LocalizedStringKey("The connected tablet does not have a capacitive touch surface."))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            DeviceStatusBar(
                settings: settings, tabletManager: tabletManager,
                registry: registry, productID: productID ?? 0)
        }
    }

    // MARK: - Sections

    private var enableSection: some View {
        Section {
            Toggle(
                String(localized: "Enable finger touch",
                       comment: "Touch pane: master toggle for capacitive touch input"),
                isOn: $settings.touchEnabled)
                .help(LocalizedStringKey("When off, the tablet's touch surface is ignored. Pen input is unaffected."))
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("Touch")).appFont(.headline)
                DeviceNameLabel(tabletManager: tabletManager, registry: registry)
            }
        }
    }

    private var pointerSection: some View {
        Section {
            Toggle(
                String(localized: "Tap to click",
                       comment: "Touch pane: brief tap posts a left click"),
                isOn: $settings.tapToClick)
                .disabled(!settings.touchEnabled)
                .help(LocalizedStringKey("A brief touch with no significant motion posts a left mouse click. Off by default — most users find it produces phantom clicks."))

            HStack {
                Text(LocalizedStringKey("Cursor speed"))
                Slider(value: $settings.touchSensitivity, in: 0.25...4.0)
                    .disabled(!settings.touchEnabled)
                Text(String(format: "%.2f×", settings.touchSensitivity))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            .help(LocalizedStringKey("Multiplier for cursor motion from finger drag. 1.00× is the natural mapping through the touch area; raise to move faster across the screen, lower for finer control."))
        } header: {
            Text(LocalizedStringKey("Pointer")).appFont(.headline)
        }
    }

    private var scrollSection: some View {
        Section {
            Toggle(
                String(localized: "Two-finger scroll",
                       comment: "Touch pane: enable two-finger scroll-wheel emulation"),
                isOn: $settings.twoFingerScroll)
                .disabled(!settings.touchEnabled)
                .help(LocalizedStringKey("Two fingers moving together post smooth scroll events that apps treat as trackpad scrolling, including rubber-banding in Safari and Preview."))

            Toggle(
                String(localized: "Reverse direction",
                       comment: "Touch pane: reverse scroll direction (off = content follows fingers)"),
                isOn: $settings.reverseScrollDirection)
                .disabled(!settings.touchEnabled || !settings.twoFingerScroll)
                .help(LocalizedStringKey("On: scroll content moves opposite to finger motion, like a classic mouse wheel. Off (default): content follows your fingers."))
        } header: {
            Text(LocalizedStringKey("Scrolling")).appFont(.headline)
        }
    }

    private var areaSection: some View {
        Section {
            Text(LocalizedStringKey("Define the active surface area for touch input.  Not available on all devices."))
                .appFont(.callout)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))

            TouchAreaCropView(settings: settings, spec: spec)
                .frame(height: 200)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
                .disabled(!settings.touchEnabled)
                .opacity(settings.touchEnabled ? 1 : 0.5)

            HStack {
                Spacer()
                Button(String(localized: "Reset to full surface",
                              comment: "Touch pane: reset the touch area to cover the entire touch surface")) {
                    settings.touchAreaX = 0
                    settings.touchAreaY = 0
                    settings.touchAreaWidth = 1
                    settings.touchAreaHeight = 1
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!settings.touchEnabled)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        } header: {
            Text(LocalizedStringKey("Touch Area")).appFont(.headline)
        }
    }

    // MARK: - Touch area crop editor

    /// Visual, drag-based editor for the touch active area.  Aspect ratio
    /// comes from the device's touch-coordinate maxima; the editor itself
    /// is the shared `NormalizedAreaEditor` used by the pen pane.
    private struct TouchAreaCropView: View {
        @ObservedObject var settings: TabletSettings
        let spec: WacomDeviceSpec?

        private var aspectRatio: Double {
            let mx = spec?.touchMaxX ?? 0
            let my = spec?.touchMaxY ?? 0
            guard mx > 0, my > 0 else { return 16.0 / 10.0 }
            return Double(mx) / Double(my)
        }

        private var rectBinding: Binding<NormalizedRect> {
            Binding(
                get: {
                    NormalizedRect(
                        x: settings.touchAreaX, y: settings.touchAreaY,
                        w: settings.touchAreaWidth, h: settings.touchAreaHeight)
                },
                set: { r in
                    settings.touchAreaX = r.x
                    settings.touchAreaY = r.y
                    settings.touchAreaWidth = r.w
                    settings.touchAreaHeight = r.h
                }
            )
        }

        var body: some View {
            NormalizedAreaEditor(aspectRatio: aspectRatio, rect: rectBinding)
        }
    }

    private var disclaimerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey("System gestures not supported"))
                        .appFont(.subheadline)
                        .fontWeight(.semibold)
                    Text(LocalizedStringKey("Mission Control, Spaces, Launchpad, and other system-wide multi-touch gestures require Wacom's official driver. macOS does not let third-party apps post the native trackpad events those gestures depend on."))
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

