// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Stylus feel settings: pressure curve, stabilization, click behavior, and rotation.
struct PenFeelView: View {
    @ObservedObject var settings: TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    let instanceKey: DeviceInstanceKey?
    /// Model axis of the bound unit — spec/catalog lookups key on this.
    private var productID: Int? { instanceKey?.productID }

    private var tool: ToolSettings { settings.activeTool }

    // MARK: - Body

    var body: some View {
        SettingsPane(
            settings: settings, tabletManager: tabletManager, registry: registry,
            instanceKey: instanceKey, overrideKeys: AppOverrideBar.pressureKeys,
            onResetToDefaults: resetToDefaults
        ) {
            pressureCurveSection

            Section("Pressure Smoothing") {
                SettingSliderRow(
                    "Strength",
                    value: pressureSmoothingBinding,
                    in: 0...1,
                    valueText: pressureSmoothingLabel,
                    caption: "Reduces line-width variation from sensor noise at light pressure."
                )
                .help(
                    "Damps pressure noise near the low end of the sensor's range — most noticeable as uneven line width on slow, light strokes. Firm pressure is left alone.")
            }

            Section("Stabilization") {
                SettingSliderRow(
                    "Strength",
                    value: smoothingBinding,
                    in: 0...1,
                    valueText: smoothingLabel,
                    caption: "Reduces cursor jitter. Higher values add lag."
                )
                .help(
                    "Reduces cursor wobble from hand tremor. Higher values smooth more aggressively but add input lag.")
            }

            Section("Double-Click Distance") {
                SettingSliderRow(
                    "Distance",
                    value: doubleClickBinding,
                    in: 0...20,
                    valueText: doubleClickLabel,
                    caption:
                        "Radius for reliable double-clicks."
                )
                .help(
                    "How close a second tap must land to the first to count as a double-click. Drag to Off to disable position snapping.")
            }

            Section("Movement") {
                DescribedToggle("Invert Rotation Direction", isOn: invertRotationBinding) {
                    Text("Current: ")
                        + Text(
                            Image(
                                systemName: settings.invertRotation
                                    ? "arrow.counterclockwise"
                                    : "arrow.clockwise"))
                        + Text(
                            settings.invertRotation
                                ? " Counter-clockwise."
                                : " Clockwise.")
                }
                .help(
                    "Reverses the pen's twist direction. Enable per-app for apps that interpret rotation backwards (e.g. Krita).")

                DescribedToggle(
                    "Art Pen: Swap Tilt with Rotation",
                    isOn: rotationAsTiltBinding,
                    description:
                        "Disables tilt so supported apps can detect barrel rotation."
                )
                .help(
                    "Feeds barrel rotation into Photoshop's Pen Tilt control by sending fake tilt data. Real tilt is suppressed while this is on. Use in Brush Dynamics → Shape Dynamics → Angle → Pen Tilt."
                )

                if tool.useRotationAsTilt {
                    SettingSliderRow(
                        "Tilt Offset",
                        value: settings.recordingBinding(
                            String(localized: "Tilt Offset"), toolOwned: true,
                            get: { tool.rotationTiltOffsetDegrees },
                            set: { tool.rotationTiltOffsetDegrees = $0 }),
                        in: -180...180,
                        valueText: "\(Int(tool.rotationTiltOffsetDegrees))°")

                    SettingSliderRow(
                        "Tilt Magnitude",
                        value: settings.recordingBinding(
                            String(localized: "Tilt Magnitude"), toolOwned: true,
                            get: { tool.rotationTiltMagnitude },
                            set: { tool.rotationTiltMagnitude = $0 }),
                        in: 0.1...1.0,
                        valueText: String(format: "%.0f%%", tool.rotationTiltMagnitude * 100))
                }

                DescribedToggle("Relative Cursor Movement", isOn: relativeCursorMovementBinding) {
                    Text("Current: ")
                        + Text(
                            Image(
                                systemName: settings.relativeCursorMovement
                                    ? "cursorarrow.motionlines"
                                    : "pencil.tip"))
                        + Text(
                            settings.relativeCursorMovement
                                ? " Relative, like a mouse."
                                : " Absolute, like a stylus.")
                }
                .help(
                    "In absolute mode, each point on the tablet maps to a fixed point on screen. In relative mode, the cursor moves by the distance you move the pen, like a mouse.")
            }

            Section("Pan View") {
                SettingSliderRow(
                    "Speed",
                    value: panScrollSpeedBinding,
                    in: 0.25...3.0,
                    step: 0.25,
                    valueText: String(format: "%.2f×", tool.panScrollSpeed),
                    caption:
                        "How fast content pans while pressing a Pan View button."
                )
                .help(
                    "Multiplier applied to pen motion while Pan View is held. 1× pans one screen point per point of pen travel; higher values pan further. Assign the Pan View action to any pen barrel, express key, or puck button in Button Mapping.")

                DescribedToggle(
                    "Momentum Scrolling",
                    isOn: panScrollMomentumBinding,
                    description: "Inertia scrolling. Compatibility varies by app."
                )
                .help(
                    "On (default): Pan View emits a phased trackpad-style stream with a momentum tail, so scroll-view apps coast after you release. Off: a simpler stream that pans in far more apps, but without inertia. Set per-app using the override bar above if some apps need it off.")
            }

            Section("Click Behavior") {
                SettingSliderRow(
                    "Tip-up Assist",
                    value: tipUpAssistBinding,
                    in: 0...200,
                    step: 10,
                    valueText: settings.tipUpAssistDelay < 1
                        ? String(
                            localized: "Off",
                            comment: "Feature disabled — tip-up assist slider at minimum value"
                        )
                        : String(
                            localized: "\(Int(settings.tipUpAssistDelay)) ms",
                            comment: "Delay in milliseconds, e.g. '80 ms'"),
                    caption:
                        "Prevents accidental stroke movement when lifting pen."
                )
                .help(
                    "Holds the pen click open for this long after the tip lifts, if you're still moving quickly. This helps prevent unintended stroke breaks during fast drawing. Drag to Off to disable.")

                SettingSliderRow(
                    "Drag Threshold",
                    value: dragThresholdBinding,
                    in: 0...15,
                    step: 1,
                    valueText: settings.dragThreshold < 1
                        ? String(
                            localized: "Off",
                            comment: "Feature disabled — drag threshold slider at minimum value"
                        )
                        : String(
                            localized: "\(Int(settings.dragThreshold)) pt",
                            comment: "Distance in points, e.g. '3 pt'"),
                    caption:
                        "Requires the pen to move this far before a tap becomes a drag."
                )
                .help(
                    "Prevents a light tap from turning into an accidental drag due to hand tremor or pressure jitter right when the tip touches down. Drag to Off to disable.")
            }
        }
    }

    // MARK: - Pressure curve section (with extracted canvas)

    @ViewBuilder
    private var pressureCurveSection: some View {
        Section {
            PressureCurveCanvas(tool: tool)
                .frame(height: 180)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))

            HStack(spacing: 4) {
                Button("Linear") {
                    let old = tool.pressureCurve
                    tool.pressureCurve = .linear
                    tool.recordToggle(String(localized: "Linear Curve", comment: "Undo action name: pressure curve preset in the Pen Feel pane"), from: old, to: .linear) { tool.pressureCurve = $0 }
                }
                .help(
                    "Linear response — equal pen force produces equal pressure output. Best for general use.")
                Button("Soft") {
                    let old = tool.pressureCurve
                    tool.pressureCurve = .soft
                    tool.recordToggle(String(localized: "Soft Curve", comment: "Undo action name: pressure curve preset in the Pen Feel pane"), from: old, to: .soft) { tool.pressureCurve = $0 }
                }
                .help(
                    "Soft response — light pressure reaches full output quickly. Good for loose, expressive work.")
                Button("Firm") {
                    let old = tool.pressureCurve
                    tool.pressureCurve = .firm
                    tool.recordToggle(String(localized: "Firm Curve", comment: "Undo action name: pressure curve preset in the Pen Feel pane"), from: old, to: .firm) { tool.pressureCurve = $0 }
                }
                .help(
                    "Firm response — requires more force to reach full output. Good for precise detail work.")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 8))

            SettingSliderRow(
                "Click Threshold",
                value: pressureThresholdBinding,
                in: 0...0.5,
                valueText: pressureThresholdLabel,
                caption: "Minimum force required before the tip registers pressure or a click."
            )
            .help(
                "Sets how much pressure the tip needs before it counts as contact — the same idea as sensitivity, but for the on/off point rather than the response curve. Raise it for a firmer, more deliberate click feel; lower it for the lightest possible touch. Off (default) starts registering at the sensor's own floor.")
        } header: {
            PaneSectionHeader("Pressure Curve") {
                ToolNameLabel(tabletManager: tabletManager, registry: registry, instanceKey: instanceKey)
            }
        }
    }

    // MARK: - Reset to Defaults

    /// Restores every field this pane owns (`AppOverrideBar.pressureKeys`) to
    /// its shipped default. Two `record` calls — one tool-owned, one
    /// device-owned — share `settings.undoManager`, so grouping them makes a
    /// single Cmd-Z undo the whole reset instead of two.
    private typealias ToolResetState = (
        curve: BezierCurve, smoothing: Double, pressureSmoothing: Double, pressureThreshold: Double,
        rotationAsTilt: Bool, tiltOffset: Double, tiltMagnitude: Double, panSpeed: Double,
        panMomentum: Bool
    )
    private typealias SettingsResetState = (
        doubleClick: Double, invertRotation: Bool, relativeCursor: Bool,
        tipUpAssist: Double, dragThreshold: Double
    )

    private func resetToDefaults() {
        let toolOld: ToolResetState = (
            tool.pressureCurve, tool.smoothingStrength, tool.pressureSmoothingStrength, tool.pressureThreshold,
            tool.useRotationAsTilt, tool.rotationTiltOffsetDegrees, tool.rotationTiltMagnitude,
            tool.panScrollSpeed, tool.panScrollMomentum
        )
        let settingsOld: SettingsResetState = (
            settings.doubleClickDistance, settings.invertRotation, settings.relativeCursorMovement,
            settings.tipUpAssistDelay, settings.dragThreshold
        )
        let toolDefaults: ToolResetState = (.linear, 0, 0, 0, false, 0, 0.8, 1.0, true)
        let settingsDefaults: SettingsResetState = (10.0, false, false, 0.0, 0.0)

        settings.undoManager?.beginUndoGrouping()
        applyToolReset(toolDefaults, undoTo: toolOld)
        applySettingsReset(settingsDefaults, undoTo: settingsOld)
        settings.undoManager?.endUndoGrouping()
    }

    /// Self-recursive so "Reset to Defaults" also redoes the tool-owned half.
    private func applyToolReset(_ new: ToolResetState, undoTo old: ToolResetState) {
        (tool.pressureCurve, tool.smoothingStrength, tool.pressureSmoothingStrength, tool.pressureThreshold,
         tool.useRotationAsTilt, tool.rotationTiltOffsetDegrees, tool.rotationTiltMagnitude,
         tool.panScrollSpeed, tool.panScrollMomentum) = new
        tool.record(String(localized: "Reset to Defaults", comment: "Undo action name: restoring a pane's controls to their defaults")) {
            self.applyToolReset(old, undoTo: new)
        }
    }

    /// Self-recursive so "Reset to Defaults" also redoes the settings-owned half.
    private func applySettingsReset(_ new: SettingsResetState, undoTo old: SettingsResetState) {
        (settings.doubleClickDistance, settings.invertRotation, settings.relativeCursorMovement,
         settings.tipUpAssistDelay, settings.dragThreshold) = new
        settings.record(String(localized: "Reset to Defaults", comment: "Undo action name: restoring a pane's controls to their defaults")) {
            self.applySettingsReset(old, undoTo: new)
        }
    }

    // MARK: - Bindings with undo support

    private var smoothingBinding: Binding<Double> {
        settings.recordingBinding(
            String(localized: "Stabilization"), toolOwned: true,
            get: { tool.smoothingStrength },
            set: { tool.smoothingStrength = $0 })
    }

    private var pressureSmoothingBinding: Binding<Double> {
        settings.recordingBinding(
            String(localized: "Pressure Smoothing"), toolOwned: true,
            get: { tool.pressureSmoothingStrength },
            set: { tool.pressureSmoothingStrength = $0 })
    }

    private var pressureThresholdBinding: Binding<Double> {
        settings.recordingBinding(
            String(localized: "Click Threshold", comment: "Undo action name: minimum pressure before tip contact registers, in the Pen Feel pane"), toolOwned: true,
            get: { tool.pressureThreshold },
            set: { tool.pressureThreshold = $0 })
    }

    private var panScrollSpeedBinding: Binding<Double> {
        settings.recordingBinding(
            String(localized: "Pan View Speed", comment: "Undo action name: Pan View pan speed multiplier in the Pen Feel pane"), toolOwned: true,
            get: { tool.panScrollSpeed },
            set: { tool.panScrollSpeed = $0 })
    }

    private var panScrollMomentumBinding: Binding<Bool> {
        settings.recordingBinding(
            String(localized: "Pan View Momentum", comment: "Undo action name: Pan View trackpad-style momentum toggle in the Pen Feel pane"), toolOwned: true,
            get: { tool.panScrollMomentum },
            set: { tool.panScrollMomentum = $0 })
    }

    private var doubleClickBinding: Binding<Double> {
        settings.recordingBinding(
            String(localized: "Double-Click Distance"),
            get: { settings.doubleClickDistance },
            set: { settings.doubleClickDistance = $0 })
    }

    private var invertRotationBinding: Binding<Bool> {
        settings.recordingBinding(
            String(localized: "Invert Rotation", comment: "Undo action name: pen barrel-rotation direction in the Pen Feel pane"),
            get: { settings.invertRotation },
            set: { settings.invertRotation = $0 })
    }

    private var rotationAsTiltBinding: Binding<Bool> {
        settings.recordingBinding(
            String(localized: "Rotation as Tilt", comment: "Undo action name: mapping barrel rotation to fake tilt in the Pen Feel pane"), toolOwned: true,
            get: { tool.useRotationAsTilt },
            set: { tool.useRotationAsTilt = $0 })
    }

    private var relativeCursorMovementBinding: Binding<Bool> {
        settings.recordingBinding(
            String(localized: "Relative Cursor Movement"),
            get: { settings.relativeCursorMovement },
            set: { settings.relativeCursorMovement = $0 })
    }

    private var tipUpAssistBinding: Binding<Double> {
        settings.recordingBinding(
            String(localized: "Tip-up Assist"),
            get: { settings.tipUpAssistDelay },
            set: { settings.tipUpAssistDelay = $0 })
    }

    private var dragThresholdBinding: Binding<Double> {
        settings.recordingBinding(
            String(localized: "Drag Threshold"),
            get: { settings.dragThreshold },
            set: { settings.dragThreshold = $0 })
    }

    // MARK: - Smoothing label

    private var smoothingLabel: String {
        switch tool.smoothingStrength {
        case 0..<0.15: return String(localized: "Off", comment: "Stabilization strength — disabled")
        case 0.15..<0.4: return String(localized: "Low", comment: "Stabilization strength label")
        case 0.4..<0.65: return String(localized: "Medium", comment: "Stabilization strength label")
        case 0.65..<0.85: return String(localized: "High", comment: "Stabilization strength label")
        default:
            return String(localized: "Max", comment: "Stabilization strength label — maximum value")
        }
    }

    private var doubleClickLabel: String {
        switch settings.doubleClickDistance {
        case 0..<3: return String(localized: "Off", comment: "Double-click distance — disabled")
        case 3..<8: return String(localized: "Low", comment: "Double-click distance label")
        case 8..<13: return String(localized: "Medium", comment: "Double-click distance label")
        case 13..<17: return String(localized: "High", comment: "Double-click distance label")
        default:
            return String(
                localized: "Max", comment: "Double-click distance label — maximum value")
        }
    }

    private var pressureSmoothingLabel: String {
        switch tool.pressureSmoothingStrength {
        case 0..<0.15:
            return String(localized: "Off", comment: "Pressure smoothing strength — disabled")
        case 0.15..<0.4: return String(localized: "Low", comment: "Pressure smoothing strength label")
        case 0.4..<0.65:
            return String(localized: "Medium", comment: "Pressure smoothing strength label")
        case 0.65..<0.85:
            return String(localized: "High", comment: "Pressure smoothing strength label")
        default:
            return String(
                localized: "Max", comment: "Pressure smoothing strength label — maximum value")
        }
    }

    private var pressureThresholdLabel: String {
        // Anything that rounds to 0% reads as "Off" — the dead zone is then
        // narrower than InputInjector.tipPressureThreshold anyway, so it has
        // no effect the user could observe.
        tool.pressureThreshold < 0.005
            ? String(localized: "Off", comment: "Click threshold — disabled, previous behavior")
            : String(format: "%.0f%%", tool.pressureThreshold * 100)
    }
}

// MARK: - Pressure Curve Canvas (extracted for clarity)

private enum PressureCurvePoint { case p1, p2 }

private struct PressureCurveCanvas: View {
    @ObservedObject var tool: ToolSettings

    @State private var draggingP1 = false
    @State private var draggingP2 = false
    @State private var pressureCurveSnapshot: BezierCurve = .linear
    @FocusState private var isFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, _ in
                drawGrid(ctx: ctx, size: size)
                drawThreshold(ctx: ctx, size: size)
                drawCurve(ctx: ctx, size: size)
                drawHandles(ctx: ctx, size: size)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !draggingP1 && !draggingP2 {
                            // First drag event on a handle — capture snapshot for undo
                            pressureCurveSnapshot = tool.pressureCurve
                        }
                        handle(drag: v, size: size)
                    }
                    .onEnded { _ in
                        // Register one undo entry for the entire drag
                        if draggingP1 || draggingP2 {
                            tool.recordToggle(String(localized: "Pressure Curve"), from: self.pressureCurveSnapshot, to: tool.pressureCurve) {
                                tool.pressureCurve = $0
                            }
                        }
                        draggingP1 = false
                        draggingP2 = false
                    }
            )
            .accessibilityRepresentation { accessibilityControls }
            .modifier(PressureCurveKeyboardModifier(
                isFocused: $isFocused,
                onNudge: { dx, dy, target in nudgeControlPoint(dx: dx, dy: dy, target: target) }))
        }
    }

    // MARK: - Accessibility (VoiceOver)

    /// Parallel control tree exposed to VoiceOver via
    /// `.accessibilityRepresentation`. The visual Canvas remains the
    /// authoritative surface for sighted-mouse users.
    private var accessibilityControls: some View {
        VStack {
            Slider(value: bindingFor(.p1, axis: .x), in: 0...1) {
                Text(String(
                    localized: "Pressure curve point 1 input",
                    comment: "Accessibility label: VoiceOver slider for the X coordinate of the first Bézier control point"))
            }
            Slider(value: bindingFor(.p1, axis: .y), in: 0...1) {
                Text(String(
                    localized: "Pressure curve point 1 output",
                    comment: "Accessibility label: VoiceOver slider for the Y coordinate of the first Bézier control point"))
            }
            Slider(value: bindingFor(.p2, axis: .x), in: 0...1) {
                Text(String(
                    localized: "Pressure curve point 2 input",
                    comment: "Accessibility label: VoiceOver slider for the X coordinate of the second Bézier control point"))
            }
            Slider(value: bindingFor(.p2, axis: .y), in: 0...1) {
                Text(String(
                    localized: "Pressure curve point 2 output",
                    comment: "Accessibility label: VoiceOver slider for the Y coordinate of the second Bézier control point"))
            }
        }
    }

    private enum Axis { case x, y }

    private func bindingFor(_ point: PressureCurvePoint, axis: Axis) -> Binding<Double> {
        Binding(
            get: {
                let p = (point == .p1) ? tool.pressureCurve.p1 : tool.pressureCurve.p2
                return axis == .x ? p.x : p.y
            },
            set: { newValue in
                let clamped = Swift.min(Swift.max(newValue, 0), 1)
                let snapshot = tool.pressureCurve
                var curve = tool.pressureCurve
                if point == .p1 {
                    curve.p1 = CGPoint(
                        x: axis == .x ? clamped : curve.p1.x,
                        y: axis == .y ? clamped : curve.p1.y)
                } else {
                    curve.p2 = CGPoint(
                        x: axis == .x ? clamped : curve.p2.x,
                        y: axis == .y ? clamped : curve.p2.y)
                }
                guard curve.p1 != tool.pressureCurve.p1 || curve.p2 != tool.pressureCurve.p2 else { return }
                tool.pressureCurve = curve
                tool.recordToggle(String(localized: "Pressure Curve"), from: snapshot, to: curve) { tool.pressureCurve = $0 }
            }
        )
    }

    // MARK: - Keyboard nudging (macOS 14+)

    private func nudgeControlPoint(dx: Double, dy: Double, target: PressureCurvePoint) {
        let clamp01: (Double) -> Double = { Swift.min(Swift.max($0, 0), 1) }
        let snapshot = tool.pressureCurve
        var curve = tool.pressureCurve
        if target == .p1 {
            curve.p1 = CGPoint(x: clamp01(curve.p1.x + dx), y: clamp01(curve.p1.y + dy))
        } else {
            curve.p2 = CGPoint(x: clamp01(curve.p2.x + dx), y: clamp01(curve.p2.y + dy))
        }
        guard curve.p1 != tool.pressureCurve.p1 || curve.p2 != tool.pressureCurve.p2 else { return }
        tool.pressureCurve = curve
        tool.recordToggle(String(localized: "Pressure Curve"), from: snapshot, to: curve) { tool.pressureCurve = $0 }
    }

    // MARK: - Drawing helpers

    private func drawGrid(ctx: GraphicsContext, size: CGSize) {
        var path = Path()
        for i in 1..<4 {
            let x = size.width * Double(i) / 4
            let y = size.height * Double(i) / 4
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(path, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
    }

    /// Normalized input below which no contact registers — read back from the
    /// LUT rather than from `tool.pressureThreshold` directly, so it accounts
    /// for both halves of the dead zone: the user's threshold, and the fact
    /// that a soft curve keeps output under `tipPressureThreshold` for a while
    /// after the threshold is crossed. Using the raw setting here would draw
    /// the marker short of where contact actually begins.
    private var effectiveOnset: Double {
        let lut = tool.pressureLUT
        var lastSilent = -1
        for (i, v) in lut.enumerated() where v <= InputInjector.tipPressureThreshold {
            lastSilent = i
        }
        guard lastSilent >= 0 else { return 0 }
        return Swift.min(Double(lastSilent) / 255.0, 1)
    }

    /// Shades the dead zone — the same idea as Wacom's "click threshold"
    /// triangle marker on its pressure curve UI.
    private func drawThreshold(ctx: GraphicsContext, size: CGSize) {
        guard tool.pressureThreshold > 0 else { return }
        let x = effectiveOnset * size.width
        let rect = CGRect(x: 0, y: 0, width: x, height: size.height)
        ctx.fill(Path(rect), with: .color(.secondary.opacity(0.12)))
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(line, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    private func drawCurve(ctx: GraphicsContext, size: CGSize) {
        var path = Path()
        let curve = tool.pressureCurve
        // Mirrors ToolSettings.buildLUT: flat at zero through the dead zone,
        // then the curve over the rescaled remainder. Drawing the bare Bézier
        // from the origin would show the tip responding inside a region where
        // the LUT actually outputs nothing.
        let t = Swift.min(Swift.max(tool.pressureThreshold, 0), 0.95)
        path.move(to: toCanvas(x: 0, y: 0, size: size))
        if t > 0 { path.addLine(to: toCanvas(x: t, y: 0, size: size)) }
        // 32-segment polyline approximation of the bezier.
        for i in 1...32 {
            let s = Double(i) / 32.0
            path.addLine(to: toCanvas(x: t + s * (1 - t), y: curve.evaluate(s), size: size))
        }
        ctx.stroke(
            path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func drawHandles(ctx: GraphicsContext, size: CGSize) {
        let curve = tool.pressureCurve
        let p0 = toCanvas(x: 0, y: 0, size: size)
        let p1 = toCanvas(x: curve.p1.x, y: curve.p1.y, size: size)
        let p2 = toCanvas(x: curve.p2.x, y: curve.p2.y, size: size)
        let p3 = toCanvas(x: 1, y: 1, size: size)

        // Guide lines from anchors to control points
        var guides = Path()
        guides.move(to: p0)
        guides.addLine(to: p1)
        guides.move(to: p3)
        guides.addLine(to: p2)
        ctx.stroke(guides, with: .color(.secondary.opacity(0.4)), lineWidth: 1)

        // Control point handles
        for pt in [p1, p2] {
            let r: CGFloat = 6
            let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(.white))
            ctx.stroke(Path(ellipseIn: rect), with: .color(.accentColor), lineWidth: 1.5)
        }
    }

    // MARK: - Drag handling

    private func handle(drag: DragGesture.Value, size: CGSize) {
        let pt = fromCanvas(drag.location, size: size)

        let p1Canvas = toCanvas(
            x: tool.pressureCurve.p1.x,
            y: tool.pressureCurve.p1.y, size: size)
        let p2Canvas = toCanvas(
            x: tool.pressureCurve.p2.x,
            y: tool.pressureCurve.p2.y, size: size)

        let hitRadius: Double = 16
        if !draggingP1 && !draggingP2 {
            let d1 = dist(drag.location, p1Canvas)
            let d2 = dist(drag.location, p2Canvas)
            if d1 < hitRadius && d1 <= d2 {
                draggingP1 = true
            } else if d2 < hitRadius {
                draggingP2 = true
            }
        }

        let clamp01: (Double) -> Double = { Swift.min(Swift.max($0, 0), 1) }
        if draggingP1 {
            tool.pressureCurve.p1 = CGPoint(x: clamp01(pt.x), y: clamp01(pt.y))
        } else if draggingP2 {
            tool.pressureCurve.p2 = CGPoint(x: clamp01(pt.x), y: clamp01(pt.y))
        }
    }

    // MARK: - Coordinate utilities

    /// Map curve space [0,1]² → canvas pixels. Y axis is flipped (0 = bottom).
    private func toCanvas(x: Double, y: Double, size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: (1 - y) * size.height)
    }

    private func fromCanvas(_ pt: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: Swift.min(Swift.max(pt.x / size.width, 0), 1),
            y: Swift.min(Swift.max(1 - pt.y / size.height, 0), 1))
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> Double {
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
    }
}

// MARK: - Keyboard nudge modifier (pressure curve)
//
//   ←/→/↑/↓          nudge control point 1 by 1%   (Y flipped: ↑ = +y)
//   Shift + arrow    nudge control point 1 by 10%
//   Option + arrow   nudge control point 2 by 1%
//   Shift + Option   nudge control point 2 by 10%
//
// Tab is deliberately *not* repurposed for cycling between control points —
// stealing Tab inside a focusable element would break standard focus
// traversal. Option-modifier targeting keeps Tab free for its normal role.
//
// `.onKeyPress` requires macOS 14+; on macOS 13 the canvas remains mouse-
// only, but VoiceOver still has the slider representation.
private struct PressureCurveKeyboardModifier: ViewModifier {
    @FocusState.Binding var isFocused: Bool
    let onNudge: (Double, Double, PressureCurvePoint) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .focusable()
                .focused($isFocused)
                // Suppress the default focus ring; on a Canvas it draws a
                // thick rectangle that competes with the curve and handles.
                // The control-point handles already convey focus by being
                // the interactive surface.
                .focusEffectDisabled()
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow],
                            phases: .down) { press in
                    let step: Double = press.modifiers.contains(.shift) ? 0.10 : 0.01
                    let target: PressureCurvePoint =
                        press.modifiers.contains(.option) ? .p2 : .p1
                    switch press.key {
                    case .leftArrow:  onNudge(-step, 0, target)
                    case .rightArrow: onNudge( step, 0, target)
                    case .upArrow:    onNudge(0,  step, target)  // curve y increases upward
                    case .downArrow:  onNudge(0, -step, target)
                    default: return .ignored
                    }
                    return .handled
                }
        } else {
            content
        }
    }
}
