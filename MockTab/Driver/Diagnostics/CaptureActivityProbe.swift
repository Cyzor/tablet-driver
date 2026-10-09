// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TabletKit
import os

/// What a collection session has seen, for the capture sheet's checklist.
///
/// A tick claims only that activity arrived, never that we understood it —
/// an undecodable stream is one of the things that can be broken, so the
/// stronger claim would fail exactly when it matters.
///
/// Not fed from `DeviceContext.liveButtons`, which is written only while the
/// Info tab and app are both frontmost and throttled to ~16 Hz
/// (`TabletManager.infoViewVisible`); a modal sheet leaves it blank.
///
/// Global, like `TouchPipelineProbe` — a session is single-owner, and this
/// path carries no per-device identity. `note` runs on HIDThread,
/// `snapshot`/`reset` on the main actor, under one unfair lock.
enum CaptureActivityProbe {

    /// Decoded activity per row, plus a session-wide count of reports no
    /// decoder claimed — unattributable, so it can't belong to a row. Kept
    /// separate rather than summed, so a later "some activity" vs. "fully
    /// understood" split needs no new plumbing.
    struct Seen: Equatable, Sendable {
        var decoded: Set<Row> = []
        var rawReports = 0
        /// Features this session exercised, for the file's coverage list.
        /// Finer than the rows: tilt, and rings apart from strips.
        var features: Set<TabletFeature> = []

        /// Rows a decoder has positively confirmed.
        func confirmed() -> Set<Row> { decoded }

        /// Traffic arrived that nothing could read.
        var hasUndecodedTraffic: Bool { rawReports >= activityThreshold }
    }

    /// One row of the capture sheet's checklist.
    enum Row: Hashable, Sendable {
        case penTip, penButtons, eraser, tabletButtons, ringOrStrip
    }

    /// A lone status frame shouldn't register; real use arrives in a burst.
    static let activityThreshold = 3

    private static let state = OSAllocatedUnfairLock(initialState: Seen())

    /// Zeroed per session, so the checklist describes this run only.
    static func reset() {
        state.withLock { $0 = Seen() }
    }

    static func snapshot() -> Seen {
        state.withLock { $0 }
    }

    /// Record decoded activity. Flags latch on — a row records what the
    /// session captured, so lifting the pen must not un-tick it.
    static func note(_ results: [DecodeResult]) {
        for result in results {
            switch result {
            case .pen(let point):
                state.withLock {
                    // Contact, not hover: the rows ask for a touch, and only
                    // contact records pressure.
                    if point.pressure > 0 {
                        if point.eraser { $0.decoded.insert(.eraser) }
                        else { $0.decoded.insert(.penTip) }
                        $0.features.formUnion([.penPosition, .pressure])
                        if point.eraser { $0.features.insert(.eraser) }
                    }
                    if point.inProximity, point.tiltX != 0 || point.tiltY != 0 {
                        $0.features.insert(.tilt)
                    }
                    if point.penButton1 || point.penButton2 || point.penButton3
                        || point.penButton4 || point.penButton5 {
                        $0.decoded.insert(.penButtons)
                    }
                }
            case .toolEnter(let identity):
                // A puck has no pressure, so arriving is all it can show.
                if identity.isMouse {
                    state.withLock { _ = $0.decoded.insert(.penTip) }
                }
            case .aux(let aux):
                state.withLock {
                    if aux.buttons.contains(true) {
                        $0.decoded.insert(.tabletButtons)
                        $0.features.insert(.tabletButtons)
                    }
                    let ring = aux.touchRingActive || aux.touchRing2Active
                        || aux.touchRingButtonDown || aux.touchRing2ButtonDown
                    let strip = aux.touchStrip1Active || aux.touchStrip2Active
                    if ring || strip { $0.decoded.insert(.ringOrStrip) }
                    // A dial reports as a ring; the engine tells them apart.
                    if ring { $0.features.insert(.ring) }
                    if strip { $0.features.insert(.strips) }
                }
            default:
                break
            }
        }
    }

    /// Record one report no decoder handled. Deliberately unattributed:
    /// report IDs can't identify a control — an Xencelabs Pen Display sends
    /// pen motion, buttons and eraser all on 0x02.
    static func noteUndecoded() {
        state.withLock { $0.rawReports += 1 }
    }
}
