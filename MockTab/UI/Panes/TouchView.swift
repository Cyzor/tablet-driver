// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import TabletKit

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
    let instanceKey: DeviceInstanceKey?
    /// Model axis of the bound unit — spec/catalog lookups key on this.
    private var productID: Int? { instanceKey?.productID }

    private var spec: WacomDeviceSpec? {
        productID.flatMap { WacomDeviceRegistry.spec(for: $0) }
    }

    private var hasFingerTouch: Bool { spec?.hasFingerTouch == true }
    private var maxTouchContacts: Int { spec?.maxTouchContacts ?? 0 }

    var body: some View {
        SettingsPane(
            settings: settings, tabletManager: tabletManager, registry: registry,
            instanceKey: instanceKey, overrideKeys: AppOverrideBar.touchKeys,
            onResetToDefaults: resetToDefaults
        ) {
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
                    Text("The connected tablet does not have a capacitive touch surface.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Sections

    private var enableSection: some View {
        Section {
            DescribedToggle(
                "Enable Finger Touch",
                isOn: settings.recordingBinding(
                    String(localized: "Touch"),
                    get: { settings.touchEnabled },
                    set: { settings.touchEnabled = $0 }),
                description: "Use your finger to move and click."
            )
        } header: {
            PaneSectionHeader("Touch") {
                DeviceNameLabel(tabletManager: tabletManager, registry: registry, instanceKey: instanceKey)
            }
        }
    }

    private var pointerSection: some View {
        Section("Pointer") {
            DescribedToggle(
                "Tap to Click",
                isOn: settings.recordingBinding(
                    String(localized: "Tap to Click", comment: "Undo action name: tap-to-click toggle in the Touch pane"),
                    get: { settings.tapToClick },
                    set: { settings.tapToClick = $0 }),
                description: "Briefly touch the tablet's surface to click."
            )
            .disabled(!settings.touchEnabled)
            .help("A brief touch with no significant motion posts a left mouse click. Off by default — most users find it produces phantom clicks.")

            SettingSliderRow(
                "Cursor Speed",
                value: settings.recordingBinding(
                    String(localized: "Cursor Speed", comment: "Undo action name: touch cursor-speed multiplier in the Touch pane"),
                    get: { settings.touchSensitivity },
                    set: { settings.touchSensitivity = $0 }),
                in: 0.25...4.0,
                valueText: String(format: "%.2f×", settings.touchSensitivity),
                caption: "Multiplier for cursor motion from finger drag."
            )
            .disabled(!settings.touchEnabled)
            .help("Multiplier for cursor motion from finger drag. 1.00× is the natural mapping through the touch area; raise to move faster across the screen, lower for finer control.")
        }
    }

    private var scrollSection: some View {
        Section("Scrolling") {
            DescribedToggle(
                "Two-Finger Scroll",
                isOn: settings.recordingBinding(
                    String(localized: "Two-Finger Scroll", comment: "Undo action name: two-finger scroll toggle in the Touch pane"),
                    get: { settings.twoFingerScroll },
                    set: { settings.twoFingerScroll = $0 }),
                description: "Use a two-finger gesture to scroll."
            )
            .disabled(!settings.touchEnabled)
            .help("Two fingers moving together post smooth scroll events that apps treat as trackpad scrolling, including rubber-banding in Safari and Preview.")

            DescribedToggle(
                "Pinch to Zoom",
                isOn: settings.recordingBinding(
                    String(localized: "Pinch to Zoom", comment: "Undo action name: pinch-to-zoom toggle in the Touch pane"),
                    get: { settings.pinchZoomEnabled },
                    set: { settings.pinchZoomEnabled = $0 }),
                description: "Use two fingers to pinch and zoom in or out."
            )
            .disabled(!settings.touchEnabled || !settings.twoFingerScroll)
            .help("Two fingers spreading or pinching together zoom in or out, the same as a trackpad pinch — works anywhere a trackpad pinch would, including Safari, Preview, and Photoshop.")

            DescribedToggle(
                "Reverse Direction",
                isOn: settings.recordingBinding(
                    String(localized: "Scroll Direction", comment: "Undo action name: touch scroll-direction toggle in the Touch pane"),
                    get: { settings.reverseScrollDirection },
                    set: { settings.reverseScrollDirection = $0 })
            ) {
                Text(
                    settings.reverseScrollDirection
                        ? "Content moves opposite your fingers."
                        : "Content follows your fingers.")
            }
            .disabled(!settings.touchEnabled || !settings.twoFingerScroll)
            .help("On: scroll content moves opposite to finger motion, like a classic mouse wheel. Off (default): content follows your fingers.")

            DescribedToggle(
                "Momentum Scrolling",
                isOn: settings.recordingBinding(
                    String(localized: "Touch Momentum Scrolling", comment: "Undo action name: two-finger scroll momentum toggle in the Touch pane"),
                    get: { settings.twoFingerScrollMomentum },
                    set: { settings.twoFingerScrollMomentum = $0 }),
                description: "Inertia scrolling. Compatibility varies by app."
            )
            .disabled(!settings.touchEnabled || !settings.twoFingerScroll)
            .help("On (default): two fingers post a phased trackpad-style stream, so scroll-view apps coast after you lift. Off: a simpler stream that scrolls in far more apps (including Calendar's Month/Year view), but without inertia.")
        }
    }

    private var areaSection: some View {
        Section("Touch Area") {
            Text("Define the active surface area for touch input.  Not available on all devices.")
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
                Button(String(localized: "Reset to Full Surface",
                              comment: "Touch pane: reset the touch area to cover the entire touch surface")) {
                    applyTouchAreaReset(
                        to: (0, 0, 1, 1),
                        undoTo: (settings.touchAreaX, settings.touchAreaY,
                                 settings.touchAreaWidth, settings.touchAreaHeight))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!settings.touchEnabled)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
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
                    Text("System gestures not supported")
                        .appFont(.subheadline)
                        .fontWeight(.semibold)
                    Text("Mission Control, Spaces, Launchpad, and other system-wide multi-touch gestures require Wacom's official driver. macOS does not let third-party apps post the native trackpad events those gestures depend on.")
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Self-recursive so "Touch Area Reset" also redoes — see
    /// `TabletSettings.recordAreaDrag` for the same pattern.
    private func applyTouchAreaReset(
        to new: (Double, Double, Double, Double), undoTo old: (Double, Double, Double, Double)
    ) {
        (settings.touchAreaX, settings.touchAreaY,
         settings.touchAreaWidth, settings.touchAreaHeight) = new
        settings.record(String(localized: "Touch Area Reset", comment: "Undo action name: resetting the touch active area in the Touch pane")) {
            self.applyTouchAreaReset(to: old, undoTo: new)
        }
    }

    private typealias TouchState = (
        enabled: Bool, tapToClick: Bool, sensitivity: Double,
        twoFingerScroll: Bool, reverseScroll: Bool, twoFingerScrollMomentum: Bool,
        pinchZoom: Bool,
        areaX: Double, areaY: Double, areaW: Double, areaH: Double
    )

    private func resetToDefaults() {
        let old: TouchState = (
            settings.touchEnabled, settings.tapToClick, settings.touchSensitivity,
            settings.twoFingerScroll, settings.reverseScrollDirection, settings.twoFingerScrollMomentum,
            settings.pinchZoomEnabled,
            settings.touchAreaX, settings.touchAreaY,
            settings.touchAreaWidth, settings.touchAreaHeight
        )
        let defaults: TouchState = (false, false, 1.0, true, false, true, false, 0, 0, 1, 1)
        applyTouchState(defaults, undoTo: old)
    }

    /// Self-recursive so "Reset Pane to Defaults" also redoes — see
    /// `TabletAreaView.applyAreaState` for the same pattern.
    private func applyTouchState(_ new: TouchState, undoTo old: TouchState) {
        settings.undoManager?.beginUndoGrouping()
        (settings.touchEnabled, settings.tapToClick, settings.touchSensitivity,
         settings.twoFingerScroll, settings.reverseScrollDirection, settings.twoFingerScrollMomentum,
         settings.pinchZoomEnabled,
         settings.touchAreaX, settings.touchAreaY,
         settings.touchAreaWidth, settings.touchAreaHeight) = new
        settings.record(String(localized: "Reset Pane to Defaults")) {
            self.applyTouchState(old, undoTo: new)
        }
        settings.undoManager?.endUndoGrouping()
    }
}

