// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import os
import TabletKit

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "capture")

/// Raw-HID capture buffer: records decoded field values alongside each
/// report and condenses steady-state runs into value-range summaries.
///
/// Call `record(tag:report:length:decoded:)` after the caller's own
/// `decoder.decode(...)`, passing that result through — this never decodes
/// on its own. Pass `decoded: nil` when no `TabletReportDecoder` is in
/// scope (e.g. `GenericHIDDigitizer`'s element-based path); those reports
/// still get a raw hex line, just no annotation.
///
/// Durability: periodically flushed to disk (`flushIfDue()`) and
/// auto-stopped after `maxCaptureDuration`, so memory stays bounded and a
/// crash loses at most one flush interval.
///
/// Reachable from InfoView's Diagnostics section, behind Option — the
/// advanced sibling of "Collect Device Data…" (`CaptureEngine`/
/// `DiscoveryAccumulator`), which statistically summarizes an *unknown*
/// protocol for triage. This one checks a *known* decoder's output against
/// real hardware, hence recording every report instead of a histogram.
///
/// Thread safety: `record(...)` runs on HIDThread; `start/stop/clear/
/// flushIfDue` and the published reads run on main. State is guarded by one
/// unfair lock.
final class HIDCapture {

    static let shared = HIDCapture()
    private init() {}

    /// Wall-clock ceiling on one session — an accidentally-left-running
    /// capture auto-stops and saves rather than growing forever.
    static let maxCaptureDuration: TimeInterval = 30 * 60

    /// How often `flushIfDue()` writes buffered samples to disk.
    static let flushInterval: TimeInterval = 15

    /// A flush only sends samples older than `graceWindow` to the
    /// condenser, holding back the freshest slice. Without this, a quiet
    /// stream's next batch can flush (and land on disk) after several
    /// already-flushed batches from a busier stream, even though it's
    /// chronologically older — confirmed on a real capture. See also
    /// `Condenser`'s watermark, which handles the same problem once a run
    /// is already inside the condenser.
    static let graceWindow: TimeInterval = 3

    /// Indexed by nibble so the per-report hex builder avoids materializing
    /// this each call.
    private static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

    // MARK: - Sample storage

    /// One recorded report, kept structured (not pre-formatted) so it can
    /// render verbatim or fold into a run summary.
    struct Sample {
        var elapsed: TimeInterval
        var tag: String
        var reportID: UInt8
        var length: Int
        var hex: String
        var decoded: [DecodeResult]?
        /// Cheap-to-compare summary of `decoded`, so condensing can detect
        /// "did anything change" without re-parsing `hex`/`decoded`.
        var signature: Signature
    }

    /// The fields that decide "same steady state" vs. "transition worth
    /// keeping verbatim." Proximity/eraser/button/tool-identity changes are
    /// always transitions; position/pressure/tilt/hover only ever widen the
    /// enclosing run's range.
    struct Signature: Equatable {
        var inProximity: Bool?
        var eraser: Bool?
        var buttonsDown: [Bool]?
        var toolEnterSerial: UInt32?
        var hasOneShotEvent: Bool  // toolEnter/battery/wireless/toolCompatibility/mouseButton/wheel present this report
        /// True when this sample has no decoder. Two undecoded samples must
        /// never compare equal — otherwise every all-nil signature would
        /// collapse an entire unfamiliar report stream into one line.
        var isUndecoded: Bool = false

        static func == (lhs: Signature, rhs: Signature) -> Bool {
            if lhs.isUndecoded || rhs.isUndecoded { return false }
            return lhs.inProximity == rhs.inProximity && lhs.eraser == rhs.eraser
                && lhs.buttonsDown == rhs.buttonsDown && lhs.toolEnterSerial == rhs.toolEnterSerial
                && lhs.hasOneShotEvent == rhs.hasOneShotEvent
        }
    }

    // MARK: - Per-report-ID summary (running, for the header block)

    /// Running per-report-ID stats for the header block — categorize the
    /// protocol at a glance. Deliberately not a full histogram like
    /// `DiscoveryAccumulator`; this tool's job is decode correctness.
    struct ReportIDSummary {
        var count = 0
        var minLength = Int.max
        var maxLength = 0
        /// First sample's decode, so the header shows what this report *is*
        /// without paging through the body.
        var firstDecoded: String?
    }

    // MARK: - State (guarded by `state`'s lock)

    private struct State {
        var isCapturing = false
        var reportCount = 0
        /// Samples recorded since the last flush.
        var samples: [Sample] = []
        var summaries: [UInt8: ReportIDSummary] = [:]
        var startTime: Date = .init()
        /// Destination file, fixed at `start()`.
        var fileURL: URL?
        var lastFlushAt: Date = .init()
        /// Carries run continuity across flush boundaries.
        var condenser = Condenser()
        var headerWritten = false
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// Drives `flushIfDue()` independent of any view's lifecycle — a
    /// UI-owned poll timer stops when its view isn't on screen, and
    /// durability must not depend on the user staying on that tab. Owned by
    /// `self`, not `state`'s lock (`Timer` isn't `Sendable`); only touched
    /// from main.
    private var backgroundFlushTimer: Timer?

    var isCapturing: Bool { state.withLock { $0.isCapturing } }
    var reportCount: Int { state.withLock { $0.reportCount } }
    var elapsedSinceStart: TimeInterval {
        state.withLock { $0.isCapturing ? Date().timeIntervalSince($0.startTime) : 0 }
    }

    // MARK: - Control

    /// Writes the file header immediately, so a crash before the first
    /// flush still leaves a valid file behind.
    func start() {
        let url = Self.makeFileURL(for: Date())
        state.withLock {
            $0.samples.removeAll()
            $0.summaries.removeAll()
            $0.reportCount = 0
            $0.startTime = Date()
            $0.fileURL = url
            $0.lastFlushAt = Date()
            $0.condenser = Condenser()
            $0.headerWritten = false
            $0.isCapturing = true
        }
        Self.writeHeader(to: url, startTime: state.withLock { $0.startTime })
        state.withLock { $0.headerWritten = true }

        backgroundFlushTimer?.invalidate()
        backgroundFlushTimer = Timer.scheduledTimer(withTimeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
            self?.flushIfDue()
        }
    }

    func stop() {
        state.withLock { $0.isCapturing = false }
        backgroundFlushTimer?.invalidate()
        backgroundFlushTimer = nil
    }

    func clear() {
        state.withLock {
            $0.samples.removeAll()
            $0.summaries.removeAll()
            $0.reportCount = 0
            $0.fileURL = nil
        }
    }

    /// Flushes if `flushInterval` has elapsed (or unconditionally if
    /// `force`), and auto-stops once `maxCaptureDuration` is reached.
    @discardableResult
    func flushIfDue(force: Bool = false) -> URL? {
        let now = Date()
        let shouldAutoStop: Bool = state.withLock {
            $0.isCapturing && now.timeIntervalSince($0.startTime) >= Self.maxCaptureDuration
        }
        if shouldAutoStop {
            logger.info("HIDCapture: auto-stopping after \(Self.maxCaptureDuration, privacy: .public)s ceiling")
            stop()
        }
        let due: Bool = state.withLock {
            force || now.timeIntervalSince($0.lastFlushAt) >= Self.flushInterval
        }
        guard due else { return nil }
        return flush()
    }

    /// Splits a buffer into (old enough to flush, must stay buffered) using
    /// the newest sample's `elapsed` as the age watermark. A pure function,
    /// pulled out of `flush()` so the grace-window logic can be tested
    /// without real timers or locking.
    static func splitByGraceWindow(_ samples: [Sample], graceWindow: TimeInterval) -> (old: [Sample], recent: [Sample], cutoff: TimeInterval) {
        let newestElapsed = samples.map(\.elapsed).max() ?? 0
        let cutoff = newestElapsed - graceWindow
        return (samples.filter { $0.elapsed <= cutoff }, samples.filter { $0.elapsed > cutoff }, cutoff)
    }

    /// Appends the condensed output of every sample older than
    /// `graceWindow` to the file, leaving the rest buffered.
    @discardableResult
    private func flush() -> URL? {
        // One lock acquisition for split + removal — two separate
        // `withLock` calls would let a concurrent `record()` append get
        // silently dropped by a wholesale reassignment.
        let result: (lines: [String], url: URL)? = state.withLock {
            guard let url = $0.fileURL, !$0.samples.isEmpty else { return nil }
            let split = Self.splitByGraceWindow($0.samples, graceWindow: Self.graceWindow)
            guard !split.old.isEmpty else { return nil }
            $0.samples.removeAll { $0.elapsed <= split.cutoff }
            let lines = $0.condenser.feed(split.old)
            $0.lastFlushAt = Date()
            return (lines, url)
        }
        guard let result, !result.lines.isEmpty else { return nil }

        Self.append(lines: result.lines, to: result.url)
        return result.url
    }

    /// Flushes everything remaining, closing out any still-open run. Call
    /// after `stop()`.
    @discardableResult
    func finish() -> URL? {
        let snapshot: (samples: [Sample], url: URL?)? = state.withLock {
            ($0.samples, $0.fileURL)
        }
        guard let url = snapshot?.url else { return nil }

        let lines: [String] = state.withLock {
            var result = $0.condenser.feed($0.samples)
            result.append(contentsOf: $0.condenser.finish())
            $0.samples.removeAll()
            return result
        }
        if !lines.isEmpty {
            Self.append(lines: lines, to: url)
        }
        return url
    }

    // MARK: - Recording

    /// Appends one report to the buffer. Called from IOHIDReportCallback on
    /// HIDThread — must stay allocation-light. `decoded` is the caller's
    /// own already-computed result, passed after its own decode call.
    func record(
        tag: String, report: UnsafePointer<UInt8>, length: Int,
        decoded: [DecodeResult]? = nil
    ) {
        guard length > 0 else { return }

        let captureStart: Date? = state.withLock {
            $0.isCapturing ? $0.startTime : nil
        }
        guard let start = captureStart else { return }

        let elapsed = Date().timeIntervalSince(start)

        // Built into a single allocation rather than `length` intermediate
        // Strings + join — dominant cost while capturing at ~133 Hz.
        let hexCount = length == 0 ? 0 : length * 3 - 1  // "AB AB AB"
        let hex = String(unsafeUninitializedCapacity: hexCount) { buf in
            let digits = Self.hexDigits
            var p = 0
            for i in 0..<length {
                if i > 0 {
                    buf[p] = 0x20  // ' '
                    p += 1
                }
                let b = report[i]
                buf[p] = digits[Int(b >> 4)]
                buf[p + 1] = digits[Int(b & 0x0F)]
                p += 2
            }
            return p
        }
        let id0 = report[0]

        let decodedSummary = decoded.flatMap(Self.summarize)
        let signature = Self.signature(for: decoded)

        state.withLock {
            // Re-check: capture may have stopped while formatting.
            guard $0.isCapturing else { return }
            $0.samples.append(
                Sample(
                    elapsed: elapsed, tag: tag, reportID: id0, length: length, hex: hex,
                    decoded: decoded, signature: signature))
            $0.reportCount += 1
            var summary = $0.summaries[id0] ?? ReportIDSummary()
            summary.count += 1
            summary.minLength = min(summary.minLength, length)
            summary.maxLength = max(summary.maxLength, length)
            if summary.count == 1 {
                summary.firstDecoded = decodedSummary
            }
            $0.summaries[id0] = summary
        }
    }

    // MARK: - Decode-result formatting

    /// Renders one report's `[DecodeResult]` tersely for the end of a
    /// hex-dump line — only the fields relevant to eyeballing decode
    /// sanity, not every field on every case.
    static func summarize(_ results: [DecodeResult]) -> String? {
        guard !results.isEmpty else { return nil }
        let parts: [String] = results.compactMap { result in
            switch result {
            case .none:
                return nil
            case .pen(let p):
                let tilt = String(format: "(%.2f,%.2f)", p.tiltX, p.tiltY)
                var flags: [String] = []
                if p.inProximity { flags.append("prox") }
                if p.eraser { flags.append("eraser") }
                if p.penButton1 { flags.append("btn1") }
                if p.penButton2 { flags.append("btn2") }
                let flagStr = flags.isEmpty ? "" : " " + flags.joined(separator: ",")
                return "pen x=\(p.x) y=\(p.y) p=\(p.pressure) tilt=\(tilt) hover=\(p.hoverDistance)\(flagStr)"
            case .toolEnter(let t):
                return "toolEnter serial=\(t.serial) code=0x\(String(t.toolCode, radix: 16)) eraser=\(t.isEraser) mouse=\(t.isMouse)"
            case .aux(let a):
                let downs = a.buttons.enumerated().filter { $0.element }.map { String($0.offset) }
                return "aux buttons=[\(downs.joined(separator: ","))]"
            case .wireless(let w):
                switch w {
                case .active: return "wireless=active"
                case .lost: return "wireless=lost"
                case .lowBattery: return "wireless=lowBattery"
                case .unknown(let v): return "wireless=unknown(0x\(String(v, radix: 16)))"
                }
            case .battery(let percent, let charging):
                return "battery=\(percent)% charging=\(charging)"
            case .toolCompatibility(let msg):
                return "toolCompatibility=\"\(msg)\""
            case .mouseButton(let mask):
                return "mouseButton=0x\(String(mask, radix: 16))"
            case .wheel(let index, let delta):
                return "wheel[\(index)]=\(delta)"
            case .touch(let contacts):
                return "touch contacts=\(contacts.count)"
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// Extracts the "steady state vs. transition" fields from decoded
    /// results. `decoded == nil` gets an all-nil, `isUndecoded` signature —
    /// see `Signature.isUndecoded`.
    static func signature(for results: [DecodeResult]?) -> Signature {
        guard let results else {
            return Signature(
                inProximity: nil, eraser: nil, buttonsDown: nil, toolEnterSerial: nil,
                hasOneShotEvent: false, isUndecoded: true)
        }
        var sig = Signature(
            inProximity: nil, eraser: nil, buttonsDown: nil, toolEnterSerial: nil,
            hasOneShotEvent: false)
        for result in results {
            switch result {
            case .pen(let p):
                sig.inProximity = p.inProximity
                sig.eraser = p.eraser
                sig.buttonsDown = [
                    p.penButton1, p.penButton2, p.penButton3, p.penButton4, p.penButton5,
                ]
            case .aux(let a):
                sig.buttonsDown = a.buttons
            case .toolEnter, .battery, .wireless, .toolCompatibility, .mouseButton, .wheel:
                sig.hasOneShotEvent = true
                if case .toolEnter(let t) = result { sig.toolEnterSerial = t.serial }
            case .touch, .none:
                break
            }
        }
        return sig
    }

    // MARK: - Condensing

    /// Value-range accumulator for one run of same-key steady-state
    /// samples. Tracks the `TabletPoint` axes plus a raw first/last hex
    /// sample for undecoded report IDs.
    ///
    /// A min/max range alone can hide a single bad sample or discontinuity
    /// inside thousands of absorbed reports — `absorb` therefore rejects
    /// (via `isOutlier`) any sample whose per-axis delta is a large outlier
    /// relative to what this run has seen so far.
    fileprivate struct RunAccumulator {
        var startElapsed: TimeInterval
        var reportID: UInt8
        var tag: String
        var count = 0
        var minLength = Int.max
        var maxLength = 0
        var firstHex: String = ""
        var lastHex: String = ""
        var xRange: ClosedRange<Int>?
        var yRange: ClosedRange<Int>?
        var pressureRange: ClosedRange<Int>?
        var tiltXRange: ClosedRange<Double>?
        var tiltYRange: ClosedRange<Double>?
        var hoverRange: ClosedRange<Int>?

        // Explicit init: the compiler-synthesized memberwise init would
        // inherit `private` from the properties below, making it
        // inaccessible to `Condenser` even though the type itself is
        // `fileprivate`.
        fileprivate init(startElapsed: TimeInterval, reportID: UInt8, tag: String) {
            self.startElapsed = startElapsed
            self.reportID = reportID
            self.tag = tag
        }

        private var lastX: Int?
        private var lastY: Int?
        private var lastTiltX: Double?
        private var lastTiltY: Double?
        /// Largest per-sample delta seen so far, per axis — the adaptive
        /// baseline `isOutlier` compares against. Not a fixed threshold:
        /// coordinate scale and step size vary too much across devices for
        /// one constant to work everywhere.
        private var maxSeenDeltaX = 0
        private var maxSeenDeltaY = 0
        private var maxSeenDeltaTilt = 0.0
        /// Samples needed before `isOutlier` starts comparing — no baseline
        /// exists before this.
        private static let baselineSampleCount = 5
        /// A delta beyond this multiple of the run's own max-seen delta
        /// counts as an outlier. 5x is generous on purpose — normal pen
        /// speed varies a lot; this should only catch an order-of-magnitude
        /// jump, not "faster than usual."
        private static let outlierMultiplier = 5.0
        /// Absolute floor so a near-motionless run doesn't make the
        /// multiplier degenerate to noise-level and flag ordinary jitter.
        private static let minOutlierDelta = 50.0

        /// True if absorbing `sample` next would be a discontinuity — the
        /// caller should close the run without absorbing it and emit it
        /// verbatim instead.
        func isOutlier(_ sample: Sample) -> Bool {
            guard count >= Self.baselineSampleCount,
                let decoded = sample.decoded,
                case .pen(let p)? = decoded.first(where: { if case .pen = $0 { return true } else { return false } })
            else { return false }
            guard let lastX, let lastY, let lastTiltX, let lastTiltY else { return false }
            let dx = Double(abs(p.x - lastX))
            let dy = Double(abs(p.y - lastY))
            let dTilt = max(abs(p.tiltX - lastTiltX), abs(p.tiltY - lastTiltY))
            let xThreshold = max(Double(maxSeenDeltaX) * Self.outlierMultiplier, Self.minOutlierDelta)
            let yThreshold = max(Double(maxSeenDeltaY) * Self.outlierMultiplier, Self.minOutlierDelta)
            // Tilt is normalized -1...1, so its floor scales to that range
            // rather than reusing minOutlierDelta.
            let tiltThreshold = max(maxSeenDeltaTilt * Self.outlierMultiplier, 0.3)
            return dx > xThreshold || dy > yThreshold || dTilt > tiltThreshold
        }

        mutating func absorb(_ sample: Sample) {
            count += 1
            minLength = min(minLength, sample.length)
            maxLength = max(maxLength, sample.length)
            if count == 1 { firstHex = sample.hex }
            lastHex = sample.hex
            guard let decoded = sample.decoded else { return }
            for result in decoded {
                guard case .pen(let p) = result else { continue }
                xRange = Self.extend(xRange, with: p.x)
                yRange = Self.extend(yRange, with: p.y)
                pressureRange = Self.extend(pressureRange, with: p.pressure)
                tiltXRange = Self.extend(tiltXRange, with: p.tiltX)
                tiltYRange = Self.extend(tiltYRange, with: p.tiltY)
                hoverRange = Self.extend(hoverRange, with: p.hoverDistance)
                if let lastX, let lastY {
                    maxSeenDeltaX = max(maxSeenDeltaX, abs(p.x - lastX))
                    maxSeenDeltaY = max(maxSeenDeltaY, abs(p.y - lastY))
                }
                if let lastTiltX, let lastTiltY {
                    maxSeenDeltaTilt = max(maxSeenDeltaTilt, max(abs(p.tiltX - lastTiltX), abs(p.tiltY - lastTiltY)))
                }
                lastX = p.x
                lastY = p.y
                lastTiltX = p.tiltX
                lastTiltY = p.tiltY
            }
        }

        private static func extend<T: Comparable>(_ range: ClosedRange<T>?, with value: T) -> ClosedRange<T> {
            guard let range else { return value...value }
            return min(range.lowerBound, value)...max(range.upperBound, value)
        }

        /// A run of one sample renders exactly like a verbatim line rather
        /// than a degenerate range (`x:1234-1234`), so it doesn't read
        /// differently from the transitions around it.
        func render(hexDigitID: String) -> String {
            let ts = Self.formatElapsed(startElapsed)
            let padded = Self.pad(tag)
            if count == 1 {
                return "[\(ts)] \(padded) ID=\(hexDigitID) len=\(String(format: "%-4d", minLength))  \(firstHex)"
            }
            let lenRange = minLength == maxLength ? "\(minLength)" : "\(minLength)-\(maxLength)"
            var fields: [String] = []
            if let r = xRange { fields.append("x:\(r.lowerBound)-\(r.upperBound)") }
            if let r = yRange { fields.append("y:\(r.lowerBound)-\(r.upperBound)") }
            if let r = pressureRange { fields.append("p:\(r.lowerBound)-\(r.upperBound)") }
            if let r = tiltXRange, let ry = tiltYRange {
                fields.append(
                    String(format: "tilt:(%.2f..%.2f,%.2f..%.2f)", r.lowerBound, r.upperBound, ry.lowerBound, ry.upperBound)
                )
            }
            if let r = hoverRange { fields.append("hover:\(r.lowerBound)-\(r.upperBound)") }
            let fieldStr = fields.isEmpty ? "(no decoder — raw bytes only)" : fields.joined(separator: " ")
            return
                "[\(ts)] \(padded) ID=\(hexDigitID) len=\(lenRange)  ×\(count) steady-state  →  \(fieldStr)"
        }

        static func formatElapsed(_ elapsed: TimeInterval) -> String {
            let mins = Int(elapsed) / 60
            let secs = Int(elapsed) % 60
            let ms = Int((elapsed - Double(Int(elapsed))) * 1000)
            return String(format: "%02d:%02d.%03d", mins, secs, ms)
        }

        static func pad(_ tag: String) -> String {
            tag.count <= 20 ? tag + String(repeating: " ", count: 20 - tag.count) : String(tag.prefix(20))
        }
    }

    /// Renders one sample verbatim — same shape as a run of one.
    private static func renderVerbatim(_ sample: Sample) -> String {
        let ts = RunAccumulator.formatElapsed(sample.elapsed)
        let padded = RunAccumulator.pad(sample.tag)
        let idHex = String(format: "%02X", sample.reportID)
        let decodedSummary = sample.decoded.flatMap(summarize)
        return "[\(ts)] \(padded) ID=\(idHex) len=\(String(format: "%-4d", sample.length))  \(sample.hex)"
            + (decodedSummary.map { "  → \($0)" } ?? "")
    }

    /// Stateful run-collapse condenser: consecutive, same-(tag, report-ID),
    /// same-`Signature` samples fold into one value-range line; every
    /// transition or outlier is kept verbatim.
    ///
    /// Accumulators persist across `feed(_:)` calls so a periodic flush
    /// doesn't cut an open run into two lines — it only closes on a real
    /// transition, an outlier, or `finish()`.
    ///
    /// Runs are keyed on (tag, report ID), not report ID alone: a device
    /// with more than one registered HID interface can deliver the same
    /// report ID from two interfaces as real, simultaneous, independent
    /// traffic (`WacomKnownDevice`'s `captureTag` disambiguates this).
    ///
    /// `feed(_:)` never releases a line newer than the oldest still-open
    /// run's start — this watermark, not per-batch sorting, is what keeps
    /// output globally chronological across calls. A run can stay open for
    /// many `feed(_:)` calls (a long continuous sweep); while it's open,
    /// every other stream's newer lines must wait too, or they land on disk
    /// before the slow run closes and catches up. Confirmed by two separate
    /// real-capture bugs: a closed run's own late-flushed batch, and a run
    /// that stayed open until `finish()` — neither is fixable by sorting
    /// within a single batch. Lines held back this way accumulate in
    /// `pending`, which is therefore the one place this condenser can grow
    /// without bound within a session (bounded in practice — such a
    /// long-lived run is rare, and `maxCaptureDuration` caps the session).
    struct Condenser {
        struct Key: Hashable { var tag: String; var reportID: UInt8 }

        private var lastSignature: [Key: Signature] = [:]
        private var lastRaw: [Key: (elapsed: TimeInterval, hex: String)] = [:]
        private var openRuns: [Key: RunAccumulator] = [:]
        /// Lines that became final but were newer than the watermark when
        /// produced — released by a later `feed(_:)` or `finish()`.
        private var pending: [(sortElapsed: TimeInterval, line: String)] = []

        /// Feeds a new batch (chronological order) and returns every line
        /// that both became final and cleared the watermark this call.
        mutating func feed(_ samples: [Sample]) -> [String] {
            func closeRun(_ key: Key) {
                guard let run = openRuns.removeValue(forKey: key) else { return }
                pending.append((run.startElapsed, run.render(hexDigitID: String(format: "%02X", key.reportID))))
            }

            for sample in samples {
                let key = Key(tag: sample.tag, reportID: sample.reportID)

                // Same key, identical bytes, same instant — the same
                // physical report reaching `record()` twice (seen on a
                // multi-interface Xencelabs dongle even after tag
                // disambiguation; cause unconfirmed). Drop the repeat.
                if let prior = lastRaw[key], prior.elapsed == sample.elapsed, prior.hex == sample.hex {
                    continue
                }
                lastRaw[key] = (sample.elapsed, sample.hex)

                let isTransition =
                    sample.signature.hasOneShotEvent
                    || sample.signature != (lastSignature[key] ?? sample.signature)
                lastSignature[key] = sample.signature

                if isTransition {
                    closeRun(key)
                    pending.append((sample.elapsed, renderVerbatim(sample)))
                    continue
                }

                if var run = openRuns[key] {
                    if run.isOutlier(sample) {
                        // Not a lasting Signature change — the next sample
                        // can resume normal absorption into a fresh run.
                        closeRun(key)
                        pending.append((sample.elapsed, renderVerbatim(sample)))
                        continue
                    }
                    run.absorb(sample)
                    openRuns[key] = run
                } else {
                    var run = RunAccumulator(startElapsed: sample.elapsed, reportID: sample.reportID, tag: sample.tag)
                    run.absorb(sample)
                    openRuns[key] = run
                }
            }

            return releaseUpToWatermark()
        }

        /// The oldest still-open run's start, or `.infinity` if none is
        /// open (release everything).
        private var watermark: TimeInterval {
            openRuns.values.map(\.startElapsed).min() ?? .infinity
        }

        /// Releases everything in `pending` at or before the watermark,
        /// sorted, leaving the rest buffered.
        private mutating func releaseUpToWatermark() -> [String] {
            let cutoff = watermark
            let ready = pending.filter { $0.sortElapsed <= cutoff }
            pending.removeAll { $0.sortElapsed <= cutoff }
            // Stable sort: same-timestamp lines (near-simultaneous
            // interfaces) keep relative emission order.
            return ready.enumerated()
                .sorted { a, b in
                    a.element.sortElapsed != b.element.sortElapsed
                        ? a.element.sortElapsed < b.element.sortElapsed : a.offset < b.offset
                }
                .map(\.element.line)
        }

        /// Closes every open run and releases everything pending — end of
        /// session, so the watermark no longer applies. Call once, after
        /// the last `feed(_:)`.
        mutating func finish() -> [String] {
            for key in openRuns.keys.sorted(by: { ($0.tag, $0.reportID) < ($1.tag, $1.reportID) }) {
                let run = openRuns.removeValue(forKey: key)!
                pending.append((run.startElapsed, run.render(hexDigitID: String(format: "%02X", key.reportID))))
            }
            let all = pending
            pending.removeAll()
            return all.enumerated()
                .sorted { a, b in
                    a.element.sortElapsed != b.element.sortElapsed
                        ? a.element.sortElapsed < b.element.sortElapsed : a.offset < b.offset
                }
                .map(\.element.line)
        }
    }

    // MARK: - Persistence

    /// "mocktab-raw-20260920-090122.txt" — hyphens throughout, no
    /// underscores, so the filename types as one word.
    private static func makeFileURL(for date: Date) -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = fmt.string(from: date)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/mocktab-raw-\(stamp).txt")
    }

    /// Written synchronously before any samples exist, so a crash before
    /// the first flush still leaves a valid file. Can't show final totals
    /// yet — names the format instead.
    private static func writeHeader(to url: URL, startTime: Date) {
        let header = """
            MockTab HID Capture
            Started    : \(startTime)
            Flushed to disk every \(Int(flushInterval))s; auto-stops after \(Int(maxCaptureDuration / 60)) minutes.
            Steady-state runs are collapsed to value ranges; proximity/button/
            tool-identity transitions are kept verbatim — see a run line's own
            ×<count> steady-state marker to tell which is which. A single
            implausible jump inside an otherwise steady run also breaks it
            and appears as its own verbatim line, so a run's x/y/tilt range
            never silently hides a discontinuity.

            Format  : [mm:ss.ms] <device-tag>            ID=<hex> len=<n>  <hex bytes>  → <decoded>
                      A run line reads len=<range>  ×<count> steady-state  →  <value ranges> instead.
            ──────────────────────────────────────────────────────────────────────────────────────

            """
        do {
            try header.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.error("HIDCapture: header write failed — \(error, privacy: .public)")
        }
    }

    /// `start()` guarantees the file already exists, so this only appends.
    private static func append(lines: [String], to url: URL) {
        let content = lines.joined(separator: "\n") + "\n"
        guard let data = content.data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            logger.error("HIDCapture: flush append failed — \(error, privacy: .public)")
        }
    }
}
