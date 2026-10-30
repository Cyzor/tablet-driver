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
/// Like `TouchStateTracker`, it has no I/O, clocks, or globals, so tests can
/// drive it; `InputInjector.postPanScroll` builds the events.
///
/// The stream follows the tool's Momentum setting (`panScrollUsePhases`). On:
/// a began/changed/ended phase envelope and, on release, a coast
/// (`panMomentumTail`) seeded from the velocity tracked here. Off: phase-free
/// events and no coast, because some apps (Calendar's Month and Year views,
/// WebKit, Adobe palettes) reject the phased stream.
///
/// Owned by `InputInjector`; HIDThread-confined like its sibling trackers.
struct PanScrollTracker {

    enum ScrollPhase: Int {
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8
        case mayBegin = 128
    }

    enum Intent: Equatable {
        case none
        case scroll(dx: Double, dy: Double, phase: ScrollPhase)
    }

    // MARK: - State

    private(set) var isActive = false

    /// Whether this gesture's `.began` has gone out (see `engage`).
    private var hasBegun = false

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

    /// Recent per-frame velocities (points/second), timed on `clock`. The
    /// momentum seed is the fastest one in a short window, which catches the
    /// peak of even a brief flick; an average would lag behind it.
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

    /// Speed-adaptive (1€) damping of the anchor point, so slow pans don't
    /// shiver: panning magnifies tremor, since the whole canvas moves. It
    /// damps near a standstill and is transparent once the pan is brisk, so
    /// it's always on, independent of the pen's Stabilization setting.
    private var smoother = PanSmoother()

    /// Fixed damping strength (0–1). Deliberately light: enough to settle
    /// tremor during slow positioning, not enough to feel like lag if a user
    /// pans slowly *on purpose*.
    static let smoothingStrength = 0.3

    /// Where this gesture's motion started, for `.began` and the axis decision.
    private var origin: CGPoint?

    /// Net travel (screen points) from `origin` before `.began` goes out, so
    /// a tip-down jolt that settles back can't pick the scroll view.
    static let beganTravel = 4.0

    /// Directional lock, as UIScrollView's: a straight start locks to its
    /// axis and a diagonal one stays free, so drift can't read as a swipe in
    /// Firefox. Unlike UIKit, a deliberate turn frees it, for canvas apps.
    private enum Axis { case vertical, horizontal }
    private var axisLock: Axis?
    private var axisDecided = false
    /// Start of the stretch of travel checked for a turn while locked.
    private var stretchStart: CGPoint?

    /// AppKit gives the whole gesture to the nested scroll view matching the
    /// `.began` delta's dominant axis, horizontal only when |dx| > |dy|. A pan
    /// that then settles along the other axis, as a vertical start turning
    /// sideways in Finder's column view, would scroll nothing, so the gesture
    /// ends and begins again, as a trackpad user lifts and touches down.
    private var latchedAxis: Axis?
    /// Start of the stretch checked for settling along the other axis.
    private var latchStretchStart: CGPoint?
    /// The `.mayBegin` from `engage` awaits its `.began`; a restarted gesture
    /// has none.
    private var mayBeginOpen = false

    /// Net travel (screen points) from `origin` that decides the lock.
    static let axisLockTravel = 10.0
    /// Along-to-across ratio that locks (2:1, within about 25 degrees).
    static let axisLockRatio = 2.0
    /// Length (screen points) of each stretch checked for a turn; long enough
    /// that a stroke's end curl isn't one.
    static let axisTurnStretch = 24.0
    /// Across-to-along ratio over one stretch that frees the lock (past 45 degrees).
    static let axisTurnRatio = 1.0

    /// Release velocity in points/second, the momentum seed.
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
    /// Longest `disengage(backdate:)` offset the sample history must still be
    /// able to answer for. Sized to cover the longest button up-debounce
    /// (`InputInjector.buttonUpDebounceMenuInterval`, 0.25 s) with margin —
    /// samples are pruned to `peakVelocityWindow + this`, so a backdated
    /// release can still see the window that was current at the physical
    /// release. Costs a handful of extra tuples on a tiny array.
    static let maxBackdate: Double = 0.30

    // MARK: - Edges

    /// Begin the gesture with `.mayBegin`, as a trackpad touch does, so AppKit
    /// drops its latch on the last view scrolled. `.began` waits for
    /// `beganTravel` and carries it: a zero-delta `.began` reads as vertical
    /// and strands horizontal pans (Finder column view). `reverse` selects
    /// classic (wheel) rather than natural direction. `speed` multiplies
    /// deltas (0.25 slow – 3.0 fast, 1.0 = 1:1).
    mutating func engage(reverse: Bool, speed: Double = 1.0) -> Intent {
        isActive = true
        hasBegun = false
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
        origin = nil
        axisLock = nil
        axisDecided = false
        stretchStart = nil
        latchedAxis = nil
        latchStretchStart = nil
        mayBeginOpen = true
        return .scroll(dx: 0, dy: 0, phase: .mayBegin)
    }

    /// End the gesture (real button release, or a confirmed proximity exit).
    /// Idempotent — a second call after an inactive period emits nothing.
    ///
    /// `backdate` is how long ago the *physical* release happened, for callers
    /// whose release edge is deferred — currently only the Xencelabs
    /// barrel-button up-debounce (`InputInjector.handleXencelabsBarrelButton`),
    /// which holds the release for `buttonUpDebounceInterval` (0.05 s) to
    /// bridge contact chatter. Wacom fires its release immediately and always
    /// passes 0. Backdating keeps flick detection independent of the debounce
    /// length, so a longer window can't start suppressing flicks.
    mutating func disengage(backdate: Double = 0) -> Intent {
        guard isActive else { return .none }
        let offset = max(0, backdate)
        if offset > Self.maxBackdate {
            // Out of contract — the sample history isn't retained this far
            // back, so no reliable answer exists. Suppress rather than clamp
            // into a permissive window: clamping would look back a fixed
            // `maxBackdate` and could resurrect a long-dead flick. A missing
            // coast is a much milder failure than a spurious one.
            releaseVelocity = .zero
        } else {
            let cutoff = clock - offset
            let peak = recentVelocities
                .filter { $0.time <= cutoff && cutoff - $0.time <= Self.peakVelocityWindow }
                .max { hypot($0.v.dx, $0.v.dy) < hypot($1.v.dx, $1.v.dy) }?.v ?? .zero
            // May go negative when motion continued into the deferral window —
            // that's a flick, and compares correctly against the threshold.
            releaseVelocity =
                timeSinceMotion - offset <= Self.momentumRecencyWindow ? peak : .zero
            // Coast along the locked axis only, as the scroll did.
            switch axisLock {
            case .vertical: releaseVelocity.dx = 0
            case .horizontal: releaseVelocity.dy = 0
            case nil: break
            }
        }
        isActive = false
        last = nil
        lastRaw = nil
        // No `.began` went out: cancel the `.mayBegin`, if one is open, with
        // nothing to coast.
        guard hasBegun else {
            releaseVelocity = .zero
            return mayBeginOpen ? .scroll(dx: 0, dy: 0, phase: .cancelled) : .none
        }
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
            // Resuming re-anchors, so travel while away never counts.
            if !axisDecided { origin = point }
            stretchStart = point
            return .none
        }
        last = point
        lastRaw = screen

        if hasBegun, let latched = latchedAxis, let start = latchStretchStart {
            let sx = abs(point.x - start.x)
            let sy = abs(point.y - start.y)
            if hypot(sx, sy) >= Self.axisTurnStretch {
                latchStretchStart = point
                let settled: Axis? = sx >= sy * Self.axisLockRatio ? .horizontal
                    : sy >= sx * Self.axisLockRatio ? .vertical : nil
                if let settled, settled != latched {
                    // Start over from here: a new `.began` once there's
                    // travel to carry, and a fresh axis decision.
                    hasBegun = false
                    latchedAxis = nil
                    origin = point
                    axisLock = nil
                    axisDecided = false
                    stretchStart = point
                    return .scroll(dx: 0, dy: 0, phase: .ended)
                }
            }
        }

        var dx = (point.x - prev.x) * sign * speed
        var dy = (point.y - prev.y) * sign * speed
        // Momentum seed comes from the *raw* travel, not the damped anchor,
        // so adding smoothing can't quietly shorten the coast after a flick.
        let rawDx = (screen.x - rawPrev.x) * sign * speed
        let rawDy = (screen.y - rawPrev.y) * sign * speed

        if !axisDecided, let origin {
            let nx = abs(point.x - origin.x)
            let ny = abs(point.y - origin.y)
            if hypot(nx, ny) >= Self.axisLockTravel {
                axisDecided = true
                if nx >= ny * Self.axisLockRatio {
                    axisLock = .horizontal
                } else if ny >= nx * Self.axisLockRatio {
                    axisLock = .vertical
                }
                stretchStart = point
            }
        }
        if let lock = axisLock, let start = stretchStart {
            let sx = abs(point.x - start.x)
            let sy = abs(point.y - start.y)
            if hypot(sx, sy) >= Self.axisTurnStretch {
                let (along, across) = lock == .horizontal ? (sx, sy) : (sy, sx)
                if across > along * Self.axisTurnRatio { axisLock = nil }
                stretchStart = point
            }
            switch axisLock {
            case .vertical: dx = 0
            case .horizontal: dy = 0
            case nil: break
            }
        }

        if dt > 0 {
            clock += dt
            recentVelocities.append((time: clock, v: CGVector(dx: rawDx / dt, dy: rawDy / dt)))
            // Retain `maxBackdate` beyond the peak window so a deferred release
            // can still be judged as of its physical edge — see disengage().
            recentVelocities.removeAll {
                clock - $0.time > Self.peakVelocityWindow + Self.maxBackdate
            }
        }
        if abs(rawDx) > 0.01 || abs(rawDy) > 0.01 {
            timeSinceMotion = 0
        } else if dt > 0 {
            timeSinceMotion += dt
        }

        accumX += dx
        accumY += dy
        if !hasBegun, let origin,
            hypot(point.x - origin.x, point.y - origin.y) < Self.beganTravel
        {
            return .none
        }
        let ix = Int(accumX.rounded(.towardZero))
        let iy = Int(accumY.rounded(.towardZero))
        guard ix != 0 || iy != 0 else { return .none }
        accumX -= Double(ix)
        accumY -= Double(iy)
        let phase: ScrollPhase = hasBegun ? .changed : .began
        if !hasBegun {
            latchedAxis = abs(ix) > abs(iy) ? .horizontal : .vertical
            latchStretchStart = point
            mayBeginOpen = false
        }
        hasBegun = true
        return .scroll(dx: Double(ix), dy: Double(iy), phase: phase)
    }
}
