// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import TabletKit

/// Rejects palm-sized capacitive contacts before they reach gesture tracking.
///
/// The PTH-660 and PTH-860 report contact major and minor axes for every
/// touch slot. The units differ per device, so the filter covers only that
/// calibrated family instead of applying a global threshold. A rejected slot
/// stays rejected until it lifts: a palm shrinks through finger sizes as it
/// peels away, and letting it back in clicked wherever the palm left.
struct TouchPalmRejector {

    struct Result {
        let acceptedIDs: Set<Int>
        let newlyRejectedIDs: [Int]
        let newlyAcceptedIDs: [Int]
    }

    /// PTH-660 and PTH-860 USB and Bluetooth Classic PIDs. Injection sees the
    /// canonical USB PID; the Bluetooth ones keep isolated tests correct.
    private static let calibratedProductIDs: Set<Int> = [0x0357, 0x0360, 0x0358, 0x0361]

    /// A palm starts at raw width/height 6/7; finger-sized fragments beside it
    /// stay at 1–4. The descriptor's logical maxima aren't millimeters, so the
    /// threshold comes from observed raw axes.
    private static let rejectAxisAtOrAbove = 5

    private var rejectedIDs: Set<Int> = []

    static func supports(productID: Int) -> Bool {
        calibratedProductIDs.contains(productID)
    }

    private static func isPalm(major: Int?, minor: Int?) -> Bool {
        [major, minor].compactMap { $0 }.contains { $0 >= rejectAxisAtOrAbove }
    }


    /// `keep` holds fingers already committed to a drag. Pressing harder
    /// flattens them to palm size, and rejecting one mid-drag lost the drag.
    mutating func filter(
        contacts: [(id: Int, major: Int?, minor: Int?)],
        productID: Int,
        keep: Set<Int> = []
    ) -> Result {
        guard Self.supports(productID: productID) else {
            reset()
            return Result(
                acceptedIDs: Set(contacts.map(\.id)),
                newlyRejectedIDs: [], newlyAcceptedIDs: [])
        }

        let activeIDs = Set(contacts.map(\.id))
        rejectedIDs.formIntersection(activeIDs)

        var acceptedIDs: Set<Int> = []
        var newlyRejectedIDs: [Int] = []
        let newlyAcceptedIDs: [Int] = []
        acceptedIDs.reserveCapacity(contacts.count)

        for contact in contacts {
            if rejectedIDs.contains(contact.id) { continue }

            guard !keep.contains(contact.id), Self.isPalm(major: contact.major, minor: contact.minor) else {
                acceptedIDs.insert(contact.id)
                continue
            }
            rejectedIDs.insert(contact.id)
            newlyRejectedIDs.append(contact.id)
        }

        return Result(
            acceptedIDs: acceptedIDs,
            newlyRejectedIDs: newlyRejectedIDs,
            newlyAcceptedIDs: newlyAcceptedIDs)
    }

    mutating func reset() {
        rejectedIDs.removeAll(keepingCapacity: true)
    }
}

/// Translates a per-frame set of capacitive contacts into one sticky-mode
/// gesture intent (pointer, two-finger scroll, tap-click, or drag).
///
/// Once a touch sequence picks a mode, it stays there until every finger
/// lifts; switching whenever a finger lands or lifts feels twitchy.
///
/// `InputInjector` owns it and calls it on the HID thread. It reads no global
/// state; `process(...)` receives everything, so tests can drive it.
struct TouchStateTracker {

    enum Mode {
        case idle
        case pending        // contact(s) down, gesture not yet committed
        case pointer        // single contact moving the cursor
        case scroll         // two contacts: pan scroll and/or pinch-zoom
        case drag           // three fingers landed together: left button held, follows one finger
    }

    /// Sticky two-finger sub-mode, chosen once per sequence when significant
    /// motion appears.
    ///
    /// Within `.gesture`, pinch and rotate can both run. A component that
    /// didn't qualify at commit may join later (see the late-join block in
    /// `process`), because evidence for the second gesture rarely arrives in
    /// the same frame as the first. Joining is one-way: ending a component
    /// mid-sequence posts an `.ended` that apps read as the gesture finishing.
    ///
    /// `.pan` excludes `.gesture`, as on a real trackpad: moving the centroid
    /// differs from the fingers moving relative to each other.
    enum TwoFingerKind {
        case undecided
        case pan
        case gesture
    }

    enum Intent: Equatable {
        case none
        /// Move the cursor by (dx, dy) screen points.
        case pointerMove(dx: Double, dy: Double)
        /// Absolute-mode counterpart to `pointerMove`: warp the cursor to this
        /// screen point (already mapped from the touch area). Only emitted when
        /// `absoluteTouch` is true.
        case pointerWarp(to: CGPoint)
        /// Tap-to-click: the sequence began and ended on roughly the same point
        /// within `tapMaxDuration`. Posts one left click.
        case tapClick
        /// Two fingers landed together, stayed put, and lifted within
        /// `twoFingerTapMaxDuration`. Posts one right click.
        case secondaryClick
        /// Three-finger drag: press the left button at this point when the
        /// cursor follows the finger, else where the cursor is. Released when
        /// every finger lifts.
        case dragDown(at: CGPoint?)
        case dragMove(dx: Double, dy: Double)
        case dragWarp(to: CGPoint)
        case dragUp
        /// Two-finger scroll delta in screen points with its scroll phase
        /// (CG values 1 began, 2 changed, 4 ended). The sign follows the
        /// natural-scrolling setting.
        case scrollDelta(dx: Double, dy: Double, phase: ScrollPhase)
        /// Pinch-zoom and two-finger rotate, each with its own phase. A real
        /// trackpad can magnify and rotate at once, so each component is
        /// optional. `nil` means the gesture isn't part of this touch, or has
        /// nothing new this frame; `.changed` never carries a zero delta.
        ///
        /// `magnify.value` is the relative growth of finger distance this frame,
        /// newDistance / oldDistance - 1, as a real trackpad reports it.
        /// Per-frame deltas then compound to the correct total scale. Spreading
        /// is positive.
        ///
        /// `rotate.value` is this frame's change in pair angle, in radians,
        /// negated from raw `atan2` because screen coordinates are y-down. It
        /// stays in radians because the CGEvent field's unit is unverified
        /// (see `postTouchRotate`); conversion belongs at the posting layer.
        case twoFingerGesture(magnify: GestureDelta?, rotate: GestureDelta?)
    }

    /// One pinch or rotate component's value and phase. `value` is a
    /// magnification for `magnify` and radians for `rotate`. A tuple can't
    /// carry this, because `Intent`'s synthesized `Equatable` needs a nominal
    /// `Equatable` type.
    struct GestureDelta: Equatable {
        let value: Double
        let phase: ScrollPhase
    }

    enum ScrollPhase: Int {
        case began = 1
        case changed = 2
        case ended = 4
    }

    // MARK: - State

    private(set) var mode: Mode = .idle

    /// Last screen-space position per contact id, for the per-frame delta.
    private var lastPositions: [Int: CGPoint] = [:]

    /// Smoothed screen-space speed (points/sec) for `.pointer` mode, feeding
    /// `pointerGain`. One frame's `delta/dt` is too noisy for a gain curve: at
    /// slow speeds a finger advances about one device unit per frame, so the
    /// instant speed flaps between 0 and a unit's worth. An exponential moving
    /// average smooths that and still follows real changes within a couple of
    /// frames. `-1` means no history (set on lift and after
    /// `pointerVelocityStaleGap`); the next sample then seeds from its own
    /// speed, so the first frames after a pause don't damp fast motion.
    private var pointerSpeed: Double = -1

    /// In `absoluteTouch` mode, the contact that started this `.pointer`
    /// sequence. It is read from `contacts.first` only while nil. Relative mode
    /// tolerates `.first` changing because a new id's first delta is zero;
    /// absolute mode has no delta to zero, so a second finger sorting ahead of
    /// the driving one would warp the cursor to it. Never set in relative mode.
    private var absolutePrimaryContactID: Int?
    /// Last screen position the cursor was warped to this sequence in
    /// `absoluteTouch` mode. A still finger doesn't re-warp every frame, but
    /// the first frame always warps, even with zero motion, so `.tapClick`
    /// lands at the right spot. `nil` means no warp yet.
    private var absoluteLastWarpedTo: CGPoint?
    /// When the last `.pointer` sample arrived, for staleness and the `dt` of
    /// the `pointerSpeed` average.
    private var lastPointerSampleTime: TimeInterval = 0

    /// First-frame screen position for tap detection. Only the primary contact
    /// (the first finger down) counts.
    private var tapAnchor: CGPoint?
    private var tapStart: TimeInterval = 0
    /// Largest distance the primary contact has moved from `tapAnchor`. Past
    /// `tapMaxDistance`, the sequence can no longer be a tap.
    private var tapMaxDelta: Double = 0

    /// Last scroll phase emitted for `.pan`, so exactly one `.ended` goes out
    /// when the last contact lifts. Pinch and rotate keep their own phases.
    private var lastScrollPhase: ScrollPhase = .ended

    /// Motion held before a committed pan's `.began`. AppKit gives a gesture to
    /// the nested scroll view matching the `.began` delta's dominant axis,
    /// judged on whole points, so `.began` waits until an axis reaches 1 pt and
    /// carries it all. A zero-delta `.began` reads as vertical and strands
    /// horizontal scrolls (the Finder's column view).
    private var pendingBeganDx = 0.0
    private var pendingBeganDy = 0.0

    /// When a committed `.pan` first fell below two contacts, or 0 while two
    /// are present. Drives `scrollSingleContactGrace`.
    private var scrollDroppedToOneContactAt: TimeInterval = 0
    /// Flick velocity captured when a `.pan` first fell to one contact, while
    /// the samples are still fresh. The later wind-down can't recompute it:
    /// every sample is older than `peakVelocityWindow` by then, so the flick
    /// would never coast. `.zero` for a deliberate brake, as on full lift.
    private var scrollVelocityAtDrop: CGVector = .zero
    /// Diagnostic snapshots taken with `scrollVelocityAtDrop` for the same
    /// reason. They feed `releaseSuppressedByRecency`, `releaseFrameGap`, and
    /// `releaseMotionGap`.
    private var suppressedByRecencyAtDrop = false
    private var frameGapAtDrop: TimeInterval = -1
    private var motionGapAtDrop: TimeInterval = -1
    /// Set once a `.scroll` sequence has wound down early (see
    /// `scrollSingleContactGrace`) while fingers remain. `process` then emits
    /// nothing for frames overlapping that gesture's contacts, so leftover
    /// fingers can't revive it. Cleared on full lift, on an entirely new
    /// contact set, or by the timed backstop.
    private var scrollWoundDown = false
    /// Backstop for `scrollWoundDown`: clears it at this time, so a lift frame
    /// that never arrives can't latch touch off.
    private var scrollWoundDownExpiresAt: TimeInterval = 0

    /// Sticky pan vs gesture once motion crosses `twoFingerDecideDistance`.
    private var twoFingerKind: TwoFingerKind = .undecided

    /// Dominant-axis lock for a committed `.pan`, so drift on the other axis
    /// doesn't scroll an app that moves both ways or read as a swipe in
    /// Firefox. `nil` while undecided. A diagonal drag never reaches
    /// `scrollAxisLockRatio` and stays free (`scrollAxisResolved` true, lock
    /// nil).
    private enum ScrollAxis { case vertical, horizontal }
    private var scrollAxisLock: ScrollAxis?
    /// True once the lock decision is made, either way. Stops the pre-lock
    /// accumulators from running for the rest of the gesture.
    private var scrollAxisResolved = false
    /// Unsigned centroid travel per axis before the lock, summed until the
    /// total reaches `scrollAxisLockWindow`.
    private var scrollPreLockAccumX = 0.0
    private var scrollPreLockAccumY = 0.0

    /// As in `PanScrollTracker`: AppKit keeps a gesture on the view its `.began`
    /// picked, so a scroll that settles along the other axis (a vertical start
    /// turning sideways in the Finder's column view) ends and begins again with
    /// a fresh lock. These hold the axis the `.began` carried and the raw
    /// travel since the last check.
    private var scrollLatchedAxis: ScrollAxis?
    private var scrollStretchX = 0.0
    private var scrollStretchY = 0.0
    /// After a restart, `.began` waits for the fresh lock so it carries a clear
    /// direction instead of the first point of travel.
    private var scrollRestarted = false

    /// Whether the live two-finger sequence committed to pan. Only the
    /// injector's stuck-scroll diagnostic reads it, and only in `.scroll` mode.
    var committedToPan: Bool { twoFingerKind == .pan }

    /// True for the one `process()` call that wound a `.pan` down early, for
    /// the injector's `scrollWindDowns` counter. The injector clears it after
    /// each frame.
    var scrollWoundDownThisFrame = false

    /// Whether a wound-down `.pan` is in its hold, with the gesture finished
    /// and its fingers still down. Mode stays `.scroll` through the hold, so
    /// the injector's stuck-scroll diagnostic skips these frames.
    var isHoldingWoundDownScroll: Bool { scrollWoundDown }
    /// Whether pinch and rotate are part of the current `.gesture`. Later
    /// frames can add a component (see `TwoFingerKind`) but never remove one.
    private var pinchInGesture = false
    private var rotateInGesture = false
    /// Independent phase envelopes for pinch and rotate. Each opens with its
    /// own `.began` when included and closes with its own `.ended` at teardown.
    private var pinchPhase: ScrollPhase = .ended
    private var rotatePhase: ScrollPhase = .ended
    /// Last inter-finger distance in screen points.
    private var lastPinchDistance: Double = 0
    /// Centroid and distance at the start of an undecided two-finger sequence.
    /// The decision uses cumulative motion from these anchors, because a slow
    /// pan never exceeds the threshold in one high-rate frame.
    private var undecidedOriginCentroid: CGPoint = .zero
    private var undecidedOriginDistance: Double = 0

    /// Whether the two fingers landed far enough apart, relative to the touch
    /// surface, for rotate to be a candidate. Computed once at escalation from
    /// raw device units: screen-space separation for the same finger span
    /// varies with the touch-area crop and display size. `false` when rotate
    /// is off.
    private var rotateEligible: Bool = false
    /// When the sequence entered `.undecided`; the dwell clock for
    /// rotate-eligible sequences (see `rotateMinDwell`).
    private var undecidedStartTime: TimeInterval = 0
    /// Angle (radians, `atan2`) of the id-sorted two-contact pair last frame.
    /// It serves as the origin angle while undecided and as the delta baseline
    /// once committed.
    private var lastPairAngle: Double = 0
    /// Cumulative wrapped angle change since the undecided origin, the rotate
    /// analog of `undecidedOriginCentroid`. Summing per frame lets a rotation
    /// past π during the decide window accumulate instead of wrapping back.
    private var undecidedCumulativeAngle: Double = 0
    /// Per-frame gesture signal over the last `lateJoinWindow`, for the
    /// late-join test. A trailing window keeps the bar a joining component
    /// must clear constant, instead of climbing with gesture duration.
    private var recentGestureDeltas:
        [(time: TimeInterval, scale: Double, tangential: Double, translation: Double)] = []

    /// Recent per-frame velocities (points/second), each the raw `delta/dt`
    /// with a timestamp. They seed the momentum tail. The fastest sample in a
    /// short window beats a moving average, which converges too slowly for a
    /// brief flick and reports well under its peak (momentum fell short of a
    /// real trackpad). Matches `PanScrollTracker`. Pruned to
    /// `peakVelocityWindow` each frame.
    private var recentVelocities: [(time: TimeInterval, v: CGVector)] = []
    private var lastFrameTime: TimeInterval = 0
    /// Time of the last frame with motion. A real trackpad starts no momentum
    /// after a deliberate brake, when the fingers rest before lifting. Gating
    /// release on recent motion catches that even when a fast sample still sits
    /// in `recentVelocities`.
    private var lastMotionTime: TimeInterval = 0
    /// Captured when the scroll gesture ends; the posting layer starts the
    /// momentum tail from it.
    private(set) var releaseVelocity: CGVector = .zero
    /// Diagnostic: when the last release produced zero `releaseVelocity`,
    /// `true` means the recency gate rejected a fast sample (a brake, or a
    /// batched-delivery gap that looks like one) and `false` means the
    /// peak-velocity window was empty.
    private(set) var releaseSuppressedByRecency = false
    /// Diagnostic: at the last release, the time since the last `.scroll`
    /// frame (`releaseFrameGap`) and since the last one that moved
    /// (`releaseMotionGap`). Both large means frames stopped arriving. Only
    /// the motion gap large means the fingers rested. -1 before the first
    /// release.
    private(set) var releaseFrameGap: TimeInterval = -1
    private(set) var releaseMotionGap: TimeInterval = -1

    /// Both fingers landed inside the onset window and far enough apart to be
    /// fingertips, not a palm's patchy outline. Gates `.secondaryClick`.
    private var twoFingerTapEligible = false

    /// Most contacts seen this sequence, and why a third finger failed to start
    /// a drag (too late or too close). For the miss diagnostic.
    private var maxContactsThisSequence = 0
    private var threeFingerMissReason: String?
    /// Diagnostic: why the last touch with three or more fingers didn't drag,
    /// set at lift. Nil when it dragged or had fewer fingers.
    private(set) var threeFingerTapMiss: String?
    /// Fingers that started the current drag. The palm filter leaves them be.
    private(set) var dragFingerIDs: Set<Int> = []
    private var dragPrimaryID: Int?
    /// Relative drag follows the fingers' centroid, re-anchored whenever the
    /// finger set changes so a lift or landing doesn't jump.
    private var dragCentroid: CGPoint?
    private var dragCentroidIDs: Set<Int> = []

    // MARK: - Tunables

    /// Maximum drift (in screen points) that still counts as a tap.
    static let tapMaxDistance: Double = 8.0
    /// Maximum tap duration (seconds); longer touches become drags or scrolls.
    static let tapMaxDuration: TimeInterval = 0.30
    /// Onset delay: a touch sequence emits nothing until it has been down this
    /// long. It does two jobs, as on trackpads, at the cost of delaying pointer
    /// motion by this much:
    /// 1. A palm landing just before the pen tips down lands inside the window,
    ///    so the injector resets the tracker before the palm moves the cursor.
    /// 2. A second finger landing inside the window starts a scroll directly,
    ///    without the first finger dragging the cursor first.
    ///
    /// Two fingers from rest land 1–3 frames (about 10–30 ms) apart, so 40 ms
    /// covers job 2 with margin (reasoned, not measured). Job 1 covers only a
    /// palm before tip-down: a hovering pen takes `touchBusyHoldOff` (150 ms)
    /// to confirm busy, and tip-down bypasses that. The risk is a drifting
    /// palm, which is harmless: it can't tap (drift exceeds `tapMaxDistance`)
    /// or scroll (needs two contacts), and the pen's next report corrects the
    /// cursor. `touchOnsetDelayMs` overrides it per device through
    /// `InjectionSnapshot`.
    ///
    /// At 0 the first frame still doesn't move the cursor: the `.idle` frame
    /// and the frame that clears the delay both return `.none`, so motion
    /// starts on the third frame (about 20 ms) and the first two frames of
    /// travel are discarded.
    static let onsetDelay: TimeInterval = 0.04

    /// Screen points a single-finger touch may drift before it moves the
    /// cursor. It absorbs lift-off skitter on a tap and the first point or two
    /// of a slow drag from rest, below where response feels sticky. Relative
    /// mode only. `TabletSettings.touchTapStabilizationPt` feeds it; this
    /// static serves tests and direct callers.
    static let tapStabilizationPt: Double = 1.5

    /// Motion (screen points) needed to commit pan vs pinch. Slightly above
    /// finger jitter, so a sliding pan doesn't decide on noise.
    static let twoFingerDecideDistance: Double = 6.0
    /// Pinch and rotate qualify only when their signal clearly exceeds
    /// centroid translation. Otherwise pan wins when it's available (see the
    /// `twoFingerScroll` guard in `process`) and the result is `.none` when
    /// not. This bar protects "pan wins on ambiguity"; it doesn't compare
    /// pinch against rotate (see the noise floors).
    static let pinchDominanceRatio: Double = 1.75
    /// Absolute floor (screen points) each of pinch and rotate must clear on
    /// top of beating pan by `pinchDominanceRatio`. It screens out jitter that
    /// is small in absolute terms. Rotate's is stricter: a document tilting
    /// during a clean zoom is worse than a zoom that misses a little rotation.
    /// Not hardware-tuned: pinch uses `twoFingerDecideDistance`, rotate 1.5
    /// times that.
    static let pinchNoiseFloor: Double = twoFingerDecideDistance
    static let rotateNoiseFloor: Double = twoFingerDecideDistance * 1.5
    /// When pinch and rotate both clear their floors, the smaller one counts
    /// as the larger one's incidental companion and is suppressed unless it
    /// reaches this fraction of the larger one's magnitude. A real pinch with
    /// twist wobble (scale 30, tangential 11, ratio 0.37) suppresses rotate.
    /// Comparable signals both survive, which allows true concurrent
    /// pinch+rotate: tangential 25 against scale 26 clears both sides.
    static let companionSuppressionRatio: Double = 0.5
    /// How far back to look for the fastest recent sample when seeding
    /// momentum; matches `PanScrollTracker.peakVelocityWindow`.
    static let peakVelocityWindow: TimeInterval = 0.06
    /// Minimum frame spacing for a `delta/dt` sample to count as a real
    /// velocity (see the `.scroll` case). It sits below the device's touch
    /// cadence and above a Bluetooth burst's inter-frame gap.
    static let minVelocityDt: TimeInterval = 0.002
    /// Smoothing factor for `pointerSpeed`: smaller is smoother and slower to
    /// react. At 0.5, each sample at the native ~100 Hz rate pulls the speed
    /// roughly a third of the way to the instant value. That removes the
    /// one-unit-per-frame quantization noise of slow sweeps without visible lag.
    static let pointerSpeedEmaFactor: Double = 0.5
    /// A gap this long since the last `.pointer` sample means the finger was
    /// still or just landed. The smoothed speed is stale and mustn't carry into
    /// new motion.
    static let pointerVelocityStaleGap: TimeInterval = 0.1
    /// Speeds (screen points/sec) below and above which `pointerGain` uses its
    /// floor and ceiling. An unhurried sweep across a typical display falls in
    /// the flat midrange, which keeps "1.00x = one sweep, one crossing" true
    /// for normal use; only the slow and fast tails change.
    static let pointerGainLowSpeed: Double = 30
    static let pointerGainHighSpeed: Double = 900
    /// Gain multiplier at or below `pointerGainLowSpeed` and at or above
    /// `pointerGainHighSpeed`, on top of the user's `sensitivity`. The bounds
    /// follow libinput's adaptive profile but sit much closer to 1.0 at the
    /// low end. The whole touch surface maps to the whole screen, so a floor as
    /// low as libinput's would keep an unhurried sweep from reaching the far
    /// edge at 1.00x. The floor now only bites at micro-adjustment speeds.
    static let pointerGainFloor: Double = 0.85
    static let pointerGainCeiling: Double = 1.6

    /// Speed-dependent gain for `.pointer` mode, where 1.0 is flat. Flat
    /// between the two thresholds, interpolated linearly to the floor and
    /// ceiling outside them. `speed` is the smoothed `pointerSpeed`; the
    /// function keeps no state.
    static func pointerGain(forSpeed speed: Double) -> Double {
        if speed <= pointerGainLowSpeed {
            let t = pointerGainLowSpeed > 0 ? speed / pointerGainLowSpeed : 1
            return pointerGainFloor + (1 - pointerGainFloor) * t
        }
        if speed >= pointerGainHighSpeed {
            let over = speed - pointerGainHighSpeed
            let span = pointerGainHighSpeed - pointerGainLowSpeed
            let t = min(over / span, 1)
            return 1 + (pointerGainCeiling - 1) * t
        }
        return 1
    }
    /// A lift counts as a flick release only if motion happened within this
    /// many seconds of it. Otherwise the fingers rested (a brake), and release
    /// velocity is suppressed even if a fast sample remains in the window.
    static let momentumRecencyWindow: TimeInterval = 0.05
    /// Grace period after a committed `.pan` drops from two contacts to one,
    /// before the gesture winds down. A brief one-contact frame is normal
    /// mid-scroll (palm filtering churns the set, or a finger lifts for a
    /// moment). A `.pan` kept alive on one finger would scroll on every later
    /// move, even in an unrelated single-finger touch. After this long, the
    /// gesture is over: close it out and hold wound down until all fingers lift.
    static let scrollSingleContactGrace: TimeInterval = 0.1
    /// Unsigned centroid travel (screen points) a committed `.pan` accumulates
    /// before deciding a dominant axis. Events before the lock still carry the
    /// off-axis component, so the window stays as small as still lets a real
    /// diagonal register.
    static let scrollAxisLockWindow: Double = 8.0
    /// Dominant-to-other axis ratio that commits the lock (2:1 is within about
    /// 25° of true horizontal or vertical). Below it on both legs, the gesture
    /// is diagonal and stays omnidirectional.
    static let scrollAxisLockRatio: Double = 2.0
    /// Raw travel (screen points) of each stretch checked for settling along
    /// the other axis; matches `PanScrollTracker.axisTurnStretch`.
    static let scrollTurnStretch: Double = 24.0
    /// Backstop that clears `scrollWoundDown` when no lift frame arrives. A
    /// real gesture is long over by then, and the bound keeps a lost lift frame
    /// from latching touch off.
    static let scrollWoundDownBackstop: TimeInterval = 2.0
    /// Above this, a release gap is the idle between two gestures (the ending
    /// frame arriving with the next touch), not a stall. The diagnostics
    /// record -1.
    static let releaseGapPlausibleMax: TimeInterval = 1.0
    /// How close `frameGap` and `motionGap` must be at a scroll release to call
    /// it a delivery gap (frames stopped) instead of a brake (frames kept
    /// coming, finger still). A healthy USB release differs by about 10 ms of
    /// jitter; a Bluetooth stall makes them identical. 30 ms clears the jitter
    /// and still separates every observed stall. See `releaseKinematics`.
    static let deliveryGapBrakeSlack: TimeInterval = 0.030
    /// Maximum hold for a two-finger contact to count as a tap rather than a
    /// rest. It needs no deviation check: a teardown still `.undecided` already
    /// guarantees centroid travel and distance change stayed under
    /// `twoFingerDecideDistance`. See the `.undecided` branch in `process`.
    static let twoFingerTapMaxDuration: TimeInterval = 0.30
    /// How far apart two fingers may land and still right-click. Separate from
    /// the onset delay, which users shorten: Bluetooth delivers touch every
    /// 20–50 ms, so fingers landing together still arrive a frame apart.
    static let twoFingerLandWindow: TimeInterval = 0.06
    /// Minimum center-to-center spacing (millimeters) for a two-finger tap to
    /// right-click. Fingertips side by side sit about 15 mm apart; a palm's
    /// stray contacts can land a fraction of a millimeter apart. Reasoned, not
    /// measured.
    static let secondaryClickMinSpacingMM: Double = 10.0
    /// Three fingers landing within this long of the first count as landing
    /// together. Longer than the onset window, since three fingers spread
    /// out more than two. Reasoned, not measured.
    static let threeFingerLandingWindow: TimeInterval = 0.10
    /// Three fingertips bunch closer than two: a PTH-660 capture put most
    /// three-finger frames' closest pair 5–10 mm apart.
    static let threeFingerMinSpacingMM: Double = 5.0
    /// Minimum finger separation, as a fraction of the touch surface's physical
    /// diagonal, for rotate to be eligible. Millimeters, because raw device
    /// units distort it (see `rawPositions` in `process`). Two close fingers
    /// sweeping together read as pan; only wide-apart swiveling should read as
    /// rotate. On the PTH-850 (about 383 mm diagonal), a 90 mm thumb-index span
    /// is about 23%, so 0.15 sits below it to allow smaller spans and tablets.
    /// Unverified on hands or a second tablet size.
    static let rotateMinSeparationFraction: Double = 0.15
    /// Minimum time a rotate-eligible sequence must sit undecided before rotate
    /// can win the decision. The 6 pt decide distance is about half a millimeter
    /// of centroid drift, so landing noise alone can exceed it in the first
    /// frame or two. Pan and pinch aren't held back, and fast, large motion
    /// bypasses the wait via `rotateDwellBypassDistance`. Not hardware-tuned;
    /// chosen at the low end of a plausible hold.
    static let rotateMinDwell: TimeInterval = 0.07
    /// Translation or scale change (screen points) large enough to bypass
    /// `rotateMinDwell`. An obviously fast pan or pinch shouldn't wait on a
    /// timer meant for slow twist onsets. Twice `twoFingerDecideDistance`.
    static let rotateDwellBypassDistance: Double = 12.0
    /// Trailing window the late-join test sums its evidence over (see the
    /// late-join block in `process`). Long enough to accumulate a deliberate
    /// motion at report rate (about 25 frames at 100 Hz, comparable to a
    /// commit), short enough that the bar doesn't climb as the gesture runs.
    /// Not hardware-tuned.
    static let lateJoinWindow: TimeInterval = 0.25

    // MARK: - Process

    /// Projects an absolute touch position (device units) to screen space using
    /// the touch-area crop and the display rect. Touch uses its own area
    /// mapping, independent of the pen's, and ignores calibration. The caller
    /// (`InputInjector+Touch.swift`) applies orientation first, so inputs
    /// arrive already oriented. It takes bare coordinates because it needs no
    /// contact id or area.
    ///
    /// Returns `nil` outside the crop rectangle. Clamping would leave the
    /// dead zone partly responsive: a finger outside on one axis would pin the
    /// cursor to that edge while the other axis still tracked.
    static func screenPoint(
        x: Double, y: Double, maxX: Double, maxY: Double,
        areaX: Double, areaY: Double,
        areaWidth: Double, areaHeight: Double,
        displayBounds: CGRect
    ) -> CGPoint? {
        let mx = Swift.max(maxX, 1)
        let my = Swift.max(maxY, 1)
        // Clamp: a coordinate past the ceiling means the registry's ceiling is
        // low, not that the finger left the surface. Without it, the crop test
        // below would reject the contact and kill touch along that edge. A
        // partial crop still rejects the region it excludes.
        let rx = Swift.min(Swift.max(x / mx, 0), 1)
        let ry = Swift.min(Swift.max(y / my, 0), 1)
        let w = Swift.max(areaWidth, 0.001)
        let h = Swift.max(areaHeight, 0.001)
        // Contacts outside the crop rect don't count.
        guard rx >= areaX, rx <= areaX + w,
              ry >= areaY, ry <= areaY + h
        else { return nil }
        let nx = (rx - areaX) / w
        let ny = (ry - areaY) / h
        return CGPoint(
            x: displayBounds.minX + nx * displayBounds.width,
            y: displayBounds.minY + ny * displayBounds.height)
    }

    /// Chooses or continues a gesture mode for contacts already projected to
    /// screen space, and returns the intent to execute.
    ///
    /// `tapToClick`, `twoFingerScroll`, `pinchZoom`, and `rotate` gate the
    /// optional behaviors (`rotate` also needs `rotateEligible`).
    /// `reverseScrollDirection` flips the scroll sign. `sensitivity` scales
    /// pointer movement (1.0 is identity). `rawPositions` maps contact ids to
    /// unprojected positions in physical millimeters. A physical finger-span
    /// gate needs them in millimeters, since the touch surface's X and Y axes
    /// scale differently. Only `rotate` reads them, so other callers can pass
    /// `[:]`. `touchDiagonal` is the surface diagonal in millimeters.
    /// `absoluteTouch` switches `.pointer` mode from relative (trackpad-style
    /// deltas, with `sensitivity` and the speed-gain curve) to absolute, where
    /// the finger's position on the surface warps the cursor 1:1, as the active
    /// area does for the pen. Pen displays use it.
    mutating func process(
        contacts: [(id: Int, screen: CGPoint)],
        tapToClick: Bool,
        twoFingerScroll: Bool,
        reverseScrollDirection: Bool,
        sensitivity: Double,
        pinchZoom: Bool = false,
        twoFingerRightClick: Bool = false,
        threeFingerDrag: Bool = false,
        rotate: Bool = false,
        rawPositions: [Int: CGPoint] = [:],
        touchDiagonal: Double = 0,
        absoluteTouch: Bool = false,
        onsetDelay: TimeInterval = TouchStateTracker.onsetDelay,
        tapStabilizationPt: Double = TouchStateTracker.tapStabilizationPt,
        now: TimeInterval
    ) -> Intent {

        // Set only by the wind-down return below.
        scrollWoundDownThisFrame = false

        // A scroll wound down early (see `scrollSingleContactGrace`) already
        // closed its phase and set `releaseVelocity`. Emit nothing while its
        // fingers linger, and clear the hold on any of: all fingers lifted, a
        // contact set that no longer overlaps the gesture (a fresh sequence),
        // or the timed backstop. The last two keep a lift frame that never
        // arrives from wedging touch off.
        if scrollWoundDown {
            if let held = processWoundDownHold(contacts: contacts, now: now) { return held }
        }

        // All fingers lifted: wrap up any gesture. A sequence that never
        // outlived the onset delay can still be a tap.
        if contacts.isEmpty {
            return processAllLifted(
                tapToClick: tapToClick,
                twoFingerRightClick: twoFingerRightClick,
                threeFingerDrag: threeFingerDrag,
                now: now
            )
        }

        maxContactsThisSequence = Swift.max(maxContactsThisSequence, contacts.count)
        // Three fingers landing together start a drag unless a scroll, zoom, or
        // rotate has begun. The first finger leads.
        if let press = startThreeFingerDrag(
            contacts: contacts,
            threeFingerDrag: threeFingerDrag,
            rawPositions: rawPositions,
            absoluteTouch: absoluteTouch,
            now: now
        ) {
            return press
        }
        // The first contact waits in pending for the onset delay, so a palm
        // smush or an arriving second finger never moves anything.
        if mode == .idle, let first = contacts.first {
            return beginSequence(first: first, absoluteTouch: absoluteTouch, now: now)
        }

        // Escalate to scroll once two contacts are present. From pending, the
        // fingers landed together and the scroll starts with no cursor drift.
        // Scroll, pinch, and rotate are alternate readings of one two-contact
        // gesture, so any one flag enables tracking; each frame decides which
        // can win.
        if let escalated = escalateToTwoFingers(
            contacts: contacts,
            twoFingerScroll: twoFingerScroll,
            pinchZoom: pinchZoom,
            rotate: rotate,
            twoFingerRightClick: twoFingerRightClick,
            threeFingerDrag: threeFingerDrag,
            rawPositions: rawPositions,
            touchDiagonal: touchDiagonal,
            onsetDelay: onsetDelay,
            now: now
        ) {
            return escalated
        }

        switch mode {
        case .drag:
            return processDrag(
                contacts: contacts,
                sensitivity: sensitivity,
                absoluteTouch: absoluteTouch,
                now: now
            )
        case .pending:
            return processPending(
                contacts: contacts,
                absoluteTouch: absoluteTouch,
                onsetDelay: onsetDelay,
                tapStabilizationPt: tapStabilizationPt,
                now: now
            )
        case .scroll:
            return processScroll(
                contacts: contacts,
                twoFingerScroll: twoFingerScroll,
                reverseScrollDirection: reverseScrollDirection,
                pinchZoom: pinchZoom,
                rotate: rotate,
                now: now
            )
        case .pointer where absoluteTouch:
            return processAbsolutePointer(contacts: contacts)
        case .pointer:
            return processPointer(contacts: contacts, sensitivity: sensitivity, now: now)
        case .idle:
            return .none
        }
    }

    /// One frame of a three-finger drag.
    private mutating func processDrag(
        contacts: [(id: Int, screen: CGPoint)],
        sensitivity: Double,
        absoluteTouch: Bool,
        now: TimeInterval
    ) -> Intent {
        if !absoluteTouch {
            let ids = Set(contacts.map(\.id))
            let c = centroid(of: contacts.map(\.screen))
            guard let prev = dragCentroid, ids == dragCentroidIDs else {
                dragCentroid = c
                dragCentroidIDs = ids
                lastPointerSampleTime = 0
                return .none
            }
            dragCentroid = c
            let rawDx = c.x - prev.x, rawDy = c.y - prev.y
            if rawDx == 0 && rawDy == 0 { return .none }
            let gain = adaptivePointerGain(rawDx: rawDx, rawDy: rawDy, now: now, sensitivity: sensitivity)
            return .dragMove(dx: rawDx * gain, dy: rawDy * gain)
        }
        // The lead finger lifting hands the drag to another without a jump.
        if dragPrimaryID.map({ id in !contacts.contains { $0.id == id } }) ?? true,
           let next = contacts.first {
            dragPrimaryID = next.id
            lastPositions = [next.id: next.screen]
            return .none
        }
        guard let id = dragPrimaryID,
              let p = contacts.first(where: { $0.id == id })?.screen,
              let prev = lastPositions[id], p != prev
        else { return .none }
        lastPositions[id] = p
        if absoluteTouch { return .dragWarp(to: p) }
        return .dragMove(dx: (p.x - prev.x) * sensitivity, dy: (p.y - prev.y) * sensitivity)
    }

    /// One frame while the first contact waits out the onset delay.
    private mutating func processPending(
        contacts: [(id: Int, screen: CGPoint)],
        absoluteTouch: Bool,
        onsetDelay: TimeInterval,
        tapStabilizationPt: Double,
        now: TimeInterval
    ) -> Intent {
        // Track motion for tap detection. Relative mode emits nothing here and
        // anchors at commit, so motion during the window is discarded instead
        // of replayed as a jump. Absolute mode has no such hazard, and skipping
        // the warp would leave the cursor stale for a tap that lifts before the
        // onset delay.
        //
        // Tap stabilization extends the hold from time to time and distance:
        // a barely moving finger stays pinned past `onsetDelay` until it clears
        // `tapStabilizationPt`. `lastPositions` is rewritten every frame, so
        // the release delta stays one frame's worth, with no catch-up jump.
        if let first = contacts.first {
            if let anchor = tapAnchor {
                tapMaxDelta = Swift.max(tapMaxDelta, hypot(
                    first.screen.x - anchor.x, first.screen.y - anchor.y))
            }
            lastPositions = [first.id: first.screen]
            if absoluteTouch {
                // Absolute mode holds on time only. Every frame warps to the
                // finger, so there's no drift to suppress.
                if absolutePrimaryContactID == nil {
                    absolutePrimaryContactID = first.id
                }
                if now - tapStart >= onsetDelay {
                    mode = .pointer
                }
                if absoluteLastWarpedTo != first.screen {
                    absoluteLastWarpedTo = first.screen
                    return .pointerWarp(to: first.screen)
                }
                return .none
            }
        }
        // Relative mode commits once the onset delay passes and the finger
        // clears the stabilization tolerance. A tolerance of 0 turns it off.
        let heldForStabilization =
            tapStabilizationPt > 0 && tapMaxDelta < tapStabilizationPt
        if now - tapStart >= onsetDelay, !heldForStabilization {
            mode = .pointer
        }
        return .none
    }

    /// One frame of absolute-mode pointing: warp to the sequence's primary contact.
    private mutating func processAbsolutePointer(contacts: [(id: Int, screen: CGPoint)]) -> Intent {
        // Pin to the contact that started the sequence (see
        // `absolutePrimaryContactID`).
        let primaryID = absolutePrimaryContactID ?? contacts.first?.id
        absolutePrimaryContactID = primaryID
        guard let primaryID, let primary = contacts.first(where: { $0.id == primaryID })
        else { return .none }
        lastPositions[primary.id] = primary.screen
        if let anchor = tapAnchor {
            tapMaxDelta = Swift.max(tapMaxDelta, hypot(
                primary.screen.x - anchor.x, primary.screen.y - anchor.y))
        }
        // Skip a repeat warp to the same spot, or a still finger would post
        // about 100 identical moves per second. The first frame always warps
        // (set in pending), so a motionless tap still clicks in the right place.
        if absoluteLastWarpedTo == primary.screen { return .none }
        absoluteLastWarpedTo = primary.screen
        return .pointerWarp(to: primary.screen)
    }

    /// One frame of relative pointing.
    private mutating func processPointer(
        contacts: [(id: Int, screen: CGPoint)],
        sensitivity: Double,
        now: TimeInterval
    ) -> Intent {
        guard let first = contacts.first else { return .none }
        let prev = lastPositions[first.id] ?? first.screen
        let rawDx = first.screen.x - prev.x
        let rawDy = first.screen.y - prev.y

        let gain = adaptivePointerGain(rawDx: rawDx, rawDy: rawDy, now: now, sensitivity: sensitivity)

        let dx = rawDx * gain
        let dy = rawDy * gain
        lastPositions[first.id] = first.screen
        if let anchor = tapAnchor {
            tapMaxDelta = Swift.max(tapMaxDelta, hypot(
                first.screen.x - anchor.x, first.screen.y - anchor.y))
        }
        if dx == 0 && dy == 0 { return .none }
        return .pointerMove(dx: dx, dy: dy)
    }

    /// One frame of a two-finger sequence: undecided, pan, or pinch and rotate.
    private mutating func processScroll(
        contacts: [(id: Int, screen: CGPoint)],
        twoFingerScroll: Bool,
        reverseScrollDirection: Bool,
        pinchZoom: Bool,
        rotate: Bool,
        now: TimeInterval
    ) -> Intent {
        let dt = now - lastFrameTime
        lastFrameTime = now
        // Centroid delta over contacts present in this frame and the last. New
        // ids (a finger lifted and re-landed, or palm filtering churned the
        // set) seed the next frame instead of stalling the gesture.
        let current = Array(contacts.prefix(2))
        let tracked = current.filter { lastPositions[$0.id] != nil }
        let oldCentroid = centroid(of: tracked.compactMap { lastPositions[$0.id] })
        let newCentroid = centroid(of: tracked.map { $0.screen })
        // Hold the last distance when a finger lifts mid-gesture; zero would
        // invent a huge scale delta.
        let newDistance = current.count >= 2
            ? Self.distance(between: current)
            : lastPinchDistance
        let oldDistance = lastPinchDistance
        let scaleDelta = newDistance - oldDistance
        lastPositions = Dictionary(
            current.map { ($0.id, $0.screen) },
            uniquingKeysWith: { first, _ in first })
        lastPinchDistance = newDistance

        // A committed pan down to one contact for longer than the grace window
        // is finished: the user lifted one finger and kept the other down.
        // Otherwise the lone finger would keep scrolling until every finger
        // lifted (`scrollWoundDown` blocks that). Capture the flick velocity
        // from when both fingers were moving, then close the phase. Pinch and
        // rotate skip this, since one-contact frames are already ignored above.
        if twoFingerKind == .pan {
            if current.count >= 2 {
                scrollDroppedToOneContactAt = 0
            } else {
                if scrollDroppedToOneContactAt == 0 {
                    // First frame of the drop: `recentVelocities` is still
                    // fresh. Snapshot the velocity and the gaps now; the
                    // wind-down is too late. `dt` is this frame's spacing,
                    // since `lastFrameTime` already holds `now`.
                    scrollDroppedToOneContactAt = now
                    let k = releaseKinematics(now: now, frameGapOverride: dt)
                    scrollVelocityAtDrop = k.velocity
                    suppressedByRecencyAtDrop = k.suppressedByRecency
                    frameGapAtDrop = k.frameGap
                    motionGapAtDrop = k.motionGap
                }
                if now - scrollDroppedToOneContactAt >= Self.scrollSingleContactGrace {
                    let priorPhase = lastScrollPhase
                    // Release values come from the drop snapshot (see
                    // `scrollVelocityAtDrop`).
                    releaseVelocity = scrollVelocityAtDrop
                    releaseSuppressedByRecency = suppressedByRecencyAtDrop
                    releaseFrameGap = frameGapAtDrop
                    releaseMotionGap = motionGapAtDrop
                    scrollWoundDown = true
                    scrollWoundDownThisFrame = true
                    scrollWoundDownExpiresAt = now + Self.scrollWoundDownBackstop
                    return priorPhase != .ended
                        ? .scrollDelta(dx: 0, dy: 0, phase: .ended)
                        : .none
                }
                // Inside the grace window, emit nothing instead of the lone
                // finger's delta. A returning second finger resumes the pan
                // cleanly, since the positions were re-seeded above.
                return .none
            }
        }

        guard !tracked.isEmpty else { return .none }
        let dx = newCentroid.x - oldCentroid.x
        let dy = newCentroid.y - oldCentroid.y

        // Not just `pinchZoom || rotate`: an undecided sequence arrives here
        // whenever a non-pan candidate was in play at escalation (see
        // `anyTwoFingerGesture`), and a committed gesture keeps tracking even
        // if its flag turns off mid-gesture.
        if twoFingerKind != .pan {
            if twoFingerKind == .undecided {
                return decideTwoFingerKind(
                    current: current,
                    newCentroid: newCentroid,
                    newDistance: newDistance,
                    twoFingerScroll: twoFingerScroll,
                    pinchZoom: pinchZoom,
                    rotate: rotate,
                    now: now
                )
            }
            if twoFingerKind == .gesture {
                return processGestureFrame(
                    current: current,
                    scaleDelta: scaleDelta,
                    oldDistance: oldDistance,
                    newDistance: newDistance,
                    dx: dx,
                    dy: dy,
                    pinchZoom: pinchZoom,
                    rotate: rotate,
                    now: now
                )
            }
        }

        return processPanFrame(
            dx: dx,
            dy: dy,
            dt: dt,
            tracked: tracked,
            reverseScrollDirection: reverseScrollDirection,
            now: now
        )
    }

    /// One undecided two-finger frame: commit to pinch, rotate, both, or pan once the motion is decisive.
    private mutating func decideTwoFingerKind(
        current: [(id: Int, screen: CGPoint)],
        newCentroid: CGPoint,
        newDistance: Double,
        twoFingerScroll: Bool,
        pinchZoom: Bool,
        rotate: Bool,
        now: TimeInterval
    ) -> Intent {
        // One contact collapses the centroid onto that finger, about half the
        // finger separation from the anchor. That alone clears the decide
        // threshold and commits a phantom pan, so wait for two contacts.
        guard current.count >= 2 else { return .none }
        // Cumulative motion since the sequence start, because per-frame deltas
        // stay tiny at high report rates.
        let totalTranslation = hypot(
            newCentroid.x - undecidedOriginCentroid.x,
            newCentroid.y - undecidedOriginCentroid.y)
        let totalScaleChange = abs(newDistance - undecidedOriginDistance)

        // Tangential motion is the angle change in screen points, the unit of
        // the other two candidates, so it shares `twoFingerDecideDistance` and
        // `pinchDominanceRatio`. It stays 0 when rotate is off or ineligible.
        var totalTangentialMotion = 0.0
        if rotate, rotateEligible {
            let sortedPair = current.sorted { $0.id < $1.id }
            let newAngle = Self.angle(between: sortedPair)
            undecidedCumulativeAngle += Self.wrappedDelta(from: lastPairAngle, to: newAngle)
            lastPairAngle = newAngle
            totalTangentialMotion = abs(undecidedCumulativeAngle) * (newDistance / 2)
        }

        let decide = Self.twoFingerDecideDistance
        // Tangential motion waits on `rotateNoiseFloor` (9), not `decide` (6),
        // because that is rotate's real bar. Stopping the wait at 6 would let
        // the "neither qualified" pan default below fire before rotate could
        // qualify at 9, so real rotates would lose to a premature pan.
        if totalScaleChange < decide, totalTranslation < decide,
            totalTangentialMotion < Self.rotateNoiseFloor
        {
            return .none
        }
        // Dwell: a rotate-eligible sequence waits briefly before rotate can
        // win, because landing noise often clears `decide` in the first frame
        // or two (see `rotateMinDwell`). Large, fast motion bypasses the wait.
        // The block never runs when rotate is off or ineligible.
        if rotate, rotateEligible,
            now - undecidedStartTime < Self.rotateMinDwell,
            totalTranslation < Self.rotateDwellBypassDistance,
            totalScaleChange < Self.rotateDwellBypassDistance
        {
            return .none
        }
        let (pinchQualifies, rotateQualifies) = Self.qualifyingComponents(
            translation: totalTranslation, scale: totalScaleChange,
            tangential: totalTangentialMotion,
            pinchZoom: pinchZoom, rotate: rotate && rotateEligible)
        if pinchQualifies || rotateQualifies {
            twoFingerKind = .gesture
            pinchInGesture = pinchQualifies
            rotateInGesture = rotateQualifies
            if pinchQualifies { pinchPhase = .began }
            if rotateQualifies { rotatePhase = .began }
            return .twoFingerGesture(
                magnify: pinchQualifies ? GestureDelta(value: 0, phase: .began) : nil,
                rotate: rotateQualifies ? GestureDelta(value: 0, phase: .began) : nil)
        }
        // Neither qualified. With `twoFingerScroll` off, pan isn't a candidate:
        // stay undecided so a clearer pinch or rotate can still win later.
        guard twoFingerScroll else { return .none }
        twoFingerKind = .pan
        pendingBeganDx = 0
        pendingBeganDy = 0
        return .none
    }

    /// Which of pinch and rotate the accumulated motion supports.
    ///
    /// Each component must beat pan's translation by `pinchDominanceRatio`
    /// (pan wins on ambiguity, including a finger anchored while the other
    /// arcs, a known limitation) and clear its own noise floor. Neither
    /// excludes the other, since a trackpad can magnify and rotate at once.
    ///
    /// Independent floors alone would let a pinch's angle jitter, or a twist's
    /// separation drift, ride along as a second gesture. So when both qualify,
    /// the one below `companionSuppressionRatio` of the other falls out.
    /// Comparable signals both survive: tangential 25 against scale 26 fires
    /// both.
    private static func qualifyingComponents(
        translation: Double, scale: Double, tangential: Double,
        pinchZoom: Bool, rotate: Bool
    ) -> (pinch: Bool, rotate: Bool) {
        var pinch = pinchZoom
            && scale > translation * pinchDominanceRatio
            && scale >= pinchNoiseFloor
        var rotation = rotate
            && tangential > translation * pinchDominanceRatio
            && tangential >= rotateNoiseFloor
        if pinch, rotation {
            if tangential < scale * companionSuppressionRatio {
                rotation = false
            } else if scale < tangential * companionSuppressionRatio {
                pinch = false
            }
        }
        return (pinch, rotation)
    }

    /// One frame of a committed pinch, rotate, or both, including a late-joining second component.
    private mutating func processGestureFrame(
        current: [(id: Int, screen: CGPoint)],
        scaleDelta: Double,
        oldDistance: Double,
        newDistance: Double,
        dx: Double,
        dy: Double,
        pinchZoom: Bool,
        rotate: Bool,
        now: TimeInterval
    ) -> Intent {
        // Angle tracking runs the whole sequence, not only while rotate is
        // active. The late-join test needs a per-frame angle delta while rotate
        // is dormant, and a gap in `lastPairAngle` would make the first delta
        // after a join one large jump. One-contact frames hold the last angle,
        // as `lastPinchDistance` does, since a lone finger has no angle.
        var frameAngleDelta = 0.0
        if rotate, rotateEligible {
            let sortedPair = current.count >= 2 ? current.sorted { $0.id < $1.id } : current
            let newAngle = current.count >= 2 ? Self.angle(between: sortedPair) : lastPairAngle
            frameAngleDelta = Self.wrappedDelta(from: lastPairAngle, to: newAngle)
            lastPairAngle = newAngle
        }

        // Late join. The commit picks components from one frame's evidence,
        // but a zoom that later adds a twist (or the reverse) produces that
        // evidence afterward. A trackpad derives both every frame, so this
        // re-runs qualification for the component not yet in play.
        //
        // It measures over a trailing window, not since the origin. Since-origin
        // totals make the bar climb with gesture length: a twist that needs
        // 20° soon after commit would need 46° once the zoom had been running.
        // The window asks how hard the user twists now.
        //
        // Latch-on only: a begun component never ends mid-sequence, because
        // apps read an `.ended` followed by a fresh `.began` as separate
        // gestures.
        if current.count >= 2 {
            recentGestureDeltas.append((
                time: now,
                scale: abs(scaleDelta),
                tangential: abs(frameAngleDelta) * (newDistance / 2),
                translation: hypot(dx, dy)))
            recentGestureDeltas.removeAll { now - $0.time > Self.lateJoinWindow }
        }
        if current.count >= 2, !pinchInGesture || !rotateInGesture {
            let totalTranslation = recentGestureDeltas.reduce(0) { $0 + $1.translation }
            let totalScaleChange = recentGestureDeltas.reduce(0) { $0 + $1.scale }
            let totalTangentialMotion = (rotate && rotateEligible)
                ? recentGestureDeltas.reduce(0) { $0 + $1.tangential }
                : 0
            // The same test as at commit. Companion suppression keeps drift
            // from firing it: over a long pinch, incidental angle wobble can
            // clear `rotateNoiseFloor` but stays far below
            // `companionSuppressionRatio` of the scale change.
            let (pinchQualifies, rotateQualifies) = Self.qualifyingComponents(
                translation: totalTranslation, scale: totalScaleChange,
                tangential: totalTangentialMotion,
                pinchZoom: pinchZoom, rotate: rotate && rotateEligible)
            let joinPinch = !pinchInGesture && pinchQualifies
            let joinRotate = !rotateInGesture && rotateQualifies
            if joinPinch || joinRotate {
                if joinPinch { pinchInGesture = true; pinchPhase = .began }
                if joinRotate { rotateInGesture = true; rotatePhase = .began }
                // Open the new envelope with a zero delta and skip the active
                // component's delta this frame, as the commit path does. One
                // frame is imperceptible, and mixing `.began` with `.changed`
                // in one return needs extra state.
                return .twoFingerGesture(
                    magnify: joinPinch ? GestureDelta(value: 0, phase: .began) : nil,
                    rotate: joinRotate ? GestureDelta(value: 0, phase: .began) : nil)
            }
        }

        // Each active component reports its own per-frame delta.
        var magnify: GestureDelta?
        if pinchInGesture, scaleDelta != 0, oldDistance > 0 {
            // Exact relative growth (see `twoFingerGesture`).
            pinchPhase = .changed
            magnify = GestureDelta(value: scaleDelta / oldDistance, phase: .changed)
        }
        var rotateComponent: GestureDelta?
        if rotateInGesture {
            let delta = frameAngleDelta
            if delta != 0 {
                rotatePhase = .changed
                // Negated: `atan2` counts counterclockwise as positive in
                // y-up coordinates, and screen coordinates are y-down. Internal
                // tracking stays raw; only the emitted intent flips.
                rotateComponent = GestureDelta(value: -delta, phase: .changed)
            }
        }
        guard magnify != nil || rotateComponent != nil else { return .none }
        return .twoFingerGesture(magnify: magnify, rotate: rotateComponent)
    }

    /// One frame of a committed pan: axis lock, velocity sampling, and the scroll phase envelope.
    private mutating func processPanFrame(
        dx: Double,
        dy: Double,
        dt: TimeInterval,
        tracked: [(id: Int, screen: CGPoint)],
        reverseScrollDirection: Bool,
        now: TimeInterval
    ) -> Intent {
        // Settled along the other axis (see `scrollLatchedAxis`): end, and
        // begin again on a later frame.
        if twoFingerKind == .pan, lastScrollPhase != .ended, let latched = scrollLatchedAxis,
           tracked.count >= 2 {
            scrollStretchX += dx
            scrollStretchY += dy
            let sx = abs(scrollStretchX), sy = abs(scrollStretchY)
            if hypot(sx, sy) >= Self.scrollTurnStretch {
                scrollStretchX = 0
                scrollStretchY = 0
                let ratio = Self.scrollAxisLockRatio
                let settled: ScrollAxis? = sx >= sy * ratio ? .horizontal
                    : sy >= sx * ratio ? .vertical : nil
                if let settled, settled != latched {
                    resetScrollAxisLock()
                    scrollRestarted = true
                    pendingBeganDx = 0
                    pendingBeganDy = 0
                    lastScrollPhase = .ended
                    return .scrollDelta(dx: 0, dy: 0, phase: .ended)
                }
            }
        }

        // Dominant-axis lock (see `scrollAxisLock`). `lockedDx` and `lockedDy`
        // carry the axis-suppressed delta; `dx` and `dy` stay raw for velocity
        // seeding and brake detection, so momentum follows the real flick, as
        // in `PanScrollTracker`.
        var lockedDx = dx
        var lockedDy = dy
        if twoFingerKind == .pan {
            if let scrollAxisLock {
                switch scrollAxisLock {
                case .vertical: lockedDx = 0
                case .horizontal: lockedDy = 0
                }
            } else if !scrollAxisResolved && tracked.count >= 2 {
                // Feed the lock only from genuine two-finger centroid deltas. A
                // frame with one new id (a finger re-landed, or palm filtering
                // churned the set) carries one finger's motion, not a centroid
                // translation. This is defensive, not a known failure; the next
                // full two-contact frame resumes the decision.
                scrollPreLockAccumX += abs(dx)
                scrollPreLockAccumY += abs(dy)
                if scrollPreLockAccumX + scrollPreLockAccumY >= Self.scrollAxisLockWindow {
                    let ratio = Self.scrollAxisLockRatio
                    if scrollPreLockAccumX >= scrollPreLockAccumY * ratio {
                        scrollAxisLock = .horizontal
                        lockedDy = 0
                    } else if scrollPreLockAccumY >= scrollPreLockAccumX * ratio {
                        scrollAxisLock = .vertical
                        lockedDx = 0
                    }
                    // Neither axis dominates, so the drag is diagonal: stay
                    // omnidirectional for the rest of the gesture.
                    scrollAxisResolved = true
                }
            }
        }

        // Content follows the finger by default; reversed, it moves opposite,
        // as a classic scroll wheel does.
        let sign = reverseScrollDirection ? -1.0 : 1.0
        let outDx = sign * lockedDx
        let outDy = sign * lockedDy
        // Sample velocity only from frames at least `minVelocityDt` apart. A
        // Bluetooth batch puts several frames microseconds apart (see
        // `BatchFramePacer`), so `delta / dt` there runs 10–100 times the real
        // speed, and the peak would latch onto it and seed a runaway coast.
        // The real touch cadence on Bluetooth is about 5.6 ms. `lastMotionTime`
        // still updates from burst frames, so brake detection is unaffected.
        // Both use the raw centroid delta, not the axis-locked one.
        if dt >= Self.minVelocityDt {
            recentVelocities.append((time: now, v: CGVector(dx: sign * dx / dt, dy: sign * dy / dt)))
            recentVelocities.removeAll { now - $0.time > Self.peakVelocityWindow }
        }
        if dx != 0 || dy != 0 {
            lastMotionTime = now
        }
        // Skip dead frames, or a stationary two-contact palm would post 100
        // no-op scrolls per second. After an axis lock, a frame of pure
        // off-axis wobble also has nothing to post.
        if outDx == 0 && outDy == 0 { return .none }
        if lastScrollPhase == .ended {
            // Nothing posted yet: open with `.began` carrying the motion.
            pendingBeganDx += outDx
            pendingBeganDy += outDy
            guard Swift.max(abs(pendingBeganDx), abs(pendingBeganDy)) >= 1,
                  !scrollRestarted || scrollAxisResolved else { return .none }
            defer { pendingBeganDx = 0; pendingBeganDy = 0 }
            scrollLatchedAxis = abs(pendingBeganDx) > abs(pendingBeganDy) ? .horizontal : .vertical
            scrollStretchX = 0
            scrollStretchY = 0
            scrollRestarted = false
            lastScrollPhase = .began
            return .scrollDelta(dx: pendingBeganDx, dy: pendingBeganDy, phase: .began)
        }
        lastScrollPhase = .changed
        return .scrollDelta(dx: outDx, dy: outDy, phase: .changed)
    }

    /// The frame where every finger has lifted: release velocity, then the closing intent (tap, right-click, or an envelope's end).
    private mutating func processAllLifted(
        tapToClick: Bool,
        twoFingerRightClick: Bool,
        threeFingerDrag: Bool,
        now: TimeInterval
    ) -> Intent {
        let priorMode = mode
        let priorPhase = lastScrollPhase
        let priorKind = twoFingerKind
        let priorPinchPhase = pinchPhase
        let priorRotatePhase = rotatePhase
        let tap = tapToClick && (priorMode == .pointer || priorMode == .pending)
            && now - tapStart <= Self.tapMaxDuration
            && tapMaxDelta < Self.tapMaxDistance
        // Computed before `reset()` clears `tapStart`. Still being `.undecided`
        // at teardown proves motion stayed under `twoFingerDecideDistance`.
        let secondaryTap = twoFingerRightClick && twoFingerTapEligible
            && maxContactsThisSequence == 2
            && priorMode == .scroll && priorKind == .undecided
            && now - tapStart <= Self.twoFingerTapMaxDuration
        threeFingerTapMiss = threeFingerDrag && maxContactsThisSequence >= 3
            && priorMode != .drag ? (threeFingerMissReason ?? "other") : nil
        if scrollDroppedToOneContactAt != 0 {
            // The drop already snapshotted everything while samples were
            // fresh. Recomputing here would lose it: the grace-window frames
            // skipped velocity sampling, so `recentVelocities` is empty.
            releaseVelocity = scrollVelocityAtDrop
            releaseSuppressedByRecency = suppressedByRecencyAtDrop
            releaseFrameGap = frameGapAtDrop
            releaseMotionGap = motionGapAtDrop
        } else if priorMode == .scroll {
            let k = releaseKinematics(now: now)
            releaseVelocity = k.velocity
            releaseSuppressedByRecency = k.suppressedByRecency
            releaseFrameGap = k.frameGap
            releaseMotionGap = k.motionGap
        } else {
            let k = releaseKinematics(now: now)
            releaseVelocity = k.velocity
            releaseSuppressedByRecency = k.suppressedByRecency
        }
        reset()
        if priorMode == .drag { return .dragUp }
        switch priorMode {
        // Must precede the pan-ended case: pinch and rotate leave
        // `lastScrollPhase` alone, so only this case closes their envelopes.
        // They close independently; either, both, or neither may be open.
        case .scroll where priorPinchPhase != .ended || priorRotatePhase != .ended:
            return .twoFingerGesture(
                magnify: priorPinchPhase != .ended ? GestureDelta(value: 0, phase: .ended) : nil,
                rotate: priorRotatePhase != .ended ? GestureDelta(value: 0, phase: .ended) : nil)
        case .scroll where priorPhase != .ended:
            return .scrollDelta(dx: 0, dy: 0, phase: .ended)
        case .scroll where secondaryTap:
            return .secondaryClick
        case .pointer where tap, .pending where tap:
            return .tapClick
        default:
            return .none
        }
    }

    /// The first contact of a sequence: enter pending, and warp at once in absolute mode.
    private mutating func beginSequence(
        first: (id: Int, screen: CGPoint),
        absoluteTouch: Bool,
        now: TimeInterval
    ) -> Intent {
        mode = .pending
        lastPositions = [first.id: first.screen]
        tapAnchor = first.screen
        tapStart = now
        tapMaxDelta = 0
        if absoluteTouch {
            // Warp on contact-down; absolute mode can't wait for `.pointer`
            // the way relative mode does (see `processPending`).
            absolutePrimaryContactID = first.id
            absoluteLastWarpedTo = first.screen
            return .pointerWarp(to: first.screen)
        }
        return .none
    }

    /// A wound-down scroll's lingering fingers: hold, release, or nil when new fingers start a fresh sequence.
    private mutating func processWoundDownHold(
        contacts: [(id: Int, screen: CGPoint)],
        now: TimeInterval
    ) -> Intent? {
        let overlapsOldContacts = contacts.contains { lastPositions[$0.id] != nil }
        if contacts.isEmpty {
            reset()
            return Intent.none
        }
        if !overlapsOldContacts {
            // Entirely new fingers start a fresh sequence from idle, with a
            // new onset delay and tap clock.
            scrollWoundDown = false
            scrollWoundDownExpiresAt = 0
            lastPositions.removeAll(keepingCapacity: true)
            scrollDroppedToOneContactAt = 0
            mode = .idle
            twoFingerKind = .undecided
            resetScrollAxisLock()
            lastScrollPhase = .ended
            // Fall through.
        } else if now >= scrollWoundDownExpiresAt {
            // Backstop: the gesture's fingers are still down after the whole
            // window, so a lift frame was likely lost. Release the hold and
            // resume as a plain pointer, not a fresh `.pending`. A new
            // `tapStart` would make the lingering finger tap-eligible, and
            // pan, lift one, rest, lift would fire a phantom click. The stale
            // `tapStart` fails the duration check and blocks any tap.
            scrollWoundDown = false
            scrollWoundDownExpiresAt = 0
            scrollDroppedToOneContactAt = 0
            twoFingerKind = .undecided
            resetScrollAxisLock()
            lastScrollPhase = .ended
            mode = .pointer
            tapAnchor = nil
            lastPositions = Dictionary(
                contacts.prefix(1).map { ($0.id, $0.screen) },
                uniquingKeysWith: { first, _ in first })
            // The two-finger sequence never pinned an absolute primary. Clear
            // both so absolute pointing re-derives from this frame's contact
            // instead of chasing a stale id.
            absolutePrimaryContactID = nil
            absoluteLastWarpedTo = nil
            return Intent.none
        } else {
            return Intent.none
        }
        return nil
    }

    /// Three fingers landing together press the button; otherwise records why they didn't, and returns nil.
    private mutating func startThreeFingerDrag(
        contacts: [(id: Int, screen: CGPoint)],
        threeFingerDrag: Bool,
        rawPositions: [Int: CGPoint],
        absoluteTouch: Bool,
        now: TimeInterval
    ) -> Intent? {
        if threeFingerDrag, contacts.count == 3, mode == .pending || mode == .scroll,
           threeFingerMissReason == nil {
            let mm = contacts.compactMap { rawPositions[$0.id] }
            var closest = Double.infinity
            for i in mm.indices {
                for j in mm.indices where j > i {
                    closest = Swift.min(closest, hypot(mm[i].x - mm[j].x, mm[i].y - mm[j].y))
                }
            }
            let gestureBegan = mode == .scroll
                && (twoFingerKind != .undecided || lastScrollPhase != .ended)
            if now - tapStart > Self.threeFingerLandingWindow {
                threeFingerMissReason = "landedApart"
            } else if mm.count < 3 || closest < Self.threeFingerMinSpacingMM {
                threeFingerMissReason = "tooClose"
            } else if gestureBegan {
                threeFingerMissReason = "moved"
            } else {
                let lead = contacts[0]
                mode = .drag
                dragPrimaryID = lead.id
                dragFingerIDs = Set(contacts.map(\.id))
                dragCentroidIDs = dragFingerIDs
                dragCentroid = centroid(of: contacts.map(\.screen))
                lastPositions = [lead.id: lead.screen]
                return .dragDown(at: absoluteTouch ? lead.screen : nil)
            }
        }
        if threeFingerDrag, contacts.count > 3, mode != .drag, threeFingerMissReason == nil {
            threeFingerMissReason = "moreThanThree"
        }
        return nil
    }

    /// A second contact during pending or pointer: start the two-finger sequence, or nil to carry on.
    private mutating func escalateToTwoFingers(
        contacts: [(id: Int, screen: CGPoint)],
        twoFingerScroll: Bool,
        pinchZoom: Bool,
        rotate: Bool,
        twoFingerRightClick: Bool,
        threeFingerDrag: Bool,
        rawPositions: [Int: CGPoint],
        touchDiagonal: Double,
        onsetDelay: TimeInterval,
        now: TimeInterval
    ) -> Intent? {
        let anyTwoFingerGesture = twoFingerScroll || pinchZoom || rotate
            || twoFingerRightClick || threeFingerDrag
        if mode == .pending || mode == .pointer, contacts.count >= 2 {
            if anyTwoFingerGesture {
                // Pending can outlast the onset window while a finger rests
                // still, so time it directly.
                let firstFingerStill = mode == .pending
                    || (mode == .pointer && tapMaxDelta < Self.tapMaxDistance)
                let landedTogether = firstFingerStill
                    && now - tapStart <= Swift.max(onsetDelay, Self.twoFingerLandWindow)
                mode = .scroll
                let pair = Array(contacts.prefix(2))
                lastPositions = Dictionary(
                    pair.map { ($0.id, $0.screen) },
                    uniquingKeysWith: { first, _ in first })
                tapAnchor = nil  // tap is off the table once we go to two fingers
                twoFingerKind = (pinchZoom || rotate || twoFingerRightClick
                    || threeFingerDrag) ? .undecided : .pan
                twoFingerTapEligible = false
                if twoFingerRightClick, landedTogether,
                   let posA = rawPositions[pair[0].id], let posB = rawPositions[pair[1].id] {
                    twoFingerTapEligible =
                        hypot(posA.x - posB.x, posA.y - posB.y) >= Self.secondaryClickMinSpacingMM
                }
                lastPinchDistance = Self.distance(between: pair)
                undecidedOriginCentroid = centroid(of: pair.map(\.screen))
                undecidedOriginDistance = lastPinchDistance
                // Separation gate (see `rotateMinSeparationFraction`), computed
                // once: a rotating pair's separation stays roughly constant.
                rotateEligible = false
                if rotate, touchDiagonal > 0,
                   let posA = rawPositions[pair[0].id], let posB = rawPositions[pair[1].id]
                {
                    let rawSeparation = hypot(posA.x - posB.x, posA.y - posB.y)
                    rotateEligible = (rawSeparation / touchDiagonal) >= Self.rotateMinSeparationFraction
                }
                lastPairAngle = Self.angle(between: pair.sorted { $0.id < $1.id })
                undecidedCumulativeAngle = 0
                undecidedStartTime = now
                recentVelocities.removeAll()
                lastFrameTime = now
                lastMotionTime = 0
                // With discrimination on, `.began` waits for the commit.
                // `lastScrollPhase` stays `.ended`, so a lift before commit
                // emits no stray scroll end.
                if twoFingerKind == .undecided {
                    return Intent.none
                }
                // Reached only with `twoFingerScroll` on and every other
                // two-finger action off, where pan is decided at once. `.began`
                // waits for motion (see `pendingBeganDx`).
                pendingBeganDx = 0
                pendingBeganDy = 0
                return Intent.none
            } else if mode == .pointer {
                // No two-finger gesture is on: ignore the second contact and
                // keep tracking the first.
                if let first = contacts.first, lastPositions[first.id] == nil {
                    lastPositions[first.id] = first.screen
                }
            }
        }
        return nil
    }

    /// Clears the dominant-axis lock and its pre-lock accumulators. `reset()`
    /// and both wound-down re-entry paths call it. Only `.pan` reads the lock,
    /// so a stale value is inert, but clearing it keeps that from being an
    /// accident.
    private mutating func resetScrollAxisLock() {
        scrollAxisLock = nil
        scrollAxisResolved = false
        scrollPreLockAccumX = 0
        scrollPreLockAccumY = 0
        scrollLatchedAxis = nil
        scrollStretchX = 0
        scrollStretchY = 0
        scrollRestarted = false
    }

    /// Sensitivity times the speed-scaled gain, from a smoothed speed over
    /// successive samples. Shared by pointer motion and relative drags.
    private mutating func adaptivePointerGain(
        rawDx: Double, rawDy: Double, now: TimeInterval, sensitivity: Double
    ) -> Double {
        let dt = lastPointerSampleTime == 0 ? 0 : now - lastPointerSampleTime
        var gain = sensitivity
        if lastPointerSampleTime == 0 || dt > Self.pointerVelocityStaleGap {
            // No usable prior sample: a new sequence, or a pause long enough
            // that the old speed means nothing. Apply flat gain this frame.
            // `-1` marks no history, so the next frame seeds from its own
            // speed; averaging up from 0 would damp the first frames after
            // every pause and feel like hesitation.
            pointerSpeed = -1
        } else if dt >= Self.minVelocityDt {
            let instant = hypot(rawDx, rawDy) / dt
            if pointerSpeed < 0 {
                pointerSpeed = instant
            } else {
                pointerSpeed += (instant - pointerSpeed) * Self.pointerSpeedEmaFactor
            }
            gain = sensitivity * Self.pointerGain(forSpeed: pointerSpeed)
        }
        lastPointerSampleTime = now
        return gain
    }

    /// Clears all sequence state back to `.idle`. Called on full lift and on
    /// the non-overlapping wound-down escape. Pen arbitration feeds
    /// `process(contacts: [])` instead, so an open phase closes normally.
    mutating func reset() {
        mode = .idle
        twoFingerTapEligible = false
        threeFingerMissReason = nil
        maxContactsThisSequence = 0
        dragPrimaryID = nil
        dragFingerIDs = []
        dragCentroid = nil
        dragCentroidIDs = []
        lastPositions.removeAll(keepingCapacity: true)
        pointerSpeed = -1
        lastPointerSampleTime = 0
        absolutePrimaryContactID = nil
        absoluteLastWarpedTo = nil
        tapAnchor = nil
        tapStart = 0
        tapMaxDelta = 0
        lastScrollPhase = .ended
        pendingBeganDx = 0
        pendingBeganDy = 0
        scrollDroppedToOneContactAt = 0
        scrollVelocityAtDrop = .zero
        suppressedByRecencyAtDrop = false
        frameGapAtDrop = -1
        motionGapAtDrop = -1
        scrollWoundDown = false
        scrollWoundDownExpiresAt = 0
        twoFingerKind = .undecided
        resetScrollAxisLock()
        pinchInGesture = false
        rotateInGesture = false
        pinchPhase = .ended
        rotatePhase = .ended
        lastPinchDistance = 0
        undecidedOriginCentroid = .zero
        undecidedOriginDistance = 0
        rotateEligible = false
        lastPairAngle = 0
        undecidedCumulativeAngle = 0
        undecidedStartTime = 0
        recentGestureDeltas.removeAll()
        recentVelocities.removeAll()
        lastFrameTime = 0
        lastMotionTime = 0
    }

    private func centroid(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let n = Double(points.count)
        let sx = points.reduce(0) { $0 + $1.x } / n
        let sy = points.reduce(0) { $0 + $1.y } / n
        return CGPoint(x: sx, y: sy)
    }

    /// Release kinematics for a scroll gesture ending now: the flick velocity
    /// that seeds the coast, whether the recency gate suppressed it, and the
    /// frame and motion gaps for diagnostics. All three release sites call it
    /// (full lift, the 2→1 drop, and the wind-down snapshot), so the
    /// brake-versus-delivery-gap logic lives in one place.
    ///
    /// The plain recency gate (no motion within `momentumRecencyWindow` means a
    /// deliberate brake and no coast) is right when frames kept arriving and
    /// the finger held still. It is wrong when frames stopped arriving: a
    /// Bluetooth touch stream stalls 100–500 ms mid-flick, the finger keeps
    /// moving fast, and the user expects a coast. The gaps tell them apart. A
    /// brake keeps `frameGap` small while `motionGap` grows; a stall grows both
    /// together. When they track within `deliveryGapBrakeSlack` and the gap is
    /// a plausible stall (up to `releaseGapPlausibleMax`), the gate is skipped
    /// so the last good sample before the stall seeds the coast. A longer gap
    /// (the roughly 1 Hz Bluetooth housekeeping event, or idle between
    /// gestures) takes the normal path, where `frameGap` reads -1.
    /// - Parameter frameGapOverride: the true spacing from the previous frame,
    ///   for the 2→1 drop, which has already set `lastFrameTime` to `now`.
    ///   Other callers omit it.
    private func releaseKinematics(
        now: TimeInterval, frameGapOverride: TimeInterval? = nil
    ) -> (velocity: CGVector, suppressedByRecency: Bool,
          frameGap: TimeInterval, motionGap: TimeInterval) {
        let rawFrameGap = frameGapOverride ?? (lastFrameTime == 0 ? -1 : now - lastFrameTime)
        let rawMotionGap = lastMotionTime == 0 ? -1 : now - lastMotionTime
        let frameGap = rawFrameGap > Self.releaseGapPlausibleMax ? -1 : rawFrameGap
        let motionGap = rawMotionGap > Self.releaseGapPlausibleMax ? -1 : rawMotionGap

        let deliveryGap =
            frameGap > 0 && motionGap > 0
            && abs(frameGap - motionGap) <= Self.deliveryGapBrakeSlack

        let seed: CGVector
        if deliveryGap {
            // On a stall, the surviving samples are the `peakVelocityWindow`
            // slice before reports stopped. The fastest of them is the wrong
            // pick: on a short flick it lands on a mid-stroke peak and the
            // coast overshoots. The coast wants the speed when the stream cut
            // out, which is the newest non-zero sample. (On a long steady
            // flick the two match.) The `+ frameGap` margin keeps the filter
            // from losing that sample if it outlived a prune.
            seed = recentVelocities
                .filter {
                    now - $0.time <= Self.peakVelocityWindow + frameGap
                        && ($0.v.dx != 0 || $0.v.dy != 0)
                }
                .last?.v ?? .zero
        } else {
            // Normal release: a brief flick's fastest sample may not be its
            // last, so take the peak over the window, as `PanScrollTracker`
            // does.
            seed = recentVelocities
                .filter { now - $0.time <= Self.peakVelocityWindow }
                .max { hypot($0.v.dx, $0.v.dy) < hypot($1.v.dx, $1.v.dy) }?.v ?? .zero
        }
        let braked = !deliveryGap && now - lastMotionTime > Self.momentumRecencyWindow

        return (
            velocity: braked ? .zero : seed,
            suppressedByRecency: braked && (seed.dx != 0 || seed.dy != 0),
            frameGap: frameGap,
            motionGap: motionGap)
    }

    private static func distance(between contacts: [(id: Int, screen: CGPoint)]) -> Double {
        guard contacts.count >= 2 else { return 0 }
        let a = contacts[0].screen
        let b = contacts[1].screen
        return hypot(a.x - b.x, a.y - b.y)
    }

    /// Angle of the vector from the first contact to the second, in radians.
    /// Swapping the pair flips the result by π, unlike distance, so callers sort
    /// by contact id first. Otherwise a reordering from palm filtering or
    /// re-landed fingers reads as a half-turn.
    private static func angle(between sortedContacts: [(id: Int, screen: CGPoint)]) -> Double {
        guard sortedContacts.count >= 2 else { return 0 }
        let a = sortedContacts[0].screen
        let b = sortedContacts[1].screen
        return atan2(b.y - a.y, b.x - a.x)
    }

    /// Shortest signed angular difference from `old` to `new`, wrapped into
    /// (-π, π]. Plain subtraction breaks at the seam: a slow rotation past ±π
    /// would report a spurious near-2π jump.
    private static func wrappedDelta(from old: Double, to new: Double) -> Double {
        var delta = new - old
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta
    }
}
