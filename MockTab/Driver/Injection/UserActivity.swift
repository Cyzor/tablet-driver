// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.pwr_mgt

/// macOS doesn't count posted events as the user's activity, so a pen alone
/// couldn't wake a sleeping display or hold off display sleep and the screen
/// saver. Every posted event calls `noteInput`, which tells macOS so at most
/// every 5 s, the way a mouse would.
enum UserActivity {
    private static let periodNs: UInt64 = 5_000_000_000
    // Posting threads; a race only means an extra declaration.
    nonisolated(unsafe) private static var lastNs: UInt64 = 0
    // Off the posting thread: the declaration is a round trip to powerd.
    private static let queue = DispatchQueue(label: "MockTab user activity", qos: .userInitiated)
    // Queue-confined. Reused, so each declaration renews one assertion.
    nonisolated(unsafe) private static var assertion: IOPMAssertionID = IOPMAssertionID(0)

    static func noteInput() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard now &- lastNs >= periodNs else { return }
        lastNs = now
        queue.async {
            var id = assertion
            IOPMAssertionDeclareUserActivity("MockTab tablet input" as CFString, kIOPMUserActiveLocal, &id)
            assertion = id
        }
    }
}
