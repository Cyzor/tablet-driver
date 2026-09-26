// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

#if canImport(Darwin)
    import Darwin.Mach
#endif

/// Process memory-footprint probe — the memory-side counterpart to TabletKit's
/// `LatencyProbe`, kept app-side because it reads whole-process state for the
/// UI and has no decoder relevance.
///
/// Reports `phys_footprint`: the figure Activity Monitor calls "Memory" and
/// `vmmap` calls "Physical footprint" — dirty plus compressed pages this
/// process is charged for. Not RSS, which counts clean shared pages and
/// overstates a GUI app badly (237 MB RSS against an 87 MB footprint, measured).
/// The peak field is the point: it catches construction spikes that recover in
/// under two seconds, which no spot check would ever see.
///
/// One `task_info` mach trap per read — UI only, never the hot path or
/// `HIDThread`. Keeps no state, so no torn-read tolerance is needed.
enum FootprintProbe {

    /// A footprint reading in bytes.
    struct Reading: Sendable, Equatable {
        /// Current `phys_footprint` — dirty + compressed pages charged to
        /// this process.
        let current: UInt64
        /// Lifetime high-water mark (`ledger_phys_footprint_peak`), which is
        /// what the kernel remembers and what shows in Activity Monitor's
        /// peak column. Never decreases for the life of the process.
        let peak: UInt64

        init(current: UInt64, peak: UInt64) {
            self.current = current
            self.peak = peak
        }
    }

    /// Current footprint, or `nil` if the kernel call fails (it should not
    /// on a live task, but this is diagnostics — never trap for it).
    static func read() -> Reading? {
        #if canImport(Darwin)
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            // `phys_footprint_peak` lives past the end of the older
            // `TASK_VM_INFO` struct revision; `count` tells us whether the
            // running kernel actually filled it in. Fall back to the current
            // value rather than reporting a garbage peak.
            let peakOffset =
                MemoryLayout<task_vm_info>.offset(of: \.ledger_phys_footprint_peak) ?? 0
            let filledBytes = Int(count) * MemoryLayout<natural_t>.size
            let hasPeak = filledBytes >= peakOffset + MemoryLayout<UInt64>.size
            let current = UInt64(info.phys_footprint)
            let peak = hasPeak ? UInt64(info.ledger_phys_footprint_peak) : current
            return Reading(current: current, peak: Swift.max(peak, current))
        #else
            return nil
        #endif
    }

    /// Formats a byte count as megabytes with one decimal, matching the
    /// units `vmmap` and Activity Monitor use for this figure.
    static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / (1024.0 * 1024.0))
    }
}
