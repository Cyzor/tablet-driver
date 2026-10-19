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
    @State var showInitControl = false
    /// Legacy Wacom pen default (feature report 0x02, value 2). Modern
    /// HID_GENERIC devices use a descriptor-specific report ID instead — see
    /// `CaptureInitReport` — so these are a starting point, not a guarantee.
    @State var initReportIDText = "0x02"
    @State var initValueText = "0x02"
    /// Device-side session state; see `CaptureSessionCoordinator`.
    @StateObject var coordinator: CaptureSessionCoordinator

    @Environment(\.accessibilityDifferentiateWithoutColor)
    var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion)
    var reduceMotion

    private var isComplete: Bool { coordinator.savedURL != nil }
    private var startupError: String? { coordinator.startupError }
    var resolvedInfo: CaptureDeviceInfo? { coordinator.resolvedInfo }
    /// Rows satisfied this session. Latching — the row records what was
    /// captured, so lifting the pen must not un-tick "tap the pen's tip".
    @State var satisfied: Set<CaptureChecklistItem> = []
    @State private var checklistOrder = CaptureChecklistItem.allCases
    /// Traffic arrived that no decoder could read. Surfaced because it's the
    /// opposite of bad news — on an unsupported device it's the most valuable
    /// thing in the file, yet leaves every row above blank.
    @State var hasUndecodedTraffic = false
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

    /// Whether the in-flight spinner and its "waiting on the tablet" line are
    /// shown. Tracks `engine.isSendingInitReport`, but only after
    /// `sendingIndicatorDelay` — see `trackSendingIndicator`.
    @State var showSendingIndicator = false
    /// Task running the delay, cancelled when a write finishes inside it.
    @State var sendingIndicatorTask: Task<Void, Never>? = nil

    // MARK: - Body

    var body: some View {
        let _ = BodyCounter.note("CaptureGuide")
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
    static let connectionOptions: Set<String> = [
        "USB", "Bluetooth", "USB wireless dongle",
    ]

    // MARK: - Collection

    private func startCollection() {
        guard coordinator.start(), let info = coordinator.resolvedInfo else { return }
        checklistOrder = Self.checklistOrder(vendorID: info.vendorID, productID: info.productID)
        if let reportID = coordinator.autoDetectedModeReportID {
            // Deliberately does not expand the section. Pre-filling the field
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
