// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
import TabletKit

// MARK: - Byte value set

/// The set of byte values seen at one byte position, as a 256-bit map.
///
/// Four words instead of a `Set<UInt8>`: the pen thread writes it for every
/// byte of every report, and insertion is a shift and an OR, with no hashing
/// or allocation. The analysis comes out once, at the end of the session.
struct ByteValueSet: Sendable, Equatable {
    private var w0: UInt64 = 0
    private var w1: UInt64 = 0
    private var w2: UInt64 = 0
    private var w3: UInt64 = 0

    mutating func insert(_ value: UInt8) {
        let bit = UInt64(1) << UInt64(value & 63)
        switch value >> 6 {
        case 0: w0 |= bit
        case 1: w1 |= bit
        case 2: w2 |= bit
        default: w3 |= bit
        }
    }

    var isEmpty: Bool { w0 == 0 && w1 == 0 && w2 == 0 && w3 == 0 }

    /// Number of distinct values observed.
    var count: Int {
        w0.nonzeroBitCount + w1.nonzeroBitCount + w2.nonzeroBitCount + w3.nonzeroBitCount
    }

    var min: UInt8? {
        for (i, w) in [w0, w1, w2, w3].enumerated() where w != 0 {
            return UInt8(i * 64 + w.trailingZeroBitCount)
        }
        return nil
    }

    var max: UInt8? {
        for (i, w) in [w0, w1, w2, w3].enumerated().reversed() where w != 0 {
            return UInt8(i * 64 + (63 - w.leadingZeroBitCount))
        }
        return nil
    }

    /// Every observed value as a 256-bit mask, low byte first, hex encoded.
    ///
    /// The complete distribution in 64 characters. The truncated `values`
    /// list misleads for signed bytes: a field spanning -12…+11 shows as
    /// `0…11` and `244…255`, which reads as a plateau at ±12. Decode this when
    /// the shape of a distribution matters.
    /// Encoded so that value `v` is bit `v % 4` of hex character `v / 4`,
    /// counting from the string's start — a plain little-endian bitmap. Built
    /// from the values rather than from the words, because a word's hex
    /// rendering puts each nibble's low bit on the wrong side.
    var valueMaskHex: String {
        var nibbles = [UInt8](repeating: 0, count: 64)
        for v in values {
            nibbles[Int(v) / 4] |= UInt8(1 << (Int(v) % 4))
        }
        return nibbles.map { String($0, radix: 16) }.joined()
    }

    /// Largest magnitude when the byte is read as a signed value.
    ///
    /// A signed field's ceiling is invisible in `min`/`max`, which report 0 and
    /// 255 for any field that merely goes negative. This is the number to
    /// compare against a candidate divisor.
    var signedMagnitudeMax: Int? {
        let signed = values.map { $0 > 127 ? Int($0) - 256 : Int($0) }
        guard let hi = signed.map({ abs($0) }).max() else { return nil }
        return hi
    }

    /// Observed values for the capture file, ascending, at most `cap` of them.
    ///
    /// When more than `cap` values were seen, keeps the lowest and highest
    /// halves, since a prefix would hide the ceiling. `min`/`max` are always
    /// exact.
    func sampledValues(cap: Int) -> (values: [UInt8], truncated: Bool) {
        let all = values
        guard all.count > cap else { return (all, false) }
        let half = cap / 2
        return (Array(all.prefix(cap - half)) + Array(all.suffix(half)), true)
    }

    /// Every observed value, ascending.
    var values: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count)
        for (i, word) in [w0, w1, w2, w3].enumerated() {
            var w = word
            while w != 0 {
                let bit = w.trailingZeroBitCount
                out.append(UInt8(i * 64 + bit))
                w &= w - 1
            }
        }
        return out
    }

    /// Which bit positions took both values across the session — set in at
    /// least one sample and clear in at least one other.
    ///
    /// On a pad or remote every key is one toggling bit, so this mask is the
    /// button map even when the descriptor is opaque; an always-set flag bit
    /// stays out of it. Computed at snapshot time, never on the pen thread.
    var togglingBits: UInt8 {
        var everSet: UInt8 = 0
        var everClear: UInt8 = 0
        for value in values {
            everSet |= value
            everClear |= ~value
        }
        return everSet & everClear
    }

    /// Bits set in at least one observed value.
    ///
    /// A bit here but not in `togglingBits` was set in every sample: a
    /// constant flag, not a control.
    var bitsEverSet: UInt8 {
        values.reduce(into: UInt8(0)) { $0 |= $1 }
    }
}

// MARK: - Capture accumulator

/// Streaming per-report statistics, written from the HID callback thread.
///
/// Keeps no raw samples: an hour at ~100 reports/sec is ~360k reports.
/// Everything the capture file reports, and everything
/// `TabletKit/tools/triage_discovery.py` reads, is derived incrementally in
/// fixed space.
final class CaptureAccumulator: Sendable {

    struct ReportStats: Sendable {
        var firstLength: Int
        var minLength: Int
        var maxLength: Int
        var sampleCount: Int
        var firstSample: [UInt8]
        /// One entry per byte position, sized to `maxLength`.
        var byteValues: [ByteValueSet]

        /// The byte position `byDiscriminator` splits on.
        ///
        /// Fixed at 1, the byte after the report ID. On the Intuos 10-byte
        /// protocol and other gear it's a packet-type byte: a coordinate
        /// report and a tool-change report share one ID and length, told
        /// apart only by this byte. In one flat histogram (`byteValues`), a
        /// tool-change packet's serial bytes look like wild coordinate
        /// excursions. See Notes/Wacom-Intuos-10-Byte-Protocol.md.
        static let discriminatorByteIndex = 1

        /// Per-value byte statistics, keyed by the value seen at
        /// `discriminatorByteIndex`. Always maintained, at one lookup and
        /// insert per report; `CaptureEngine` decides at snapshot time
        /// whether the split is worth reading.
        var byDiscriminator: [UInt8: [ByteValueSet]] = [:]
        var discriminatorSampleCounts: [UInt8: Int] = [:]

        // MARK: Inter-arrival gaps
        //
        // Time between one report of this ID and the next, in millisecond
        // buckets plus the longest gaps kept whole with their session time.
        // They show whether a touch stream stalls mid-gesture or only
        // between gestures.
        //
        // Gaps split on whether a contact was down at both ends
        // (`inGestureGapBuckets`) or not (`idleGapBuckets`); a lift counts as
        // idle. The caller supplies the contact-down flag; with `nil`, a gap
        // goes only to the combined `gapBuckets`.

        /// Upper edges, in milliseconds, of the gap buckets. A gap of exactly
        /// an edge value falls in the lower bucket. Each bucket array has one
        /// more slot than this has edges — the last catches everything `>=`
        /// the final edge.
        static let gapBucketEdgesMs: [Double] = [2, 5, 10, 20, 50, 100, 500]

        /// Count of every inter-arrival gap per bucket, regardless of contact
        /// state. `gapBucketEdgesMs.count + 1` wide.
        var gapBuckets: [Int] = Array(repeating: 0, count: gapBucketEdgesMs.count + 1)
        /// Gaps with a contact down at both ends — a stall while the gesture
        /// was in progress. Only populated when the caller supplies the flag.
        var inGestureGapBuckets: [Int] = Array(repeating: 0, count: gapBucketEdgesMs.count + 1)
        /// Gaps with no contact at one or both ends — idle between gestures,
        /// or the lift boundary itself. Only populated when the caller
        /// supplies the flag.
        var idleGapBuckets: [Int] = Array(repeating: 0, count: gapBucketEdgesMs.count + 1)

        /// One retained inter-arrival gap: how long it was, and the
        /// session-elapsed time it ended at (the arrival that closed it).
        struct Gap: Sendable, Equatable {
            var ms: Double
            var atElapsedMs: Double
        }

        /// The longest inter-arrival gaps seen, largest first, capped at
        /// `maxRetainedGaps`.
        var longestGaps: [Gap] = []
        static let maxRetainedGaps = 8

        /// `mach_absolute_time()` of the last report of this ID, or 0 before
        /// the first. Not published — cleared on `start()` with the rest.
        var lastArrivalMachTime: UInt64 = 0
        /// Contact-down flag the caller supplied with the *previous* report of
        /// this ID — the "before" end of the next gap. `nil` until the caller
        /// supplies one.
        var lastContactDown: Bool? = nil

        /// - Parameter bothEndsContactDown: `true` if a contact was down at
        ///   both the previous and current report; `false` if not; `nil` if
        ///   the caller can't say. Routes the gap to `inGestureGapBuckets`,
        ///   `idleGapBuckets`, or neither.
        mutating func noteGap(ms: Double, atElapsedMs: Double, bothEndsContactDown: Bool?) {
            let slot = Self.gapBucketEdgesMs.firstIndex { ms < $0 } ?? Self.gapBucketEdgesMs.count
            gapBuckets[slot] += 1
            switch bothEndsContactDown {
            case .some(true): inGestureGapBuckets[slot] += 1
            case .some(false): idleGapBuckets[slot] += 1
            case .none: break
            }

            if longestGaps.count < Self.maxRetainedGaps || ms > (longestGaps.last?.ms ?? 0) {
                longestGaps.append(Gap(ms: ms, atElapsedMs: atElapsedMs))
                longestGaps.sort { $0.ms > $1.ms }
                if longestGaps.count > Self.maxRetainedGaps { longestGaps.removeLast() }
            }
        }

        var lengthVaried: Bool { minLength != maxLength }

        /// How each byte position of this report behaved.
        enum ByteRole: Equatable {
            /// Present in every sample, took more than one value.
            case varying
            /// Present in every sample, always the same value.
            case constant(UInt8)
            /// Present in only some samples, because the report arrived at
            /// more than one length. Neither "constant" nor "varying" can be
            /// claimed honestly for these, so they're reported separately.
            case optional
        }

        /// Classify every byte position, in order. The three published lists
        /// (`varyingBytes`, `constantBytes`, `optionalBytes`) are exactly this
        /// partition, so they cannot drift apart — and `constantValues` is
        /// carried in the `constant` case rather than in a parallel array.
        ///
        /// Every position up to `maxLength` gets a role: a report that grew
        /// mid-session leaves no position unaccounted for.
        func byteRoles() -> [(index: Int, role: ByteRole)] {
            (0..<maxLength).map { idx in
                let seen = byteValues[idx]
                if idx >= minLength { return (idx, .optional) }
                if let only = seen.min, seen.count == 1 { return (idx, .constant(only)) }
                return (idx, .varying)
            }
        }
    }

    private struct State: Sendable {
        var isCapturing = false
        var reports: [UInt8: ReportStats] = [:]
        var totalSamples = 0
        var toolCodes: Set<UInt16> = []
        /// `mach_absolute_time()` at `start()`, the origin for the elapsed
        /// timestamps attached to retained gaps.
        var sessionStartMachTime: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// `mach_absolute_time()` ticks → milliseconds. Read once; the timebase
    /// is fixed for the life of the process.
    private static let machMsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000
    }()

    // MARK: Control

    /// Discard any previous session's data and begin accepting reports.
    func start() {
        state.withLock {
            $0.reports.removeAll()
            $0.totalSamples = 0
            $0.toolCodes.removeAll()
            $0.sessionStartMachTime = mach_absolute_time()
            $0.isCapturing = true
        }
    }

    /// Stop accepting reports. Collected statistics stay readable until the
    /// next `start()` so the result can be built after the session ends.
    func stop() {
        state.withLock { $0.isCapturing = false }
    }

    var isCapturing: Bool { state.withLock { $0.isCapturing } }
    var sampleCount: Int { state.withLock { $0.totalSamples } }

    func snapshot() -> (reports: [UInt8: ReportStats], toolCodes: Set<UInt16>) {
        state.withLock { ($0.reports, $0.toolCodes) }
    }

    func noteToolCode(_ code: UInt16) {
        state.withLock { _ = $0.toolCodes.insert(code) }
    }

    /// Fold one report into `stats.byDiscriminator[disc]`, growing that
    /// bucket's byte-position array the same way the top-level `byteValues`
    /// grows in `record(reportID:pointer:length:)`.
    private static func foldDiscriminated(
        _ stats: inout ReportStats, disc: UInt8, pointer: UnsafePointer<UInt8>, length: Int
    ) {
        stats.discriminatorSampleCounts[disc, default: 0] += 1
        var bucket = stats.byDiscriminator[disc] ?? []
        if length > bucket.count {
            bucket.append(contentsOf: repeatElement(ByteValueSet(), count: length - bucket.count))
        }
        for i in 0..<length { bucket[i].insert(pointer[i]) }
        stats.byDiscriminator[disc] = bucket
    }

    // MARK: Recording

    /// Fold one report into the running statistics.
    ///
    /// Called directly from `IOHIDReportCallback` on HIDThread — no actor hop,
    /// no copy of the report. The `isCapturing` check happens inside the same
    /// lock acquisition, so a report arriving while collection is off costs one
    /// uncontended `os_unfair_lock` round trip and nothing else.
    ///
    /// - Parameter contactDown: whether a touch contact was down as of this
    ///   report, from the caller's decoded touch state. Splits the
    ///   inter-arrival gap ending at this report into `inGestureGapBuckets`
    ///   vs `idleGapBuckets` — a gap counts as in-gesture only when a contact
    ///   was down at *both* ends. `nil` (the default, and always for a report
    ///   the caller doesn't decode as touch) leaves the split untouched; the
    ///   combined `gapBuckets` still counts every gap.
    func record(
        reportID: UInt8, pointer: UnsafePointer<UInt8>, length: Int, contactDown: Bool? = nil
    ) {
        guard length > 0 else { return }
        // `withLockUnchecked` rather than `withLock`: the body is synchronous
        // and can't outlive this call, but the report pointer isn't `Sendable`
        // and a `@Sendable` closure would reject it. Copying the report just to
        // satisfy that is the per-report allocation this path exists to avoid.
        let now = mach_absolute_time()
        state.withLockUnchecked { s in
            guard s.isCapturing else { return }
            s.totalSamples += 1

            if var stats = s.reports[reportID] {
                if length > stats.maxLength {
                    stats.maxLength = length
                    stats.byteValues.append(
                        contentsOf: repeatElement(ByteValueSet(), count: length - stats.byteValues.count))
                }
                if length < stats.minLength { stats.minLength = length }
                stats.sampleCount += 1
                for i in 0..<length { stats.byteValues[i].insert(pointer[i]) }
                if length > ReportStats.discriminatorByteIndex {
                    let disc = pointer[ReportStats.discriminatorByteIndex]
                    Self.foldDiscriminated(&stats, disc: disc, pointer: pointer, length: length)
                }
                if stats.lastArrivalMachTime != 0 {
                    let gapMs = Double(now - stats.lastArrivalMachTime) * Self.machMsPerTick
                    let elapsedMs = Double(now - s.sessionStartMachTime) * Self.machMsPerTick
                    let bothEnds: Bool? =
                        (stats.lastContactDown != nil || contactDown != nil)
                        ? ((stats.lastContactDown ?? false) && (contactDown ?? false))
                        : nil
                    stats.noteGap(ms: gapMs, atElapsedMs: elapsedMs, bothEndsContactDown: bothEnds)
                }
                stats.lastArrivalMachTime = now
                stats.lastContactDown = contactDown
                s.reports[reportID] = stats
            } else {
                var byteValues = [ByteValueSet](repeating: ByteValueSet(), count: length)
                for i in 0..<length { byteValues[i].insert(pointer[i]) }
                var stats = ReportStats(
                    firstLength: length,
                    minLength: length,
                    maxLength: length,
                    sampleCount: 1,
                    firstSample: [UInt8](UnsafeBufferPointer(start: pointer, count: length)),
                    byteValues: byteValues)
                if length > ReportStats.discriminatorByteIndex {
                    let disc = pointer[ReportStats.discriminatorByteIndex]
                    Self.foldDiscriminated(&stats, disc: disc, pointer: pointer, length: length)
                }
                // First report of this ID: no predecessor, so no gap. Just
                // arm the clock and contact state for the next one.
                stats.lastArrivalMachTime = now
                stats.lastContactDown = contactDown
                s.reports[reportID] = stats
            }
        }
    }
}
