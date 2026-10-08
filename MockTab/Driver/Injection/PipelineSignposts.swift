// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

import os

/// Instruments intervals for each stage of the pen path: the whole report,
/// injection, and the event post. Decode time is what's left of a report
/// after its injection.
///
/// The dynamic-tracing category keeps them off until Instruments records,
/// so the path pays only a flag check, about 7 ns. Ordinary signposts cost
/// about 380 ns per interval even when nothing is recording.
enum PipelineSignposts {
    static let signposter = OSSignposter(
        logHandle: OSLog(subsystem: "com.cyzor.mocktab", category: .dynamicTracing))

    @inline(__always)
    static func begin(_ name: StaticString) -> OSSignpostIntervalState? {
        signposter.isEnabled ? signposter.beginInterval(name) : nil
    }

    @inline(__always)
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState?) {
        if let state { signposter.endInterval(name, state) }
    }
}
