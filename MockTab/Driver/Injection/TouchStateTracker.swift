// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import TabletKit

/// Rejects palm-sized capacitive contacts before they reach gesture tracking.
///
/// The IntuosV2 touch family (PTH-660 and PTH-860 — the latter's touch
/// maxima are the registry's own basis for the former's estimated ones, and
/// both share the same 0x21 report layout) reports the contact major and
/// minor axes for every touch slot. The units are device-specific, so this
/// filter is deliberately limited to that calibrated family rather than
/// applying an unsafe global threshold. A rejected slot remains rejected
/// until it falls below a lower threshold or lifts, which keeps a noisy palm
/// footprint from flapping into a finger gesture.
struct TouchPalmRejector {

    struct Result {
        let acceptedIDs: Set<Int>
        let newlyRejectedIDs: [Int]
        let newlyAcceptedIDs: [Int]
    }

    /// PTH-660 and PTH-860 USB and Bluetooth Classic PIDs. Injection normally
    /// sees the canonical USB PID, but accepting both keeps the filter
    /// correct before canonicalization and in isolated tests.
    private static let calibratedProductIDs: Set<Int> = [0x0357, 0x0360, 0x0358, 0x0361]

    /// Live PTH-660 capture: a palm begins at Width/Height 6/7, while the
    /// finger-sized fragments alongside it remain 1–4. The descriptor's
    /// logical maxima (41 × 31) are not physical millimetres, so a threshold
    /// inferred from those maxima was invalid; use both observed raw axes.
    private static let rejectAxisAtOrAbove = 5
    /// A rejected contact only returns once both axes shrink below the
    /// threshold, avoiding size-noise flapping during a palm contact.
    private static let acceptAxisAtOrBelow = 3

    private var rejectedIDs: Set<Int> = []

    static func supports(productID: Int) -> Bool {
        calibratedProductIDs.contains(productID)
    }

    private static func isPalm(major: Int?, minor: Int?) -> Bool {
        [major, minor].compactMap { $0 }.contains { $0 >= rejectAxisAtOrAbove }
    }

    private static func isFingerSized(major: Int?, minor: Int?) -> Bool {
        let axes = [major, minor].compactMap { $0 }
        return !axes.isEmpty && axes.allSatisfy { $0 <= acceptAxisAtOrBelow }
    }

    mutating func filter(
        contacts: [(id: Int, major: Int?, minor: Int?)],
        productID: Int
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
        var newlyAcceptedIDs: [Int] = []
        acceptedIDs.reserveCapacity(contacts.count)

        for contact in contacts {
            if rejectedIDs.contains(contact.id) {
                // A report missing its footprint must not let a previously
                // classified palm back into an active gesture.
                guard Self.isFingerSized(major: contact.major, minor: contact.minor) else {
                    continue
                }
                rejectedIDs.remove(contact.id)
                newlyAcceptedIDs.append(contact.id)
                acceptedIDs.insert(contact.id)
                continue
            }

            guard Self.isPalm(major: contact.major, minor: contact.minor) else {
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

/// Translates a per-frame set of capacitive contacts into a single sticky-mode
/// gesture intent (pointer drag vs. two-finger scroll vs. tap-click).
///
/// "Sticky mode" means once a touch sequence picks a mode at second-finger-down,
/// it stays in that mode until *all* fingers lift.  Wacom's official driver
/// switches modes mid-stream whenever a finger is added or removed; users
/// uniformly describe the result as twitchy.  This tracker chooses once and
/// commits.
///
/// Owned by `InputInjector`.  All state is mutable; the injector is the only
/// caller and is single-threaded for touch (HIDThread).  Reads no global state
/// — everything it needs is passed via `process(...)` so tests can drive it.
struct TouchStateTracker {

    enum Mode {
        case idle
        case pending        // contact(s) down, gesture not yet committed
        case pointer        // single contact moving the cursor
        case scroll         // two contacts: pan scroll and/or pinch-zoom
    }

    /// Sticky two-finger sub-mode once significant motion is seen. `.pan` vs
    /// `.gesture` is chosen once per sequence and doesn't change once
    /// committed.
    ///
    /// Within `.gesture`, which of pinch/rotate are in play
    /// (`pinchInGesture`/`rotateInGesture`) is *not* frozen at commit: a
    /// component that wasn't qualified there can join later in the same
    /// sequence, so a pinch that grows a twist becomes a concurrent
    /// pinch+rotate instead of resolving pinch-only. (It was frozen through
    /// 2026-08-27, which is what made simultaneous zoom-and-rotate so hard to
    /// invoke — the evidence for the second gesture almost never arrives in
    /// the same frame as the first. See the late-join block in `process`.)
    /// Joining is one-way: a component that has begun is never dropped
    /// mid-sequence, because retracting it means posting an `.ended` that
    /// apps read as the gesture finishing.
    ///
    /// `.pan` is still exclusive with `.gesture`: translating the centroid
    /// (pan) is a fundamentally different action from the fingers moving
    /// relative to *each other* in place (pinch/rotate), and a real trackpad
    /// treats them exclusively too. Pinch and rotate are not exclusive with
    /// each other — see `pinchInGesture`/`rotateInGesture`.
    enum TwoFingerKind {
        case undecided
        case pan
        case gesture
    }

    enum Intent: Equatable {
        case none
        /// Move the cursor by (dx, dy) screen points, optionally posting a click
        /// at the move's destination when the gesture finishes as a tap.
        case pointerMove(dx: Double, dy: Double)
        /// Absolute-mode counterpart to `pointerMove`: warp the cursor
        /// directly to this screen point (already touch-area→display
        /// mapped) rather than moving it by a delta. Only emitted when
        /// `absoluteTouch` is true — see `process(...)`'s doc comment.
        case pointerWarp(to: CGPoint)
        /// Tap-to-click: a touch sequence that began and ended on roughly the
        /// same point within `tapMaxDuration`.  Posted as a single left click.
        case tapClick
        /// Two-finger scroll delta in screen points + the scroll phase
        /// (CG `kCGScrollWheelEventScrollPhase` values: 1=Began, 2=Changed,
        /// 4=Ended).  Sign convention follows the natural-scrolling setting.
        case scrollDelta(dx: Double, dy: Double, phase: ScrollPhase)
        /// Smart Zoom: two-finger double-tap, posted as a single one-shot
        /// zoom-to-fit event — no phase envelope, unlike `twoFingerGesture`.
        case smartZoom
        /// Pinch-zoom and/or two-finger rotate, independently — a real
        /// trackpad can magnify and rotate at once (see `TwoFingerKind`'s
        /// doc comment), so this carries one optional, independently
        /// phase-bracketed component per gesture rather than forcing a
        /// choice between them. `nil` means that gesture isn't part of this
        /// touch's committed set at all (see `pinchInGesture`/
        /// `rotateInGesture`) *or* it is, but has nothing new to report this
        /// frame (its own `.changed` phase carries no zero-delta frames,
        /// same as the exclusive design this replaced) — the receiving
        /// phase field on the non-nil side is what actually opens/closes
        /// each stream; a still-active component simply isn't present in a
        /// zero-delta frame.
        ///
        /// `magnify.magnification` is the exact relative growth of
        /// inter-finger distance this frame — (newDistance / oldDistance) - 1
        /// — which is what a real trackpad's magnify gesture reports, and
        /// what makes per-frame deltas compound to the correct total scale
        /// factor (Π(1 + dᵢ) telescopes to distance_final / distance_initial).
        /// Fingers spreading → positive.
        ///
        /// `rotate.rotation` is this frame's change in the pair's angle, in
        /// radians, sign-corrected to match the actual direction of finger
        /// twist as the user perceives it on screen — hardware-confirmed
        /// 2026-08-08 that raw `atan2` reads backwards here (screen
        /// coordinates are y-down, which flips its usual y-up handedness).
        /// Left in radians deliberately: the CGEvent field's actual expected
        /// unit is unverified (see `postTouchRotate`'s doc comment), so any
        /// unit conversion belongs at the posting layer, not baked into this
        /// tracker's internal math.
        case twoFingerGesture(magnify: GestureDelta?, rotate: GestureDelta?)
    }

    /// A pinch or rotate component's per-frame value and phase — same shape
    /// for both, disambiguated by which `twoFingerGesture` argument label
    /// it's under (`value` is a magnification for `magnify`, radians for
    /// `rotate`). A plain tuple can't be used here: enum associated values
    /// need a nominal `Equatable` type to synthesize `Intent`'s conformance.
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

    /// Per-contact last screen-space position, keyed by contact id.  Used to
    /// compute the per-frame delta.  In `.scroll` mode the centroid of the
    /// contacts is what drives the delta — two-finger spread/rotate is
    /// deliberately ignored (Phase 2 territory).
    private var lastPositions: [Int: CGPoint] = [:]

    /// Smoothed screen-space speed (points/sec) for `.pointer` mode, feeding
    /// `TouchStateTracker.pointerGain`. A single frame's `delta/dt` is too
    /// noisy to drive a gain curve directly — at slow sweep speeds a finger
    /// can advance ~1 device unit per frame, so instantaneous velocity flaps
    /// between 0 and 1 unit/frame's worth of speed. This exponential moving
    /// average smooths that out while still tracking real speed changes
    /// within a couple of frames. `-1` means "no history": set on lift
    /// (`reset()`) and after a stale gap (`pointerVelocityStaleGap`), it
    /// tells the next sample to seed directly from its own instant speed
    /// rather than EMA-ing up from 0 — the latter would damp the first
    /// couple of frames after every pause, however fast the actual resumed
    /// motion is.
    private var pointerSpeed: Double = -1

    /// In `absoluteTouch` mode, the contact id that started this `.pointer`
    /// sequence — deliberately re-read as `contacts.first` only when this is
    /// nil, not every frame. Relative mode tolerates `.first` changing
    /// mid-sequence because a new id's first delta is defined as zero (see
    /// `lastPositions[first.id] ?? first.screen`); absolute mode has no
    /// delta to zero out, so if a second finger landed and briefly sorted
    /// ahead of the driving one, re-deriving "the" contact from `.first`
    /// would warp the cursor straight to it. Reset alongside `tapAnchor` and
    /// `lastPositions` in `reset()`; irrelevant (never set) when
    /// `absoluteTouch` is false.
    private var absolutePrimaryContactID: Int?
    /// Last screen position this sequence has already warped the cursor to
    /// in `absoluteTouch` mode — a still finger must not re-warp every
    /// frame (that's ~100 identical `.mouseMoved` CGEvents/sec, the same
    /// class of waste the scroll case's dead-frame skip exists to avoid).
    /// Warping once per sequence regardless of motion is still needed for
    /// the tap-position fix, so this tracks "have we ever warped" and "to
    /// where", not just a this-frame delta. `nil` means no warp has been
    /// emitted yet this sequence — the case that must always warp, even
    /// with zero motion, so `.tapClick`'s "click at current cursor
    /// position" lands correctly.
    private var absoluteLastWarpedTo: CGPoint?
    /// Wall-clock time of the last `.pointer` sample, for staleness detection
    /// and computing `dt` for the `pointerSpeed` EMA.
    private var lastPointerSampleTime: CFAbsoluteTime = 0

    /// First-frame screen position for tap-to-click detection.  Only the
    /// primary contact (id of the first finger down) is tracked.
    private var tapAnchor: CGPoint?
    private var tapStart: CFAbsoluteTime = 0
    /// Largest distance the primary contact has moved from `tapAnchor` during
    /// this sequence; if it exceeds `tapMaxDistance` a tap is no longer
    /// possible (sequence has become a drag).
    private var tapMaxDelta: Double = 0

    /// Last-emitted scroll phase for `.pan`, used to ensure we emit a single
    /// `.ended` when the last contact lifts. Pinch/rotate track their own
    /// phases separately — see `pinchPhase`/`rotatePhase`.
    private var lastScrollPhase: ScrollPhase = .ended

    /// When a committed `.pan` scroll first dropped below two contacts, or 0
    /// while two are present. Drives `scrollSingleContactGrace`.
    private var scrollDroppedToOneContactAt: CFAbsoluteTime = 0
    /// The flick velocity captured at the instant a `.pan` first dropped to one
    /// contact — i.e. from the last frame both fingers were down and their
    /// samples were still fresh. The wind-down that fires `scrollSingleContactGrace`
    /// later can't recompute this: by then every sample is older than
    /// `peakVelocityWindow`, so a recompute always yields zero and the flick
    /// never coasts. `.zero` when the drop was a deliberate brake (no recent
    /// motion) — same rule as the all-fingers-lifted path.
    private var scrollVelocityAtDrop: CGVector = .zero
    /// Diagnostic snapshots taken alongside `scrollVelocityAtDrop`, for the
    /// same reason: the `contacts.isEmpty` release path and the wind-down both
    /// fire too late to measure these meaningfully. `suppressedByRecencyAtDrop`
    /// feeds `releaseSuppressedByRecency`; the two gaps feed `releaseFrameGap`/
    /// `releaseMotionGap`.
    private var suppressedByRecencyAtDrop = false
    private var frameGapAtDrop: CFAbsoluteTime = -1
    private var motionGapAtDrop: CFAbsoluteTime = -1
    /// Set once a `.scroll` sequence has been wound down early (see
    /// `scrollSingleContactGrace`) but not every finger has lifted yet.
    /// While true, `process` emits nothing for any non-empty frame whose
    /// contacts overlap the wound-down gesture's — the gesture is finished;
    /// its remaining finger(s) must not resurrect it. Cleared by the real
    /// `reset()` on all-fingers-lifted, by an entirely new contact set
    /// (`scrollWoundDownExpiresAt`'s frame), or by a wall-clock backstop, so a
    /// never-arriving empty frame can't latch touch off.
    private var scrollWoundDown = false
    /// Wall-clock backstop for `scrollWoundDown`: if no clean exit has cleared
    /// it by this time, clear it anyway. Guards against an all-fingers-lifted
    /// frame that never arrives (the exact failure this whole change targets)
    /// latching touch permanently.
    private var scrollWoundDownExpiresAt: CFAbsoluteTime = 0

    /// Sticky pan vs gesture (pinch and/or rotate) once motion crosses
    /// `twoFingerDecideDistance`.
    private var twoFingerKind: TwoFingerKind = .undecided

    /// Dominant-axis lock for a committed `.pan`, mirroring
    /// `PanScrollTracker.axisLock`. Rationale is the same — a slight diagonal
    /// drift bleeds an off-axis component into the stream — but the stakes are
    /// higher here: touch scroll runs phase-free (`twoFingerScrollMomentum`
    /// off), so macOS routes each event independently and a nested
    /// vertically-scrollable view (Finder column view) swallows a horizontal
    /// scroll that carries any vertical component at all. Locking to one axis
    /// and zeroing the other for the rest of the gesture keeps pure-axis
    /// events pure. `nil` = undecided; only ever set once `twoFingerKind ==
    /// .pan`. A genuinely diagonal drag never crosses `scrollAxisLockRatio`
    /// and stays omnidirectional (`scrollAxisResolved` true, `scrollAxisLock`
    /// still nil).
    private enum ScrollAxis { case vertical, horizontal }
    private var scrollAxisLock: ScrollAxis?
    /// True once the lock decision has been made — committed to an axis, or
    /// deliberately abandoned for a diagonal drag. Stops the pre-lock
    /// accumulators from being re-evaluated every frame for the rest of the
    /// gesture.
    private var scrollAxisResolved = false
    /// Pre-lock unsigned centroid travel per axis, summed until their total
    /// reaches `scrollAxisLockWindow`.
    private var scrollPreLockAccumX = 0.0
    private var scrollPreLockAccumY = 0.0

    /// Whether the live two-finger sequence has committed to pan (scroll), for
    /// the injector's stuck-scroll diagnostic only — keeps the probe out of
    /// this type. Meaningless outside `.scroll` mode.
    var committedToPan: Bool { twoFingerKind == .pan }

    /// Set true by exactly the `process()` call that wound a `.pan` down early
    /// (`scrollSingleContactGrace`), for the injector's `scrollWindDowns`
    /// counter. Read-and-clear: the injector zeroes it after each frame.
    var scrollWoundDownThisFrame = false

    /// Whether a wound-down `.pan` is currently in its post-wind-down hold
    /// (gesture finished, its finger(s) still lingering). Mode stays `.scroll`
    /// through the hold, so the injector's stuck-scroll diagnostic must skip
    /// these frames — they're the fix *working*, not the bug.
    var isHoldingWoundDownScroll: Bool { scrollWoundDown }
    /// Whether pinch/rotate are part of the current `.gesture` sequence's
    /// committed set — fixed at the commit decision, not re-evaluated per
    /// frame (see `TwoFingerKind`'s doc comment). Meaningless while
    /// `twoFingerKind != .gesture`.
    private var pinchInGesture = false
    private var rotateInGesture = false
    /// Independent phase envelopes for the pinch and rotate components of a
    /// `.gesture` sequence — each opens with its own `.began` when that
    /// component is included at commit, and closes with its own `.ended` at
    /// teardown, regardless of what the other component is doing.
    private var pinchPhase: ScrollPhase = .ended
    private var rotatePhase: ScrollPhase = .ended
    /// Last inter-finger distance in screen points (pinch tracking).
    private var lastPinchDistance: Double = 0
    /// Centroid / distance at the start of an undecided two-finger sequence.
    /// Decision uses cumulative motion from these anchors, not per-frame deltas
    /// (slow pans never exceed the threshold in a single high-rate frame).
    private var undecidedOriginCentroid: CGPoint = .zero
    private var undecidedOriginDistance: Double = 0

    /// Whether the current two-finger sequence's contacts started far enough
    /// apart, relative to the touch surface, for rotate to even be a
    /// candidate. Computed once at escalation (see `process`) from raw
    /// device-unit positions, not screen points — screen-space separation
    /// for the same physical finger span changes with the user's touch-area
    /// crop and display size, which a fixed threshold must not be sensitive
    /// to. `false` whenever rotate is disabled, so it costs nothing when off.
    private var rotateEligible: Bool = false
    /// When the current two-finger sequence entered `.undecided` — the dwell
    /// clock for rotate-eligible sequences (see `rotateMinDwell`'s doc
    /// comment). Unused, and not meaningfully read, when rotate is off.
    private var undecidedStartTime: CFAbsoluteTime = 0
    /// Last frame's angle (radians, `atan2`) of the id-sorted two-contact
    /// pair. Doubles as the undecided sequence's origin angle (set once at
    /// escalation) and the per-frame delta baseline once committed.
    private var lastPairAngle: Double = 0
    /// Cumulative wrapped angle change (radians) since an undecided
    /// sequence's origin — the rotate analogue of `undecidedOriginCentroid`/
    /// `undecidedOriginDistance`. Summed per-frame rather than taken as
    /// `newAngle - originAngle` so a rotation exceeding π during the decide
    /// window still accumulates correctly instead of wrapping back on itself.
    private var undecidedCumulativeAngle: Double = 0
    /// Per-frame gesture signal over the last `lateJoinWindow`, for the
    /// late-join test only. Kept as a trailing window rather than a running
    /// total so the bar a joining component has to clear stays constant
    /// instead of climbing with the gesture's own duration.
    private var recentGestureDeltas:
        [(time: CFAbsoluteTime, scale: Double, tangential: Double, translation: Double)] = []

    /// Recent per-frame instantaneous velocities (points/second), each frame's
    /// raw `delta/dt` with a timestamp — the momentum-tail seed. An EMA was
    /// tried first and rejected: at `velocityAlpha = 0.20` it takes several
    /// frames to converge, and a real flick is often over in less time than
    /// that, so the EMA reports well under the finger's actual peak speed —
    /// exactly the "momentum falls short of a real trackpad" complaint. Using
    /// the fastest sample within a short recent window instead captures the
    /// peak even from a very brief flick, matching `PanScrollTracker`'s
    /// equivalent. Pruned to `peakVelocityWindow` each frame; tiny array,
    /// never holds more than a handful of samples at touch report rates.
    private var recentVelocities: [(time: CFAbsoluteTime, v: CGVector)] = []
    private var lastFrameTime: CFAbsoluteTime = 0
    /// Time of the last frame with nonzero motion. A real trackpad detects a
    /// deliberate brake — holding fingers still before lifting — and starts
    /// no momentum even if a fast sample is still sitting in `recentVelocities`
    /// from just before the brake. Gating release on *recent* motion instead
    /// of trusting the peak-velocity window alone catches that directly.
    private var lastMotionTime: CFAbsoluteTime = 0
    /// Captured at scroll-gesture end; read by the posting layer to start a
    /// momentum decay tail. Unused while the gesture is still active.
    private(set) var releaseVelocity: CGVector = .zero
    /// Diagnostic only: when the most recent release produced a zero
    /// `releaseVelocity`, which leg zeroed it — `true` if a fast sample was
    /// present but the recency gate (a deliberate brake, or a batched-delivery
    /// gap that looks like one) rejected it, `false` if the peak-velocity
    /// window was simply empty. Meaningless when `releaseVelocity` is nonzero.
    private(set) var releaseSuppressedByRecency = false
    /// Diagnostic only: at the most recent release, how long since the last
    /// `.scroll` frame of any kind (`releaseFrameGap`) and since the last one
    /// that actually moved (`releaseMotionGap`). Both large ⇒ frames stopped
    /// arriving (a delivery gap — bug B). Only the motion gap large ⇒ frames
    /// kept coming but stationary (a genuine brake). Set on every scroll
    /// release; -1 before the first.
    private(set) var releaseFrameGap: CFAbsoluteTime = -1
    private(set) var releaseMotionGap: CFAbsoluteTime = -1

    /// End time of the most recent qualifying two-finger tap, for Smart Zoom
    /// double-tap detection. Deliberately *not* cleared by `reset()` — every
    /// lift calls `reset()`, including the lift between the two taps of a
    /// double-tap, so this must survive it or the second tap could never see
    /// the first.
    private var lastTwoFingerTapEndTime: CFAbsoluteTime?

    // MARK: - Tunables

    /// Maximum drift (in screen points) that still counts as a tap.
    static let tapMaxDistance: Double = 8.0
    /// Maximum tap duration (seconds); longer touches become drags or scrolls.
    static let tapMaxDuration: CFAbsoluteTime = 0.30
    /// Onset delay: a touch sequence emits nothing until it has been down this
    /// long.  Two jobs: (1) a palm landing just before the pen tips down does so
    /// within this window, so the injector resets the tracker before the palm
    /// has moved the cursor; (2) a second finger landing within the window
    /// starts a scroll directly, without the first finger having dragged the
    /// cursor in the meantime.  Same trick trackpads use; the cost is pointer
    /// motion starting this late.
    ///
    /// Default lowered 0.12 → 0.04 (2026-08-27): a two-finger gesture from rest
    /// lands its fingers 1–3 frames (~10–30 ms) apart, so 40 ms covers job (2)
    /// with margin — reasoned, not measured.  Job (1) only ever covered
    /// palm-before-tip-down: a *hovering* pen takes `touchBusyHoldOff` (150 ms,
    /// longer than the old window) to confirm busy, and tip-down bypasses that
    /// hold-off.  What the window guards is a palm *drifting* the cursor before
    /// tip-down — not an irreversible action (a palm can't tap: drift exceeds
    /// `tapMaxDistance`; can't scroll: needs two contacts), and pen absolute
    /// positioning corrects the cursor on its next report.  Overridable per
    /// device via the `touchOnsetDelayMs` defaults key; the value reaches
    /// `process` through `InjectionSnapshot`.
    ///
    /// Setting it to 0 does not make the first frame move the cursor: the
    /// `.idle` frame returns `.none`, and the frame that clears the delay
    /// re-anchors `lastPositions` and also returns `.none`, so first motion is
    /// the third frame (~20 ms at container rate) and the first ~2 frames of
    /// travel are discarded, not replayed.  0 shrinks the dead span to that
    /// floor; it does not remove it.
    static let onsetDelay: CFAbsoluteTime = 0.04
    /// Motion (screen points) needed to commit pan vs pinch for a sequence.
    /// Slightly above finger-jitter so a sliding pan doesn't decide on noise.
    static let twoFingerDecideDistance: Double = 6.0
    /// Pinch/rotate qualify only when their own signal clearly exceeds
    /// centroid translation. Equal/noisy signal vs pan → stay pan (scroll)
    /// when pan is even available, `.none` otherwise (see `process`'s
    /// `twoFingerScroll` guard). This is the bar that protects "pan wins on
    /// ambiguity"; it does not compare pinch and rotate against each other —
    /// see `pinchNoiseFloor`/`rotateNoiseFloor` for that.
    static let pinchDominanceRatio: Double = 1.75
    /// Absolute floor (screen points, same unit as `twoFingerDecideDistance`)
    /// each of pinch and rotate must independently clear before qualifying,
    /// on top of beating pan by `pinchDominanceRatio`. Rotate's floor is
    /// deliberately the stricter of the two: a document that tilts during a
    /// clean zoom is a worse experience than a zoom that doesn't quite add
    /// rotation. Not hardware-tuned — chosen at `twoFingerDecideDistance`
    /// (the existing "not noise" bar) for pinch, 1.5× that for rotate;
    /// revisit once this can be measured directly. On its own this floor
    /// only screens out small-in-absolute-terms jitter; see
    /// `companionSuppressionRatio` for the case both floors clear but one
    /// signal is still negligible next to the other.
    static let pinchNoiseFloor: Double = twoFingerDecideDistance
    static let rotateNoiseFloor: Double = twoFingerDecideDistance * 1.5
    /// When both pinch and rotate independently clear their own floor, the
    /// smaller of the two is still suppressed as the larger one's incidental
    /// companion (jitter/drift, not a second real gesture) unless it reaches
    /// at least this fraction of the larger one's magnitude — verified
    /// against a real-capture example (a pinch with genuine incidental
    /// twist wobble: scale change 30, tangential motion 11, ratio 0.37 —
    /// below this threshold, so rotate is correctly suppressed there).
    /// Comparable signals (near this ratio or above) both survive, which is
    /// what makes true concurrent pinch+rotate possible — and is strictly
    /// more permissive to rotate than the exclusive dominance rule this
    /// replaced: a near-tie that used to hand pinch an outright win (e.g.
    /// tangential 25 vs scale 26) now clears suppression on both sides.
    static let companionSuppressionRatio: Double = 0.5
    /// How far back to look for the fastest recent sample when seeding
    /// momentum release velocity — matches `PanScrollTracker.peakVelocityWindow`.
    static let peakVelocityWindow: CFAbsoluteTime = 0.06
    /// Minimum frame spacing for a `delta/dt` sample to be trusted as a real
    /// velocity — see the `.scroll` case. Below the device's true touch cadence,
    /// above a Bluetooth burst's inter-frame gap.
    static let minVelocityDt: CFAbsoluteTime = 0.002
    /// EMA time-constant for `pointerSpeed`: smaller = smoother/slower to
    /// react, larger = snappier/noisier. 0.5 means each new sample pulls the
    /// smoothed speed roughly a third of the way to the instantaneous value
    /// at the device's native ~100Hz report rate — enough to kill the
    /// 1-unit/frame quantization noise seen in slow-sweep captures without
    /// perceptibly lagging a real speed change.
    static let pointerSpeedEmaFactor: Double = 0.5
    /// A gap this long since the last `.pointer` sample means the finger was
    /// effectively still or freshly landed; the smoothed speed is stale and
    /// must not carry forward into a new motion.
    static let pointerVelocityStaleGap: CFAbsoluteTime = 0.1
    /// Screen points/sec below which `pointerGain` treats motion as
    /// fine-placement speed (gain floor) — and above which it treats motion
    /// as a fast reposition (gain ceiling). Chosen so an ordinary, unhurried
    /// sweep across a typical display falls in the flat midrange between
    /// them, matching the existing "1.00x = one sweep, one crossing" mental
    /// model for normal-speed use; only the slow and fast tails are reshaped.
    static let pointerGainLowSpeed: Double = 30
    static let pointerGainHighSpeed: Double = 900
    /// Gain multiplier applied at/below `pointerGainLowSpeed` and at/above
    /// `pointerGainHighSpeed`, on top of the user's `sensitivity`. Mirrors
    /// libinput's adaptive-profile bounds (deceleration floor, acceleration
    /// ceiling), not copied verbatim — retuned much closer to 1.0 on the low
    /// end than libinput's mouse curve. Unlike a mouse, the whole touch
    /// surface maps to the whole screen (see the Cursor Speed caption): a
    /// floor as low as libinput's would mean a deliberate, unhurried sweep
    /// can no longer reach the far edge at 1.00x, recreating the exact
    /// "sweep doesn't cross the screen" complaint this feature exists
    /// alongside, not to reintroduce. The floor only bites at genuine
    /// micro-adjustment speeds now, below `pointerGainLowSpeed`.
    static let pointerGainFloor: Double = 0.85
    static let pointerGainCeiling: Double = 1.6

    /// Speed-dependent gain multiplier for `.pointer` mode, on a 0..1..∞
    /// scale where 1.0 is the flat, un-accelerated multiplier this replaces.
    /// Flat (1.0) between the two thresholds, linearly interpolated to
    /// `pointerGainFloor`/`pointerGainCeiling` outside them. `speed` is the
    /// smoothed screen-points/sec value from `pointerSpeed`, already past
    /// the EMA — this function itself is a pure lookup with no state.
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
    /// A lift is only treated as a flick-release if motion happened within
    /// this many seconds of it — otherwise the fingers were held still
    /// (braking) and release velocity is suppressed regardless of any fast
    /// sample still sitting in the peak-velocity window.
    static let momentumRecencyWindow: CFAbsoluteTime = 0.05
    /// Grace period after a committed `.pan` scroll drops from two contacts to
    /// one before the gesture is wound down. A brief 1-contact frame is normal
    /// mid-scroll — palm filtering churns the set, or one finger momentarily
    /// lifts — and the `.scroll` case tolerates it (see `lastPinchDistance`
    /// hold). But a `.pan` gesture kept alive on a *single* finger keeps
    /// emitting `scrollDelta` from that finger's own motion indefinitely: the
    /// user lifts one finger, keeps the other down, and every subsequent
    /// move — even an unrelated single-finger touch later — still scrolls the
    /// view. Once one finger has been gone this long the gesture is over;
    /// close it out and hold wound-down until all fingers actually lift.
    static let scrollSingleContactGrace: CFAbsoluteTime = 0.1
    /// Cumulative unsigned centroid travel (screen points) a committed `.pan`
    /// considers before deciding a dominant axis — the touch analogue of
    /// `PanScrollTracker.axisLockWindow`. Deliberately much shorter than the
    /// pen tracker's 26pt: a freeform diagonal *pen* pan (rotating the canvas
    /// with the Hand tool) is a real use case that needs room to reveal its
    /// curve; a freeform diagonal two-finger *scroll* is not, and every event
    /// emitted before the lock commits still carries the off-axis component
    /// that a phase-free stream lets a nested scroll view swallow (the whole
    /// point of this lock). Keep the unlocked prefix as small as still lets a
    /// genuine diagonal register.
    static let scrollAxisLockWindow: Double = 8.0
    /// Dominant-axis-to-other-axis ratio to commit the lock (~2:1 ≈ within
    /// 25° of true horizontal/vertical). Same value as
    /// `PanScrollTracker.axisLockRatio`. Below it on both legs the gesture is
    /// genuinely diagonal — give up on locking and stay omnidirectional for
    /// the rest of the gesture.
    static let scrollAxisLockRatio: Double = 2.0
    /// Wall-clock backstop clearing `scrollWoundDown` even if an
    /// all-fingers-lifted frame never arrives. Generous — a real gesture is
    /// long over well before this — but bounded, so a dropped lift frame can
    /// never latch touch permanently off.
    static let scrollWoundDownBackstop: CFAbsoluteTime = 2.0
    /// Above this, a release "gap" is the idle between two separate gestures
    /// (the ending frame arriving with the next touch), not a within-gesture
    /// stall — the release-gap diagnostics record -1 instead.
    static let releaseGapPlausibleMax: CFAbsoluteTime = 1.0
    /// Maximum hold duration for a two-finger contact to still count as a
    /// Smart Zoom tap rather than a rest. Deliberately does *not* need a
    /// separate max-deviation check: a still-`.undecided` teardown already
    /// guarantees both total centroid translation and total inter-finger
    /// distance change stayed under `twoFingerDecideDistance` — that's the
    /// same guard that keeps `.undecided` from ever committing to pan or
    /// pinch in the first place. See the `.undecided` branch in `process`.
    static let twoFingerTapMaxDuration: CFAbsoluteTime = 0.30
    /// Maximum gap between the first tap's lift and the second tap's touch-
    /// down to count as a double-tap. Not derived from any real trackpad
    /// measurement — a tunable to revisit after hardware testing.
    static let twoFingerTapMaxGap: CFAbsoluteTime = 0.35
    /// Minimum finger separation, as a fraction of the touch surface's
    /// physical diagonal (millimeters — see `process`'s `rawPositions` doc
    /// comment for why raw device units would distort this), for rotate to
    /// be eligible at all. Below this, two fingers close together sweeping
    /// together reads as pan (the common case) — only wide-apart swiveling
    /// should ever be considered rotate. Sanity-checked but not hardware-
    /// verified: on the PTH-850 (325×203mm active area, ~383mm diagonal), a
    /// ~90mm thumb-index span is ≈23% of the diagonal; this threshold is
    /// set conservatively below that estimate to allow smaller spans and
    /// other tablet sizes, but needs checking against a second,
    /// differently-sized tablet before being trusted, and against real
    /// hands before being final.
    static let rotateMinSeparationFraction: Double = 0.15
    /// Minimum time a rotate-eligible two-finger sequence must sit undecided
    /// before *rotate specifically* is allowed to win the three-way decision.
    /// `decide` (6.0 points) is a tiny amount of physical motion — roughly
    /// half a millimeter of centroid drift at typical touch-surface-to-
    /// display scaling — so on the very first frame or two after two fingers
    /// land, landing noise alone can already exceed it in whichever
    /// direction the fingers happened to settle. Hardware feedback
    /// 2026-08-08 confirmed this empirically: "plant the fingers, hold for a
    /// moment, then twist" was the only reliable way to invoke rotate,
    /// meaning the fix belongs at the timing layer. Pan and pinch are not
    /// held back by this — only rotate-eligible sequences wait, and only
    /// rotate's own win condition is gated by it; obviously large, fast
    /// motion still bypasses the wait via `rotateDwellBypassDistance`, so a
    /// genuine fast pan/pinch on a wide-enough pair isn't stuck waiting on a
    /// clock it has no use for. Not independently hardware-tuned — chosen at
    /// the low end of a plausible "hold for a moment" range; revisit once
    /// this can be measured directly.
    static let rotateMinDwell: CFAbsoluteTime = 0.07
    /// Translation or scale change (screen points, same unit as `decide`)
    /// large enough to bypass `rotateMinDwell` entirely — an obviously fast
    /// pan or pinch shouldn't wait on a timer meant to disambiguate a
    /// *slow*, deliberate twist onset. Set to 2× `twoFingerDecideDistance`.
    static let rotateDwellBypassDistance: Double = 12.0
    /// Trailing window the late-join test sums its evidence over (see the
    /// late-join block in `process`).  Long enough to accumulate a deliberate
    /// motion at report rate (~25 frames at 100 Hz, comparable to what a
    /// commit sees), short enough that the bar doesn't drift upward as the
    /// gesture runs.  Not hardware-tuned — reasoned from the commit path's own
    /// timescale; revisit against a v12 capture's `twoFingerLateJoins`.
    static let lateJoinWindow: CFAbsoluteTime = 0.25

    // MARK: - Process

    /// Project an absolute touch contact (device units) into screen-space
    /// using the touch-area crop and the supplied display rect.  Touch uses
    /// its own area mapping — independent from the pen's — and ignores
    /// orientation and calibration in v1 (added later if real captures show
    /// they're needed).
    ///
    /// Returns `nil` for contacts whose raw position falls outside the crop
    /// rectangle.  Clamping out-of-bounds contacts to the rect edge would
    /// make the "deadzone" outside the crop still partially responsive:
    /// a finger touching outside one axis would pin the cursor to that
    /// axis's edge while the other axis still tracked normally.
    static func screenPoint(
        for contact: TouchContact,
        maxX: Int,
        maxY: Int,
        areaX: Double, areaY: Double,
        areaWidth: Double, areaHeight: Double,
        displayBounds: CGRect
    ) -> CGPoint? {
        let mx = Double(Swift.max(maxX, 1))
        let my = Double(Swift.max(maxY, 1))
        // Clamped, because a coordinate past the ceiling means the registry's
        // ceiling is too low, not that the finger left the surface — and the
        // crop test below would read the difference as "outside the crop" and
        // drop the contact, killing touch along that edge. Clamping keeps
        // crop semantics intact (a partial crop still rejects the region it
        // excludes) while making a low ceiling cost a thin dead band instead.
        let rx = Swift.min(Swift.max(Double(contact.x) / mx, 0), 1)
        let ry = Swift.min(Swift.max(Double(contact.y) / my, 0), 1)
        let w = Swift.max(areaWidth, 0.001)
        let h = Swift.max(areaHeight, 0.001)
        // Reject contacts outside the crop rect entirely.
        guard rx >= areaX, rx <= areaX + w,
              ry >= areaY, ry <= areaY + h
        else { return nil }
        let nx = (rx - areaX) / w
        let ny = (ry - areaY) / h
        return CGPoint(
            x: displayBounds.minX + nx * displayBounds.width,
            y: displayBounds.minY + ny * displayBounds.height)
    }

    /// Given a set of contacts already projected to screen-space, choose or
    /// continue a gesture mode and return the intent to execute.
    ///
    /// `tapToClick` and `twoFingerScroll` gate the optional behaviours;
    /// `reverseScrollDirection` flips the sign of the scroll delta.
    /// `sensitivity` multiplies pointer-mode movement (1.0 = identity).
    /// `pinchZoom` enables sticky pinch → synthesized magnify-gesture zoom (vs pan scroll).
    /// `smartZoom` enables two-finger double-tap → one-shot Smart Zoom.
    /// `rotate` enables sticky rotate (vs pan/pinch), gated additionally by
    /// `rotateEligible` (see that field). `rawPositions` are unprojected
    /// contact positions keyed by contact id, in physical millimeters (not
    /// device units, not screen points) — the separation gate is a physical
    /// finger-span threshold, and only mm keeps it consistent across a
    /// touch surface's X/Y axes, which are not equally scaled — only
    /// consulted when `rotate` is true, so callers not using rotate may
    /// pass `[:]`. `touchDiagonal` is the touch surface's diagonal in the
    /// same unit (millimeters). `absoluteTouch` switches `.pointer` mode
    /// from relative (trackpad-style delta, the default, gated by
    /// `sensitivity`/the speed-gain curve) to absolute (the finger's own
    /// position on the touch surface warps the cursor 1:1, mirroring what
    /// the tablet's active area does for the pen) — hidden `defaults`-only
    /// knob, no UI; see `TabletSettings.touchAbsoluteMode`.
    mutating func process(
        contacts: [(id: Int, screen: CGPoint)],
        tapToClick: Bool,
        twoFingerScroll: Bool,
        reverseScrollDirection: Bool,
        sensitivity: Double,
        pinchZoom: Bool = false,
        smartZoom: Bool = false,
        rotate: Bool = false,
        rawPositions: [Int: CGPoint] = [:],
        touchDiagonal: Double = 0,
        absoluteTouch: Bool = false,
        onsetDelay: CFAbsoluteTime = TouchStateTracker.onsetDelay,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Intent {

        // Per-frame diagnostic flag — set only by the wind-down return below.
        scrollWoundDownThisFrame = false

        // A scroll wound down early (one finger lifted, the other lingered —
        // see `scrollSingleContactGrace`). The phase envelope and
        // `releaseVelocity` were already handled at wind-down. Emit nothing
        // while the wound-down gesture's own finger(s) linger, but clear the
        // hold — never latch it — on any of: all fingers lifted (the real
        // teardown), a contact set that no longer overlaps the wound-down
        // gesture (these are new fingers, a fresh sequence), or the wall-clock
        // backstop. The overlap and backstop escapes exist precisely because
        // "the all-lifted frame never arrives" is the failure this change
        // targets — it must not become a way to wedge touch off entirely.
        if scrollWoundDown {
            let overlapsOldContacts = contacts.contains { lastPositions[$0.id] != nil }
            if contacts.isEmpty {
                reset()
                return .none
            }
            if !overlapsOldContacts {
                // Entirely new fingers — a genuinely fresh sequence. Full
                // reset so this frame starts from idle (onset delay, tap
                // clock, the lot).
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
                // Backstop: the wound-down gesture's own finger(s) are still
                // down after the whole backstop window — an all-lifted frame
                // was apparently lost. Release the hold, but resume as a plain
                // pointer, NOT a fresh `.pending`: seeding a new `tapStart`
                // here would make this lingering finger tap-eligible, so a
                // pan → lift-one → rest → lift would fire a phantom click.
                // Leaving `tapStart` stale means the isEmpty branch's
                // `now - tapStart <= tapMaxDuration` fails and no tap can.
                scrollWoundDown = false
                scrollWoundDownExpiresAt = 0
                scrollDroppedToOneContactAt = 0
                twoFingerKind = .undecided
                resetScrollAxisLock()
                lastScrollPhase = .ended
                mode = .pointer
                tapAnchor = nil
                lastPositions = Dictionary(uniqueKeysWithValues:
                    contacts.prefix(1).map { ($0.id, $0.screen) })
                // A two-finger sequence never ran absolute-mode's own
                // primary-pinning — clear both so `.pointer where
                // absoluteTouch` re-derives cleanly from this frame's
                // contact rather than chasing a stale id from before the
                // scroll started (or warping again to a position it
                // never actually warped to yet this sequence).
                absolutePrimaryContactID = nil
                absoluteLastWarpedTo = nil
                return .none
            } else {
                return .none
            }
        }

        // All fingers lifted — wrap up any in-progress gesture.  A sequence
        // that never outlived the onset delay can still be a tap (a tap is by
        // definition shorter than most onset windows).
        if contacts.isEmpty {
            let priorMode = mode
            let priorPhase = lastScrollPhase
            let priorKind = twoFingerKind
            let priorPinchPhase = pinchPhase
            let priorRotatePhase = rotatePhase
            let tap = tapToClick && (priorMode == .pointer || priorMode == .pending)
                && now - tapStart <= Self.tapMaxDuration
                && tapMaxDelta < Self.tapMaxDistance
            // Captured before `reset()` clears `tapStart` — the deviation
            // half of "was this a tap" is implicit: still being `.undecided`
            // at teardown already proves motion stayed under
            // `twoFingerDecideDistance` (see the tunable's doc comment).
            let twoFingerTap = smartZoom && priorMode == .scroll && priorKind == .undecided
                && now - tapStart <= Self.twoFingerTapMaxDuration
            let thisTapStart = tapStart
            if scrollDroppedToOneContactAt != 0 {
                // The gesture already dropped to one contact and everything was
                // snapshotted then, while samples were fresh. Recomputing here
                // loses it: the grace-window frames returned `.none` before the
                // velocity-sampling line, so `recentVelocities` has nothing
                // inside `peakVelocityWindow` and the gaps would read ~0.
                releaseVelocity = scrollVelocityAtDrop
                releaseSuppressedByRecency = suppressedByRecencyAtDrop
                releaseFrameGap = frameGapAtDrop
                releaseMotionGap = motionGapAtDrop
            } else if priorMode == .scroll {
                let peak = recentVelocities
                    .filter { now - $0.time <= Self.peakVelocityWindow }
                    .max { hypot($0.v.dx, $0.v.dy) < hypot($1.v.dx, $1.v.dy) }?.v ?? .zero
                let braked = now - lastMotionTime > Self.momentumRecencyWindow
                releaseVelocity = braked ? .zero : peak
                releaseSuppressedByRecency = braked && (peak.dx != 0 || peak.dy != 0)
                // The `contacts.isEmpty` frame that ends a scroll can arrive
                // seconds later, bundled with the *next* touch's first contact —
                // touch reports don't stream while nothing is on the surface.
                // A gap beyond `releaseGapPlausibleMax` is that inter-gesture
                // idle, not a within-gesture stall; record -1 (undefined)
                // rather than poisoning the diagnostic with idle time.
                let frameGap = lastFrameTime == 0 ? -1 : now - lastFrameTime
                let motionGap = lastMotionTime == 0 ? -1 : now - lastMotionTime
                releaseFrameGap = frameGap > Self.releaseGapPlausibleMax ? -1 : frameGap
                releaseMotionGap = motionGap > Self.releaseGapPlausibleMax ? -1 : motionGap
            } else {
                let peak = recentVelocities
                    .filter { now - $0.time <= Self.peakVelocityWindow }
                    .max { hypot($0.v.dx, $0.v.dy) < hypot($1.v.dx, $1.v.dy) }?.v ?? .zero
                let braked = now - lastMotionTime > Self.momentumRecencyWindow
                releaseVelocity = braked ? .zero : peak
                releaseSuppressedByRecency = braked && (peak.dx != 0 || peak.dy != 0)
            }
            reset()
            switch priorMode {
            // Must precede the generic pan-ended case below: pinch/rotate
            // also leave `lastScrollPhase` untouched (they track their own
            // phases), so without this case an open pinch/rotate envelope
            // would never close. Pinch and rotate close independently —
            // either, both, or (if the sequence never actually committed to
            // either) neither may be open here.
            case .scroll where priorPinchPhase != .ended || priorRotatePhase != .ended:
                return .twoFingerGesture(
                    magnify: priorPinchPhase != .ended ? GestureDelta(value: 0, phase: .ended) : nil,
                    rotate: priorRotatePhase != .ended ? GestureDelta(value: 0, phase: .ended) : nil)
            case .scroll where priorPhase != .ended:
                return .scrollDelta(dx: 0, dy: 0, phase: .ended)
            case .scroll where twoFingerTap:
                if let last = lastTwoFingerTapEndTime, thisTapStart - last <= Self.twoFingerTapMaxGap {
                    lastTwoFingerTapEndTime = nil
                    return .smartZoom
                }
                lastTwoFingerTapEndTime = now
                return .none
            case .pointer where tap, .pending where tap:
                return .tapClick
            default:
                return .none
            }
        }

        // First contact — hold in pending until the onset delay elapses, so
        // the opening frames of a sequence (where a palm smush or the second
        // scroll finger is still arriving) never move anything.
        if mode == .idle, let first = contacts.first {
            mode = .pending
            lastPositions = [first.id: first.screen]
            tapAnchor = first.screen
            tapStart = now
            tapMaxDelta = 0
            if absoluteTouch {
                // Warp immediately on contact-down — see the `.pending`
                // case below and `Intent.pointerWarp`'s doc comment for why
                // absolute mode can't wait for `.pointer` mode the way
                // relative mode does.
                absolutePrimaryContactID = first.id
                absoluteLastWarpedTo = first.screen
                return .pointerWarp(to: first.screen)
            }
            return .none
        }

        // Escalate to scroll once two contacts are present, if enabled.
        // From pending this means the fingers landed together (the normal
        // two-finger gesture) — the scroll starts with zero cursor drift.
        // Scroll, pinch, and rotate are alternate resolutions of the same
        // two-contact gesture, not scroll plus two features layered on top
        // of it — so escalation itself must not require `twoFingerScroll`
        // specifically. Any one of the three being enabled is enough to
        // start tracking; which one(s) can actually win is decided per-frame
        // below via each flag independently.
        let anyTwoFingerGesture = twoFingerScroll || pinchZoom || rotate || smartZoom
        if mode == .pending || mode == .pointer, contacts.count >= 2 {
            if anyTwoFingerGesture {
                mode = .scroll
                let pair = Array(contacts.prefix(2))
                lastPositions = Dictionary(uniqueKeysWithValues:
                    pair.map { ($0.id, $0.screen) })
                tapAnchor = nil  // tap is off the table once we go to two fingers
                twoFingerKind = (pinchZoom || rotate || smartZoom) ? .undecided : .pan
                lastPinchDistance = Self.distance(between: pair)
                undecidedOriginCentroid = centroid(of: pair.map(\.screen))
                undecidedOriginDistance = lastPinchDistance
                // Separation gate (see `rotateMinSeparationFraction`'s doc
                // comment): millimeter positions, computed once here, not
                // re-evaluated per frame — a rotate gesture's finger
                // separation is expected to stay roughly constant while the
                // angle changes.
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
                // Defer Began until pan/pinch/rotate commits when
                // discrimination is on — leave lastScrollPhase .ended so a
                // lift before commit does not emit a stray scroll Ended.
                if twoFingerKind == .undecided {
                    return .none
                }
                // Only reachable with twoFingerScroll on and pinchZoom/rotate/
                // smartZoom all off — the one case where pan is decided
                // immediately rather than discriminated.
                lastScrollPhase = .began
                return .scrollDelta(dx: 0, dy: 0, phase: .began)
            } else if mode == .pointer {
                // No two-finger gesture enabled at all: ignore the second
                // contact, keep pointer-tracking the first.
                if let first = contacts.first, lastPositions[first.id] == nil {
                    lastPositions[first.id] = first.screen
                }
            }
        }

        switch mode {
        case .pending:
            // Track motion for tap detection. Relative mode emits nothing
            // here and anchors at commit instead, so motion accumulated
            // during the window is discarded rather than replayed as a
            // cursor jump — there's no equivalent hazard in absolute mode
            // (a warp is never a "jump" relative to prior motion, it's just
            // where the finger is), and skipping the warp here would leave
            // the cursor stale for a tap that lifts before onset ever
            // elapses (see `Intent.pointerWarp`'s doc comment).
            if let first = contacts.first {
                if let anchor = tapAnchor {
                    tapMaxDelta = Swift.max(tapMaxDelta, hypot(
                        first.screen.x - anchor.x, first.screen.y - anchor.y))
                }
                lastPositions = [first.id: first.screen]
                if absoluteTouch {
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
            if now - tapStart >= onsetDelay {
                mode = .pointer
            }
            return .none

        case .scroll:
            let dt = now - lastFrameTime
            lastFrameTime = now
            // Centroid delta over the contacts present in both this frame and
            // the last.  Contacts with new ids (finger lifted and re-landed,
            // or upstream palm filtering churned the set) are seeded for the
            // next frame instead of stalling the gesture — losing both
            // original ids used to kill the scroll until every finger lifted.
            let current = Array(contacts.prefix(2))
            let tracked = current.filter { lastPositions[$0.id] != nil }
            let oldCentroid = centroid(of: tracked.compactMap { lastPositions[$0.id] })
            let newCentroid = centroid(of: tracked.map { $0.screen })
            // Hold last distance when a finger lifts mid-gesture (1-contact
            // frames). distance(between:) would be 0 and invent a huge scaleDelta.
            let newDistance = current.count >= 2
                ? Self.distance(between: current)
                : lastPinchDistance
            let oldDistance = lastPinchDistance
            let scaleDelta = newDistance - oldDistance
            lastPositions = Dictionary(uniqueKeysWithValues:
                current.map { ($0.id, $0.screen) })
            lastPinchDistance = newDistance

            // A committed pan that has dropped to a single contact for longer
            // than the grace window is finished — the user lifted one finger
            // and kept the other down. Without this it would keep emitting
            // `scrollDelta` from the lone finger's motion until every finger
            // lifted, so a later unrelated single-finger touch keeps scrolling
            // the view (`scrollWoundDown` blocks that resurrection). Capture
            // the flick velocity now, from the window when both fingers were
            // still moving, then close the phase envelope. Pinch/rotate are
            // excluded: `newDistance` collapses to nonsense on one contact, so
            // a 1-contact frame there is already ignored above.
            if twoFingerKind == .pan {
                if current.count >= 2 {
                    scrollDroppedToOneContactAt = 0
                } else {
                    if scrollDroppedToOneContactAt == 0 {
                        // First frame of the drop — both fingers were still
                        // down last frame, so `recentVelocities` is fresh
                        // right now. Snapshot the flick velocity *and* the
                        // frame/motion gaps here; the wind-down below fires too
                        // late for any of it to be recomputed meaningfully.
                        scrollDroppedToOneContactAt = now
                        let peak = recentVelocities
                            .filter { now - $0.time <= Self.peakVelocityWindow }
                            .max { hypot($0.v.dx, $0.v.dy) < hypot($1.v.dx, $1.v.dy) }?.v ?? .zero
                        let braked = now - lastMotionTime > Self.momentumRecencyWindow
                        scrollVelocityAtDrop = braked ? .zero : peak
                        suppressedByRecencyAtDrop = braked && (peak.dx != 0 || peak.dy != 0)
                        // `dt` is this frame's real spacing from the previous
                        // one (`lastFrameTime` was reassigned to `now` above,
                        // so recomputing here would read ~0). Cap idle gaps to
                        // -1 as on the isEmpty path.
                        frameGapAtDrop = dt > Self.releaseGapPlausibleMax ? -1 : dt
                        // `lastMotionTime == 0` means the scroll never had a
                        // moving frame — the gap is undefined, not enormous.
                        let mGap = lastMotionTime == 0 ? -1 : now - lastMotionTime
                        motionGapAtDrop = mGap > Self.releaseGapPlausibleMax ? -1 : mGap
                    }
                    if now - scrollDroppedToOneContactAt >= Self.scrollSingleContactGrace {
                        let priorPhase = lastScrollPhase
                        // All release diagnostics come from the drop-site
                        // snapshot — this frame is far too late to measure any
                        // of them (see `scrollVelocityAtDrop`).
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
                    // Inside the grace window: emit nothing rather than the
                    // lone finger's delta, so the symptom doesn't just shrink
                    // to the grace duration. `lastPositions`/`lastPinchDistance`
                    // were re-seeded above, so a returning second finger picks
                    // the pan back up cleanly.
                    return .none
                }
            }

            guard !tracked.isEmpty else { return .none }
            let dx = newCentroid.x - oldCentroid.x
            let dy = newCentroid.y - oldCentroid.y

            // Not just `pinchZoom || rotate`: an .undecided sequence reaches
            // here whenever any non-pan candidate was in play at escalation
            // (see `anyTwoFingerGesture`), and an already-committed .pinch/
            // .rotate sequence must keep being tracked here even if its flag
            // were somehow toggled off mid-gesture.
            if twoFingerKind != .pan {
                if twoFingerKind == .undecided {
                    // A 1-contact frame collapses the centroid onto that single
                    // finger, roughly half the finger separation away from the
                    // two-finger anchor — enough to clear the decide threshold
                    // on its own and commit a phantom pan. Wait for two contacts.
                    guard current.count >= 2 else { return .none }
                    // Cumulative motion since two-finger sequence start — not
                    // per-frame deltas, which stay tiny at high report rates.
                    let totalTranslation = hypot(
                        newCentroid.x - undecidedOriginCentroid.x,
                        newCentroid.y - undecidedOriginCentroid.y)
                    let totalScaleChange = abs(newDistance - undecidedOriginDistance)

                    // Tangential motion: angle change converted into the same
                    // unit (screen points) as the other two candidates, so it
                    // can share `twoFingerDecideDistance`/`pinchDominanceRatio`
                    // without a second, unrelated tunable. `rotateEligible`
                    // was decided once at escalation from raw device-unit
                    // separation — when it's false (or rotate is off), this
                    // stays exactly 0 and the block below behaves identically
                    // to the pinch-only two-way decision it replaced.
                    var totalTangentialMotion = 0.0
                    if rotate, rotateEligible {
                        let sortedPair = current.sorted { $0.id < $1.id }
                        let newAngle = Self.angle(between: sortedPair)
                        undecidedCumulativeAngle += Self.wrappedDelta(from: lastPairAngle, to: newAngle)
                        lastPairAngle = newAngle
                        totalTangentialMotion = abs(undecidedCumulativeAngle) * (newDistance / 2)
                    }

                    let decide = Self.twoFingerDecideDistance
                    // Tangential motion's own leg uses `rotateNoiseFloor`
                    // (9.0), not `decide` (6.0): rotate's actual
                    // qualification bar below is the higher floor, so
                    // ending the "still just landing noise" wait at the
                    // lower `decide` opened a dead zone — tangential motion
                    // between 6 and 9 stopped the wait but couldn't yet
                    // qualify, and neither pinch nor pan had cleared their
                    // own bars either, so the sequence fell through to the
                    // "neither qualified" pan default below regardless.
                    // That default only makes sense once every live
                    // candidate has had a real chance to clear its own bar
                    // — confirmed against hardware captures (2026-08-25)
                    // showing genuine rotate gestures losing the race to an
                    // instant, premature pan commit before tangential
                    // motion ever reached 9.
                    if totalScaleChange < decide, totalTranslation < decide,
                        totalTangentialMotion < Self.rotateNoiseFloor
                    {
                        return .none
                    }
                    // Dwell: a rotate-eligible sequence gets a brief grace
                    // period before rotate can win, because `decide` is tiny
                    // enough (see `rotateMinDwell`'s doc comment) that
                    // landing noise alone often clears it within the first
                    // frame or two — deciding this early is a coin flip, not
                    // a discrimination. Obviously large, fast motion bypasses
                    // the wait so a real pan/pinch on a wide-enough pair
                    // isn't held up by a clock meant for a slow twist onset.
                    // Pan and pinch are otherwise untouched by this: when
                    // rotate is off or the pair isn't eligible, this block
                    // never runs.
                    if rotate, rotateEligible,
                        now - undecidedStartTime < Self.rotateMinDwell,
                        totalTranslation < Self.rotateDwellBypassDistance,
                        totalScaleChange < Self.rotateDwellBypassDistance
                    {
                        return .none
                    }
                    // Pinch and rotate are evaluated independently — each
                    // just needs to beat pan's translation by
                    // `pinchDominanceRatio` (the bar that matters for "pan
                    // wins on ambiguity", including the anchored-finger-arc
                    // case — documented, intentional limitation, not a bug)
                    // and clear its own absolute noise floor. No *exclusive*
                    // bar between them: a real trackpad can magnify and
                    // rotate at once (see `TwoFingerKind`'s doc comment), so
                    // both may qualify together here.
                    var pinchQualifies = pinchZoom
                        && totalScaleChange > totalTranslation * Self.pinchDominanceRatio
                        && totalScaleChange >= Self.pinchNoiseFloor
                    var rotateQualifies = rotate && rotateEligible
                        && totalTangentialMotion > totalTranslation * Self.pinchDominanceRatio
                        && totalTangentialMotion >= Self.rotateNoiseFloor
                    // Independent floors alone let a much smaller companion
                    // signal ride along with a much larger dominant one — a
                    // real pinch's incidental angle jitter (or a real
                    // twist's incidental separation drift) can each clear
                    // their own floor without being a genuine second
                    // gesture. Suppress whichever signal is small relative
                    // to the other (below `companionSuppressionRatio` of
                    // it); comparable signals still both survive, which is
                    // what makes true concurrent pinch+rotate possible here.
                    // Symmetric and gentler than the exclusive dominance
                    // rule it replaced — a near-tie (say tangential 25 vs
                    // scale 26, which used to hand pinch an outright win)
                    // now clears suppression on both sides and fires both.
                    if pinchQualifies, rotateQualifies {
                        if totalTangentialMotion < totalScaleChange * Self.companionSuppressionRatio {
                            rotateQualifies = false
                        } else if totalScaleChange < totalTangentialMotion * Self.companionSuppressionRatio {
                            pinchQualifies = false
                        }
                    }
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
                    // Neither qualified. Pan isn't a candidate at all when
                    // twoFingerScroll is off — stay undecided (rather than
                    // lock in a fallback that will never be emitted) so a
                    // clearer pinch/rotate signal later in the same sequence
                    // can still win.
                    guard twoFingerScroll else { return .none }
                    lastScrollPhase = .began
                    twoFingerKind = .pan
                    return .scrollDelta(dx: 0, dy: 0, phase: .began)
                }
                if twoFingerKind == .gesture {
                    // Angle tracking runs for the whole sequence, not just while
                    // rotate is an active component: the late-join window below
                    // needs a per-frame angle delta even while rotate is
                    // dormant, and a gap in `lastPairAngle` would make the
                    // first delta after a join one large jump.
                    //
                    // Hold the last angle on a 1-contact frame instead of
                    // computing — same treatment `lastPinchDistance` gets
                    // above, for the same reason (a lone survivor's angle
                    // relative to nothing is meaningless and would invent a
                    // huge delta).
                    var frameAngleDelta = 0.0
                    if rotate, rotateEligible {
                        let sortedPair = current.count >= 2 ? current.sorted { $0.id < $1.id } : current
                        let newAngle = current.count >= 2 ? Self.angle(between: sortedPair) : lastPairAngle
                        frameAngleDelta = Self.wrappedDelta(from: lastPairAngle, to: newAngle)
                        lastPairAngle = newAngle
                    }

                    // Late join. The commit above picks the components from one
                    // frame's evidence; a hand that starts as a clean zoom and
                    // then adds a twist (or the reverse) produced that evidence
                    // *later*, and freezing the set at commit meant the second
                    // gesture could never arrive — the sequence had to be lifted
                    // and restarted. A trackpad has no such commit: it derives
                    // magnification and rotation independently every frame. This
                    // re-runs the qualification for whichever component isn't in
                    // play yet, so the second gesture joins when its evidence
                    // arrives.
                    //
                    // Measured over a trailing window, *not* cumulative since
                    // the sequence origin the commit uses. Since-origin totals
                    // make the join bar climb with the gesture's own length:
                    // `companionSuppressionRatio` asks the newcomer to reach
                    // half of a scale change that has been growing the whole
                    // time, so a twist that joins after ~20° a moment after
                    // commit needed ~46° once the zoom had been running (probed
                    // 2026-08-27, which is why this isn't the commit's own
                    // accumulators). A window keeps the bar constant, and "how
                    // hard am I twisting *now*" is the question this is actually
                    // asking.
                    //
                    // Latch-on only: a component that has begun is never removed
                    // mid-sequence. Removal would mean posting an `.ended` and
                    // then a fresh `.began` if it came back, and apps read that
                    // envelope churn as separate gestures. Growth is safe;
                    // retraction isn't.
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
                        var pinchQualifies = pinchZoom
                            && totalScaleChange > totalTranslation * Self.pinchDominanceRatio
                            && totalScaleChange >= Self.pinchNoiseFloor
                        var rotateQualifies = rotate && rotateEligible
                            && totalTangentialMotion > totalTranslation * Self.pinchDominanceRatio
                            && totalTangentialMotion >= Self.rotateNoiseFloor
                        // Same companion suppression as at commit, and it is
                        // what keeps this from firing on drift: over a long
                        // pinch the incidental angle wobble does eventually
                        // clear `rotateNoiseFloor` in absolute terms, but it
                        // stays far below `companionSuppressionRatio` of the
                        // scale change unless the user is really twisting.
                        if pinchQualifies, rotateQualifies {
                            if totalTangentialMotion < totalScaleChange * Self.companionSuppressionRatio {
                                rotateQualifies = false
                            } else if totalScaleChange < totalTangentialMotion * Self.companionSuppressionRatio {
                                pinchQualifies = false
                            }
                        }
                        let joinPinch = !pinchInGesture && pinchQualifies
                        let joinRotate = !rotateInGesture && rotateQualifies
                        if joinPinch || joinRotate {
                            if joinPinch { pinchInGesture = true; pinchPhase = .began }
                            if joinRotate { rotateInGesture = true; rotatePhase = .began }
                            // Open the new envelope with a zero delta and skip
                            // the already-active component's delta for this one
                            // frame, exactly as the commit path does. One frame
                            // at report rate is imperceptible; mixing a `.began`
                            // and a `.changed` for different components in one
                            // return is not worth the extra state.
                            return .twoFingerGesture(
                                magnify: joinPinch ? GestureDelta(value: 0, phase: .began) : nil,
                                rotate: joinRotate ? GestureDelta(value: 0, phase: .began) : nil)
                        }
                    }

                    // Each active component reports its own per-frame delta,
                    // independently of the other.
                    var magnify: GestureDelta?
                    if pinchInGesture, scaleDelta != 0, oldDistance > 0 {
                        // Exact relative growth this frame — see the
                        // `twoFingerGesture` doc comment for why this is the
                        // correct (not approximate) per-frame value for a
                        // multiplicative magnify stream.
                        pinchPhase = .changed
                        magnify = GestureDelta(value: scaleDelta / oldDistance, phase: .changed)
                    }
                    var rotateComponent: GestureDelta?
                    if rotateInGesture {
                        let delta = frameAngleDelta
                        if delta != 0 {
                            rotatePhase = .changed
                            // Negated: hardware-confirmed 2026-08-08 that raw
                            // atan2 delta reads backwards from the actual
                            // finger twist. `atan2`'s "positive is counter-
                            // clockwise" convention holds in math coordinates
                            // (y-up); screen coordinates here are y-down,
                            // which flips the handedness. Internal tracking
                            // (`lastPairAngle`, `undecidedCumulativeAngle`)
                            // stays in the raw, unflipped convention — only
                            // the emitted intent is corrected, right at the
                            // boundary.
                            rotateComponent = GestureDelta(value: -delta, phase: .changed)
                        }
                    }
                    guard magnify != nil || rotateComponent != nil else { return .none }
                    return .twoFingerGesture(magnify: magnify, rotate: rotateComponent)
                }
            }

            // Dominant-axis lock (see `scrollAxisLock`). Only a committed
            // `.pan` reaches here with `twoFingerKind == .pan` — pinch/rotate/
            // undecided all returned above. `lockedDx`/`lockedDy` carry the
            // axis-suppressed delta forward; `dx`/`dy` stay raw for velocity
            // seeding and brake detection, which must track the real finger
            // (not the locked axis) so momentum coasts the way the hand
            // flicked if `twoFingerScrollMomentum` is ever back on — matching
            // `PanScrollTracker`, which likewise seeds from unlocked travel.
            var lockedDx = dx
            var lockedDy = dy
            if twoFingerKind == .pan {
                if let scrollAxisLock {
                    switch scrollAxisLock {
                    case .vertical: lockedDx = 0
                    case .horizontal: lockedDy = 0
                    }
                } else if !scrollAxisResolved && tracked.count >= 2 {
                    // Only feed the lock decision from genuine two-finger
                    // centroid deltas. A frame with one new id (`current.count
                    // == 2` but `tracked.count == 1` — finger re-landed, or
                    // palm filtering churned the set) yields only that single
                    // finger's own motion here, not a centroid translation.
                    // Defensive, not a known failure: `oldCentroid` and
                    // `newCentroid` are both taken over `tracked`, so such a
                    // frame doesn't inject a jump — but it also isn't the
                    // signal this accumulator is meant to measure, so skip it.
                    // `lastPositions` was re-seeded for the new id above; the
                    // next full two-contact frame resumes the decision.
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
                        // Neither axis dominates — a genuinely diagonal
                        // two-finger drag. Give up on locking for the rest of
                        // this gesture and stay omnidirectional.
                        scrollAxisResolved = true
                    }
                }
            }

            // Default (reverseScrollDirection=false): content follows finger.
            // Reversed: classic scroll-wheel semantics, content moves opposite.
            let sign = reverseScrollDirection ? -1.0 : 1.0
            let outDx = sign * lockedDx
            let outDy = sign * lockedDy
            // Only sample velocity from frames spaced at least `minVelocityDt`
            // apart. A Bluetooth batch delivered in a burst puts several frames
            // microseconds apart (see `BatchFramePacer` / `subMillisecondDtFrames`);
            // `delta / dt` on one of those is a velocity 10–100× the real finger
            // speed, and `peak` below is a max, so it latches onto exactly that
            // sample and seeds a runaway coast. The device's true touch cadence
            // is ~5.6ms on BT (a ~22.5ms batch carrying ~4 touch frames), so
            // 2ms is comfortably below real spacing and above burst spacing.
            // `lastMotionTime` still updates from burst frames (it gates on
            // delta, not dt), so brake detection is unaffected. Both use the
            // raw pre-lock centroid delta, not the axis-locked one.
            if dt >= Self.minVelocityDt {
                recentVelocities.append((time: now, v: CGVector(dx: sign * dx / dt, dy: sign * dy / dt)))
                recentVelocities.removeAll { now - $0.time > Self.peakVelocityWindow }
            }
            if dx != 0 || dy != 0 {
                lastMotionTime = now
            }
            // Skip dead frames: a stationary palm with two contacts down would
            // otherwise post 100 no-op scroll events per second. After an axis
            // lock this also swallows a frame of pure off-axis wobble (its
            // on-axis component zeroed) — correct: a phase-free stream must
            // not emit that at all, not even as a zero.
            if outDx == 0 && outDy == 0 { return .none }
            lastScrollPhase = .changed
            return .scrollDelta(dx: outDx, dy: outDy, phase: .changed)

        case .pointer where absoluteTouch:
            // Pin to the contact that started this sequence rather than
            // re-reading `contacts.first` every frame — see
            // `absolutePrimaryContactID`'s doc comment for why relative
            // mode's own "just take .first" approach would misbehave here.
            let primaryID = absolutePrimaryContactID ?? contacts.first?.id
            absolutePrimaryContactID = primaryID
            guard let primaryID, let primary = contacts.first(where: { $0.id == primaryID })
            else { return .none }
            lastPositions[primary.id] = primary.screen
            if let anchor = tapAnchor {
                tapMaxDelta = Swift.max(tapMaxDelta, hypot(
                    primary.screen.x - anchor.x, primary.screen.y - anchor.y))
            }
            // Skip a repeat warp to the same position — a still finger
            // would otherwise post ~100 identical .mouseMoved CGEvents/sec,
            // the same waste the scroll case's dead-frame skip above exists
            // to avoid. `absoluteLastWarpedTo` still gets set on the first
            // frame regardless of motion (from the .idle/.pending
            // transitions above), which is what makes a motionless
            // tap-to-click resolve at the right position — this guard only
            // suppresses *repeats* of a warp already emitted, never the
            // first one.
            if absoluteLastWarpedTo == primary.screen { return .none }
            absoluteLastWarpedTo = primary.screen
            return .pointerWarp(to: primary.screen)

        case .pointer:
            guard let first = contacts.first else { return .none }
            let prev = lastPositions[first.id] ?? first.screen
            let rawDx = first.screen.x - prev.x
            let rawDy = first.screen.y - prev.y

            let dt = lastPointerSampleTime == 0 ? 0 : now - lastPointerSampleTime
            var gain = sensitivity
            if lastPointerSampleTime == 0 || dt > Self.pointerVelocityStaleGap {
                // No usable prior sample — either the first frame of a new
                // sequence, or one after a pause long enough that the old
                // smoothed speed no longer describes anything real. Apply
                // flat gain for this one frame rather than assuming slow;
                // `pointerSpeed = -1` marks "no history" so the next frame
                // seeds directly from its own instant speed instead of
                // EMA-ing up from 0, which would otherwise damp the first
                // couple of frames after every pause — the same felt
                // "hesitation" this feature exists to get away from, not
                // reintroduce elsewhere.
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

            let dx = rawDx * gain
            let dy = rawDy * gain
            lastPositions[first.id] = first.screen
            if let anchor = tapAnchor {
                tapMaxDelta = Swift.max(tapMaxDelta, hypot(
                    first.screen.x - anchor.x, first.screen.y - anchor.y))
            }
            if dx == 0 && dy == 0 { return .none }
            return .pointerMove(dx: dx, dy: dy)

        case .idle:
            return .none
        }
    }

    /// Clears the committed-`.pan` dominant-axis lock and its pre-lock
    /// accumulators. Called from `reset()` and from both wound-down re-entry
    /// paths that drop `twoFingerKind` back to `.undecided` — the lock is
    /// only read while `twoFingerKind == .pan`, so a stale value is inert,
    /// but clearing it keeps that invariant from being a load-bearing
    /// accident.
    private mutating func resetScrollAxisLock() {
        scrollAxisLock = nil
        scrollAxisResolved = false
        scrollPreLockAccumX = 0
        scrollPreLockAccumY = 0
    }

    /// Clears all sequence state back to `.idle`. Called internally on
    /// all-fingers-lifted and on the non-overlapping-contacts wound-down
    /// escape; the injector no longer calls this directly — pen arbitration
    /// now feeds `process(contacts: [])` so an open gesture phase closes
    /// through the normal wind-down path instead of vanishing.
    mutating func reset() {
        mode = .idle
        lastPositions.removeAll(keepingCapacity: true)
        pointerSpeed = -1
        lastPointerSampleTime = 0
        absolutePrimaryContactID = nil
        absoluteLastWarpedTo = nil
        tapAnchor = nil
        tapStart = 0
        tapMaxDelta = 0
        lastScrollPhase = .ended
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

    private static func distance(between contacts: [(id: Int, screen: CGPoint)]) -> Double {
        guard contacts.count >= 2 else { return 0 }
        let a = contacts[0].screen
        let b = contacts[1].screen
        return hypot(a.x - b.x, a.y - b.y)
    }

    /// Angle of the vector from the first contact to the second, in radians.
    /// Distance is symmetric under swapping the pair, so `distance(between:)`
    /// is safe doing it by array position — angle is not: swap the pair and
    /// the result flips by π. Callers must sort by contact id first so a
    /// frame-to-frame reordering upstream (palm filtering, re-landed fingers)
    /// can't be mistaken for a half-turn.
    private static func angle(between sortedContacts: [(id: Int, screen: CGPoint)]) -> Double {
        guard sortedContacts.count >= 2 else { return 0 }
        let a = sortedContacts[0].screen
        let b = sortedContacts[1].screen
        return atan2(b.y - a.y, b.x - a.x)
    }

    /// Shortest signed angular difference from `old` to `new`, wrapped into
    /// (-π, π]. Plain subtraction breaks at the seam — two contacts slowly
    /// rotating past ±π would otherwise report a spurious near-2π jump.
    private static func wrappedDelta(from old: Double, to new: Double) -> Double {
        var delta = new - old
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta
    }
}
