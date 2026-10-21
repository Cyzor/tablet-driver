// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later


import SwiftUI
import AppKit
import Combine
import TabletKit

// MARK: - NSViewRepresentable bridge

struct ScratchpadCanvas: NSViewRepresentable {
    @Binding var currentPressure: Double
    let clearID: Int
    let resetViewID: Int
    @Binding var isViewMoved: Bool
    let tabletManager: TabletManager
    let undoManager: UndoManager?

    func makeNSView(context: Context) -> ScratchpadNSView {
        let view = ScratchpadNSView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(String(localized: "Test canvas", comment: "VoiceOver label for the Scratchpad drawing canvas"))
        view.onPressureChange = { pressure in
            currentPressure = pressure
        }
        view.onViewMovedChange = { moved in
            isViewMoved = moved
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
        if resetViewID != context.coordinator.lastResetViewID {
            nsView.resetView()
            context.coordinator.lastResetViewID = resetViewID
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(clearID: clearID, resetViewID: resetViewID)
    }

    final class Coordinator {
        var lastClearID: Int
        var lastResetViewID: Int

        init(clearID: Int, resetViewID: Int) {
            self.lastClearID = clearID
            self.lastResetViewID = resetViewID
        }
    }
}

// MARK: - NSView drawing canvas

final class ScratchpadNSView: NSView {
    var onPressureChange: ((Double) -> Void)?
    var onViewMovedChange: ((Bool) -> Void)?
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

    /// Cached rendering of all committed strokes. Rebuilt whenever the stroke
    /// list changes or the view resizes. Lets draw(_:) composite a single image
    /// blit + the live stroke rather than re-rendering every segment every frame.
    private var strokeCache: NSImage?

    /// Cumulative translation from canvas space to view space.
    ///
    /// Strokes are stored in canvas space (stable coordinates independent of
    /// view size). On each resize, `contentOffset.y` is adjusted by the height
    /// delta so that content stays anchored to the top-left corner: growing the
    /// window reveals space at the bottom/right; shrinking clips there first.
    ///
    /// Drawing applies this offset as a transform; mouse events subtract it
    /// before coordinates are stored.
    private var contentOffset: CGPoint = .zero

    /// Scroll, zoom and rotation, applied before `contentOffset` so resizes
    /// keep shifting the content uniformly. Lets rings, dials and touch
    /// gestures show their effect here as in any other app.
    private var userTransform: CGAffineTransform = .identity {
        didSet {
            strokeCache = nil
            needsDisplay = true
            let moved = userTransform != .identity
            if moved != (oldValue != .identity) { onViewMovedChange?(moved) }
        }
    }

    private var canvasToView: CGAffineTransform {
        userTransform.concatenating(
            CGAffineTransform(translationX: contentOffset.x, y: contentOffset.y))
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // Ring cursor: white halo + black stroke for visibility on any background color.
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

    // A cursorUpdate tracking area, not a cursor rect: the SwiftUI host
    // resets the cursor over cursor rects.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        Self.ringCursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        Self.ringCursor.set()
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
        strokeCache = nil
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = bounds.size
        super.setFrameSize(newSize)
        // Skip the initial layout pass (oldSize is zero before the first frame
        // is set) so the offset doesn't pick up the full initial height.
        if oldSize.height > 0 {
            contentOffset.y += newSize.height - oldSize.height
        }
        strokeCache = nil
        needsDisplay = true
    }

    // MARK: - Coordinate helpers

    /// Converts a point in view space to canvas space (stable across resizes).
    private func canvasPoint(_ viewPt: NSPoint) -> NSPoint {
        viewPt.applying(canvasToView.inverted())
    }

    /// Converts a point in canvas space back to view space (for dirty-rect math).
    private func viewPoint(_ canvasPt: NSPoint) -> NSPoint {
        canvasPt.applying(canvasToView)
    }

    // MARK: - View navigation

    private static let zoomRange: ClosedRange<CGFloat> = 0.25...8

    func resetView() {
        userTransform = .identity
    }

    /// Scales and rotates about `viewPt`, the pointer or gesture location.
    private func transformView(about viewPt: NSPoint, _ change: CGAffineTransform) {
        let p = CGPoint(x: viewPt.x - contentOffset.x, y: viewPt.y - contentOffset.y)
        userTransform = userTransform
            .concatenating(CGAffineTransform(translationX: -p.x, y: -p.y))
            .concatenating(change)
            .concatenating(CGAffineTransform(translationX: p.x, y: p.y))
    }

    override func scrollWheel(with event: NSEvent) {
        // Line-based wheels report a few units per notch.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        userTransform = userTransform.concatenating(CGAffineTransform(
            translationX: event.scrollingDeltaX * scale,
            y: -event.scrollingDeltaY * scale))
    }

    override func magnify(with event: NSEvent) {
        let t = userTransform
        let zoom = sqrt(t.a * t.a + t.b * t.b)
        let target = min(max(zoom * (1 + event.magnification), Self.zoomRange.lowerBound),
                         Self.zoomRange.upperBound)
        let factor = target / zoom
        transformView(about: convert(event.locationInWindow, from: nil),
                      CGAffineTransform(scaleX: factor, y: factor))
    }

    override func rotate(with event: NSEvent) {
        transformView(about: convert(event.locationInWindow, from: nil),
                      CGAffineTransform(rotationAngle: CGFloat(event.rotation) * .pi / 180))
    }

    override func smartMagnify(with event: NSEvent) {
        resetView()
    }

    // Middle- and right-drag pan, as in Rebelle.
    override func otherMouseDragged(with event: NSEvent) { pan(by: event) }
    override func rightMouseDragged(with event: NSEvent) { pan(by: event) }
    override func otherMouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    private func pan(by event: NSEvent) {
        userTransform = userTransform.concatenating(
            CGAffineTransform(translationX: event.deltaX, y: -event.deltaY))
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        Self.ringCursor.set()
        let pt = canvasPoint(convert(event.locationInWindow, from: nil))
        let activeContext = tabletManager?.activeContext
        let isEraser = activeContext?.injector.activeToolIsEraser == true
            || activeContext?.activeToolID?.hasPrefix("eraser") == true
            || event.pointingDeviceType == .eraser
            || activeContext?.livePoint?.eraser == true
            || activeContext?.liveButtons.eraserDown == true
        if isEraser {
            currentStroke = nil
            isErasingGesture = true
            undoManager?.beginUndoGrouping()
            eraseStrokes(crossing: pt)
        } else {
            isErasingGesture = false
            currentStroke = Stroke(points: [(pt, CGFloat(event.pressure))], isEraser: false)
        }
        onPressureChange?(Double(event.pressure))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        Self.ringCursor.set()
        let viewPt = convert(event.locationInWindow, from: nil)
        let pt = canvasPoint(viewPt)
        if isErasingGesture {
            eraseStrokes(crossing: pt)
            onPressureChange?(Double(event.pressure))
            return
        }
        guard let previousCanvas = currentStroke?.points.last?.0 else { return }
        currentStroke?.points.append((pt, CGFloat(event.pressure)))
        onPressureChange?(Double(event.pressure))
        // Dirty rect is in view space; convert the previous canvas point back.
        let previousView = viewPoint(previousCanvas)
        let t = userTransform
        let zoom = sqrt(t.a * t.a + t.b * t.b)
        let pad: CGFloat = Swift.max(2, CGFloat(event.pressure) * 20) * zoom
        let minX = Swift.min(previousView.x, viewPt.x) - pad
        let maxX = Swift.max(previousView.x, viewPt.x) + pad
        let minY = Swift.min(previousView.y, viewPt.y) - pad
        let maxY = Swift.max(previousView.y, viewPt.y) + pad
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
        strokeCache = nil
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
        strokeCache = nil
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
        strokeCache = nil
        undoManager?.registerUndo(withTarget: self) { target in
            target.insertStroke(removed, at: index)
        }
        needsDisplay = true
    }

    private func insertStroke(_ stroke: Stroke, at index: Int) {
        let clamped = min(max(index, 0), strokes.count)
        strokes.insert(stroke, at: clamped)
        strokeCache = nil
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
        strokeCache = nil
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

        // Composite the cached image of all committed strokes (a single blit),
        // then draw only the live stroke on top. This keeps per-frame cost
        // constant with respect to stroke history.
        let cache = strokeCache ?? buildStrokeCache()
        cache.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)

        if let currentStroke {
            NSGraphicsContext.saveGraphicsState()
            applyContentOffset()
            drawStroke(currentStroke)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Pushes the canvas-to-view transform onto the current graphics context.
    private func applyContentOffset() {
        let xform = NSAffineTransform()
        let t = canvasToView
        xform.transformStruct = NSAffineTransformStruct(
            m11: t.a, m12: t.b, m21: t.c, m22: t.d, tX: t.tx, tY: t.ty)
        xform.concat()
    }

    /// Renders all committed strokes into an NSImage the same size as the view.
    /// Called at most once per stroke-list mutation; result is reused every frame.
    private func buildStrokeCache() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        applyContentOffset()
        for stroke in strokes {
            drawStroke(stroke)
        }
        image.unlockFocus()
        strokeCache = image
        return image
    }

    /// Dots live in canvas space so they move with the view but keep a fixed
    /// on-screen size. Spacing doubles when zoomed out so the dot count stays
    /// bounded; the in-between dots fade in with zoom rather than popping.
    private func drawDotGrid(in dirtyRect: NSRect) {
        let t = canvasToView
        let zoom = sqrt(t.a * t.a + t.b * t.b)
        var spacing: CGFloat = 16
        while spacing * zoom < 12 { spacing *= 2 }
        let fade = min(max((spacing * zoom - 12) / 8, 0), 1)
        let fineAlpha = fade * fade * (3 - 2 * fade)
        let radius: CGFloat = 1
        // Centers snap to device pixels: antialiasing at varying subpixel
        // offsets reads as blocks of lighter and darker dots when rotating.
        let scale = window?.backingScaleFactor ?? 2

        let area = dirtyRect.insetBy(dx: -radius, dy: -radius)
            .applying(t.inverted())
        let coarse = NSBezierPath()
        let fine = NSBezierPath()
        var i = Int(floor(area.minX / spacing))
        while CGFloat(i) * spacing <= area.maxX {
            var j = Int(floor(area.minY / spacing))
            while CGFloat(j) * spacing <= area.maxY {
                let p = CGPoint(x: CGFloat(i) * spacing, y: CGFloat(j) * spacing).applying(t)
                let x = (p.x * scale).rounded() / scale
                let y = (p.y * scale).rounded() / scale
                let dot = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                if i.isMultiple(of: 2) && j.isMultiple(of: 2) {
                    coarse.appendOval(in: dot)
                } else {
                    fine.appendOval(in: dot)
                }
                j += 1
            }
            i += 1
        }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let (white, alpha): (CGFloat, CGFloat) = isDark ? (1, 0.25) : (0, 0.16)
        NSColor(white: white, alpha: alpha).setFill()
        coarse.fill()
        guard fineAlpha > 0 else { return }
        NSColor(white: white, alpha: alpha * fineAlpha).setFill()
        fine.fill()
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
