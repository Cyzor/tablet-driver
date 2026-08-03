// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import Foundation
import IOKit.hid
import OSLog
import TabletKit
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "capture")

// MARK: - Capture engine

/// Open-ended device data collection.
///
/// Usage:
/// 1. `startDiscovery(deviceInfo:duration:)` to begin.
/// 2. Drivers call `CaptureEngine.recordRaw(...)` from their report callbacks.
/// 3. `finishDiscovery()` to end and build a `DiscoveryResult`.
/// 4. `exportDiscoveryJSON(result:)` to write it to disk.
///
/// Thread safety: UI-state methods are `@MainActor`. The recording path is
/// deliberately *not* — `recordRaw` runs on HIDThread and writes into a
/// lock-guarded `DiscoveryAccumulator`, so no report ever hops to the main
/// actor. The main actor only polls the accumulated count for display.
@MainActor
final class CaptureEngine: ObservableObject {

    init() {}

    // MARK: - Recording entry point

    /// Statistics store, shared with the HID callback thread.
    private nonisolated let accumulator = DiscoveryAccumulator()

    /// Every in-progress session's accumulator, keyed by the identity of the
    /// `IOHIDDevice` it's recording — not product ID, so two connected units
    /// of the same model (or two capture sheets open at once) each keep their
    /// own data. Registered in `startDiscovery`, deregistered in
    /// `cancelDiscovery`/`finishDiscovery`. Lock-guarded because drivers call
    /// `recordRaw` from HIDThread, never the main actor.
    private nonisolated static let activeAccumulators =
        OSAllocatedUnfairLock<[ObjectIdentifier: DiscoveryAccumulator]>(initialState: [:])

    /// Record one raw HID input report toward whichever session (if any) is
    /// currently capturing `device`.
    ///
    /// Safe (and cheap) to call unconditionally from any driver's report
    /// callback: it no-ops when no session is capturing this device.
    ///
    /// - Parameters:
    ///   - device: the driver's own `IOHIDDevice` — identifies which
    ///     session (if any) this report belongs to.
    ///   - reportID: the report ID **from the IOKit callback**, not
    ///     `report[0]`. Devices whose descriptor declares no Report ID send
    ///     reports with no ID prefix, where `report[0]` is the first data byte
    ///     and would invent a new "report ID" on nearly every sample.
    ///   - pointer: the callback's report buffer. Only read for the duration
    ///     of this call — nothing retains it.
    nonisolated static func recordRaw(
        device: IOHIDDevice, reportID: UInt32, pointer: UnsafePointer<UInt8>, length: CFIndex
    ) {
        guard let accumulator = activeAccumulators.withLock({ $0[ObjectIdentifier(device)] })
        else { return }
        accumulator.record(
            reportID: UInt8(truncatingIfNeeded: reportID), pointer: pointer, length: Int(length))
    }

    // MARK: - Published UI State

    @Published private(set) var isRunning = false
    @Published private(set) var discoverySampleCount = 0
    @Published private(set) var lastError: String?
    /// Device-mode init writes attempted this session, in order. Surfaced in the
    /// capture UI and carried into the exported JSON.
    @Published private(set) var initReportsSent: [CaptureInitReport] = []
    /// True while a `sendInitReport` write is in flight. `IOHIDDeviceSetReport`
    /// blocks for the full device round-trip — several seconds is normal over
    /// Bluetooth — so callers must not invoke it on the main thread; this flag
    /// lets the UI show that state instead of just going unresponsive.
    @Published private(set) var isSendingInitReport = false

    // MARK: - Session State

    private var sessionDeviceInfo: CaptureDeviceInfo?
    /// The `IOHIDDevice` this session is scoped to — the key `recordRaw` and
    /// `updateToolCode` use to route reports here instead of to some other
    /// window's session on a different device.
    private var sessionDevice: IOHIDDevice?
    private var discoveryStartTime: Date = .distantPast
    /// Fires once at the end of the session duration to auto-finish a session
    /// the user walked away from.
    private var discoveryTimer: Timer?
    /// Polls the accumulator so the UI can show a live event count without the
    /// recording path touching `@Published` state per report.
    private var pollTimer: Timer?

    // MARK: - Callbacks

    /// Called when discovery finishes with the full result.
    var onDiscoveryComplete: ((DiscoveryResult) -> Void)?

    // MARK: - Public API

    /// Begin a collection session scoped to `device`. Records every report
    /// that specific `IOHIDDevice` sends for `duration` seconds, or until
    /// `finishDiscovery()` is called. Independent of any other `CaptureEngine`
    /// instance's session, even one running concurrently on another device.
    func startDiscovery(device: IOHIDDevice, deviceInfo: CaptureDeviceInfo, duration: TimeInterval = 60) {
        stopTimers()
        deregisterAccumulator()
        lastError = nil
        initReportsSent = []
        discoverySampleCount = 0
        sessionDeviceInfo = deviceInfo
        sessionDevice = device
        discoveryStartTime = Date()

        // Arm the accumulator before announcing the session: a report arriving
        // between these two statements must land in the fresh store, never the
        // previous session's.
        accumulator.start()
        Self.activeAccumulators.withLock { $0[ObjectIdentifier(device)] = accumulator }
        isRunning = true

        pollTimer = scheduledTimer(interval: 0.5, repeats: true) { [weak self] in
            guard let self, self.isRunning else { return }
            self.discoverySampleCount = self.accumulator.sampleCount
        }
        discoveryTimer = scheduledTimer(interval: duration, repeats: false) { [weak self] in
            self?.finishDiscovery()
        }
    }

    /// Cancel collection and discard everything gathered.
    func cancelDiscovery() {
        guard isRunning else { return }
        stopTimers()
        accumulator.stop()
        deregisterAccumulator()
        isRunning = false
        sessionDeviceInfo = nil
        discoverySampleCount = 0
    }

    /// Remove this session's accumulator from the routing table so `recordRaw`
    /// stops delivering reports to it. Idempotent; safe with no active session.
    private func deregisterAccumulator() {
        guard let device = sessionDevice else { return }
        Self.activeAccumulators.withLock { $0.removeValue(forKey: ObjectIdentifier(device)) }
        sessionDevice = nil
    }

    /// Note a Wacom tool code seen during collection (pen vs. eraser vs. puck).
    /// Called from `TabletManager`'s tool-enter path; harmless when idle.
    ///
    /// - Parameter device: the device the tool event came from, so it's
    ///   folded into the right session's accumulator (see `recordRaw`).
    nonisolated static func updateToolCode(_ toolCode: UInt16, device: IOHIDDevice) {
        activeAccumulators.withLock { $0[ObjectIdentifier(device)] }?.noteToolCode(toolCode)
    }

    /// Finish collection and build the result. Also invokes
    /// `onDiscoveryComplete`.
    @discardableResult
    func finishDiscovery() -> DiscoveryResult? {
        guard isRunning else { return nil }
        stopTimers()
        // Close the accumulator before snapshotting so no report lands between
        // the snapshot and the end of the session.
        accumulator.stop()
        deregisterAccumulator()
        isRunning = false
        discoverySampleCount = accumulator.sampleCount

        guard let deviceInfo = sessionDeviceInfo else {
            lastError = String(
                localized: "Collection ended before the tablet was identified. Nothing was saved.",
                comment: "Capture error shown when a session finishes with no device information")
            return nil
        }

        let result = buildDiscoveryResult(deviceInfo: deviceInfo)
        onDiscoveryComplete?(result)
        return result
    }

    // MARK: - Device Mode Init

    /// Write a device-mode init feature report, and record the attempt.
    ///
    /// Experimental and manually driven: see `CaptureInitReport` for why the
    /// report ID can't be discovered automatically on modern devices. The write
    /// is best-effort — an unsupported report ID is normally NAK'd harmlessly —
    /// and either outcome is recorded, since "this report ID was rejected" is
    /// itself useful evidence in a capture file.
    ///
    /// The actual `IOHIDDeviceSetReport` call runs off the main actor: it
    /// blocks for the full device round-trip, and over Bluetooth that's
    /// routinely several seconds — long enough to beachball the app if done
    /// inline from a button action. `initReportsSent` and `isSendingInitReport`
    /// are only touched back on the main actor once the write returns.
    func sendInitReport(device: IOHIDDevice, reportID: Int, value: Int) {
        guard !isSendingInitReport else { return }
        isSendingInitReport = true
        Task.detached(priority: .userInitiated) { [weak self] in
            var bytes: [UInt8] = [UInt8(truncatingIfNeeded: reportID), UInt8(truncatingIfNeeded: value)]
            let ret = hidSetReport(
                device,
                reportID: CFIndex(reportID),
                bytes: &bytes,
                tag: "capture modeInit \(String(format: "0x%02X", reportID))=\(value)",
                severity: .bestEffort,
                log: logger
            )
            let ok = ret == kIOReturnSuccess
            let attempt = CaptureInitReport(
                reportID: reportID,
                value: value,
                succeeded: ok,
                ioReturn: ok ? nil : String(format: "0x%08X", ret)
            )
            await MainActor.run { [weak self] in
                self?.initReportsSent.append(attempt)
                self?.isSendingInitReport = false
            }
        }
    }

    // MARK: - JSON Export

    /// Write the discovery result to a JSON file on the Desktop, falling back
    /// to a save panel when that write fails (most often because the app has
    /// not been granted Desktop access).
    func exportDiscoveryJSON(result: DiscoveryResult) -> URL? {
        let filename = "mocktab_discovery_\(result.deviceInfo.productID)_\(Self.fileStamp()).json"

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data: Data
        do {
            data = try encoder.encode(result)
        } catch {
            lastError = String(
                localized: "Couldn't prepare the file: \(error.localizedDescription)",
                comment: "Capture error shown when the collected data could not be encoded")
            return nil
        }

        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent(filename)
        do {
            try data.write(to: desktop)
            return desktop
        } catch {
            logger.error(
                "capture export to Desktop failed — \(error.localizedDescription, privacy: .public)")
        }

        guard let chosen = Self.runSavePanel(suggestedName: filename) else {
            lastError = String(
                localized: "Couldn't save to the Desktop, and no other location was chosen.",
                comment: "Capture error shown when the Desktop write failed and the user dismissed the save panel")
            return nil
        }
        do {
            try data.write(to: chosen)
            return chosen
        } catch {
            lastError = String(
                localized: "Couldn't save the file: \(error.localizedDescription)",
                comment: "Capture error shown when writing the capture file failed")
            return nil
        }
    }

    /// Ask the user where to put the capture file. Only reached when the
    /// Desktop write failed — typically because the app hasn't been granted
    /// access to the Desktop folder, which a save panel resolves by handing
    /// back a user-chosen destination.
    @MainActor
    private static func runSavePanel(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.title = String(
            localized: "Save Device Data",
            comment: "Title of the save panel shown when the capture file can't be written to the Desktop")
        panel.message = String(
            localized: "MockTab couldn't write to your Desktop. Choose where to save the collected device data.",
            comment: "Explanation in the capture save panel after a Desktop write failure")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Timestamp for capture filenames.
    ///
    /// Pinned to `en_US_POSIX` so the stamp is Gregorian ASCII regardless of
    /// the user's region. Without this, a submitted capture came back named
    /// `mocktab_discovery_0x0000_14050418_150909.json` — Persian calendar year
    /// 1405 — which sorts and reads as nonsense next to every other file.
    private static func fileStamp(_ date: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = .current
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        return fmt.string(from: date)
    }

    // MARK: - Result Building

    private func buildDiscoveryResult(deviceInfo: CaptureDeviceInfo) -> DiscoveryResult {
        let (reports, toolCodes) = accumulator.snapshot()
        var reportSummaries: [String: DiscoveryReportSummary] = [:]

        for (reportID, stats) in reports {
            let idHex = String(format: "0x%02X", reportID)

            var varyingBytes: [Int] = []
            var constantBytes: [Int] = []
            var optionalBytes: [Int] = []
            var constantValues: [Int] = []
            var byteStats: [Int: DiscoveryByteStat] = [:]

            // `byteRoles()` partitions every position exactly once, so
            // `constantBytes` and `constantValues` stay the same length by
            // construction rather than by two loops agreeing with each other.
            for (idx, role) in stats.byteRoles() {
                switch role {
                case .constant(let value):
                    constantBytes.append(idx)
                    constantValues.append(Int(value))
                case .varying, .optional:
                    if role == .optional {
                        optionalBytes.append(idx)
                    } else {
                        varyingBytes.append(idx)
                    }
                    let seen = stats.byteValues[idx]
                    if let lo = seen.min, let hi = seen.max {
                        byteStats[idx] = Self.byteStat(seen, lo: lo, hi: hi)
                    }
                }
            }

            // Cross-reference against the parsed descriptor: does it expose a
            // decodable (non-opaque) field for this input report ID? Discovery
            // only observes device->host traffic, so we only ever check the
            // "input:" direction here.
            let descriptorReadable = deviceInfo.parsedDescriptor?.reports["input:\(idHex)"]?.isReadable

            // Runs regardless of `descriptorReadable`: a report can have a
            // readable descriptor for *some* fields and still pack an opaque
            // repeated block (a vendor touch sub-report tacked onto an
            // otherwise-documented pen report), so withholding this behind
            // the opacity check would hide it in exactly that case.
            let signatures = Dictionary(
                uniqueKeysWithValues: byteStats.map {
                    ($0.key, ByteVarianceSignature(distinctCount: $0.value.distinctCount, max: $0.value.max))
                })
            let repeatingStructure = RepeatingReportStructureDetector
                .detect(signatures: signatures)
                .map(Self.discoveryRepeatingStructure)

            reportSummaries[idHex] = DiscoveryReportSummary(
                reportID: reportID,
                length: stats.firstLength,
                maxLength: stats.maxLength,
                lengthVaried: stats.lengthVaried,
                sampleCount: stats.sampleCount,
                varyingBytes: varyingBytes,
                constantBytes: constantBytes,
                optionalBytes: optionalBytes.isEmpty ? nil : optionalBytes,
                firstSample: stats.firstSample.map { String(format: "%02X", $0) }.joined(),
                constantValues: constantValues.isEmpty ? nil : constantValues,
                byteStats: byteStats.isEmpty ? nil : byteStats,
                descriptorReadable: descriptorReadable,
                repeatingStructure: repeatingStructure,
                byteStatsByDiscriminator: Self.discriminatedStats(stats)
            )
        }

        let toolCodeHex = toolCodes.map { String(format: "0x%04X", $0) }.sorted()
        var notes = "Observed tool codes: \(toolCodeHex.isEmpty ? "none" : toolCodeHex.joined(separator: ", "))"
        if toolCodes.contains(0x080A) {
            notes += " (eraser capable)"
        }

        return DiscoveryResult(
            capturedAt: Date(),
            mode: "discovery",
            duration: Date().timeIntervalSince(discoveryStartTime),
            deviceInfo: DiscoveryDeviceInfo(
                vendorID: deviceInfo.vendorIDHex,
                productID: deviceInfo.productIDHex,
                name: deviceInfo.name,
                manufacturer: deviceInfo.manufacturer,
                transport: deviceInfo.transport,
                locationID: deviceInfo.locationID
            ),
            reports: reportSummaries,
            hidReportDescriptor: deviceInfo.parsedDescriptor,
            initReports: initReportsSent.isEmpty ? nil : initReportsSent,
            observedToolCodes: toolCodeHex.isEmpty ? nil : toolCodeHex,
            notes: notes,
            submitterContact: nil
        )
    }

    /// Values listed per byte position before the list is trimmed. See
    /// `ByteValueSet.sampledValues(cap:)` for what trimming preserves.
    private static let byteValueListCap = 24

    /// Byte 1 must take at least this many but no more than
    /// `discriminatorMaxDistinct` values across the session for its buckets
    /// to be worth exporting. Fewer than 2 means byte 1 was constant — no
    /// split to make. More than this and it's behaving like coordinate data
    /// itself (a report ID whose byte 1 sweeps a wide range isn't a
    /// status/type field), so splitting on it would fragment the capture
    /// into dozens of near-empty buckets instead of clarifying anything.
    private static let discriminatorMaxDistinct = 16

    /// Builds `byteStatsByDiscriminator` for one report, or nil when byte 1's
    /// own cardinality falls outside `discriminatorMaxDistinct` — see that
    /// property and `DiscoveryReportSummary.byteStatsByDiscriminator`.
    private static func discriminatedStats(
        _ stats: DiscoveryAccumulator.ReportStats
    ) -> [String: DiscoveryDiscriminatedStats]? {
        let distinctDiscriminatorValues = stats.byDiscriminator.count
        guard (2...discriminatorMaxDistinct).contains(distinctDiscriminatorValues) else { return nil }

        var out: [String: DiscoveryDiscriminatedStats] = [:]
        for (disc, bucket) in stats.byDiscriminator {
            var byteStats: [Int: DiscoveryByteStat] = [:]
            for (idx, seen) in bucket.enumerated() {
                guard let lo = seen.min, let hi = seen.max else { continue }
                byteStats[idx] = Self.byteStat(seen, lo: lo, hi: hi)
            }
            let key = String(format: "%02X", disc)
            out[key] = DiscoveryDiscriminatedStats(
                sampleCount: stats.discriminatorSampleCounts[disc] ?? 0,
                byteStats: byteStats)
        }
        return out
    }

    private static func byteStat(_ seen: ByteValueSet, lo: UInt8, hi: UInt8) -> DiscoveryByteStat {
        let (kept, truncated) = seen.sampledValues(cap: byteValueListCap)
        // Emitted only when some bit actually toggled: on a coordinate byte
        // nearly every bit does, which says nothing, and a field of 255s
        // across a long report would bury the positions where it means
        // something.
        let toggled = seen.togglingBits
        return DiscoveryByteStat(
            min: Int(lo),
            max: Int(hi),
            distinctCount: seen.count,
            values: kept.map(Int.init),
            truncated: truncated ? true : nil,
            bitsToggled: toggled == 0 ? nil : Int(toggled),
            bitsSet: toggled == 0 ? nil : Int(seen.bitsEverSet)
        )
    }

    private static func discoveryRepeatingRun(_ run: RepeatingRun) -> DiscoveryRepeatingRun {
        DiscoveryRepeatingRun(
            startOffset: run.startOffset, period: run.period,
            repeatCount: run.repeatCount, matchFraction: run.matchFraction)
    }

    private static func discoveryRepeatingStructure(
        _ structure: RepeatingReportStructure
    ) -> DiscoveryRepeatingStructure {
        DiscoveryRepeatingStructure(
            outer: discoveryRepeatingRun(structure.outer),
            nested: structure.nested.map(discoveryRepeatingRun))
    }

    // MARK: - Timers

    /// Timers run in `.common` mode so a live session keeps counting (and
    /// still auto-finishes) while a menu is tracking or the window is being
    /// resized, both of which stall the default run-loop mode.
    private func scheduledTimer(
        interval: TimeInterval, repeats: Bool, _ body: @escaping @MainActor () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in
            Task { @MainActor in body() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func stopTimers() {
        pollTimer?.invalidate()
        pollTimer = nil
        discoveryTimer?.invalidate()
        discoveryTimer = nil
    }
}
