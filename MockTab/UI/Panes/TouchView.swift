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
///   • Pinch to zoom
///
/// What this pane does not do:
///   • Mission Control / Spaces / Launchpad / App Exposé gestures
///   • Force Touch
///   • Native multi-touch `NSTouch` events that apps like Final Cut consume
///
/// The first group is unimplemented, not impossible — see project memory
/// `project_dock_swipe_gesture_feasibility`. The rest is a genuine platform
/// ceiling.
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

    /// For the two settings that only affect the *scroll* reading of a
    /// two-finger gesture (direction, momentum) — unlike Pinch to Zoom and
    /// Rotate, which are independent of Two-Finger Scroll and use
    /// `settings.touchEnabled` alone. Matches the `.disabled(!settings.touchEnabled
    /// || !settings.twoFingerScroll)` on those two rows below.
    private var gestureRowOpacity: Double {
        (settings.touchEnabled && settings.twoFingerScroll) ? 1 : 0.5
    }

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
            .opacity(settings.touchEnabled ? 1 : 0.5)
            .help("A brief touch with no significant motion posts a left mouse click. Off by default — most users find it produces phantom clicks.")

            SettingSliderRow(
                "Cursor Speed",
                value: settings.recordingBinding(
                    String(localized: "Cursor Speed", comment: "Undo action name: touch cursor-speed multiplier in the Touch pane"),
                    get: { settings.touchSensitivity },
                    set: { settings.touchSensitivity = $0 }),
                in: 0.25...4.0,
                step: 0.25,
                valueText: String(format: "%.2f×", settings.touchSensitivity),
                caption: "Multiplier for cursor motion from finger drag."
            )
            .disabled(!settings.touchEnabled)
            .opacity(settings.touchEnabled ? 1 : 0.5)
            .help("Multiplier for cursor motion from finger drag. 1.00× is the natural mapping through the touch area; raise to move faster across the screen, lower for finer control.")
        }
    }

    private var scrollSection: some View {
        Section("Gestures") {
            DescribedToggle(
                "Two-Finger Scroll",
                isOn: settings.recordingBinding(
                    String(localized: "Two-Finger Scroll", comment: "Undo action name: two-finger scroll toggle in the Touch pane"),
                    get: { settings.twoFingerScroll },
                    set: { settings.twoFingerScroll = $0 }),
                description: "Use a two-finger gesture to scroll."
            )
            .disabled(!settings.touchEnabled)
            .opacity(settings.touchEnabled ? 1 : 0.5)
            .help("Two fingers moving together post smooth scroll events that apps treat as trackpad scrolling, including rubber-banding in Safari and Preview.")

            DescribedToggle(
                "Pinch to Zoom",
                isOn: settings.recordingBinding(
                    String(localized: "Pinch to Zoom", comment: "Undo action name: pinch-to-zoom toggle in the Touch pane"),
                    get: { settings.pinchZoomEnabled },
                    set: { settings.pinchZoomEnabled = $0 }),
                description: "Use two fingers to pinch and zoom in or out."
            )
            .disabled(!settings.touchEnabled)
            .opacity(settings.touchEnabled ? 1 : 0.5)
            .help("Two fingers spreading or pinching together zoom in or out, the same as a trackpad pinch — works anywhere a trackpad pinch would, including Safari, Preview, and Photoshop. Independent of Two-Finger Scroll: scroll, pinch, and rotate are alternate readings of the same two-finger gesture, so each can be on or off on its own.")

            // Smart Zoom's toggle is deliberately not shown: hardware testing
            // 2026-08-08 found the double-tap detection unreliable (~70% of
            // taps produced no or an unpredictable response). Detection and
            // event-posting stay in place — `settings.smartZoomEnabled`
            // simply has no UI path to becoming true — so the work isn't
            // lost, but nothing exposes it until that reliability improves.

            DescribedToggle(
                "Rotate",
                isOn: settings.recordingBinding(
                    String(localized: "Rotate", comment: "Undo action name: two-finger rotate toggle in the Touch pane"),
                    get: { settings.rotateEnabled },
                    set: { settings.rotateEnabled = $0 }),
                description: "Swivel two fingers apart to rotate."
            )
            .disabled(!settings.touchEnabled)
            .opacity(settings.touchEnabled ? 1 : 0.5)
            .help("Two fingers held well apart, swiveling about their center, rotate — the same as a trackpad rotate gesture. Independent of Two-Finger Scroll: scroll, pinch, and rotate are alternate readings of the same two-finger gesture, so each can be on or off on its own.")

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
            .opacity(gestureRowOpacity)
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
            .opacity(gestureRowOpacity)
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

            TouchAreaCropView(settings: settings, spec: spec, productID: productID)
                .frame(height: 200)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
                .disabled(!settings.touchEnabled)
                .opacity(settings.touchEnabled ? 1 : 0.5)

            HStack {
                Spacer()
                Button(String(localized: "Reset to Full Surface",
                              comment: "Touch pane: reset the touch area to cover the entire touch surface")) {
                    let snap = TabletSettings.AreaSnapshot(
                        x: settings.touchAreaX, y: settings.touchAreaY,
                        w: settings.touchAreaWidth, h: settings.touchAreaHeight)
                    settings.touchAreaX = 0; settings.touchAreaY = 0
                    settings.touchAreaWidth = 1; settings.touchAreaHeight = 1
                    settings.recordTouchAreaDrag(before: snap)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                // Gated on `touchEnabled` only — deliberately not also on
                // "the rect is already full", which the pen pane doesn't do
                // either. A reset button that greys out at exactly the state
                // it produces reads as broken rather than as already-done.
                .disabled(!settings.touchEnabled)
                .help("Reset the touch area to the full touch surface (undoable).")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
    }

    // MARK: - Touch area crop editor

    /// Visual, drag-based editor for the touch active area — the shared
    /// `NormalizedAreaEditor` the pen pane uses, configured to match it.
    ///
    /// Deliberately *not* matched on one point: `TabletAreaView` swaps the
    /// aspect ratio for a rotated tablet orientation, and this doesn't,
    /// because the touch mapping itself ignores orientation (see
    /// `TouchStateTracker.screenPoint`).  Showing a rotated box here would
    /// promise a mapping the injector doesn't perform.
    private struct TouchAreaCropView: View {
        @ObservedObject var settings: TabletSettings
        let spec: WacomDeviceSpec?
        let productID: Int?

        /// Same derivation as `TabletAreaView.activeAspectRatio`, and for the
        /// same reason: raw coordinate density isn't equal on both axes, so a
        /// maxima ratio isn't a stand-in for the surface's visual shape.  It
        /// is worst on the two models whose touch space the kernel hardcodes
        /// to a square 4096×4096 — PTH-850 and PTH-651 — where `touchMaxX /
        /// touchMaxY` is 1.00 against a physical 1.60, drawing a square box
        /// for a widescreen tablet (reported on issue #12).  Physical
        /// millimetres first; the maxima only as a fallback.
        private var aspectRatio: Double {
            if let pid = productID,
                let profile = VendorDeviceRegistry.profile(forProductID: pid),
                let w = profile.activeWidthMM, w > 0, let h = profile.activeHeightMM, h > 0
            {
                return w / h
            }
            if let w = spec?.activeWidthMM, w > 0, let h = spec?.activeHeightMM, h > 0 {
                return w / h
            }
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
            // `onCommit` fires once on drag-end, so a crop drag is undoable
            // here exactly as it is in the pen pane.
            NormalizedAreaEditor(
                aspectRatio: aspectRatio,
                rect: rectBinding,
                onCommit: { oldRect in
                    settings.recordTouchAreaDrag(before: TabletSettings.AreaSnapshot(
                        x: oldRect.x, y: oldRect.y, w: oldRect.w, h: oldRect.h))
                })
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
                    Text("Not all system gestures are available.")
                        .appFont(.subheadline)
                        .fontWeight(.semibold)
                    Text("MockTab does not currently support all system gestures, such as Mission Control, Spaces, Launchpad, and App Exposé.")
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private typealias TouchState = (
        enabled: Bool, tapToClick: Bool, sensitivity: Double,
        twoFingerScroll: Bool, reverseScroll: Bool, twoFingerScrollMomentum: Bool,
        pinchZoom: Bool, smartZoom: Bool, rotate: Bool,
        areaX: Double, areaY: Double, areaW: Double, areaH: Double
    )

    private func resetToDefaults() {
        let old: TouchState = (
            settings.touchEnabled, settings.tapToClick, settings.touchSensitivity,
            settings.twoFingerScroll, settings.reverseScrollDirection, settings.twoFingerScrollMomentum,
            settings.pinchZoomEnabled, settings.smartZoomEnabled, settings.rotateEnabled,
            settings.touchAreaX, settings.touchAreaY,
            settings.touchAreaWidth, settings.touchAreaHeight
        )
        let defaults: TouchState = (false, false, 1.0, true, false, true, false, false, false, 0, 0, 1, 1)
        applyTouchState(defaults, undoTo: old)
    }

    /// Self-recursive so "Reset Pane to Defaults" also redoes — see
    /// `TabletAreaView.applyAreaState` for the same pattern.
    private func applyTouchState(_ new: TouchState, undoTo old: TouchState) {
        settings.undoManager?.beginUndoGrouping()
        (settings.touchEnabled, settings.tapToClick, settings.touchSensitivity,
         settings.twoFingerScroll, settings.reverseScrollDirection, settings.twoFingerScrollMomentum,
         settings.pinchZoomEnabled, settings.smartZoomEnabled, settings.rotateEnabled,
         settings.touchAreaX, settings.touchAreaY,
         settings.touchAreaWidth, settings.touchAreaHeight) = new
        settings.record(String(localized: "Reset Pane to Defaults")) {
            self.applyTouchState(old, undoTo: new)
        }
        settings.undoManager?.endUndoGrouping()
    }
}

