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
/// Visual treatment of the crop chrome — the embedded settings-pane editors
/// sit inside a small thumbnail and want a self-contained frame with a solid
/// accent border and fill; a full-screen overlay sits directly over the real
/// desktop and wants the macOS screenshot-tool look instead: no canvas-edge
/// border/inset (the canvas already *is* the full screen), a dashed border,
/// near-invisible fill, and a heavier exterior dim.
enum AreaEditorStyle {
    case embedded
    case fullScreen
}

struct NormalizedAreaEditor<Background: View, Overlay: View>: View {
    let aspectRatio: Double
    @Binding var rect: NormalizedRect
    /// Smallest dimension (width or height) the user can drag the rect to,
    /// expressed as a fraction of the canvas.  Default 5%.
    var minDimension: Double = 0.05
    var style: AreaEditorStyle = .embedded
    /// Opacity of the exterior dimming mask. The embedded settings-pane
    /// editors sit over a wallpaper thumbnail and want a light touch; a
    /// full-screen overlay sitting over the real desktop wants a much
    /// stronger dim so the crop rect reads clearly (Apple's screenshot tool
    /// convention).
    var dimOpacity: Double = 0.10
    /// Called once on drag-end with the rect's value *before* the drag
    /// started.  Use it to record a single coalesced undo entry.
    var onCommit: ((NormalizedRect) -> Void)? = nil
    /// Drawn first, behind the crop chrome (dim exterior, fill, border,
    /// handles) — e.g. a display's wallpaper thumbnail. Sized to the full
    /// canvas. Defaults to nothing, matching every pane before this existed.
    @ViewBuilder var background: () -> Background
    /// Decorations drawn above the fill and border, below the handles.
    /// Receives the area rect (in canvas-local coordinates) and the full
    /// canvas size. Since this draws above the border, content that fills
    /// the *entire* canvas here (rather than just the area rect) will paint
    /// over the border — use `background` instead for anything full-canvas.
    @ViewBuilder var overlay: (CGRect, CGSize) -> Overlay

    @State private var dragOrigin = NormalizedRect(x: 0, y: 0, w: 0, h: 0)
    @State private var draftRect: NormalizedRect?
    @State private var dragAnchor: CGPoint?
    /// Latched once per corner drag (Shift held) from the first frame with
    /// meaningful travel, so which axis stays cursor-exact doesn't
    /// flip-flop frame to frame — see `applyKeepProportions`.
    @State private var cornerDominantAxisIsWidth: Bool?

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
                background()
                    .frame(width: cs.width, height: cs.height)
                    .allowsHitTesting(false)
                if style == .embedded {
                    Rectangle()
                        .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                        .frame(width: cs.width, height: cs.height)
                }
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
        // The embedded editors reserve 8pt so the 1px canvas-edge border
        // above doesn't clip; a full-screen overlay has no such border and
        // must let the crop rect reach the true screen edge.
        let inset: CGFloat = style == .embedded ? 8 : 0
        let maxW = available.width - inset
        let maxH = available.height - inset
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
                ctx.fill(outer, with: .color(.black.opacity(dimOpacity)),
                         style: FillStyle(eoFill: true))
            }
            .frame(width: cs.width, height: cs.height)
            .allowsHitTesting(false)

            Rectangle()
                .fill(Color.accentColor.opacity(style == .fullScreen ? 0.01 : 0.12))
                .frame(width: w, height: h)
                .offset(x: x, y: y)
                .gesture(cropGesture(.body, cs: cs))
                .cursor(.openHand)

            Group {
                if style == .fullScreen {
                    Rectangle()
                        .strokeBorder(
                            Color.white,
                            style: StrokeStyle(
                                lineWidth: isFocused ? Self.focusedStrokeWidth : Self.strokeWidth,
                                dash: [6, 4]))
                } else {
                    Rectangle()
                        .strokeBorder(
                            Color.accentColor,
                            lineWidth: isFocused ? Self.focusedStrokeWidth : Self.strokeWidth)
                }
            }
            .frame(width: w, height: h)
            .offset(x: x, y: y)
            .allowsHitTesting(false)

            overlay(areaRect, cs)
                .allowsHitTesting(false)

            edgeHandle(.top,    rect: areaRect, cs: cs)
            edgeHandle(.bottom, rect: areaRect, cs: cs)
            edgeHandle(.left,   rect: areaRect, cs: cs)
            edgeHandle(.right,  rect: areaRect, cs: cs)

            // Visible dots, drawn as siblings directly in this ZStack's
            // canvas-absolute coordinate space — same as `cornerHandle`
            // below — rather than nested inside `edgeHandle`'s own
            // drag-strip frame, so both handle kinds straddle the dashed
            // border from the exact same `areaRect` math with no risk of
            // the strip's local offset throwing the dot's position off.
            if style == .fullScreen {
                edgeHandleDot(.top,    rect: areaRect)
                edgeHandleDot(.bottom, rect: areaRect)
                edgeHandleDot(.left,   rect: areaRect)
                edgeHandleDot(.right,  rect: areaRect)
            }

            cornerHandle(.topLeft,     rect: areaRect, cs: cs)
            cornerHandle(.topRight,    rect: areaRect, cs: cs)
            cornerHandle(.bottomLeft,  rect: areaRect, cs: cs)
            cornerHandle(.bottomRight, rect: areaRect, cs: cs)
        }
    }

    // MARK: - Handles

    /// Invisible hit-testing strip for dragging an edge — draws nothing
    /// itself; the visible dot for `.fullScreen` style is `edgeHandleDot`,
    /// a sibling drawn directly in `cropOverlay`'s coordinate space.
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
            .contentShape(Rectangle())
            .frame(width: max(frame.0, 0), height: max(frame.1, 0))
            .offset(x: offset.0, y: offset.1)
            .gesture(cropGesture(edge, cs: cs))
            .cursor(edgeCursor(edge))
    }

    /// Visible midpoint handle, positioned in the same canvas-absolute
    /// coordinate space `cornerHandle` uses — straddles the dashed border
    /// exactly like the corner dots.
    private func edgeHandleDot(_ edge: CropEdge, rect r: CGRect) -> some View {
        let s = Self.handleSize
        let pos: CGPoint
        switch edge {
        case .top:    pos = CGPoint(x: r.midX, y: r.minY)
        case .bottom: pos = CGPoint(x: r.midX, y: r.maxY)
        case .left:   pos = CGPoint(x: r.minX, y: r.midY)
        case .right:  pos = CGPoint(x: r.maxX, y: r.midY)
        default:      pos = .zero
        }
        return handleDot()
            .frame(width: s, height: s)
            .offset(x: pos.x - s / 2, y: pos.y - s / 2)
            .allowsHitTesting(false)
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

        return handleDot()
            .frame(width: s, height: s)
            .offset(x: pos.0 - s / 2, y: pos.1 - s / 2)
            .gesture(cropGesture(corner, cs: cs))
            .cursor(.crosshair)
    }

    /// A single handle dot — solid accent fill for the embedded editors,
    /// blue-on-white (macOS screenshot tool's own handle colors) full screen.
    @ViewBuilder
    private func handleDot() -> some View {
        if style == .fullScreen {
            Circle()
                .fill(Color.accentColor)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
        } else {
            Circle()
                .fill(Color.accentColor)
        }
    }

    // MARK: - Drag

    private func cropGesture(_ edge: CropEdge, cs: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { v in
                if dragAnchor == nil {
                    dragOrigin = rect
                    draftRect = rect
                    dragAnchor = v.startLocation
                    cornerDominantAxisIsWidth = nil
                }
                guard let anchor = dragAnchor else { return }
                let dx = (v.location.x - anchor.x) / cs.width
                let dy = (v.location.y - anchor.y) / cs.height
                if cornerDominantAxisIsWidth == nil, dx * dx + dy * dy > 0.0001 * 0.0001 {
                    cornerDominantAxisIsWidth = abs(dx) >= abs(dy)
                }
                let flags = NSEvent.modifierFlags
                applyDrag(
                    edge: edge, dx: dx, dy: dy,
                    fromCenter: flags.contains(.option),
                    keepProportions: flags.contains(.shift))
            }
            .onEnded { _ in
                if dragAnchor != nil, let draft = draftRect {
                    rect = draft
                    onCommit?(dragOrigin)
                }
                dragAnchor = nil
                draftRect = nil
                cornerDominantAxisIsWidth = nil
            }
    }

    private func applyDrag(
        edge: CropEdge, dx rawDx: Double, dy rawDy: Double,
        fromCenter: Bool = false, keepProportions: Bool = false
    ) {
        guard var draft = draftRect else { return }
        let o = dragOrigin
        let minD = minDimension

        guard edge != .body else {
            draft.x = Swift.min(Swift.max(o.x + rawDx, 0), 1 - o.w)
            draft.y = Swift.min(Swift.max(o.y + rawDy, 0), 1 - o.h)
            draftRect = draft
            return
        }

        // Option mirrors growth to the opposite side, so the grabbed handle
        // stays glued to the cursor only if the driving edge moves *twice*
        // the cursor's delta (half goes to this side, half to the mirror).
        var dx = rawDx, dy = rawDy
        if fromCenter {
            dx *= 2
            dy *= 2
        }

        switch edge {
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
        case .body:
            break
        }

        if keepProportions, o.h > 0 {
            draft = applyKeepProportions(edge: edge, draft: draft, origin: o, minDimension: minD)
        }
        if fromCenter {
            draft = anchorToCenter(edge: edge, draft: draft, origin: o)
        }

        draftRect = draft
    }

    /// Rescales the non-driving axis so the rect's aspect ratio matches the
    /// drag's starting aspect ratio — matches Photoshop/Sketch's Shift-drag
    /// convention. The driving axis (the one the dragged handle controls
    /// directly) is left alone; a corner drag drives both, so its larger
    /// fractional change wins. Re-anchors the edges Shift didn't drive so
    /// the grabbed handle stays under the cursor.
    private func applyKeepProportions(
        edge: CropEdge, draft: NormalizedRect, origin o: NormalizedRect, minDimension minD: Double
    ) -> NormalizedRect {
        var draft = draft
        let targetAspect = o.w / o.h

        // `fixedRight`/`fixedBottom`: true when that opposite edge must stay
        // pinned at its origin position (i.e. the near edge is what's being
        // dragged), so a width/height rescale needs to shift x/y to compensate.
        // Corners rescale whichever axis moved proportionally *less*, so the
        // axis the cursor is actively pushing harder on stays exact and only
        // the lagging axis snaps to match it.
        switch edge {
        case .left:
            draft.h = Swift.max(draft.w / targetAspect, minD)
            draft.y = o.y + o.h - draft.h
        case .right:
            draft.h = Swift.max(draft.w / targetAspect, minD)
        case .top:
            draft.w = Swift.max(draft.h * targetAspect, minD)
            draft.x = o.x + o.w - draft.w
        case .bottom:
            draft.w = Swift.max(draft.h * targetAspect, minD)
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            // Corner drags: pick the dominant axis once, from raw cursor
            // travel at drag start, and hold that choice for the whole
            // gesture — re-evaluating every frame flip-flops which axis is
            // "exact" and reads as the grabbed corner outrunning the cursor.
            if cornerDominantAxisIsWidth ?? true {
                draft.h = Swift.max(draft.w / targetAspect, minD)
                if edge == .topLeft || edge == .topRight {
                    draft.y = o.y + o.h - draft.h
                }
            } else {
                draft.w = Swift.max(draft.h * targetAspect, minD)
                if edge == .topLeft || edge == .bottomLeft {
                    draft.x = o.x + o.w - draft.w
                }
            }
        case .body:
            break
        }

        draft.w = Swift.min(draft.w, 1 - draft.x)
        draft.h = Swift.min(draft.h, 1 - draft.y)
        return draft
    }

    /// Re-centers the rect on the drag's original center after a mirrored
    /// resize — the width/height computed by the doubled delta already
    /// reflect both sides growing together; this just re-derives x/y from
    /// that center instead of the single-sided edge math above, and clamps
    /// so the mirrored rect can't run off either edge of the canvas.
    private func anchorToCenter(
        edge: CropEdge, draft: NormalizedRect, origin o: NormalizedRect
    ) -> NormalizedRect {
        var draft = draft
        let centerX = o.x + o.w / 2
        let centerY = o.y + o.h / 2
        let maxW = Swift.min(centerX, 1 - centerX) * 2
        let maxH = Swift.min(centerY, 1 - centerY) * 2

        draft.w = Swift.min(draft.w, maxW)
        draft.h = Swift.min(draft.h, maxH)
        draft.x = centerX - draft.w / 2
        draft.y = centerY - draft.h / 2
        return draft
    }

    private func edgeCursor(_ edge: CropEdge) -> NSCursor {
        switch edge {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        default:            return .arrow
        }
    }
}

// Convenience initialiser for the no-background, no-overlay case (e.g. TouchView).
extension NormalizedAreaEditor where Background == EmptyView, Overlay == EmptyView {
    init(
        aspectRatio: Double,
        rect: Binding<NormalizedRect>,
        minDimension: Double = 0.05,
        style: AreaEditorStyle = .embedded,
        dimOpacity: Double = 0.10,
        onCommit: ((NormalizedRect) -> Void)? = nil
    ) {
        self.aspectRatio = aspectRatio
        self._rect = rect
        self.minDimension = minDimension
        self.style = style
        self.dimOpacity = dimOpacity
        self.onCommit = onCommit
        self.background = { EmptyView() }
        self.overlay = { _, _ in EmptyView() }
    }
}

// Convenience initialiser for the no-background case with a live overlay
// (e.g. the pen pane's letterbox preview + device-name badge, or the
// full-screen screen-area overlay's dimension HUD).
extension NormalizedAreaEditor where Background == EmptyView {
    init(
        aspectRatio: Double,
        rect: Binding<NormalizedRect>,
        minDimension: Double = 0.05,
        style: AreaEditorStyle = .embedded,
        dimOpacity: Double = 0.10,
        onCommit: ((NormalizedRect) -> Void)? = nil,
        @ViewBuilder overlay: @escaping (CGRect, CGSize) -> Overlay
    ) {
        self.aspectRatio = aspectRatio
        self._rect = rect
        self.minDimension = minDimension
        self.style = style
        self.dimOpacity = dimOpacity
        self.onCommit = onCommit
        self.background = { EmptyView() }
        self.overlay = overlay
    }
}

// Convenience initialiser for the background-only case with no overlay
// (e.g. the Displays pane's wallpaper-backed screen-area editor).
extension NormalizedAreaEditor where Overlay == EmptyView {
    init(
        aspectRatio: Double,
        rect: Binding<NormalizedRect>,
        minDimension: Double = 0.05,
        onCommit: ((NormalizedRect) -> Void)? = nil,
        @ViewBuilder background: @escaping () -> Background
    ) {
        self.aspectRatio = aspectRatio
        self._rect = rect
        self.minDimension = minDimension
        self.onCommit = onCommit
        self.background = background
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
