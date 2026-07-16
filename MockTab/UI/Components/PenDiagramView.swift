// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import TabletKit

// MARK: - PenDiagramView

/// Renders a schematic side-view of the stylus pen, rotated 90° so the tip
/// faces right and the eraser faces left.  Segments illuminate in accent color
/// when the corresponding physical input is active.
///
/// Thin non-equatable wrapper owning the pressed-part state — NOT in the
/// equatable core below — because a Form row swallows @State-driven
/// re-renders inside an EquatableView (same trap as TouchRingModeListView).
struct PenDiagramView: View {
    let liveButtons: LiveButtonState
    /// Called when a pen part is clicked — callers use it to start recording
    /// in that part's binding field (direct manipulation, same pattern as
    /// TouchRingModeListView's diagram). nil leaves the diagram inert.
    var onPartTap: ((Part) -> Void)? = nil
    /// Parts that respond to clicks (and show press feedback). nil = all.
    /// Callers pass the parts whose binding rows are actually shown, so a
    /// missing button or a mouse tool never darkens as if it were pushable.
    var enabledParts: Set<Part>? = nil

    /// The clickable parts, matching the pane's binding rows.
    enum Part {
        case tip, eraser, button1, button2, button3
    }

    /// Part under a mouse press that started on it — darkened like a pushed
    /// AppKit button; dragging off the part cancels, matching button
    /// semantics.
    @State private var pressedPart: Part? = nil

    var body: some View {
        PenDiagramCore(liveButtons: liveButtons, pressedPart: pressedPart)
            .equatable()
            .overlay {
                if onPartTap != nil {
                    GeometryReader { geo in
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let start = part(at: value.startLocation, in: geo.size)
                                    let current = part(at: value.location, in: geo.size)
                                    let held = (start != nil && current == start) ? start : nil
                                    if pressedPart != held { pressedPart = held }
                                }
                                .onEnded { value in
                                    pressedPart = nil
                                    if let start = part(at: value.startLocation, in: geo.size),
                                       part(at: value.location, in: geo.size) == start {
                                        onPartTap?(start)
                                    }
                                })
                    }
                }
            }
            // Sighted-only affordance: press highlights and part-clicks are
            // both redundant with the binding rows, which carry the accessible
            // interface for this section.
            .accessibilityHidden(true)
    }

    /// Maps a click in the rendered diagram back to a pen part by inverting
    /// the body's transform into SVG space, then splitting along the pen's
    /// long axis (0 = eraser end, 344.8 = tip). Ranges come from the path
    /// data in the core, padded a little — the barrel buttons and the round
    /// third button are thin targets at this display size.
    private func part(at point: CGPoint, in size: CGSize) -> Part? {
        let scale = min(size.width / PenDiagramCore.svgH, size.height / PenDiagramCore.svgW)
        guard scale > 0 else { return nil }
        let tx = (size.width + PenDiagramCore.svgH * scale) / 2.0
        let ty = (size.height - PenDiagramCore.svgW * scale) / 2.0
        let svgX = (point.y - ty) / scale
        let svgY = (tx - point.x) / scale
        // Reject clicks off the pen's width (SVG x spans 0…44.6).
        guard svgX > -6, svgX < PenDiagramCore.svgW + 6 else { return nil }
        let hit: Part?
        switch svgY {
        case ..<24: hit = .eraser
        case 226..<258: hit = .button2
        case 258..<292: hit = .button1
        case 292..<310: hit = .button3
        case 315...: hit = .tip
        default: hit = nil
        }
        guard let hit else { return nil }
        if let enabledParts, !enabledParts.contains(hit) { return nil }
        return hit
    }
}

// MARK: - PenDiagramCore

/// The drawn diagram, equatable over its visible state so the ~16 Hz
/// liveButtons/livePoint invalidations streaming through the pane
/// short-circuit when nothing visible has changed.
private struct PenDiagramCore: View, Equatable {
    let liveButtons: LiveButtonState
    let pressedPart: PenDiagramView.Part?

    // SVG viewBox origin and dimensions (tablet-generic-stylus.svg: 0 0 44.6 344.8)
    fileprivate static let svgW = 44.6
    fileprivate static let svgH = 344.8

    // Pre-parse once at app launch (static let is lazy in Swift)
    // swiftlint:disable:next line_length
    private static let outlineD: String = "M22.3,2c5.3,0,9.6,4.3,9.6,9.6v5.5c0,.4,0,.8-.2,1.1,2.8.5,5,2.9,5.1,5.8l1.9,131.7c0,.8-.2,1.6-.7,2.3,1.4.6,2.4,2,2.4,3.6l2.1,134.3c.2,7.9-1.7,15.8-5.6,22.9h0c-.4.8-2.3,3.6-3,4.8-.4.6-1,1.1-1.7,1.3,0,.6,0,1.3-.5,1.8l-3.6,5c-.5.7-1.2,1.4-1.9,1.8.1.3.2.6.1,1l-.3,4.9c-.1,2-1.8,3.5-3.8,3.5s-3.6-1.6-3.8-3.5l-.3-4.9c0-.3,0-.7.1-1-.7-.5-1.4-1.1-1.9-1.8l-3.6-5c-.4-.5-.5-1.2-.5-1.8-.7-.2-1.3-.6-1.7-1.3-.7-1.1-2.6-4-3-4.7h0c-3.9-7.1-5.8-15.1-5.6-23l2.1-134.3c0-1.6,1-3,2.4-3.6-.4-.7-.7-1.5-.7-2.3L7.8,24c0-3,2.3-5.4,5.1-5.9-.1-.3-.2-.7-.2-1.1v-5.5c0-5.3,4.3-9.6,9.6-9.6M22.3,0h0C15.9,0,10.7,5.2,10.7,11.6v5.1c-2.8,1.2-4.8,4-4.9,7.2l-1.9,131.7c0,.5,0,1.1.2,1.6-1.2,1.1-1.9,2.6-1.9,4.3L0,295.8c-.3,8.3,1.8,16.6,5.8,23.9h0c0,.1,0,.2,0,.2.5.8,2.6,4.1,3,4.7.4.6.9,1.1,1.5,1.5.1.6.4,1.1.8,1.6l3.6,5c.4.6.9,1.1,1.4,1.5v.2l.3,4.9c.2,3,2.7,5.4,5.8,5.4s5.6-2.4,5.8-5.4l.3-4.9v-.2c.5-.5,1-1,1.4-1.5l3.6-5c.4-.5.6-1.1.8-1.6.6-.4,1.1-.9,1.5-1.5.6-1,2.6-4,3-4.7h0s0,0,0,0h0c4.1-7.5,6.1-15.8,5.9-24.1l-2.1-134.3c0-1.7-.8-3.2-1.9-4.3.1-.5.2-1,.2-1.6l-1.9-131.7c-.1-3.2-2.1-6-4.9-7.2v-5.1C33.9,5.2,28.7,0,22.3,0h0Z"
    private static let outlinePath = Path(svgData: outlineD)
    // swiftlint:disable:next line_length
    private static let bodyD: String = "M7.9,155.8l1.9-131.7c0-2.2,1.9-4,4.1-4h16.7c2.2,0,4.1,1.8,4.1,4l1.9,131.7c0,1.1-.9,2-2,2H9.9c-1.1,0-2-.9-2-2ZM40.5,295.9c.2,7.6-1.6,15.2-5.3,21.9-.4.7-2.3,3.5-3,4.6-.2.3-.5.5-.8.5H13.2c-.3,0-.7-.2-.8-.5-.7-1.1-2.5-4-3-4.6-3.7-6.7-5.6-14.3-5.3-21.9l2.1-134.3c0-1.1.9-2,2-2h28.3c1.1,0,2,.9,2,2l2.1,134.3ZM16.7,230.6l.7,28.6h9.8l.6-28.6c0-3.1-2.4-5.6-5.5-5.6h-.2c-3.1,0-5.5,2.5-5.5,5.6ZM27.2,261.2h-9.8l-.6,24.1c0,3.1,2.4,5.6,5.5,5.6s5.6-2.5,5.5-5.6l-.6-24.1ZM27.9,300.2c0-3.1-2.5-5.6-5.6-5.6s-5.6,2.5-5.6,5.6,2.5,5.6,5.6,5.6,5.6-2.5,5.6-5.6Z"
    private static let bodyPath = Path(svgData: bodyD)
    private static let eraserPath = Path(
        svgData:
            "M29.9,11.6c0-4.2-3.4-7.6-7.6-7.6s-7.6,3.4-7.6,7.6v5.5c0,.5.4,1,1,1h13.2"
            + "c.5,0,1-.5,1-1,0,0,0-5.5,0-5.5Z")
    private static let tipPath = Path(
        svgData:
            "M22.3,324.6h7.4c.4,0,.6.5.4.8l-3.6,5c-1,1.4-2.6,2.1-4.2,2.1s-3.2-.7-4.2-2.1l-3.6-5"
            + "c-.2-.3,0-.8.4-.8h7.4ZM24.1,339.1l.3-4.9c0-.3-.3-.6-.6-.5-.3,0-.8.1-1.5.1s-1.1,0-1.5-.1"
            + "c-.3,0-.6.2-.6.5l.3,4.9c0,.9.8,1.7,1.8,1.7h0c.9,0,1.7-.7,1.8-1.7Z"
    )
    private static let btn2Path = Path(
        svgData:
            "M19.3,257.2l-.6-26.7c0-.9.3-1.8,1-2.5.7-.7,1.5-1,2.5-1h.2c.9,0,1.8.4,2.5,1"
            + ",.7.7,1,1.6,1,2.5l-.6,26.7h-5.9Z")
    private static let btn1Path = Path(
        svgData:
            "M22.3,289c-.9,0-1.8-.4-2.5-1-.7-.7-1-1.6-1-2.5l.5-22.2h5.9l.5,22.2"
            + "c0,.9-.3,1.8-1,2.5-.7.7-1.5,1-2.5,1Z")
    private static let btn3Path = Path(
        svgData:
            "M22.3,303.9c-2,0-3.6-1.6-3.6-3.6s1.6-3.6,3.6-3.6,3.6,1.6,3.6,3.6-1.6,3.6-3.6,3.6Z")

    var body: some View {
        Canvas { context, size in
            // Scale to fit, preserving aspect ratio.
            // Pen is displayed rotated 90° counterclockwise: tip at left, eraser at right.
            // SVG (x,y) → display (-y·scale + tx,  x·scale + ty)
            let scale = min(size.width / Self.svgH, size.height / Self.svgW)
            let tx = (size.width + Self.svgH * scale) / 2.0
            let ty = (size.height - Self.svgW * scale) / 2.0
            var t = CGAffineTransform(a: 0, b: scale, c: -scale, d: 0, tx: tx, ty: ty)

            func draw(_ path: Path, fill: Color, stroke: Color, pressed: Bool = false) {
                guard let xp = path.cgPath.copy(using: &t) else { return }
                let p = Path(xp)
                context.fill(p, with: .color(fill))
                if pressed {
                    // Pushed-button feedback: primary darkens in light mode
                    // and lightens in dark mode, like AppKit's press state.
                    context.fill(p, with: .color(.primary.opacity(0.15)))
                }
                context.stroke(p, with: .color(stroke), style: StrokeStyle(lineWidth: 0.1))
            }

            let passive = Color.secondary
            let bodyFill = Color.primary.opacity(0.80)
            let strokeDim = Color.secondary
            let accent = Color.accentColor

            draw(Self.outlinePath, fill: bodyFill, stroke: strokeDim)
            draw(Self.bodyPath, fill: bodyFill, stroke: strokeDim)
            draw(
                Self.eraserPath, fill: liveButtons.eraserDown ? accent : passive,
                stroke: liveButtons.eraserDown ? accent : strokeDim,
                pressed: pressedPart == .eraser)
            draw(
                Self.btn2Path, fill: liveButtons.button2Down ? accent : passive,
                stroke: liveButtons.button2Down ? accent : strokeDim,
                pressed: pressedPart == .button2)
            draw(
                Self.btn1Path, fill: liveButtons.button1Down ? accent : passive,
                stroke: liveButtons.button1Down ? accent : strokeDim,
                pressed: pressedPart == .button1)
            draw(
                Self.btn3Path, fill: liveButtons.button3Down ? accent : passive,
                stroke: liveButtons.button3Down ? accent : strokeDim,
                pressed: pressedPart == .button3)
            draw(
                Self.tipPath, fill: liveButtons.tipDown ? accent : passive,
                stroke: liveButtons.tipDown ? accent : strokeDim,
                pressed: pressedPart == .tip)
        }
    }
}
