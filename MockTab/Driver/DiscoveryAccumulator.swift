// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

// MARK: - Byte value set

/// The set of byte values seen at one byte position, as a 256-bit map.
///
/// Four words instead of a `Set<UInt8>` because this is written from the HID
/// callback thread — the same thread that feeds cursor movement — for every
/// byte of every report. Insertion is a shift and an OR: no hashing, no
/// allocation, no growth, ever. The analysis the capture file needs (distinct
/// count, min, max, the value list) all falls out of bit tricks on the way
/// back out, which happens once at the end of the session.
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

    /// Observed values for the capture file, ascending, at most `cap` of them.
    ///
    /// When more than `cap` values were seen, keeps the lowest and highest
    /// halves rather than a prefix. A prefix of a sorted list hides the
    /// *ceiling* — a pressure byte that swept 0…255 got reported as having
    /// taken the values 0…19, which is the opposite of the number the capture
    /// is read for. `min`/`max` are reported separately and are always exact.
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
    /// The decodable signal for a button device. A report whose descriptor is
    /// opaque still gives its structure away here: on a pad or remote, every
    /// key is one bit that toggles, so this mask *is* the button map, and a
    /// bit that is always set (a validity or battery flag) drops out of it
    /// automatically instead of being counted as a nineteenth button.
    ///
    /// Derived at snapshot time by folding the observed values, never on the
    /// HID callback thread — this walks the value list, which the hot path
    /// must not.
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
    /// Reported alongside `togglingBits` because the difference between them
    /// is meaningful: a bit here but not there was set in *every* sample, so
    /// it is a constant flag rather than a control, and knowing that saves
    /// the reader from chasing it.
    var bitsEverSet: UInt8 {
        values.reduce(into: UInt8(0)) { $0 |= $1 }
    }
}

// MARK: - Discovery accumulator

/// Streaming per-report statistics, written from the HID callback thread.
///
/// Deliberately does **not** retain raw samples. A one-hour session on a
/// tablet streaming ~100 reports/sec is ~360k reports; retaining them cost
/// tens of megabytes, a `Task { @MainActor }` hop per report while the user
/// was drawing, and a multi-second main-thread reduction when they clicked
/// Done. Everything the capture file reports — and everything
/// `tools/triage_discovery.py` reads — is derivable incrementally, so it is
/// derived incrementally, in fixed space.
final class DiscoveryAccumulator: Sendable {

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
        /// Fixed at 1 — the byte immediately after the report ID. On the
        /// Wacom IntuosV1 protocol (and a good deal of other HID tablet/
        /// joystick gear) that position is a status/packet-type byte: an
        /// ordinary coordinate report and a tool-change/aux report can share
        /// one report ID and length, told apart only by this byte's high
        /// bits. Folding both into one flat byte-position histogram (what
        /// `byteValues` above does) makes a tool-change packet's serial/type
        /// bytes look like wild coordinate excursions in the "varying byte"
        /// stats for every other position — this is exactly what made a
        /// submitted GD-0608-U capture unreadable for confirming maxX/maxY:
        /// byte 2's range looked large enough to span the tool ID space, not
        /// because the pen moved there, but because a handful of tool-change
        /// samples were mixed into the same histogram as thousands of pen
        /// samples. See Notes/Wacom-HID-GD‑0608‑U-Reference.md.
        static let discriminatorByteIndex = 1

        /// Per-value byte statistics, keyed by the value seen at
        /// `discriminatorByteIndex`. Maintained unconditionally during
        /// recording — one extra dictionary lookup and a `ByteValueSet`
        /// insert per report, negligible next to the top-level accumulation
        /// this mirrors. Whether it's worth *reading* depends on how many
        /// distinct values that byte took; that judgment is made once, at
        /// snapshot time, in `CaptureEngine`, not here — a byte position that
        /// turns out to be a coordinate byte itself (high cardinality) simply
        /// makes an uninteresting set of buckets, not an incorrect one.
        var byDiscriminator: [UInt8: [ByteValueSet]] = [:]
        var discriminatorSampleCounts: [UInt8: Int] = [:]

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
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    // MARK: Control

    /// Discard any previous session's data and begin accepting reports.
    func start() {
        state.withLock {
            $0.reports.removeAll()
            $0.totalSamples = 0
            $0.toolCodes.removeAll()
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
    func record(reportID: UInt8, pointer: UnsafePointer<UInt8>, length: Int) {
        guard length > 0 else { return }
        // `withLockUnchecked` rather than `withLock`: the body is synchronous
        // and can't outlive this call, but the report pointer isn't `Sendable`
        // and a `@Sendable` closure would reject it. Copying the report just to
        // satisfy that is the per-report allocation this path exists to avoid.
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
                s.reports[reportID] = stats
            }
        }
    }
}
