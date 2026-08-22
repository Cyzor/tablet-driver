// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import TabletKit

/// Spreads a batch of already-decoded pen samples across the interval they
/// actually span, instead of delivering them all in one synchronous burst.
///
/// Some Bluetooth tablets (Intuos Pro 2 BT and similar) buffer several
/// native-rate samples internally and flush them as one HID report at a much
/// lower report rate — confirmed on-device: ~201 Hz native sampling batched
/// into a ~22.5ms/18-slot BT report interval, 4-5 samples per report. Fed
/// straight through, all 4-5 samples reach `CGEventPost` within a fraction of
/// a millisecond of each other, then nothing for ~22.5ms — the cursor visibly
/// leaps in bursts at the report rate instead of advancing smoothly at the
/// device's real sample rate. Confirmed with a `CGEventTap` capture during
/// live drawing: bimodal inter-event gaps (76.6% <2ms, 22.4% at 18-25ms).
///
/// This only ever activates for a report that decoded to more than one pen
/// sample — USB and single-sample BT reports are untouched and pay zero cost
/// (no timer, no allocation; see `WacomKnownDevice.dispatchPenBatch`).
///
/// HIDThread-confined, like every other injection-adjacent timer in this
/// codebase (`MomentumTail`, `DialScrollCoaster`) — scheduled on
/// `HIDThread.shared.runLoop`, mutated only from its own timer handler or
/// from calls already on that thread.
final class PenBatchPacer {

    /// Delivers one paced frame. Supplied by the owner (`WacomKnownDevice`)
    /// so this type has no knowledge of `InputInjector` or event
    /// construction — its only job is timing. The owner is responsible for
    /// setting `InputInjector.currentReportTimestampNs` to `timestampNs`
    /// around the call so stale-report suppression keeps working correctly
    /// for a frame delivered well after its own report's `handleReport` call
    /// has already returned (and already cleared that static via its own
    /// `defer`) — see the call site for why this must not be skipped.
    private let deliver: (_ point: TabletPoint, _ timestampNs: UInt64) -> Void

    private var timer: CFRunLoopTimer?
    private var pending: [(point: TabletPoint, timestampNs: UInt64)] = []
    private var tickInterval: TimeInterval = 0

    init(deliver: @escaping (_ point: TabletPoint, _ timestampNs: UInt64) -> Void) {
        self.deliver = deliver
    }

    deinit {
        timer.map { CFRunLoopTimerInvalidate($0) }
    }

    var isPacing: Bool { timer != nil }

    /// Queues frames to be delivered one per `interval`, oldest first. Any
    /// frames still queued from a prior batch are flushed immediately first —
    /// see `WacomKnownDevice.dispatchPenBatch`'s overlap-policy note for why
    /// that's the right call here (rare in steady state; favors never
    /// dropping real samples over strict pacing fidelity in the rare case a
    /// new batch outruns the previous one's drain).
    func schedule(_ frames: [(point: TabletPoint, timestampNs: UInt64)], interval: TimeInterval) {
        flush()
        guard !frames.isEmpty else { return }
        pending = frames
        tickInterval = interval
        scheduleTick()
    }

    /// Delivers everything still queued, immediately, in order. No-op if
    /// nothing is pending.
    func flush() {
        timer.map { CFRunLoopTimerInvalidate($0) }
        timer = nil
        guard !pending.isEmpty else { return }
        let rest = pending
        pending = []
        for frame in rest { deliver(frame.point, frame.timestampNs) }
    }

    private func scheduleTick() {
        let t = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + tickInterval,
            0, 0, 0
        ) { [weak self] _ in self?.tick() }
        CFRunLoopAddTimer(HIDThread.shared.runLoop, t, .commonModes)
        timer = t
    }

    private func tick() {
        timer = nil
        guard !pending.isEmpty else { return }
        let frame = pending.removeFirst()
        deliver(frame.point, frame.timestampNs)
        if !pending.isEmpty { scheduleTick() }
    }
}
