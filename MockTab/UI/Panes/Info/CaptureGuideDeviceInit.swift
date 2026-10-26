// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later


import AppKit
import Combine
import SwiftUI
import TabletKit

// The capture guide's advanced device-mode setup: the init steps a capture
// can send before recording.
extension CaptureGuideView {
    /// How long a write must stay in flight before the sheet says anything
    /// about it.
    ///
    /// A USB feature write returns in a millisecond or two, so an indicator
    /// tied directly to `isSendingInitReport` appears and vanishes within a
    /// frame or two — long enough to grow the sheet and snap it back, which
    /// reads as the window flinching rather than as progress. The indicator
    /// exists for the Bluetooth case, where the same write genuinely takes
    /// several seconds; below this threshold there is nothing worth reporting,
    /// and showing nothing at all is the honest rendering of "instant".
    static let sendingIndicatorDelay = Duration.milliseconds(500)

    /// Show the indicator only if the write is still in flight after the
    /// delay, and hide it the moment the write finishes.
    func trackSendingIndicator(isSending: Bool) {
        sendingIndicatorTask?.cancel()
        guard isSending else {
            showSendingIndicator = false
            return
        }
        sendingIndicatorTask = Task { @MainActor in
            try? await Task.sleep(for: Self.sendingIndicatorDelay)
            guard !Task.isCancelled, engine.isSendingInitReport else { return }
            showSendingIndicator = true
        }
    }

    /// Collapsed-by-default control for writing a device-mode init feature
    /// report mid-session.
    ///
    /// Deliberately supplemental rather than a gating step: collection is
    /// already running when this appears, so a tester can send a write and
    /// watch the event counter for a response without restarting. Most devices
    /// never need it — hence collapsed, and labeled advanced.
    var deviceModeInitControl: some View {
        DisclosureRow(
            label: String(localized: "Experimental: switch the tablet into data mode", comment: "Disclosure row label for the advanced device mode init control"),
            isExpanded: $showInitControl
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Some tablets stay quiet unless they're asked to answer.", comment: "Explanation of the advanced device mode init control in device data collection"))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let reportID = coordinator.autoDetectedModeReportID {
                    Label(
                        String(localized: "Found in this tablet's descriptor: report \(String(format: "0x%02X", reportID))", comment: "Notice that the device mode init report ID was read from the device's own descriptor rather than guessed"),
                        systemImage: "checkmark.circle"
                    )
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text(String(localized: "Report", comment: "Label for the feature report ID field in the device mode init control"))
                        .appFont(.caption)
                    TextField("0x02", text: $initReportIDText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .monospacedDigit()
                    Text(String(localized: "Value", comment: "Label for the feature report value field in the device mode init control"))
                        .appFont(.caption)
                    TextField("0x02", text: $initValueText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .monospacedDigit()
                    Button {
                        sendInitReport()
                    } label: {
                        Text(String(localized: "Send", comment: "Button that writes the device mode init feature report"))
                    }
                    .disabled(!engine.isRunning || engine.isSendingInitReport
                              || parseHexByte(initReportIDText) == nil
                              || parseHexByte(initValueText) == nil)

                    if showSendingIndicator {
                        ProgressView()
                            .appControlSize(.small)
                    }
                }

                if showSendingIndicator {
                    Text(String(localized: "Waiting on the tablet — over Bluetooth this takes a moment.", comment: "Status shown while a device mode init write is in flight"))
                        .appFont(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The driver's own init write, which happened when the tablet
                // connected — before this sheet was open. When it was refused
                // the tablet never left its reduced reporting mode, so the
                // whole capture describes a half-awake device. Said here
                // because the exported file alone is too late to help someone
                // still standing at the hardware.
                if let failed = engine.initReportsAutomatic.last(where: { !$0.succeeded }) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "The tablet refused the setup command it needs to report fully.", comment: "Warning that the driver's own device-mode init write was rejected by the tablet"))
                            Text(String(localized: "Sent \(failed.reportIDHex) = \(failed.valueHex) on connect. Pen details will be missing.", comment: "Detail line naming the rejected automatic init write and its consequence"))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .appFont(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let last = engine.initReportsSent.last {
                    let rejectedCount = engine.initReportsSent.filter { !$0.succeeded }.count
                    Label(
                        last.succeeded
                            ? String(localized: "Sent \(last.reportIDHex) = \(last.valueHex)", comment: "Confirmation that a device mode init write was accepted")
                            : String(localized: "Rejected \(last.reportIDHex) = \(last.valueHex)", comment: "Notice that a device mode init write was refused by the device"),
                        systemImage: last.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .appFont(.caption)
                    .foregroundStyle(last.succeeded ? .green : .secondary)

                    if rejectedCount > 1 {
                        Text(String(localized: "\(rejectedCount) attempts rejected", comment: "Rolling count of rejected device mode init writes"))
                            .appFont(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.top, 6)
            .padding(.leading, 30)
        }
    }

    /// Accepts "0x02", "02", or "2" — testers copy report IDs from documentation
    /// in whichever form the source used. Returns nil when out of byte range.
    func parseHexByte(_ text: String) -> Int? {
        var s = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("0x") { s = String(s.dropFirst(2)) }
        guard let v = Int(s, radix: 16), (0...255).contains(v) else { return nil }
        return v
    }

    func sendInitReport() {
        guard let reportID = parseHexByte(initReportIDText),
              let value = parseHexByte(initValueText)
        else { return }
        coordinator.sendModeSwitch(reportID: reportID, value: value)
    }

    /// Recording-status indicator dot. When Differentiate-Without-Color is
    /// enabled, uses an SF Symbol that distinguishes state by glyph
    /// (filled-vs-hollow record glyph) in addition to red-vs-gray color.
    @ViewBuilder
    var recordingDot: some View {
        if differentiateWithoutColor {
            Image(systemName: engine.isRunning ? "record.circle.fill" : "circle")
                .font(.system(size: 7))
                .foregroundStyle(engine.isRunning ? Color.red : Color.secondary)
                .accessibilityHidden(true)
        } else {
            Circle()
                .fill(engine.isRunning ? Color.red : Color.secondary)
        }
    }

    /// Explains what an unticked row means, so a blank one doesn't read as a
    /// failed session.
    ///
    /// A checkmark means MockTab recognized that activity — not that the row
    /// is a requirement. Rows stay blank for controls the tablet doesn't
    /// have, and for controls whose reports we can't read yet, which on an
    /// unsupported device is most of them. Everything that arrives is
    /// recorded either way.
    /// Both lines stay in the layout so the sheet never changes height. The
    /// second would otherwise appear a fraction of a second in, once the probe
    /// has enough reports to say — a visible lurch. Only emphasis changes.
    var checklistFootnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(
                localized: "Blank rows are fine. Everything is saved.",
                comment: "Footnote under the data collection checklist explaining that unticked rows are not a failure"))
            Text(String(
                localized: "MockTab can't read some of this yet. The file helps.",
                comment: "Shown during collection when reports arrived that no decoder could read"))
            .foregroundStyle(hasUndecodedTraffic ? AnyShapeStyle(.secondary) : AnyShapeStyle(.clear))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: hasUndecodedTraffic)
            .accessibilityHidden(!hasUndecodedTraffic)
        }
        .appFont(.caption)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// One row of the "do whatever your tablet supports" checklist.
    ///
    /// Gates nothing — Done stays enabled, and the stepped-progress version of
    /// this sheet was abandoned for being tedious. The point is that a tester
    /// sees the pen row still blank and retries while the tablet is in their
    /// hands; on issue #14 no session ever caught the pen, and nothing said
    /// so.
    enum CaptureChecklistItem: Hashable, CaseIterable {
        case penTip, penButtons, eraser, tabletButtons, ringOrStrip, fingerTouch

        /// The registry features the row shows. Pen buttons have none.
        var features: [TabletFeature] {
            switch self {
            case .penTip: return [.penPosition, .pressure]
            case .penButtons: return []
            case .eraser: return [.eraser]
            case .tabletButtons: return [.tabletButtons]
            case .ringOrStrip: return [.ring, .strips, .dial]
            case .fingerTouch: return [.touch]
            }
        }
    }

    /// Rows for features no recording or hardware has shown on this model
    /// come first, and rows for features it lacks come last. Unknown tablets
    /// keep the default order. Set once per session, so rows never move while
    /// they tick.
    static func checklistOrder(vendorID: Int, productID: Int) -> [CaptureChecklistItem] {
        let all = CaptureChecklistItem.allCases
        guard WacomDeviceRegistry.vendorIDs.contains(vendorID),
            let spec = WacomDeviceRegistry.spec(for: WacomDeviceRegistry.canonicalProductID(for: productID))
        else { return all }
        let evidence = spec.evidence
        func rank(_ item: CaptureChecklistItem) -> Int {
            // Pen buttons have no evidence of their own; they go where the pen goes.
            if item == .penButtons { return evidence[.penPosition] == nil ? 2 : 1 }
            guard let weakest = item.features.compactMap({ evidence[$0]?.level }).min() else { return 2 }
            return weakest < .recorded ? 0 : 1
        }
        return all.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    func instruction(for item: CaptureChecklistItem) -> some View {
        switch item {
        case .penTip:
            return instruction("pencil.tip", String(localized: "Tap the pen’s tip to the tablet, then lift", comment: "Device data collection instruction: pen tip"), item)
        case .penButtons:
            return instruction("button.horizontal", String(localized: "Hold down each button on the pen", comment: "Device data collection instruction: pen buttons"), item)
        case .eraser:
            return instruction("eraser.line.dashed", String(localized: "Touch the pen's eraser end to the tablet", comment: "Device data collection instruction: eraser"), item)
        case .tabletButtons:
            return instruction("rectangle.grid.2x2", String(localized: "Press each button on the tablet", comment: "Device data collection instruction: tablet buttons"), item)
        case .ringOrStrip:
            return instruction("circle.dashed", String(localized: "Slide a finger around any ring or strip", comment: "Device data collection instruction: touch ring/strip"), item)
        case .fingerTouch:
            return instruction("hand.draw", String(localized: "Drag one finger, then pinch with two", comment: "Device data collection instruction: capacitive finger touch (only meaningful on touch-capable tablets)"), item)
        }
    }

    /// Fold probe state into `satisfied`. Only ever inserts — see
    /// `satisfied` for why rows latch.
    func refreshChecklist() {
        guard engine.isRunning else { return }
        let seen = CaptureActivityProbe.snapshot()
        for row in seen.confirmed() {
            switch row {
            case .penTip: satisfied.insert(.penTip)
            case .penButtons: satisfied.insert(.penButtons)
            case .eraser: satisfied.insert(.eraser)
            case .tabletButtons: satisfied.insert(.tabletButtons)
            case .ringOrStrip: satisfied.insert(.ringOrStrip)
            }
        }
        // Finger touch is counted by the injection pipeline rather than the
        // decoder, and is likewise zeroed per session by `startCapture`.
        if TouchPipelineProbe.snapshot().contactsDecoded > 0 {
            satisfied.insert(.fingerTouch)
        }
        hasUndecodedTraffic = seen.hasUndecodedTraffic
    }

    func instruction(
        _ icon: String, _ text: String, _ item: CaptureChecklistItem
    ) -> some View {
        let done = satisfied.contains(item)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Overlaid so a tall glyph can't change the row's height.
            Text(verbatim: " ")
                .appFont(.body)
                .frame(width: 18)
                .overlay {
                    Image(systemName: done ? "checkmark.circle.fill" : icon)
                        .appFont(.body)
                        .foregroundStyle(done ? Color.green : Color.secondary)
                }
                .accessibilityHidden(true)
            Text(text)
                .appFont(.body)
                .foregroundStyle(done ? .secondary : .primary)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: done)
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            done
                ? String(localized: "Recorded", comment: "Accessibility value for a satisfied data-collection checklist row")
                : String(localized: "Not yet recorded", comment: "Accessibility value for a data-collection checklist row with no matching activity yet"))
    }
}
