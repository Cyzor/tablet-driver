import AppKit
import SwiftUI

/// A drawing surface with `Canvas`'s calls, drawn by Core Graphics.
///
/// SwiftUI's `Canvas` sets up a Metal renderer each time its view appears.
/// Drawing in an AppKit view's `draw(_:)` needs none. Gestures and
/// accessibility attach to a clear SwiftUI layer on top, as they would to a
/// `Canvas`.
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

        enum Shading {
            case color(Color)

            fileprivate var cgColor: CGColor {
                switch self {
                case .color(let color): NSColor(color).cgColor
                }
            }
        }

        func fill(_ path: Path, with shading: Shading) {
            cg.addPath(path.cgPath)
            cg.setFillColor(shading.cgColor)
            cg.fillPath()
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

        override func draw(_ dirtyRect: NSRect) {
            guard let cg = NSGraphicsContext.current?.cgContext, let draw else { return }
            var context = CGCanvas.Context(cg: cg)
            draw(&context, bounds.size)
        }
    }
}
