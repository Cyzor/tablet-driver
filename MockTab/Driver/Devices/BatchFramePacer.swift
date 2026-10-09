// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import TabletKit

/// One decoded sample from a batched HID report — a pen point or a touch
/// contact-set. Kept in strict decode order across both kinds: `penBusy` in
/// `InputInjector.injectTouch` arbitrates touch against the pen's live
/// proximity state, so a touch frame delivered out of order relative to a
/// still-queued pen frame can read stale proximity — see
/// `WacomKnownDevice.dispatchBatch`'s flush-first requirement.
enum BatchedFrame {
    case pen(TabletPoint)
    case touch([TouchContact])
}

/// Spreads a batch of already-decoded pen/touch samples across the interval
/// they actually span, instead of delivering them all in one synchronous
/// burst.
///
/// Some Bluetooth tablets (Intuos Pro 2 BT and similar) buffer several
/// native-rate samples internally and flush them as one HID report at a much
/// lower report rate — confirmed on-device: ~201 Hz native pen sampling
/// batched into a ~22.5ms/18-slot BT report interval, 4-5 samples per
/// report; touch frames are packed the same way in the same report
/// (`decodeBTTouch`, up to 4 per report). Fed straight through, all samples
/// in a batch reach `CGEventPost` within a fraction of a millisecond of each
/// other, then nothing until the next batch — the cursor visibly leaps in
/// bursts at the report rate instead of advancing smoothly at the device's
/// real sample rate. Confirmed with a `CGEventTap` capture during live
/// drawing: bimodal inter-event gaps (76.6% <2ms, 22.4% at 18-25ms) before
/// pacing; unimodal (91.5% in a 3-8ms band) after.
///
/// This only ever activates for a report that decoded to more than one
/// pen+touch sample combined — USB and single-sample BT reports are
/// untouched and pay zero cost (no timer, no allocation; see
/// `WacomKnownDevice.dispatchBatch`).
///
/// HIDThread-confined, like every other injection-adjacent timer in this
/// codebase (`MomentumTail`, `RingScrollGlide`) — scheduled on
/// `HIDThread.shared.runLoop`, mutated only from its own timer handler or
/// from calls already on that thread.
final class BatchFramePacer {

    /// Delivers one paced frame. Supplied by the owner (`WacomKnownDevice`)
    /// so this type has no knowledge of `InputInjector` or event
    /// construction — its only job is timing. The owner is responsible for
    /// setting `InputInjector.currentReportTimestampNs` to `timestampNs`
    /// around the call so stale-report suppression keeps working correctly
    /// for a frame delivered well after its own report's `handleReport` call
    /// has already returned (and already cleared that static via its own
    /// `defer`) — see the call site for why this must not be skipped.
    private let deliver: (_ frame: BatchedFrame, _ timestampNs: UInt64) -> Void

    private var timer: CFRunLoopTimer?
    /// Queued frames with absolute due times (`CFAbsoluteTime`), oldest first.
    /// Absolute rather than chained, so a late tick doesn't push every later
    /// frame back with it.
    private var pending: [(frame: BatchedFrame, timestampNs: UInt64, dueAt: CFAbsoluteTime)] = []

    init(deliver: @escaping (_ frame: BatchedFrame, _ timestampNs: UInt64) -> Void) {
        self.deliver = deliver
    }

    deinit {
        timer.map { CFRunLoopTimerInvalidate($0) }
    }

    var isPacing: Bool { timer != nil }

    /// Queues frames to be delivered one per `interval`, oldest first.
    ///
    /// Any frames still queued from a prior batch are flushed immediately
    /// first. This used to be framed as just an overlap policy ("rare in
    /// steady state"), but it's load-bearing, not a corner case: the caller
    /// must also flush before delivering anything synchronously (a
    /// single-sample report, or the implausible-interval bypass path) —
    /// otherwise a synchronous pen-exit delivery can post *after* residual
    /// queued frames from the same lift are still pending, re-asserting
    /// in-proximity and leaving `InputInjector.lastProximity` stuck true.
    /// That silently kills touch (`injectTouch`'s `penBusy` gate) until
    /// something else happens to flip proximity again — confirmed as the
    /// mechanism behind "touch registers points but produces no action,
    /// degrades after a few uses" (2026-08-22). See `dispatchBatch`, which
    /// flushes unconditionally at its top for exactly this reason.
    func schedule(_ frames: [(frame: BatchedFrame, timestampNs: UInt64)], interval: TimeInterval) {
        flush()
        guard !frames.isEmpty else { return }
        let now = CFAbsoluteTimeGetCurrent()
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
        var dueAt = CFAbsoluteTimeGetCurrent() + max(0, delay)
        if let last = pending.last { dueAt = max(dueAt, last.dueAt) }
        pending.append((frame, timestampNs, dueAt))
        if timer == nil { scheduleTick() }
    }

    /// Delivers everything still queued, immediately, in order. No-op if
    /// nothing is pending. Returns how many frames it delivered — a nonzero
    /// return in steady state means a batch didn't finish pacing before the
    /// next report arrived, and those frames reached the injector bunched
    /// (see `DiscoveryTouchPipeline.pacerFlushDeliveredFrames`).
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
            kCFAllocatorDefault, next.dueAt, 0, 0, 0
        ) { [weak self] _ in self?.tick() }
        CFRunLoopAddTimer(HIDThread.shared.runLoop, t, .commonModes)
        timer = t
    }

    private func tick() {
        timer = nil
        // Everything already due goes now, so a late tick catches up instead
        // of carrying its lateness forward.
        let now = CFAbsoluteTimeGetCurrent()
        while let item = pending.first, item.dueAt <= now + 0.0002 {
            pending.removeFirst()
            deliver(item.frame, item.timestampNs)
        }
        if !pending.isEmpty { scheduleTick() }
    }
}
