// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid
import OSLog
import TabletKit

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "driver")

/// One TabletKit session transport, in the driver slot a `DeviceContext`
/// holds. The session opens and closes it; this carries what the panes and
/// settings read, and the handler its reports arrive at.
final class SessionDriver: TabletDevice, @unchecked Sendable {
    let transportID: TabletTransport.ID
    let handler: TransportEventHandler
    let controls: TabletControls
    /// Set on main when a receiver names its tablet.
    var spec: DigitizerSpec
    private weak var transport: TabletTransport?

    /// What the session guessed an unknown tablet as; nil for a registry one.
    let guessedAs: UnclaimedKind?
    /// Another maker's tablet, switched on and sized from its own answer.
    let isSelfDescribed: Bool
    /// For another maker's unknown tablet, the brand its USB strings suggest.
    let detectedBrand: String?
    /// A CTL-x100 Intuos in Android mode, which swaps Wacom's vendor ID for
    /// 0x2D1F and offers only a basic pen report. Holding the outer
    /// ExpressKeys switches it back to PC mode.
    let isWacomAndroidMode: Bool
    /// An unknown tablet's descriptor, for the diagnostic report.
    let parsedDescriptor: LiveHIDDescriptorInspector.Parsed?

    private static let androidModeVendorID = 0x2D1F
    private static let androidModeProductIDs: Set<Int> = [0x0374, 0x0375, 0x0376, 0x0378, 0x03C5, 0x03C7]

    @MainActor
    init(_ transport: TabletTransport, callbacks: DeviceRouter.Callbacks) {
        transportID = transport.id
        controls = transport.controls
        spec = transport.digitizer
        self.transport = transport
        guessedAs = transport.guessedAs
        isSelfDescribed = transport.spec.format == .ucLogic
        let primary = transport.primary
        let device = (primary as? IOKitHIDInterface)?.device
        if guessedAs == .genericDigitizer {
            let manufacturer = device.flatMap { IOHIDDeviceGetProperty($0, kIOHIDManufacturerKey as CFString) as? String }
            detectedBrand = BrandHeuristic.likelyBrand(manufacturer: manufacturer, product: primary.productName)
        } else {
            detectedBrand = nil
        }
        isWacomAndroidMode = primary.vendorID == Self.androidModeVendorID
            && Self.androidModeProductIDs.contains(primary.productID)
        parsedDescriptor = guessedAs != nil ? device.map(LiveHIDDescriptorInspector.read) : nil
        handler = TransportEventHandler(
            spec: transport.spec, isBluetooth: transport.isBluetooth,
            isWireless: transport.isWireless, callbacks: callbacks)
    }

    /// The session opened it already.
    func open() {}
    /// The session closes it when its interfaces go.
    func close() {}

    func reawaken() {
        let send: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.transport?.reawaken() }
        }
        if Thread.isMainThread { send() } else { DispatchQueue.main.async(execute: send) }
    }

    @MainActor
    func pairedTabletChanged() {
        if let transport { spec = transport.digitizer }
    }
}

/// Turns one transport's decoded reports into the app's callbacks, on the
/// input thread: capture hooks, then pen and touch samples paced across the
/// interval a Bluetooth report spans, then everything else at once.
///
/// HIDThread-confined, like the driver it came from.
final class TransportEventHandler: TabletInputSink, @unchecked Sendable {
    private let spec: TabletSpec
    private let isBluetooth: Bool
    /// A wireless kit receiver, whose level reads high while its tablet
    /// charges (96% whatever the charge).
    private let isWireless: Bool
    private let callbacks: DeviceRouter.Callbacks
    /// The kit's last link status; its receiver repeats it twice a second.
    private var wirelessLinked: Bool?
    /// Interfaces joined after the primary, for telling their report
    /// streams apart in a capture.
    var siblingCount = 0

    private lazy var batchFramePacer = BatchFramePacer { [weak self] frame, timestampNs in
        guard let self else { return }
        InputInjector.currentReportTimestampNs = timestampNs
        self.deliver(frame)
        InputInjector.currentReportTimestampNs = 0
    }
    /// Arrival of the previous report, for measuring a batch's real interval.
    private var lastBatchReportTimestampNs: UInt64 = 0

    // The PTK-870 over Bluetooth LE sends one sample per report but several
    // reports per radio window: four Pro Pen 3 samples within 3 ms, then
    // nothing for 15 ms (2026-10-09 captures).
    /// Arrival of the current window's first pen sample; 0 when none is open.
    private var penWindowStartNs: UInt64 = 0
    /// Arrival of the most recent single-sample pen report.
    private var lastPenReportNs: UInt64 = 0
    /// Gap between the last two window starts.
    private var penWindowIntervalNs: UInt64 = 0
    /// Samples posted or queued in the current window.
    private var penWindowCount = 0
    /// Sample counts of recently closed windows; their maximum sets the spacing.
    private var recentPenWindowCounts: [Int] = []

    /// Whether each interface's last report decoded to a touch contact, so a
    /// discovery capture can tell a mid-gesture gap from an idle one.
    private var lastReportHadContact: [ObjectIdentifier: Bool] = [:]
    /// Last logged pairing-table summary; the receiver repeats it twice a second.
    private var lastRemotePairingSummary: String?

    /// Reports closer together than this share one radio window. Measured
    /// on a PTK-870 over Bluetooth LE: samples within a window land at most
    /// 3.8 ms apart, windows at least 13 ms apart.
    private static let penWindowGapNs: UInt64 = 5_000_000

    init(spec: TabletSpec, isBluetooth: Bool, isWireless: Bool, callbacks: DeviceRouter.Callbacks) {
        self.spec = spec
        self.isBluetooth = isBluetooth
        self.isWireless = isWireless
        self.callbacks = callbacks
    }

    // MARK: - From the session

    /// Every report, before decoding.
    func didReceive(_ report: HIDReport, at ns: UInt64, from interface: any HIDInterface) {
        // Kernel receipt to here. Spikes mean the scheduler starved HIDThread.
        if ns != 0 { LatencyProbe.shared.record(kernelTimestamp: Self.ticks(ns)) }
        guard let device = (interface as? IOKitHIDInterface)?.device else { return }
        let pointer = report.pointer
        CaptureEngine.recordRaw(
            device: device, reportID: UInt32(report.count > 0 ? pointer[0] : 0), pointer: pointer,
            length: report.count, contactDown: lastReportHadContact[ObjectIdentifier(device)])
    }

    /// One report's events.
    func didDecode(_ events: [TabletEvent], from report: HIDReport, on interface: any HIDInterface, at ns: UInt64) {
        let signpost = PipelineSignposts.begin("Report")
        defer { PipelineSignposts.end("Report", signpost) }
        InputInjector.currentReportTimestampNs = ns
        defer { InputInjector.currentReportTimestampNs = 0 }
        let device = (interface as? IOKitHIDInterface)?.device
        let name = spec.name
        do {
            let pointer = report.pointer
            let tag = siblingCount > 1 && device != nil
                ? "\(name) [\(ObjectIdentifier(device!).hashValue & 0xFFFF)]" : name
            HIDCapture.shared.record(
                tag: tag, report: pointer, length: report.count, decoded: events, productID: spec.productID)
        }
        if events.isEmpty {
            CaptureActivityProbe.noteUndecoded()
        } else {
            CaptureActivityProbe.note(events)
        }
        let (frames, touchStamps) = collect(events, name: name)
        if let device {
            let key = ObjectIdentifier(device)
            if events.contains(where: { if case .touch = $0 { true } else { false } }) {
                lastReportHadContact[key] = frames.contains {
                    if case .touch(let c) = $0 { !c.isEmpty } else { false }
                }
            } else {
                lastReportHadContact[key] = nil
            }
        }
        let deferred = dispatchBatch(frames, reportTimestampNs: ns, touchFrameStamps: touchStamps)
        // Receipt to posted events, unless the pacer still holds some of them.
        if ns != 0 && !deferred {
            LatencyProbe.shared.recordPipelineComplete(kernelTimestamp: Self.ticks(ns))
        }
    }

    private static func ticks(_ ns: UInt64) -> UInt64 {
        UInt64(Double(ns) / LatencyProbe.timebaseFactor)
    }

    // MARK: - Events to callbacks

    /// Pen and touch samples queue, in decode order, so a Bluetooth report's
    /// several samples can be paced. They share one queue because touch
    /// injection reads live pen proximity. Everything else goes at once; a
    /// report's other events always precede its samples.
    private func collect(_ events: [TabletEvent], name: String) -> (frames: [BatchedFrame], touchStamps: [Int: UInt16]) {
        var frames: [BatchedFrame] = []
        var touchStamps: [Int: UInt16] = [:]
        for event in events {
            switch event {
            case .pen(let point):
                frames.append(.pen(point))
            case .tool(let tool):
                // Leave is inferred from the pen point.
                guard tool.phase == .enter else { break }
                callbacks.onToolEnter(tool.identity)
            case .pad(let pad):
                callbacks.onAux(pad)
            case .dial(let index, let delta):
                callbacks.onWheel(index, delta)
            case .touch(let frame):
                if let time = frame.deviceTime { touchStamps[frames.count] = time }
                frames.append(.touch(frame.contacts))
            case .device(let device):
                switch device.kind {
                case .battery:
                    if let b = device.battery {
                        callbacks.onBattery(isWireless && b.charging ? nil : b.percent, b.charging)
                    }
                case .wireless:
                    let linked: Bool? = switch device.wireless {
                    case .active: true
                    case .lost: false
                    default: nil
                    }
                    if isWireless, let linked, linked != wirelessLinked {
                        wirelessLinked = linked
                        callbacks.onWirelessLink(linked)
                    }
                case .mouseButtons:
                    if let mask = device.mouseButtons { callbacks.onMouseButton(mask) }
                case .toolSupport:
                    logger.info("\(name, privacy: .public): \(device.unsupportedToolNote ?? "", privacy: .public)")
                case .remotePairing:
                    let paired = (device.remotePairing ?? []).filter { $0.connected }
                        .map { "\($0.index):\($0.serial)" }.joined(separator: ",")
                    if paired != lastRemotePairingSummary {
                        lastRemotePairingSummary = paired
                        logger.info("\(name, privacy: .public): paired remotes [\(paired.isEmpty ? "none" : paired, privacy: .public)]")
                    }
                default:
                    break
                }
            }
        }
        return (frames, touchStamps)
    }

    /// Delivers a report's samples, pacing them across the report's real
    /// interval when there's more than one (a Bluetooth batch; see
    /// `BatchFramePacer`). Returns true if any were left to the pacer.
    @discardableResult
    private func dispatchBatch(
        _ frames: [BatchedFrame], reportTimestampNs: UInt64, touchFrameStamps: [Int: UInt16]
    ) -> Bool {
        if pacePenWindowSample(frames, reportTimestampNs: reportTimestampNs) { return true }
        // Flush first: a queued sample is older than anything decoded now,
        // and a pen lift posted ahead of it left proximity stuck on, which
        // silenced touch (2026-08-22). A report with no samples has nothing
        // to order against, and flushing for it would burst a paced window.
        let flushed = frames.isEmpty ? 0 : batchFramePacer.flush()
        if !frames.isEmpty {
            TouchPipelineProbe.note { $0.noteBatch(frameCount: frames.count) }
        }
        if flushed > 0 {
            TouchPipelineProbe.note { $0.pacerFlushDeliveredFrames += flushed }
        }
        // Every report stamps this, single-sample or not, so the interval is
        // this report's own (2026-08-25).
        let previous = lastBatchReportTimestampNs
        lastBatchReportTimestampNs = reportTimestampNs

        guard let first = frames.first else { return false }
        guard frames.count > 1 else {
            deliver(first)
            return false
        }
        let intervalNs = previous != 0 && reportTimestampNs > previous ? reportTimestampNs - previous : 0
        // Outside this band the batch came from noise or a stall, not the
        // device's cadence; pacing a stall would crawl through stale samples.
        guard (4_000_000...80_000_000).contains(intervalNs) else {
            for frame in frames { deliver(frame) }
            return false
        }
        // The oldest sample is already the stalest; post it now and pace the rest.
        deliver(first)
        let perFrameDelayNs = intervalNs / UInt64(frames.count)
        // A touch frame's device-clock stamp replaces the even-spacing guess.
        // Only differences within this container count, anchored to the
        // newest stamped frame, so the clock's 6.55 s wrap can't be reached.
        let anchor = touchFrameStamps.keys.max().flatMap { key in
            touchFrameStamps[key].map { (index: key, stamp: $0) }
        }
        let maxPlausibleSpanCounts = UInt64(TouchFrame.deviceTimeCountsPerBluetoothFrame) * 16
        let scheduled: [(frame: BatchedFrame, timestampNs: UInt64)] = frames.dropFirst()
            .enumerated().map { offset, frame in
                let index = offset + 1
                let interpolated = reportTimestampNs - UInt64(frames.count - 1 - index) * perFrameDelayNs
                guard let anchor, let stamp = touchFrameStamps[index] else { return (frame, interpolated) }
                let countsBehind = UInt64(anchor.stamp &- stamp)
                guard countsBehind <= maxPlausibleSpanCounts else { return (frame, interpolated) }
                // The anchor is the report's arrival: IntuosV2Decoder appends
                // touch frames after pen frames, so the newest stamped frame
                // is the last one.
                let nsBehind = UInt64(Double(countsBehind) * TouchFrame.deviceTimeMsPerCount * 1_000_000.0)
                guard reportTimestampNs > nsBehind else { return (frame, interpolated) }
                return (frame, reportTimestampNs - nsBehind)
            }
        batchFramePacer.schedule(scheduled, interval: TimeInterval(perFrameDelayNs) / 1_000_000_000.0)
        return true
    }

    /// Paces Bluetooth pen samples that arrive as separate reports within one
    /// radio window. The first sample of a window posts at once; later ones
    /// queue at `windowStart + k × interval ÷ samplesPerWindow`. Like Wacom's
    /// driver, this assumes a pen samples evenly. Returns true if it queued
    /// this report's sample.
    private func pacePenWindowSample(_ frames: [BatchedFrame], reportTimestampNs now: UInt64) -> Bool {
        guard isBluetooth, now != 0, frames.count == 1, case .pen = frames[0] else {
            if frames.count > 1 { penWindowStartNs = 0 }
            return false
        }
        let sinceLast = lastPenReportNs != 0 && now > lastPenReportNs ? now - lastPenReportNs : .max
        lastPenReportNs = now
        guard penWindowStartNs != 0, sinceLast < Self.penWindowGapNs else {
            if penWindowStartNs != 0 {
                recentPenWindowCounts.append(penWindowCount)
                if recentPenWindowCounts.count > 8 { recentPenWindowCounts.removeFirst() }
                penWindowIntervalNs = now - penWindowStartNs
            }
            penWindowStartNs = now
            penWindowCount = 1
            return false
        }
        let index = penWindowCount
        penWindowCount += 1
        let perWindow = max(recentPenWindowCounts.max() ?? 0, penWindowCount)
        // No steady rhythm yet (first window after a gap): post now, in order.
        guard (6_000_000...40_000_000).contains(penWindowIntervalNs) else { return false }
        let targetNs = penWindowStartNs + penWindowIntervalNs * UInt64(index) / UInt64(perWindow)
        let delay = targetNs > now ? Double(targetNs - now) / 1_000_000_000.0 : 0
        batchFramePacer.append(frames[0], timestampNs: targetNs, delay: delay)
        return true
    }

    private func deliver(_ frame: BatchedFrame) {
        switch frame {
        case .pen(let point): callbacks.onTablet(point)
        case .touch(let contacts): callbacks.onTouch(contacts)
        }
    }
}
