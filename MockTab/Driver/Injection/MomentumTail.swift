// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

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

/// Inertial scroll model for a *discrete click* encoder — currently only the
/// Xencelabs Quick Keys dial.
///
/// Deliberately not a `MomentumTail`: that type coasts *after* a gesture ends,
/// seeded once from a measured release velocity. The dial's problem is the
/// opposite shape. Its encoder emits occasional runs of 2-3 wrong-direction
/// clicks in the middle of a fast one-way spin — present in the native
/// Xencelabs driver too, so it is the hardware's own signal, not a decode bug.
/// While clicks post scroll events one-for-one, such a run is a 150-360 ms hole
/// in forward motion, which is the lurch the user perceives. Suppressing the
/// wrong-signed clicks was tried on hardware and changed nothing, precisely
/// because the complaint is the missing forward motion, not the small backward
/// motion.
///
/// So here the ticker is the *sole* emitter and clicks never post anything
/// themselves: each click only adds a signed impulse to a velocity that
/// constant friction is always bleeding off. Output is therefore continuous
/// regardless of click timing, and a wrong-direction run subtracts a fraction
/// of an established spin's velocity instead of interrupting it — the arcade
/// trackball behaviour that was asked for, where a bearing's minor friction is
/// irrelevant once the ball is moving. A *sustained* reversal still pulls
/// velocity through zero within a few clicks, and after any pause friction has
/// already parked it at zero, so a deliberate flick the other way stays
/// responsive.
///
/// HIDThread-confined on the same terms as `MomentumTail`.
final class DialScrollCoaster {

    /// Posts one scroll increment, in points. Must capture its owner weakly.
    private let post: (_ dy: Double) -> Void

    private var timer: CFRunLoopTimer?
    /// Signed, points/second. Positive follows the same convention as the
    /// caller's `lines` — the natural-scrolling flip is applied upstream.
    private var velocity = 0.0
    /// Fractional-point carry; scroll events are whole points and a decaying
    /// tail spends its last frames well under 1 pt/tick.
    private var accum = 0.0
    private var lastTickTime: CFAbsoluteTime = 0
    /// True between the first impulse from rest and the end of `launchWindow`.
    private var launching = false

    // MARK: - Tunables
    //
    // Starting points chosen to preserve the current per-click feel at slow,
    // deliberate turns while letting a fast spin build real inertia. Expect
    // these to need a hardware tuning pass.

    static let tickInterval: TimeInterval = 1.0 / 60.0

    /// Velocity (points/second) added per line of dial travel. Under constant
    /// friction a lone click travels `kick² / (2 · friction)`, so this value
    /// sets the granularity of a slow click-by-click turn: ≈ 12 pt, about one
    /// line, at the default 1x speed. An earlier 440 gave ≈ 48 pt and read as
    /// coarse on hardware — too big a jump for a dial that looks analog.
    static let kick = 220.0

    /// How long a spin starting from rest accumulates impulses before the
    /// ticker emits anything.
    ///
    /// The encoder's wrong-direction runs are worst at the very start of a
    /// spin, where there is no established velocity for them to merely dent —
    /// a lone stray click at rest gets the full launch impulse to itself and
    /// reads as a visible flinch backwards before the spin takes off. Summing
    /// impulses across this window first lets a stray click cancel against the
    /// real ones around it before any of it becomes motion. Short enough not
    /// to read as lag on a deliberate single-click nudge, which still lands —
    /// this defers motion, it never suppresses it.
    static let launchWindow: TimeInterval = 0.08

    /// Constant deceleration (points/second²). Low enough that a 300 ms hole
    /// in forward clicks costs only part of an established spin's velocity
    /// rather than stopping it.
    static let friction = 2000.0

    /// Ceiling on accumulated velocity. Without one, a spin whose clicks
    /// arrive faster than friction can bleed them off grows without bound.
    static let maxVelocity = 4000.0

    init(post: @escaping (_ dy: Double) -> Void) {
        self.post = post
    }

    /// Feeds one dial click in, as signed lines of travel (already scaled by
    /// the user's speed setting). Never posts directly — it only changes the
    /// velocity the ticker is emitting from.
    func impulse(lines: Double) {
        // Opposing clicks are free to carry velocity straight through zero and
        // out the other side. A variant that braked to a standstill first —
        // one click to cancel the spin, a second to reverse it — was tried on
        // hardware and rejected: it removed a slight backwards overshoot when
        // counter-twisting to a stop, but cost noticeably more than that in
        // responsiveness under rapid CW-CCW-CW twisting, which is the motion
        // people actually make. The overshoot is the better trade.
        velocity = min(Self.maxVelocity, max(-Self.maxVelocity, velocity + lines * Self.kick))
        guard timer == nil else { return }
        accum = 0
        launching = true
        lastTickTime = CFAbsoluteTimeGetCurrent()
        scheduleTick(after: Self.launchWindow)
    }

    func cancel() {
        timer.map { CFRunLoopTimerInvalidate($0) }
        timer = nil
        velocity = 0
        accum = 0
        launching = false
    }

    private func scheduleTick(after interval: TimeInterval = DialScrollCoaster.tickInterval) {
        let t = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + interval,
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
        // The launch window accumulates impulses only — it contributes no
        // travel, so the deferral shows up as a brief delay before motion
        // starts rather than as a jump covering the whole window at once.
        if launching {
            launching = false
            lastTickTime = now
            guard velocity != 0 else { accum = 0; return }
            scheduleTick()
            return
        }
        let dt = now - lastTickTime
        lastTickTime = now

        let speed = abs(velocity)
        guard speed > 0 else { accum = 0; return }
        let direction = velocity < 0 ? -1.0 : 1.0
        // Trapezoidal integration, as in MomentumTail: travel uses the average
        // of the speed at both ends of the tick so it doesn't depend on cadence.
        let newSpeed = max(0, speed - Self.friction * dt)
        accum += direction * (speed + newSpeed) / 2 * dt
        velocity = direction * newSpeed

        let whole = accum.rounded(.towardZero)
        accum -= whole
        if whole != 0 { post(whole) }

        guard newSpeed > 0 else { accum = 0; return }
        scheduleTick()
    }
}
