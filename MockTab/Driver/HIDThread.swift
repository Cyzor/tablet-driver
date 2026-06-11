// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreFoundation
import Foundation

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

    /// Called on HIDThread for every input report from the known-device path.
    func record(kernelTimestamp: UInt64) {
        let now = mach_absolute_time()
        guard now > kernelTimestamp else { return }
        let ms = Double(now - kernelTimestamp) * Self.timebaseFactor / 1_000_000.0
        reportCount &+= 1
        averageMs += (ms - averageMs) / 64.0
        if ms > worstMs { worstMs = ms }
        if ms > Self.stallThresholdMs { stallCount &+= 1 }
    }
}
