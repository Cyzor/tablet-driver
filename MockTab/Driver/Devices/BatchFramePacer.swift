// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import TabletKit

/// One decoded sample from a batched HID report: a pen point or a touch
/// contact set. Both kinds stay in decode order, because touch arbitration
/// reads the pen's proximity, and a touch frame delivered ahead of a queued
/// pen frame would read it stale.
enum BatchedFrame {
    case pen(TabletPoint)
    case touch([TouchContact])
}

/// Spreads a batch of already-decoded pen/touch samples across the interval
/// they actually span, instead of delivering them all in one synchronous
/// burst.
///
/// Some Bluetooth tablets (Intuos Pro 2 and similar) sample at ~200 Hz but
/// send 4–5 samples per report every ~22 ms, touch frames included. Posted
/// straight through, the cursor leaps in bursts at the report rate instead
/// of moving at the sample rate.
///
/// Only reports that decode to more than one sample use it; USB and
/// single-sample reports pay nothing (see `TransportEventHandler.dispatchBatch`).
///
/// HIDThread-confined, like `MomentumTail` and `RingScrollGlide`.
final class BatchFramePacer {

    /// Delivers one paced frame; this type only does timing. The owner sets
    /// `InputInjector.currentReportTimestampNs` to `timestampNs` around the
    /// call, so stale-report suppression still works for a frame delivered
    /// after its report's handler has returned.
    private let deliver: (_ frame: BatchedFrame, _ timestampNs: UInt64) -> Void

    private var timer: CFRunLoopTimer?
    /// Queued frames with absolute due times (system uptime), oldest first.
    /// Absolute rather than chained, so a late tick doesn't push every later
    /// frame back with it.
    private var pending: [(frame: BatchedFrame, timestampNs: UInt64, dueAt: TimeInterval)] = []

    init(deliver: @escaping (_ frame: BatchedFrame, _ timestampNs: UInt64) -> Void) {
        self.deliver = deliver
    }

    deinit {
        timer.map { CFRunLoopTimerInvalidate($0) }
    }

    /// Queues frames to be delivered one per `interval`, oldest first.
    ///
    /// Frames still queued from a prior batch are flushed first. Callers must
    /// also flush before delivering anything synchronously: a pen exit posted
    /// ahead of queued frames from the same lift leaves proximity stuck on,
    /// which blocks touch. `dispatchBatch` flushes at its top for this reason.
    func schedule(_ frames: [(frame: BatchedFrame, timestampNs: UInt64)], interval: TimeInterval) {
        flush()
        guard !frames.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        pending = frames.enumerated().map { i, item in
            (item.frame, item.timestampNs, now + Double(i + 1) * interval)
        }
        scheduleTick()
    }

    /// Queues one more frame `delay` seconds from now, behind anything already
    /// queued and without flushing it. For samples that arrive as separate
    /// reports within one radio window (PTK-870 over Bluetooth LE), where the
    /// batch isn't known up front. A due time earlier than the queue's tail
    /// is raised to it, so order always holds.
    func append(_ frame: BatchedFrame, timestampNs: UInt64, delay: TimeInterval) {
        var dueAt = ProcessInfo.processInfo.systemUptime + max(0, delay)
        if let last = pending.last { dueAt = max(dueAt, last.dueAt) }
        pending.append((frame, timestampNs, dueAt))
        if timer == nil { scheduleTick() }
    }

    /// Delivers everything still queued, immediately, in order, and returns
    /// how many. Nonzero in steady state means a batch didn't finish pacing
    /// before the next report (see `CaptureTouchPipeline.pacerFlushDeliveredFrames`).
    @discardableResult
    func flush() -> Int {
        timer.map { CFRunLoopTimerInvalidate($0) }
        timer = nil
        guard !pending.isEmpty else { return 0 }
        let rest = pending
        pending = []
        for item in rest { deliver(item.frame, item.timestampNs) }
        return rest.count
    }

    private func scheduleTick() {
        guard let next = pending.first else { return }
        let t = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + max(0, next.dueAt - ProcessInfo.processInfo.systemUptime), 0, 0, 0
        ) { [weak self] _ in self?.tick() }
        CFRunLoopAddTimer(HIDThread.shared.runLoop, t, .commonModes)
        timer = t
    }

    private func tick() {
        timer = nil
        // Everything already due goes now, so a late tick catches up instead
        // of carrying its lateness forward.
        let now = ProcessInfo.processInfo.systemUptime
        while let item = pending.first, item.dueAt <= now + 0.0002 {
            pending.removeFirst()
            deliver(item.frame, item.timestampNs)
        }
        if !pending.isEmpty { scheduleTick() }
    }
}
