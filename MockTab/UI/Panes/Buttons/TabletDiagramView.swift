// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - TabletDiagramView

/// The tablet drawn in the Buttons pane: its keys, rings, and strips light
/// while in use, and clicking one starts recording in its row, as the pen
/// diagram does. Drawn from the bezel layout with a verified control map.
///
/// Thin non-equatable wrapper owning the pressed control, for the same
/// reason as `PenDiagramView`: a Form row swallows @State-driven re-renders
/// inside an EquatableView.
struct TabletDiagramView: View {
    /// Landscape, with `controls` set.
    let figure: TabletFigure
    /// Bits of the controls in use; see `ControlTarget.bit`.
    let lit: UInt64
    /// Bits of the controls that have a row, so they answer clicks.
    let enabled: UInt64
    var onTap: ((ControlTarget) -> Void)? = nil

    /// The control under a mouse press that started on it, darkened like a
    /// pushed button; dragging off it cancels.
    @State private var pressed: ControlTarget? = nil
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scrollPaneTo) private var scrollPaneTo

    var body: some View {
        TabletDiagramCore(figure: figure, lit: lit, enabled: enabled, pressed: pressed)
            .equatable()
            .overlay {
                if onTap != nil {
                    GeometryReader { geo in
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let start = target(at: value.startLocation, in: geo.size)
                                    let current = target(at: value.location, in: geo.size)
                                    let held = (start != nil && current == start) ? start : nil
                                    if pressed != held { pressed = held }
                                }
                                .onEnded { value in
                                    pressed = nil
                                    if let start = target(at: value.startLocation, in: geo.size),
                                       target(at: value.location, in: geo.size) == start {
                                        // Rows carry their target as ID.
                                        scrollPaneTo(start)
                                        onTap?(start)
                                    }
                                })
                    }
                }
            }
            // Sighted-only affordance: highlights and clicks are both
            // redundant with the binding rows, which carry the accessible
            // interface for this section.
            .accessibilityHidden(true)
    }

    private func target(at point: CGPoint, in size: CGSize) -> ControlTarget? {
        let d = figure.drawing(.bezel, in: TabletDiagramCore.bounds(size), scale: displayScale)
        guard let hit = d.target(at: point), enabled & (1 << UInt64(hit.bit)) != 0 else { return nil }
        return hit
    }
}

// MARK: - TabletDiagramCore

/// The drawn diagram, equatable over what it shows, so the pane's live
/// updates redraw it only when a lit control changes.
private struct TabletDiagramCore: View, Equatable {
    let figure: TabletFigure
    let lit: UInt64
    let enabled: UInt64
    let pressed: ControlTarget?

    @Environment(\.controlActiveState) private var controlActiveState

    // Environment changes refresh the view on their own, so equality
    // compares only the drawn state.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        // SwiftUI compares views on the main actor.
        MainActor.assumeIsolated {
            a.lit == b.lit && a.enabled == b.enabled && a.pressed == b.pressed && a.figure == b.figure
        }
    }

    /// Where the body fits, leaving its edge clear of the frame.
    static func bounds(_ size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
    }

    var body: some View {
        let _ = BodyCounter.note("TabletDiagramCore")
        Canvas { context, size in
            let scale = max(context.environment.displayScale, 1)
            func pixels(_ points: CGFloat) -> CGFloat { max((points * scale).rounded(), 1) / scale }
            let d = figure.drawing(.bezel, in: Self.bounds(size), scale: scale)

            // The pen diagram's palette: ink body, passive faces, accent when in use.
            let isDark = context.environment.colorScheme == .dark
            let ink = isDark ? Color.primary.opacity(0.80) : Color.secondary
            let passive = isDark ? Color.secondary : Color.primary.opacity(0.35)
            let accent = Color.windowAccent(controlActiveState)
            let line = pixels(2), gap = pixels(1.5), radius = pixels(8)

            // The pen diagram's anatomy: an outline ring, a cleared gap, then
            // the body filled, with the surface and each control set into it
            // through a cleared slot.
            var outline = Path(roundedRect: d.body, cornerRadius: radius, style: .continuous)
            outline.addPath(Path(roundedRect: d.body.insetBy(dx: line, dy: line), cornerRadius: radius - line,
                                 style: .continuous))
            context.fill(outline, with: .color(ink), style: FillStyle(eoFill: true))

            let inset = line + gap
            var body = Path(roundedRect: d.body.insetBy(dx: inset, dy: inset), cornerRadius: radius - inset,
                            style: .continuous)
            let surface = d.surface.insetBy(dx: gap, dy: gap)
            body.addPath(Path(roundedRect: surface.insetBy(dx: -gap, dy: -gap), cornerRadius: pixels(3) + gap,
                              style: .continuous))
            // A pad's four keys share one slot; adding it twice would refill it.
            var pads: [CGRect] = []
            for shape in d.shapes where shape.kind != .mark && shape.kind != .center {
                if case .wedge = shape.kind {
                    if pads.contains(shape.rect) { continue }
                    pads.append(shape.rect)
                }
                body.addPath(Self.path(shape, outset: gap))
            }
            context.fill(body, with: .color(ink), style: FillStyle(eoFill: true))

            // A pen display's screen is a face in its opening; a tablet's
            // active area stays open.
            if figure.isPenDisplay {
                context.fill(Path(roundedRect: surface, cornerRadius: pixels(3), style: .continuous), with: .color(passive))
            }

            for shape in d.shapes where shape.kind != .mark {
                let face = Self.face(shape, scale: scale, gap: gap)
                let on = shape.target.map { lit & (1 << UInt64($0.bit)) != 0 } ?? false
                context.fill(face, with: .color(on ? accent : passive), style: FillStyle(eoFill: true))
                if let target = shape.target, target == pressed {
                    // Pushed-button feedback, like AppKit's press state.
                    context.fill(face, with: .color(.primary.opacity(0.15)), style: FillStyle(eoFill: true))
                }
            }
        }
    }

    /// A shape's outline grown by `outset`, for the slot cleared around it.
    private static func path(_ shape: TabletFigure.Shape, outset: CGFloat = 0) -> Path {
        let r = shape.rect.insetBy(dx: -outset, dy: -outset)
        switch shape.kind {
        case .ring, .dial, .center, .wedge: return Path(ellipseIn: r)
        case .strip: return Path(roundedRect: r, cornerRadius: min(r.width, r.height) / 2)
        case .key, .cluster, .mark:
            return Path(roundedRect: r, cornerRadius: min(min(r.width, r.height) * 0.25, 3) + outset, style: .continuous)
        }
    }

    /// The face that fills: a ring is an annulus, so its hole stays clear; a
    /// pad's key is a quarter of the ring around its center, cleared apart
    /// from its neighbors by `gap`.
    private static func face(_ shape: TabletFigure.Shape, scale: CGFloat, gap: CGFloat) -> Path {
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
        guard shape.kind == .ring else { return path(shape) }
        let r = shape.rect
        var ring = Path(ellipseIn: r)
        let inset = (r.width * (1 - TabletFigure.ringHole) / 2 * scale).rounded() / scale
        ring.addEllipse(in: r.insetBy(dx: inset, dy: inset))
        return ring
    }
}
