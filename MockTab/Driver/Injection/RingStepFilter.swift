// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

/// Tells a finger turning a touch ring from a hand resting on it.
///
/// A ring reports one position. A hand touching two spots reads as that
/// position flipping between them on every report, which scrolled back and
/// forth while the pen held still (PTH-850 turned to portrait, ring under
/// the hand). A finger reverses once and keeps going, so a reversal waits
/// for a second step before it moves anything; the step it then applies
/// covers the whole distance, so a real turn loses nothing.
///
/// Free of AppKit and TabletKit so the checks can compile it.
struct RingStepFilter {
    private var direction = 0
    private var reversalPending = false

    /// Whether a move of `delta` steps from the last accepted position
    /// counts. When it doesn't, keep that position and measure the next
    /// report from it.
    mutating func accepts(_ delta: Int) -> Bool {
        guard delta != 0 else {
            reversalPending = false
            return true
        }
        let sign = delta > 0 ? 1 : -1
        if direction == 0 || sign == direction || reversalPending {
            direction = sign
            reversalPending = false
            return true
        }
        reversalPending = true
        return false
    }

    /// Forgets the direction, as when the finger lifts.
    mutating func reset() {
        direction = 0
        reversalPending = false
    }
}
