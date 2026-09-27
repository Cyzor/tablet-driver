// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import TabletKit

/// `kCGMomentumScrollPhase` values (distinct from and mutually exclusive with
/// the `kCGScrollPhase` lifecycle that brackets a live gesture).
enum MomentumPhase: Int64 {
    case none = 0
    case begin = 1
    case `continue` = 2
    case end = 3
}

/// Synthetic momentum decay tail for a CGEvent-posted scroll stream.
///
/// A real trackpad's coast comes from a system-synthesized
/// `kCGMomentumScrollPhase` stream generated after finger-lift; `CGEventPost`
/// has no hardware behind it and never gets that for free, so the coast is
/// synthesized here from a release-velocity estimate.
///
/// Both Scroll Drag (Pan View) and two-finger touch scroll need this, with the
/// hard requirement that their tails can never cancel or blend into each other.
/// That's guaranteed structurally: each owner holds its *own instance*, so
/// there is no shared timer or velocity state to collide over.
///
/// HIDThread-confined, like everything else in the injection path — the timer
/// is scheduled on `HIDThread.shared.runLoop` and every mutation happens in its
/// handler or in a call already on that thread.
final class MomentumTail {

    /// Posts one momentum event. Supplied by the owner so this type stays a
    /// pure decay driver with no knowledge of event construction. Must capture
    /// its owner **weakly** — the owner holds this instance, so a strong
    /// capture here is a retain cycle.
    private let post: (_ dx: Double, _ dy: Double, _ phase: MomentumPhase) -> Void

    private var timer: CFRunLoopTimer?
    private var velocity: CGVector = .zero
    /// Fractional-pixel carry: scroll events are integer pixels, and a decaying
    /// tail spends its final frames moving well under 1 px per tick.
    private var accumX = 0.0
    private var accumY = 0.0
    /// Real time of the last tick, measured rather than assumed — a one-shot
    /// self-rescheduling timer never lands exactly `tickInterval` apart under
    /// runloop load, so the decay math measures actual elapsed time each tick
    /// instead of silently assuming a fixed cadence.
    private var lastTickTime: CFAbsoluteTime = 0

    // MARK: - Tunables

    /// Tick cadence — matches a real trackpad's momentum-stream rate. This is
    /// the *scheduling* interval, not what the decay math assumes elapsed.
    static let tickInterval: TimeInterval = 1.0 / 60.0

    /// Constant deceleration (points/second²) applied to the momentum
    /// velocity every tick, replacing an earlier exponential-decay model
    /// (`momentumDecayPer10ms`, sourced from a Wacom native-driver trace —
    /// wrong target: the user's comparison has always been a real Apple
    /// trackpad, not Wacom's own touch feel, and Wacom's captured rate
    /// produced a slow, grinding coast that never sat right). Exponential
    /// decay also structurally cannot match a real trackpad's flick
    /// signature — a decisive flick coasts hard and briefly (a real
    /// trackpad: roughly a quarter second) while still covering a large
    /// distance, then stops cleanly, rather than asymptotically crawling to
    /// a near-stop and lingering there. Constant deceleration reaches
    /// exactly zero in bounded time and its distance scales with the square
    /// of release speed, so a decisive flick travels disproportionately
    /// farther than a gentle one — matching both complaints in one change.
    /// This value is a starting point derived from a rough target (a firm
    /// flick decaying to a stop in ~0.25s while covering several thousand
    /// points), not a hardware measurement — expect it to need retuning
    /// once real release-velocity numbers are observed on hardware.
    static let deceleration: CGFloat = 6000.0

    /// Velocity magnitude (points/second) below which a tail never starts —
    /// a slow, deliberate release isn't a flick on a real trackpad either,
    /// and doesn't get a momentum phase there. Constant deceleration reaches
    /// exactly zero on its own, so this is only a start gate, not a stop
    /// condition (see `tick()`).
    static let stopVelocity: CGFloat = 8.0

    init(post: @escaping (_ dx: Double, _ dy: Double, _ phase: MomentumPhase) -> Void) {
        self.post = post
    }

    var isRunning: Bool { timer != nil }

    /// Starts (or restarts) the decay tail. A release slower than
    /// `stopVelocity` starts nothing.
    func start(velocity: CGVector) {
        cancel()
        guard hypot(velocity.dx, velocity.dy) >= Self.stopVelocity else { return }
        self.velocity = velocity
        accumX = 0
        accumY = 0
        lastTickTime = CFAbsoluteTimeGetCurrent()
        post(0, 0, .begin)
        scheduleTick()
    }

    /// Cancels any in-flight tail *without* posting a `.end` event — used when
    /// a new gesture engages before the previous tail decayed out. The wheel
    /// event that immediately follows carries a fresh scroll phase, which by
    /// itself cancels a prior momentum animation.
    func cancel() {
        timer.map { CFRunLoopTimerInvalidate($0) }
        timer = nil
    }

    /// Like `cancel()`, but also posts an explicit momentum-end event.
    ///
    /// Needed when the gesture is arrested but *no* scroll delta will follow —
    /// a stationary two-finger grab on a coasting view, rather than a new
    /// gesture. `NSScrollView`-based apps that received the begin/continue
    /// stream are running their own independent coast animation by this point;
    /// simply stopping our timer never tells them to stop theirs. A real
    /// trackpad senses the touch-down and halts the animation directly — this
    /// is the nearest equivalent that can be posted.
    func stop() {
        guard timer != nil else { return }
        cancel()
        post(0, 0, .end)
    }

    private func scheduleTick() {
        let t = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + Self.tickInterval,
            0, 0, 0
        ) { [weak self] _ in
            self?.tick()
        }
        CFRunLoopAddTimer(HIDThread.shared.runLoop, t, .commonModes)
        timer = t
    }

    private func tick() {
        timer = nil
        let now = CFAbsoluteTimeGetCurrent()
        let dt = now - lastTickTime
        lastTickTime = now

        let speed = hypot(velocity.dx, velocity.dy)
        guard speed > 0 else {
            post(0, 0, .end)
            return
        }
        // Trapezoidal integration: distance uses the average of the speed at
        // both ends of the tick, so the travel doesn't depend on tick cadence.
        let newSpeed = max(0, speed - Self.deceleration * CGFloat(dt))
        let avgSpeed = (speed + newSpeed) / 2
        let dx = velocity.dx / speed * avgSpeed * dt
        let dy = velocity.dy / speed * avgSpeed * dt
        velocity = newSpeed > 0
            ? CGVector(dx: velocity.dx / speed * newSpeed, dy: velocity.dy / speed * newSpeed)
            : .zero

        accumX += dx
        accumY += dy
        let ix = Int(accumX.rounded(.towardZero))
        let iy = Int(accumY.rounded(.towardZero))
        accumX -= Double(ix)
        accumY -= Double(iy)

        if newSpeed <= 0 {
            post(Double(ix), Double(iy), .end)
            return
        }
        if ix != 0 || iy != 0 {
            post(Double(ix), Double(iy), .continue)
        }
        scheduleTick()
    }
}

/// Direct-drive smoothing for ring, strip, and dial scrolling: every notch
/// moves the page exactly its own distance, spread over a few frames to hide
/// the step, with no stored velocity. A reversal drops whatever is still
/// pending, so the page turns on a dime instead of coasting through zero as
/// an inertial coaster would.
final class RingScrollGlide {

    /// Posts one scroll increment, in points. Must capture its owner weakly.
    private let post: (_ dy: Double) -> Void

    private var timer: CFRunLoopTimer?
    /// Signed points not yet posted.
    private var pending = 0.0
    private var lastTickTime: CFAbsoluteTime = 0

    static let tickInterval: TimeInterval = 1.0 / 120.0

    /// Points per line: 3 lines per notch at ~10 px/line, the distance the
    /// discrete `.line` path always produced.
    static let pointsPerLine = 30.0

    /// Exponential catch-up time constant for fast input. About 95% of a
    /// notch lands within three of these, short enough to feel attached.
    static let timeConstant: TimeInterval = 0.025

    /// Slow input stretches the glide to fill the gap between clicks, so a
    /// slow turn reads as continuous motion instead of step-pause-step. The
    /// time constant tracks this fraction of the last click interval, capped
    /// at `maxTimeConstant` so a long pause doesn't turn into a slow drift.
    static let intervalFraction = 0.35
    static let maxTimeConstant: TimeInterval = 0.07
    private var currentTimeConstant = RingScrollGlide.timeConstant

    /// Mechanical encoders emit stray wrong-direction clicks mid-spin (the
    /// Xencelabs dial about once per revolution). When set, a lone reversed
    /// click arriving within `reversalWindow` of the last one is held until a
    /// second reversed click confirms it; a forward click discards it, and
    /// silence applies it, so a deliberate single nudge back still lands.
    private let confirmReversals: Bool
    private var lastDirection = 0.0
    private var lastClickTime: CFAbsoluteTime = 0
    private var held: [Double] = []
    /// Consecutive same-direction clicks, each within `reversalWindow`.
    private var runLength = 0
    /// A run this long is an established spin, which needs one more reversed
    /// click to confirm a reversal (the Xencelabs stray can arrive in pairs).
    static let establishedRun = 4
    private var heldTimer: CFRunLoopTimer?

    static let reversalWindow: TimeInterval = 0.08

    init(confirmReversals: Bool = false, post: @escaping (_ dy: Double) -> Void) {
        self.confirmReversals = confirmReversals
        self.post = post
    }

    func impulse(lines: Double) {
        let points = lines * Self.pointsPerLine
        guard points != 0 else { return }
        let direction: Double = points < 0 ? -1 : 1
        let now = CFAbsoluteTimeGetCurrent()
        if confirmReversals, lastDirection != 0, direction != lastDirection,
           now - lastClickTime < Self.reversalWindow {
            held.append(points)
            let needed = runLength >= Self.establishedRun ? 3 : 2
            if held.count >= needed {
                let confirmed = held
                clearHeld()
                runLength = 0
                confirmed.forEach(apply)
            } else if held.count == 1 {
                armHeldTimer()
            }
            return
        }
        clearHeld()  // a forward click marks a held reversal as a stray
        apply(points)
    }

    func cancel() {
        timer.map { CFRunLoopTimerInvalidate($0) }
        timer = nil
        pending = 0
        clearHeld()
        lastDirection = 0
        runLength = 0
    }

    private func apply(_ points: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        let direction: Double = points < 0 ? -1 : 1
        let interval = now - lastClickTime
        if direction == lastDirection, interval < Self.reversalWindow {
            runLength += 1
        } else {
            runLength = 1
        }
        currentTimeConstant = direction == lastDirection
            ? min(Self.maxTimeConstant, max(Self.timeConstant, interval * Self.intervalFraction))
            : Self.timeConstant
        // Opposite direction: discard the unposted remainder so the reversal
        // is immediate rather than first playing out the old direction.
        if pending != 0, (pending < 0) != (points < 0) { pending = 0 }
        pending += points
        lastDirection = direction
        lastClickTime = now
        guard timer == nil else { return }
        lastTickTime = lastClickTime
        tick()
    }

    private func armHeldTimer() {
        let t = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + Self.reversalWindow,
            0, 0, 0
        ) { [weak self] _ in
            guard let self, !self.held.isEmpty else { return }
            let pending = self.held
            self.heldTimer = nil
            self.held = []
            pending.forEach(self.apply)
        }
        CFRunLoopAddTimer(HIDThread.shared.runLoop, t, .commonModes)
        heldTimer = t
    }

    private func clearHeld() {
        heldTimer.map { CFRunLoopTimerInvalidate($0) }
        heldTimer = nil
        held = []
    }

    private func scheduleTick() {
        let t = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + Self.tickInterval,
            0, 0, 0
        ) { [weak self] _ in
            self?.tick()
        }
        CFRunLoopAddTimer(HIDThread.shared.runLoop, t, .commonModes)
        timer = t
    }

    private func tick() {
        timer = nil
        let now = CFAbsoluteTimeGetCurrent()
        // First tick of a burst posts one interval's worth rather than zero.
        let dt = max(now - lastTickTime, Self.tickInterval)
        lastTickTime = now
        var step = pending * (1 - exp(-dt / currentTimeConstant))
        if abs(pending) < 1 { step = pending }
        let whole = step.rounded(.awayFromZero)
        let posted = abs(whole) > abs(pending) ? pending.rounded() : whole
        pending -= posted
        if posted != 0 { post(posted) }
        if abs(pending) < 0.5 { pending = 0; return }
        scheduleTick()
    }
}
