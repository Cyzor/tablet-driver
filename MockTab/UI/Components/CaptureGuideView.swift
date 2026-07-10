// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
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
    @State private var lastCapturedStep: CalibrationStep? = nil

    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    private var isComplete: Bool { savedURL != nil }

    /// Always false: the named step-by-step walkthrough (`guidedRecordingView`)
    /// is retired in favor of the free-form discovery recorder everywhere. It
    /// misread noise as user actions, stalled on 60s timeouts waiting for
    /// signals that never arrived, and — on any device streaming more than
    /// one report ID — routinely mislabeled reports from the *other* stream
    /// as the requested action. The discovery recorder has none of those
    /// failure modes and produces equally usable output. `guidedRecordingView`
    /// and the underlying `CaptureEngine.startCalibration` machinery are left
    /// in place for now rather than deleted outright, since removing them
    /// touches the calibration JSON export format and the GitHub-issue
    /// submission flow documented in
    /// Notes/Scratch/Unknown-Device-Discovery-2026-05-21.md — a separate,
    /// deliberate cleanup pass, not a side effect of this one.
    private var isUnknownDevice: Bool { false }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isComplete, let url = savedURL {
                completionView(url: url)
            } else if isUnknownDevice {
                guidedRecordingView
            } else {
                recordingView
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 400)
        .alert(String(localized: "Cancel Data Collection?", comment: "Data collection confirmation alert title"), isPresented: $showCancelConfirm) {
            Button("Continue Collecting", role: .cancel) {}
            Button("Cancel", role: .destructive) {
                if isUnknownDevice { engine.cancel() } else { engine.cancelDiscovery() }
                onDismiss()
            }
        } message: {
            Text(String(localized: "Any data collected so far will be discarded.", comment: "Data collection alert message"))
        }
        .onAppear { startCollection() }
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

    private var subtitle: String {
        WacomDeviceRegistry.spec(for: productID) != nil
            ? String(localized: "Captures diagnostic data to help investigate a problem with your device.", comment: "Subtitle for device data collection when tablet is already supported")
            : String(localized: "Helps add support for your device by capturing its HID report layout.", comment: "Subtitle for device data collection when tablet is not yet supported")
    }

    // MARK: - Recording view

    private var recordingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "Perform each of these actions, then click Done:", comment: "Instruction text for device data collection"))
                .appFont(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 10) {
                instruction("hand.point.down.left",  String(localized: "Touch the pen tip to the surface, then lift", comment: "Device data collection instruction: pen tip"))
                instruction("button.horizontal",      String(localized: "Press and hold each side button on the pen", comment: "Device data collection instruction: pen buttons"))
                instruction("arrow.up.and.down.circle", String(localized: "Press the eraser end to the surface (if present)", comment: "Device data collection instruction: eraser"))
                instruction("rectangle.grid.2x2",    String(localized: "Press each button on the tablet body (if any)", comment: "Device data collection instruction: tablet buttons"))
                instruction("circle.dashed",          String(localized: "Slide or touch any rings or strips on the tablet (if any)", comment: "Device data collection instruction: touch ring/strip"))
                instruction("hand.draw",              String(localized: "If your tablet has a touch surface, slide a finger across it and try a two-finger pinch", comment: "Device data collection instruction: capacitive finger touch (only meaningful on touch-capable tablets)"))
            }
            .padding(.horizontal, 20)

            Spacer()

            HStack(spacing: 6) {
                recordingDot
                    .frame(width: 7, height: 7)
                Text(engine.isRunning
                     ? String(localized: "\(engine.discoverySampleCount) events recorded", comment: "HID discovery: number of events captured during device discovery")
                     : String(localized: "Starting…", comment: "HID discovery: status indicator while discovery is starting"))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Guided recording view (unknown devices)

    private var guidedRecordingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let step = engine.armedStep {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Step \(engine.currentStepIndex + 1) of \(engine.sessionSteps.count)", comment: "Guided capture: step progress, e.g. 'Step 3 of 21'"))
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                    Text(step.instruction)
                        .appFont(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                    if lastCapturedStep == step {
                        Label(String(localized: "Captured — advancing…", comment: "Guided capture: confirmation after a step's input is detected"),
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .appFont(.caption)
                    } else {
                        Text(String(localized: "Perform the action above. If your tablet doesn't have it, click Skip.", comment: "Guided capture: prompt below current step instruction"))
                            .appFont(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            } else {
                Text(String(localized: "Starting…", comment: "Guided capture: brief status while the first step arms"))
                    .padding(20)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Button(String(localized: "Skip", comment: "Guided capture: skip the current step")) {
                    lastCapturedStep = nil
                    engine.skipCurrentStep()
                }
                .buttonStyle(.bordered)
                .disabled(engine.armedStep == nil)
                Spacer()
                HStack(spacing: 6) {
                    recordingDot
                        .frame(width: 7, height: 7)
                    Text(String(localized: "\(engine.stepResults.count) captured", comment: "Guided capture: count of steps with a captured sample"))
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Recording-status indicator dot, shared by `recordingView` and
    /// `guidedRecordingView`. When Differentiate-Without-Color is enabled,
    /// uses an SF Symbol that distinguishes state by glyph (filled-vs-hollow
    /// record glyph) in addition to red-vs-gray color.
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

            Text(String(localized: "The issue is pre-filled with your tablet's data. If the JSON is too large to fit in the form, drag the file from Finder into the issue body.", comment: "Caption on the data-collection completion screen"))
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
        let pidHex = String(format: "0x%04X", productID)
        let title = "Device support: Wacom \(pidHex)"
        let baseURL = "https://github.com/cyzor/tablet-driver/issues/new"
        let json = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        let inlineBody = """
        <!-- Captured by MockTab — please leave the JSON block intact -->

        **Wacom product ID:** `\(pidHex)`
        **Capture file:** `\(url.lastPathComponent)`

        <details><summary>Capture JSON</summary>

        ```json
        \(json)
        ```

        </details>
        """

        let fallbackBody = """
        <!-- Captured by MockTab -->

        **Wacom product ID:** `\(pidHex)`

        The capture JSON is too large to fit in this form. Please drag
        `\(url.lastPathComponent)` from Finder into the comment box to attach it.
        """

        var comps = URLComponents(string: baseURL)!
        comps.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "labels", value: "device-support"),
            URLQueryItem(name: "body", value: inlineBody),
        ]

        // GitHub serves /issues/new server-side; URL length needs to stay below
        // typical browser/server limits. 7000 leaves headroom under the 8 KB mark.
        if let u = comps.url, u.absoluteString.count > 7000 {
            comps.queryItems = [
                URLQueryItem(name: "title", value: title),
                URLQueryItem(name: "labels", value: "device-support"),
                URLQueryItem(name: "body", value: fallbackBody),
            ]
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
                Button("Done") {
                    if isUnknownDevice {
                        _ = engine.finish()
                    } else {
                        _ = engine.finishDiscovery()
                    }
                }
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
        guard let devInfo = deviceInfo() else { return }

        if isUnknownDevice {
            engine.onSampleCaptured = { step, _ in
                Task { @MainActor in
                    lastCapturedStep = step
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    engine.confirmAndContinue()
                }
            }
            engine.onCalibrationComplete = { result in
                Task { @MainActor in
                    if let url = engine.exportJSON(result: result) {
                        savedURL = url
                    }
                }
            }
            engine.startCalibration(deviceInfo: devInfo, steps: CalibrationStep.allUniversal)
        } else {
            engine.onDiscoveryComplete = { result in
                Task { @MainActor in
                    if let url = engine.exportDiscoveryJSON(result: result) {
                        savedURL = url
                    }
                }
            }
            engine.startDiscovery(deviceInfo: devInfo, duration: 3600)
        }
    }

    private func deviceInfo() -> CaptureDeviceInfo? {
        guard let dev = tabletManager.contexts[productID]?.hidDevice else { return nil }

        let vendorID     = (IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int) ?? 0x056A
        let manufacturer = IOHIDDeviceGetProperty(dev, kIOHIDManufacturerKey as CFString) as? String
        let transport    = IOHIDDeviceGetProperty(dev, kIOHIDTransportKey    as CFString) as? String
        let serial       = IOHIDDeviceGetProperty(dev, kIOHIDSerialNumberKey as CFString) as? String
        let productString = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String
        let locationID   = (IOHIDDeviceGetProperty(dev, kIOHIDLocationIDKey  as CFString) as? Int)
            .map { String(format: "0x%08X", $0) }
        let parsed = HIDDescriptorReader.read(dev)

        let name =
            WacomDeviceRegistry.spec(for: productID)?.name
            ?? TabletManager.deviceName(
                forProductID: productID, vendorID: vendorID, productString: productString)

        return CaptureDeviceInfo(
            vendorID: vendorID,
            productID: productID,
            name: name,
            locationID: locationID,
            serialNumber: serial,
            manufacturer: manufacturer,
            transport: transport,
            parsedDescriptor: parsed
        )
    }
}
