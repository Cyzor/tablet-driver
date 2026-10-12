// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
import TabletKit
import Testing

@Suite("Ring scroll glide")
struct RingScrollGlideTests {

    /// Feeds one notch through a glide on the pen thread and returns every
    /// increment it posted once it should have settled.
    private func posts(forLines lines: Double) async throws -> [Double] {
        let posted = OSAllocatedUnfairLock(initialState: [Double]())
        let glide = RingScrollGlide { dy in posted.withLock { $0.append(dy) } }
        CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) {
            glide.impulse(lines: lines)
        }
        CFRunLoopWakeUp(HIDThread.shared.runLoop)
        try await Task.sleep(for: .milliseconds(600))
        let settled = posted.withLock { $0 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(posted.withLock { $0.count } == settled.count, "glide still posting after it settled")
        _ = glide
        return settled
    }

    @Test("A half-point remainder stops instead of wobbling", arguments: [0.25, -0.25, 0.75, 1.0])
    func settles(lines: Double) async throws {
        let posted = try await posts(forLines: lines)
        let total = posted.reduce(0, +)
        #expect(abs(total - lines * RingScrollGlide.pointsPerLine) <= 0.5)
    }
}
