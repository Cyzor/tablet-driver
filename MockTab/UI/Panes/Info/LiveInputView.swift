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

    /// For a wireless-dongle-bound window, the dongle's own PID carries no
    /// capability data — the paired tablet's does.
    private var effectiveProductID: Int? {
        if let paired = deviceContext?.pairedProductID, paired != 0 { return paired }
        return productID
    }

    /// Unused directly — its writes force a body re-evaluation when
    /// livePoint publishes, since that no longer rides tabletManager's
    /// general objectWillChange cascade (see DeviceContext.livePoint).
    @State private var livePointTick = 0

    var body: some View {
        let _ = BodyCounter.note("LiveInputSection")
        // Establishes livePointTick as a read dependency of this body —
        // without a read, bumping it doesn't reliably trigger a re-render.
        let _ = livePointTick
        LiveInputView(
            livePoint: deviceContext?.livePoint,
            liveButtons: deviceContext?.liveButtons ?? LiveButtonState(),
            activeToolID: deviceContext?.activeToolID,
            registry: DeviceRegistry.shared,
            hasDualRings: WacomDeviceRegistry.spec(for: effectiveProductID ?? 0)?.hasDualRings == true,
            // Only Wacom's protocol carries a hover height; every other
            // decoder hardcodes 0, so show plain in/out instead of a
            // number that reads as a measured zero.
            reportsHoverDistance: (deviceContext?.vendorID ?? 0x056A) == 0x056A
        )
        .onReceive(
            deviceContext?.livePointPublisher.eraseToAnyPublisher()
                ?? Empty().eraseToAnyPublisher()
        ) { _ in livePointTick &+= 1 }
    }
}

// MARK: - LiveInputView
//
// Isolated from InfoView so SwiftUI only diffs and re-renders this section
// when livePoint / liveButtons / activeToolID change.

private struct LiveInputView: View {
    let livePoint: TabletPoint?
    let liveButtons: LiveButtonState
    let activeToolID: String?
    let registry: DeviceRegistry
    var hasDualRings: Bool = false
    var reportsHoverDistance: Bool = true

    // MARK: - Rotation gauge

    /// Total signed rotation since the gauge last reset, not clamped to 0-360 —
    /// each new raw angle adds the shortest signed delta from the previous one,
    /// so a wrap (358° -> 2°) contributes +4° instead of snapping the hand back
    /// ~356° (confirmed against a ~9-revolution PTK-870 USB capture).
    @Environment(\.textScale) private var textScale
    @State private var accumAngle: Double = 0
    @State private var lastRawAngle: Double?

    /// Clock-face rotation gauge: thin line pivots from center like a clock hand.
    /// Negates the accumulated angle so clockwise physical twist = clockwise sweep.
    @ViewBuilder
    private func rotationGauge(degrees: Double?) -> some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1.5)
            Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 2, height: 6).offset(y: -14)
            Rectangle().fill(Color.accentColor).frame(width: 2, height: 14).offset(y: -7)
                .rotationEffect(.radians(-accumAngle * .pi / 180), anchor: .center)
        }
        .frame(width: 36, height: 36)
        // Drawn at 36 pt and scaled whole, so the hand stays centered.
        .scaleEffect(textScale)
        .scaledFrame(width: 36, height: 36)
        .onChange(of: degrees) { newDeg in
            guard let d = newDeg else {
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
    }

    var body: some View {
        let _ = BodyCounter.note("LiveInput")
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                let tool: DeviceRegistry.KnownTool? = {
                    guard let id = activeToolID else { return nil }
                    return registry.knownTools.first(where: { $0.id == id })
                }()

                stylusRow(label: String(localized: "Stylus Name", comment: "Live Input table row label"), value: tool?.nickname ?? "—")
                stylusRow(label: String(localized: "Stylus Type", comment: "Live Input table row label"), value: tool?.kind ?? "—")
                stylusRow(
                    label: String(localized: "Tool Code", comment: "Live Input table row label — hex tool identifier"),
                    value: tool?.toolCode.map { "0x\(String(format: "%04X", $0))" } ?? "—")
                stylusRow(label: String(localized: "Serial", comment: "Live Input table row label — tool serial number"), value: tool?.displayID ?? "—")

                Divider()
                    .gridCellColumns(2)
                    .padding(.vertical, 4)

                let point = livePoint
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
                        if !lb.tipDown && !lb.eraserDown && !lb.button1Down
                            && !lb.button2Down && !anyExpress
                        {
                            Text("None").foregroundStyle(.tertiary).appFont(.settingsLabel)
                        }
                    }
                }

                liveRow(
                    label: String(localized: "Pressure", comment: "Live Input table row label"),
                    spokenValue: (point?.normalizedPressure ?? 0).formatted(.percent.precision(.fractionLength(0)))
                ) {
                    HStack {
                        Text(point != nil ? "\(point!.pressure)" : "0")
                            .monospacedDigit()
                            .scaledFrame(width: 48, alignment: .trailing)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.2))
                                Capsule().fill(Color.accentColor)
                                    .frame(
                                        width: geo.size.width
                                            * CGFloat(point?.normalizedPressure ?? 0))
                            }
                        }
                        .scaledFrame(width: 80, height: 6)
                    }
                }

                liveRow(
                    label: String(localized: "Rotation", comment: "Live Input table row label — pen rotation in degrees"),
                    spokenValue: point.map {
                        Measurement(value: $0.rotation.rounded(), unit: UnitAngle.degrees).formatted(.measurement(width: .wide))
                    } ?? String(localized: "None")
                ) {
                    rotationGauge(degrees: point?.rotation)
                }

                // Coordinate and tilt are heavily quantized: this table is a
                // liveness check, not a precision readout, and raw values
                // flicker on every report even with the pen at rest.
                liveRow(label: String(localized: "Coordinate", comment: "Live Input table row label — raw X/Y position")) {
                    Text(
                        point != nil
                            ? "X: \(quantize(point!.x, to: 100))   Y: \(quantize(point!.y, to: 100))"
                            : String(localized: "X: 0   Y: 0", comment: "Default coordinate display when no pen is detected")
                    )
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                liveRow(label: String(localized: "Tilt", comment: "Live Input table row label — pen tilt X/Y")) {
                    let tilt = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1)).sign(strategy: .always())
                    Text(verbatim: "X: \((point?.tiltX ?? 0).formatted(tilt))   Y: \((point?.tiltY ?? 0).formatted(tilt))")
                        .monospacedDigit()
                }

                liveRow(label: String(localized: "Hover", comment: "Live Input table row label — hover distance")) {
                    if let p = point, reportsHoverDistance {
                        Text("\(p.hoverDistance)   \(p.inProximity ? String(localized: "(In Range)", comment: "Hover proximity state") : String(localized: "(Out)", comment: "Hover proximity state — out of range"))")
                            .monospacedDigit()
                    } else if let p = point {
                        Text(p.inProximity
                            ? String(localized: "In Range", comment: "Hover state without a height value — device reports only in/out")
                            : String(localized: "Out of Range", comment: "Hover state without a height value — device reports only in/out"))
                    } else {
                        Text("—").monospacedDigit()
                    }
                }

                liveRow(label: hasDualRings ? String(localized: "Ring \u{2014} Left", comment: "Live Input table row label — left touch ring on dual-ring tablets") : String(localized: "Touch Ring", comment: "Section header / row label for touch ring")) {
                    HStack(spacing: 6) {
                        Image(
                            systemName: lb.touchRingActive
                                ? "checkmark.circle.fill" : "circle"
                        )
                        .foregroundStyle(lb.touchRingActive ? Color.green : Color.secondary)
                        .imageScale(.small)
                        .accessibilityHidden(true)
                        Text(verbatim: lb.touchRingActive
                            ? String(localized: "Active", comment: "Touch ring active state in Live Input")
                            : String(localized: "Idle", comment: "Touch ring idle state in Live Input"))
                            .foregroundStyle(lb.touchRingActive ? .primary : .tertiary)
                    }
                }

                if hasDualRings {
                    liveRow(label: String(localized: "Ring \u{2014} Right", comment: "Live Input table row label — right touch ring on dual-ring tablets")) {
                        HStack(spacing: 6) {
                            Image(
                                systemName: lb.touchRing2Active
                                    ? "checkmark.circle.fill" : "circle"
                            )
                            .foregroundStyle(lb.touchRing2Active ? Color.green : Color.secondary)
                            .imageScale(.small)
                            .accessibilityHidden(true)
                            Text(verbatim: lb.touchRing2Active
                                ? String(localized: "Active", comment: "Touch ring active state in Live Input")
                                : String(localized: "Idle", comment: "Touch ring idle state in Live Input"))
                                .foregroundStyle(lb.touchRing2Active ? .primary : .tertiary)
                        }
                    }
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
    private func stylusRow(label: String, value: String) -> some View {
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

    /// `spokenValue` makes the row one VoiceOver element, for values drawn
    /// rather than written.
    @ViewBuilder
    private func liveRow(
        label: String,
        spokenValue: String? = nil,
        @ViewBuilder value: () -> some View
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .scaledFrame(minWidth: 90, alignment: .trailing)
                .gridColumnAlignment(.trailing)
                .accessibilityHidden(spokenValue != nil)
            if let spokenValue {
                value()
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel(label)
                    .accessibilityValue(spokenValue)
            } else {
                value()
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
