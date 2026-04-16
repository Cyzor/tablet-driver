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
import AppKit

// MARK: - SwiftUI wrapper

struct ScratchpadView: View {
    @ObservedObject var settings:      TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry:      DeviceRegistry
    var productID: Int?
    @State private var currentPressure: Double = 0
    @State private var clearID = 0  // toggle to trigger a clear

    var body: some View {
        VStack(spacing: 0) {
            mainContent
            Spacer(minLength: 0)
            DeviceStatusBar(settings: settings, tabletManager: tabletManager, registry: registry, productID: productID ?? 0)
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey("Test Area"))
                .font(.headline)

            Text(String(localized: "Draw on the canvas to verify pressure and click behavior.", comment: "Description of the scratchpad drawing area"))
                .font(.settingsLabel)
                .foregroundStyle(.secondary)

            ScratchpadCanvas(currentPressure: $currentPressure, clearID: clearID)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .background(Color.white)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1))

            HStack(spacing: 10) {
                Text("Pressure")
                    .font(.settingsLabel)
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.12))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(pressureColor)
                            .frame(width: geo.size.width * currentPressure)
                            .animation(.linear(duration: 0.05), value: currentPressure)
                    }
                }
                .frame(height: 8)

                Text(String(format: "%.0f%%", currentPressure * 100))
                    .font(.monospaced)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)

                Spacer()

                Button(LocalizedStringKey("Clear")) { clearID += 1 }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .padding()
    }

    private var pressureColor: Color {
        // Shift from accent (light) toward red at full pressure.
        currentPressure < 0.5
            ? .accentColor
            : Color(hue: 0.05, saturation: 0.8, brightness: 0.85)
    }
}

// MARK: - NSViewRepresentable bridge

private struct ScratchpadCanvas: NSViewRepresentable {
    @Binding var currentPressure: Double
    let clearID: Int

    func makeNSView(context: Context) -> ScratchpadNSView {
        let view = ScratchpadNSView()
        view.onPressureChange = { p in currentPressure = p }
        return view
    }

    func updateNSView(_ nsView: ScratchpadNSView, context: Context) {
        if clearID != context.coordinator.lastClearID {
            nsView.clear()
            context.coordinator.lastClearID = clearID
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(clearID: clearID) }

    final class Coordinator {
        var lastClearID: Int
        init(clearID: Int) { self.lastClearID = clearID }
    }
}

// MARK: - NSView drawing canvas

final class ScratchpadNSView: NSView {
    var onPressureChange: ((Double) -> Void)?

    // Each stroke is a sequence of (position, pressure) samples.
    private var strokes: [[(NSPoint, CGFloat)]] = []
    private var currentStroke: [(NSPoint, CGFloat)] = []

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        currentStroke = [(p, CGFloat(event.pressure))]
        onPressureChange?(Double(event.pressure))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        currentStroke.append((p, CGFloat(event.pressure)))
        onPressureChange?(Double(event.pressure))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if !currentStroke.isEmpty {
            strokes.append(currentStroke)
            currentStroke = []
        }
        onPressureChange?(0)
        needsDisplay = true
    }

    func clear() {
        strokes = []
        currentStroke = []
        onPressureChange?(0)
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

        // Subtle dot-grid background
        let gridColor = NSColor.black.withAlphaComponent(0.04)
        gridColor.setFill()
        let spacing: CGFloat = 16
        var x: CGFloat = spacing
        while x < bounds.width {
            var y: CGFloat = spacing
            while y < bounds.height {
                let dot = CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)
                NSBezierPath(ovalIn: dot).fill()
                y += spacing
            }
            x += spacing
        }

        for stroke in strokes { drawStroke(stroke) }
        drawStroke(currentStroke)
    }

    private func drawStroke(_ points: [(NSPoint, CGFloat)]) {
        guard points.count >= 2 else {
            // Single tap: draw a dot proportional to pressure.
            if let (p, pressure) = points.first {
                let r = Swift.max(1.0, pressure * 10)
                let dot = CGRect(x: p.x - r / 2, y: p.y - r / 2, width: r, height: r)
                NSColor.black.withAlphaComponent(0.85).setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return
        }

        // Draw each segment as a round-capped line with width ∝ pressure.
        // Average adjacent pressure samples for smoother width transitions.
        for i in 1..<points.count {
            let (p0, pr0) = points[i - 1]
            let (p1, pr1) = points[i]
            let avgPressure = (pr0 + pr1) / 2
            let width = Swift.max(0.5, avgPressure * 20.0)

            let segment = NSBezierPath()
            segment.lineWidth = width
            segment.lineCapStyle = .round
            segment.lineJoinStyle = .round
            segment.move(to: p0)
            segment.line(to: p1)
            NSColor.black.withAlphaComponent(0.82).setStroke()
            segment.stroke()
        }
    }
}
