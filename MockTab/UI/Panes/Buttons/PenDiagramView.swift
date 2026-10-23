// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import TabletKit

// MARK: - PenDiagramView

/// Renders a schematic side view of the tool, tip at left and eraser at
/// right, drawn from a `PenRecipe` so its barrel, buttons, and eraser match
/// the tool. Parts illuminate in accent color when the corresponding
/// physical input is active.
///
/// Thin non-equatable wrapper owning the pressed-part state — not in the
/// equatable core below — because a Form row swallows @State-driven
/// re-renders inside an EquatableView (same trap as TouchRingModeListView).
struct PenDiagramView: View {
    let liveButtons: LiveButtonState
    var recipe: PenRecipe = .classic
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
    @Environment(\.liveInputMuffled) private var muffled

    var body: some View {
        PenDiagramCore(recipe: recipe, down: PenDiagramCore.down(liveButtons), pressedPart: pressedPart, muffled: muffled)
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

    /// Maps a click back to a pen part through the drawing's transform.
    private func part(at point: CGPoint, in size: CGSize) -> Part? {
        let t = PenDiagramCore.transform(for: size)
        guard let hit = recipe.part(at: point.applying(t.inverted())).map(Part.init) else { return nil }
        if let enabledParts, !enabledParts.contains(hit) { return nil }
        return hit
    }
}

extension PenDiagramView.Part {
    init(_ part: PenRecipe.Part) {
        switch part {
        case .tip: self = .tip
        case .eraser: self = .eraser
        case .button(1): self = .button1
        case .button(2): self = .button2
        default: self = .button3
        }
    }
}

// MARK: - PenDiagramCore

/// The drawn diagram, equatable over its visible state so the ~16 Hz
/// liveButtons/livePoint invalidations streaming through the pane
/// short-circuit when nothing visible has changed. It sees only the pen's
/// own parts, so ExpressKey and ring traffic never redraws it.
private struct PenDiagramCore: View, Equatable {
    let recipe: PenRecipe
    /// One bit per part that's down; see `bit(_:)`.
    let down: UInt8
    let pressedPart: PenDiagramView.Part?
    /// Outline-only highlights; see `EnvironmentValues.liveInputMuffled`.
    let muffled: Bool

    @Environment(\.controlActiveState) private var controlActiveState

    // Environment changes refresh the view on their own, so equality
    // compares only the drawn state.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        // SwiftUI compares views on the main actor.
        MainActor.assumeIsolated {
            a.recipe == b.recipe && a.down == b.down && a.pressedPart == b.pressedPart && a.muffled == b.muffled
        }
    }

    static func bit(_ part: PenDiagramView.Part) -> UInt8 {
        switch part {
        case .tip: return 1 << 0
        case .eraser: return 1 << 1
        case .button1: return 1 << 2
        case .button2: return 1 << 3
        case .button3: return 1 << 4
        }
    }

    static func down(_ live: LiveButtonState) -> UInt8 {
        (live.tipDown ? bit(.tip) : 0) | (live.eraserDown ? bit(.eraser) : 0)
            | (live.button1Down ? bit(.button1) : 0) | (live.button2Down ? bit(.button2) : 0)
            | (live.button3Down ? bit(.button3) : 0)
    }

    /// Recipe space to view space: scaled to fit, turned so the tip faces
    /// left. Every recipe shares one frame, so pens compare in size.
    static func transform(for size: CGSize) -> CGAffineTransform {
        let f = PenRecipe.frame
        let scale = min(size.width / f.height, size.height / f.width)
        // (x, y) → (−y·scale + tx, x·scale + ty)
        return CGAffineTransform(a: 0, b: scale, c: -scale, d: 0,
                                 tx: size.width / 2 + f.midY * scale, ty: size.height / 2 - f.midX * scale)
    }

    var body: some View {
        let _ = BodyCounter.note("PenDiagramCore")
        Canvas { context, size in
            let t = Self.transform(for: size)
            func view(_ path: CGPath) -> Path { Path(path).applying(t) }

            // Light mode swaps the fills: a darker body under lighter
            // buttons keeps the highlighted part leading.
            let isDark = context.environment.colorScheme == .dark
            let passive = isDark ? Color.secondary : Color.primary.opacity(0.35)
            let bodyFill = isDark ? Color.primary.opacity(0.80) : Color.secondary
            let accent = Color.windowAccent(controlActiveState)

            context.fill(view(recipe.outline), with: .color(bodyFill))
            context.fill(view(recipe.bodyFill), with: .color(bodyFill))
            for (part, path) in recipe.parts {
                let p = view(path)
                let shown = PenDiagramView.Part(part)
                let down = self.down & Self.bit(shown) != 0
                context.fill(p, with: .color(down && !muffled ? accent : passive))
                if pressedPart == shown {
                    // Pushed-button feedback: primary darkens in light mode
                    // and lightens in dark mode, like AppKit's press state.
                    context.fill(p, with: .color(.primary.opacity(0.15)))
                }
                if down && muffled {
                    context.stroke(p, with: .color(.primary), lineWidth: 1)
                }
            }
        }
    }
}

// MARK: - Recipe for a tool

extension PenRecipe {
    /// The barrel for a tool, with its button count and eraser. Grip and Art
    /// Pens are classic, Pro Pen 2 and 3 slim (the Pro Pen 2 with a rocker),
    /// Art Pen 2 and the Xencelabs 3 Button Pen their own, and the rest
    /// straight; an airbrush is a fatter straight barrel for now.
    init(tool: ToolSpec?, buttonCount: Int, hasEraser: Bool? = nil) {
        let name = tool?.name ?? ""
        var recipe: PenRecipe
        switch tool?.toolType {
        // A mouse keeps the pen it has always shown, until it has a drawing of its own.
        case .mouse: recipe = .classic
        case .airbrush: recipe = .straight.girth(1.3)
        case .inkingPen: recipe = .straight.girth(0.85)
        case .artPen: recipe = name == "Art Pen 2" ? .artPen2 : .classic
        default:
            if tool == nil || name.contains("Grip Pen") || name == "Pro Pen" { recipe = .classic }
            else if name.hasPrefix("Xencelabs 3") { recipe = .xencelabs }
            else if name.hasPrefix("Pro Pen 2") { recipe = .slim; recipe.buttons = .rocker(dot: false) }
            else if name.hasPrefix("Pro Pen") { recipe = .slim }
            else { recipe = .straight }
        }
        recipe.eraser = hasEraser ?? tool?.hasEraserVariant ?? true
        self = recipe.buttons(buttonCount)
    }
}

// MARK: - MouseDiagramView

/// A mouse seen from above, upright, drawn in the pen diagram's style.
/// Left, right, and middle always show; buttons 4 and 5 sit in the middle
/// column on mice that have them. The middle part lights for the middle
/// button and while the wheel turns.
struct MouseDiagramView: View {
    let liveButtons: LiveButtonState
    var wheelTurning = false
    /// Whether buttons 4 and 5 are drawn.
    var hasSideButtons = false
    var onPartTap: ((Part) -> Void)? = nil

    enum Part: CaseIterable {
        case left, right, middle, button4, button5
    }

    @State private var pressedPart: Part? = nil
    @Environment(\.liveInputMuffled) private var muffled

    var body: some View {
        MouseDiagramCore(down: down, hasSideButtons: hasSideButtons, pressedPart: pressedPart, muffled: muffled)
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
            // Redundant with the binding rows, as on the pen.
            .accessibilityHidden(true)
    }

    private var down: Set<Part> {
        var parts: Set<Part> = []
        if liveButtons.button1Down { parts.insert(.left) }
        if liveButtons.button2Down { parts.insert(.right) }
        if liveButtons.button3Down || wheelTurning { parts.insert(.middle) }
        if liveButtons.button4Down { parts.insert(.button4) }
        if liveButtons.button5Down { parts.insert(.button5) }
        return parts
    }

    private func part(at point: CGPoint, in size: CGSize) -> Part? {
        let p = point.applying(MouseDiagramCore.transform(for: size).inverted())
        return MouseDiagramCore.parts(hasSideButtons: hasSideButtons).first { $0.path.contains(p) }?.part
    }
}

private struct MouseDiagramCore: View, Equatable {
    let down: Set<MouseDiagramView.Part>
    let hasSideButtons: Bool
    let pressedPart: MouseDiagramView.Part?
    let muffled: Bool

    @Environment(\.controlActiveState) private var controlActiveState

    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated {
            a.down == b.down && a.hasSideButtons == b.hasSideButtons && a.pressedPart == b.pressedPart
                && a.muffled == b.muffled
        }
    }

    /// The drawing's own box, upright.
    static let frame = CGSize(width: 112.27, height: 167.81)

    /// Drawing space to view space: upright, scaled to fit, and centered.
    static func transform(for size: CGSize) -> CGAffineTransform {
        let scale = min(size.width / frame.width, size.height / frame.height)
        return CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: (size.width - frame.width * scale) / 2,
                                             y: (size.height - frame.height * scale) / 2))
    }

    /// The outline, its inner edge, and the body.
    static let shell: (outer: Path, body: Path) = {
        var outer = Path()
        outer.move(to: CGPoint(x: 56.74, y: 157.34))
        outer.addCurve(to: CGPoint(x: 14.74, y: 115.34), control1: CGPoint(x: 33.58, y: 157.34), control2: CGPoint(x: 14.74, y: 138.5))
        outer.addLine(to: CGPoint(x: 14.74, y: 48.66))
        outer.addCurve(to: CGPoint(x: 48.74, y: 14.66), control1: CGPoint(x: 14.74, y: 29.91), control2: CGPoint(x: 29.99, y: 14.66))
        outer.addLine(to: CGPoint(x: 64.74, y: 14.66))
        outer.addCurve(to: CGPoint(x: 98.74, y: 48.66), control1: CGPoint(x: 83.49, y: 14.66), control2: CGPoint(x: 98.74, y: 29.91))
        outer.addLine(to: CGPoint(x: 98.74, y: 115.33))
        outer.addCurve(to: CGPoint(x: 56.74, y: 157.33), control1: CGPoint(x: 98.74, y: 138.49), control2: CGPoint(x: 79.9, y: 157.33))
        outer.closeSubpath()

        var body = Path()
        body.move(to: CGPoint(x: 64.74, y: 16.66))
        body.addLine(to: CGPoint(x: 48.74, y: 16.66))
        body.addCurve(to: CGPoint(x: 16.74, y: 48.66), control1: CGPoint(x: 31.07, y: 16.66), control2: CGPoint(x: 16.74, y: 30.99))
        body.addLine(to: CGPoint(x: 16.74, y: 115.33))
        body.addCurve(to: CGPoint(x: 56.74, y: 155.33), control1: CGPoint(x: 16.74, y: 137.42), control2: CGPoint(x: 34.65, y: 155.33))
        body.addCurve(to: CGPoint(x: 96.74, y: 115.33), control1: CGPoint(x: 78.83, y: 155.33), control2: CGPoint(x: 96.74, y: 137.42))
        body.addLine(to: CGPoint(x: 96.74, y: 48.66))
        body.addCurve(to: CGPoint(x: 64.74, y: 16.66), control1: CGPoint(x: 96.74, y: 30.99), control2: CGPoint(x: 82.41, y: 16.66))
        body.closeSubpath()
        return (outer, body)
    }()

    /// The buttons, in drawing space. Without side buttons the middle
    /// column keeps only its middle key.
    static func parts(hasSideButtons: Bool) -> [(part: MouseDiagramView.Part, path: Path)] {
        var left = Path()
        left.move(to: CGPoint(x: 20.74, y: 88.01))
        left.addCurve(to: CGPoint(x: 18.74, y: 86.01), control1: CGPoint(x: 19.64, y: 88.01), control2: CGPoint(x: 18.74, y: 87.11))
        left.addLine(to: CGPoint(x: 18.74, y: 48.66))
        left.addCurve(to: CGPoint(x: 48.07, y: 18.67), control1: CGPoint(x: 18.74, y: 32.34), control2: CGPoint(x: 31.84, y: 19.02))
        left.addLine(to: CGPoint(x: 48.07, y: 68.93))
        left.addCurve(to: CGPoint(x: 53.41, y: 74.27), control1: CGPoint(x: 48.07, y: 71.87), control2: CGPoint(x: 50.47, y: 74.27))
        left.addCurve(to: CGPoint(x: 54.75, y: 75.61), control1: CGPoint(x: 54.15, y: 74.27), control2: CGPoint(x: 54.75, y: 74.87))
        left.addLine(to: CGPoint(x: 54.75, y: 86))
        left.addCurve(to: CGPoint(x: 52.75, y: 88), control1: CGPoint(x: 54.75, y: 87.1), control2: CGPoint(x: 53.85, y: 88))
        left.closeSubpath()

        var right = Path()
        right.move(to: CGPoint(x: 60.72, y: 88.01))
        right.addCurve(to: CGPoint(x: 58.72, y: 86.01), control1: CGPoint(x: 59.62, y: 88.01), control2: CGPoint(x: 58.72, y: 87.11))
        right.addLine(to: CGPoint(x: 58.72, y: 75.62))
        right.addCurve(to: CGPoint(x: 60.06, y: 74.28), control1: CGPoint(x: 58.72, y: 74.88), control2: CGPoint(x: 59.32, y: 74.28))
        right.addCurve(to: CGPoint(x: 65.4, y: 68.94), control1: CGPoint(x: 63.01, y: 74.28), control2: CGPoint(x: 65.4, y: 71.88))
        right.addLine(to: CGPoint(x: 65.4, y: 18.67))
        right.addCurve(to: CGPoint(x: 94.73, y: 48.66), control1: CGPoint(x: 81.64, y: 19.03), control2: CGPoint(x: 94.73, y: 32.34))
        right.addLine(to: CGPoint(x: 94.73, y: 86.01))
        right.addCurve(to: CGPoint(x: 92.73, y: 88.01), control1: CGPoint(x: 94.73, y: 87.11), control2: CGPoint(x: 93.83, y: 88.01))
        right.closeSubpath()

        func key(_ y: Double) -> Path {
            Path(roundedRect: CGRect(x: 52.07, y: y, width: 9.33, height: 14.54), cornerRadius: 1)
        }
        var parts: [(MouseDiagramView.Part, Path)] = [(.left, left), (.right, right), (.middle, key(37.2))]
        if hasSideButtons { parts += [(.button4, key(18.66)), (.button5, key(55.74))] }
        return parts
    }

    var body: some View {
        let _ = BodyCounter.note("MouseDiagramCore")
        Canvas { context, size in
            let t = Self.transform(for: size)
            // The pen diagram's fills, so the two read as one family.
            let isDark = context.environment.colorScheme == .dark
            let passive = isDark ? Color.secondary : Color.primary.opacity(0.35)
            let bodyFill = isDark ? Color.primary.opacity(0.80) : Color.secondary
            let accent = Color.windowAccent(controlActiveState)

            let parts = Self.parts(hasSideButtons: hasSideButtons)
            // A thin outline ring, a cleared gap, then the body with each
            // button cut out of it, as the pen's are.
            context.drawLayer { layer in
                let outer = Self.shell.outer.applying(t)
                layer.stroke(outer, with: .color(bodyFill), lineWidth: 4 * hypot(t.a, t.b))
                layer.blendMode = .destinationOut
                layer.fill(outer, with: .color(.black))
                layer.blendMode = .normal
                layer.fill(Self.shell.body.applying(t), with: .color(bodyFill))
                layer.blendMode = .destinationOut
                for (_, path) in parts { layer.fill(path.applying(t), with: .color(.black)) }
            }
            for (part, path) in parts {
                let p = path.applying(t)
                let isDown = down.contains(part)
                context.fill(p, with: .color(isDown && !muffled ? accent : passive))
                if pressedPart == part { context.fill(p, with: .color(.primary.opacity(0.15))) }
                if isDown && muffled { context.stroke(p, with: .color(.primary), lineWidth: 1) }
            }
        }
    }
}
