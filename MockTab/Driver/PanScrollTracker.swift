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

    /// Dominant scroll axis, once established (see `axisLockRatio`). Real
    /// trackpad drivers do the same "directional lock": without it, a slight
    /// diagonal drift during a vertical scroll bleeds a horizontal component
    /// into the event stream, which some apps (Firefox's swipe-to-navigate
    /// gesture recognizer, in particular) can mistake for a two-finger swipe
    /// gesture instead of a scroll — hijacking or truncating it. Locking to
    /// one axis and zeroing the other for the rest of the gesture avoids that.
    ///
    /// The lock is decided by the *angle* of travel, not raw distance: a
    /// near-axis gesture (an ordinary scroll) commits almost immediately,
    /// while a genuinely diagonal drag (a Hand-tool-style free pan in an app
    /// like Illustrator or Rebelle) never crosses the ratio and stays
    /// omnidirectional for the whole gesture. This is what lets one behavior
    /// serve both cases without a user-facing setting.
    private enum Axis { case vertical, horizontal }
    private var axisLock: Axis?
    private var preLockAccumX = 0.0
    private var preLockAccumY = 0.0

    /// Cumulative unsigned travel (points) considered before giving up on
    /// axis lock for this gesture. Wide enough that a tight circular pan
    /// (small-radius freeform drag in a graphics app) reveals its curve
    /// before a lock commits — too short a window catches only a small arc,
    /// which looks locally straight and locks prematurely.
    static let axisLockWindow = 26.0

    /// Dominant-axis-to-other-axis ratio required to commit to a lock
    /// (~2:1 ≈ within 25° of true vertical/horizontal — matches the informal
    /// "direction lock" behavior of trackpad drivers).
    static let axisLockRatio = 2.0

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
        axisLock = nil
        preLockAccumX = 0
        preLockAccumY = 0
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

        var dx = (screen.x - prev.x) * sign * speed
        var dy = (screen.y - prev.y) * sign * speed

        if let axisLock {
            switch axisLock {
            case .vertical: dx = 0
            case .horizontal: dy = 0
            }
        } else {
            preLockAccumX += abs(dx)
            preLockAccumY += abs(dy)
            let total = preLockAccumX + preLockAccumY
            if total >= Self.axisLockWindow {
                let ratio = Self.axisLockRatio
                if preLockAccumX >= preLockAccumY * ratio {
                    axisLock = .horizontal
                    dy = 0
                } else if preLockAccumY >= preLockAccumX * ratio {
                    axisLock = .vertical
                    dx = 0
                }
                // Neither axis dominates enough (a genuinely diagonal drag):
                // give up on locking for the rest of this gesture and stay
                // omnidirectional, the way a native Hand tool would.
            }
        }

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
