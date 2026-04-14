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

import SwiftUI
import AppKit

/// Modal sheet that walks the user through calibration steps for an unknown tablet.
/// Each step instructs the user to perform a specific action, then captures the
/// resulting HID report as a delta from the idle baseline.
struct CaptureWizardView: View {
    @ObservedObject var engine: CaptureEngine
    @ObservedObject var tabletManager: TabletManager
    let productID: Int
    let onDismiss: () -> Void

    @State private var selectedMode: WizardMode = .calibration
    @State private var discoveryProgress: Double = 0

    enum WizardMode {
        case calibration
        case discovery
    }

    @State private var showCancelConfirm = false
    @State private var lastCapturedSample: CapturedSample?
    @State private var savedURL: URL?

    private var deviceInfo: CaptureDeviceInfo? {
        guard let spec = WacomDeviceRegistry.spec(for: productID) else { return nil }
        // Wacom vendor ID is always 0x056A
        let vendorID = 0x056A
        return CaptureDeviceInfo(
            vendorID: vendorID,
            productID: spec.productID,
            name: spec.name,
            locationID: nil,
            serialNumber: nil
        )
    }


    private var currentStep: CalibrationStep? {
        engine.armedStep
    }

    private var progressFraction: Double {
        guard !engine.sessionSteps.isEmpty else { return 0 }
        return Double(engine.currentStepIndex) / Double(engine.sessionSteps.count)
    }

    private var progressText: String {
        "\(engine.currentStepIndex + 1) of \(engine.sessionSteps.count)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if engine.isRunning {
                if let step = currentStep {
                    stepContent(step)
                }
            } else if let url = savedURL {
                completionContent(url: url)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 380)
        .alert("Cancel Calibration?", isPresented: $showCancelConfirm) {
            Button("Continue", role: .cancel) {}
            Button("Cancel Calibration", role: .destructive) {
                engine.cancel()
                onDismiss()
            }
        } message: {
            Text("Captured data will be lost. Start over to try again.")
        }
        .onAppear {
            startCalibration()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Unknown Tablet Calibration")
                    .font(.headline)
                Spacer()
                Text(progressText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Step Content

    private func stepContent(_ step: CalibrationStep) -> some View {
        VStack(spacing: 20) {
            // Current step instruction
            VStack(spacing: 8) {
                Text(step.shortLabel)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(step.instruction)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            // Status indicator
            HStack(spacing: 12) {
                if lastCapturedSample == nil {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 12, height: 12)
                    Text("Waiting for input...")
                        .foregroundStyle(.secondary)
                } else {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 12, height: 12)
                    Text("Captured!")
                        .foregroundStyle(.green)
                }
                Spacer()
                Text(String(format: "%.1fs", engine.elapsedSeconds))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, 20)

            // Captured sample detail
            if let sample = lastCapturedSample {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Captured Report")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ID: \(String(format: "0x%02X", sample.reportID))")
                            Text("Length: \(sample.action.count)")
                            Text("Changed bytes: \(sample.changedIndices.count)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Spacer()

                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(sample.changedIndices.prefix(8), id: \.self) { idx in
                                Text("byte[\(idx)] = \(String(format: "0x%02X", sample.action[idx]))")
                                    .font(.system(.caption, design: .monospaced))
                            }
                            if sample.changedIndices.count > 8 {
                                Text("... and \(sample.changedIndices.count - 8) more")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
                .padding(.horizontal, 20)
            }

            Spacer()
        }
    }

    // MARK: - Completion Content

    private func completionContent(url: URL) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Calibration Complete")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Saved to Desktop:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(url.lastPathComponent)
                .font(.caption)
                .fontDesign(.monospaced)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)

            Text("Share this file to add support for your device.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if engine.isRunning {
                Button("Skip") {
                    engine.skipCurrentStep()
                    lastCapturedSample = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Skip All") {
                    skipRemainingSteps()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.secondary)

                Spacer()

                if lastCapturedSample != nil {
                    Button("Continue") {
                        engine.confirmAndContinue()
                        lastCapturedSample = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                Spacer()
                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button("Cancel") {
                if engine.isRunning {
                    showCancelConfirm = true
                } else {
                    onDismiss()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundStyle(.red)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Actions

    private func startCalibration() {
        guard let devInfo = deviceInfo else { return }

        // Determine which steps to include based on device capabilities.
        let spec = WacomDeviceRegistry.spec(for: productID)
        var steps = CalibrationStep.basicPenSteps
        if spec?.hasTilt == true {
            steps.append(contentsOf: [.hover5mm, .tilt15, .tilt45])
        }
    if spec?.hasTilt == true {  // hasTilt used as proxy for art pen rotation
            steps.append(contentsOf: [.rotationCW, .rotationCCW])
        }
        if let ek = spec?.buttonCount, ek > 0 {
            let ekCount = min(ek, 8)
            for i in 1...ekCount {
                switch i {
                case 1: steps.append(.expressKey1)
                case 2: steps.append(.expressKey2)
                case 3: steps.append(.expressKey3)
                case 4: steps.append(.expressKey4)
                case 5: steps.append(.expressKey5)
                case 6: steps.append(.expressKey6)
                case 7: steps.append(.expressKey7)
                case 8: steps.append(.expressKey8)
                default: break
                }
            }
        }
        if spec?.hasTouchRing == true {
            steps.append(contentsOf: [.touchRing, .touchRingPos0])
        }

        engine.onSampleCaptured = { _, sample in
            lastCapturedSample = sample
        }

        engine.onCalibrationComplete = { result in
            if let url = engine.exportJSON(result: result) {
                savedURL = url
            }
        }

        engine.startCalibration(deviceInfo: devInfo, steps: steps)
    }

    private func skipRemainingSteps() {
        // Mark remaining steps as skipped and finish early.
        for step in engine.sessionSteps {
            if engine.stepResults[step] == nil {
                // Leave as nil — will be omitted from output.
            }
        }
        if let result = engine.finish() {
            if let url = engine.exportJSON(result: result) {
                savedURL = url
            }
        }
    }
}

