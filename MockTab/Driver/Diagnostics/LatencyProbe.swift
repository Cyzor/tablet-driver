// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreFoundation
import Foundation
import os

/// Delivery-latency probe for HID input reports.
///
/// Measures kernel-receipt → callback-entry latency from the timestamp
/// supplied by `IOHIDDeviceRegisterInputReportWithTimeStampCallback`
/// (mach absolute time stamped when the kernel received the report).
/// Sustained spikes here mean HIDThread is being starved by system load —
/// the precondition for promoting it to a time-constraint (real-time)
/// scheduling policy.
///
/// Cost per report: one `mach_absolute_time()` call, one
/// `clock_gettime_nsec_np` read, and a few double ops. No allocations, no
/// timers, no mach traps. All writes happen on HIDThread; reads from
/// the diagnostics UI are non-atomic snapshots (same tolerated-torn-read
/// pattern as `CursorSmoother.jitterLevel`) — a stale value is harmless.
///
/// `@unchecked Sendable`: every stored property is an independently
/// torn-read-tolerant scalar (`Double`/`UInt64`), never combined into a
/// value needing cross-field consistency — reading `averageMs` from one
/// instant and `stallCount` from another still gives a meaningful, if
/// stale, snapshot. Writes happen only on `HIDThread`. A future field whose
/// meaning depends on another field's value at the same instant breaks
/// this and needs real synchronization instead.
final class LatencyProbe: @unchecked Sendable {

    static let shared = LatencyProbe()

    /// mach timebase → nanoseconds conversion factor, computed once.
    /// Non-private: the injection path reuses it to convert kernel report
    /// timestamps (mach ticks) into CGEventTimestamp nanoseconds.
    static let timebaseFactor: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    /// Delivery latency above this counts as a scheduling stall.
    static let stallThresholdMs: Double = 5.0

    /// Reports arriving within this window after a device connect are
    /// attributed to connect-phase work (handshakes, paced settings writes,
    /// serial queries) rather than steady-state usage. Those episodes are
    /// real but don't reflect what a user feels mid-stroke, so they're
    /// bucketed separately and kept out of the headline numbers.
    static let settleWindowSeconds: Double = 5.0

    /// EMA of delivery latency (α = 1/64 ≈ 0.5 s settling at 133 Hz).
    private(set) var averageMs: Double = 0
    /// Worst latency observed since launch, steady-state reports only.
    private(set) var worstMs: Double = 0
    /// Steady-state reports delivered later than `stallThresholdMs`.
    private(set) var stallCount: UInt64 = 0
    private(set) var reportCount: UInt64 = 0

    /// Connect-phase counterparts, tracked so handshake regressions stay
    /// visible without polluting the steady-state figures.
    private(set) var connectWorstMs: Double = 0
    private(set) var connectStallCount: UInt64 = 0

    /// Stage-2: kernel receipt → injection complete (decode + all injection
    /// callbacks returned, CGEvents posted). Measured at the end of report
    /// handling, so `totalAverageMs − averageMs` is the app's own share of
    /// the pipeline. Steady-state only, same settling-window gate as above.
    private(set) var totalAverageMs: Double = 0
    private(set) var totalWorstMs: Double = 0

    /// Mach deadline until which reports count as connect-phase. Written by
    /// `noteDeviceConnected()` and read on HIDThread, so call that there too.
    /// From another thread it's the tolerated race the counters above
    /// accept: a stale read just misattributes a handful of reports.
    private var settlingDeadline: UInt64 = 0

    /// Call when a device connects (or reconnects) to open the settling
    /// window during which stalls are attributed to connect-phase work.
    func noteDeviceConnected() {
        let ticks = UInt64(Self.settleWindowSeconds * 1_000_000_000.0 / Self.timebaseFactor)
        settlingDeadline = mach_absolute_time() &+ ticks
    }

    /// Unified-log channel for stall episodes, so evidence survives without
    /// the diagnostics pane being open. Lines are emitted at `.info`, which
    /// the unified log keeps in memory only — `log show` after the fact is
    /// unreliable. Watch live instead:
    ///   log stream --level info --predicate 'subsystem == "com.mocktab.latency"'
    /// To retrieve after the fact, opt the subsystem into disk persistence
    /// first (survives until reboot, and puts stall logging back in the disk
    /// path — enable it only for a session that is hunting a stall):
    ///   sudo log config --subsystem com.mocktab.latency --mode "level:info,persist:info"
    ///   log show --info --last 1h --predicate 'subsystem == "com.mocktab.latency"'
    private static let log = Logger(subsystem: "com.mocktab.latency", category: "stall")

    /// Stalls arrive in bursts during load storms; log the burst, not every
    /// report. At most one line per second (mach ticks), each summarizing
    /// the worst latency seen since the previous line.
    private var lastLogTime: UInt64 = 0
    private var burstWorstMs: Double = 0
    private var burstStallCount: UInt64 = 0

    /// Inter-report gap histogram, bucketed at 2/5/10/20/40 ms. Unlike
    /// `stallCount` (gated on delivery latency vs. `kernelTimestamp`, so it
    /// is blind to anything delayed *before* the kernel timestamp itself —
    /// e.g. a transport batching reports upstream of IOHIDManager), this
    /// buckets `gapMs` unconditionally, so it can distinguish "delivering
    /// fewer reports, evenly spaced" (mass shifts to one higher bucket)
    /// from "delivering reports in bursts" (mass split between the lowest
    /// bucket and a higher one — coalesce-then-flush). Reset per capture
    /// window via `resetGapHistogram()` so a USB run and a Bluetooth run of
    /// the same device can be compared without one polluting the other.
    /// Six plain counters, not an array: main reads them while HIDThread
    /// writes, which a scalar tolerates and an array's buffer doesn't.
    private var gap0: UInt64 = 0, gap1: UInt64 = 0, gap2: UInt64 = 0
    private var gap3: UInt64 = 0, gap4: UInt64 = 0, gap5: UInt64 = 0
    var gapHistogramMs: [UInt64] { [gap0, gap1, gap2, gap3, gap4, gap5] }
    static let gapHistogramBucketsMs: [Double] = [2, 5, 10, 20, 40]

    private func bucketGap(_ gapMs: Double) {
        switch gapMs {
        case ..<2: gap0 &+= 1
        case ..<5: gap1 &+= 1
        case ..<10: gap2 &+= 1
        case ..<20: gap3 &+= 1
        case ..<40: gap4 &+= 1
        default: gap5 &+= 1
        }
    }

    /// Clears the gap histogram to start a fresh comparison window (e.g.
    /// before switching a device from USB to Bluetooth mid-diagnosis).
    func resetGapHistogram() {
        (gap0, gap1, gap2, gap3, gap4, gap5) = (0, 0, 0, 0, 0, 0)
    }

    /// Wall clock and this thread's consumed CPU time at the previous
    /// report — tells a *stalled* thread from a *busy* one. A delivery
    /// stall alone can't say why; comparing CPU burned across the gap can:
    ///
    ///   - CPU ≈ gap: the thread ran the whole time, busy inside another
    ///     source or an overrun handler. Ours to fix.
    ///   - CPU ≈ 0: the thread wasn't running. Ambiguous, not necessarily
    ///     unfixable — could be descheduled or paging (nothing userspace
    ///     can do), or blocked in `CGEventPost`'s mach IPC waiting on a busy
    ///     WindowServer (ours). `totalAverageMs`/`totalWorstMs` separate
    ///     these: a pipeline-total spike alongside the stall points at the
    ///     post, not at paging.
    ///
    /// Measured between consecutive callbacks, not across the stall window
    /// itself (not observable after the fact) — a superset of the stall, so
    /// near-zero CPU is conclusive while a large delta only narrows things
    /// to the run loop.
    ///
    /// A page-fault counter would separate "descheduled" from "paged," but
    /// `task_info` is a mach trap on a time-constraint thread, and the extra
    /// precision wouldn't change what to do about an already-ambiguous case.
    private var lastRecordWall: UInt64 = 0
    private var lastRecordThreadCPUNs: UInt64 = 0

    /// Gap and thread-CPU figures belonging to the worst stall in the current
    /// burst, so the logged line describes that report rather than whichever
    /// one happened to trip the rate limiter.
    private var burstWorstGapMs: Double = 0
    private var burstWorstCPUMs: Double = 0

    /// Called on HIDThread for every input report from the known-device path.
    func record(kernelTimestamp: UInt64) {
        let now = mach_absolute_time()
        guard now > kernelTimestamp else { return }
        let ms = Double(now - kernelTimestamp) * Self.timebaseFactor / 1_000_000.0

        // Sampled every report so a stall can be explained after the fact.
        // `clock_gettime_nsec_np` is a vDSO-style read, not a mach trap — a
        // few tens of nanoseconds, which the time-constraint computation
        // budget absorbs without noticing.
        let threadCPUNs = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let isFirstReport = lastRecordWall == 0
        let gapMs = isFirstReport
            ? 0
            : Double(now &- lastRecordWall) * Self.timebaseFactor / 1_000_000.0
        let cpuMs = lastRecordThreadCPUNs == 0
            ? 0
            : Double(threadCPUNs &- lastRecordThreadCPUNs) / 1_000_000.0
        lastRecordWall = now
        lastRecordThreadCPUNs = threadCPUNs

        if now < settlingDeadline {
            if ms > connectWorstMs { connectWorstMs = ms }
            if ms > Self.stallThresholdMs {
                connectStallCount &+= 1
                let oneSecondTicks = UInt64(1_000_000_000.0 / Self.timebaseFactor)
                if now &- lastLogTime > oneSecondTicks {
                    Self.log.info("connect-phase stall: \(ms, format: .fixed(precision: 1)) ms; connect stalls \(self.connectStallCount)")
                    lastLogTime = now
                }
            }
            return
        }
        reportCount &+= 1
        if !isFirstReport { bucketGap(gapMs) }
        averageMs += (ms - averageMs) / 64.0
        if ms > worstMs { worstMs = ms }
        if ms > Self.stallThresholdMs {
            stallCount &+= 1
            burstStallCount &+= 1
            if ms > burstWorstMs {
                burstWorstMs = ms
                burstWorstGapMs = gapMs
                burstWorstCPUMs = cpuMs
            }
            let oneSecondTicks = UInt64(1_000_000_000.0 / Self.timebaseFactor)
            if now &- lastLogTime > oneSecondTicks {
                // Logged at `.info`, matching the connect-phase line: `.warning`
                // persists to the on-disk log store, and this fires from the
                // time-constraint thread precisely when the disk is already the
                // suspect — a measurement that writes to the thing it is
                // measuring. Retrieve with `log show --info`.
                Self.log.info("delivery stall: worst \(self.burstWorstMs, format: .fixed(precision: 1)) ms over \(self.burstStallCount) report(s); thread ran \(self.burstWorstCPUMs, format: .fixed(precision: 2)) ms of \(self.burstWorstGapMs, format: .fixed(precision: 1)) ms since previous report; avg \(self.averageMs, format: .fixed(precision: 2)) ms, total stalls \(self.stallCount)")
                lastLogTime = now
                burstWorstMs = 0
                burstStallCount = 0
                burstWorstGapMs = 0
                burstWorstCPUMs = 0
            }
        }
    }

    /// Called on HIDThread after a report has been fully handled (decoded and
    /// all injection callbacks returned). Pairs with the `record` call made at
    /// callback entry for the same report; connect-phase reports are skipped
    /// entirely so both stages cover the same population.
    func recordPipelineComplete(kernelTimestamp: UInt64) {
        let now = mach_absolute_time()
        guard now > kernelTimestamp, now >= settlingDeadline else { return }
        let ms = Double(now - kernelTimestamp) * Self.timebaseFactor / 1_000_000.0
        totalAverageMs += (ms - totalAverageMs) / 64.0
        if ms > totalWorstMs { totalWorstMs = ms }
    }
}
