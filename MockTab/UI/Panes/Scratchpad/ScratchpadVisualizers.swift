// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later


import SwiftUI
import AppKit
import Combine
import TabletKit

// MARK: - Touch Visualizer wrapper

/// Isolation boundary for the live-touch stream: observes the publisher so
/// each ~30 Hz contact frame re-evaluates only this wrapper (and redraws the
/// Equatable-gated canvas when contacts actually changed) instead of the
/// whole Scratchpad pane.
struct TouchVisualizer: View {
    @ObservedObject var liveTouch: LiveTouchPublisher
    let maxContacts: Int

    var body: some View {
        TouchContactsCanvas(contacts: liveTouch.contacts, maxContacts: maxContacts)
            .accessibilityElement()
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(Text("Touch contacts", comment: "VoiceOver label for the Scratchpad touch visualizer"))
            .accessibilityValue(Text(liveTouch.contacts.count, format: .number))
    }
}

// MARK: - Tilt Visualizer Canvas

/// Top-down disc that shows the active pen's live tilt as a dot offset from
/// center. Concentric reference rings give a magnitude scale; values are the
/// raw `tiltX`/`tiltY` from `TabletPoint` (each clamped to ±1). When the pen
/// leaves proximity the dot snaps back to center so the disc does not flicker
/// each time the user rolls the pen off the surface.
///
/// Performance: `livePoint` is not `@Published` (see `DeviceContext.livePoint`),
/// so this wrapper subscribes to `livePointPublisher` directly via `onReceive`
/// instead of relying on tabletManager's general objectWillChange cascade —
/// that keeps this ~16 Hz-when-frontmost redraw scoped to just this small
/// disc instead of also firing on every other view that merely observes
/// `tabletManager`. The inner `TiltDisc` is `Equatable` and keyed on a
/// quantized (tiltX, tiltY) pair, so SwiftUI skips body evaluation and the
/// Canvas redraw whenever tilt rounds to the same display position — sensor
/// noise and unrelated X/Y movement are filtered out for free.
struct TiltVisualizerCanvas: View {
    @ObservedObject var tabletManager: TabletManager
    /// Incremented by the `livePointPublisher` subscription below. It MUST be
    /// read in `body` (see the `let _` line) to register as a dependency —
    /// a `@State` write to a value the body never reads does not invalidate
    /// the view, so without the read the disc only refreshed when some *other*
    /// state (tip pressure) re-ran the parent body, i.e. only on fresh
    /// surface contact, never during pure hover. Matches InfoView's pattern.
    @State private var livePointTick = 0

    var body: some View {
        let _ = BodyCounter.note("TiltCanvas")
        // Establishes livePointTick as a read dependency of this body so each
        // livePoint publish forces a re-evaluation.
        let _ = livePointTick
        // Quantize to 0.01 (sub-pixel on a 100-pt disc) so micro-jitter and
        // changes that wouldn't move the dot don't trigger redraws.
        let raw = tabletManager.activeContext?.livePoint
        let inProximity = raw?.inProximity == true
        let tx: Double = inProximity ? quantize(raw!.tiltX) : 0.0
        let ty: Double = inProximity ? quantize(raw!.tiltY) : 0.0
        return TiltDisc(tiltX: tx, tiltY: ty).equatable()
            .accessibilityElement()
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(Text("Tilt"))
            .accessibilityValue(Text(
                "X \(tx.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))), Y \(ty.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always())))",
                comment: "VoiceOver value of the tilt visualizer, matching the Live Input readout"))
            .onReceive(
                tabletManager.activeContext?.livePointPublisher.eraseToAnyPublisher()
                    ?? Empty().eraseToAnyPublisher()
            ) { _ in livePointTick &+= 1 }
    }

    private func quantize(_ value: Double) -> Double {
        (max(-1.0, min(1.0, value)) * 100).rounded() / 100
    }
}

private struct TiltDisc: View, Equatable {
    let tiltX: Double
    let tiltY: Double

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let radius = min(size.width, size.height) * 0.5 - 6
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            Canvas { ctx, _ in
                drawReference(ctx: ctx, center: center, radius: radius)
                drawDot(ctx: ctx, center: center, radius: radius)
            }
        }
    }

    private func drawReference(ctx: GraphicsContext, center: CGPoint, radius: CGFloat) {
        var cross = Path()
        cross.move(to: CGPoint(x: center.x - radius, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - radius))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        ctx.stroke(cross, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)

        for fraction in [0.25, 0.5, 0.75] {
            let r = radius * fraction
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            ctx.stroke(
                Path(ellipseIn: rect),
                with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
        }

        let outer = CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2)
        ctx.stroke(Path(ellipseIn: outer), with: .color(.secondary.opacity(0.45)), lineWidth: 1)
    }

    private func drawDot(ctx: GraphicsContext, center: CGPoint, radius: CGFloat) {
        var tx = tiltX
        var ty = tiltY
        let magnitude = sqrt(tx * tx + ty * ty)
        if magnitude > 1.0 {
            tx /= magnitude
            ty /= magnitude
        }
        let dotX = center.x + radius * tx
        let dotY = center.y + radius * ty

        let r: CGFloat = 4
        let rect = CGRect(x: dotX - r, y: dotY - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: rect), with: .color(.accentColor))
        ctx.stroke(
            Path(ellipseIn: rect),
            with: .color(.white.opacity(0.9)), lineWidth: 1)
    }
}

// MARK: - Touch contacts visualizer

/// Top-down rectangle showing normalised finger-contact positions as numbered
/// dots. The tablet's touch surface maps to the full canvas area.
/// Contacts fade out over ~0.3 s after they lift (lift = empty contacts array).
private struct TouchContactsCanvas: View, Equatable {
    let contacts: [TouchContact]
    let maxContacts: Int

    nonisolated static func == (lhs: TouchContactsCanvas, rhs: TouchContactsCanvas) -> Bool {
        // SwiftUI compares views on the main actor.
        MainActor.assumeIsolated {
            lhs.contacts == rhs.contacts && lhs.maxContacts == rhs.maxContacts
        }
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                drawBorder(ctx: ctx, size: size)
                drawContacts(ctx: ctx, size: size)
            }
        }
    }

    private func drawBorder(ctx: GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        ctx.stroke(
            Path(roundedRect: rect, cornerRadius: 3),
            with: .color(.secondary.opacity(0.3)), lineWidth: 1)
    }

    private func drawContacts(ctx: GraphicsContext, size: CGSize) {
        guard !contacts.isEmpty else { return }

        // Determine the normalised coordinate range from the first contact.
        // TouchContact uses raw tablet units; we don't have access to maxX/maxY
        // here, so normalise each contact against the bounding box of all
        // contacts with a small guard against zero-range.
        let xs = contacts.map { Double($0.x) }
        let ys = contacts.map { Double($0.y) }

        // Normalise within [0,1] using whatever range the contacts span.
        // Falls back to centring a single contact on the canvas.
        func norm(_ val: Double, _ vals: [Double]) -> Double {
            let lo = vals.min() ?? 0
            let hi = vals.max() ?? 1
            guard hi > lo else { return 0.5 }
            return (val - lo) / (hi - lo)
        }

        let r: CGFloat = 6
        let pad: CGFloat = r + 4

        for (i, contact) in contacts.enumerated() {
            let nx = contacts.count == 1 ? 0.5 : norm(Double(contact.x), xs)
            let ny = contacts.count == 1 ? 0.5 : norm(Double(contact.y), ys)

            let cx = pad + nx * (size.width  - 2 * pad)
            let cy = pad + ny * (size.height - 2 * pad)
            let dot = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)

            ctx.fill(Path(ellipseIn: dot), with: .color(.accentColor.opacity(0.8)))
            ctx.stroke(Path(ellipseIn: dot), with: .color(.white.opacity(0.9)), lineWidth: 1)

            // Label: contact index
            ctx.draw(
                Text("\(i + 1)")
                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white),
                at: CGPoint(x: cx, y: cy),
                anchor: .center)
        }
    }
}
