// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreFoundation
import Foundation
import os

/// Dedicated high-priority run-loop thread for IOHIDManager callbacks.
///
/// Scheduling IOHIDManager on the main run loop means HID reports are
/// delivered only when the main thread is idle — a SwiftUI rendering pass
/// can delay delivery by an entire frame (~8 ms at 120 Hz). HIDThread keeps
/// a CFRunLoop spinning on a `.userInteractive` background thread, so reports
/// arrive immediately regardless of what the main thread is doing.
///
/// Only IOHIDManager/IOHIDDevice scheduling should use this run loop.
/// The injection hot path (decode → InputInjector → CGEvent post) runs
/// inline on this thread; UI mutations hop to the main actor via
/// Task { @MainActor in … } from callbacks.
final class HIDThread {

    static let shared = HIDThread()

    /// The CFRunLoop running on the dedicated background thread.
    /// Safe to use from any thread for IOHIDDeviceScheduleWithRunLoop.
    let runLoop: CFRunLoop

    private init() {
        var captured: CFRunLoop?
        let sema = DispatchSemaphore(value: 0)

        let thread = Thread {
            captured = CFRunLoopGetCurrent()
            sema.signal()
            HIDThread.promoteToTimeConstraintPolicy()
            // Add a keep-alive source so the run loop doesn't exit when idle.
            let source = CFRunLoopSourceCreate(
                nil, 0,
                // UnsafeMutablePointer to CFRunLoopSourceContext — use a blank one.
                &HIDThread.blankSourceContext)
            if let source {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            CFRunLoopRun()
        }
        thread.name = "com.cyzor.mocktab.hid"
        thread.qualityOfService = .userInteractive
        thread.start()

        sema.wait()
        guard let rl = captured else {
            fatalError("HIDThread: run loop capture failed — thread never started")
        }
        runLoop = rl
    }

    /// Promote the calling thread to `THREAD_TIME_CONSTRAINT_POLICY` so HID
    /// report delivery keeps its scheduling priority under system load
    /// (LatencyProbe showed 5–9 ms delivery stalls during I/O storms that
    /// ordinary `.userInteractive` QoS didn't prevent). Parameters sized for
    /// a 133 Hz report stream: period ≈7.5 ms, computation ≈500 µs per
    /// report, constraint 2 ms, preemptible. On failure the thread simply
    /// stays at `.userInteractive` QoS.
    private static func promoteToTimeConstraintPolicy() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticksPerNs = Double(timebase.denom) / Double(timebase.numer)
        func ticks(_ ms: Double) -> UInt32 { UInt32(ms * 1_000_000.0 * ticksPerNs) }

        var policy = thread_time_constraint_policy(
            period: ticks(7.5),
            computation: ticks(0.5),
            constraint: ticks(2.0),
            preemptible: 1)
        let count = mach_msg_type_number_t(
            MemoryLayout<thread_time_constraint_policy>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),
                                  $0, count)
            }
        }
        let log = Logger(subsystem: "com.mocktab.latency", category: "policy")
        if result == KERN_SUCCESS {
            log.info("HIDThread promoted to time-constraint scheduling policy")
        } else {
            log.warning("time-constraint policy rejected (kern \(result)); staying at userInteractive QoS")
        }
    }

    // A do-nothing CFRunLoopSourceContext used to keep the run loop alive.
    private static var blankSourceContext = CFRunLoopSourceContext(
        version: 0, info: nil,
        retain: nil, release: nil, copyDescription: nil,
        equal: nil, hash: nil,
        schedule: nil, cancel: nil,
        perform: { _ in })
}

/// Delivery-latency probe for HID input reports.
///
/// Measures kernel-receipt → callback-entry latency from the timestamp
/// supplied by `IOHIDDeviceRegisterInputReportWithTimeStampCallback`
/// (mach absolute time stamped when the kernel received the report).
/// Sustained spikes here mean HIDThread is being starved by system load —
/// the precondition for promoting it to a time-constraint (real-time)
/// scheduling policy.
///
/// Cost per report: one `mach_absolute_time()` call and a few double ops.
/// No allocations, no timers. All writes happen on HIDThread; reads from
/// the diagnostics UI are non-atomic snapshots (same tolerated-torn-read
/// pattern as `CursorSmoother.jitterLevel`) — a stale value is harmless.
final class LatencyProbe {

    static let shared = LatencyProbe()

    /// mach timebase → nanoseconds conversion factor, computed once.
    private static let timebaseFactor: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    /// Delivery latency above this counts as a scheduling stall.
    static let stallThresholdMs: Double = 5.0

    /// EMA of delivery latency (α = 1/64 ≈ 0.5 s settling at 133 Hz).
    private(set) var averageMs: Double = 0
    /// Worst latency observed since launch.
    private(set) var worstMs: Double = 0
    /// Reports delivered later than `stallThresholdMs`.
    private(set) var stallCount: UInt64 = 0
    private(set) var reportCount: UInt64 = 0

    /// Unified-log channel for stall episodes, so evidence survives without
    /// the diagnostics pane being open. Retrieve after the fact with:
    ///   log show --last 1h --predicate 'subsystem == "com.mocktab.latency"'
    private static let log = Logger(subsystem: "com.mocktab.latency", category: "stall")

    /// Stalls arrive in bursts during load storms; log the burst, not every
    /// report. At most one line per second (mach ticks), each summarizing
    /// the worst latency seen since the previous line.
    private var lastLogTime: UInt64 = 0
    private var burstWorstMs: Double = 0
    private var burstStallCount: UInt64 = 0

    /// Called on HIDThread for every input report from the known-device path.
    func record(kernelTimestamp: UInt64) {
        let now = mach_absolute_time()
        guard now > kernelTimestamp else { return }
        let ms = Double(now - kernelTimestamp) * Self.timebaseFactor / 1_000_000.0
        reportCount &+= 1
        averageMs += (ms - averageMs) / 64.0
        if ms > worstMs { worstMs = ms }
        if ms > Self.stallThresholdMs {
            stallCount &+= 1
            burstStallCount &+= 1
            if ms > burstWorstMs { burstWorstMs = ms }
            let oneSecondTicks = UInt64(1_000_000_000.0 / Self.timebaseFactor)
            if now &- lastLogTime > oneSecondTicks {
                Self.log.warning("delivery stall: worst \(self.burstWorstMs, format: .fixed(precision: 1)) ms over \(self.burstStallCount) report(s); avg \(self.averageMs, format: .fixed(precision: 2)) ms, total stalls \(self.stallCount)")
                lastLogTime = now
                burstWorstMs = 0
                burstStallCount = 0
            }
        }
    }
}
