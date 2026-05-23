// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A normalised (0..1) rectangle.  Origin top-left; matches SwiftUI conventions.
struct NormalizedRect: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

/// Photoshop-style crop editor for a normalised rectangle inside an
/// aspect-preserving canvas.  Draggable interior + 4 edge handles + 4 corner
/// dots, with a dimmed exterior, accent border, and a snapshot-based drag
/// state machine that drafts internally and writes the binding once on
/// release (so the binding's observers don't see 60 Hz mutations during the
/// drag).
///
/// Used by `TabletAreaView` (pen active area) and `TouchView`'s touch-area
/// editor.  Generic `Overlay` lets the pen view draw a device-name badge
/// inside the active rect without forcing the touch view to opt in.
struct NormalizedAreaEditor<Overlay: View>: View {
    let aspectRatio: Double
    @Binding var rect: NormalizedRect
    /// Smallest dimension (width or height) the user can drag the rect to,
    /// expressed as a fraction of the canvas.  Default 5%.
    var minDimension: Double = 0.05
    /// Called once on drag-end with the rect's value *before* the drag
    /// started.  Use it to record a single coalesced undo entry.
    var onCommit: ((NormalizedRect) -> Void)? = nil
    /// Decorations drawn above the fill, below the handles.  Receives the
    /// area rect (in canvas-local coordinates) and the full canvas size.
    @ViewBuilder var overlay: (CGRect, CGSize) -> Overlay

    @State private var dragOrigin = NormalizedRect(x: 0, y: 0, w: 0, h: 0)
    @State private var draftRect: NormalizedRect?
    @State private var dragAnchor: CGPoint?

    /// Drives the focus ring for keyboard users; also enables `.onKeyPress`
    /// nudging on macOS 14+ via the conditional modifier below.
    @FocusState private var isFocused: Bool

    private enum CropEdge {
        case body
        case top, bottom, left, right
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private static var handleSize: CGFloat { 10 }
    private static var edgeThickness: CGFloat { 8 }
    private static var coordinateSpaceName: String { "normalizedAreaEditorCanvas" }
    private static var strokeWidth: CGFloat { 2.0 }
    private static var focusedStrokeWidth: CGFloat { 3.0 }

    var body: some View {
        GeometryReader { geo in
            let cs = canvasSize(in: geo.size)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                    .frame(width: cs.width, height: cs.height)
                cropOverlay(canvasSize: cs)
            }
            .frame(width: cs.width, height: cs.height)
            .coordinateSpace(name: Self.coordinateSpaceName)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .accessibilityRepresentation { accessibilityControls }
            .modifier(KeyboardNudgeModifier(
                isFocused: $isFocused,
                onMove: { dx, dy in commitNudge(dx: dx, dy: dy) },
                onResize: { dw, dh in commitResize(dw: dw, dh: dh) }))
        }
    }

    // MARK: - Accessibility (VoiceOver)

    /// Parallel control tree exposed to VoiceOver via
    /// `.accessibilityRepresentation`. The visual Canvas remains the
    /// authoritative surface for sighted-mouse users; this tree never
    /// renders, so its layout doesn't matter — only the labels, values, and
    /// adjustability matter.
    private var accessibilityControls: some View {
        VStack {
            Slider(value: bindingFor(.x), in: 0...1) {
                Text(String(
                    localized: "Active area horizontal position",
                    comment: "Accessibility label: VoiceOver slider for the active area's X origin (0%–100%)"))
            }
            Slider(value: bindingFor(.y), in: 0...1) {
                Text(String(
                    localized: "Active area vertical position",
                    comment: "Accessibility label: VoiceOver slider for the active area's Y origin (0%–100%)"))
            }
            Slider(value: bindingFor(.w), in: minDimension...1) {
                Text(String(
                    localized: "Active area width",
                    comment: "Accessibility label: VoiceOver slider for the active area's width (clamped above minimum)"))
            }
            Slider(value: bindingFor(.h), in: minDimension...1) {
                Text(String(
                    localized: "Active area height",
                    comment: "Accessibility label: VoiceOver slider for the active area's height (clamped above minimum)"))
            }
        }
    }

    private enum RectField { case x, y, w, h }

    private func bindingFor(_ field: RectField) -> Binding<Double> {
        Binding(
            get: {
                switch field {
                case .x: return rect.x
                case .y: return rect.y
                case .w: return rect.w
                case .h: return rect.h
                }
            },
            set: { newValue in
                let before = rect
                var r = rect
                switch field {
                case .x: r.x = Swift.min(Swift.max(newValue, 0), 1 - r.w)
                case .y: r.y = Swift.min(Swift.max(newValue, 0), 1 - r.h)
                case .w: r.w = Swift.min(Swift.max(newValue, minDimension), 1 - r.x)
                case .h: r.h = Swift.min(Swift.max(newValue, minDimension), 1 - r.y)
                }
                if r != before {
                    rect = r
                    onCommit?(before)
                }
            }
        )
    }

    // MARK: - Keyboard nudging (macOS 14+)

    private func commitNudge(dx: Double, dy: Double) {
        let before = rect
        var r = rect
        r.x = Swift.min(Swift.max(r.x + dx, 0), 1 - r.w)
        r.y = Swift.min(Swift.max(r.y + dy, 0), 1 - r.h)
        if r != before {
            rect = r
            onCommit?(before)
        }
    }

    private func commitResize(dw: Double, dh: Double) {
        let before = rect
        var r = rect
        r.w = Swift.min(Swift.max(r.w + dw, minDimension), 1 - r.x)
        r.h = Swift.min(Swift.max(r.h + dh, minDimension), 1 - r.y)
        if r != before {
            rect = r
            onCommit?(before)
        }
    }

    private func canvasSize(in available: CGSize) -> CGSize {
        let maxW = available.width - 8
        let maxH = available.height - 8
        if maxW / aspectRatio <= maxH {
            return CGSize(width: maxW, height: maxW / aspectRatio)
        } else {
            return CGSize(width: maxH * aspectRatio, height: maxH)
        }
    }

    private func cropOverlay(canvasSize cs: CGSize) -> some View {
        let active = draftRect ?? rect
        let x = active.x * cs.width
        let y = active.y * cs.height
        let w = active.w * cs.width
        let h = active.h * cs.height
        let areaRect = CGRect(x: x, y: y, width: w, height: h)

        return ZStack(alignment: .topLeading) {
            // Dimmed exterior — even-odd fill darkens everything outside.
            Canvas { ctx, size in
                var outer = Path(CGRect(origin: .zero, size: size))
                outer.addRect(areaRect)
                ctx.fill(outer, with: .color(.black.opacity(0.10)),
                         style: FillStyle(eoFill: true))
            }
            .frame(width: cs.width, height: cs.height)
            .allowsHitTesting(false)

            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: w, height: h)
                .offset(x: x, y: y)
                .gesture(cropGesture(.body, cs: cs))
                .cursor(.openHand)

            Rectangle()
                .strokeBorder(
                    Color.accentColor,
                    lineWidth: isFocused ? Self.focusedStrokeWidth : Self.strokeWidth)
                .frame(width: w, height: h)
                .offset(x: x, y: y)
                .allowsHitTesting(false)

            overlay(areaRect, cs)
                .allowsHitTesting(false)

            edgeHandle(.top,    rect: areaRect, cs: cs)
            edgeHandle(.bottom, rect: areaRect, cs: cs)
            edgeHandle(.left,   rect: areaRect, cs: cs)
            edgeHandle(.right,  rect: areaRect, cs: cs)

            cornerHandle(.topLeft,     rect: areaRect, cs: cs)
            cornerHandle(.topRight,    rect: areaRect, cs: cs)
            cornerHandle(.bottomLeft,  rect: areaRect, cs: cs)
            cornerHandle(.bottomRight, rect: areaRect, cs: cs)
        }
    }

    // MARK: - Handles

    private func edgeHandle(_ edge: CropEdge, rect r: CGRect, cs: CGSize) -> some View {
        let t = Self.edgeThickness
        let hs = Self.handleSize
        let frame: (CGFloat, CGFloat)
        let offset: (CGFloat, CGFloat)

        switch edge {
        case .top:
            frame  = (r.width - hs * 2, t)
            offset = (r.minX + hs, r.minY - t / 2)
        case .bottom:
            frame  = (r.width - hs * 2, t)
            offset = (r.minX + hs, r.maxY - t / 2)
        case .left:
            frame  = (t, r.height - hs * 2)
            offset = (r.minX - t / 2, r.minY + hs)
        case .right:
            frame  = (t, r.height - hs * 2)
            offset = (r.maxX - t / 2, r.minY + hs)
        default: frame = (0, 0); offset = (0, 0)
        }

        return Color.clear
            .frame(width: max(frame.0, 0), height: max(frame.1, 0))
            .contentShape(Rectangle())
            .offset(x: offset.0, y: offset.1)
            .gesture(cropGesture(edge, cs: cs))
            .cursor(edgeCursor(edge))
    }

    private func cornerHandle(_ corner: CropEdge, rect r: CGRect, cs: CGSize) -> some View {
        let s = Self.handleSize
        let pos: (CGFloat, CGFloat)
        switch corner {
        case .topLeft:     pos = (r.minX, r.minY)
        case .topRight:    pos = (r.maxX, r.minY)
        case .bottomLeft:  pos = (r.minX, r.maxY)
        case .bottomRight: pos = (r.maxX, r.maxY)
        default:           pos = (0, 0)
        }

        return Circle()
            .fill(Color.accentColor)
            .frame(width: s, height: s)
            .offset(x: pos.0 - s / 2, y: pos.1 - s / 2)
            .gesture(cropGesture(corner, cs: cs))
            .cursor(.crosshair)
    }

    // MARK: - Drag

    private func cropGesture(_ edge: CropEdge, cs: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { v in
                if dragAnchor == nil {
                    dragOrigin = rect
                    draftRect = rect
                    dragAnchor = v.startLocation
                }
                guard let anchor = dragAnchor else { return }
                let dx = (v.location.x - anchor.x) / cs.width
                let dy = (v.location.y - anchor.y) / cs.height
                applyDrag(edge: edge, dx: dx, dy: dy)
            }
            .onEnded { _ in
                if dragAnchor != nil, let draft = draftRect {
                    rect = draft
                    onCommit?(dragOrigin)
                }
                dragAnchor = nil
                draftRect = nil
            }
    }

    private func applyDrag(edge: CropEdge, dx: Double, dy: Double) {
        guard var draft = draftRect else { return }
        let o = dragOrigin
        let minD = minDimension

        switch edge {
        case .body:
            draft.x = Swift.min(Swift.max(o.x + dx, 0), 1 - o.w)
            draft.y = Swift.min(Swift.max(o.y + dy, 0), 1 - o.h)
        case .left:
            let newX = Swift.min(Swift.max(o.x + dx, 0), o.x + o.w - minD)
            draft.x = newX
            draft.w = o.x + o.w - newX
        case .right:
            draft.w = Swift.min(Swift.max(o.w + dx, minD), 1 - o.x)
        case .top:
            let newY = Swift.min(Swift.max(o.y + dy, 0), o.y + o.h - minD)
            draft.y = newY
            draft.h = o.y + o.h - newY
        case .bottom:
            draft.h = Swift.min(Swift.max(o.h + dy, minD), 1 - o.y)
        case .topLeft:
            let newX = Swift.min(Swift.max(o.x + dx, 0), o.x + o.w - minD)
            let newY = Swift.min(Swift.max(o.y + dy, 0), o.y + o.h - minD)
            draft.x = newX; draft.y = newY
            draft.w = o.x + o.w - newX
            draft.h = o.y + o.h - newY
        case .topRight:
            let newY = Swift.min(Swift.max(o.y + dy, 0), o.y + o.h - minD)
            draft.y = newY
            draft.w = Swift.min(Swift.max(o.w + dx, minD), 1 - o.x)
            draft.h = o.y + o.h - newY
        case .bottomLeft:
            let newX = Swift.min(Swift.max(o.x + dx, 0), o.x + o.w - minD)
            draft.x = newX
            draft.w = o.x + o.w - newX
            draft.h = Swift.min(Swift.max(o.h + dy, minD), 1 - o.y)
        case .bottomRight:
            draft.w = Swift.min(Swift.max(o.w + dx, minD), 1 - o.x)
            draft.h = Swift.min(Swift.max(o.h + dy, minD), 1 - o.y)
        }

        draftRect = draft
    }

    private func edgeCursor(_ edge: CropEdge) -> NSCursor {
        switch edge {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        default:            return .arrow
        }
    }
}

// Convenience initialiser for the no-overlay case (e.g. TouchView).
extension NormalizedAreaEditor where Overlay == EmptyView {
    init(
        aspectRatio: Double,
        rect: Binding<NormalizedRect>,
        minDimension: Double = 0.05,
        onCommit: ((NormalizedRect) -> Void)? = nil
    ) {
        self.aspectRatio = aspectRatio
        self._rect = rect
        self.minDimension = minDimension
        self.onCommit = onCommit
        self.overlay = { _, _ in EmptyView() }
    }
}

// MARK: - Cursor modifier

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Keyboard nudge modifier
//
// Adds arrow-key nudging when the editor is focused:
//   ←/→/↑/↓             move rect origin by 1%
//   Shift + arrow       move rect origin by 10%
//   Option + arrow      grow/shrink along that axis by 1%
//   Shift + Option +    grow/shrink along that axis by 10%
//
// Wrapped in a ViewModifier with an availability gate because `.onKeyPress`
// requires macOS 14+. On macOS 13 the editor remains mouse-driven, but the
// VoiceOver slider representation (which uses VO adjust gestures, not key
// presses) is still active.
private struct KeyboardNudgeModifier: ViewModifier {
    @FocusState.Binding var isFocused: Bool
    let onMove: (Double, Double) -> Void
    let onResize: (Double, Double) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .focusable()
                .focused($isFocused)
                // Suppress the default system focus ring; it outlines the
                // whole canvas including the dimmed exterior and competes
                // with the resize handles. The crop rect's border thickens
                // on focus instead — a purpose-built indicator.
                .focusEffectDisabled()
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow],
                            phases: .down) { press in
                    let step: Double = press.modifiers.contains(.shift) ? 0.10 : 0.01
                    let resize = press.modifiers.contains(.option)
                    switch press.key {
                    case .leftArrow:  resize ? onResize(-step, 0) : onMove(-step, 0)
                    case .rightArrow: resize ? onResize( step, 0) : onMove( step, 0)
                    case .upArrow:    resize ? onResize(0, -step) : onMove(0, -step)
                    case .downArrow:  resize ? onResize(0,  step) : onMove(0,  step)
                    default: return .ignored
                    }
                    return .handled
                }
        } else {
            content
        }
    }
}
