// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import SwiftUI
import TabletKit

/// Open-ended device data collection sheet.
///
/// Shows the user a static list of actions to perform, records all HID
/// reports via discovery mode, and lets the user click Done when finished.
/// No step gating, no per-row buttons — the engine captures whatever arrives.
///
/// Output is a compact JSON summary (~5–15 KB) produced by
/// `CaptureEngine.buildDiscoveryResult`: which byte positions varied and what
/// values they took. Not a raw hex firehose.
struct CaptureGuideView: View {

    @ObservedObject var engine: CaptureEngine
    @ObservedObject var tabletManager: TabletManager
    let productID: Int
    let onDismiss: () -> Void
    /// Stop and flush the paired raw capture, returning its file so it can go
    /// into the package. Owned by the presenting view, not this sheet — see
    /// `DiagnosticSession`. Nil when no raw capture is running.
    var onFinalizeRawCapture: (() -> URL?)? = nil

    // MARK: - State

    @State private var showCancelConfirm = false
    @State private var showInitControl = false
    /// Legacy Wacom pen default (feature report 0x02, value 2). Modern
    /// HID_GENERIC devices use a descriptor-specific report ID instead — see
    /// `CaptureInitReport` — so these are a starting point, not a guarantee.
    @State private var initReportIDText = "0x02"
    @State private var initValueText = "0x02"
    /// Device-side session state; see `CaptureSessionCoordinator`.
    @StateObject private var coordinator: CaptureSessionCoordinator

    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    private var isComplete: Bool { coordinator.savedURL != nil }
    private var startupError: String? { coordinator.startupError }
    private var resolvedInfo: CaptureDeviceInfo? { coordinator.resolvedInfo }
    /// Rows satisfied this session. Latching — the row records what was
    /// captured, so lifting the pen must not un-tick "tap the pen's tip".
    @State private var satisfied: Set<CaptureChecklistItem> = []
    @State private var checklistOrder = CaptureChecklistItem.allCases
    /// Traffic arrived that no decoder could read. Surfaced because it's the
    /// opposite of bad news — on an unsupported device it's the most valuable
    /// thing in the file, yet leaves every row above blank.
    @State private var hasUndecodedTraffic = false
    /// Polls the activity probes for the checklist. A plain Timer rather
    /// than a `Timer.publish` computed in `body`: that form hands `.onReceive`
    /// a brand-new publisher on every redraw, restarting the countdown each
    /// time, so a frequently-redrawn sheet may never tick.
    @State private var checklistTimer: Timer? = nil

    init(
        engine: CaptureEngine, tabletManager: TabletManager, productID: Int,
        onDismiss: @escaping () -> Void, onFinalizeRawCapture: (() -> URL?)? = nil
    ) {
        self.engine = engine
        self.tabletManager = tabletManager
        self.productID = productID
        self.onDismiss = onDismiss
        self.onFinalizeRawCapture = onFinalizeRawCapture
        _coordinator = StateObject(
            wrappedValue: CaptureSessionCoordinator(
                engine: engine, tabletManager: tabletManager, productID: productID,
                onFinalizeRawCapture: onFinalizeRawCapture))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isComplete, let url = coordinator.savedURL {
                completionView(url: url)
            } else {
                recordingView
            }
            Divider()
            footer
        }
        .frame(width: 460)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showInitControl)
        .alert(String(localized: "Stop Collecting?", comment: "Data collection confirmation alert title"), isPresented: $showCancelConfirm) {
            Button("Keep Collecting", role: .cancel) {}
            Button(String(localized: "Stop and Discard", comment: "Destructive button that ends the in-progress data collection session and discards its data"), role: .destructive) {
                engine.cancelDiscovery()
                onDismiss()
            }
        } message: {
            Text(String(localized: "Nothing collected so far will be saved.", comment: "Data collection alert message"))
        }
        .onAppear { startCollection() }
        // Tied to the view rather than to each of the three exit paths
        // (Done, Cancel, auto-finish) — the sheet always disappears.
        .onDisappear {
            coordinator.stop()
            checklistTimer?.invalidate()
            checklistTimer = nil
        }
        // A tablet's interfaces don't all attach at once — see
        // `CaptureEngine.addInterface`. `DeviceContext` is nested inside
        // `TabletManager.contexts`, so its changes don't reach this view
        // through `tabletManager` alone; subscribe to the context itself.
        //
        // Hopped rather than run inline: `objectWillChange` fires from the
        // `@Published` property's `willSet`, so a synchronous handler reads
        // `captureInterfaces` as it was *before* the interface was appended,
        // finds nothing new, and never hears about that append again.
        // (Verified in isolation: a sink on `objectWillChange` observes counts
        // 0 and 1 across two appends.) The picker this replaced was immune
        // because SwiftUI re-evaluates `body` after the mutation, not during.
        .onReceive(coordinator.contextChanges) { _ in
            Task { @MainActor in coordinator.adoptNewInterfaces() }
        }
        .onChange(of: engine.isSendingInitReport) { sending in
            trackSendingIndicator(isSending: sending)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up.on.square")
                .appFont(.title2)
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Collect Device Data", comment: "Sheet title: device data collection"))
                    .appFont(.headline)
                Text(subtitle)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Whether the tablet is one MockTab already has a spec for.
    ///
    /// Must be asked the same way `deviceInfo()` asks it — off the resolved
    /// device, and only when the vendor is Wacom. Consulting the registry with
    /// the raw `contexts` key returns a match for a product ID of 0, which is
    /// how a Pro-One came to be called "PenPartner" (issue #2). Getting it
    /// wrong here tells a user whose tablet *isn't* recognized that the sheet
    /// is for investigating a problem with a supported one.
    private var isRecognizedTablet: Bool {
        guard let info = resolvedInfo, info.vendorID == CaptureSessionCoordinator.wacomVendorID else { return false }
        return WacomDeviceRegistry.spec(for: info.productID) != nil
    }

    private var subtitle: String {
        isRecognizedTablet
            ? String(localized: "Records what your tablet sends to help track down a problem.", comment: "Subtitle for device data collection when tablet is already supported")
            : String(localized: "Collects details about your tablet's behavior for analysis.", comment: "Subtitle for device data collection when tablet is not yet supported")
    }

    // MARK: - Recording view

    private var recordingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(String(localized: "Do whatever your tablet supports, then click Done:", comment: "Instruction text for device data collection"))
                        .appFont(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 12)

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(checklistOrder, id: \.self) { item in
                            instruction(for: item)
                        }
                    }
                    .padding(.horizontal, 20)

                    checklistFootnote
                        .padding(.horizontal, 20)
                        .padding(.top, 10)

                    deviceModeInitControl
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 16)
                }
            }
            // Sizes to fit its content (so the sheet grows with it, and the
            // instructions never need to scroll) up to a cap — a safety net
            // for edge cases like a long run of logged init-report attempts,
            // not something the common case should ever reach.
            .frame(maxHeight: 480)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    recordingDot
                        .frame(width: 7, height: 7)
                    Text(statusLine)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                // Without this, a failure after collection ends — a Desktop
                // write blocked by privacy settings being the likely one —
                // left the sheet sitting there with no file and no
                // explanation, indistinguishable from still working.
                if let problem = startupError ?? engine.lastError {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .appFont(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }


    private var statusLine: String {
        if !coordinator.deviceIsConnected {
            return String(
                localized: "Not connected (\(String(format: "0x%04X", productID)))",
                comment: "HID discovery: shown instead of the event counter when the target device isn't currently connected"
            )
        }
        if startupError != nil {
            return String(
                localized: "Not collecting",
                comment: "HID discovery: status shown when collection could not be started")
        }
        return engine.isRunning
            ? String(localized: "\(engine.discoverySampleCount) events recorded", comment: "HID discovery: number of events captured during device discovery")
            : String(localized: "Starting…", comment: "HID discovery: status indicator while discovery is starting")
    }


    // MARK: - Device mode init (advanced)

    /// Collapsed-by-default control for writing a device-mode init feature
    /// report mid-session.
    ///
    /// Deliberately supplemental rather than a gating step: collection is
    /// already running when this appears, so a tester can send a write and
    /// watch the event counter for a response without restarting. Most devices
    /// never need it — hence collapsed, and labelled advanced.
    /// Whether the in-flight spinner and its "waiting on the tablet" line are
    /// shown. Tracks `engine.isSendingInitReport`, but only after
    /// `sendingIndicatorDelay` — see `trackSendingIndicator`.
    @State private var showSendingIndicator = false
    /// Task running the delay, cancelled when a write finishes inside it.
    @State private var sendingIndicatorTask: Task<Void, Never>? = nil

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
    private static let sendingIndicatorDelay = Duration.milliseconds(500)

    /// Show the indicator only if the write is still in flight after the
    /// delay, and hide it the moment the write finishes.
    private func trackSendingIndicator(isSending: Bool) {
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

    private var deviceModeInitControl: some View {
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
                            .controlSize(.small)
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
    private func parseHexByte(_ text: String) -> Int? {
        var s = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("0x") { s = String(s.dropFirst(2)) }
        guard let v = Int(s, radix: 16), (0...255).contains(v) else { return nil }
        return v
    }

    private func sendInitReport() {
        guard let reportID = parseHexByte(initReportIDText),
              let value = parseHexByte(initValueText)
        else { return }
        coordinator.sendModeSwitch(reportID: reportID, value: value)
    }

    /// Recording-status indicator dot. When Differentiate-Without-Color is
    /// enabled, uses an SF Symbol that distinguishes state by glyph
    /// (filled-vs-hollow record glyph) in addition to red-vs-gray color.
    @ViewBuilder
    private var recordingDot: some View {
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
    private var checklistFootnote: some View {
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
    private static func checklistOrder(vendorID: Int, productID: Int) -> [CaptureChecklistItem] {
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

    private func instruction(for item: CaptureChecklistItem) -> some View {
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
    private func refreshChecklist() {
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
        // decoder, and is likewise zeroed per session by `startDiscovery`.
        if TouchPipelineProbe.snapshot().contactsDecoded > 0 {
            satisfied.insert(.fingerTouch)
        }
        hasUndecodedTraffic = seen.hasUndecodedTraffic
    }

    private func instruction(
        _ icon: String, _ text: String, _ item: CaptureChecklistItem
    ) -> some View {
        let done = satisfied.contains(item)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : icon)
                .appFont(.body)
                .foregroundStyle(done ? Color.green : Color.secondary)
                .frame(width: 18)
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

    // MARK: - Completion

    private func completionView(url: URL) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .appFont(size: 44)
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text(String(localized: "Collection Complete", comment: "Data collection completion status"))
                .appFont(.title3)
                .fontWeight(.semibold)

            HStack(spacing: 8) {
                Button {
                    openGitHubIssue(url: url)
                } label: {
                    Label(String(localized: "Open GitHub Issue…", comment: "Button label: open a pre-filled GitHub issue for device support"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                emailButton(url: url)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label(String(localized: "Show in Finder", comment: "Button label: open data collection file in Finder"), systemImage: "doc.badge.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(String(localized: "On GitHub, drag the file into the form.", comment: "Caption on the data-collection completion screen"))
                .appFont(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            // Share extensions take only the file, so the address has to be
            // somewhere the user can see and copy.
            if !Self.defaultMailIsAppleMail {
                Text(String(
                    localized: "Email goes to \(Self.reportAddress)",
                    comment: "Caption naming the address for emailed diagnostics"))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Open a pre-filled GitHub issue containing the capture JSON.
    /// Falls back to a short body asking the user to drag-attach the file when
    /// the inline JSON would exceed GitHub's URL form length limit.
    private func openGitHubIssue(url: URL) {
        // Identify the device the way the capture file does, not the way the
        // app guessed. `productID` here is the contexts key, and the old title
        // said "Wacom" regardless of who actually made the tablet.
        let pidHex = resolvedInfo.map { String(format: "0x%04X", $0.productID) }
            ?? String(format: "0x%04X", productID)
        let vidHex = resolvedInfo.map { $0.vendorIDHex } ?? "unknown"
        let deviceLabel = resolvedInfo?.name ?? pidHex
        let title = "Device support: \(deviceLabel) (\(vidHex)/\(pidHex))"
        let baseURL = "https://github.com/cyzor/tablet-driver/issues/new"
        let json = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        // These fill the form's **Capture data** field, so they lead with the
        // JSON block rather than restating the device — model, connection, and
        // macOS version have their own fields.
        let inlineBody = """
        <!-- Captured by MockTab — please leave the JSON block intact -->
        <!-- Device: \(deviceLabel) — \(vidHex)/\(pidHex) — \(url.lastPathComponent) -->

        ```json
        \(json)
        ```
        """

        let fallbackBody = """
        <!-- Captured by MockTab -->
        <!-- Device: \(deviceLabel) — \(vidHex)/\(pidHex) -->

        **Attach `\(url.lastPathComponent)`:** drag it here from the Finder window MockTab opened.
        """

        // Name the issue form explicitly. Without `template`, GitHub shows the
        // template chooser and discards everything prefilled here the moment the
        // user picks one — which is the only path Contributing.md documents.
        // With it, prefill is keyed by the form's field `id`s, not `body`.
        var comps = URLComponents(string: baseURL)!
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var items = [
            URLQueryItem(name: "template", value: "device-support.yml"),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "labels", value: "device-support"),
            URLQueryItem(name: "model", value: deviceLabel),
            URLQueryItem(
                name: "macos", value: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            URLQueryItem(name: "capture", value: inlineBody),
        ]
        // The dropdown only accepts one of its declared options; anything else
        // makes GitHub drop the whole prefill, so leave it unset when unsure.
        if let transport = resolvedInfo?.transport,
            Self.connectionOptions.contains(transport)
        {
            items.append(URLQueryItem(name: "connection", value: transport))
        }
        comps.queryItems = items

        // A zip can't be inlined, and /issues/new is served server-side, so the
        // URL must stay under typical limits; 7000 leaves headroom under 8 KB.
        if json.isEmpty || (comps.url?.absoluteString.count ?? 0) > 7000 {
            comps.queryItems = items.map {
                $0.name == "capture" ? URLQueryItem(name: "capture", value: fallbackBody) : $0
            }
        }

        if let u = comps.url {
            NSWorkspace.shared.open(u)
        }
        // The form can't take the file itself; put it where the user can grab it.
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Sends the capture privately: no account, nothing posted. Apple Mail
    /// takes recipient, subject, and attachment directly. Other mail apps
    /// (MailMate, Outlook) take attachments only through their share
    /// extensions, which carry no recipient, so there the button is the
    /// system share menu and the address rides in the message.
    @ViewBuilder
    private func emailButton(url: URL) -> some View {
        let label = Label(
            String(localized: "Email…", comment: "Button label: send the data collection file by email"),
            systemImage: "envelope")
        if Self.defaultMailIsAppleMail {
            Button { composeInAppleMail(url: url) } label: { label }
        } else {
            ShareLink(
                item: url,
                subject: Text(emailSubject),
                message: Text(String(
                    localized: "Send to \(Self.reportAddress)",
                    comment: "Line in the diagnostics email body naming the address to send it to")
                    + "\n\n" + emailBody)
            ) { label }
        }
    }

    /// The compose service claims it can mail for any default client, then
    /// hands other clients only address, subject, and text; the file is lost.
    /// So choose by the default client itself.
    private static var defaultMailIsAppleMail: Bool {
        guard let mailto = URL(string: "mailto:"),
            let app = NSWorkspace.shared.urlForApplication(toOpen: mailto)
        else { return false }
        return Bundle(url: app)?.bundleIdentifier == "com.apple.mail"
    }

    private var emailSubject: String {
        let pidHex = resolvedInfo.map { String(format: "0x%04X", $0.productID) }
            ?? String(format: "0x%04X", productID)
        return "MockTab data: \(resolvedInfo?.name ?? pidHex) (\(pidHex))"
    }

    /// Prompt, room to answer, then the facts a reply would otherwise ask for.
    private var emailBody: String {
        let prompt = String(
            localized: "How well is MockTab working for you? Please describe your experience and what needs to improve.\n\n",
            comment: "Prompt placed in the body of the diagnostics email")
        let device = resolvedInfo.map {
            "\($0.name) (\($0.vendorIDHex)/" + String(format: "0x%04X", $0.productID) + ")"
                + ($0.transport.map { ", \($0)" } ?? "")
        } ?? String(format: "0x%04X", productID)
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return prompt + "\n\n—\n"
            + "Tablet: \(device)\n"
            + "MockTab \(version) (\(build)), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)\n"
    }

    private func composeInAppleMail(url: URL) {
        guard let service = NSSharingService(named: .composeEmail) else { return }
        service.recipients = [Self.reportAddress]
        service.subject = emailSubject
        service.perform(withItems: [emailBody, url])
    }

    /// Assembled at runtime so address scrapers reading the source find nothing.
    private static let reportAddress = ["info", "mocktab.org"].joined(separator: "@")

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if !isComplete {
                Button("Cancel") {
                    if engine.isRunning { showCancelConfirm = true } else { onDismiss() }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isComplete {
                Button("Done") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { engine.finishDiscovery() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!engine.isRunning)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// The `connection` dropdown options in `.github/ISSUE_TEMPLATE/device-support.yml`.
    /// Prefilling a value the form doesn't offer makes GitHub discard the rest.
    private static let connectionOptions: Set<String> = [
        "USB", "Bluetooth", "USB wireless dongle",
    ]

    // MARK: - Collection

    private func startCollection() {
        guard coordinator.start(), let info = coordinator.resolvedInfo else { return }
        checklistOrder = Self.checklistOrder(vendorID: info.vendorID, productID: info.productID)
        if let reportID = coordinator.autoDetectedModeReportID {
            // Deliberately does NOT expand the section. Pre-filling the field
            // is the useful part; opening it put two text fields on screen at
            // first layout, and AppKit handed first responder to the Report
            // field — instantiating the shared field editor, which drew a
            // blank panel for a frame and then zoomed its focus ring in. An
            // experimental control almost nobody touches should not take the
            // keyboard, and the value is waiting for anyone who opens it.
            initReportIDText = String(format: "0x%02X", reportID)
        }
        // The checklist reads two lock-guarded probes — cheap enough to poll
        // often, and it needs to be: a row that ticks seconds after the user
        // presses the button reads as unresponsive rather than as feedback.
        checklistTimer?.invalidate()
        checklistTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in refreshChecklist() }
        }
    }
}
