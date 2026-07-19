// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

/// State machine for the "Scroll Drag" button binding: while the bound button
/// is held, pen motion is converted into trackpad-style scroll intents
/// (began/changed/ended) instead of cursor motion.
///
/// Deliberately mirrors `TouchStateTracker`'s shape: no I/O, no clocks, no
/// globals — everything arrives via `process(...)`/edge calls so tests can
/// drive it, and the only event-construction site (`InputInjector.postPanScroll`)
/// stays a single replaceable backend.
///
/// Momentum is *not* synthesized here. macOS only generates inertia for scroll
/// streams arriving from hardware through IOKit HID; CGEvent-posted scrolls go
/// straight to apps exactly as sent. Real system inertia therefore requires
/// reporting contacts to a virtual HID trackpad (the parked IOHIDUserDevice
/// spike) — at which point this tracker's intents become "report contact
/// began/moved/ended" and the posting backend is swapped. To keep that future
/// cheap, a short-window release velocity is maintained from day one (it is
/// the entire input a momentum tail needs, real or synthetic); v1 records it
/// and discards it.
///
/// Owned by `InputInjector`; HIDThread-confined like its sibling trackers.
struct PanScrollTracker {

    enum ScrollPhase: Int {
        case began = 1
        case changed = 2
        case ended = 4
    }

    enum Intent: Equatable {
        case none
        case scroll(dx: Double, dy: Double, phase: ScrollPhase)
    }

    // MARK: - State

    private(set) var isActive = false

    /// Screen position from the previous frame while active; the scroll delta
    /// is `current - last`. Nil on the first frame after engage/resume so a
    /// resume never replays the distance traveled while the pen was away.
    private var last: CGPoint?

    /// Fractional-pixel carry. Scroll events are Int32 pixels; a slow pan
    /// moves < 1 px/frame at 133 Hz and would stall without accumulating the
    /// remainder (same pattern as the ring/strip accumulators).
    private var accumX = 0.0
    private var accumY = 0.0

    /// Exponential moving average of per-frame velocity (points/second), for
    /// the future momentum tail. alpha chosen so the window spans ~50 ms at
    /// pen report rates — matches the scale of a trackpad's flick sampling.
    private var velX = 0.0
    private var velY = 0.0

    /// Sign applied to deltas: natural scrolling (content follows pen) is the
    /// default; reversed matches classic scroll-wheel semantics. Captured at
    /// engage from the snapshot so a mid-gesture settings change doesn't
    /// flip direction under the user's hand.
    private var sign = 1.0

    /// Delta multiplier captured at engage (from `ToolSettings.panScrollSpeed`).
    private var speed = 1.0

    /// Release velocity in points/second — the momentum seed. Read by the
    /// posting layer when it gains a tail; unused in v1.
    private(set) var releaseVelocity: CGVector = .zero

    // MARK: - Tunables

    /// EMA weight per frame for the velocity estimate (~50 ms window at 133 Hz).
    static let velocityAlpha = 0.20

    // MARK: - Edges

    /// Begin the gesture. Emits `.began` with zero delta; the first real
    /// motion arrives as `.changed` on the next frame. `reverse` selects
    /// classic (wheel) rather than natural (content-follows) direction.
    /// `speed` multiplies deltas (0.25 slow – 3.0 fast, 1.0 = 1:1).
    mutating func engage(reverse: Bool, speed: Double = 1.0) -> Intent {
        isActive = true
        sign = reverse ? -1.0 : 1.0
        self.speed = max(0.05, speed)
        last = nil
        accumX = 0
        accumY = 0
        velX = 0
        velY = 0
        releaseVelocity = .zero
        return .scroll(dx: 0, dy: 0, phase: .began)
    }

    /// End the gesture (real button release, or a confirmed proximity exit).
    /// Idempotent — a second call after an inactive period emits nothing.
    mutating func disengage() -> Intent {
        guard isActive else { return .none }
        releaseVelocity = CGVector(dx: velX, dy: velY)
        isActive = false
        last = nil
        return .scroll(dx: 0, dy: 0, phase: .ended)
    }

    /// The pen left range (or was suspended by a debounced exit) while the
    /// gesture is held: forget the anchor so resumption doesn't jump, but
    /// keep the gesture logically open — Xencelabs debounced out-of-range
    /// blips must not close a pan the user is still holding.
    mutating func suspend() {
        last = nil
    }

    // MARK: - Per-frame

    /// One in-proximity frame while active. `screen` is the mapped,
    /// smoothing-filtered absolute screen point; `dt` is seconds since the
    /// previous frame (for the velocity estimate only — deltas themselves are
    /// displacement, not rate).
    mutating func process(screen: CGPoint, dt: Double) -> Intent {
        guard isActive else { return .none }
        guard let prev = last else {
            // First frame after engage/suspend: anchor only, no delta.
            last = screen
            return .none
        }
        last = screen

        let dx = (screen.x - prev.x) * sign * speed
        let dy = (screen.y - prev.y) * sign * speed

        // Velocity EMA (ungated, so a stop decays the estimate toward zero —
        // a flick-then-hold release must not carry stale flick velocity).
        if dt > 0 {
            let a = Self.velocityAlpha
            velX += a * (dx / dt - velX)
            velY += a * (dy / dt - velY)
        }

        accumX += dx
        accumY += dy
        let ix = Int(accumX.rounded(.towardZero))
        let iy = Int(accumY.rounded(.towardZero))
        guard ix != 0 || iy != 0 else { return .none }
        accumX -= Double(ix)
        accumY -= Double(iy)
        return .scroll(dx: Double(ix), dy: Double(iy), phase: .changed)
    }
}
