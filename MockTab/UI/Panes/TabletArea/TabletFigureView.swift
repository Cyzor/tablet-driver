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

    var body: some View {
        GeometryReader { geo in
            let surface = figure.drawing(
                .bezel, in: TabletBezelView.bounds(geo.size), scale: displayScale
            ).surface
            ZStack(alignment: .topLeading) {
                TabletBezelView(figure: figure)
                    .equatable()
                    .frame(width: geo.size.width, height: geo.size.height)
                content
                    .frame(
                        width: surface.width + Self.editorInset * 2,
                        height: surface.height + Self.editorInset * 2)
                    .offset(x: surface.minX - Self.editorInset, y: surface.minY - Self.editorInset)
            }
        }
    }
}

// MARK: - Bezel

/// The tablet drawn quietly behind the area editor: its body and controls,
/// and a darker screen for a pen display. Decorative; the editor on top
/// carries the meaning.
struct TabletBezelView: View, Equatable {
    let figure: TabletFigure

    /// Outline weight, rounded to whole pixels: 2 px at 1x, 3 px at 2x.
    private static var lineWidth: CGFloat { 1.5 }
    private static var cornerRadius: CGFloat { 8 }

    /// Where the body fits, leaving its edge clear of the frame.
    static func bounds(_ size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
    }

    var body: some View {
        Canvas { context, size in
            let scale = max(context.environment.displayScale, 1)
            let d = figure.drawing(.bezel, in: Self.bounds(size), scale: scale)
            let dark = context.environment.colorScheme == .dark
            let ink = dark ? Color.white : Color.black
            let display = figure.isPenDisplay
            func pixels(_ points: CGFloat) -> CGFloat { max((points * scale).rounded(), 1) / scale }

            // Light mode needs more weight than dark to read at all.
            let bodyFill = display ? ink.opacity(dark ? 0.10 : 0.17) : ink.opacity(dark ? 0.07 : 0.10)
            // Corners and edges on whole pixels stay smooth at 1x, where a
            // fractional edge steps.
            let line = pixels(Self.lineWidth), radius = pixels(Self.cornerRadius)
            let inner = d.body.insetBy(dx: line, dy: line)
            context.fill(Path(roundedRect: inner, cornerRadius: radius - line), with: .color(bodyFill))
            var outline = Path(roundedRect: d.body, cornerRadius: radius)
            outline.addPath(Path(roundedRect: inner, cornerRadius: radius - line))
            context.fill(outline, with: .color(ink.opacity(dark ? 0.12 : 0.20)), style: FillStyle(eoFill: true))

            let surfaceFill = display
                ? Color.black.opacity(dark ? 0.40 : 0.16)
                : Color.black.opacity(dark ? 0.16 : 0.05)
            context.fill(Path(d.surface), with: .color(surfaceFill))

            let controlFill = ink.opacity(dark ? 0.17 : 0.26)
            for shape in d.shapes {
                let r = shape.rect
                switch shape.kind {
                case .ring:
                    var ring = Path(ellipseIn: r)
                    let inset = pixels(r.width * 0.27)
                    ring.addEllipse(in: r.insetBy(dx: inset, dy: inset))
                    context.fill(ring, with: .color(controlFill), style: FillStyle(eoFill: true))
                case .dial, .center, .wedge:
                    context.fill(Path(ellipseIn: r), with: .color(controlFill))
                case .strip:
                    let corner = min(r.width, r.height) / 2
                    context.fill(Path(roundedRect: r, cornerRadius: corner), with: .color(controlFill))
                case .key, .cluster:
                    let corner = pixels(min(min(r.width, r.height) * 0.25, 3))
                    context.fill(Path(roundedRect: r, cornerRadius: corner), with: .color(controlFill))
                case .mark:
                    break
                }
            }
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
                case .ring, .dial, .center, .wedge:
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
