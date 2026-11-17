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
/// whole Scratchpad pane. It shows only its own tablet's fingers, and only
/// in the front window; others hold still apart from clearing on a lift.
struct TouchVisualizer: View {
    let liveTouch: LiveTouchPublisher
    /// The window's tablet; nil accepts any.
    let source: ObjectIdentifier?
    let maxContacts: Int
    let orientation: TabletOrientation
    @State private var contacts: [TouchContact] = []
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        TouchContactsCanvas(contacts: contacts, maxContacts: maxContacts, orientation: orientation)
            .accessibilityElement()
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(Text("Touch contacts", comment: "VoiceOver label for the Scratchpad touch visualizer"))
            .accessibilityValue(Text(contacts.count, format: .number))
            .onReceive(liveTouch.$contacts) { new in
                guard new.isEmpty
                    || (controlActiveState == .key && (source == nil || liveTouch.source == source))
                else { return }
                contacts = new
            }
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
    let orientation: TabletOrientation
    /// Incremented by the `livePointPublisher` subscription below. It must be
    /// read in `body` (see the `let _` line) to register as a dependency —
    /// a `@State` write to a value the body never reads does not invalidate
    /// the view, so without the read the disc only refreshed when some *other*
    /// state (tip pressure) re-ran the parent body, i.e. only on fresh
    /// surface contact, never during pure hover. Matches InfoView's pattern.
    @State private var livePointTick = 0
    /// Only the front window follows the pen; others recenter when it leaves.
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        let _ = BodyCounter.note("TiltCanvas")
        // Establishes livePointTick as a read dependency of this body so each
        // livePoint publish forces a re-evaluation.
        let _ = livePointTick
        // Quantize to 0.01 (sub-pixel on a 100-pt disc) so micro-jitter and
        // changes that wouldn't move the dot don't trigger redraws.
        let raw = tabletManager.activeContext?.livePoint
        let inProximity = raw?.inProximity == true
        let turned = inProximity
            ? DisplayMapper.orientTilt(x: raw!.tiltX, y: raw!.tiltY, orientation: orientation)
            : (x: 0.0, y: 0.0)
        let tx = quantize(turned.x)
        let ty = quantize(turned.y)
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
            ) { point in
                guard controlActiveState == .key || point?.inProximity != true else { return }
                livePointTick &+= 1
            }
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

/// Where to draw each contact, as fractions of the contacts' own bounding
/// box, turned to match the tablet on the desk. A contact carries raw units
/// with no axis maxima, so this shows how the fingers sit relative to each
/// other; one finger alone sits in the middle.
func touchContactLayout(_ contacts: [TouchContact], orientation: TabletOrientation) -> [CGPoint] {
    // The bounding-box normalization cancels the axis offsets, so zero
    // maxima suffice.
    let points = contacts.map {
        DisplayMapper.orient(x: Double($0.x), y: Double($0.y), maxX: 0, maxY: 0, orientation: orientation)
    }
    func fraction(_ value: Double, in values: [Double]) -> Double {
        guard let lo = values.min(), let hi = values.max(), hi > lo else { return 0.5 }
        return (value - lo) / (hi - lo)
    }
    let xs = points.map(\.ox), ys = points.map(\.oy)
    return points.map { CGPoint(x: fraction($0.ox, in: xs), y: fraction($0.oy, in: ys)) }
}

/// Top-down rectangle showing normalized finger-contact positions as numbered
/// dots, turned to match the tablet on the desk. The tablet's touch surface
/// maps to the full canvas area.
/// Contacts fade out over ~0.3 s after they lift (lift = empty contacts array).
private struct TouchContactsCanvas: View, Equatable {
    let contacts: [TouchContact]
    let maxContacts: Int
    let orientation: TabletOrientation

    nonisolated static func == (lhs: TouchContactsCanvas, rhs: TouchContactsCanvas) -> Bool {
        // SwiftUI compares views on the main actor.
        MainActor.assumeIsolated {
            lhs.contacts == rhs.contacts && lhs.maxContacts == rhs.maxContacts
                && lhs.orientation == rhs.orientation
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

        let layout = touchContactLayout(contacts, orientation: orientation)

        let r: CGFloat = 6
        let pad: CGFloat = r + 4

        for (i, spot) in layout.enumerated() {
            let cx = pad + spot.x * (size.width  - 2 * pad)
            let cy = pad + spot.y * (size.height - 2 * pad)
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
