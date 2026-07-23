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

    /// The physical unit this view is currently showing.
    let boundKey: DeviceInstanceKey?
    /// Model axis of the bound unit — spec/catalog lookups key on this.
    private var boundProductID: Int? { boundKey?.productID }

    @AppStorage(AppearancePrefs.storageKey) private var textSizeIndex: Int = AppearancePrefs.defaultIndex
    private var textScale: CGFloat { AppearancePrefs.scale(forIndex: textSizeIndex) }

    /// Width of the leading status-glyph column in the calibration section, so
    /// every row's label starts on the same edge whatever glyph precedes it.
    static let statusGutter: CGFloat = 20

    /// Cursor offset is a nudge on top of calibration, not a mapping control —
    /// ±20 pt is well past any real parallax and keeps the pad's arrow on-pad.
    static let parallaxLimit: Double = 20

    static func clampParallax(_ value: Double) -> Double {
        Swift.min(Swift.max(value, -parallaxLimit), parallaxLimit)
    }

    // MARK: - Digitizer dimensions

    /// Digitizer width for the currently-shown device, in hardware line-units.
    private var activeDeviceMaxX: Int {
        if let pid = boundProductID {
            if let s = tabletManager.context(forKey: boundKey)?.tabletDevice?.spec { return s.maxX }
            if let s = WacomDeviceRegistry.spec(for: pid) { return s.maxX }
        }
        return 44800
    }

    /// Digitizer height for the currently-shown device, in hardware line-units.
    private var activeDeviceMaxY: Int {
        if let pid = boundProductID {
            if let s = tabletManager.context(forKey: boundKey)?.tabletDevice?.spec { return s.maxY }
            if let s = WacomDeviceRegistry.spec(for: pid) { return s.maxY }
        }
        return 29600
    }

    /// True if the connected device is a pen display (Cintiq-class).
    private var activeDeviceIsPenDisplay: Bool {
        if let pid = boundProductID {
            if let s = tabletManager.context(forKey: boundKey)?.tabletDevice?.spec { return s.isPenDisplay }
            if let s = WacomDeviceRegistry.spec(for: pid) { return s.isPenDisplay }
        }
        return false
    }

    /// True if the bound device is currently physically connected.
    private var activeDeviceIsConnected: Bool {
        guard boundKey != nil else { return false }
        return tabletManager.context(forKey: boundKey)?.isConnected == true
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
            instanceKey: boundKey, overrideKeys: AppOverrideBar.areaKeys,
            onResetToDefaults: resetToDefaults
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

                        // Deliberately a checkbox, not a switch: Finder still
                        // uses checkboxes for inline options like this.
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
                        // Calibration status + actions. Both rows in this section
                        // share a fixed leading gutter so their labels start on one
                        // column regardless of which status glyph is showing.
                        HStack(spacing: 8) {
                            Group {
                                if !activeDeviceIsConnected {
                                    Image(systemName: "display.trianglebadge.exclamationmark")
                                        .foregroundStyle(.secondary)
                                } else if activeCalibration != nil {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                } else {
                                    // "scope" rather than a plain circle, which read as a
                                    // radio button or a stray letter O next to the label.
                                    Image(systemName: "scope")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .scaledFrame(width: Self.statusGutter)
                            .accessibilityHidden(true)

                            if !activeDeviceIsConnected {
                                Text("Display not connected")
                                    .foregroundStyle(.secondary)
                            } else if let cal = activeCalibration {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Calibrated")
                                        .appFont(.body)
                                    Text(cal.calibratedAt, format: .dateTime.month(.abbreviated).day().year())
                                        .appFont(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("Default Calibration")
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
                            }
                        }

                        // Cursor offset — the gap between where the pen touches and
                        // where the cursor lands. Shown as a pad rather than two
                        // number fields: the arrow's position *is* the offset, so
                        // the magnitude never needs spelling out.
                        HStack(spacing: 8) {
                            Image(systemName: "cursorarrow.square")
                                .foregroundStyle(.secondary)
                                .scaledFrame(width: Self.statusGutter)
                                .accessibilityHidden(true)
                            Text("Pointer Offset")
                            Spacer()
                            CursorOffsetPad(
                                offsetX: settings.parallaxOffsetX,
                                offsetY: settings.parallaxOffsetY,
                                limit: Self.parallaxLimit,
                                onCommit: { toX, toY in
                                    applyParallaxChange(
                                        toX: toX, toY: toY,
                                        undoX: settings.parallaxOffsetX,
                                        undoY: settings.parallaxOffsetY,
                                        name: "Parallax Offset")
                                },
                                onNudge: { dx, dy in
                                    let fromX = settings.parallaxOffsetX
                                    let fromY = settings.parallaxOffsetY
                                    applyParallaxChange(
                                        toX: Self.clampParallax(fromX + dx),
                                        toY: Self.clampParallax(fromY + dy),
                                        undoX: fromX, undoY: fromY, name: "Parallax Offset")
                                })
                            // Second spacer pulls the pad in off the trailing edge,
                            // toward the middle of the window.
                            Spacer()
                            Button("Reset Offset") {
                                applyParallaxChange(
                                    toX: 0, toY: 0,
                                    undoX: settings.parallaxOffsetX, undoY: settings.parallaxOffsetY,
                                    name: "Reset Offset")
                            }
                            .buttonStyle(.bordered)
                            .disabled(settings.parallaxOffsetX == 0 && settings.parallaxOffsetY == 0)
                        }
                        .help("Apply a small constant offset on top of calibration for sub-pixel fine-tuning.")
                    }
                }

                Section("Orientation") {
                    OrientationPickerView(settings: settings)
                }
        }
    }

    // MARK: - Reset to Defaults

    /// Restores every field `AppOverrideBar.areaKeys` tracks to its shipped
    /// default: full-surface active area, proportional mapping on, no
    /// parallax offset, landscape orientation, primary display, all displays
    /// toggle-eligible. Calibration and touch-area fields aren't in
    /// `areaKeys` and already have their own dedicated reset controls above.
    private typealias AreaState = (
        x: Double, y: Double, w: Double, h: Double, proportional: Bool,
        parallaxX: Double, parallaxY: Double, orientation: TabletOrientation,
        displayIndex: Int, toggleIDs: String
    )

    private func resetToDefaults() {
        let old: AreaState = (
            settings.activeAreaX, settings.activeAreaY,
            settings.activeAreaWidth, settings.activeAreaHeight,
            settings.proportionalMapping,
            settings.parallaxOffsetX, settings.parallaxOffsetY,
            settings.tabletOrientation,
            settings.targetDisplayIndex, settings.toggleDisplayIDs
        )
        let defaults: AreaState = (0, 0, 1, 1, true, 0, 0, .landscape, 0, "")
        applyAreaState(defaults, undoTo: old)
    }

    /// Self-recursive so "Reset to Defaults" also redoes: each invocation
    /// applies one state and registers the swap as the next undo (which,
    /// from the redo stack, replays as the next redo) — see
    /// `TabletSettings.recordAreaDrag` for the same pattern.
    private func applyAreaState(_ new: AreaState, undoTo old: AreaState) {
        settings.undoManager?.beginUndoGrouping()
        (settings.activeAreaX, settings.activeAreaY,
         settings.activeAreaWidth, settings.activeAreaHeight,
         settings.proportionalMapping,
         settings.parallaxOffsetX, settings.parallaxOffsetY,
         settings.tabletOrientation,
         settings.targetDisplayIndex, settings.toggleDisplayIDs) = new
        settings.record("Reset to Defaults") {
            self.applyAreaState(old, undoTo: new)
        }
        settings.undoManager?.endUndoGrouping()
    }

    /// Moves both offset axes as one undoable step. Self-recursive so the change
    /// also redoes. Both axes go together because a drag changes them together —
    /// recording them separately would take two undos to put back one gesture.
    private func applyParallaxChange(
        toX: Double, toY: Double, undoX: Double, undoY: Double, name: String
    ) {
        guard toX != undoX || toY != undoY else { return }
        settings.parallaxOffsetX = toX
        settings.parallaxOffsetY = toY
        settings.record(name) {
            self.applyParallaxChange(
                toX: undoX, toY: undoY, undoX: toX, undoY: toY, name: name)
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
        if let tablet = registry.knownTablets.first(where: { $0.productID == pid }),
           tablet.nickname != tablet.modelName {
            return DeviceLabel(primary: tablet.nickname, secondary: modelName)
        }
        return DeviceLabel(primary: modelName, secondary: nil)
    }

    // MARK: - Section heading

    private var sectionHeading: some View {
        PaneSectionHeader("Active Surface Area") {
            DeviceNameLabel(tabletManager: tabletManager, registry: registry, instanceKey: boundKey)
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
        let newJSON = settings.calibrationJSON
        settings.recordToggle("Reset Calibration", from: oldJSON, to: newJSON) {
            settings.calibrationJSON = $0
        }
        tabletManager.activeContext?.injector.invalidateCalibrationCache()
    }

    /// Binding that registers undo when proportional mapping is toggled.
    private var proportionalMappingBinding: Binding<Bool> {
        Binding(
            get: { settings.proportionalMapping },
            set: { newValue in
                let oldValue = settings.proportionalMapping
                settings.proportionalMapping = newValue
                settings.recordToggle("Proportional Mapping", from: oldValue, to: newValue) {
                    settings.proportionalMapping = $0
                }
            }
        )
    }

    // MARK: - Coordinate readout

    private var coordinateReadout: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Width").foregroundStyle(.secondary)
                    .scaledFrame(width: 60, alignment: .trailing)
                pixelField(fraction: $settings.activeAreaWidth,
                           maxValue: activeDeviceMaxX,
                           minFraction: Self.minFraction,
                           maxFraction: 1 - settings.activeAreaX)
                Text("Height").foregroundStyle(.secondary)
                    .scaledFrame(width: 60, alignment: .trailing)
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
            .scaledFrame(width: 80)
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
            .scaledFrame(width: 80)
            .multilineTextAlignment(.trailing)
    }

    // MARK: - Badge

    /// Draws a dark translucent badge with the tablet nickname and model name
    /// centered inside `areaRect`, matching the display-pane caption style.
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

// MARK: - Cursor offset pad

/// Square pad showing where the cursor lands relative to the pen tip.
///
/// The crosshair is the pen's contact point; the arrow is the cursor. Drag the
/// arrow away from the crosshair to offset one from the other.
///
/// `limit` maps onto the pad's usable half-extent, so the edge is always the
/// maximum offset. At the shipped ±20 pt limit that works out to exactly one
/// point of travel per point of offset, making the pad a literal 1:1 preview of
/// the screen gap; a different limit would still fill the pad, just not at 1:1.
/// No number is drawn — exact values stay reachable through the tooltip and the
/// accessibility value.
private struct CursorOffsetPad: View {
    let offsetX: Double
    let offsetY: Double
    let limit: Double
    /// Called once when a drag ends, with the final value. Matching the area
    /// editor above, the drag itself only moves local state — writing `settings`
    /// per frame would mean 60 Hz `persist(...)` calls and snapshot rebuilds, and
    /// there's nothing to preview live since the pen isn't in proximity while
    /// the mouse is dragging here.
    var onCommit: (Double, Double) -> Void
    /// Arrow-key nudge, in points. Records its own undo step per press.
    var onNudge: (Double, Double) -> Void

    private static let side: CGFloat = 60
    private static let crosshair: CGFloat = 18
    /// Half-extent the arrow may travel from center. Stated outright rather than
    /// derived from a glyph size: `cursorarrow` measures 12×17 here, so the worst
    /// case is vertical at 20 + 17/2 = 28.5 against the 30 pt half-width.
    ///
    /// The glyph is centered on the offset point rather than hung from its tip —
    /// an arrow's ink sits down-right of its tip, so tip-anchoring made the reach
    /// look twice as far right/down as left/up even though the values matched.
    private static let travel: CGFloat = 20

    /// In-flight drag position. Non-nil only between gesture start and end; the
    /// committed `offsetX`/`offsetY` drive the arrow the rest of the time.
    @State private var dragging: (x: Double, y: Double)?
    @FocusState private var focused: Bool

    private var shownX: Double { dragging?.x ?? offsetX }
    private var shownY: Double { dragging?.y ?? offsetY }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    focused ? Color.accentColor.opacity(0.55)
                            : Color.secondary.opacity(0.35),
                    lineWidth: focused ? 1.5 : 1
                )

            CrosshairShape()
                .stroke(Color.secondary.opacity(0.50), lineWidth: 1)
                .frame(width: Self.crosshair, height: Self.crosshair)

            ZStack {
                Image(systemName: "cursorarrow")
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Color.white.opacity(0.95))
                    .offset(x: padPosition(shownX), y: padPosition(shownY))

                Image(systemName: "cursorarrow")
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .offset(x: padPosition(shownX), y: padPosition(shownY))
            }
        }

        .frame(width: Self.side, height: Self.side)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragging = (offsetValue(from: value.location.x),
                                offsetValue(from: value.location.y))
                }
                .onEnded { _ in
                    if let final = dragging { onCommit(final.x, final.y) }
                    dragging = nil
                }
        )
        .focusable()
        .focused($focused)
        .modifier(SuppressSystemFocusRing())
        .onMoveCommand { direction in
            switch direction {
            case .left:  onNudge(-1, 0)
            case .right: onNudge(1, 0)
            case .up:    onNudge(0, -1)
            case .down:  onNudge(0, 1)
            @unknown default: break
            }
        }
        .help(Text("Drag the arrow to set where the cursor appears relative to the pen tip.")
            + Text(verbatim: " ") + Text(readout))
        .accessibilityElement()
        .accessibilityLabel(Text("Pointer Offset"))
        .accessibilityValue(Text(readout))
    }

    /// Offset value → the arrow tip's position within the pad, in points from center.
    private func padPosition(_ value: Double) -> CGFloat {
        CGFloat(value / limit) * Self.travel
    }

    /// A point in pad coordinates → the offset value it represents.
    private func offsetValue(from coordinate: CGFloat) -> Double {
        let fromCenter = coordinate - Self.side / 2
        return clamp(Double(fromCenter / Self.travel) * limit)
    }

    private func clamp(_ value: Double) -> Double {
        Swift.min(Swift.max(value, -limit), limit)
    }

    /// Exact values for the tooltip and VoiceOver — the pad itself stays wordless.
    private var readout: LocalizedStringKey {
        "Horizontal \(formatted(offsetX)), vertical \(formatted(offsetY))"
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.1f pt", value)
    }
}

/// Drops the system focus ring, which draws a heavy full-strength outline around
/// the whole control and reads as an error state at rest. The pad tints its own
/// border instead. Same trade the crop editor makes in `KeyboardNudgeModifier`;
/// `.focusEffectDisabled()` is macOS 14+, so on 13 the system ring still shows.
private struct SuppressSystemFocusRing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}
