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
/// Thin non-equatable wrapper owning the pressed-part state — NOT in the
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
        PenDiagramCore(recipe: recipe, liveButtons: liveButtons, pressedPart: pressedPart, muffled: muffled)
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
/// short-circuit when nothing visible has changed.
private struct PenDiagramCore: View, Equatable {
    let recipe: PenRecipe
    let liveButtons: LiveButtonState
    let pressedPart: PenDiagramView.Part?
    /// Outline-only highlights; see `EnvironmentValues.liveInputMuffled`.
    let muffled: Bool

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
        Canvas { context, size in
            let t = Self.transform(for: size)
            func view(_ path: CGPath) -> Path { Path(path).applying(t) }

            // Light mode swaps the fills: a darker body under lighter
            // buttons keeps the highlighted part leading.
            let isDark = context.environment.colorScheme == .dark
            let passive = isDark ? Color.secondary : Color.primary.opacity(0.35)
            let bodyFill = isDark ? Color.primary.opacity(0.80) : Color.secondary
            let accent = Color.accentColor

            context.fill(view(recipe.outline), with: .color(bodyFill))
            context.fill(view(recipe.bodyFill), with: .color(bodyFill))
            for (part, path) in recipe.parts {
                let p = view(path)
                let shown = PenDiagramView.Part(part)
                let down = isDown(shown)
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

    private func isDown(_ part: PenDiagramView.Part) -> Bool {
        switch part {
        case .tip: return liveButtons.tipDown
        case .eraser: return liveButtons.eraserDown
        case .button1: return liveButtons.button1Down
        case .button2: return liveButtons.button2Down
        case .button3: return liveButtons.button3Down
        }
    }
}

// MARK: - Recipe for a tool

extension PenRecipe {
    /// The barrel for a tool, with its button count and eraser. Grip and Art
    /// Pens are classic, Pro Pen 2 and 3 slim, the Xencelabs 3 Button Pen
    /// its own, and the rest straight; an airbrush is a fatter straight
    /// barrel for now.
    init(tool: ToolSpec?, buttonCount: Int) {
        let name = tool?.name ?? ""
        var recipe: PenRecipe
        switch tool?.toolType {
        // A mouse keeps the pen it has always shown, until it has a drawing of its own.
        case .mouse: recipe = .classic
        case .airbrush: recipe = .straight.girth(1.3)
        case .inkingPen: recipe = .straight.girth(0.85)
        case .artPen: recipe = .classic
        default:
            if tool == nil || name.contains("Grip Pen") || name == "Pro Pen" { recipe = .classic }
            else if name.hasPrefix("Xencelabs 3") { recipe = .xencelabs }
            else if name.hasPrefix("Pro Pen") { recipe = .slim }
            else { recipe = .straight }
        }
        recipe.eraser = tool?.hasEraserVariant ?? true
        self = recipe.buttons(buttonCount)
    }
}
