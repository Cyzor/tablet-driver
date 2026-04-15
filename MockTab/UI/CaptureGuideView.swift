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
        .alert("Cancel Data Collection?", isPresented: $showCancelConfirm) {
            Button("Continue Collecting", role: .cancel) {}
            Button("Cancel", role: .destructive) {
                engine.cancelDiscovery()
                onDismiss()
            }
        } message: {
            Text("Any data collected so far will be discarded.")
        }
        .onAppear { startCollection() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Collect Device Data")
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
            ? "Captures diagnostic data to help investigate a problem with your device."
            : "Helps add support for your device by capturing its HID report layout."
    }

    // MARK: - Recording view

    private var recordingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Perform each of these actions, then click Done:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 10) {
                instruction("hand.point.down.left",  "Touch the pen tip to the surface, then lift")
                instruction("button.horizontal",      "Press and hold each side button on the pen")
                instruction("arrow.up.and.down.circle", "Press the eraser end to the surface (if present)")
                instruction("rectangle.grid.2x2",    "Press each button on the tablet body (if any)")
                instruction("circle.dashed",          "Slide or touch any rings or strips on the tablet (if any)")
            }
            .padding(.horizontal, 20)

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(engine.isRunning ? Color.red : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(engine.isRunning
                     ? "\(engine.discoverySampleCount) events recorded"
                     : "Starting…")
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

            Text("Collection Complete")
                .font(.title3)
                .fontWeight(.semibold)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Show File in Finder", systemImage: "doc.badge.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("Share this file with MockTab developers for potential feature support.")
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
