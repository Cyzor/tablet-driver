// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import os
import TabletKit

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "capture")

/// Lightweight raw-HID capture buffer.
///
/// Call `HIDCapture.shared.record(tag:report:length:)` at the top of every
/// `handleReport()` to accumulate a hex dump of every incoming report.
/// Start/stop/save are driven from InfoView.
///
/// Thread safety: `record(...)` is invoked from the IOHIDManager callback,
/// which now runs on HIDThread (see HIDThread.swift), while `start/stop/
/// clear/save` and the `isCapturing`/`reportCount` reads come from the UI
/// on main. All state is therefore guarded by a single unfair lock; the
/// per-report cost is a couple of atomics, negligible at 133 Hz.
final class HIDCapture {

    static let shared = HIDCapture()
    private init() {}

    /// ASCII bytes for hex digits 0–F, indexed by nibble. Lives in static
    /// storage so the per-report hex builder doesn't materialize it each call.
    private static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

    // MARK: - State (guarded by `state`'s lock)

    private struct State {
        var isCapturing = false
        var reportCount = 0
        var lines: [String] = []
        var startTime: Date = .init()
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    var isCapturing: Bool { state.withLock { $0.isCapturing } }
    var reportCount: Int { state.withLock { $0.reportCount } }

    // MARK: - Control

    func start() {
        state.withLock {
            $0.lines.removeAll()
            $0.reportCount = 0
            $0.startTime = Date()
            $0.isCapturing = true
        }
    }

    func stop() {
        state.withLock { $0.isCapturing = false }
    }

    func clear() {
        state.withLock {
            $0.lines.removeAll()
            $0.reportCount = 0
        }
    }

    // MARK: - Recording

    /// Append one report to the in-memory buffer.
    /// Called from IOHIDReportCallback on HIDThread — must stay
    /// allocation-light and fast. State is guarded by `lock`.
    func record(tag: String, report: UnsafePointer<UInt8>, length: Int) {
        guard length > 0 else { return }

        // Format outside the lock to keep the critical section minimal.
        // Read startTime atomically under the lock first, with an early
        // exit if capturing is off.
        let captureStart: Date? = state.withLock {
            $0.isCapturing ? $0.startTime : nil
        }
        guard let start = captureStart else { return }

        let elapsed = Date().timeIntervalSince(start)
        let mins = Int(elapsed) / 60
        let secs = Int(elapsed) % 60
        let ms = Int((elapsed - Double(Int(elapsed))) * 1000)
        let ts = String(format: "%02d:%02d.%03d", mins, secs, ms)

        // Hex dump: build directly into a single allocation rather than
        // `length` intermediate Strings + an Array + a join.  At ~133 Hz with
        // 10–64 byte reports this is the dominant cost while capturing.
        let hexCount = length == 0 ? 0 : length * 3 - 1  // "AB AB AB" — 3 chars per byte minus trailing space
        let hex = String(unsafeUninitializedCapacity: hexCount) { buf in
            let digits = Self.hexDigits
            var p = 0
            for i in 0..<length {
                if i > 0 {
                    buf[p] = 0x20  // ' '
                    p += 1
                }
                let b = report[i]
                buf[p] = digits[Int(b >> 4)]
                buf[p + 1] = digits[Int(b & 0x0F)]
                p += 2
            }
            return p
        }
        let id0 = report[0]
        let id = String(unsafeUninitializedCapacity: 2) { buf in
            buf[0] = Self.hexDigits[Int(id0 >> 4)]
            buf[1] = Self.hexDigits[Int(id0 & 0x0F)]
            return 2
        }

        // Pad tag to 20 chars for column alignment across devices.
        let padded =
            tag.count <= 20
            ? tag + String(repeating: " ", count: 20 - tag.count)
            : String(tag.prefix(20))

        let line = "[\(ts)] \(padded) ID=\(id) len=\(String(format: "%-4d", length))  \(hex)"

        state.withLock {
            // Re-check under the lock: capture may have stopped while we
            // were formatting. If it did, drop this line.
            guard $0.isCapturing else { return }
            $0.lines.append(line)
            $0.reportCount += 1
        }
    }

    // MARK: - Persistence

    /// Write captured lines to ~/Desktop/mocktab_capture_<timestamp>.txt.
    /// Returns the URL on success, nil if the buffer is empty or write fails.
    @discardableResult
    func save() -> URL? {
        // Snapshot all state under the lock so a concurrent record()
        // on HIDThread can't mutate `lines` while we're joining it.
        let snapshot: (lines: [String], start: Date, count: Int)? = state.withLock {
            guard !$0.lines.isEmpty else { return nil }
            return ($0.lines, $0.startTime, $0.reportCount)
        }
        guard let snap = snapshot else { return nil }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = fmt.string(from: snap.start)

        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/mocktab_capture_\(stamp).txt")

        let header = """
            MockTab HID Capture
            Started : \(snap.start)
            Reports : \(snap.count)
            Format  : [mm:ss.ms] <device-tag>            ID=<hex> len=<n>  <hex bytes>
            ──────────────────────────────────────────────────────────────────────────────────────

            """

        let content = header + snap.lines.joined(separator: "\n") + "\n"
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            logger.error("HIDCapture: save failed — \(error, privacy: .public)")
            return nil
        }
    }
}
