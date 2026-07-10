// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Stylus feel settings: pressure curve, stabilization, click behavior, and rotation.
struct PenFeelView: View {
    @ObservedObject var settings: TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    var productID: Int?

    private var tool: ToolSettings { settings.activeTool }

    // MARK: - Body

    var body: some View {
        SettingsPane(
            settings: settings, tabletManager: tabletManager, registry: registry,
            productID: productID, overrideKeys: AppOverrideBar.pressureKeys
        ) {
            pressureCurveSection

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
                    in: 0...30,
                    step: 1,
                    valueText: settings.doubleClickDistance < 1
                        ? String(
                            localized: "Off",
                            comment:
                                "Feature disabled — double-click distance slider at minimum value"
                        )
                        : String(
                            localized: "\(Int(settings.doubleClickDistance)) pt",
                            comment: "Distance in points, e.g. '10 pt'"),
                    caption:
                        "Snaps a second tap to the first click position within this radius, making double-clicks reliable."
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
                                ? " Counter-clockwise"
                                : " Clockwise")
                }
                .help(
                    "Reverses the pen's twist direction. Enable per-app for apps that interpret rotation backwards (e.g. Krita).")

                DescribedToggle(
                    "Art Pen: Swap Tilt with Rotation",
                    isOn: rotationAsTiltBinding,
                    description:
                        "Sacrifices an Art Pen's tilt behavior, allowing apps like Adobe Photoshop to detect barrel rotation."
                )
                .help(
                    "Feeds barrel rotation into Photoshop's Pen Tilt control by sending fake tilt data. Real tilt is suppressed while this is on. Use in Brush Dynamics → Shape Dynamics → Angle → Pen Tilt."
                )

                if tool.useRotationAsTilt {
                    SettingSliderRow(
                        "Tilt Offset",
                        value: settings.recordingBinding(
                            "Tilt Offset", toolOwned: true,
                            get: { tool.rotationTiltOffsetDegrees },
                            set: { tool.rotationTiltOffsetDegrees = $0 }),
                        in: -180...180,
                        valueText: "\(Int(tool.rotationTiltOffsetDegrees))°")

                    SettingSliderRow(
                        "Tilt Magnitude",
                        value: settings.recordingBinding(
                            "Tilt Magnitude", toolOwned: true,
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
                                ? " Relative, like a mouse"
                                : " Absolute, like a stylus")
                }
                .help(
                    "In absolute mode, each point on the tablet maps to a fixed point on screen. In relative mode, the cursor moves by the distance you move the pen, like a mouse.")
            }

            Section("Click Behavior") {
                DescribedToggle(
                    "Tip-up Assist",
                    isOn: tipUpAssistBinding,
                    description:
                        "Delays the stroke release briefly when the pen is lifted mid-motion, preventing accidental short strokes."
                )
                .help(
                    "When enabled, the pen click is held open for ~80 ms after the tip lifts if you are moving quickly. This helps prevent unintended stroke breaks during fast drawing.")
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
                    tool.record("Linear Curve") { tool.pressureCurve = old }
                }
                .help(
                    "Linear response — equal pen force produces equal pressure output. Best for general use.")
                Button("Soft") {
                    let old = tool.pressureCurve
                    tool.pressureCurve = .soft
                    tool.record("Soft Curve") { tool.pressureCurve = old }
                }
                .help(
                    "Soft response — light pressure reaches full output quickly. Good for loose, expressive work.")
                Button("Firm") {
                    let old = tool.pressureCurve
                    tool.pressureCurve = .firm
                    tool.record("Firm Curve") { tool.pressureCurve = old }
                }
                .help(
                    "Firm response — requires more force to reach full output. Good for precise detail work.")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 8))
        } header: {
            PaneSectionHeader("Pressure Curve") {
                ToolNameLabel(tabletManager: tabletManager, registry: registry, productID: productID)
            }
        }
    }

    // MARK: - Bindings with undo support

    private var smoothingBinding: Binding<Double> {
        settings.recordingBinding(
            "Stabilization", toolOwned: true,
            get: { tool.smoothingStrength },
            set: { tool.smoothingStrength = $0 })
    }

    private var doubleClickBinding: Binding<Double> {
        settings.recordingBinding(
            "Double-Click Distance",
            get: { settings.doubleClickDistance },
            set: { settings.doubleClickDistance = $0 })
    }

    private var invertRotationBinding: Binding<Bool> {
        settings.recordingBinding(
            "Invert Rotation",
            get: { settings.invertRotation },
            set: { settings.invertRotation = $0 })
    }

    private var rotationAsTiltBinding: Binding<Bool> {
        settings.recordingBinding(
            "Rotation as Tilt", toolOwned: true,
            get: { tool.useRotationAsTilt },
            set: { tool.useRotationAsTilt = $0 })
    }

    private var relativeCursorMovementBinding: Binding<Bool> {
        settings.recordingBinding(
            "Relative Cursor Movement",
            get: { settings.relativeCursorMovement },
            set: { settings.relativeCursorMovement = $0 })
    }

    private var tipUpAssistBinding: Binding<Bool> {
        settings.recordingBinding(
            "Tip-up Assist",
            get: { settings.tipUpAssist },
            set: { settings.tipUpAssist = $0 })
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
                            tool.record("Pressure Curve") {
                                tool.pressureCurve = self.pressureCurveSnapshot
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
                tool.record("Pressure Curve") { tool.pressureCurve = snapshot }
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
        tool.record("Pressure Curve") { tool.pressureCurve = snapshot }
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

    private func drawCurve(ctx: GraphicsContext, size: CGSize) {
        var path = Path()
        let curve = tool.pressureCurve
        // Draw 64-point polyline approximation of the bezier.
        path.move(to: toCanvas(x: 0, y: 0, size: size))
        for i in 1...32 {
            let t = Double(i) / 32.0
            path.addLine(to: toCanvas(x: t, y: curve.evaluate(t), size: size))
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
