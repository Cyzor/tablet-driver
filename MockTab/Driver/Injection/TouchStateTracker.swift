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

    /// Sticky two-finger sub-mode once significant motion is seen. Chosen
    /// once per sequence (same sticky policy as Mode): `.pan` vs `.gesture`
    /// doesn't change once committed, and within `.gesture`, which of
    /// pinch/rotate are in play (`pinchInGesture`/`rotateInGesture`) is
    /// fixed at the same commit, not re-evaluated frame to frame — a pinch
    /// that grows a twist mid-sequence still resolves as pinch-only, a
    /// known, deliberate v1 limitation, not a bug to chase.
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

    /// Sticky pan vs gesture (pinch and/or rotate) once motion crosses
    /// `twoFingerDecideDistance`.
    private var twoFingerKind: TwoFingerKind = .undecided
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

    /// End time of the most recent qualifying two-finger tap, for Smart Zoom
    /// double-tap detection. Deliberately *not* cleared by `reset()` — every
    /// lift calls `reset()`, including the lift between the two taps of a
    /// double-tap, so this must survive it or the second tap could never see
    /// the first.
    private var lastTwoFingerTapEndTime: CFAbsoluteTime?

    /// Set on the first empty-contacts frame seen mid-drag; bridges a brief
    /// capacitive dropout so it isn't treated as a real lift. See `process`.
    private var pendingPointerLiftoffTime: CFAbsoluteTime?

    // MARK: - Tunables

    /// Maximum drift (in screen points) that still counts as a tap.
    static let tapMaxDistance: Double = 8.0
    /// Maximum tap duration (seconds); longer touches become drags or scrolls.
    static let tapMaxDuration: CFAbsoluteTime = 0.30
    /// Onset delay: a touch sequence emits nothing until it has been down this
    /// long.  Two jobs: (1) a pen+palm landing posts its proximity report
    /// within this window, so the injector resets the tracker before the palm
    /// has moved the cursor or scrolled anything; (2) a second finger landing
    /// within the window starts a scroll directly, without the first finger
    /// having dragged the cursor in the meantime.  Same trick trackpads use;
    /// the cost is pointer motion starting ~0.1 s late.
    static let onsetDelay: CFAbsoluteTime = 0.12
    /// Grace window for a dropped touch report mid-drag before it's treated
    /// as a real lift — bridges a brief capacitive signal loss (weak/slow
    /// contact, worse near the surface edges) without losing the drag's
    /// position or re-arming `onsetDelay`. Only applies once a drag is
    /// already committed (past `tapMaxDistance`); taps and other gestures
    /// still resolve immediately on lift. Below `onsetDelay` so a real quick
    /// re-touch still reads as a fresh sequence, not a bridged one.
    static let liftoffGraceDelay: CFAbsoluteTime = 0.05
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
    /// A lift is only treated as a flick-release if motion happened within
    /// this many seconds of it — otherwise the fingers were held still
    /// (braking) and release velocity is suppressed regardless of any fast
    /// sample still sitting in the peak-velocity window.
    static let momentumRecencyWindow: CFAbsoluteTime = 0.05
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
    /// same unit (millimeters).
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
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Intent {

        // All fingers lifted — wrap up any in-progress gesture.  A sequence
        // that never outlived the onset delay can still be a tap (a tap is by
        // definition shorter than most onset windows).
        if contacts.isEmpty {
            // Bridge a dropped report mid-drag instead of tearing the
            // sequence down immediately: taps and other gestures still need
            // their lift-triggered intent (tap/`.ended`) to fire right away,
            // but a plain drag has nothing to flush, so it can wait out a
            // short grace window before being treated as a real lift.
            if mode == .pointer, tapMaxDelta >= Self.tapMaxDistance {
                if let pending = pendingPointerLiftoffTime {
                    if now - pending < Self.liftoffGraceDelay { return .none }
                } else {
                    pendingPointerLiftoffTime = now
                    return .none
                }
            }
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
            let peak = recentVelocities
                .filter { now - $0.time <= Self.peakVelocityWindow }
                .max { hypot($0.v.dx, $0.v.dy) < hypot($1.v.dx, $1.v.dy) }?.v ?? .zero
            releaseVelocity = now - lastMotionTime <= Self.momentumRecencyWindow ? peak : .zero
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
        pendingPointerLiftoffTime = nil

        // First contact — hold in pending until the onset delay elapses, so
        // the opening frames of a sequence (where a palm smush or the second
        // scroll finger is still arriving) never move anything.
        if mode == .idle, let first = contacts.first {
            mode = .pending
            lastPositions = [first.id: first.screen]
            tapAnchor = first.screen
            tapStart = now
            tapMaxDelta = 0
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
            // Track motion for tap detection, but emit nothing.  Anchor at the
            // contact's current position on commit so motion accumulated during
            // the window is discarded rather than replayed as a cursor jump.
            if let first = contacts.first {
                if let anchor = tapAnchor {
                    tapMaxDelta = Swift.max(tapMaxDelta, hypot(
                        first.screen.x - anchor.x, first.screen.y - anchor.y))
                }
                lastPositions = [first.id: first.screen]
            }
            if now - tapStart >= Self.onsetDelay {
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
                    if totalScaleChange < decide, totalTranslation < decide,
                        totalTangentialMotion < decide
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
                    // Each component was fixed at commit (see
                    // `TwoFingerKind`'s doc comment) and now just reports its
                    // own per-frame delta, independently of the other.
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
                        // Hold the last angle on a 1-contact frame instead of
                        // computing — same treatment `lastPinchDistance` gets
                        // above, for the same reason (a lone survivor's angle
                        // relative to nothing is meaningless and would
                        // invent a huge delta).
                        let sortedPair = current.count >= 2 ? current.sorted { $0.id < $1.id } : current
                        let newAngle = current.count >= 2 ? Self.angle(between: sortedPair) : lastPairAngle
                        let delta = Self.wrappedDelta(from: lastPairAngle, to: newAngle)
                        lastPairAngle = newAngle
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

            // Default (reverseScrollDirection=false): content follows finger.
            // Reversed: classic scroll-wheel semantics, content moves opposite.
            let sign = reverseScrollDirection ? -1.0 : 1.0
            let outDx = sign * dx
            let outDy = sign * dy
            if dt > 0 {
                recentVelocities.append((time: now, v: CGVector(dx: outDx / dt, dy: outDy / dt)))
                recentVelocities.removeAll { now - $0.time > Self.peakVelocityWindow }
            }
            if dx != 0 || dy != 0 {
                lastMotionTime = now
            }
            // Skip dead frames: a stationary palm with two contacts down would
            // otherwise post 100 no-op scroll events per second.
            if dx == 0 && dy == 0 { return .none }
            lastScrollPhase = .changed
            return .scrollDelta(dx: outDx, dy: outDy, phase: .changed)

        case .pointer:
            guard let first = contacts.first else { return .none }
            let prev = lastPositions[first.id] ?? first.screen
            let dx = (first.screen.x - prev.x) * sensitivity
            let dy = (first.screen.y - prev.y) * sensitivity
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

    /// Also called directly by the injector to force an immediate hard reset
    /// (e.g. pen arbitration taking over) — bypassing the drag-dropout grace
    /// window in `process`, which only makes sense while touch itself is
    /// still authoritative.
    mutating func reset() {
        mode = .idle
        lastPositions.removeAll(keepingCapacity: true)
        tapAnchor = nil
        tapStart = 0
        tapMaxDelta = 0
        lastScrollPhase = .ended
        twoFingerKind = .undecided
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
        recentVelocities.removeAll()
        lastFrameTime = 0
        pendingPointerLiftoffTime = nil
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
