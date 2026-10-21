// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - Bezel frame

/// Sets `content`, the area editor, into the tablet's bezel so it covers the
/// surface exactly.
struct TabletBezelFrame<Content: View>: View {
    let figure: TabletFigure
    @ViewBuilder var content: Content

    @Environment(\.displayScale) private var displayScale

    /// The area editor keeps 4 pt clear on each side for its edge.
    private static var editorInset: CGFloat { 4 }

    /// The row's height: taller when turned upright, so the surface keeps
    /// its room.
    static func height(_ orientation: TabletOrientation) -> CGFloat { orientation.swapsAxes ? 300 : 200 }

    var body: some View {
        GeometryReader { geo in
            let drawing = figure.drawing(.backdrop, in: TabletBezelView.bounds(geo.size), scale: displayScale)
            let surface = drawing.surface
            ZStack(alignment: .topLeading) {
                TabletBezelView(figure: figure)
                    .equatable()
                    .frame(width: geo.size.width, height: geo.size.height)
                content
                    .frame(
                        width: surface.width + Self.editorInset * 2,
                        height: surface.height + Self.editorInset * 2)
                    .offset(x: surface.minX - Self.editorInset, y: surface.minY - Self.editorInset)
                    .environment(\.areaEditorCanvasOpening,
                                 TabletDiagramInk.openingRadius(drawing, scale: displayScale))
            }
        }
    }
}

// MARK: - Bezel

/// The tablet drawn quietly behind the area editor, in the Buttons pane
/// diagram's line art at low contrast. Decorative; the editor on top carries
/// the meaning.
struct TabletBezelView: View, Equatable {
    let figure: TabletFigure

    /// Where the body fits, leaving its edge clear of the frame.
    static func bounds(_ size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
    }

    var body: some View {
        Canvas { context, size in
            let scale = max(context.environment.displayScale, 1)
            let d = figure.drawing(.backdrop, in: Self.bounds(size), scale: scale)
            TabletDiagramInk.draw(d, isPenDisplay: figure.isPenDisplay,
                                  palette: .backdrop(dark: context.environment.colorScheme == .dark),
                                  scale: scale, in: &context)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Glyph

/// The tablet as an orientation picture: an outline around filled panels, with
/// the controls and a tablet's corner marks knocked out. A figure with no controls
/// gets a wider bezel and a deeper chin to show which way is down.
struct TabletGlyphView: View, Equatable {
    let figure: TabletFigure
    /// Tints the glyph with the accent, for the orientation in use.
    var isSelected = false

    @Environment(\.controlActiveState) private var controlActiveState

    // Environment changes refresh the view on their own, so equality
    // compares only the drawn state.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        // SwiftUI compares views on the main actor.
        MainActor.assumeIsolated { a.figure == b.figure && a.isSelected == b.isSelected }
    }

    var body: some View {
        Canvas { context, size in
            let d = figure.drawing(.glyph, in: CGRect(origin: .zero, size: size), scale: context.environment.displayScale)
            let u = d.unit
            let radii = TabletFigureInk.Radii(body: 7 * u, opening: 4 * u, panel: 2 * u, key: u)
            let tint = isSelected ? Color.windowAccent(controlActiveState).opacity(0.4) : nil
            TabletFigureInk.draw(d, radii: radii, tint: tint, in: &context)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Icon

/// The tablet as a list icon, in the glyph's style: enough to tell one
/// tablet from another at a glance.
struct TabletIconView: View, Equatable {
    let figure: TabletFigure

    var body: some View {
        Canvas { context, size in
            let d = figure.drawing(.icon, in: CGRect(origin: .zero, size: size), scale: context.environment.displayScale)
            let radii = TabletFigureInk.Radii(body: 3, opening: 2, panel: 0.5, key: 0)
            TabletFigureInk.draw(d, radii: radii, tint: nil, in: &context)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Glyph and icon drawing

/// How the glyph and icon draw: an outline ring around filled panels, in the
/// pen diagram's body fill, with the controls knocked out.
enum TabletFigureInk {
    struct Radii {
        var body: CGFloat
        var opening: CGFloat
        var panel: CGFloat
        var key: CGFloat
    }

    static func draw(_ d: TabletFigure.Drawing, radii: Radii, tint: Color?, in context: inout GraphicsContext) {
        // The pen diagram's body fill, so the two read as one family.
        let ink = context.environment.colorScheme == .dark ? Color.primary.opacity(0.80) : Color.secondary
        context.drawLayer { layer in
            var outline = Path(roundedRect: d.body, cornerRadius: radii.body, style: .continuous)
            outline.addPath(Path(roundedRect: d.opening, cornerRadius: radii.opening, style: .continuous))
            layer.fill(outline, with: .color(ink), style: FillStyle(eoFill: true))
            for panel in d.bands + [d.surface] {
                layer.fill(Path(roundedRect: panel, cornerRadius: radii.panel, style: .continuous), with: .color(ink))
            }
            layer.blendMode = .destinationOut
            for shape in d.shapes {
                let r = shape.rect
                let path: Path
                switch shape.kind {
                case .ring, .dial, .center, .wedge, .button:
                    path = Path(ellipseIn: r)
                case .strip:
                    path = Path(roundedRect: r, cornerRadius: min(r.width, r.height) / 2)
                case .key, .cluster:
                    path = radii.key > 0 ? Path(roundedRect: r, cornerRadius: radii.key) : Path(r)
                case .mark:
                    path = Path(r)
                }
                layer.fill(path, with: .color(.black))
            }
            if let tint {
                // Tint only what's drawn, leaving the knockouts clear.
                layer.blendMode = .sourceAtop
                layer.fill(Path(d.body), with: .color(tint))
            }
        }
    }
}

// MARK: - Diagram ink

/// How the Buttons pane's diagram and the area editors' backdrop draw a
/// tablet, in the pen diagram's anatomy: an outline ring, a cleared gap, then
/// the body filled, with the surface and each control set into it through a
/// cleared slot. Every width and corner is the drawing's grid step.
enum TabletDiagramInk {
    struct Palette {
        /// Outline and body.
        var ink: Color
        /// Each control's face, and a pen display's screen.
        var face: Color
        var screen: Color
        /// A face in use.
        var accent: Color
        /// Controls cut straight out of the body, with no slot or face, as
        /// the glyph draws them: one tone, borderless.
        var knockout = false
        /// The body's corner radius, in grid steps.
        var corner: CGFloat = 5

        /// The Buttons pane's diagram, the pen diagram's palette.
        static func diagram(dark: Bool, accent: Color) -> Palette {
            let face = dark ? Color.secondary : Color.primary.opacity(0.35)
            return Palette(ink: dark ? Color.primary.opacity(0.80) : Color.secondary, face: face, screen: face,
                           accent: accent)
        }

        /// Behind the area editors: the same relationship at low contrast, so
        /// the editor on top leads.
        static func backdrop(dark: Bool) -> Palette {
            let ink = dark ? Color.white : Color.black
            return Palette(ink: ink.opacity(0.16), face: ink.opacity(dark ? 0.08 : 0.07),
                           screen: Color.black.opacity(dark ? 0.40 : 0.16), accent: ink.opacity(dark ? 0.08 : 0.07),
                           knockout: true, corner: 3)
        }
    }

    /// One grid step: the drawing's own, or 1.5 pt in whole pixels.
    private static func unit(_ d: TabletFigure.Drawing, scale: CGFloat) -> CGFloat {
        d.grid > 0 ? d.grid : max((1.5 * scale).rounded(), 1) / scale
    }

    /// The surface opening's corner radius.
    static func openingRadius(_ d: TabletFigure.Drawing, scale: CGFloat) -> CGFloat {
        3 * unit(d, scale: scale)
    }

    static func draw(
        _ d: TabletFigure.Drawing, isPenDisplay: Bool, palette: Palette, lit: UInt64 = 0,
        pressed: ControlTarget? = nil, scale: CGFloat, in context: inout GraphicsContext
    ) {
        let u = unit(d, scale: scale)
        let line = u, gap = u, radius = palette.corner * u
        guard d.body.width > 4 * radius, d.body.height > 4 * radius else { return }

        var outline = Path(roundedRect: d.body, cornerRadius: radius, style: .continuous)
        outline.addPath(Path(roundedRect: d.body.insetBy(dx: line, dy: line), cornerRadius: radius - line,
                             style: .continuous))
        context.fill(outline, with: .color(palette.ink), style: FillStyle(eoFill: true))

        let inset = line + gap
        var body = Path(roundedRect: d.body.insetBy(dx: inset, dy: inset), cornerRadius: radius - inset,
                        style: .continuous)
        let surface = d.surface.insetBy(dx: gap, dy: gap)
        body.addPath(Path(roundedRect: d.surface, cornerRadius: openingRadius(d, scale: scale),
                          style: .continuous))
        if palette.knockout {
            // Each face cut once; a pad's wedges and a block's keys don't overlap.
            for shape in d.shapes where shape.kind != .mark {
                body.addPath(Self.face(shape, scale: scale, gap: gap, corner: u))
            }
            context.fill(body, with: .color(palette.ink), style: FillStyle(eoFill: true))
            if isPenDisplay {
                context.fill(Path(roundedRect: surface, cornerRadius: 2 * u, style: .continuous),
                             with: .color(palette.screen))
            }
            return
        }
        // Even-odd fills a doubly cut area back in, so each area is cut once:
        // a pad's four keys share one slot, and the slots of keys close
        // enough to touch merge into one block, as in a cluster.
        var pads: [CGRect] = []
        var blocks: [CGRect] = []
        for shape in d.shapes where shape.kind != .mark && shape.kind != .center {
            switch shape.kind {
            case .wedge:
                if pads.contains(shape.rect) { continue }
                pads.append(shape.rect)
                body.addPath(path(shape, outset: gap, corner: u))
            case .key, .cluster:
                var block = shape.rect.insetBy(dx: -gap, dy: -gap)
                while let i = blocks.firstIndex(where: { $0.intersects(block) }) {
                    block = block.union(blocks.remove(at: i))
                }
                blocks.append(block)
            default:
                body.addPath(path(shape, outset: gap, corner: u))
            }
        }
        for block in blocks {
            body.addPath(Path(roundedRect: block, cornerRadius: u + gap, style: .continuous))
        }
        context.fill(body, with: .color(palette.ink), style: FillStyle(eoFill: true))

        // A pen display's screen is a face in its opening; a tablet's active
        // area stays open.
        if isPenDisplay {
            context.fill(Path(roundedRect: surface, cornerRadius: 2 * u, style: .continuous), with: .color(palette.screen))
        }

        for shape in d.shapes where shape.kind != .mark {
            let face = Self.face(shape, scale: scale, gap: gap, corner: u)
            let on = shape.target.map { lit & (1 << UInt64($0.bit)) != 0 } ?? false
            context.fill(face, with: .color(on ? palette.accent : palette.face), style: FillStyle(eoFill: true))
            if let target = shape.target, target == pressed {
                // Pushed-button feedback, like AppKit's press state.
                context.fill(face, with: .color(.primary.opacity(0.15)), style: FillStyle(eoFill: true))
            }
        }
    }

    /// A shape's outline grown by `outset`, for the slot cleared around it;
    /// keys take `corner` as their radius.
    private static func path(_ shape: TabletFigure.Shape, outset: CGFloat = 0, corner: CGFloat) -> Path {
        let r = shape.rect.insetBy(dx: -outset, dy: -outset)
        switch shape.kind {
        case .ring, .dial, .center, .wedge, .button: return Path(ellipseIn: r)
        case .strip: return Path(roundedRect: r, cornerRadius: min(r.width, r.height) / 2)
        case .key, .cluster, .mark:
            return Path(roundedRect: r, cornerRadius: min(corner, min(r.width, r.height) / 2) + outset, style: .continuous)
        }
    }

    /// The face that fills: a ring is an annulus, so its hole stays clear; a
    /// pad's key is a quarter of the ring around its center, cleared apart
    /// from its neighbors by `gap`.
    private static func face(_ shape: TabletFigure.Shape, scale: CGFloat, gap: CGFloat, corner: CGFloat) -> Path {
        if case let .wedge(direction) = shape.kind {
            let r = shape.rect
            let center = CGPoint(x: r.midX, y: r.midY)
            let outer = r.width / 2, inner = r.width * 0.18 + gap
            // Half the gap on each side, as an angle at each radius.
            let spread = Double.pi / 4
            var wedge = Path()
            wedge.addArc(center: center, radius: outer, startAngle: .radians(direction - spread + gap / 2 / outer),
                         endAngle: .radians(direction + spread - gap / 2 / outer), clockwise: false)
            wedge.addArc(center: center, radius: inner, startAngle: .radians(direction + spread - gap / 2 / inner),
                         endAngle: .radians(direction - spread + gap / 2 / inner), clockwise: true)
            wedge.closeSubpath()
            return wedge
        }
        guard shape.kind == .ring else { return path(shape, corner: corner) }
        let r = shape.rect
        var ring = Path(ellipseIn: r)
        let inset = (r.width * (1 - TabletFigure.ringHole) / 2 * scale).rounded() / scale
        ring.addEllipse(in: r.insetBy(dx: inset, dy: inset))
        return ring
    }
}
