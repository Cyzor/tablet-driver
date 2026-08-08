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

    /// Sticky two-finger sub-mode once significant motion is seen.
    /// Pan vs pinch vs rotate is chosen once per sequence (same sticky
    /// policy as Mode). Exclusive by design: a real trackpad can magnify
    /// and rotate at once, this tracker cannot — twist-while-spreading
    /// resolves to whichever dominates, never both. Documented limitation,
    /// not a bug to chase.
    enum TwoFingerKind {
        case undecided
        case pan
        case pinch
        case rotate
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
        /// Pinch-zoom magnify delta + phase, mirroring `scrollDelta`'s
        /// envelope. `magnification` is the exact relative growth of
        /// inter-finger distance this frame — (newDistance / oldDistance) - 1
        /// — which is what a real trackpad's magnify gesture reports, and
        /// what makes per-frame deltas compound to the correct total scale
        /// factor (Π(1 + dᵢ) telescopes to distance_final / distance_initial).
        /// Fingers spreading → positive.
        case zoomMagnify(magnification: Double, phase: ScrollPhase)
        /// Smart Zoom: two-finger double-tap, posted as a single one-shot
        /// zoom-to-fit event — no phase envelope, unlike `zoomMagnify`.
        case smartZoom
        /// Two-finger rotate delta + phase, mirroring `zoomMagnify`'s
        /// envelope. `rotation` is this frame's change in the pair's angle,
        /// in radians, sign-corrected to match the actual direction of
        /// finger twist as the user perceives it on screen — hardware-
        /// confirmed 2026-08-08 that raw `atan2` reads backwards here (screen
        /// coordinates are y-down, which flips its usual y-up handedness).
        /// Left in radians deliberately: the CGEvent field's actual expected
        /// unit is unverified (see `postTouchRotate`'s doc comment), so any
        /// unit conversion belongs at the posting layer, not baked into this
        /// tracker's internal math.
        case rotate(rotation: Double, phase: ScrollPhase)
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

    /// Last-emitted scroll phase, used to ensure we emit a single `.ended`
    /// when the last contact lifts.
    private var lastScrollPhase: ScrollPhase = .ended

    /// Sticky pan vs pinch vs rotate once motion crosses `twoFingerDecideDistance`.
    private var twoFingerKind: TwoFingerKind = .undecided
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
    /// Motion (screen points) needed to commit pan vs pinch for a sequence.
    /// Slightly above finger-jitter so a sliding pan doesn't decide on noise.
    static let twoFingerDecideDistance: Double = 6.0
    /// Pinch/rotate win only when their own signal clearly exceeds centroid
    /// translation. Equal/noisy signal vs pan → stay pan (scroll). This is
    /// the bar that protects "pan wins on ambiguity" — see
    /// `crossCandidateDominanceRatio` for the separate, gentler bar pinch
    /// and rotate use against *each other*.
    static let pinchDominanceRatio: Double = 1.75
    /// Bar pinch and rotate must clear against each other (not against pan).
    /// Deliberately gentler than `pinchDominanceRatio`: a real pinch has
    /// some incidental angle jitter, a real twist has some incidental
    /// separation drift, and requiring either to dominate the other by the
    /// same 1.75× reserved for beating pan made a real pinch with a modest
    /// twist wobble misclassify as pan once rotate was enabled — a pinch
    /// regression, confirmed by hand-computed example before this was added.
    static let crossCandidateDominanceRatio: Double = 1.0
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
        let rx = Double(contact.x) / mx
        let ry = Double(contact.y) / my
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
            let priorMode = mode
            let priorPhase = lastScrollPhase
            let priorKind = twoFingerKind
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
            case .scroll where priorKind == .pinch && priorPhase != .ended:
                return .zoomMagnify(magnification: 0, phase: .ended)
            // Must precede the generic pan-ended case below: rotate also
            // leaves `lastScrollPhase` at .began/.changed once committed, so
            // without this case a rotate teardown would emit a stray
            // scrollDelta(.ended) instead and its own phase envelope would
            // never close.
            case .scroll where priorKind == .rotate && priorPhase != .ended:
                return .rotate(rotation: 0, phase: .ended)
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
            return .none
        }

        // Escalate to scroll once two contacts are present, if enabled.
        // From pending this means the fingers landed together (the normal
        // two-finger gesture) — the scroll starts with zero cursor drift.
        if mode == .pending || mode == .pointer, contacts.count >= 2 {
            if twoFingerScroll {
                mode = .scroll
                let pair = Array(contacts.prefix(2))
                lastPositions = Dictionary(uniqueKeysWithValues:
                    pair.map { ($0.id, $0.screen) })
                tapAnchor = nil  // tap is off the table once we go to two fingers
                twoFingerKind = (pinchZoom || rotate) ? .undecided : .pan
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
                if pinchZoom || rotate {
                    return .none
                }
                lastScrollPhase = .began
                return .scrollDelta(dx: 0, dy: 0, phase: .began)
            } else if mode == .pointer {
                // Two-finger scroll disabled: ignore the second contact,
                // keep pointer-tracking the first.
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

            if pinchZoom || rotate {
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
                    // Prefer pan unless one rival clearly dominates *both*
                    // others — the three-way generalization of the original
                    // pinch-vs-pan dominance rule. Pan is the only rival both
                    // others must beat by the full `pinchDominanceRatio`;
                    // that's the bar that matters for "pan wins on
                    // ambiguity" (including the anchored-finger-arc case,
                    // which has real translation *and* real angle change at
                    // once — documented, intentional limitation, not a bug).
                    // Pinch-vs-rotate uses a gentler
                    // `crossCandidateDominanceRatio`: a real pinch has some
                    // incidental angle jitter and a real twist has some
                    // incidental separation drift, and neither should be
                    // able to veto the other at the same strict bar reserved
                    // for outvoting pan.
                    let pinchWins = pinchZoom
                        && totalScaleChange > totalTranslation * Self.pinchDominanceRatio
                        && totalScaleChange > totalTangentialMotion * Self.crossCandidateDominanceRatio
                    let rotateWins = rotate && rotateEligible
                        && totalTangentialMotion > totalTranslation * Self.pinchDominanceRatio
                        && totalTangentialMotion > totalScaleChange * Self.crossCandidateDominanceRatio
                    lastScrollPhase = .began
                    if pinchWins {
                        twoFingerKind = .pinch
                        return .zoomMagnify(magnification: 0, phase: .began)
                    }
                    if rotateWins {
                        twoFingerKind = .rotate
                        return .rotate(rotation: 0, phase: .began)
                    }
                    twoFingerKind = .pan
                    return .scrollDelta(dx: 0, dy: 0, phase: .began)
                }
                if twoFingerKind == .pinch {
                    guard scaleDelta != 0, oldDistance > 0 else { return .none }
                    // Exact relative growth this frame — see the `zoomMagnify`
                    // doc comment for why this is the correct (not approximate)
                    // per-frame value for a multiplicative magnify stream.
                    let magnification = scaleDelta / oldDistance
                    lastScrollPhase = .changed
                    return .zoomMagnify(magnification: magnification, phase: .changed)
                }
                if twoFingerKind == .rotate {
                    // Hold the last angle on a 1-contact frame instead of
                    // computing — same treatment `lastPinchDistance` gets
                    // above, for the same reason (a lone survivor's angle
                    // relative to nothing is meaningless and would invent a
                    // huge delta).
                    let sortedPair = current.count >= 2 ? current.sorted { $0.id < $1.id } : current
                    let newAngle = current.count >= 2 ? Self.angle(between: sortedPair) : lastPairAngle
                    let delta = Self.wrappedDelta(from: lastPairAngle, to: newAngle)
                    lastPairAngle = newAngle
                    guard delta != 0 else { return .none }
                    lastScrollPhase = .changed
                    // Negated: hardware-confirmed 2026-08-08 that raw atan2
                    // delta reads backwards from the actual finger twist.
                    // `atan2`'s "positive is counter-clockwise" convention
                    // holds in math coordinates (y-up); screen coordinates
                    // here are y-down, which flips the handedness. Internal
                    // tracking (`lastPairAngle`, `undecidedCumulativeAngle`)
                    // stays in the raw, unflipped convention — only the
                    // emitted intent is corrected, right at the boundary.
                    return .rotate(rotation: -delta, phase: .changed)
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

    private mutating func reset() {
        mode = .idle
        lastPositions.removeAll(keepingCapacity: true)
        tapAnchor = nil
        tapStart = 0
        tapMaxDelta = 0
        lastScrollPhase = .ended
        twoFingerKind = .undecided
        lastPinchDistance = 0
        undecidedOriginCentroid = .zero
        undecidedOriginDistance = 0
        rotateEligible = false
        lastPairAngle = 0
        undecidedCumulativeAngle = 0
        undecidedStartTime = 0
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
