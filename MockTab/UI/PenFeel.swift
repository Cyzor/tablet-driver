// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026 This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab. If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

/// Stylus feel settings: pressure curve, stabilization, click behaviour, and rotation.
struct PenFeel: View {
    @ObservedObject var settings: TabletSettings
    @ObservedObject var tool: ToolSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    var productID: Int?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            AppOverrideBar(settings: settings, domainKeys: AppOverrideBar.pressureKeys, productID: productID)
            Form {
                pressureCurveSection

                Section("Stabilization") {
                    VStack(alignment: .leading, spacing: 4) {   // ← Added .leading for consistency
                        HStack {
                            Text("Strength")
                                .font(.subheadline)
                            Spacer()
                            Text(verbatim: smoothingLabel)
                                .font(.settingsLabel)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        
                        Slider(value: smoothingBinding, in: 0...1)
                            .labelsHidden()
                            .help("Reduces cursor wobble from hand tremor. Higher values smooth more aggressively but add input lag.")

                        Text("Reduces cursor jitter. Higher values add lag.")
                            .font(.settingsLabel)
                            .foregroundStyle(.secondary)
                    }
                    // .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }

                Section("Double-Click Distance") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Distance")
                                .font(.subheadline)
                            Spacer()
                            Text(verbatim: settings.doubleClickDistance < 1
                                ? String(localized: "Off", comment: "Feature disabled — double-click distance slider at minimum value")
                                : String(localized: "\(Int(settings.doubleClickDistance)) pt", comment: "Distance in points, e.g. '10 pt'"))
                                .font(.settingsLabel)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: doubleClickBinding, in: 0...30, step: 1)
                            .labelsHidden()
                            .help("How close a second tap must land to the first to count as a double-click. Drag to Off to disable position snapping.")

                        Text("Snaps a second tap to the first click position within this radius, making double-clicks reliable.")
                            .font(.settingsLabel)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Movement") {
                    Toggle(isOn: invertRotationBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Invert Rotation Direction")
                            (Text("Current: ")
                                + Text(Image(systemName: settings.invertRotation
                                    ? "arrow.counterclockwise"
                                    : "arrow.clockwise"))
                                + Text(settings.invertRotation
                                    ? " Counter-clockwise"
                                    : " Clockwise"))
                                .font(.settingsLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help("Reverses the pen's twist direction. Enable per-app for apps that interpret rotation backwards (e.g. Krita).")

                    Toggle(isOn: relativeCursorMovementBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Relative Cursor Movement")
                            (Text("Current: ")
                                + Text(Image(systemName: settings.relativeCursorMovement
                                    ? "cursorarrow.motionlines"
                                    : "pencil.tip"))
                                + Text(settings.relativeCursorMovement
                                    ? " Relative, like a mouse"
                                    : " Absolute, like a stylus"))
                                .font(.settingsLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help("In absolute mode, each point on the tablet maps to a fixed point on screen. In relative mode, the cursor moves by the distance you move the pen, like a mouse.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            DeviceStatusBar(settings: settings, tabletManager: tabletManager, registry: registry, productID: productID ?? 0)
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
                Button(LocalizedStringKey("Linear")) {
                    let old = tool.pressureCurve
                    tool.pressureCurve = .linear
                    tool.record("Linear Curve") { tool.pressureCurve = old }
                }
                .help("Linear response — equal pen force produces equal pressure output. Best for general use.")
                Button(LocalizedStringKey("Soft")) {
                    let old = tool.pressureCurve
                    tool.pressureCurve = .soft
                    tool.record("Soft Curve") { tool.pressureCurve = old }
                }
                .help("Soft response — light pressure reaches full output quickly. Good for loose, expressive work.")
                Button(LocalizedStringKey("Firm")) {
                    let old = tool.pressureCurve
                    tool.pressureCurve = .firm
                    tool.record("Firm Curve") { tool.pressureCurve = old }
                }
                .help("Firm response — requires more force to reach full output. Good for precise detail work.")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 8))
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("Pressure Curve"))
                ToolNameLabel(tabletManager: tabletManager, registry: registry)
            }
        }
    }

    // MARK: - Bindings with undo support

    private var smoothingBinding: Binding<Double> {
        Binding(
            get: { tool.smoothingStrength },
            set: { newVal in
                let old = tool.smoothingStrength
                tool.smoothingStrength = newVal
                tool.record("Stabilization") { tool.smoothingStrength = old }
            }
        )
    }

    private var doubleClickBinding: Binding<Double> {
        Binding(
            get: { settings.doubleClickDistance },
            set: { newVal in
                let old = settings.doubleClickDistance
                settings.doubleClickDistance = newVal
                settings.record("Double-Click Distance") { settings.doubleClickDistance = old }
            }
        )
    }

    private var invertRotationBinding: Binding<Bool> {
        Binding(
            get: { settings.invertRotation },
            set: { newVal in
                let old = settings.invertRotation
                settings.invertRotation = newVal
                settings.record("Invert Rotation") { settings.invertRotation = old }
            }
        )
    }

    private var relativeCursorMovementBinding: Binding<Bool> {
        Binding(
            get: { settings.relativeCursorMovement },
            set: { newVal in
                let old = settings.relativeCursorMovement
                settings.relativeCursorMovement = newVal
                settings.record("Relative Cursor Movement") { settings.relativeCursorMovement = old }
            }
        )
    }

    // MARK: - Smoothing label

    private var smoothingLabel: String {
        switch tool.smoothingStrength {
        case 0..<0.15:  return String(localized: "Off",    comment: "Stabilization strength — disabled")
        case 0.15..<0.4:  return String(localized: "Low",    comment: "Stabilization strength label")
        case 0.4..<0.65:  return String(localized: "Medium", comment: "Stabilization strength label")
        case 0.65..<0.85: return String(localized: "High",   comment: "Stabilization strength label")
        default:          return String(localized: "Max",    comment: "Stabilization strength label — maximum value")
        }
    }
}

// MARK: - Pressure Curve Canvas (extracted for clarity)

private struct PressureCurveCanvas: View {
    @ObservedObject var tool: ToolSettings

    @State private var draggingP1 = false
    @State private var draggingP2 = false
    @State private var pressureCurveSnapshot: BezierCurve = .linear

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, _ in
                drawGrid(ctx: ctx, size: size)
                drawCurve(ctx: ctx, size: size)
                drawHandles(ctx: ctx, size: size)
            }
            .gesture(DragGesture(minimumDistance: 0)
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
        }
    }

    // MARK: - Drawing helpers

    private func drawGrid(ctx: GraphicsContext, size: CGSize) {
        var path = Path()
        for i in 1..<4 {
            let x = size.width  * Double(i) / 4
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
        for i in 1...64 {
            let t = Double(i) / 64.0
            path.addLine(to: toCanvas(x: t, y: curve.evaluate(t), size: size))
        }
        ctx.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func drawHandles(ctx: GraphicsContext, size: CGSize) {
        let curve = tool.pressureCurve
        let p0 = toCanvas(x: 0,          y: 0,          size: size)
        let p1 = toCanvas(x: curve.p1.x, y: curve.p1.y, size: size)
        let p2 = toCanvas(x: curve.p2.x, y: curve.p2.y, size: size)
        let p3 = toCanvas(x: 1,          y: 1,          size: size)

        // Guide lines from anchors to control points
        var guides = Path()
        guides.move(to: p0); guides.addLine(to: p1)
        guides.move(to: p3); guides.addLine(to: p2)
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

        let p1Canvas = toCanvas(x: tool.pressureCurve.p1.x,
                                y: tool.pressureCurve.p1.y, size: size)
        let p2Canvas = toCanvas(x: tool.pressureCurve.p2.x,
                                y: tool.pressureCurve.p2.y, size: size)

        let hitRadius: Double = 16
        if !draggingP1 && !draggingP2 {
            let d1 = dist(drag.location, p1Canvas)
            let d2 = dist(drag.location, p2Canvas)
            if d1 < hitRadius && d1 <= d2 { draggingP1 = true }
            else if d2 < hitRadius         { draggingP2 = true }
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
        CGPoint(x: Swift.min(Swift.max(pt.x / size.width,  0), 1),
                y: Swift.min(Swift.max(1 - pt.y / size.height, 0), 1))
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> Double {
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
    }
}
