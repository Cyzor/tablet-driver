// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026  This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab.  If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

/// Bezier pressure curve editor.
/// Draws the curve on a Canvas with two draggable control point handles.
struct PressureCurveView: View {
    @ObservedObject var settings:      TabletSettings
    @ObservedObject var tool:          ToolSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry:      DeviceRegistry
    var productID: Int?

    @State private var draggingP1 = false
    @State private var draggingP2 = false
    @State private var pressureCurveSnapshot: BezierCurve = .linear

    var body: some View {
        VStack(spacing: 0) {
            AppOverrideBar(settings: settings, domainKeys: AppOverrideBar.pressureKeys)
            ScrollView {
                mainContent
            }
            DeviceStatusBar(settings: settings, tabletManager: tabletManager, registry: registry, productID: productID ?? 0)
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pressure Curve").font(.headline)
                DeviceNameLabel(tabletManager: tabletManager, registry: registry)
            }

            curveCanvas
                .frame(height: 180)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)

            HStack {
                Button("Linear")  {
                    let old = tool.pressureCurve
                    tool.pressureCurve = .linear
                    tool.record("Linear Curve") { tool.pressureCurve = old }
                }
                Button("Soft")    {
                    let old = tool.pressureCurve
                    tool.pressureCurve = .soft
                    tool.record("Soft Curve") { tool.pressureCurve = old }
                }
                Button("Firm")    {
                    let old = tool.pressureCurve
                    tool.pressureCurve = .firm
                    tool.record("Firm Curve") { tool.pressureCurve = old }
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Stabilization")
                        .font(.subheadline)
                    Spacer()
                    Text(smoothingLabel)
                        .font(.settingsLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: smoothingBinding, in: 0...1)
                Text("Reduces cursor jitter. Higher values add lag.")
                    .font(.settingsLabel)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Double-Click Distance")
                        .font(.subheadline)
                    Spacer()
                    Text(settings.doubleClickDistance < 1
                         ? "Off"
                         : "\(Int(settings.doubleClickDistance)) pt")
                        .font(.settingsLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: doubleClickBinding, in: 0...30, step: 1)
                Text("Snaps a second tap to the first click position within this radius, making double-clicks reliable.")
                    .font(.settingsLabel)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Slider bindings with undo support

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

    // MARK: - Smoothing label

    private var smoothingLabel: String {
        switch tool.smoothingStrength {
        case 0..<0.15:  return "Off"
        case 0.15..<0.4: return "Low"
        case 0.4..<0.65: return "Medium"
        case 0.65..<0.85: return "High"
        default:          return "Max"
        }
    }

    // MARK: - Canvas

    private var curveCanvas: some View {
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
                    draggingP1 = false; draggingP2 = false
                }
            )
        }
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
        for i in 1...64 {
            let t = Double(i) / 64.0
            path.addLine(to: toCanvas(x: t, y: curve.evaluate(t), size: size))
        }
        ctx.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func drawHandles(ctx: GraphicsContext, size: CGSize) {
        let curve = tool.pressureCurve
        let p0 = toCanvas(x: 0, y: 0, size: size)
        let p1 = toCanvas(x: curve.p1.x, y: curve.p1.y, size: size)
        let p2 = toCanvas(x: curve.p2.x, y: curve.p2.y, size: size)
        let p3 = toCanvas(x: 1, y: 1, size: size)

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
            else if d2 < hitRadius        { draggingP2 = true }
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
        CGPoint(x: Swift.min(Swift.max(pt.x / size.width, 0), 1),
                y: Swift.min(Swift.max(1 - pt.y / size.height, 0), 1))
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> Double {
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
    }
}
