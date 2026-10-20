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

            TabletDiagramInk.draw(d, isPenDisplay: figure.isPenDisplay,
                                  palette: .diagram(dark: context.environment.colorScheme == .dark,
                                                    accent: .windowAccent(controlActiveState)),
                                  lit: lit, pressed: pressed, scale: scale, in: &context)
        }
    }
}
