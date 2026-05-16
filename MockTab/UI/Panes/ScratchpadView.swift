// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

// MARK: - SwiftUI wrapper

struct ScratchpadView: View {
    @ObservedObject var settings: TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    var productID: Int?

    @State private var currentPressure: Double = 0
    @State private var clearID = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)

            DeviceStatusBar(
                settings: settings,
                tabletManager: tabletManager,
                registry: registry,
                productID: productID ?? 0
            )
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey("Test Area"))
                .font(.headline)

            Text(
                String(
                    localized: "Draw on the canvas to verify pressure and click behavior.",
                    comment: "Description of the scratchpad drawing area"
                )
            )
            .font(.settingsLabel)
            .foregroundStyle(.secondary)

            ScratchpadCanvas(currentPressure: $currentPressure, clearID: clearID)
                .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.85), lineWidth: 1)
                }

            pressureRow

            tiltRow
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var pressureRow: some View {
        HStack(spacing: 10) {
            Text(LocalizedStringKey("Pressure"))
                .font(.settingsLabel)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.quaternary)

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(pressureColor)
                        .frame(width: geo.size.width * currentPressure)
                        .animation(reduceMotion ? nil : .linear(duration: 0.05), value: currentPressure)
                }
            }
            .frame(height: 8)

            Text(String(format: "%.0f%%", currentPressure * 100))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            Spacer()

            Button(LocalizedStringKey("Clear")) {
                clearID += 1
            }
            .help(LocalizedStringKey("Erase all strokes from the test canvas"))
//            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    private var tiltRow: some View {
        HStack(spacing: 10) {
            Text(LocalizedStringKey("Tilt"))
                .font(.settingsLabel)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)

            TiltVisualizerCanvas(tabletManager: tabletManager)
                .frame(width: 100, height: 100)
                .help(LocalizedStringKey("Live tilt direction and magnitude from the active pen."))

            Spacer()
        }
    }

    private var pressureColor: Color {
        currentPressure < 0.5
            ? .accentColor
            : Color(hue: 0.05, saturation: 0.8, brightness: 0.85)
    }
}

// MARK: - Tilt Visualizer Canvas

/// Top-down disc that shows the active pen's live tilt as a dot offset from
/// center. Concentric reference rings give a magnitude scale; values are the
/// raw `tiltX`/`tiltY` from `TabletPoint` (each clamped to ±1). When the pen
/// leaves proximity the dot snaps back to center so the disc does not flicker
/// each time the user rolls the pen off the surface.
///
/// Performance: this wrapper observes `tabletManager` and therefore invalidates
/// whenever `livePoint` publishes (~16 Hz when the pane is frontmost). The
/// inner `TiltDisc` is `Equatable` and keyed on a quantized (tiltX, tiltY)
/// pair, so SwiftUI skips body evaluation and the Canvas redraw whenever tilt
/// rounds to the same display position — sensor noise and unrelated X/Y
/// movement are filtered out for free.
struct TiltVisualizerCanvas: View {
    @ObservedObject var tabletManager: TabletManager

    var body: some View {
        // Quantize to 0.01 (sub-pixel on a 100-pt disc) so micro-jitter and
        // changes that wouldn't move the dot don't trigger redraws.
        let raw = tabletManager.livePoint
        let inProximity = raw?.inProximity == true
        let tx: Double = inProximity ? quantize(raw!.tiltX) : 0.0
        let ty: Double = inProximity ? quantize(raw!.tiltY) : 0.0
        return TiltDisc(tiltX: tx, tiltY: ty).equatable()
    }

    private func quantize(_ value: Double) -> Double {
        (max(-1.0, min(1.0, value)) * 100).rounded() / 100
    }
}

private struct TiltDisc: View, Equatable {
    let tiltX: Double
    let tiltY: Double

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let radius = min(size.width, size.height) * 0.5 - 6
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            Canvas { ctx, _ in
                drawReference(ctx: ctx, center: center, radius: radius)
                drawDot(ctx: ctx, center: center, radius: radius)
            }
        }
    }

    private func drawReference(ctx: GraphicsContext, center: CGPoint, radius: CGFloat) {
        var cross = Path()
        cross.move(to: CGPoint(x: center.x - radius, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - radius))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        ctx.stroke(cross, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)

        for fraction in [0.25, 0.5, 0.75] {
            let r = radius * fraction
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            ctx.stroke(
                Path(ellipseIn: rect),
                with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
        }

        let outer = CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2)
        ctx.stroke(Path(ellipseIn: outer), with: .color(.secondary.opacity(0.45)), lineWidth: 1)
    }

    private func drawDot(ctx: GraphicsContext, center: CGPoint, radius: CGFloat) {
        var tx = tiltX
        var ty = tiltY
        let magnitude = sqrt(tx * tx + ty * ty)
        if magnitude > 1.0 {
            tx /= magnitude
            ty /= magnitude
        }
        let dotX = center.x + radius * tx
        let dotY = center.y + radius * ty

        let r: CGFloat = 4
        let rect = CGRect(x: dotX - r, y: dotY - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: rect), with: .color(.accentColor))
        ctx.stroke(
            Path(ellipseIn: rect),
            with: .color(.white.opacity(0.9)), lineWidth: 1)
    }
}

// MARK: - NSViewRepresentable bridge

private struct ScratchpadCanvas: NSViewRepresentable {
    @Binding var currentPressure: Double
    let clearID: Int

    func makeNSView(context: Context) -> ScratchpadNSView {
        let view = ScratchpadNSView()
        view.onPressureChange = { pressure in
            currentPressure = pressure
        }
        return view
    }

    func updateNSView(_ nsView: ScratchpadNSView, context: Context) {
        if clearID != context.coordinator.lastClearID {
            nsView.clear()
            context.coordinator.lastClearID = clearID
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(clearID: clearID)
    }

    final class Coordinator {
        var lastClearID: Int

        init(clearID: Int) {
            self.lastClearID = clearID
        }
    }
}

// MARK: - NSView drawing canvas

final class ScratchpadNSView: NSView {
    var onPressureChange: ((Double) -> Void)?

    private var strokes: [[(NSPoint, CGFloat)]] = []
    private var currentStroke: [(NSPoint, CGFloat)] = []

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        currentStroke = [(point, CGFloat(event.pressure))]
        onPressureChange?(Double(event.pressure))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        currentStroke.append((point, CGFloat(event.pressure)))
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
        strokes.removeAll()
        currentStroke.removeAll()
        onPressureChange?(0)
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        drawDotGrid()
        for stroke in strokes {
            drawStroke(stroke)
        }
        drawStroke(currentStroke)
    }

    private func drawDotGrid() {
        let gridColor = NSColor.gridColor.withAlphaComponent(0.20)
        gridColor.setFill()

        let spacing: CGFloat = 16
        let radius: CGFloat = 0.75

        var x: CGFloat = spacing
        while x < bounds.width {
            var y: CGFloat = spacing
            while y < bounds.height {
                let dotRect = CGRect(
                    x: x - radius,
                    y: y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                NSBezierPath(ovalIn: dotRect).fill()
                y += spacing
            }
            x += spacing
        }
    }

    private func drawStroke(_ points: [(NSPoint, CGFloat)]) {
        guard points.count >= 2 else {
            if let (point, pressure) = points.first {
                let radius = Swift.max(1.0, pressure * 10)
                let dotRect = CGRect(
                    x: point.x - radius / 2,
                    y: point.y - radius / 2,
                    width: radius,
                    height: radius
                )
                NSColor.labelColor.withAlphaComponent(0.90).setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }
            return
        }

        for index in 1 ..< points.count {
            let (p0, pressure0) = points[index - 1]
            let (p1, pressure1) = points[index]
            let averagePressure = (pressure0 + pressure1) / 2
            let width = Swift.max(0.5, averagePressure * 20.0)

            let segment = NSBezierPath()
            segment.lineWidth = width
            segment.lineCapStyle = .round
            segment.lineJoinStyle = .round
            segment.move(to: p0)
            segment.line(to: p1)

            NSColor.labelColor.withAlphaComponent(0.85).setStroke()
            segment.stroke()
        }
    }
}
