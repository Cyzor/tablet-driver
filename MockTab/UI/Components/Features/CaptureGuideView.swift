// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import IOKit.hid
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

    // MARK: - State

    @State private var savedURL: URL? = nil
    @State private var showCancelConfirm = false
    @State private var showInitControl = false
    /// Legacy Wacom pen default (feature report 0x02, value 2). Modern
    /// HID_GENERIC devices use a descriptor-specific report ID instead — see
    /// `CaptureInitReport` — so these are a starting point, not a guarantee.
    @State private var initReportIDText = "0x02"
    @State private var initValueText = "0x02"
    /// Set when the device's own descriptor names a feature report carrying a
    /// mode-switch usage — see `DescriptorLayout.modeSwitchUsages` in TabletKit
    /// — in which case the report ID
    /// is correct rather than a guess. `nil` on every classic Wacom / Xencelabs
    /// device we've tested, since their descriptors declare neither usage; the
    /// 0x02 default above remains the fallback for those.
    @State private var autoDetectedModeReportID: UInt8? = nil
    /// The interface whose descriptor declared `autoDetectedModeReportID`, so
    /// the Send button writes to that one rather than to the primary.
    ///
    /// These differ on exactly the hardware the control exists for: a
    /// multitouch interface carries the standard Device Mode usage while the
    /// pen interface carries Wacom's vendor DATAMODE, and a mode-switch write
    /// addressed to the wrong sibling is simply NAK'd — indistinguishable, to
    /// the tester, from the device not supporting the report at all.
    @State private var modeSwitchDevice: IOHIDDevice? = nil

    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    private var isComplete: Bool { savedURL != nil }

    /// Set when the session can't start at all (no device, or a device that
    /// won't tell us what it is). Distinct from `engine.lastError`, which
    /// covers failures after collection has begun.
    @State private var startupError: String? = nil

    /// The device identity actually written into the capture file, kept so the
    /// issue-submission text describes the same hardware.
    @State private var resolvedInfo: CaptureDeviceInfo? = nil

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isComplete, let url = savedURL {
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
        .onReceive(contextChanges) { _ in
            Task { @MainActor in adoptNewInterfaces() }
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
        guard let info = resolvedInfo, info.vendorID == Self.wacomVendorID else { return false }
        return WacomDeviceRegistry.spec(for: info.productID) != nil
    }

    private var subtitle: String {
        isRecognizedTablet
            ? String(localized: "Records what your tablet sends, to help track down a problem.", comment: "Subtitle for device data collection when tablet is already supported")
            : String(localized: "Records details about your tablet for analysis.", comment: "Subtitle for device data collection when tablet is not yet supported")
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
                        instruction("pencil.tip",  String(localized: "Tap the pen’s tip to the tablet, then lift", comment: "Device data collection instruction: pen tip"))
                        instruction("button.horizontal",      String(localized: "Hold down each button on the pen", comment: "Device data collection instruction: pen buttons"))
                        instruction("eraser.line.dashed", String(localized: "Touch the pen's eraser end to the tablet", comment: "Device data collection instruction: eraser"))
                        instruction("rectangle.grid.2x2",    String(localized: "Press each button on the tablet", comment: "Device data collection instruction: tablet buttons"))
                        instruction("circle.dashed",          String(localized: "Slide a finger around any ring or strip", comment: "Device data collection instruction: touch ring/strip"))
                        instruction("hand.draw",              String(localized: "Drag one finger across the tablet, then pinch with two", comment: "Device data collection instruction: capacitive finger touch (only meaningful on touch-capable tablets)"))
                    }
                    .padding(.horizontal, 20)

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

    /// `deviceInfo()` (and therefore collection) needs a currently-connected
    /// `IOHIDDevice` for `productID`. Distinguishing "no such device" from the
    /// ordinary brief startup lag matters: without it, a device that dropped
    /// its connection — or was never found under this productID — reads
    /// identically to "still starting", and stays that way forever with no
    /// way to tell why.
    private var deviceIsConnected: Bool {
        tabletManager.contexts[productID]?.hidDevice != nil
    }

    private var statusLine: String {
        if !deviceIsConnected {
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

    // MARK: - Interfaces

    /// Every interface of this tablet worth listening to, primary first.
    ///
    /// The session records all of them at once rather than asking which one to
    /// use. A tablet whose pen and touch data arrive on separate HID
    /// interfaces (PTH-850 — see `DeviceContext.hidDevice`'s doc comment)
    /// otherwise yields a file covering half the hardware, and *which* half is
    /// enumeration-order luck. Nobody submitting a capture for an unrecognized
    /// device can be expected to know which interface carries the traffic
    /// worth having — that judgment is the whole point of reading the file
    /// afterward, so it can't be a precondition for producing one.
    ///
    /// `hidDevice` leads when it's among the listed interfaces: it's the one
    /// the driver reads pen reports from, so its data is what fills the
    /// top-level block of the capture file that existing triage tooling reads.
    ///
    /// It is *not* promoted when it was left off that list. `hidDevice` is
    /// claimed by the first `.driver`-routed interface whether or not the
    /// driver installed a report callback on it, while `captureInterfaces`
    /// deliberately omits interfaces that got none (see
    /// `TabletManager.offerForCapture`). Leading with one of those would put
    /// a permanently empty block at the top level of the file — which is
    /// exactly the block a `captureVersion` 6 reader treats as the whole
    /// capture — while the real traffic sat in a section it doesn't read.
    ///
    /// The bare `hidDevice` fallback remains for a device whose interfaces
    /// never got listed at all.
    private func captureInterfaces() -> [IOHIDDevice] {
        let context = tabletManager.contexts[productID]
        let listed = (context?.captureInterfaces ?? []).compactMap(\.device)
        guard !listed.isEmpty else { return [context?.hidDevice].compactMap { $0 } }
        guard let primary = context?.hidDevice, listed.contains(where: { $0 === primary })
        else { return listed }
        return [primary] + listed.filter { $0 !== primary }
    }

    /// This tablet's touch configuration, for the capture file.
    ///
    /// Nil for a device whose spec declares no finger touch: these settings
    /// exist on every `TabletSettings` but do nothing without a touch sensor,
    /// and recording them there would invite reading a meaningless `false` as
    /// a cause.
    private func touchSettingsSnapshot() -> DiscoveryTouchSettings? {
        guard let settings = tabletManager.contexts[productID]?.settings,
            WacomDeviceRegistry.spec(for: productID)?.hasFingerTouch == true
        else { return nil }
        return DiscoveryTouchSettings(
            touchEnabled: settings.touchEnabled,
            tapToClick: settings.tapToClick,
            twoFingerScroll: settings.twoFingerScroll,
            pinchZoom: settings.pinchZoomEnabled,
            twoFingerScrollMomentum: settings.twoFingerScrollMomentum,
            reverseScrollDirection: settings.reverseScrollDirection,
            rotateEnabled: settings.rotateEnabled,
            smartZoom: settings.smartZoomEnabled,
            touchOnsetDelayMs: settings.touchOnsetDelayMs,
            sensitivity: settings.touchSensitivity,
            areaX: settings.touchAreaX,
            areaY: settings.touchAreaY,
            areaWidth: settings.touchAreaWidth,
            areaHeight: settings.touchAreaHeight)
    }

    /// Change notifications from this tablet's `DeviceContext`, or a publisher
    /// that never fires when there's no context to watch.
    private var contextChanges: ObservableObjectPublisher {
        tabletManager.contexts[productID]?.objectWillChange ?? Self.silentChanges
    }

    private static let silentChanges = ObservableObjectPublisher()

    /// Fold any interface that has attached since collection started into the
    /// running session, keeping what's already been gathered.
    ///
    /// Cheap enough to run on every context change: it does nothing unless an
    /// interface is genuinely new to the session, which happens once or twice
    /// in a device's lifetime.
    private func adoptNewInterfaces() {
        guard engine.isRunning else { return }
        for device in captureInterfaces() where !engine.isRecording(device) {
            guard let info = deviceInfo(device: device) else { continue }
            engine.addInterface(device: device, deviceInfo: info)
        }
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
                Text(String(localized: "Try sending a signal to awaken an unresponsive tablet.  Some stay quiet unless prompted to answer.", comment: "Explanation of the advanced device mode init control in device data collection"))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let reportID = autoDetectedModeReportID {
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
                    Text(String(localized: "Waiting on the tablet. This can take a few seconds over Bluetooth.", comment: "Status shown while a device mode init write is in flight"))
                        .appFont(.caption)
                        .foregroundStyle(.tertiary)
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
        // The interface whose descriptor declared the report when one did —
        // see `modeSwitchDevice`. Otherwise the primary, which is the right
        // target for the hand-entered legacy 0x02 case this control started as.
        guard let reportID = parseHexByte(initReportIDText),
              let value = parseHexByte(initValueText),
              let dev = modeSwitchDevice ?? tabletManager.contexts[productID]?.hidDevice
        else { return }
        engine.sendInitReport(device: dev, reportID: reportID, value: value)
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

    @ViewBuilder
    private func instruction(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .appFont(.body)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .appFont(.body)
        }
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

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label(String(localized: "Show in Finder", comment: "Button label: open data collection file in Finder"), systemImage: "doc.badge.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(String(localized: "The issue comes pre-filled with your tablet's data. If it's too big for the form, drag the file in from Finder.", comment: "Caption on the data-collection completion screen"))
                .appFont(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
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

        The capture JSON is too large to fit in this form. Please drag
        `\(url.lastPathComponent)` from Finder into the comment box to attach it.
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

        // GitHub serves /issues/new server-side; URL length needs to stay below
        // typical browser/server limits. 7000 leaves headroom under the 8 KB mark.
        if let u = comps.url, u.absoluteString.count > 7000 {
            comps.queryItems = items.map {
                $0.name == "capture" ? URLQueryItem(name: "capture", value: fallbackBody) : $0
            }
        }

        if let u = comps.url {
            NSWorkspace.shared.open(u)
        }
    }

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

    // MARK: - Collection logic

    private func startCollection() {
        // Each interface is described from its own `IOHIDDevice`: the usage
        // page and the report descriptor differ between them, and those are
        // exactly what the capture file needs in order to say which interface
        // a report came from and whether that interface declared it.
        let interfaces = captureInterfaces()
        guard !interfaces.isEmpty else {
            startupError = String(
                localized: "That tablet isn't connected anymore.",
                comment: "Capture error shown when the target device disappeared before collection started")
            return
        }
        let targets = interfaces.compactMap { device in
            deviceInfo(device: device).map { (device, $0) }
        }
        // Only the failure to describe *any* interface stops collection. A
        // sibling that won't name itself is dropped quietly: the tablet is
        // still fully capturable through the interfaces that will, and its
        // absence from the file is visible there.
        guard let primary = targets.first else {
            startupError = String(
                localized: "This tablet doesn't report a usable USB ID, so a recording from it couldn't identify it.",
                comment: "Capture error shown when the device's USB identifiers are missing or zero")
            return
        }
        resolvedInfo = primary.1
        // Cleared first: a device that reconnected without the interface that
        // declared the report must not leave the previous one's ID pre-filled.
        startupError = nil
        applyAutoDetectedModeSwitch(from: targets)

        engine.onDiscoveryComplete = { result in
            Task { @MainActor in
                if let url = engine.exportDiscoveryJSON(result: result) {
                    savedURL = url
                }
            }
        }
        engine.startDiscovery(
            devices: targets, duration: 3600, touchSettings: touchSettingsSnapshot(),
            bluetoothAddressCandidate: tabletManager.contexts[productID]?.bluetoothAddressCandidate)
    }

    /// Parses the device's own raw descriptor bytes for a mode-switch feature
    /// report and pre-fills the report field with it when found — replacing
    /// the 0x02 legacy guess with the ID this specific device actually uses.
    /// Also expands the (otherwise collapsed) advanced control, since a
    /// detected report makes it worth the tester's attention rather than an
    /// edge case to dig for.
    ///
    /// The usage list lives in TabletKit beside the lookup
    /// (`DescriptorLayout.modeSwitchUsages`) because `WacomFallbackDevice`
    /// consults the same one when initializing an unrecognized device. A
    /// second copy here would let the tester's pre-filled value and the
    /// driver's actual write drift apart, which is the one discrepancy this
    /// screen must never introduce.
    ///
    /// Runs once, before the tester can have typed anything, so it never
    /// clobbers a manual edit. No classic Wacom or Xencelabs descriptor tested
    /// so far declares either usage, so this still does nothing on all of them.
    private func applyAutoDetectedModeSwitch(from targets: [(IOHIDDevice, CaptureDeviceInfo)]) {
        for (device, info) in targets {
            guard let hex = info.parsedDescriptor?.rawHex,
                  let layout = try? HIDReportDescriptorParser.parse(hex: hex),
                  let reportID = layout.modeSwitchFeatureReportID()
            else { continue }

            autoDetectedModeReportID = reportID
            modeSwitchDevice = device
            initReportIDText = String(format: "0x%02X", reportID)
            showInitControl = true
            return
        }
    }

    /// Wacom's USB vendor ID. Only devices reporting it may be described using
    /// the Wacom device registry.
    private static let wacomVendorID = 0x056A

    /// The `connection` dropdown options in `.github/ISSUE_TEMPLATE/device-support.yml`.
    /// Prefilling a value the form doesn't offer makes GitHub discard the rest.
    private static let connectionOptions: Set<String> = [
        "USB", "Bluetooth", "USB wireless dongle",
    ]

    /// Build the capture header from the **device itself**, not from what the
    /// app guessed about it.
    ///
    /// Both IDs used to come from the wrong place: the vendor ID fell back to
    /// Wacom's when unreadable, and the product ID was the `contexts` dictionary
    /// key rather than the device's own. A submitted capture (issue #2) came
    /// back describing a Pro-One PDT6002 as vendor `0x056A`, product `0x0000`,
    /// name "PenPartner" — three fabrications in a header whose entire job is
    /// to say what the hardware is. Read both off the `IOHIDDevice`, and only
    /// consult the Wacom registry once the vendor ID says Wacom.
    ///
    /// Deliberately free of side effects, unlike the single-device version it
    /// replaced: it now runs once per interface, and a sibling that can't name
    /// itself is a dropped interface rather than a failed session. Deciding
    /// that is the caller's job — see `startCollection`, which raises the
    /// error only when *no* interface could be described.
    private func deviceInfo(device dev: IOHIDDevice) -> CaptureDeviceInfo? {
        let vendorID = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int
        let deviceProductID = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int

        // A capture whose header can't name the hardware can't become a
        // registry entry — TabletKit/tools/triage_discovery.py rejects exactly this.
        // Better to say so now than after an hour of collecting.
        guard let vendorID, let deviceProductID, deviceProductID != 0 else { return nil }

        let manufacturer = IOHIDDeviceGetProperty(dev, kIOHIDManufacturerKey as CFString) as? String
        let transport    = IOHIDDeviceGetProperty(dev, kIOHIDTransportKey    as CFString) as? String
        // Device serial is deliberately not read: capture files are pasted into
        // public issues, and the serial adds nothing to decoding.
        let productString = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String
        let locationID   = (IOHIDDeviceGetProperty(dev, kIOHIDLocationIDKey  as CFString) as? Int)
            .map { String(format: "0x%08X", $0) }
        let parsed = HIDDescriptorReader.read(dev)

        let registryName =
            vendorID == Self.wacomVendorID
            ? WacomDeviceRegistry.spec(for: deviceProductID)?.name : nil
        let name =
            registryName
            ?? TabletManager.deviceName(
                forProductID: deviceProductID, vendorID: vendorID, productString: productString)

        return CaptureDeviceInfo(
            vendorID: vendorID,
            productID: deviceProductID,
            name: name,
            locationID: locationID,
            manufacturer: manufacturer,
            transport: transport,
            parsedDescriptor: parsed,
            usagePage: hidIntProperty(dev, kIOHIDPrimaryUsagePageKey),
            usage: hidIntProperty(dev, kIOHIDPrimaryUsageKey)
        )
    }
}
