// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import ServiceManagement
import SwiftUI
import TabletKit

// MARK: - LiveInputSectionContent
//
// Owns the livePointTick polling dependency itself rather than InfoView
// hosting it. `livePoint` publishes on every HID report; scoping the tick
// to just this subtree keeps the rest of InfoView (including the
// diagnostics text, whose in-progress selection a stylus report would
// otherwise blow away on every redraw) stable while the pen moves.
struct LiveInputSectionContent: View {
    let deviceContext: DeviceContext?
    let productID: Int?
    let orientation: TabletOrientation
    /// Not observed here: touch frames redraw only the touch gauge.
    let liveTouch: LiveTouchPublisher
    /// An ExpressKey Remote or Quick Keys puck that goes with this tablet,
    /// shown as part of it, as in the Buttons pane.
    var companion: DeviceContext?

    /// Unused directly — its writes force a body re-evaluation when a
    /// button changes.
    @State private var livePointTick = 0
    /// Draws the gauges' marks straight onto their layers as points
    /// arrive, so pen motion doesn't rebuild this section.
    @State private var marks = LiveGaugeMarks()
    /// The point VoiceOver reads, refreshed once a second and at once when
    /// the pen enters or leaves. Storing it rebuilds the section.
    @State private var spokenPoint: TabletPoint?
    @State private var lastSpokenAt: TimeInterval = 0
    private static let spokenInterval: TimeInterval = 1

    @State private var isVisible = false
    @State private var touchViewer = UUID()
    /// Only the front window follows the pen and fingers; others hold
    /// still, apart from going quiet when the pen leaves.
    @Environment(\.controlActiveState) private var controlActiveState

    private func updateLiveTouchGate() {
        liveTouch.setShowing(isVisible && controlActiveState == .key, for: touchViewer)
    }

    var body: some View {
        let _ = BodyCounter.note("LiveInputSection")
        // The Buttons pane's lookup, which also covers Xencelabs devices and
        // a wireless dongle's paired tablet.
        let spec = productID.flatMap { ButtonsView.layoutSpec(productID: $0, context: deviceContext) }
        let companionSpec = companion.flatMap { c in
            ButtonsView.layoutSpec(productID: c.productID, context: c)
        }
        // Establishes livePointTick as a read dependency of this body —
        // without a read, bumping it doesn't reliably trigger a re-render.
        let _ = livePointTick
        // Only Wacom's protocol carries a hover height; every other decoder
        // hardcodes 0, so the hover gauge shows one height for those.
        let _ = marks.configure(
            orientation: orientation,
            reportsHoverDistance: (deviceContext?.vendorID ?? 0x056A) == 0x056A)
        LiveInputView(
            livePoint: spokenPoint,
            marks: marks,
            liveButtons: deviceContext?.liveButtons ?? LiveButtonState(),
            dialsTurning: spec?.hasMechanicalDial == true ? deviceContext?.dialsTurning : nil,
            activeToolID: deviceContext?.activeToolID,
            registry: DeviceRegistry.shared,
            hasRing: spec?.hasTouchRing == true || spec?.hasMechanicalDial == true,
            hasDualRings: spec?.hasDualRings == true,
            companion: companion.map { c in
                CompanionState(
                    name: companionSpec?.format == .expressKeyRemote ? "ExpressKey Remote" : "Quick Keys",
                    keyPrefix: companionSpec?.format == .expressKeyRemote ? "R" : "Q",
                    buttons: c.liveButtons,
                    ringActive: companionSpec?.hasMechanicalDial == true
                        ? c.dialsTurning.first == true : c.liveButtons.touchRingActive,
                    connected: c.isConnected)
            },
            orientation: orientation,
            liveTouch: spec?.hasFingerTouch == true ? liveTouch : nil,
            touchSource: deviceContext.map(ObjectIdentifier.init)
        )
        .onReceive(
            deviceContext?.livePointPublisher.eraseToAnyPublisher()
                ?? Empty().eraseToAnyPublisher()
        ) { point in
            guard controlActiveState == .key || point?.inProximity != true else { return }
            marks.receive(point)
            let now = ProcessInfo.processInfo.systemUptime
            let edge = (point?.inProximity == true) != (spokenPoint?.inProximity == true)
            guard edge || now - lastSpokenAt >= Self.spokenInterval else { return }
            lastSpokenAt = now
            spokenPoint = point
        }
        // Buttons show the moment they change. The publisher replays its
        // value to each new subscriber, and the body makes a new one every
        // redraw, so the replay is skipped or each redraw would cause another.
        .onReceive(
            deviceContext?.$liveButtons.dropFirst().eraseToAnyPublisher()
                ?? Empty().eraseToAnyPublisher()
        ) { _ in livePointTick &+= 1 }
        .onReceive(
            deviceContext?.$dialsTurning.dropFirst().eraseToAnyPublisher()
                ?? Empty().eraseToAnyPublisher()
        ) { _ in livePointTick &+= 1 }
        .onReceive(
            companion?.$liveButtons.dropFirst().eraseToAnyPublisher()
                ?? Empty().eraseToAnyPublisher()
        ) { _ in livePointTick &+= 1 }
        .onReceive(
            companion?.$dialsTurning.dropFirst().eraseToAnyPublisher()
                ?? Empty().eraseToAnyPublisher()
        ) { _ in livePointTick &+= 1 }
        .onAppear { isVisible = true; updateLiveTouchGate() }
        .onDisappear { isVisible = false; updateLiveTouchGate() }
        .onChange(of: controlActiveState) { state in
            updateLiveTouchGate()
            // Catch up with whatever happened while another window was in front.
            guard state == .key else { return }
            let point = deviceContext?.livePoint
            marks.receive(point)
            spokenPoint = point
            lastSpokenAt = ProcessInfo.processInfo.systemUptime
        }
    }
}

// MARK: - LiveInputView
//
// Isolated from InfoView so SwiftUI only diffs and re-renders this section
// when livePoint / liveButtons / activeToolID change.

private struct LiveInputView: View {
    /// Read for VoiceOver values only; refreshed about once a second.
    let livePoint: TabletPoint?
    let marks: LiveGaugeMarks
    let liveButtons: LiveButtonState
    /// Each mechanical dial, true while it turns; nil for touch rings.
    var dialsTurning: [Bool]?
    let activeToolID: String?
    let registry: DeviceRegistry
    /// False for a device with neither a touch ring nor a dial, which shows
    /// no ring gauge.
    var hasRing: Bool = false
    var hasDualRings: Bool = false
    var companion: CompanionState?
    var orientation: TabletOrientation = .landscape
    /// Nil for a tablet without finger touch.
    var liveTouch: LiveTouchPublisher?
    /// The tablet whose fingers the touch gauge shows; nil accepts any.
    var touchSource: ObjectIdentifier?

    // MARK: - Gauges
    //
    // Position, pressure, tilt, rotation, and hover each draw as a small
    // mark that glides. Numerals replaced several times a second read as
    // flashing; this section is a liveness check, not a precision readout.

    @Environment(\.textScale) private var textScale

    fileprivate static let gaugeSide: CGFloat = 36
    /// Each gauge's column, caption included.
    private static let cellWidth: CGFloat = 72
    /// The ring gauge eases on and off, matching the hover ring's change
    /// between heights; the pen marks glide on their layers.
    private static let ringEase = Animation.easeInOut(duration: 0.2)
    fileprivate static let outline = Color.secondary.opacity(0.3)
    /// Square frames: a dot wandering inside a circle reads as an eye.
    fileprivate static let gaugeFrame = RoundedRectangle(cornerRadius: 8, style: .continuous)

    @ViewBuilder
    private func gaugeRow(point: TabletPoint?, buttons: LiveButtonState) -> some View {
        let tiltFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1)).sign(strategy: .always())
        HStack(alignment: .top, spacing: 6) {
            gauge(
                label: String(localized: "Position", comment: "Live Input gauge label — pen position on the tablet"),
                spokenValue: point.map { "X: \(quantize($0.x, to: 100)), Y: \(quantize($0.y, to: 100))" } ?? String(localized: "None"),
                mark: .position
            ) {
                Self.gaugeFrame.stroke(Self.outline, lineWidth: 1.5)
            }
            gauge(
                label: String(localized: "Pressure", comment: "Live Input table row label"),
                spokenValue: (point?.normalizedPressure ?? 0).formatted(.percent.precision(.fractionLength(0))),
                mark: .pressure
            ) {
                Self.gaugeFrame.stroke(Self.outline, lineWidth: 1.5)
            }
            gauge(
                label: String(localized: "Tilt", comment: "Live Input table row label — pen tilt X/Y"),
                spokenValue: "X: \((point?.tiltX ?? 0).formatted(tiltFormat)), Y: \((point?.tiltY ?? 0).formatted(tiltFormat))",
                mark: .tilt
            ) {
                ZStack {
                    Self.gaugeFrame.stroke(Self.outline, lineWidth: 1.5)
                    Circle().fill(Color.secondary.opacity(0.4)).frame(width: 3, height: 3)
                }
            }
            gauge(
                label: String(localized: "Rotation", comment: "Live Input table row label — pen rotation in degrees"),
                spokenValue: point.map {
                    Measurement(value: $0.rotation.rounded(), unit: UnitAngle.degrees).formatted(.measurement(width: .wide))
                } ?? String(localized: "None"),
                mark: .rotation
            ) {
                ZStack {
                    Self.gaugeFrame.stroke(Self.outline, lineWidth: 1.5)
                    Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 2, height: 6).offset(y: -14)
                }
            }
            gauge(
                label: String(localized: "Hover", comment: "Live Input table row label — hover distance"),
                spokenValue: point?.inProximity == true
                    ? String(localized: "In Range", comment: "Hover state without a height value — device reports only in/out")
                    : String(localized: "Out of Range", comment: "Hover state without a height value — device reports only in/out"),
                mark: .hover
            ) {
                Self.gaugeFrame.stroke(Self.outline, lineWidth: 1.5)
            }
            if let liveTouch {
                TouchGauge(liveTouch: liveTouch, source: touchSource, orientation: orientation) { label, spoken, drawing in
                    gauge(label: label, spokenValue: spoken) { drawing }
                }
            }
            if let dials = dialsTurning {
                ringGauge(
                    label: hasDualRings
                        ? String(localized: "Dial \u{2014} Left", comment: "Live Input gauge label — left dial on two-dial tablets")
                        : String(localized: "Dial", comment: "Section header / row label for a mechanical rotate-only dial"),
                    active: dials.first == true)
                if hasDualRings {
                    ringGauge(
                        label: String(localized: "Dial \u{2014} Right", comment: "Live Input gauge label — right dial on two-dial tablets"),
                        active: dials.dropFirst().first == true)
                }
            } else if hasRing {
                ringGauge(
                    label: hasDualRings
                        ? String(localized: "Ring \u{2014} Left", comment: "Live Input table row label — left touch ring on dual-ring tablets")
                        : String(localized: "Touch Ring", comment: "Section header / row label for touch ring"),
                    active: buttons.touchRingActive)
                if hasDualRings {
                    ringGauge(
                        label: String(localized: "Ring \u{2014} Right", comment: "Live Input table row label — right touch ring on dual-ring tablets"),
                        active: buttons.touchRing2Active)
                }
            }
            if let companion {
                ringGauge(label: companion.name, active: companion.ringActive)
                    .opacity(companion.connected ? 1 : 0.4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    /// One drawn gauge over its caption, read by VoiceOver as one element.
    /// Drawn at 36 pt and scaled whole, so marks stay centered; a moving
    /// mark lies over the drawing in the same 36-point space.
    @ViewBuilder
    private func gauge(
        label: String,
        spokenValue: String,
        mark: LiveGaugeMarks.Kind? = nil,
        @ViewBuilder drawing: () -> some View
    ) -> some View {
        VStack(spacing: 4) {
            drawing()
                .frame(width: Self.gaugeSide, height: Self.gaugeSide)
                .scaleEffect(textScale)
                .scaledFrame(width: Self.gaugeSide, height: Self.gaugeSide)
                .overlay { if let mark { GlidingMarkView(kind: mark, marks: marks) } }
            // A fixed width keeps the gauges evenly spaced; a long caption
            // wraps to a second line.
            Text(label)
                .appFont(.settingsBadge)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .scaledFrame(width: Self.cellWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue)
    }

    /// A ring that fills while a finger is on it, or while a dial turns.
    @ViewBuilder
    private func ringGauge(label: String, active: Bool) -> some View {
        gauge(
            label: label,
            spokenValue: active
                ? String(localized: "Active", comment: "Touch ring active state in Live Input")
                : String(localized: "Idle", comment: "Touch ring idle state in Live Input")
        ) {
            ZStack {
                Self.gaugeFrame.stroke(Self.outline, lineWidth: 1.5)
                Circle().stroke(Self.outline, lineWidth: 5).padding(8)
                Circle().stroke(Color.accentColor, lineWidth: 5).padding(8)
                    .opacity(active ? 1 : 0)
                    .animation(Self.ringEase, value: active)
            }
        }
    }

    var body: some View {
        let _ = BodyCounter.note("LiveInput")
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                let tool: DeviceRegistry.KnownTool? = {
                    guard let id = activeToolID else { return nil }
                    return registry.knownTools.first(where: { $0.id == id })
                }()

                penRow(label: String(localized: "Pen Name", comment: "Live Input table row label"), value: tool?.nickname ?? "—")
                penRow(label: String(localized: "Pen Type", comment: "Live Input table row label"), value: tool?.kind ?? "—")

                let lb = liveButtons

                liveRow(label: String(localized: "Buttons", comment: "Live Input table row label")) {
                    let anyExpress = lb.expressKeys.contains(true)
                    HStack(spacing: 4) {
                        if lb.tipDown { tag(String(localized: "Tip", comment: "Pen tip live input tag")) }
                        if lb.eraserDown { tag(String(localized: "Eraser", comment: "Eraser live input tag")) }
                        if lb.button1Down { tag("B1") }
                        if lb.button2Down { tag("B2") }
                        ForEach(0..<lb.expressKeys.count, id: \.self) { i in
                            if lb.expressKeys[i] { tag("K\(i + 1)") }
                        }
                        let companionKeys = (companion?.buttons.expressKeys ?? []).indices
                            .filter { companion?.buttons.expressKeys[$0] == true }
                        ForEach(companionKeys, id: \.self) { i in
                            tag("\(companion?.keyPrefix ?? "")\(i + 1)")
                        }
                        if !lb.tipDown && !lb.eraserDown && !lb.button1Down
                            && !lb.button2Down && !anyExpress && companionKeys.isEmpty
                        {
                            Text("None").foregroundStyle(.tertiary).appFont(.settingsLabel)
                        }
                    }
                }

                Divider()
                    .gridCellColumns(2)
                    .padding(.vertical, 4)

                GridRow {
                    gaugeRow(point: livePoint, buttons: lb)
                        .gridCellColumns(2)
                }
            }
            // The enclosing grouped-form section supplies the card chrome.
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minWidth: 380)
        }
    }

    /// Round to the nearest multiple of `step` (coordinates are non-negative).
    private func quantize(_ value: Int, to step: Int) -> Int {
        ((value + step / 2) / step) * step
    }

    @ViewBuilder
    private func penRow(label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .scaledFrame(minWidth: 90, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func liveRow(
        label: String,
        @ViewBuilder value: () -> some View
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .scaledFrame(minWidth: 90, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            value()
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .appFont(.settingsBadge)
            .padding(.horizontal, 4)
            .background(Color.accentColor.opacity(0.2))
            .cornerRadius(3)
    }
}

/// A dot for each finger on the surface, placed as the fingers sit relative
/// to each other: the Scratchpad's touch view in plain form. It observes the
/// touch stream itself, so a touch frame redraws only this gauge, and only
/// for its own tablet in the front window. `framed` wraps the drawing in the
/// row's shared frame and caption.
private struct TouchGauge<Framed: View>: View {
    let liveTouch: LiveTouchPublisher
    let source: ObjectIdentifier?
    let orientation: TabletOrientation
    let framed: (_ label: String, _ spokenValue: String, _ drawing: AnyView) -> Framed
    @State private var contacts: [TouchContact] = []
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        let spots = touchContactLayout(contacts, orientation: orientation)
        let travel = LiveInputView.gaugeSide - 14
        framed(
            String(localized: "Touch"),
            contacts.count.formatted(),
            AnyView(ZStack {
                LiveInputView.gaugeFrame.stroke(LiveInputView.outline, lineWidth: 1.5)
                ForEach(spots.indices, id: \.self) { i in
                    Circle().fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .offset(x: (spots[i].x - 0.5) * travel, y: (spots[i].y - 0.5) * travel)
                }
            })
        )
        .onReceive(liveTouch.$contacts) { new in
            guard new.isEmpty
                || (controlActiveState == .key && (source == nil || liveTouch.source == source))
            else { return }
            contacts = new
        }
    }
}

/// What the live input section shows of a tablet's companion.
private struct CompanionState {
    /// The product's own name, which stays in English.
    let name: String
    /// Marks the companion's keys apart from the tablet's own K1, K2, …
    let keyPrefix: String
    let buttons: LiveButtonState
    let ringActive: Bool
    let connected: Bool
}

/// A gauge's moving mark, in the gauge's 36-point space.
private struct GlidingMark: Equatable {
    var path: Path
    /// Nil fills the path; otherwise strokes it this wide.
    var lineWidth: CGFloat?
    var roundCap = false
    var visible = true
}

/// Hosts one gauge's mark layer and hands it to `LiveGaugeMarks`.
private struct GlidingMarkView: NSViewRepresentable {
    let kind: LiveGaugeMarks.Kind
    let marks: LiveGaugeMarks

    func makeNSView(context: Context) -> GlidingMarkLayerView { GlidingMarkLayerView() }

    func updateNSView(_ view: GlidingMarkLayerView, context: Context) {
        marks.attach(view, as: kind)
    }
}

/// Works out each gauge's mark from pen points and sets it on the gauge's
/// layer directly, so motion costs no SwiftUI rebuild. The system's render
/// server draws the glide between marks. Precision isn't the point: the
/// gauges confirm the pen is alive and moving the expected way.
@MainActor
private final class LiveGaugeMarks {
    enum Kind: CaseIterable { case position, pressure, tilt, rotation, hover }

    /// How often each mark updates, on average. The crosshair and pressure
    /// disc update a little faster, since they're the ones people watch move.
    private static func interval(_ kind: Kind) -> TimeInterval {
        kind == .position || kind == .pressure ? 1.0 / 12 : 0.1
    }
    /// Points arrive about 16 times a second, so a glide this long always
    /// ends before the next can start; a longer one would be cut short and
    /// jump.
    private static let glide: CFTimeInterval = 1.0 / 16

    private struct WeakView { weak var view: GlidingMarkLayerView? }
    private var views: [Kind: WeakView] = [:]
    private var current: [Kind: GlidingMark] = [:]

    private var orientation = TabletOrientation.landscape
    private var reportsHoverDistance = true
    /// Largest hover height seen. The range differs by family, so the gauge
    /// fits itself to what the tablet reports.
    private var hoverCeiling = 63
    private var lastPoint: TabletPoint?
    private var wasInRange = false
    private var lastShownAt: [Kind: TimeInterval] = [:]
    /// Total signed rotation since the pen entered, not clamped to 0-360:
    /// each new angle adds the shortest signed step from the last, so a wrap
    /// (358° -> 2°) adds +4° instead of sweeping the hand back ~356°
    /// (confirmed against a ~9-revolution PTK-870 USB capture).
    private var accumAngle: Double = 0
    private var lastRawAngle: Double?

    func configure(orientation: TabletOrientation, reportsHoverDistance: Bool) {
        guard orientation != self.orientation || reportsHoverDistance != self.reportsHoverDistance else { return }
        self.orientation = orientation
        self.reportsHoverDistance = reportsHoverDistance
        for kind in Kind.allCases { show(kind, mark(kind, lastPoint), glide: 0) }
    }

    func attach(_ view: GlidingMarkLayerView, as kind: Kind) {
        if views[kind]?.view !== view { views[kind] = WeakView(view: view) }
        view.show(current[kind] ?? mark(kind, lastPoint), glide: 0)
    }

    func receive(_ point: TabletPoint?) {
        lastPoint = point
        accumulateRotation(point?.rotation)
        if let height = point?.hoverDistance, height > hoverCeiling { hoverCeiling = height }

        // A pen entering or leaving shows at once, without a glide; so does
        // the reset after it leaves.
        let inRange = point?.inProximity == true
        let edge = inRange != wasInRange || point == nil
        wasInRange = inRange

        let now = ProcessInfo.processInfo.systemUptime
        for kind in Kind.allCases {
            // Points arrive about 1/16 s apart, so waiting a full interval
            // after each update would skip every other point and run at
            // 8 a second. Counting from when the update was due keeps the
            // average at the intended rate.
            let interval = Self.interval(kind)
            let last = lastShownAt[kind] ?? 0
            guard edge || now - last >= interval else { continue }
            lastShownAt[kind] = max(last + interval, now - interval)
            // The hover ring changes only between heights, so it can take
            // longer and ease.
            show(kind, mark(kind, point), glide: edge ? 0 : kind == .hover ? 0.2 : Self.glide, eases: kind == .hover)
        }
    }

    private func show(_ kind: Kind, _ mark: GlidingMark, glide: CFTimeInterval, eases: Bool = false) {
        current[kind] = mark
        views[kind]?.view?.show(mark, glide: glide, eases: eases)
    }

    private func accumulateRotation(_ degrees: Double?) {
        guard let d = degrees else {
            accumAngle = 0
            lastRawAngle = nil
            return
        }
        guard let prev = lastRawAngle else {
            accumAngle = d
            lastRawAngle = d
            return
        }
        var delta = (d - prev).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        accumAngle += delta
        lastRawAngle = d
    }

    // MARK: Marks, in the gauge's 36-point space

    private static let side = LiveInputView.gaugeSide
    private static let center = side / 2

    /// Rounds to whole points: smaller moves hardly show at this size, and
    /// an unchanged mark skips its layer update.
    private func snap(_ v: CGFloat) -> CGFloat { v.rounded() }

    private func mark(_ kind: Kind, _ point: TabletPoint?) -> GlidingMark {
        let side = Self.side, c = Self.center
        let inRange = point?.inProximity == true
        switch kind {
        case .position:
            // Two lines crossing where the pen is, turned like the tablet on
            // the desk so they follow the hand.
            let travel = side - 8
            let turned = point.map {
                DisplayMapper.orient(x: Double($0.x), y: Double($0.y), maxX: Double($0.maxX), maxY: Double($0.maxY), orientation: orientation)
            }
            let x = snap(c + ((turned.map { $0.effMaxX > 0 ? $0.ox / $0.effMaxX : 0.5 } ?? 0.5) - 0.5) * travel)
            let y = snap(c + ((turned.map { $0.effMaxY > 0 ? $0.oy / $0.effMaxY : 0.5 } ?? 0.5) - 0.5) * travel)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 1.5)); path.addLine(to: CGPoint(x: x, y: side - 1.5))
            path.move(to: CGPoint(x: 1.5, y: y)); path.addLine(to: CGPoint(x: side - 1.5, y: y))
            return GlidingMark(path: path, lineWidth: 1.5, visible: inRange)
        case .pressure:
            // A disc that grows with pressure, like a brush mark, in six
            // steps; the lightest touch shows the smallest.
            let level = (min(max(point?.normalizedPressure ?? 0, 0), 1) * 6).rounded(.up) / 6
            let d = max(0.01, (side - 3) * level)
            return GlidingMark(path: Path(ellipseIn: CGRect(x: c - d / 2, y: c - d / 2, width: d, height: d)), lineWidth: nil)
        case .tilt:
            // A needle that points the way the top of the pen leans, in
            // eight directions and two lengths; a nearly upright pen shows
            // a dot.
            let reach = side / 2 - 4
            let lean = DisplayMapper.orientTilt(x: point?.tiltX ?? 0, y: point?.tiltY ?? 0, orientation: orientation)
            let amount = (lean.x * lean.x + lean.y * lean.y).squareRoot()
            let length = amount < 0.15 ? 0 : amount < 0.45 ? reach / 2 : reach
            let direction = (atan2(lean.y, lean.x) / (.pi / 4)).rounded() * (.pi / 4)
            var path = Path()
            path.move(to: CGPoint(x: c, y: c))
            path.addLine(to: CGPoint(x: c + cos(direction) * length, y: c + sin(direction) * length))
            return GlidingMark(path: path, lineWidth: 2, roundCap: true, visible: inRange)
        case .rotation:
            // A clock hand in 15° steps; negated so a clockwise twist sweeps
            // clockwise.
            let a = -(accumAngle / 15).rounded() * 15 * .pi / 180
            var path = Path()
            path.move(to: CGPoint(x: c, y: c))
            path.addLine(to: CGPoint(x: c + 14 * sin(a), y: c - 14 * cos(a)))
            return GlidingMark(path: path, lineWidth: 2, visible: inRange)
        case .hover:
            // Bands, not a height: a wide ring while the pen hovers high, a
            // smaller one as it nears, and a dot when it touches. The ring
            // changes only when the band does.
            let fraction: Double = {
                guard let p = point else { return 1 }
                if p.pressure > 0 { return 0 }
                guard reportsHoverDistance else { return 1 }
                return Double(p.hoverDistance) <= Double(hoverCeiling) * 0.4 ? 0.5 : 1
            }()
            let dot: CGFloat = 6
            let d = dot + (side - dot - 6) * fraction
            return GlidingMark(path: Path(ellipseIn: CGRect(x: c - d / 2, y: c - d / 2, width: d, height: d)), lineWidth: 2, visible: inRange)
        }
    }
}

private final class GlidingMarkLayerView: NSView {
    private let shape = CAShapeLayer()
    private var mark: GlidingMark?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Unflipped, so the layer draws y-up and `apply` flips the mark once.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    /// Glides to `next` over `glide` seconds, so each glide ends about as
    /// the next mark arrives; zero places it at once.
    func show(_ next: GlidingMark, glide: CFTimeInterval, eases: Bool = false) {
        // Sensor jitter and a still pen resend the same mark; skipping it
        // saves a layer update.
        if next == mark { return }
        // A mark that was hidden fades in where it belongs, without gliding
        // from where the pen last left; leaving fades it out.
        let fades = mark != nil && mark?.visible != next.visible
        let glides = glide > 0 && mark?.visible == true && next.visible
        mark = next
        apply(glide: glides ? glide : 0, eases: eases, fades: fades)
    }

    override func layout() {
        super.layout()
        apply(glide: 0)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(glide: 0)
    }

    /// One fade when the pen enters or leaves: cheap, since nothing moves.
    private static let fadeDuration: CFTimeInterval = 0.2

    private func apply(glide: CFTimeInterval, eases: Bool = false, fades: Bool = false) {
        guard let mark, bounds.width > 0 else { return }
        let scale = bounds.width / LiveInputView.gaugeSide
        // Layers draw y-up; the mark's path is y-down.
        var flip = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: 0, ty: bounds.height)
        let path = mark.path.cgPath.copy(using: &flip)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        var accent = NSColor.controlAccentColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { accent = NSColor.controlAccentColor.cgColor }
        shape.fillColor = mark.lineWidth == nil ? accent : nil
        shape.strokeColor = mark.lineWidth == nil ? nil : accent
        shape.lineWidth = (mark.lineWidth ?? 0) * scale
        shape.lineCap = mark.roundCap ? .round : .butt
        // A hidden mark keeps its last place, so a fade-out doesn't move; a
        // gliding one moves in the transaction below.
        if mark.visible && glide == 0 { shape.path = path }
        CATransaction.commit()

        CATransaction.begin()
        if fades {
            CATransaction.setAnimationDuration(Self.fadeDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        shape.opacity = mark.visible ? 1 : 0
        CATransaction.commit()

        guard glide > 0, mark.visible else { return }
        // A shape's path never animates implicitly, so the glide is an
        // explicit animation. It starts from where the mark shows now, so a
        // glide cut short by the next one doesn't jump.
        let from = shape.presentation()?.path ?? shape.path
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = path
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = from
        animation.toValue = path
        animation.duration = glide
        animation.timingFunction = CAMediaTimingFunction(name: eases ? .easeInEaseOut : .linear)
        shape.add(animation, forKey: "glide")
    }
}
