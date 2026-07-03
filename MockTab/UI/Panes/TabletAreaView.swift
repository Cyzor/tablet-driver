// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import TabletKit

/// Interactive tablet active-area editor.
/// Shows the full digitizer surface with a crop-tool-style draggable
/// active area rectangle — resizable from all four edges and corners,
/// repositionable by dragging the interior.
struct TabletAreaView: View {
    @ObservedObject var settings: TabletSettings

    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry

    /// Called when the user selects a different tablet from the picker.
    var onDeviceSelected: ((Int) -> Void)?

    /// The product ID this view is currently showing.
    var boundProductID: Int?

    @AppStorage(AppearancePrefs.storageKey) private var textSizeIndex: Int = AppearancePrefs.defaultIndex
    private var textScale: CGFloat { AppearancePrefs.scale(forIndex: textSizeIndex) }

    // MARK: - Digitizer dimensions

    /// Digitizer width for the currently-shown device, in hardware line-units.
    private var activeDeviceMaxX: Int {
        if let pid = boundProductID {
            if let s = tabletManager.contexts[pid]?.tabletDevice?.spec { return s.maxX }
            if let s = WacomDeviceRegistry.spec(for: pid) { return s.maxX }
        }
        return 44800
    }

    /// Digitizer height for the currently-shown device, in hardware line-units.
    private var activeDeviceMaxY: Int {
        if let pid = boundProductID {
            if let s = tabletManager.contexts[pid]?.tabletDevice?.spec { return s.maxY }
            if let s = WacomDeviceRegistry.spec(for: pid) { return s.maxY }
        }
        return 29600
    }

    /// True if the connected device is a pen display (Cintiq-class).
    private var activeDeviceIsPenDisplay: Bool {
        if let pid = boundProductID {
            if let s = tabletManager.contexts[pid]?.tabletDevice?.spec { return s.isPenDisplay }
            if let s = WacomDeviceRegistry.spec(for: pid) { return s.isPenDisplay }
        }
        return false
    }

    /// True if the bound device is currently physically connected.
    private var activeDeviceIsConnected: Bool {
        guard let pid = boundProductID else { return false }
        return tabletManager.contexts[pid]?.isConnected == true
    }

    /// Raw digitizer coordinate density isn't always the same on both axes
    /// (confirmed on Xencelabs' Pen Display: very different units-per-mm per
    /// axis), so `maxX / maxY` in raw units is not a reliable stand-in for
    /// the tablet's visual aspect ratio — it rendered this preview box as a
    /// tall portrait rectangle for a landscape display. Prefer the vendor
    /// profile's physical mm dimensions when available; same fix as
    /// InputInjector.mapToScreen and CalibrationSession's proportional
    /// mapping.
    private var activeAspectRatio: Double {
        if let pid = boundProductID,
            let profile = VendorDeviceRegistry.profile(forProductID: pid),
            let w = profile.activeWidthMM, w > 0, let h = profile.activeHeightMM, h > 0
        {
            return w / h
        }
        let y = activeDeviceMaxY
        guard y > 0 else { return 44800.0 / 29600.0 }
        return Double(activeDeviceMaxX) / Double(y)
    }

    /// Aspect ratio adjusted for the user's tablet orientation (90°/270° swap
    /// the canvas axes); passed through to `NormalizedAreaEditor`.
    private var orientedAspectRatio: Double {
        settings.tabletOrientation.swapsAxes
            ? 1.0 / activeAspectRatio
            : activeAspectRatio
    }

    /// Smallest dimension (as a fraction of the surface) the user can shrink
    /// the active area to — enforced by both the `NormalizedAreaEditor` drag
    /// gestures and the Width/Height pixel-field clamping below.
    private static let minFraction: Double = 0.05

    /// Single rect binding over the four `activeArea*` settings, the form the
    /// shared crop editor consumes.  The editor writes the binding once on
    /// drag-end, so this doesn't cause 60 Hz `persist(...)` calls.
    private var activeAreaBinding: Binding<NormalizedRect> {
        Binding(
            get: {
                NormalizedRect(
                    x: settings.activeAreaX, y: settings.activeAreaY,
                    w: settings.activeAreaWidth, h: settings.activeAreaHeight)
            },
            set: { r in
                settings.activeAreaX = r.x
                settings.activeAreaY = r.y
                settings.activeAreaWidth = r.w
                settings.activeAreaHeight = r.h
            }
        )
    }

    var body: some View {
        SettingsPane(
            settings: settings, tabletManager: tabletManager, registry: registry,
            productID: boundProductID, overrideKeys: AppOverrideBar.areaKeys
        ) {
                Section {
                    NormalizedAreaEditor(
                        aspectRatio: orientedAspectRatio,
                        rect: activeAreaBinding,
                        onCommit: { oldRect in
                            settings.recordAreaDrag(before: TabletSettings.AreaSnapshot(
                                x: oldRect.x, y: oldRect.y, w: oldRect.w, h: oldRect.h))
                        }
                    ) { areaRect, cs in
                        Canvas { ctx, _ in
                            tabletBadge(ctx: ctx, areaRect: areaRect)
                        }
                        .frame(width: cs.width, height: cs.height)
                    }
                    .frame(height: 200)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))

                    coordinateReadout
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))

                    HStack {

                        Toggle("Proportional mapping", isOn: proportionalMappingBinding)
                            .toggleStyle(.checkbox)
                            .help("Lock the tablet-to-screen mapping ratio to match your display's proportions, so the cursor never feels stretched or compressed.")
                        
                        Spacer()
                        
                        Button("Reset to Full Area") {
                            let snap = TabletSettings.AreaSnapshot(
                                x: settings.activeAreaX, y: settings.activeAreaY,
                                w: settings.activeAreaWidth, h: settings.activeAreaHeight)
                            settings.activeAreaX = 0; settings.activeAreaY = 0
                            settings.activeAreaWidth = 1; settings.activeAreaHeight = 1
                            settings.recordAreaDrag(before: snap)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Reset the active area to the full tablet surface (undoable).")

                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                } header: {
                    sectionHeading
                }

                if activeDeviceIsPenDisplay {
                    Section("Pen Display Calibration") {
                        // Calibration status + actions
                        HStack {
                            if !activeDeviceIsConnected {
                                Image(systemName: "display.trianglebadge.exclamationmark")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text("Display not connected")
                                    .foregroundStyle(.secondary)
                            } else if let cal = activeCalibration {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Calibrated")
                                        .appFont(.body)
                                    Text(cal.calibratedAt, format: .dateTime.month(.abbreviated).day().year())
                                        .appFont(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                    .accessibilityHidden(true)
                                Text("Not calibrated")
                            }
                            Spacer()
                            Button("Calibrate…") {
                                startCalibration()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!activeDeviceIsConnected || settings.targetDisplayIndex == TabletSettings.displayModeAll)
                            .help("Open the calibration overlay to tap crosshair targets on your pen display.")
                            if activeCalibration != nil {
                                Button("Reset") {
                                    resetCalibration()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        // Manual fine-tune offset
                        DisclosureGroup("Manual Fine-Tune") {
                            // Vertical padding keeps the rounded-border fields and
                            // buttons from clipping against the disclosure row bounds.
                            HStack(spacing: 16) {
                                HStack(spacing: 4) {
                                    Text("Horizontal:")
                                        .foregroundStyle(.secondary)
                                    TextField("", value: parallaxXBinding,
                                              format: .number.precision(.fractionLength(1)))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 60)
                                        .multilineTextAlignment(.trailing)
                                    Text("pt").foregroundStyle(.secondary)
                                }
                                HStack(spacing: 4) {
                                    Text("Vertical:")
                                        .foregroundStyle(.secondary)
                                    TextField("", value: parallaxYBinding,
                                              format: .number.precision(.fractionLength(1)))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 60)
                                        .multilineTextAlignment(.trailing)
                                    Text("pt").foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Reset Offset") {
                                    let oldX = settings.parallaxOffsetX
                                    let oldY = settings.parallaxOffsetY
                                    settings.parallaxOffsetX = 0
                                    settings.parallaxOffsetY = 0
                                    settings.record("Reset Offset") {
                                        settings.parallaxOffsetX = oldX
                                        settings.parallaxOffsetY = oldY
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(settings.parallaxOffsetX == 0 && settings.parallaxOffsetY == 0)
                            }
                            .padding(.vertical, 6)
                        }
                        .help("Apply a small constant offset on top of calibration for sub-pixel fine-tuning.")
                    }
                }

                Section("Orientation") {
                    OrientationPickerView(settings: settings)
                }
        }
    }

    // MARK: - Device identity

    private struct DeviceLabel {
        let primary: String
        let secondary: String?
    }

    private var deviceLabel: DeviceLabel {
        guard let pid = boundProductID else {
            if let activePID = tabletManager.activeContext?.productID {
                return DeviceLabel(primary: TabletManager.deviceName(forProductID: activePID), secondary: nil)
            }
            return DeviceLabel(primary: String(localized: "No device", comment: "Fallback label when no tablet is connected"), secondary: nil)
        }
        let modelName = TabletManager.deviceName(forProductID: pid)
        if let tablet = registry.knownTablets.first(where: { $0.id == pid }),
           tablet.nickname != tablet.modelName {
            return DeviceLabel(primary: tablet.nickname, secondary: modelName)
        }
        return DeviceLabel(primary: modelName, secondary: nil)
    }

    // MARK: - Section heading

    private var sectionHeading: some View {
        PaneSectionHeader("Active Surface Area") {
            DeviceNameLabel(tabletManager: tabletManager, registry: registry, productID: boundProductID)
        }
    }

    // MARK: - Calibration

    /// The active calibration entry for the current orientation and display, if any.
    private var activeCalibration: CalibrationEntry? {
        let uuid = resolveCurrentDisplayUUID()
        return settings.calibration(for: settings.tabletOrientation, displayUUID: uuid)
    }

    /// Resolve the persistent UUID string for the current target display.
    /// Returns "" for the "All Displays" mode or when resolution fails.
    private func resolveCurrentDisplayUUID() -> String {
        let idx = settings.targetDisplayIndex
        if idx == TabletSettings.displayModeAll { return "" }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return CalibrationKey.uuidString(for: CGMainDisplayID())
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return CalibrationKey.uuidString(for: CGMainDisplayID())
        }
        if idx > 0, idx <= ids.count { return CalibrationKey.uuidString(for: ids[idx - 1]) }
        return CalibrationKey.uuidString(for: CGMainDisplayID())
    }

    @State private var calibrationWindow: CalibrationOverlayWindow?

    /// Launch the calibration overlay on the target display.
    private func startCalibration() {
        let idx = settings.targetDisplayIndex
        guard idx != TabletSettings.displayModeAll else { return }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return }
        let displayID: CGDirectDisplayID
        if idx > 0, idx <= ids.count {
            displayID = ids[idx - 1]
        } else {
            displayID = CGMainDisplayID()
        }
        let displayUUID = CalibrationKey.uuidString(for: displayID)
        guard !displayUUID.isEmpty else { return }

        let session = CalibrationSession(
            settings: settings,
            tabletManager: tabletManager,
            displayUUID: displayUUID,
            displayBounds: CGDisplayBounds(displayID),
            orientation: settings.tabletOrientation)

        let window = CalibrationOverlayWindow(session: session)
        calibrationWindow = window
        window.beginCalibration()
    }

    /// Clear calibration data for the current orientation and display.
    private func resetCalibration() {
        let uuid = resolveCurrentDisplayUUID()
        let key = CalibrationKey(orientation: settings.tabletOrientation.rawValue, displayUUID: uuid)
        let oldJSON = settings.calibrationJSON
        var entries = settings.calibrationEntries
        entries.removeAll { $0.key == key }
        settings.calibrationEntries = entries
        settings.record("Reset Calibration") {
            settings.calibrationJSON = oldJSON
        }
        tabletManager.activeContext?.injector.invalidateCalibrationCache()
    }

    /// Binding that clamps and registers undo for horizontal parallax offset.
    private var parallaxXBinding: Binding<Double> {
        Binding(
            get: { settings.parallaxOffsetX },
            set: { newValue in
                let clamped = Swift.min(Swift.max(newValue, -20), 20)
                let oldValue = settings.parallaxOffsetX
                settings.parallaxOffsetX = clamped
                settings.record("Parallax Offset") {
                    settings.parallaxOffsetX = oldValue
                }
            }
        )
    }

    /// Binding that clamps and registers undo for vertical parallax offset.
    private var parallaxYBinding: Binding<Double> {
        Binding(
            get: { settings.parallaxOffsetY },
            set: { newValue in
                let clamped = Swift.min(Swift.max(newValue, -20), 20)
                let oldValue = settings.parallaxOffsetY
                settings.parallaxOffsetY = clamped
                settings.record("Parallax Offset") {
                    settings.parallaxOffsetY = oldValue
                }
            }
        )
    }

    /// Binding that registers undo when proportional mapping is toggled.
    private var proportionalMappingBinding: Binding<Bool> {
        Binding(
            get: { settings.proportionalMapping },
            set: { newValue in
                let oldValue = settings.proportionalMapping
                settings.proportionalMapping = newValue
                settings.record("Proportional Mapping") {
                    settings.proportionalMapping = oldValue
                }
            }
        )
    }

    // MARK: - Coordinate readout

    private var coordinateReadout: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Width").foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                pixelField(fraction: $settings.activeAreaWidth,
                           maxValue: activeDeviceMaxX,
                           minFraction: Self.minFraction,
                           maxFraction: 1 - settings.activeAreaX)
                Text("Height").foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                pixelField(fraction: $settings.activeAreaHeight,
                           maxValue: activeDeviceMaxY,
                           minFraction: Self.minFraction,
                           maxFraction: 1 - settings.activeAreaY)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// An editable text field showing a 0–100 % value.
    private func percentField(_ binding: Binding<Double>) -> some View {
        TextField("", value: binding, format: .percent.precision(.fractionLength(1)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
    }

    /// An editable text field showing a pixel value derived from a fraction.
    private func pixelField(fraction: Binding<Double>, maxValue: Int,
                            minFraction: Double, maxFraction: Double) -> some View {
        let pixelBinding = Binding<Int>(
            get: {
                guard maxValue > 0 else { return 0 }
                let value = fraction.wrappedValue * Double(maxValue)
                guard !value.isNaN && !value.isInfinite else { return 0 }
                return Int(round(value))
            },
            set: { newPx in
                guard maxValue > 0 else { return }
                let f = Double(newPx) / Double(maxValue)
                guard !f.isNaN && !f.isInfinite else { return }
                fraction.wrappedValue = Swift.min(Swift.max(f, minFraction), maxFraction)
            }
        )
        return TextField("", value: pixelBinding, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .multilineTextAlignment(.trailing)
    }

    // MARK: - Badge

    /// Draws a dark translucent badge with the tablet nickname and model name
    /// centred inside `areaRect`, matching the display-pane caption style.
    private func tabletBadge(ctx: GraphicsContext, areaRect: CGRect) {
        let label = deviceLabel

        let line1Resolved = ctx.resolve(
            Text(label.primary).font(Font.appFont(.badgeTitle, scale: textScale)).bold().foregroundColor(.white))
        let line2Resolved = label.secondary.map {
            ctx.resolve(Text($0).font(Font.appFont(.badgeSubtitle, scale: textScale)).foregroundColor(.white))
        }

        let hPad: CGFloat = 6
        let vPad: CGFloat = 4
        let gap:  CGFloat = 4
        let maxTextW = areaRect.width - hPad * 2 - 4

        guard maxTextW > 16 else { return }

        let measureBound = CGSize(width: maxTextW, height: 40)
        let s1 = line1Resolved.measure(in: measureBound)
        let s2 = line2Resolved?.measure(in: measureBound) ?? .zero

        // Vanish if area is too narrow; avoids text wrapping/measurement changes
        guard areaRect.width >= 140 else { return }

        let maxTextWidth = max(s1.width, s2.width)
        let twoLines = line2Resolved != nil
        let textH    = twoLines ? s1.height + gap + s2.height : s1.height

        let badgeW   = min(maxTextWidth + hPad * 2, areaRect.width - 4)
        let badgeH   = textH + vPad * 2

        let badgeX   = areaRect.midX - badgeW / 2
        let badgeY   = areaRect.midY - badgeH / 2

        let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)
        let badgePath = Path(roundedRect: badgeRect, cornerRadius: 3, style: .continuous)
        let clipPath  = Path(areaRect.insetBy(dx: 2, dy: 2))

        ctx.drawLayer { layer in
            layer.clip(to: clipPath)
            layer.fill(badgePath, with: .color(.black.opacity(0.42)))

            if twoLines, let r2 = line2Resolved {
                let y1 = areaRect.midY - (gap / 2 + s1.height / 2)
                let y2 = areaRect.midY + (gap / 2 + s2.height / 2)
                layer.draw(line1Resolved, at: CGPoint(x: areaRect.midX, y: y1), anchor: .center)
                layer.draw(r2,            at: CGPoint(x: areaRect.midX, y: y2), anchor: .center)
            } else {
                layer.draw(line1Resolved, at: CGPoint(x: areaRect.midX, y: areaRect.midY),
                           anchor: .center)
            }
        }
    }

}
