// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import Foundation
import IOKit.hid
import OSLog
@_spi(TabletKitInternals) import TabletKit
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

    /// One interface being recorded: the `IOHIDDevice` reports arrive from,
    /// what that interface says it is, and its own statistics store.
    ///
    /// A session records *every* reporting interface of the device at once
    /// rather than one the user picked, so each needs its own accumulator:
    /// two interfaces of the same tablet routinely use the same report IDs
    /// for unrelated payloads (PTH-850 sends pen data and a 64-byte touch
    /// frame that would otherwise be histogrammed into one bucket), and each
    /// carries its own report descriptor to cross-reference against.
    struct InterfaceSession {
        let device: IOHIDDevice
        let info: CaptureDeviceInfo
        let accumulator: DiscoveryAccumulator
    }

    /// Every interface this session is recording, primary first — see
    /// `startDiscovery(devices:)`. Empty when idle.
    private var sessions: [InterfaceSession] = []

    /// Every in-progress session's accumulator, keyed by the identity of the
    /// `IOHIDDevice` it's recording — not product ID, so two connected units
    /// of the same model (or two capture sheets open at once) each keep their
    /// own data. Registered in `startDiscovery`, deregistered in
    /// `cancelDiscovery`/`finishDiscovery`. Lock-guarded because drivers call
    /// `recordRaw` from HIDThread, never the main actor.
    /// The device's touch settings as of `startDiscovery`, recorded into the
    /// capture file. Nil for a device without finger touch, where these
    /// settings are inert.
    private var capturedTouchSettings: DiscoveryTouchSettings?
    /// Live for the session only — created in `startDiscovery` when the
    /// device is Bluetooth and a candidate address is available, torn down
    /// in `finishDiscovery`/`cancelDiscovery`. Not a standing per-device
    /// monitor: polling bluetoothd for the whole time a tablet sits connected
    /// would be needless background chatter for something only useful while
    /// actively diagnosing.
    private var bluetoothLinkMonitor: BluetoothLinkMonitor?

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
    ///   - contactDown: whether a touch contact was down as of the driver's
    ///     most recent decode. Used only to split the arrival-gap histogram
    ///     (see `DiscoveryAccumulator.record`); `nil` when the caller has no
    ///     touch state to offer, which is every non-touch report and every
    ///     driver that doesn't decode touch.
    nonisolated static func recordRaw(
        device: IOHIDDevice, reportID: UInt32, pointer: UnsafePointer<UInt8>, length: CFIndex,
        contactDown: Bool? = nil
    ) {
        guard let accumulator = activeAccumulators.withLock({ $0[ObjectIdentifier(device)] })
        else { return }
        accumulator.record(
            reportID: UInt8(truncatingIfNeeded: reportID), pointer: pointer, length: Int(length),
            contactDown: contactDown)
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

    /// Begin a collection session covering **every** reporting interface of
    /// one tablet at once. Records for `duration` seconds, or until
    /// `finishDiscovery()` is called. Independent of any other `CaptureEngine`
    /// instance's session, even one running concurrently on another device.
    ///
    /// - Parameter devices: each interface to record, paired with its own
    ///   identity and descriptor. `devices[0]` names the hardware in the
    ///   capture header (`deviceInfo`); the interface that supplies the
    ///   top-level `reports` block is chosen from descriptor contents at
    ///   build time — see `buildDiscoveryResult` — so callers no longer have
    ///   to sort a pen interface to the front. Passing more than one is the
    ///   point: which interface carries the interesting traffic is exactly
    ///   what a tester submitting an unknown device cannot be expected to
    ///   know, and recording them all costs a few KB.
    func startDiscovery(
        devices: [(IOHIDDevice, CaptureDeviceInfo)],
        duration: TimeInterval = 60,
        touchSettings: DiscoveryTouchSettings? = nil,
        bluetoothAddressCandidate: String? = nil
    ) {
        guard !devices.isEmpty else { return }
        stopTimers()
        deregisterAccumulators()
        lastError = nil
        initReportsSent = []
        discoverySampleCount = 0
        discoveryStartTime = Date()
        // Zeroed per session so the counters describe this recording rather
        // than everything since launch.
        TouchPipelineProbe.reset()
        capturedTouchSettings = touchSettings
        bluetoothLinkMonitor = bluetoothAddressCandidate.flatMap {
            BluetoothLinkMonitor(addressCandidate: $0)
        }

        let started = devices.map {
            InterfaceSession(device: $0.0, info: $0.1, accumulator: DiscoveryAccumulator())
        }
        sessions = started
        // Arm each accumulator before announcing it: a report arriving between
        // these two statements must land in the fresh store, never a previous
        // session's.
        let armed = started.map { (ObjectIdentifier($0.device), $0.accumulator) }
        Self.activeAccumulators.withLock { table in
            for (key, accumulator) in armed {
                accumulator.start()
                table[key] = accumulator
            }
        }
        isRunning = true

        pollTimer = scheduledTimer(interval: 0.5, repeats: true) { [weak self] in
            guard let self, self.isRunning else { return }
            self.discoverySampleCount = self.totalSampleCount
        }
        discoveryTimer = scheduledTimer(interval: duration, repeats: false) { [weak self] in
            self?.finishDiscovery()
        }
    }

    /// Whether `device` is one of the interfaces this session is recording.
    func isRecording(_ device: IOHIDDevice) -> Bool {
        sessions.contains { $0.device === device }
    }

    /// Start recording one more interface on a session already under way,
    /// keeping everything gathered so far.
    ///
    /// A tablet's interfaces do not all attach at once — on a PTH-850 the
    /// touch interface routinely enumerates a moment *after* the sheet has
    /// opened and started recording the pen interface. Without this, that
    /// interface is absent from the file for no reason the tester could see
    /// or act on, which is the same silent half-capture recording every
    /// interface exists to prevent. Never primary: the interface that named
    /// the hardware in the header keeps that role for the whole session.
    func addInterface(device: IOHIDDevice, deviceInfo: CaptureDeviceInfo) {
        guard isRunning, !isRecording(device) else { return }
        let accumulator = DiscoveryAccumulator()
        accumulator.start()
        sessions.append(
            InterfaceSession(device: device, info: deviceInfo, accumulator: accumulator))
        let key = ObjectIdentifier(device)
        Self.activeAccumulators.withLock { $0[key] = accumulator }
    }

    /// Events recorded across every interface — what the sheet's live counter
    /// shows, so a tester watching it sees their pen *and* their fingers move
    /// the number regardless of which interface each travels on.
    private var totalSampleCount: Int {
        sessions.reduce(0) { $0 + $1.accumulator.sampleCount }
    }

    /// Cancel collection and discard everything gathered.
    func cancelDiscovery() {
        guard isRunning else { return }
        stopTimers()
        for session in sessions { session.accumulator.stop() }
        deregisterAccumulators()
        isRunning = false
        discoverySampleCount = 0
        _ = bluetoothLinkMonitor?.stopAndSummarize()
        bluetoothLinkMonitor = nil
    }

    /// Remove every interface's accumulator from the routing table so
    /// `recordRaw` stops delivering reports to them. Idempotent; safe with no
    /// active session.
    private func deregisterAccumulators() {
        guard !sessions.isEmpty else { return }
        let keys = sessions.map { ObjectIdentifier($0.device) }
        Self.activeAccumulators.withLock { table in
            for key in keys { table.removeValue(forKey: key) }
        }
        sessions = []
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
        // Close every accumulator before snapshotting so no report lands
        // between the snapshot and the end of the session.
        for session in sessions { session.accumulator.stop() }
        isRunning = false
        discoverySampleCount = totalSampleCount

        guard !sessions.isEmpty else {
            lastError = String(
                localized: "Collection ended before the tablet was identified. Nothing was saved.",
                comment: "Capture error shown when a session finishes with no device information")
            return nil
        }

        // Stopped before building: the result needs the final summary, and
        // sampling any later than this can't land in a file already written.
        let bluetoothSummary = bluetoothLinkMonitor?.stopAndSummarize()
        bluetoothLinkMonitor = nil

        // Built before deregistering: `sessions` holds the data being read.
        let result = buildDiscoveryResult(sessions: sessions, bluetoothLink: bluetoothSummary)
        deregisterAccumulators()
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

    /// Assemble the file from every interface's accumulator.
    ///
    /// The primary interface — chosen just below, by descriptor contents —
    /// also fills the top-level `reports`/`hidReportDescriptor`, which is what
    /// a `captureVersion` 6 reader (`TabletKit/tools/triage_discovery.py` as
    /// shipped) knows how to read. `deviceInfo` stays keyed to `sessions[0]`,
    /// the interface the registry lookup was built around. Every interface,
    /// primary included, is additionally listed in `interfaces`. Tool codes
    /// are unioned across interfaces, since a tool entering proximity is a
    /// property of the tablet rather than of whichever interface reported it.
    private func buildDiscoveryResult(
        sessions: [InterfaceSession], bluetoothLink: BluetoothLinkMonitor.Summary?
    ) -> DiscoveryResult {
        // Which interface fills the top-level block, in order of preference:
        //
        //  1. The one whose descriptor declares pen fields (pressure/tilt/…),
        //     *unless* it carried almost no traffic this session. The pen
        //     interface is the one a reader means by "the device's pen
        //     report", and which interface declares pen fields is a fixed
        //     property of the hardware — not of attach order or of what the
        //     tester exercised. The PTH-860 USB needs this: its pen interface
        //     attaches second and advertises a Generic Desktop / Mouse
        //     primary usage, so nothing but the descriptor contents picks it
        //     out. But when the pen is simply absent for the whole session
        //     (a touch-only recording), that interface streams a handful of
        //     status reports and nothing else — leading with it would put a
        //     near-empty block at the top level, the same failure step 3
        //     guards against. So it only wins if it carried at least
        //     `minPrimaryShare` of the busiest interface's sample count.
        //     Across the PTH-860 captures the split is unambiguous: pen
        //     present ⇒ the pen interface is the busiest (share 1.0); pen
        //     absent ⇒ share ~0.03.
        //  2. Else the driver-designated interface, if it recorded anything.
        //  3. Else the busiest — the PTH-850 case, where the vendor interface
        //     attaches first, leads the session, and then sits silent for the
        //     whole run while the other carries every sample. Leading with the
        //     silent one would put an empty `reports` at the top level.
        //
        // Sample count alone was rejected as the *primary* rule deliberately:
        // it would make a pen-heavy and a touch-heavy capture of the same
        // tablet disagree about the primary. The descriptor predicate stays
        // primary; sample share is only a floor under it.
        let minPrimaryShare = 0.1
        let busiestCount = sessions.map(\.accumulator.sampleCount).max() ?? 0
        let primaryDevice =
            sessions.first(where: {
                $0.info.parsedDescriptor?.declaresPenFields == true
                    && (busiestCount == 0
                        || Double($0.accumulator.sampleCount) >= Double(busiestCount) * minPrimaryShare)
            })?.device
            ?? (sessions[0].accumulator.sampleCount > 0
                ? sessions[0].device
                : (sessions.max { $0.accumulator.sampleCount < $1.accumulator.sampleCount }
                    ?? sessions[0]).device)

        var interfaces: [DiscoveryInterface] = []
        var allToolCodes: Set<UInt16> = []

        for session in sessions {
            let (reports, toolCodes) = session.accumulator.snapshot()
            allToolCodes.formUnion(toolCodes)
            interfaces.append(
                DiscoveryInterface(
                    usagePage: session.info.usagePage.map { String(format: "0x%04X", $0) },
                    usage: session.info.usage.map { String(format: "0x%04X", $0) },
                    isPrimary: session.device === primaryDevice,
                    sampleCount: session.accumulator.sampleCount,
                    reports: Self.reportSummaries(
                        reports, descriptor: session.info.parsedDescriptor),
                    hidReportDescriptor: session.info.parsedDescriptor))
        }

        // Ordered so the interface filling the top-level block is also
        // `interfaces[0]`, matching what the `isPrimary` flag claims.
        if let idx = interfaces.firstIndex(where: { $0.isPrimary }), idx != 0 {
            interfaces.insert(interfaces.remove(at: idx), at: 0)
        }

        // Identity still comes from the interface the driver reads pen reports
        // from: every interface reports the same VID/PID, but that one is the
        // one whose name the registry lookup was built around.
        let deviceInfo = sessions[0].info
        let toolCodeHex = allToolCodes.map { String(format: "0x%04X", $0) }.sorted()
        let touchPipeline = TouchPipelineProbe.snapshot()
        var notes = "Observed tool codes: \(toolCodeHex.isEmpty ? "none" : toolCodeHex.joined(separator: ", "))"
        if allToolCodes.contains(0x080A) {
            notes += " (eraser capable)"
        }
        // Only worth saying when there was more than one interface: on the
        // common single-interface device it would be noise in every file.
        if interfaces.count > 1 {
            let quiet = interfaces.filter { $0.sampleCount == 0 }.count
            notes += ". Recorded \(interfaces.count) interfaces"
            notes += quiet == 0 ? "." : ", \(quiet) of which sent nothing."
        }
        // Surfaced in the notes line, not just the structured block: the one
        // number that says whether a touch problem is ours is how many
        // contacts we decoded versus how many reached a gesture, and it
        // should be readable without opening the file to the right key.
        if !touchPipeline.isEmpty {
            notes += " Touch: decoded \(touchPipeline.framesDecoded) frames"
            notes += "/\(touchPipeline.contactsDecoded) contacts, tracked"
            notes += " \(touchPipeline.framesTracked)."
        }

        // Only worth recording if any RSSI sample actually landed — a
        // candidate that resolved to the wrong (or no) device produces a
        // block of pure zeros/nils that would read as "signal is fine"
        // rather than "we have no data."
        let discoveryBluetoothLink = bluetoothLink.flatMap { summary -> DiscoveryBluetoothLink? in
            guard summary.sampleCount > 0 else { return nil }
            return DiscoveryBluetoothLink(
                addressCandidate: summary.addressCandidate,
                sampleCount: summary.sampleCount,
                disconnectedSampleCount: summary.disconnectedSampleCount,
                addressLikelyWrong: summary.addressLikelyWrong,
                rssiMin: summary.rssiMin,
                rssiMax: summary.rssiMax,
                rssiAvg: summary.rssiAvg,
                rawRSSIMin: summary.rawRSSIMin,
                rawRSSIMax: summary.rawRSSIMax,
                rawRSSIAvg: summary.rawRSSIAvg)
        }

        return DiscoveryResult(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appBuildDate: Bundle.main.object(forInfoDictionaryKey: "MockTabBuildDate") as? String,
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
            reports: interfaces[0].reports,
            hidReportDescriptor: interfaces[0].hidReportDescriptor,
            interfaces: interfaces.count > 1 ? interfaces : nil,
            initReports: initReportsSent.isEmpty ? nil : initReportsSent,
            observedToolCodes: toolCodeHex.isEmpty ? nil : toolCodeHex,
            touchSettings: capturedTouchSettings,
            touchPipeline: touchPipeline.isEmpty ? nil : touchPipeline,
            bluetoothLink: discoveryBluetoothLink,
            notes: notes,
            submitterContact: nil
        )
    }

    /// Summarize one interface's accumulated reports.
    ///
    /// - Parameter descriptor: **that interface's own** parsed descriptor, not
    ///   the device's primary one. `descriptorReadable` below is a claim about
    ///   whether this report's fields are declared, and checking a touch
    ///   interface's reports against a pen interface's descriptor marks every
    ///   one of them opaque — the same mis-attribution across sibling
    ///   interfaces that `WacomKnownDevice`'s `sender`-based routing fixed.
    private static func reportSummaries(
        _ reports: [UInt8: DiscoveryAccumulator.ReportStats],
        descriptor: LiveHIDDescriptorInspector.Parsed?
    ) -> [String: DiscoveryReportSummary] {
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
            let descriptorReadable = descriptor?.reports["input:\(idHex)"]?.isReadable

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

            // Only meaningful once a report has arrived more than once — a
            // single-arrival report has no gap and `gapBuckets` is all zeros.
            let arrivalGaps: DiscoveryArrivalGaps? =
                stats.sampleCount > 1
                ? DiscoveryArrivalGaps(
                    bucketEdgesMs: DiscoveryAccumulator.ReportStats.gapBucketEdgesMs,
                    buckets: stats.gapBuckets,
                    inGestureBuckets: stats.inGestureGapBuckets.contains { $0 != 0 }
                        ? stats.inGestureGapBuckets : nil,
                    idleBuckets: stats.idleGapBuckets.contains { $0 != 0 }
                        ? stats.idleGapBuckets : nil,
                    longestGaps: stats.longestGaps.map {
                        DiscoveryArrivalGaps.Gap(ms: $0.ms, endedAtSessionMs: $0.atElapsedMs)
                    })
                : nil

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
                byteStatsByDiscriminator: Self.discriminatedStats(stats),
                arrivalGaps: arrivalGaps
            )
        }

        return reportSummaries
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
            // Only where the list is lossy; a complete list needs no backstop.
            valueMask: truncated ? seen.valueMaskHex : nil,
            signedMagnitudeMax: truncated ? seen.signedMagnitudeMax : nil,
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
