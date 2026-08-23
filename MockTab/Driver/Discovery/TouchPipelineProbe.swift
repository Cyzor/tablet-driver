// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Counts what each stage of the touch injection pipeline did with the
/// contacts handed to it, for inclusion in a discovery capture.
///
/// Why this exists: a discovery capture records the reports a device *sent*.
/// That is the whole answer when a device sends nothing, and no answer at all
/// when it sends well-formed contacts that produce no visible response — the
/// case a PTH-651 (0x0315) presented in issue #12, where four captures showed
/// clean BPT3 contact data arriving and touch did nothing. Localizing that
/// meant asking the reporter to check settings one at a time. These counters
/// make the file answer it instead.
///
/// Deliberately global rather than per-device. Touch injection is single-owner
/// at any instant (`InputInjector` is per-context, but only the context
/// driving the cursor receives contacts), a capture session targets one
/// tablet, and per-device keying would need an identity the injector doesn't
/// carry on this path. The cost of being wrong is a miscount in the
/// vanishingly rare two-tablets-touching-at-once case, against needing an
/// `IOHIDDevice` threaded through five call sites.
///
/// Thread safety: every `note` call runs on HIDThread; `snapshot`/`reset` run
/// on the main actor. An uncontended `OSAllocatedUnfairLock` acquisition is
/// tens of nanoseconds — immaterial next to the CGEvent post at the end of
/// the same frame, and this is not on the pen hot path at all.
enum TouchPipelineProbe {

    private static let state = OSAllocatedUnfairLock(
        initialState: DiscoveryTouchPipeline())

    /// Zero the counters. Called when a capture session starts so the file
    /// reflects that session and not everything since launch.
    static func reset() {
        state.withLock { $0 = DiscoveryTouchPipeline() }
    }

    static func snapshot() -> DiscoveryTouchPipeline {
        state.withLock { $0 }
    }

    /// Record one pipeline event. The closure form keeps every increment at
    /// its own call site rather than growing an enum of event kinds that has
    /// to be kept in sync with the struct.
    static func note(_ body: (inout DiscoveryTouchPipeline) -> Void) {
        state.withLock(body)
    }
}
