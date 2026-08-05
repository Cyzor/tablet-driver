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
    /// Pinch vs pan is chosen once per sequence (same sticky policy as Mode).
    enum TwoFingerKind {
        case undecided
        case pan
        case pinch
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

    /// Sticky pan vs pinch once motion crosses `twoFingerDecideDistance`.
    private var twoFingerKind: TwoFingerKind = .undecided
    /// Last inter-finger distance in screen points (pinch tracking).
    private var lastPinchDistance: Double = 0
    /// Centroid / distance at the start of an undecided two-finger sequence.
    /// Decision uses cumulative motion from these anchors, not per-frame deltas
    /// (slow pans never exceed the threshold in a single high-rate frame).
    private var undecidedOriginCentroid: CGPoint = .zero
    private var undecidedOriginDistance: Double = 0

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
    /// Pinch wins only when inter-finger distance change clearly exceeds
    /// centroid translation. Equal/noisy scale vs pan → stay pan (scroll).
    static let pinchDominanceRatio: Double = 1.75

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
    mutating func process(
        contacts: [(id: Int, screen: CGPoint)],
        tapToClick: Bool,
        twoFingerScroll: Bool,
        reverseScrollDirection: Bool,
        sensitivity: Double,
        pinchZoom: Bool = false,
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
            reset()
            switch priorMode {
            case .scroll where priorKind == .pinch && priorPhase != .ended:
                return .zoomMagnify(magnification: 0, phase: .ended)
            case .scroll where priorPhase != .ended:
                return .scrollDelta(dx: 0, dy: 0, phase: .ended)
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
                twoFingerKind = pinchZoom ? .undecided : .pan
                lastPinchDistance = Self.distance(between: pair)
                undecidedOriginCentroid = centroid(of: pair.map(\.screen))
                undecidedOriginDistance = lastPinchDistance
                // Defer Began until pan/pinch commits when pinch discrimination
                // is on — leave lastScrollPhase .ended so a lift before commit
                // does not emit a stray scroll Ended.
                if pinchZoom {
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

            if pinchZoom {
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
                    let decide = Self.twoFingerDecideDistance
                    if totalScaleChange < decide, totalTranslation < decide {
                        return .none
                    }
                    // Prefer pan unless pinch clearly dominates (ordinary pans
                    // always have some finger-distance jitter).
                    twoFingerKind =
                        totalScaleChange > totalTranslation * Self.pinchDominanceRatio
                        ? .pinch : .pan
                    if twoFingerKind == .pan {
                        lastScrollPhase = .began
                        return .scrollDelta(dx: 0, dy: 0, phase: .began)
                    }
                    lastScrollPhase = .began
                    return .zoomMagnify(magnification: 0, phase: .began)
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
            }

            // Skip dead frames: a stationary palm with two contacts down would
            // otherwise post 100 no-op scroll events per second.
            if dx == 0 && dy == 0 { return .none }
            // Default (reverseScrollDirection=false): content follows finger.
            // Reversed: classic scroll-wheel semantics, content moves opposite.
            let sign = reverseScrollDirection ? -1.0 : 1.0
            lastScrollPhase = .changed
            return .scrollDelta(dx: sign * dx, dy: sign * dy, phase: .changed)

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
}
