// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026 This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab. If not, see <https://www.gnu.org/licenses/>.

import AppKit
import SwiftUI

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

    private var isComplete: Bool { savedURL != nil }

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
        .frame(width: 460, height: 400)
        .alert(String(localized: "Cancel Data Collection?", comment: "Data collection confirmation alert title"), isPresented: $showCancelConfirm) {
            Button(LocalizedStringKey("Continue Collecting"), role: .cancel) {}
            Button(LocalizedStringKey("Cancel"), role: .destructive) {
                engine.cancelDiscovery()
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
                .font(.title2)
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Collect Device Data", comment: "Sheet title: device data collection"))
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
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
                .font(.subheadline)
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
            }
            .padding(.horizontal, 20)

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(engine.isRunning ? Color.red : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(engine.isRunning
                     ? String(localized: "\(engine.discoverySampleCount) events recorded", comment: "HID discovery: number of events captured during device discovery")
                     : String(localized: "Starting…", comment: "HID discovery: status indicator while discovery is starting"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func instruction(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
        }
    }

    // MARK: - Completion

    private func completionView(url: URL) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text(String(localized: "Collection Complete", comment: "Data collection completion status"))
                .font(.title3)
                .fontWeight(.semibold)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label(String(localized: "Show File in Finder", comment: "Button label: open data collection file in Finder"), systemImage: "doc.badge.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text(String(localized: "Share this file with MockTab developers for potential feature support.", comment: "Message encouraging user to share data collection file"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if !isComplete {
                Button(LocalizedStringKey("Cancel")) {
                    if engine.isRunning { showCancelConfirm = true } else { onDismiss() }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isComplete {
                Button(LocalizedStringKey("Done")) { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(LocalizedStringKey("Done")) {
                    _ = engine.finishDiscovery()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!engine.isRunning)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Collection logic

    private func startCollection() {
        guard let devInfo = deviceInfo() else { return }

        engine.onDiscoveryComplete = { result in
            Task { @MainActor in
                if let url = engine.exportDiscoveryJSON(result: result) {
                    savedURL = url
                }
            }
        }

        engine.startDiscovery(deviceInfo: devInfo, duration: 3600)
    }

    private func deviceInfo() -> CaptureDeviceInfo? {
        let name =
            WacomDeviceRegistry.spec(for: productID)?.name
            ?? TabletManager.deviceName(forProductID: productID)
        return CaptureDeviceInfo(
            vendorID: 0x056A,
            productID: productID,
            name: name,
            locationID: nil,
            serialNumber: nil
        )
    }
}
