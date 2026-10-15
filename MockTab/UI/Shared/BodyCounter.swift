// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Debug-only count of SwiftUI body evaluations, for checking which views
/// re-run on live input. Off unless launched with `-debugBodyCounts YES`;
/// logs one line every 10 s listing each view that ran, then resets.
///
/// Call as the first line of a body: `let _ = BodyCounter.note("Buttons")`.
@MainActor
enum BodyCounter {
    #if DEBUG
        private static let enabled = UserDefaults.standard.bool(forKey: "debugBodyCounts")
        private static let logger = Logger(subsystem: "com.cyzor.mocktab", category: "bodycount")
        private static var counts: [String: Int] = [:]
        private static var timer: Timer?
    #endif

    static func note(_ name: String) {
        #if DEBUG
            guard enabled else { return }
            counts[name, default: 0] += 1
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                    MainActor.assumeIsolated { flush() }
                }
            }
        #endif
    }

    #if DEBUG
        private static func flush() {
            guard !counts.isEmpty else { return }
            let line = counts.sorted { $0.value > $1.value }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
            logger.notice("bodies/10s: \(line, privacy: .public)")
            counts.removeAll()
        }
    #endif
}
