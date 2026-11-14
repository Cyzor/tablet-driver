// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// A drawing surface with `Canvas`'s calls, drawn by Core Graphics.
///
/// SwiftUI's `Canvas` sets up a Metal renderer each time its view appears.
/// Drawing in an AppKit view's `draw(_:)` needs none. Gestures and
/// accessibility attach to a clear SwiftUI layer on top, as they would to a
/// `Canvas`.
///
/// It redraws when the enclosing body runs again. State read only inside
/// the drawing closure isn't tracked, so read it in the body too.
struct CGCanvas: View {
    let draw: (inout Context, CGSize) -> Void

    init(_ draw: @escaping (inout Context, CGSize) -> Void) {
        self.draw = draw
    }

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .background(Surface(draw: draw).allowsHitTesting(false))
    }

    /// The subset of `GraphicsContext` the app's drawings use.
    struct Context {
        let cg: CGContext
        var environment: Environment

        struct Environment {
            var colorScheme: ColorScheme
            var displayScale: CGFloat
        }

        /// Applies to what's drawn next, as in `GraphicsContext`.
        var blendMode: GraphicsContext.BlendMode = .normal {
            didSet { cg.setBlendMode(Self.cgBlendMode(blendMode)) }
        }

        private static func cgBlendMode(_ mode: GraphicsContext.BlendMode) -> CGBlendMode {
            switch mode {
            case .destinationOut: .destinationOut
            case .sourceAtop: .sourceAtop
            case .destinationOver: .destinationOver
            case .multiply: .multiply
            case .clear: .clear
            case .copy: .copy
            default: .normal
            }
        }

        enum Shading {
            case color(Color)

            fileprivate var cgColor: CGColor {
                switch self {
                case .color(let color): NSColor(color).cgColor
                }
            }
        }

        func fill(_ path: Path, with shading: Shading, style: FillStyle = FillStyle()) {
            cg.addPath(path.cgPath)
            cg.setFillColor(shading.cgColor)
            cg.fillPath(using: style.isEOFilled ? .evenOdd : .winding)
        }

        /// Draws into a layer that composites as one, so blend modes inside
        /// it act on the layer alone.
        func drawLayer(_ content: (inout Context) -> Void) {
            cg.saveGState()
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            var layer = Context(cg: cg, environment: environment)
            content(&layer)
            cg.endTransparencyLayer()
            cg.restoreGState()
        }

        func stroke(_ path: Path, with shading: Shading, lineWidth: CGFloat = 1) {
            stroke(path, with: shading, style: StrokeStyle(lineWidth: lineWidth))
        }

        func stroke(_ path: Path, with shading: Shading, style: StrokeStyle) {
            cg.saveGState()
            cg.addPath(path.cgPath)
            cg.setStrokeColor(shading.cgColor)
            cg.setLineWidth(style.lineWidth)
            cg.setLineCap(style.lineCap)
            cg.setLineJoin(style.lineJoin)
            cg.setMiterLimit(style.miterLimit)
            if !style.dash.isEmpty { cg.setLineDash(phase: style.dashPhase, lengths: style.dash) }
            cg.strokePath()
            cg.restoreGState()
        }
    }

    private struct Surface: NSViewRepresentable {
        let draw: (inout CGCanvas.Context, CGSize) -> Void

        func makeNSView(context: Self.Context) -> DrawingView { DrawingView() }

        func updateNSView(_ view: DrawingView, context: Self.Context) {
            view.draw = draw
            view.needsDisplay = true
        }
    }

    final class DrawingView: NSView {
        var draw: ((inout CGCanvas.Context, CGSize) -> Void)?

        override var isFlipped: Bool { true }

        // A switch between light and dark, or to a screen of another
        // scale, redraws.
        override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
        override func viewDidChangeBackingProperties() { needsDisplay = true }

        override func draw(_ dirtyRect: NSRect) {
            guard let cg = NSGraphicsContext.current?.cgContext, let draw else { return }
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            var context = CGCanvas.Context(
                cg: cg,
                environment: .init(colorScheme: dark ? .dark : .light,
                                   displayScale: window?.backingScaleFactor ?? 2))
            draw(&context, bounds.size)
        }
    }
}
