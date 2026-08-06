// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import TabletKit

/// State machine for the "Scroll Drag" button binding: while the bound button
/// is held, pen motion is converted into trackpad-style scroll intents
/// (began/changed/ended) instead of cursor motion.
///
/// Deliberately mirrors `TouchStateTracker`'s shape: no I/O, no clocks, no
/// globals — everything arrives via `process(...)`/edge calls so tests can
/// drive it, and the only event-construction site (`InputInjector.postPanScroll`)
/// stays a single replaceable backend.
///
/// Momentum is *not* synthesized, and the stream carries no scroll-phase
/// envelope. The posting backend (`InputInjector.postPanScroll`) tags every
/// event continuous with `scrollWheelEventScrollPhase = 0` and no
/// began/changed/ended lifecycle. That phase-free shape is deliberate: a real
/// trackpad pairs its phased deltas with a companion gesture-event stream that
/// the public CGEvent API cannot forge, and recognizers that key on the phase
/// lifecycle (Calendar Month/Year, WebKit gesture-scroll / overscroll-behavior,
/// Adobe palettes) reject a phased stream that lacks that gesture backing.
/// Captured third-party scroll tools that pan those apps smoothly (Smooze)
/// emit exactly this phase-free continuous shape.
///
/// A short-window release velocity is still maintained here regardless (it is
/// the entire input a momentum tail needs, real or synthetic), for the day a
/// virtual HID trackpad (the parked IOHIDUserDevice spike) lets this tracker's
/// intents become "report contact began/moved/ended" with true system-level
/// gesture + inertia in *every* app. v1 records the velocity and discards it.
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

    /// Unsmoothed counterpart of `last`, kept only to seed the release
    /// velocity from true pen travel.
    private var lastRaw: CGPoint?

    /// Fractional-pixel carry. Scroll events are Int32 pixels; a slow pan
    /// moves < 1 px/frame at 133 Hz and would stall without accumulating the
    /// remainder (same pattern as the ring/strip accumulators).
    private var accumX = 0.0
    private var accumY = 0.0

    /// Recent per-frame instantaneous velocities (points/second) with a
    /// timestamp on `clock` — the momentum-tail seed. An EMA was tried first
    /// and rejected: it takes several frames to converge, and a real flick
    /// is often over before that happens, so the EMA reports well under the
    /// pen's actual peak speed. Using the fastest sample within a short
    /// recent window instead captures the peak even from a very brief flick.
    private var recentVelocities: [(time: Double, v: CGVector)] = []
    /// Free-running elapsed-time clock, advanced by each call's `dt` — this
    /// tracker only ever receives relative frame deltas, never wall-clock
    /// time, so the peak-velocity window needs its own local timeline.
    private var clock: Double = 0

    /// Sign applied to deltas: natural scrolling (content follows pen) is the
    /// default; reversed matches classic scroll-wheel semantics. Captured at
    /// engage from the snapshot so a mid-gesture settings change doesn't
    /// flip direction under the user's hand.
    private var sign = 1.0

    /// Delta multiplier captured at engage (from `ToolSettings.panScrollSpeed`).
    private var speed = 1.0

    /// Speed-adaptive damping of the anchor point, so slow deliberate pans
    /// don't shiver. Panning magnifies hand tremor in a way cursor motion
    /// does not — the whole canvas moves — so this is always on at a fixed
    /// light setting rather than being exposed as a control. It is
    /// independent of the pen's Stabilization setting: the point arriving
    /// here has already been through that filter, or not, if it's off.
    ///
    /// The filter is speed-adaptive (1€), which is what keeps it invisible:
    /// it damps hard near a standstill and is effectively transparent by the
    /// time the pan is brisk, so gross motion still lands exactly where the
    /// pen puts it.
    private var smoother = PanSmoother()

    /// Fixed damping strength (0–1). Deliberately light: enough to settle
    /// tremor during slow positioning, not enough to feel like lag if a user
    /// pans slowly *on purpose*.
    static let smoothingStrength = 0.3

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

    /// Seconds of `process()` calls since the last frame with non-negligible
    /// raw motion. A real trackpad detects a deliberate brake — holding
    /// still before releasing — and starts no momentum even if a fast sample
    /// is still sitting in `recentVelocities` from just before the brake.
    /// `disengage()` gates release on this instead of trusting the
    /// peak-velocity window alone.
    private var timeSinceMotion: Double = 0

    // MARK: - Tunables

    /// How far back to look for the fastest recent sample when seeding
    /// momentum release velocity.
    static let peakVelocityWindow: Double = 0.06
    /// A release is only treated as a flick if motion happened within this
    /// many seconds of it.
    static let momentumRecencyWindow: Double = 0.05

    // MARK: - Edges

    /// Begin the gesture. Emits `.began` with zero delta; the first real
    /// motion arrives as `.changed` on the next frame. `reverse` selects
    /// classic (wheel) rather than natural (content-follows) direction.
    /// `speed` multiplies deltas (0.25 slow – 3.0 fast, 1.0 = 1:1).
    mutating func engage(reverse: Bool, speed: Double = 1.0) -> Intent {
        isActive = true
        sign = reverse ? -1.0 : 1.0
        self.speed = max(0.05, speed)
        smoother.strength = Self.smoothingStrength
        smoother.reset()
        last = nil
        accumX = 0
        accumY = 0
        recentVelocities.removeAll()
        clock = 0
        releaseVelocity = .zero
        timeSinceMotion = 0
        lastRaw = nil
        axisLock = nil
        preLockAccumX = 0
        preLockAccumY = 0
        return .scroll(dx: 0, dy: 0, phase: .began)
    }

    /// End the gesture (real button release, or a confirmed proximity exit).
    /// Idempotent — a second call after an inactive period emits nothing.
    mutating func disengage() -> Intent {
        guard isActive else { return .none }
        let peak = recentVelocities
            .filter { clock - $0.time <= Self.peakVelocityWindow }
            .max { hypot($0.v.dx, $0.v.dy) < hypot($1.v.dx, $1.v.dy) }?.v ?? .zero
        releaseVelocity = timeSinceMotion <= Self.momentumRecencyWindow ? peak : .zero
        isActive = false
        last = nil
        lastRaw = nil
        return .scroll(dx: 0, dy: 0, phase: .ended)
    }

    /// The pen left range (or was suspended by a debounced exit) while the
    /// gesture is held: forget the anchor so resumption doesn't jump, but
    /// keep the gesture logically open — Xencelabs debounced out-of-range
    /// blips must not close a pan the user is still holding.
    mutating func suspend() {
        last = nil
        lastRaw = nil
        smoother.reset()
    }

    // MARK: - Per-frame

    /// One in-proximity frame while active. `screen` is the mapped,
    /// smoothing-filtered absolute screen point; `dt` is seconds since the
    /// previous frame (for the velocity estimate only — deltas themselves are
    /// displacement, not rate).
    mutating func process(screen: CGPoint, dt: Double) -> Intent {
        guard isActive else { return .none }
        // Damp the anchor before anything reads it. Positional, so a long
        // slow pan still travels the full distance — the filter only lags,
        // it never drops displacement.
        let point = smoother.process(raw: screen, dt: dt)
        guard let prev = last, let rawPrev = lastRaw else {
            // First frame after engage/suspend: anchor only, no delta.
            last = point
            lastRaw = screen
            return .none
        }
        last = point
        lastRaw = screen

        var dx = (point.x - prev.x) * sign * speed
        var dy = (point.y - prev.y) * sign * speed
        // Momentum seed comes from the *raw* travel, not the damped anchor,
        // so adding smoothing can't quietly shorten the coast after a flick.
        let rawDx = (screen.x - rawPrev.x) * sign * speed
        let rawDy = (screen.y - rawPrev.y) * sign * speed

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

        if dt > 0 {
            clock += dt
            recentVelocities.append((time: clock, v: CGVector(dx: rawDx / dt, dy: rawDy / dt)))
            recentVelocities.removeAll { clock - $0.time > Self.peakVelocityWindow }
        }
        if abs(rawDx) > 0.01 || abs(rawDy) > 0.01 {
            timeSinceMotion = 0
        } else if dt > 0 {
            timeSinceMotion += dt
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
