// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import TabletKit

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
        case pointer        // single contact moving the cursor
        case scroll         // two contacts moving the scroll wheel
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

    // MARK: - Tunables

    /// Maximum drift (in screen points) that still counts as a tap.
    static let tapMaxDistance: Double = 8.0
    /// Maximum tap duration (seconds); longer touches become drags or scrolls.
    static let tapMaxDuration: CFAbsoluteTime = 0.30

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
    mutating func process(
        contacts: [(id: Int, screen: CGPoint)],
        tapToClick: Bool,
        twoFingerScroll: Bool,
        reverseScrollDirection: Bool,
        sensitivity: Double,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Intent {

        // All fingers lifted — wrap up any in-progress gesture.
        if contacts.isEmpty {
            let priorMode = mode
            let priorPhase = lastScrollPhase
            let tap = tapToClick && priorMode == .pointer
                && now - tapStart <= Self.tapMaxDuration
                && tapMaxDelta < Self.tapMaxDistance
            reset()
            switch priorMode {
            case .scroll where priorPhase != .ended:
                return .scrollDelta(dx: 0, dy: 0, phase: .ended)
            case .pointer where tap:
                return .tapClick
            default:
                return .none
            }
        }

        // First contact — enter pointer mode tentatively.  Mode escalates to
        // .scroll on the frame a second finger arrives, and stays there until
        // all fingers lift (sticky).
        if mode == .idle, let first = contacts.first {
            mode = .pointer
            lastPositions = [first.id: first.screen]
            tapAnchor = first.screen
            tapStart = now
            tapMaxDelta = 0
            return .none  // first frame is just calibration
        }

        // Escalate to scroll once two contacts are present, if enabled.
        if mode == .pointer, contacts.count >= 2 {
            if twoFingerScroll {
                mode = .scroll
                lastPositions = Dictionary(uniqueKeysWithValues:
                    contacts.prefix(2).map { ($0.id, $0.screen) })
                tapAnchor = nil  // tap is off the table once we go to two fingers
                lastScrollPhase = .began
                return .scrollDelta(dx: 0, dy: 0, phase: .began)
            } else {
                // Two-finger scroll disabled: ignore the second contact,
                // keep pointer-tracking the first.
                if let first = contacts.first, lastPositions[first.id] == nil {
                    lastPositions[first.id] = first.screen
                }
            }
        }

        switch mode {
        case .scroll:
            // Centroid of the (up to two) tracked contacts.
            let tracked = contacts.prefix(2).filter { lastPositions[$0.id] != nil }
            guard !tracked.isEmpty else {
                // The original two contacts both lifted; defer to next frame.
                return .none
            }
            let oldCentroid = centroid(of: tracked.compactMap { lastPositions[$0.id] })
            let newCentroid = centroid(of: tracked.map { $0.screen })
            let dx = newCentroid.x - oldCentroid.x
            let dy = newCentroid.y - oldCentroid.y
            for c in tracked { lastPositions[c.id] = c.screen }
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
    }

    private func centroid(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let n = Double(points.count)
        let sx = points.reduce(0) { $0 + $1.x } / n
        let sy = points.reduce(0) { $0 + $1.y } / n
        return CGPoint(x: sx, y: sy)
    }
}
