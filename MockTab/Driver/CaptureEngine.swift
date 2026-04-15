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

import Combine
import Foundation

/// Phase 1+2: Guided calibration wizard + delta filtering engine.
///
/// Usage:
/// 1. Call `startCalibration(deviceInfo:steps:)` to begin a session.
/// 2. Each step, call `armForStep()` then wait for `onSampleCaptured` callback.
/// 3. Call `recordSample(reportID:report:length:)` from device handleReport callbacks.
/// 4. On completion, call `finish()` to get a `CalibrationResult`.
/// 5. Call `exportJSON(result:)` to write to disk.
///
/// Thread safety: all UI-state methods are @MainActor. Device callbacks fire on
/// main thread (IOHIDManager scheduled on kCFRunLoopCommonModes).
@MainActor
final class CaptureEngine: ObservableObject {

    // MARK: - Singleton

    static let shared = CaptureEngine()

    private init() {}

    // MARK: - Published UI State

    @Published private(set) var isRunning = false {
        didSet { _isRunningNonisolated = isRunning }
    }
    /// Nonisolated mirror of `isRunning` for use in HID callbacks (main run loop, no data race).
    nonisolated(unsafe) private(set) var _isRunningNonisolated = false
    @Published private(set) var currentStepIndex = 0
    @Published private(set) var armedStep: CalibrationStep?
    @Published private(set) var lastError: String?
    @Published private(set) var stepResults: [CalibrationStep: CapturedSample] = [:]
    @Published private(set) var reportsSeen: [String: CapturedReportSummary] = [:]
    @Published private(set) var elapsedSeconds: Double = 0

    // MARK: - Session Configuration

    private var sessionDeviceInfo: CaptureDeviceInfo?
    var sessionSteps: [CalibrationStep] = []
    /// Tool code observed at start of calibration (e.g. 0x0802 = Grip Pen, 0x080A = Grip Pen eraser).
    private(set) var initialToolCode: UInt16?
    /// All tool codes observed during this calibration session.
    private(set) var observedToolCodes: Set<UInt16> = []
    /// The tool code most recently seen during capture.
    private(set) var currentToolCode: UInt16?
    private var stepStartTime: Date = .distantPast
    private var elapsedTimer: Timer?
    private var stepTimeoutTimer: Timer?

    // MARK: - Discovery Mode State
    @Published private(set) var isDiscoveryMode = false
    @Published private(set) var discoverySampleCount = 0
    private var discoveryStartTime: Date = .distantPast
    private var discoveryTimer: Timer?
    @Published private(set) var discoveryDuration: TimeInterval = 60
    private var discoverySamples: [UInt8: [[UInt8]]] = [:]

    // MARK: - Capture State

    /// Baseline sample captured before the current step's action.
    private var currentBaseline: [UInt8]?

    /// The first action sample that differs from baseline — captured and held.
    private var capturedAction: (reportID: UInt8, data: [UInt8])?

    /// Guard to prevent re-triggering within the same step.
    private var hasCapturedThisStep = false

    // MARK: - Callbacks

    /// Called when a calibration step produces a CapturedSample.
    var onSampleCaptured: ((CalibrationStep, CapturedSample) -> Void)?

    /// Called when all steps are complete with the full result.
    var onCalibrationComplete: ((CalibrationResult) -> Void)?
    /// Called when discovery finishes with the full result.
    var onDiscoveryComplete: ((DiscoveryResult) -> Void)?

    // MARK: - Public API

    /// Begin a new calibration session.
    /// - Parameters:
    ///   - deviceInfo: device descriptor for the JSON export header
    ///   - steps: ordered list of calibration steps to perform
    func startCalibration(deviceInfo: CaptureDeviceInfo, steps: [CalibrationStep], toolCode: UInt16? = nil) {
        reset()
        sessionDeviceInfo = deviceInfo
        sessionSteps = steps
        initialToolCode = toolCode
        if let tc = toolCode {
            observedToolCodes.insert(tc)
            currentToolCode = tc
        }
        isRunning = true
        currentStepIndex = 0
        stepStartTime = Date()
        startElapsedTimer()
        advanceToStep(0)
    }

    /// Update the current tool code during calibration (e.g., when user flips pen).
    func updateToolCode(_ toolCode: UInt16) {
        observedToolCodes.insert(toolCode)
        currentToolCode = toolCode
    }

    /// Reset the current step's baseline to the next incoming report.
    /// Also resets `hasCapturedThisStep` so the step can capture again — used
    /// when a spurious capture (e.g. hover movement) must be discarded.
    func rebaseline() {
        guard isRunning, !isDiscoveryMode else { return }
        currentBaseline = nil
        hasCapturedThisStep = false
        capturedAction = nil
    }

    /// Request that the current step be skipped.
    func skipCurrentStep() {
        guard isRunning else { return }
        advanceToNextStep()
    }

    /// Cancel the calibration session.
    func cancel() {
        guard isRunning else { return }
        stopTimers()
        isRunning = false
        armedStep = nil
        sessionSteps = []
        sessionDeviceInfo = nil
        stepResults = [:]
        reportsSeen = [:]
        // Reset discovery state if active
        isDiscoveryMode = false
        discoverySamples = [:]
    }

    /// Attempt to record a report toward the current step.
    /// Called from device handleReport callbacks when captureMode is .delta.
    func recordSample(reportID: UInt8, report: UnsafePointer<UInt8>, length: Int, toolCode: UInt16? = nil) {

        // Discovery mode: capture all samples without baseline comparison
        if isRunning && isDiscoveryMode {
            recordDiscoverySample(reportID: reportID, report: report, length: length)
            return
        }
        guard isRunning,
            let step = armedStep,
            !hasCapturedThisStep,
            length > 0
        else { return }

        let data = Array(UnsafeBufferPointer(start: report, count: length))

        if currentBaseline == nil {
            // First report for this step — establish baseline.
            currentBaseline = data
            return
        }

        // Already have baseline. Check if this report differs.
        guard let baseline = currentBaseline else { return }

        if reportsIdentical(baseline, data) {
            // Still idle — ignore.
            return
        }

        // This report differs from baseline — capture as action sample.
        capturedAction = (reportID, data)
        hasCapturedThisStep = true

        // Build sample and record it.
        var sample = CapturedSample(
            step: step,
            reportID: reportID,
            timestamp: Date(),
            baseline: baseline,
            action: data
        )
        sample.toolCode = toolCode
        if let tc = toolCode {
            observedToolCodes.insert(tc)
            currentToolCode = tc
        }

        stepResults[step] = sample
        updateReportSummary(sample)
        onSampleCaptured?(step, sample)
    }

    /// Called by the UI to dismiss the last captured sample and proceed manually.
    func confirmAndContinue() {
        guard isRunning else { return }
        stepTimeoutTimer?.invalidate()
        advanceToNextStep()
    }

    /// Finish the session and return the calibration result.
    func finish() -> CalibrationResult? {
        guard isRunning else { return nil }
        stopTimers()
        isRunning = false

        guard let deviceInfo = sessionDeviceInfo else { return nil }

        let result = buildResult(deviceInfo: deviceInfo)
        onCalibrationComplete?(result)
        return result
    }

    // MARK: - Discovery Mode

    /// Begin a discovery session for unknown devices.
    /// Records all reports for `duration` seconds (default 60s).
    func startDiscovery(deviceInfo: CaptureDeviceInfo, duration: TimeInterval = 60) {
        reset()
        isDiscoveryMode = true
        sessionDeviceInfo = deviceInfo
        discoveryDuration = duration
        isRunning = true
        discoveryStartTime = Date()
        startElapsedTimer()

        // Auto-finish after duration
        discoveryTimer?.invalidate()
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) {
            [weak self] _ in
            Task { @MainActor in
                self?.finishDiscovery()
            }
        }
    }

    /// Cancel discovery mode.
    func cancelDiscovery() {
        guard isRunning, isDiscoveryMode else { return }
        stopTimers()
        isRunning = false
        isDiscoveryMode = false
        discoverySamples = [:]
    }

    /// Record a sample in discovery mode (no baseline comparison).
    private func recordDiscoverySample(reportID: UInt8, report: UnsafePointer<UInt8>, length: Int) {
        guard isRunning, isDiscoveryMode, length > 0 else { return }
        let data = Array(UnsafeBufferPointer(start: report, count: length))
        if discoverySamples[reportID] == nil {
            discoverySamples[reportID] = []
        }
        discoverySamples[reportID]?.append(data)
        discoverySampleCount += 1
    }

    /// Finish discovery and return results.
    func finishDiscovery() -> DiscoveryResult? {
        guard isRunning, isDiscoveryMode else { return nil }
        stopTimers()
        isRunning = false
        isDiscoveryMode = false
        discoverySampleCount = 0
        guard let deviceInfo = sessionDeviceInfo else { return nil }
        let result = buildDiscoveryResult(deviceInfo: deviceInfo)
        onDiscoveryComplete?(result)
        return result
    }

    /// Export discovery result to JSON.
    func exportDiscoveryJSON(result: DiscoveryResult) -> URL? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = fmt.string(from: Date())
        let pid = sessionDeviceInfo?.productIDHex ?? "unknown"
        let filename = "mocktab_discovery_\(pid)_\(stamp).json"

        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(result)
            try data.write(to: url)
            return url
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

private func buildDiscoveryResult(deviceInfo: CaptureDeviceInfo) -> DiscoveryResult {
    var reportSummaries: [String: DiscoveryReportSummary] = [:]

    for (reportID, samples) in discoverySamples {
        let idHex = String(format: "0x%02X", reportID)
        let length = samples.first?.count ?? 0

        // Find which bytes vary and which are constant
        var varyingBytes: [Int] = []
        var constantBytes: [Int] = []
        var firstSampleHex: String? = nil
        var constantValues: [Int]? = nil
        var byteSampleValues: [Int: [Int]]? = nil

        if !samples.isEmpty {
            let firstSample = samples[0]
            firstSampleHex = firstSample.map { String(format: "%02X", $0) }.joined()

            // Build per-byte value sets
            var byteValues: [Int: Set<UInt8>] = [:]
            for sample in samples {
                for byteIdx in 0..<sample.count {
                    byteValues[byteIdx, default: []].insert(sample[byteIdx])
                }
            }

            for byteIdx in 0..<firstSample.count {
                let valuesAtIdx = byteValues[byteIdx] ?? []
                if valuesAtIdx.count > 1 {
                    varyingBytes.append(byteIdx)
                } else {
                    constantBytes.append(byteIdx)
                }
            }

            // Collect constant values
            if !constantBytes.isEmpty {
                constantValues = constantBytes.map { byteIdx in
                    Int(byteValues[byteIdx]?.first ?? 0)
                }
            }

            // Collect sample values for varying bytes (up to 20 per byte)
            byteSampleValues = [:]
            for byteIdx in varyingBytes {
                let values = Array(byteValues[byteIdx] ?? []).sorted()
                byteSampleValues?[byteIdx] = values.prefix(20).map { Int($0) }
            }
        }

        reportSummaries[idHex] = DiscoveryReportSummary(
            reportID: reportID,
            length: length,
            sampleCount: samples.count,
            varyingBytes: varyingBytes,
            constantBytes: constantBytes,
            firstSample: firstSampleHex,
            constantValues: constantValues,
            byteSampleValues: byteSampleValues
        )
    }

    return DiscoveryResult(
        capturedAt: Date(),
        mode: "discovery",
        duration: Date().timeIntervalSince(discoveryStartTime),
        deviceInfo: DiscoveryDeviceInfo(
            vendorID: deviceInfo.vendorIDHex,
            productID: deviceInfo.productIDHex,
            name: deviceInfo.name
        ),
        reports: reportSummaries
    )
}
    // MARK: - JSON Export

    /// Write calibration result to a JSON file on the Desktop.
    func exportJSON(result: CalibrationResult) -> URL? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = fmt.string(from: result.capturedAt)
        let pid = sessionDeviceInfo?.productIDHex ?? "unknown"
        let filename = "mocktab_calibration_\(pid)_\(stamp).json"

        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(result)
            try data.write(to: url)
            return url
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Private Helpers

    private func reset() {
        stopTimers()
        currentBaseline = nil
        capturedAction = nil
        hasCapturedThisStep = false
        currentStepIndex = 0
        stepResults = [:]
        reportsSeen = [:]
        elapsedSeconds = 0
        lastError = nil
    }

    private func advanceToStep(_ index: Int) {
        guard index < sessionSteps.count else {
            _ = finish()
            return
        }

        let step = sessionSteps[index]
        armedStep = step
        currentStepIndex = index
        currentBaseline = nil
        capturedAction = nil
        hasCapturedThisStep = false
        stepStartTime = Date()

        // Timeout per step — 60 seconds.
        stepTimeoutTimer?.invalidate()
        stepTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: false) {
            [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isRunning else { return }
                // Timed out — treat as skipped.
                self.advanceToNextStep()
            }
        }
    }

    private func advanceToNextStep() {
        let nextIndex = currentStepIndex + 1
        advanceToStep(nextIndex)
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.elapsedSeconds = Date().timeIntervalSince(self.stepStartTime)
            }
        }
    }

    private func stopTimers() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        stepTimeoutTimer?.invalidate()
        stepTimeoutTimer = nil
    }

    private func reportsIdentical(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        for i in 0..<a.count {
            if a[i] != b[i] { return false }
        }
        return true
    }

    private func updateReportSummary(_ sample: CapturedSample) {
        let idHex = String(format: "0x%02X", sample.reportID)
        if reportsSeen[idHex] == nil {
            reportsSeen[idHex] = CapturedReportSummary(id: idHex)
            reportsSeen[idHex]?.reportID = sample.reportID
            reportsSeen[idHex]?.length = sample.action.count
        }
        reportsSeen[idHex]?.samples.append(sample)
    }

    private func buildResult(deviceInfo: CaptureDeviceInfo) -> CalibrationResult {
        var reportInfoDict: [String: CalibrationResult.ReportInfo] = [:]

        for (idHex, summary) in reportsSeen {
            // Pick the most informative sample for this report ID (most changed bytes).
            let bestSample = summary.samples.max(by: {
                $0.changedIndices.count < $1.changedIndices.count
            })

            var fields: [String: CalibrationResult.FieldInfo] = [:]
            for idx in summary.allChangedIndices.sorted() {
                let freq = summary.changeFrequency[idx] ?? 0
                let isHighValue = summary.highValueIndices.contains(idx)
                let changedIn = summary.samples.filter { $0.changedIndices.contains(idx) }.map {
                    $0.step.shortLabel
                }

                fields["byte[\(idx)]"] = CalibrationResult.FieldInfo(
                    role: isHighValue ? "HIGH-VALUE (\(freq)/\(summary.samples.count) steps)" : nil,
                    bitmask: nil,
                    note: "changed in: \(changedIn.joined(separator: ", "))",
                    rangeMin: nil,
                    rangeMax: nil,
                    bits: nil,
                    sampleValues: summary.samples.compactMap { s -> String? in
                        guard s.changedIndices.contains(idx) else { return nil }
                        return String(format: "0x%02X", s.action[idx])
                    }
                )
            }

            reportInfoDict[idHex] = CalibrationResult.ReportInfo(
                length: summary.length,
                description: describeReportID(summary.reportID),
                fields: fields,
                sampleIdle: bestSample?.baselineHex,
                sampleAction: bestSample?.actionHex
            )
        }

        var toolCodesDescription = observedToolCodes.isEmpty ? "none" : observedToolCodes.map { String(format: "0x%04X", $0) }.sorted().joined(separator: ", ")
        var notes = "Observed tool codes: \(toolCodesDescription)"
        if observedToolCodes.contains(0x080A) {
            notes += " (eraser capable)"
        }

        return CalibrationResult(
            capturedAt: Date(),
            deviceInfo: CalibrationResult.DeviceInfo(
                vendorID: deviceInfo.vendorIDHex,
                productID: deviceInfo.productIDHex,
                name: deviceInfo.name,
                locationID: deviceInfo.locationID,
                serialNumber: deviceInfo.serialNumber
            ),
            reports: reportInfoDict,
            notes: notes,
            submitterContact: nil
        )
    }

    private func describeReportID(_ id: UInt8) -> String {
        switch id {
        case 0x10: return "Pen position + pressure (IntuosV2)"
        case 0x11: return "Express keys / aux"
        case 0x1E: return "Offset pen report"
        case 0x21: return "Touch / gesture"
        case 0x80: return "Wireless status"
        case 0x01: return "Tip switch / mouse-compatible"
        default: return "Report ID \(String(format: "0x%02X", id))"
        }
    }
}

// MARK: - CaptureMode Extension for Device Callbacks

/// Extension to make CaptureMode conveniently accessible from device handleReport.
extension CaptureEngine {

    /// Convenience for device classes to check if they should record.
    /// Returns the armed step if delta capture is active, nil otherwise.
    func captureMode(for deviceTag: String) -> CalibrationStep? {
        guard isRunning else { return nil }
        return armedStep
    }
}
