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
    var undoManager: UndoManager?

    @State private var currentPressure: Double = 0
    @State private var clearID = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()

            DeviceStatusBar(
                settings: settings,
                tabletManager: tabletManager,
                registry: registry,
                productID: productID ?? 0
            )
            .layoutPriority(1)
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

            ScratchpadCanvas(
                currentPressure: $currentPressure,
                clearID: clearID,
                tabletManager: tabletManager,
                undoManager: undoManager
            )
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
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
    let tabletManager: TabletManager
    let undoManager: UndoManager?

    func makeNSView(context: Context) -> ScratchpadNSView {
        let view = ScratchpadNSView()
        view.onPressureChange = { pressure in
            currentPressure = pressure
        }
        view.tabletManager = tabletManager
        view.injectedUndoManager = undoManager
        return view
    }

    func updateNSView(_ nsView: ScratchpadNSView, context: Context) {
        nsView.tabletManager = tabletManager
        nsView.injectedUndoManager = undoManager
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
    weak var tabletManager: TabletManager?
    var injectedUndoManager: UndoManager?

    override var undoManager: UndoManager? { injectedUndoManager ?? super.undoManager }

    private struct Stroke {
        var points: [(NSPoint, CGFloat)]
        var isEraser: Bool
    }

    private var strokes: [Stroke] = []
    private var currentStroke: Stroke?
    private var isErasingGesture = false

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // Ring cursor: white halo + black stroke for visibility on any background colour.
    private static let ringCursor: NSCursor = {
        let size: CGFloat = 20
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let center = NSPoint(x: size / 2, y: size / 2)
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: 7, startAngle: 0, endAngle: 360)
            NSColor.white.setStroke()
            path.lineWidth = 3
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }()

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.ringCursor)
    }

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
        NSEvent.isMouseCoalescingEnabled = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let isEraser = tabletManager?.injector?.activeToolIsEraser == true
            || tabletManager?.activeToolID?.hasPrefix("eraser") == true
            || event.pointingDeviceType == .eraser
            || tabletManager?.livePoint?.eraser == true
            || tabletManager?.liveButtons.eraserDown == true
        if isEraser {
            currentStroke = nil
            isErasingGesture = true
            undoManager?.beginUndoGrouping()
            eraseStrokes(crossing: point)
        } else {
            isErasingGesture = false
            currentStroke = Stroke(points: [(point, CGFloat(event.pressure))], isEraser: false)
        }
        onPressureChange?(Double(event.pressure))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isErasingGesture {
            eraseStrokes(crossing: point)
            onPressureChange?(Double(event.pressure))
            return
        }
        guard let previous = currentStroke?.points.last?.0 else { return }
        currentStroke?.points.append((point, CGFloat(event.pressure)))
        onPressureChange?(Double(event.pressure))
        let pad: CGFloat = Swift.max(2, CGFloat(event.pressure) * 20)
        let minX = Swift.min(previous.x, point.x) - pad
        let maxX = Swift.max(previous.x, point.x) + pad
        let minY = Swift.min(previous.y, point.y) - pad
        let maxY = Swift.max(previous.y, point.y) + pad
        setNeedsDisplay(NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }

    override func mouseUp(with event: NSEvent) {
        if isErasingGesture {
            isErasingGesture = false
            undoManager?.setActionName(
                NSLocalizedString("Erase", comment: "Undo name for eraser stroke")
            )
            undoManager?.endUndoGrouping()
        } else if let finished = currentStroke, !finished.points.isEmpty {
            currentStroke = nil
            commitStroke(finished)
        } else {
            currentStroke = nil
        }

        onPressureChange?(0)
        needsDisplay = true
    }

    func clear() {
        let previous = strokes
        currentStroke = nil
        guard !previous.isEmpty else {
            onPressureChange?(0)
            needsDisplay = true
            return
        }
        strokes.removeAll()
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreStrokes(previous)
        }
        undoManager?.setActionName(
            NSLocalizedString("Clear Canvas", comment: "Undo name for clearing the scratchpad")
        )
        onPressureChange?(0)
        needsDisplay = true
    }

    // MARK: - Undo helpers

    private func commitStroke(_ stroke: Stroke) {
        let index = strokes.count
        strokes.append(stroke)
        undoManager?.registerUndo(withTarget: self) { target in
            target.removeStroke(at: index)
        }
        undoManager?.setActionName(
            stroke.isEraser
                ? NSLocalizedString("Erase", comment: "Undo name for eraser stroke")
                : NSLocalizedString("Draw", comment: "Undo name for ink stroke")
        )
        needsDisplay = true
    }

    private func removeStroke(at index: Int) {
        guard strokes.indices.contains(index) else { return }
        let removed = strokes.remove(at: index)
        undoManager?.registerUndo(withTarget: self) { target in
            target.insertStroke(removed, at: index)
        }
        needsDisplay = true
    }

    private func insertStroke(_ stroke: Stroke, at index: Int) {
        let clamped = min(max(index, 0), strokes.count)
        strokes.insert(stroke, at: clamped)
        undoManager?.registerUndo(withTarget: self) { target in
            target.removeStroke(at: clamped)
        }
        needsDisplay = true
    }

    private func eraseStrokes(crossing point: NSPoint) {
        let radius: CGFloat = 12
        var removed = false
        var index = strokes.count - 1
        while index >= 0 {
            if strokeHitTest(strokes[index], near: point, radius: radius) {
                removeStroke(at: index)
                removed = true
            }
            index -= 1
        }
        if removed { needsDisplay = true }
    }

    private func strokeHitTest(_ stroke: Stroke, near point: NSPoint, radius: CGFloat) -> Bool {
        let r2 = radius * radius
        let pts = stroke.points
        if pts.count == 1 {
            let dx = pts[0].0.x - point.x
            let dy = pts[0].0.y - point.y
            return dx * dx + dy * dy <= r2
        }
        for index in 1 ..< pts.count {
            if segmentDistanceSquared(point, pts[index - 1].0, pts[index].0) <= r2 {
                return true
            }
        }
        return false
    }

    private func segmentDistanceSquared(_ p: NSPoint, _ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 {
            let ex = p.x - a.x
            let ey = p.y - a.y
            return ex * ex + ey * ey
        }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = Swift.max(0, Swift.min(1, t))
        let cx = a.x + t * dx
        let cy = a.y + t * dy
        let ex = p.x - cx
        let ey = p.y - cy
        return ex * ex + ey * ey
    }

    private func restoreStrokes(_ previous: [Stroke]) {
        let current = strokes
        strokes = previous
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreStrokes(current)
        }
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        drawDotGrid(in: dirtyRect)
        for stroke in strokes {
            drawStroke(stroke)
        }
        if let currentStroke {
            drawStroke(currentStroke)
        }
    }

    private func drawDotGrid(in dirtyRect: NSRect) {
        let gridColor = NSColor.gridColor.withAlphaComponent(0.20)
        gridColor.setFill()

        let spacing: CGFloat = 16
        let radius: CGFloat = 0.75

        // Snap to the nearest grid line on or before the dirty rect, then
        // iterate only within it. A single batched path avoids allocating one
        // NSBezierPath per dot on every partial repaint.
        let startX = ceil(max(spacing, dirtyRect.minX - radius) / spacing) * spacing
        let startY = ceil(max(spacing, dirtyRect.minY - radius) / spacing) * spacing

        let path = NSBezierPath()
        var x = startX
        while x < bounds.width && x <= dirtyRect.maxX + radius {
            var y = startY
            while y < bounds.height && y <= dirtyRect.maxY + radius {
                path.appendOval(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                y += spacing
            }
            x += spacing
        }
        path.fill()
    }

    private func drawStroke(_ stroke: Stroke) {
        let points = stroke.points
        let inkColor: NSColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? .white : .black
        }
        inkColor.setStroke()
        inkColor.setFill()

        guard points.count >= 2 else {
            if let (point, pressure) = points.first {
                let radius = Swift.max(1.0, pressure * 10)
                let dotRect = CGRect(
                    x: point.x - radius / 2,
                    y: point.y - radius / 2,
                    width: radius,
                    height: radius
                )
                NSBezierPath(ovalIn: dotRect).fill()
            }
            return
        }

        guard points.count >= 3 else {
            // Only two raw points — straight segment, no smoothing needed.
            let (p0, pressure0) = points[0]
            let (p1, pressure1) = points[1]
            let seg = NSBezierPath()
            seg.lineWidth = Swift.max(0.5, ((pressure0 + pressure1) / 2) * 20.0)
            seg.lineCapStyle = .round
            seg.move(to: p0)
            seg.line(to: p1)
            seg.stroke()
            return
        }

        // Midpoint bezier smoothing: each segment spans from
        // midpoint(p[i-1], p[i]) to midpoint(p[i], p[i+1]), using p[i] as a
        // quadratic control point (converted to cubic for NSBezierPath).
        // The first and last raw endpoints are preserved exactly.
        // Stored sample data is unchanged — smoothing is render-only.

        // First segment: raw start → midpoint(p[0], p[1]), straight.
        let firstMid = NSPoint(
            x: (points[0].0.x + points[1].0.x) / 2,
            y: (points[0].0.y + points[1].0.y) / 2)
        do {
            let seg = NSBezierPath()
            seg.lineWidth = Swift.max(0.5, ((points[0].1 + points[1].1) / 2) * 20.0)
            seg.lineCapStyle = .round
            seg.move(to: points[0].0)
            seg.line(to: firstMid)
            seg.stroke()
        }

        // Interior segments: smoothed arcs between consecutive midpoints.
        for i in 1 ..< points.count - 1 {
            let (p0, _) = points[i - 1]
            let (ctrl, pressure) = points[i]
            let (p2, _) = points[i + 1]

            let segStart = NSPoint(x: (p0.x + ctrl.x) / 2, y: (p0.y + ctrl.y) / 2)
            let segEnd   = NSPoint(x: (ctrl.x + p2.x) / 2, y: (ctrl.y + p2.y) / 2)

            // Quadratic (segStart, ctrl, segEnd) → cubic control points.
            let cp1 = NSPoint(x: (segStart.x + 2 * ctrl.x) / 3, y: (segStart.y + 2 * ctrl.y) / 3)
            let cp2 = NSPoint(x: (2 * ctrl.x + segEnd.x) / 3,   y: (2 * ctrl.y + segEnd.y) / 3)

            let seg = NSBezierPath()
            seg.lineWidth = Swift.max(0.5, pressure * 20.0)
            seg.lineCapStyle = .round
            seg.lineJoinStyle = .round
            seg.move(to: segStart)
            seg.curve(to: segEnd, controlPoint1: cp1, controlPoint2: cp2)
            seg.stroke()
        }

        // Last segment: midpoint(p[n-2], p[n-1]) → raw end, straight.
        let n = points.count
        let lastMid = NSPoint(
            x: (points[n - 2].0.x + points[n - 1].0.x) / 2,
            y: (points[n - 2].0.y + points[n - 1].0.y) / 2)
        do {
            let seg = NSBezierPath()
            seg.lineWidth = Swift.max(0.5, ((points[n - 2].1 + points[n - 1].1) / 2) * 20.0)
            seg.lineCapStyle = .round
            seg.move(to: lastMid)
            seg.line(to: points[n - 1].0)
            seg.stroke()
        }
    }
}
