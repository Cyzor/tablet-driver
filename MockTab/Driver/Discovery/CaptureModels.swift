// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid

// MARK: - Device Mode Init

/// One device-mode init attempt made during a capture session.
///
/// Modern Wacom devices boot emitting a reduced (or no) pen stream until the
/// host writes a data-mode feature report; a read-only capture then records
/// nothing useful and looks like "the device reports no tilt". Legacy families
/// use feature report `0x02` value `2`; on current `HID_GENERIC` devices the
/// report ID is whatever carries the vendor DATAMODE usage (`0xff0d1002`), and
/// on Precision-Touchpad-style multitouch interfaces the standard Device Mode
/// usage (`0x0d`/`0x52`) plays the same role. Either must be read out of the raw
/// descriptor — IOKit surfaces those fields as `usage 0x00`, so we can't
/// discover it from the element list. Hence the manual entry: a tester
/// with modern hardware can try candidate report IDs and ship the outcome back
/// in the capture file. See Notes/Wacom-HID-Post-2020-Preliminary-Research.md.
struct CaptureInitReport: Codable, Identifiable {
    let reportID: Int
    let value: Int
    let succeeded: Bool
    /// `IOReturn` as hex when the write failed; nil on success.
    var ioReturn: String?

    var id: String { "\(reportID)-\(value)-\(ioReturn ?? "ok")" }

    var reportIDHex: String { String(format: "0x%02X", reportID) }
    var valueHex: String { String(format: "0x%02X", value) }
}

// MARK: - Discovery Result

/// Output of a discovery session. Records every report ID seen and, for each,
/// which byte positions varied and what values they took.
///
/// Consumed by `TabletKit/tools/triage_discovery.py` and read by hand when adding a new
/// device to the registry.
struct DiscoveryResult: Codable {
    /// 5: `byteSampleValues` replaced by `byteStats` (adds per-byte min/max and
    /// distinct-value counts); adds `maxLength`/`lengthVaried`/`optionalBytes`
    /// and top-level `observedToolCodes`.
    /// 6: adds `byteStatsByDiscriminator` — per-report byte stats further
    /// split by the value at byte position 1, so a report ID that actually
    /// carries more than one packet shape (coordinate data and a tool-change/
    /// status packet sharing one ID and length, on Wacom-family devices)
    /// doesn't get histogrammed as one blob. See `DiscoveryAccumulator
    /// .ReportStats.discriminatorByteIndex`.
    /// 7: adds `interfaces` — a device whose reports arrive on more than one
    /// HID interface is now recorded on all of them at once, each with its own
    /// reports and descriptor, instead of only whichever one was captured.
    /// 8: adds `touchSettings` and `touchPipeline`. A capture until now
    /// recorded only what the *device* sent, which is half the picture when a
    /// report arrives well-formed and produces nothing: the answer is then
    /// somewhere in the app, and the file said nothing about the app. These
    /// two blocks close that — what the user's touch settings were, and how
    /// many contacts each stage of the injection pipeline let through.
    /// 9: `touchSettings` gains `twoFingerScrollMomentum`, `reverseScrollDirection`,
    /// `rotateEnabled`, `smartZoomEnabled` — the gesture toggles a reader
    /// otherwise had to ask the user about. `touchPipeline` gains the
    /// scroll-wind-down and momentum-tail counters (`scrollSingleContactFrames`,
    /// `longestScrollSingleContactRun`, `scrollWindDowns`, `momentumTailStarts`,
    /// `momentumSuppressedStale`, `momentumSuppressedSlow`,
    /// `maxReleaseVelocity`, `maxReleaseFrameGap`, `maxReleaseMotionGap`) plus
    /// `subMillisecondDtFrames` / `pacerFlushDeliveredFrames` for diagnosing a
    /// batched-Bluetooth scroll that coasts erratically. All new
    /// `touchPipeline` fields default to 0 and all new `touchSettings` fields
    /// are optional, so a v8 reader and v8 files still decode.
    /// 10: adds `appVersion` / `appBuildDate` — which binary produced the file,
    /// so a capture can't be mis-attributed to a build that lacks the fix under
    /// test. `touchPipeline` gains `penProximityForcedExits` (leak-watchdog
    /// recoveries, split out of `penProximityExits` which now counts *every*
    /// exit path) and `palmRejectionBrokeTwoFingerFrames` (a ≥2-contact frame
    /// filtered below two — palm rejection costing a gesture, as distinct from
    /// `contactsPalmRejected` correctly dropping a lone palm).
    /// 11: `touchSettings` gains `touchOnsetDelayMs` — the onset window is now a
    /// silent user-settable `defaults` value, so a file that doesn't carry it
    /// can't rule it out as the cause of "a palm moved the cursor" / "touch
    /// starts laggy". `touchPipeline` gains `onsetWindowsEntered`,
    /// `onsetWindowsReArmedWithin`, `longestSingleContactDragMs` — whether a
    /// slow full-surface swipe is re-paying the onset delay per re-land (the
    /// PTH-651 issue #12 "swipe covers only part of the screen" report). New
    /// pipeline fields default 0, the new settings field is optional, so v10
    /// readers and files still decode.
    /// 12: `touchPipeline` gains `twoFingerResolvedBoth` and
    /// `twoFingerLateJoins`, which measure concurrent pinch+rotate — the
    /// per-component tallies alone can't distinguish one sequence running
    /// both from two separate sequences. Added alongside the change that
    /// lets a component join a gesture after commit. Both default 0, so v11
    /// readers and files still decode.
    /// 13: adds `bluetoothLink` — RSSI and link-quality samples taken during
    /// the capture, for a Bluetooth device only. Answers "was this specific
    /// choppy session a weak-signal problem or something else" without
    /// asking the reporter to guess. The address used to find the device is
    /// a best-effort match (`BluetoothLinkMonitor`'s doc comment explains
    /// why), so the block also carries `addressLikelyWrong` — set if the
    /// resolved device's own connection state ever disagreed with reality
    /// during the session — and a reader should treat the numbers as
    /// unreliable when that's true. Nil on USB, and nil if no paired device
    /// could be matched at all. Optional, so v12 readers and files still
    /// decode.
    /// 14: two changes.
    /// (a) The top-level `reports`/`hidReportDescriptor` block now comes from
    /// the interface whose descriptor declares pen fields (pressure/tilt/…),
    /// not the one that attached first. On a multi-interface Wacom device
    /// whose pen interface enumerates second and behind a Generic Desktop
    /// primary usage — the PTH-860 over USB — v13 and earlier put the touch
    /// tunnel's reports at the top level while the pen samples sat in
    /// `interfaces[]`; v14 puts the pen interface there as the block's name
    /// always implied. Single-interface captures and devices whose pen
    /// interface already led are unchanged. `interfaces[]` still carries
    /// every interface, so nothing is lost either way.
    /// (b) each `DiscoveryReportSummary` gains `arrivalGaps` — a histogram of
    /// the time between consecutive reports of that ID, plus the longest few
    /// gaps kept whole, split by whether a touch contact was down at both
    /// ends of the gap. A capture recorded what reports *contained* but never
    /// when they arrived, so a stream that stalls mid-gesture left no trace;
    /// the contact-state split then separates a real mid-gesture stall from a
    /// finger-off pause between gestures. New field is optional, so v13
    /// readers and files still decode.
    var captureVersion: Int = 14
    /// App marketing version and build-date stamp (`MockTabBuildDate` from the
    /// bundle) of the binary that recorded this capture. Nil only if the keys
    /// are somehow absent.
    var appVersion: String?
    var appBuildDate: String?
    let capturedAt: Date
    let mode: String  // always "discovery"
    let duration: TimeInterval
    let deviceInfo: DiscoveryDeviceInfo
    /// The **primary** interface's reports — the pen interface on a tablet
    /// that has one (`captureVersion` 14+ selects it by descriptor contents,
    /// so this holds even when the pen interface attached second or hid
    /// behind a non-digitizer primary usage; see the version note above).
    /// Duplicated from `interfaces[0]` rather than replaced by it so a reader
    /// that predates `captureVersion` 7 (`TabletKit/tools/triage_discovery.py`
    /// as shipped, and every capture file already submitted against it) still
    /// finds the block it looks for, in the shape it expects. A few KB of
    /// duplication buys that.
    let reports: [String: DiscoveryReportSummary]
    /// Likewise the primary interface's descriptor.
    var hidReportDescriptor: LiveHIDDescriptorInspector.Parsed?
    /// Every interface recorded, primary first — present only when there was
    /// more than one, so single-interface captures (the overwhelming majority)
    /// stay byte-for-byte the shape they always were.
    var interfaces: [DiscoveryInterface]?
    /// Device-mode init writes attempted during the session, in order. Empty
    /// when the tester didn't use the advanced control — the common case.
    var initReports: [CaptureInitReport]?
    /// Wacom tool codes observed while collecting, as hex (e.g. `0x0802` pen,
    /// `0x080A` eraser). The clearest evidence of which tools a device reports
    /// distinctly, which no amount of byte-level analysis recovers on its own.
    var observedToolCodes: [String]?
    /// The touch-related settings in force during the session. Present only
    /// for a device whose spec declares finger touch — on everything else
    /// these settings are inert and would be misleading noise.
    var touchSettings: DiscoveryTouchSettings?
    /// Per-stage tallies of what the touch injection pipeline did with the
    /// contacts it decoded. Present only when the pipeline saw at least one
    /// frame, so a pen-only session doesn't carry a block of zeroes.
    var touchPipeline: DiscoveryTouchPipeline?
    /// RSSI/link-quality samples taken during the session, Bluetooth only.
    /// See `captureVersion` 13's doc line for the address-match caveat.
    var bluetoothLink: DiscoveryBluetoothLink?
    var notes: String?
    var submitterContact: String?
}

/// RSSI and link-quality summary for a Bluetooth capture session. See
/// `BluetoothLinkMonitor` for how it's gathered and the address-match
/// caveat this block exists to carry along with the numbers.
struct DiscoveryBluetoothLink: Codable {
    /// The candidate BD_ADDR string used to find the device. Not proof it's
    /// correct — kept so a reader can spot-check it against `ioreg` or
    /// System Settings if the numbers look implausible.
    let addressCandidate: String
    let sampleCount: Int
    let disconnectedSampleCount: Int
    /// True if the resolved device's own `isConnected` state ever disagreed
    /// with the fact that reports were actively arriving from some
    /// Bluetooth tablet during this session. When true, treat every other
    /// field in this block as describing the wrong device.
    let addressLikelyWrong: Bool
    let rssiMin: Int?
    let rssiMax: Int?
    let rssiAvg: Double?
    let rawRSSIMin: Int?
    let rawRSSIMax: Int?
    let rawRSSIAvg: Double?
}

/// The user's touch configuration at capture time.
///
/// Every field here can independently silence touch, and none of them is
/// visible in a report stream. Recording them turns "touch does nothing" from
/// a question that has to be asked into a fact the file already carries.
struct DiscoveryTouchSettings: Codable {
    let touchEnabled: Bool
    let tapToClick: Bool
    let twoFingerScroll: Bool
    let pinchZoom: Bool
    /// Gesture toggles that are otherwise invisible in a report stream and had
    /// to be asked about after the fact — `reverseScrollDirection` alone
    /// explains a "scroll goes the wrong way" report, and `twoFingerScrollMomentum`
    /// being off makes "no coasting" expected rather than a bug. Optional so a
    /// v8 capture file (which lacks them) still decodes.
    var twoFingerScrollMomentum: Bool?
    var reverseScrollDirection: Bool?
    var rotateEnabled: Bool?
    var smartZoom: Bool?
    /// Milliseconds a touch sequence emits nothing after landing
    /// (`TabletSettings.touchOnsetDelayMs`, default 40). User-settable via a
    /// `defaults` key with no UI, so it is invisible in a report stream: a
    /// value of 0 makes "a palm moved the cursor" or "no onset pause" expected
    /// rather than a bug, and a large value explains a laggy-feeling touch
    /// start. Optional so pre-v11 files still decode.
    var touchOnsetDelayMs: Double?
    let sensitivity: Double
    /// Touch-area crop as a fraction of the surface (x, y, width, height).
    /// A crop that excludes where the tester's fingers actually landed drops
    /// every contact at projection — indistinguishable from dead touch
    /// without this.
    let areaX: Double
    let areaY: Double
    let areaWidth: Double
    let areaHeight: Double
}

/// How far touch contacts got through the injection pipeline.
///
/// Read top to bottom, these localize a touch failure to one stage without
/// any further round trip: contacts decoded but zero intents posted, with the
/// drop counted against exactly one gate, names the gate.
///
/// Counts are of *frames* where the whole frame was rejected, and of
/// *contacts* where individual contacts were filtered out of a surviving
/// frame — the distinction matters, since a partially filtered frame still
/// reaches the gesture tracker.
struct DiscoveryTouchPipeline: Codable {
    /// Frames the decoder emitted (`DecodeResult.touch`), and the total
    /// contacts across them. A nonzero `framesDecoded` with everything else
    /// zero means the decode half is working and the loss is downstream.
    var framesDecoded: Int = 0
    var contactsDecoded: Int = 0
    /// Frames dropped because "Enable Finger Touch" was off.
    var framesTouchDisabled: Int = 0
    /// Frames dropped because no injection snapshot existed yet — a startup
    /// race, not a user setting.
    var framesNoSnapshot: Int = 0
    /// Frames dropped by pen arbitration (`touchPenConfirmedBusy` or inside
    /// `touchArbitrationGrace`). A large count here with the pen untouched is
    /// the signature of a latched proximity state.
    var framesPenBusy: Int = 0
    /// Pen frames actually delivered to `InputInjector.inject(point:settings:)`
    /// during this capture — i.e. real proximity/tip data flowing, not just
    /// the arbitration flag. Compared against `framesPenBusy`: pen frames
    /// streaming continuously while `framesPenBusy` is high means arbitration
    /// is correctly reacting to genuine sustained proximity (the pen really
    /// is held in-hand throughout a touch gesture); near-zero pen frames
    /// during a long busy run instead means `touchPenConfirmedBusy` latched
    /// stuck true with nothing left to justify it. Same mechanism, opposite
    /// fixes — see `longestPenBusyStreak`.
    var framesPenDelivered: Int = 0
    /// Longest unbroken run of touch frames dropped by pen-busy arbitration
    /// in a row, with no non-busy touch frame in between.
    var longestPenBusyStreak: Int = 0
    var currentPenBusyStreak: Int = 0
    /// Count of `point.inProximity` transitions seen by
    /// `InputInjector.inject(point:settings:)`, each direction tallied
    /// separately. `commitProximityExit` — the only thing that clears
    /// `touchPenConfirmedBusy` for a non-Xencelabs device — fires only on an
    /// exit transition. `penProximityEnters` far outrunning
    /// `penProximityExits` means exit frames are being lost somewhere
    /// between decode and `inject` (a real dispatch/decoder bug, distinct
    /// from arbitration policy); the two staying roughly equal instead means
    /// proximity is genuinely toggling as reported and any long busy streak
    /// reflects the pen really being held in range that whole time.
    var penProximityEnters: Int = 0
    /// Every committed proximity exit, whichever path triggered it — the
    /// report-driven transition, the Xencelabs debounce, or the leak-watchdog.
    /// (Before v10 this counted only the report-driven transition, so a device
    /// whose clean exit reports don't arrive — a BT PTH-660 — showed enters
    /// with zero exits and read as a stuck latch when the watchdog was in fact
    /// recovering it every time.)
    var penProximityExits: Int = 0
    /// A **subset** of `penProximityExits` (not a separate total — don't add
    /// them): how many of those exits were forced by the leak-watchdog rather
    /// than driven by a real exit report. A high count means the device is
    /// genuinely failing to report proximity loss and only the timeout
    /// recovers it — the real shape of "bug C", distinct from touch being
    /// suppressed.
    var penProximityForcedExits: Int = 0
    /// Touch frames let through by the `staleBusyTimeout` escape hatch —
    /// i.e. `touchPenConfirmedBusy` was true, but with no tip contact for
    /// long enough that arbitration treated it as an idle, ambiguously-near
    /// pen rather than genuine use. Nonzero confirms the mechanism actually
    /// engaged during a capture.
    var framesStaleBusyRecovered: Int = 0

    mutating func noteTouchPenBusy() {
        framesPenBusy += 1
        currentPenBusyStreak += 1
        longestPenBusyStreak = Swift.max(longestPenBusyStreak, currentPenBusyStreak)
    }

    mutating func noteTouchNotPenBusy() {
        currentPenBusyStreak = 0
    }
    /// Contacts removed by `TouchPalmRejector`. Only ever nonzero on the
    /// calibrated PTH-660/860 family.
    var contactsPalmRejected: Int = 0
    /// Count of *entries* into the state where a ≥2-contact frame left palm
    /// filtering with fewer than two — palm rejection preventing or
    /// interrupting a two-finger gesture. Counted once per entry, not per held
    /// frame (a resting palm holds the state at report rate). The number to
    /// weigh against `contactsPalmRejected` when a "gesture didn't take" report
    /// comes in: a nonzero value here during a failed pinch/scroll attempt is
    /// palm rejection being too aggressive, not the gesture tracker failing to
    /// commit. Name kept `…Frames` for capture-file compatibility though it now
    /// counts events.
    var palmRejectionBrokeTwoFingerFrames: Int = 0
    /// Contacts dropped by `TouchStateTracker.screenPoint` returning nil —
    /// i.e. falling outside the touch-area crop above.
    var contactsOffArea: Int = 0
    /// Extremes of the raw contact coordinates the decoder produced, in device
    /// units, before any projection.
    ///
    /// These answer a question the counters cannot: whether the registry's
    /// `touchMaxX`/`touchMaxY` match what the sensor actually reaches. Touch
    /// pointer motion is relative, scaled by `coordinate / touchMax`, so a
    /// ceiling set above the reachable range makes a full-surface swipe cover
    /// only that fraction of the screen — the PTH-651 report in issue #12,
    /// where a full sweep stopped short of the right edge. A capture taken
    /// while tracing the four edges puts the true range in the file.
    ///
    /// Nil until the first contact, so a session with no touch records no
    /// misleading zeroes.
    var observedMinX: Int?
    var observedMaxX: Int?
    var observedMinY: Int?
    var observedMaxY: Int?

    /// Fold one contact's raw position into the observed extents.
    mutating func noteExtent(x: Int, y: Int) {
        observedMinX = Swift.min(observedMinX ?? x, x)
        observedMaxX = Swift.max(observedMaxX ?? x, x)
        observedMinY = Swift.min(observedMinY ?? y, y)
        observedMaxY = Swift.max(observedMaxY ?? y, y)
    }

    /// Largest same-ID frame-to-frame movement seen, in raw device units.
    /// A finger cannot cross a large fraction of the surface in one ~10ms
    /// report period; a value here that's a large fraction of touchMaxX/Y
    /// is a contact "teleporting" — the signature of a noisy, wet, or dirty
    /// capacitive surface reporting a spurious position, not a real touch.
    /// Nil until two consecutive frames share a contact id.
    var maxContactJump: Int?
    /// Contacts that appeared and vanished again within a handful of
    /// frames (see `TabletManager.shortLivedContactFrames`) — flickering
    /// touchdown/liftoff rather than a deliberate tap or lift. A high count
    /// here alongside a normal-looking `maxContactJump` still points at a
    /// marginal surface: the symptom just shows up as chatter instead of
    /// large jumps.
    var shortLivedContacts: Int = 0

    /// Longest run of consecutive frames, immediately before a contact
    /// disappeared, where its reported position did not change at all while
    /// still "down". A high value — motion frozen right up to the moment a
    /// touch vanishes, rather than a genuine deliberate hold — is the
    /// signature of the sensor's coordinate stalling (signal too weak to
    /// update, likely as contact area collapses near a surface edge) before
    /// the firmware finally reports liftoff. Neither `sensitivity` nor a
    /// tighter touch-area crop can compensate for this: both only scale up
    /// motion that's actually reported, and a frozen coordinate has no delta
    /// left to scale. `stallAreaAtLift`/`stallX`/`stallY` capture the
    /// contact area and raw position at that longest stall, so a cluster of
    /// stalls at a consistent position/shrinking area supports the theory; a
    /// scatter across the surface argues against it. All nil until some
    /// contact both moves and later disappears.
    var maxStallBeforeLift: Int?
    var stallAreaAtLift: Int?
    var stallX: Int?
    var stallY: Int?

    /// Frames that reached the gesture tracker with at least one contact.
    var framesTracked: Int = 0
    /// Intents the tracker produced, by kind. All zero while `framesTracked`
    /// is large means the gesture tracker is receiving contacts and refusing
    /// to commit to a gesture.
    var pointerMoves: Int = 0
    var scrolls: Int = 0
    var zooms: Int = 0
    var rotates: Int = 0
    var taps: Int = 0

    /// How two-or-more-finger sequences resolved, tallied once per sequence
    /// (at the moment it commits to a gesture, or at teardown if it never
    /// commits to anything) — not once per frame, unlike the counts above.
    /// Answers a question `zooms`/`rotates` alone cannot: whether a "gesture
    /// didn't work" complaint is a *discrimination* failure (the sequence
    /// resolved as pan when the user meant to pinch or rotate — check
    /// `twoFingerResolvedPan` against expectations) or *non-detection*
    /// (`twoFingerResolvedNone`, nothing ever committed at all). Distinct
    /// mechanisms, distinct fixes: the former is a dominance/timing tuning
    /// issue in `TouchStateTracker`, the latter suggests the gesture never
    /// cleared its own threshold in the first place.
    var twoFingerResolvedPan: Int = 0
    var twoFingerResolvedPinch: Int = 0
    var twoFingerResolvedRotate: Int = 0
    var twoFingerResolvedNone: Int = 0

    /// Largest combined pen+touch frame count seen in one Bluetooth-batched
    /// HID report (`BatchFramePacer`/`WacomKnownDevice.dispatchBatch`), and
    /// the number of batches at or above `largeBatchThreshold` (6 — bigger
    /// than the 4-5 pure-pen batches this pacer was originally measured
    /// against). `perFrameDelayNs` is the report's real interval divided by
    /// this count: a report combining several pen frames with several touch
    /// frames (pen held near the tablet during a touch gesture) drives the
    /// count well past pure-pen batches, over-slicing the interval and
    /// delaying the tail frame much longer than pacing was designed for.
    /// Answers, from a single capture, whether "stalls only when pen is near
    /// touch" tracks batch size the way that theory predicts.
    var maxBatchFrameCount: Int = 0
    var largeBatchCount: Int = 0
    static let largeBatchThreshold = 6

    mutating func noteBatch(frameCount: Int) {
        maxBatchFrameCount = Swift.max(maxBatchFrameCount, frameCount)
        if frameCount >= Self.largeBatchThreshold { largeBatchCount += 1 }
    }

    /// Frames a committed two-finger pan scroll ran with only one contact
    /// present, and the longest unbroken run of them. A `.pan` gesture kept
    /// alive on a single finger keeps scrolling from that finger's motion —
    /// large numbers here are the signature of "scroll gets stuck, one finger
    /// keeps scrolling the view". `TouchStateTracker.scrollSingleContactGrace`
    /// now winds the gesture down once such a run exceeds the grace window;
    /// `scrollWindDowns` counts how often that fired.
    var scrollSingleContactFrames: Int = 0
    var longestScrollSingleContactRun: Int = 0
    var currentScrollSingleContactRun: Int = 0
    var scrollWindDowns: Int = 0

    mutating func noteScrollSingleContactFrame() {
        scrollSingleContactFrames += 1
        currentScrollSingleContactRun += 1
        longestScrollSingleContactRun =
            Swift.max(longestScrollSingleContactRun, currentScrollSingleContactRun)
    }

    mutating func noteScrollTwoContactFrame() {
        currentScrollSingleContactRun = 0
    }

    /// Momentum-tail outcomes at scroll release. `momentumTailStarts` is a coast
    /// actually beginning. `momentumSuppressedStale` is a release that *had* a
    /// fast recent sample but the recency gate rejected it because motion
    /// stopped more than `momentumRecencyWindow` ago — a deliberate brake, or a
    /// batched-delivery gap that *looks* like one (the suspected cause of
    /// "Bluetooth scroll doesn't coast"). `momentumSuppressedSlow` is every
    /// other non-start: genuinely slow motion, or no recent motion and no fast
    /// sample at all. `maxReleaseVelocity` is the largest release-velocity
    /// magnitude seen (points/sec) — an implausible value points at a
    /// delivery-timing bug corrupting the per-frame `dt`.
    var momentumTailStarts: Int = 0
    var momentumSuppressedStale: Int = 0
    var momentumSuppressedSlow: Int = 0
    var maxReleaseVelocity: Double = 0

    /// At each scroll release: the largest gap seen since the last `.scroll`
    /// frame of any kind (`maxReleaseFrameGap`) and since the last one that
    /// moved (`maxReleaseMotionGap`), seconds. Plus counts of releases where
    /// each gap exceeded `releaseGapThreshold` — a single max can't tell one
    /// outlier from a systematic pattern, these can.
    ///
    /// The discriminator for a suppressed coast: `motionGapExceeded` high while
    /// `frameGapExceeded` stays low ⇒ frames kept arriving but fingers held
    /// still (a genuine brake — correct suppression). Both high together ⇒
    /// frames stopped arriving (a batched-delivery gap — bug B).
    var maxReleaseFrameGap: Double = 0
    var maxReleaseMotionGap: Double = 0
    var releaseFrameGapExceeded: Int = 0
    var releaseMotionGapExceeded: Int = 0
    /// Seconds. A gap beyond this at release is well past both
    /// `peakVelocityWindow` (0.06) and `momentumRecencyWindow` (0.05), so it's
    /// a real stall, not report jitter.
    static let releaseGapThreshold: Double = 0.1

    mutating func noteReleaseGaps(frameGap: Double, motionGap: Double) {
        if frameGap >= 0 {
            maxReleaseFrameGap = Swift.max(maxReleaseFrameGap, frameGap)
            if frameGap > Self.releaseGapThreshold { releaseFrameGapExceeded += 1 }
        }
        if motionGap >= 0 {
            maxReleaseMotionGap = Swift.max(maxReleaseMotionGap, motionGap)
            if motionGap > Self.releaseGapThreshold { releaseMotionGapExceeded += 1 }
        }
    }

    /// Touch frames whose measured `dt` since the previous frame was under a
    /// millisecond, and the number of frames the `BatchFramePacer` delivered
    /// via an immediate `flush()` rather than a paced tick. A batched-Bluetooth
    /// stream whose frames arrive bunched (near-zero `dt`) produces a wildly
    /// inflated per-frame velocity estimate; these two localize that to the
    /// pacer's flush path.
    var subMillisecondDtFrames: Int = 0
    var pacerFlushDeliveredFrames: Int = 0

    /// Onset-window lifecycle. `onsetWindowsEntered` counts `.idle` → `.pending`
    /// transitions (one per touch sequence). `onsetWindowsReArmedWithin` counts
    /// how many of those started within `reArmWindow` of the previous
    /// sequence's teardown — a single slow finger drag that dips below the
    /// sensor's contact threshold and re-lands pays the onset delay again each
    /// time, so a full-surface swipe stutters. `longestSingleContactDragMs` is
    /// the longest unbroken single-contact pointer drag seen; a large value
    /// next to a high re-arm count says the "swipe covers only part of the
    /// screen" report is churn, not a real short drag. The onset-delay change
    /// (2026-08-27) shortens each re-arm's cost from ~120 ms to the configured
    /// value but does not remove the re-arm itself — these measure whether it
    /// still matters.
    ///
    /// `TouchPipelineProbe` is global, so on a bench with two tablets connected
    /// `onsetWindowsEntered` sums both — don't read
    /// `onsetWindowsReArmedWithin / onsetWindowsEntered` as a fraction there.
    /// A single-tablet capture (a normal user, and issue #12's reporter) is fine.
    var onsetWindowsEntered: Int = 0
    var onsetWindowsReArmedWithin: Int = 0
    var longestSingleContactDragMs: Int = 0
    /// Concurrent pinch+rotate. `twoFingerResolvedPinch`/`Rotate` are tallied
    /// per component per sequence, so a file showing 9 and 29 cannot say
    /// whether any *one* sequence ran both or whether they were 38 separate
    /// single-component gestures — the exact question behind "simultaneous
    /// zoom and rotate is hard to invoke". `twoFingerResolvedBoth` counts
    /// sequences that ended up running both at once; `twoFingerLateJoins`
    /// counts components that opened their envelope after the sequence had
    /// already committed, which is the late-join path (added 2026-08-27)
    /// firing. A high `Both` with a high `LateJoins` means concurrency is
    /// arriving the new way — the first gesture commits, the second joins
    /// when its evidence shows up — rather than needing both signals to
    /// qualify in the same frame.
    var twoFingerResolvedBoth: Int = 0
    var twoFingerLateJoins: Int = 0
    /// Seconds. A gap between one sequence's teardown and the next's onset
    /// shorter than this reads as one interrupted drag rather than two
    /// deliberate touches.
    static let reArmWindow: Double = 0.25

    /// True when the pipeline saw anything at all, so a pen-only capture can
    /// omit the block entirely.
    var isEmpty: Bool {
        framesDecoded == 0 && framesTouchDisabled == 0 && framesNoSnapshot == 0
            && framesPenBusy == 0
    }
}

/// One HID interface of a captured device, with the reports it sent and the
/// descriptor it declared.
///
/// Multi-interface tablets are the reason this exists. A PTH-850 puts pen data
/// on one interface and a 64-byte touch frame on another; before this, a
/// capture recorded exactly one of them and whether it was the interesting one
/// came down to which attached first. Which interface matters is precisely
/// what a tester submitting an unknown device can't be asked to judge, so all
/// of them are recorded and the triage happens later, off the file.
///
/// An interface with `sampleCount` 0 is kept rather than dropped: "this
/// interface exists, we listened, and it said nothing for the whole session"
/// is a real finding — it's what a device sitting in a reduced boot mode looks
/// like, and it's the evidence a mode-switch write is needed.
struct DiscoveryInterface: Codable {
    /// HID primary usage page/usage, as hex. Together these name the
    /// interface's role — `0x000D`/`0x0002` a pen digitizer, `0x000D`/`0x0004`
    /// a touchscreen, `0xFF00`+ a vendor-private tunnel.
    var usagePage: String?
    var usage: String?
    /// True for the interface whose data is also duplicated at the top level
    /// of `DiscoveryResult`. Exactly one interface has this.
    let isPrimary: Bool
    /// Reports recorded on this interface alone.
    let sampleCount: Int
    let reports: [String: DiscoveryReportSummary]
    /// This interface's own descriptor — the one every `descriptorReadable`
    /// flag in `reports` above was judged against.
    var hidReportDescriptor: LiveHIDDescriptorInspector.Parsed?
}

struct DiscoveryDeviceInfo: Codable {
    let vendorID: String
    let productID: String
    let name: String
    var manufacturer: String?
    var transport: String?
    var locationID: String?
}

/// What one byte position did across every sample of a report.
struct DiscoveryByteStat: Codable {
    let min: Int
    let max: Int
    /// Number of distinct values observed at this position.
    let distinctCount: Int
    /// Observed values, ascending. Complete when `distinctCount` is small;
    /// otherwise the lowest and highest dozen, so the *range* stays visible.
    /// (Naively truncating a sorted list hides a pressure byte's ceiling.)
    let values: [Int]
    /// True when `values` omits some observed values.
    var truncated: Bool?
    /// Every observed value as a 256-bit mask, low byte first, hex encoded.
    /// Authoritative when `truncated` is set — see
    /// `DiscoveryByteValueSet.valueMaskHex` for why the list alone misleads.
    var valueMask: String?
    /// Largest magnitude when this byte is read as signed. Compare a candidate
    /// tilt divisor against this, not against `max`, which reads 255 for any
    /// field that simply goes negative.
    var signedMagnitudeMax: Int?
    /// Bit positions that took both 0 and 1 across the session.
    ///
    /// On a device whose descriptor is opaque — every classic Wacom pad and
    /// remote — this is the closest thing to a button map the capture can
    /// offer, because each key is one toggling bit. Reading it beats deriving
    /// it from `values` by hand, which is what triaging such a device
    /// otherwise requires.
    var bitsToggled: Int?
    /// Bit positions set in at least one sample. A bit present here but
    /// absent from `bitsToggled` was set in every sample, marking it a
    /// constant flag rather than a control.
    var bitsSet: Int?
}

struct DiscoveryReportSummary: Codable {
    let reportID: UInt8
    /// Length of the first sample seen. Equal to `maxLength` unless
    /// `lengthVaried`.
    let length: Int
    /// Longest sample seen for this report ID.
    var maxLength: Int
    /// True when this report ID arrived with more than one length. Byte
    /// positions beyond the shortest sample are reported in `optionalBytes`
    /// rather than being called constant or varying.
    var lengthVaried: Bool
    let sampleCount: Int
    var varyingBytes: [Int]           // positions present in every sample that took >1 value
    var constantBytes: [Int]          // positions present in every sample that took exactly 1
    /// Positions present in only *some* samples (short reports). Neither
    /// constant nor varying can be claimed honestly for these.
    var optionalBytes: [Int]?
    var firstSample: String?          // hex string of first captured sample
    var constantValues: [Int]?        // values at `constantBytes`, same order
    /// Per-byte statistics, keyed by byte index. Covers every position that
    /// took more than one value, plus every optional position.
    var byteStats: [Int: DiscoveryByteStat]?
    /// Whether the HID report descriptor exposes at least one standard-usage
    /// field for this report ID (see `LiveHIDDescriptorInspector.Field.isReadable`).
    /// `false` flags a report whose bytes vary (real signal, per the above
    /// fields) but whose meaning is opaque from the descriptor alone — the
    /// triage-relevant case, since those bytes need a captured-sample
    /// correlation pass instead of a descriptor read. `nil` if no descriptor
    /// was available to check.
    var descriptorReadable: Bool?
    /// Repeating byte-stride structure found in this report's own varying
    /// bytes — see `RepeatingReportStructureDetector` in TabletKit.
    ///
    /// Exists for exactly the reports `descriptorReadable == false` flags:
    /// with no descriptor to read, `varyingBytes` is otherwise a flat list of
    /// positions with no hint that they are, say, four repeats of a 43-byte
    /// touch frame rather than one 174-byte record. That repeat is the single
    /// most useful fact in a capture of an unrecognized device, and the
    /// hardest one to notice by reading the byte list. `nil` when no
    /// structure cleared the detector's thresholds, which is the correct and
    /// common answer for reports with real varying bytes and no repeat.
    var repeatingStructure: DiscoveryRepeatingStructure?
    /// `byteStats` further split by the value at byte position 1 — see
    /// `DiscoveryAccumulator.ReportStats.discriminatorByteIndex`. Keyed by
    /// that value as a two-digit uppercase hex string (JSON object keys must
    /// be strings; hex keeps it legible next to `firstSample`).
    ///
    /// Present only when byte 1 looks like a packet-type/status field rather
    /// than more coordinate data: more than one but no more than
    /// `CaptureEngine.discriminatorMaxDistinct` values observed. Below that
    /// threshold this is genuinely absent, not merely omitted — reading a
    /// capture file without it means byte 1 was constant for every sample of
    /// this report, or its own stats already told the whole story.
    var byteStatsByDiscriminator: [String: DiscoveryDiscriminatedStats]?
    /// How long this report ID went between arrivals — `captureVersion` 14+.
    /// `captureVersion` 13 and earlier recorded what each report *contained*
    /// but nothing about when it arrived, so a Bluetooth stream that stalls
    /// mid-gesture — the two-finger-scroll coast that dies because the touch
    /// stream stopped feeding the momentum path before the finger lifted —
    /// left no trace in the file. Present for every report ID; `nil` only for
    /// a report that arrived exactly once (no gap to measure).
    var arrivalGaps: DiscoveryArrivalGaps?
}

/// Inter-arrival timing for one report ID: a fixed-bucket histogram of the
/// gaps between consecutive reports, plus the longest few kept whole with
/// the session-elapsed time each ended at.
///
/// The histogram shows the *shape* of a stall — one clean multi-hundred-ms
/// dropout reads as a single count in a high bucket, a gradual thinning as a
/// spread across the middle buckets. The retained longest gaps show *where*:
/// clustered at gesture ends, or scattered through the session.
///
/// `inGestureBuckets` / `idleBuckets` split `buckets` by whether a touch
/// contact was down at both ends of the gap. A finger-off pause between
/// flicks lands in `idle`; a stall while the finger stays on the tablet
/// lands in `inGesture` — which is the one that matters for "why did the
/// coast die". Both are nil unless the driver supplied touch state (it does
/// for the USB touch report; not yet for the Bluetooth 0x80 wrapper, whose
/// touch frames are packed inside it and never reach this counter as their
/// own report — there `buckets` is wrapper-arrival cadence, not touch).
struct DiscoveryArrivalGaps: Codable {
    /// Upper edges of the histogram buckets, in milliseconds, copied from
    /// `DiscoveryAccumulator.ReportStats.gapBucketEdgesMs` so a reader has
    /// them without the source. Each bucket array is one longer — the final
    /// slot counts everything at or above the last edge.
    let bucketEdgesMs: [Double]
    /// Gap count per bucket, every gap regardless of contact state.
    /// `buckets[0]` is `< bucketEdgesMs[0]`; the last entry is
    /// `>= bucketEdgesMs.last`.
    let buckets: [Int]
    /// Subset of `buckets`: gaps with a contact down at both ends — a stall
    /// mid-gesture. Nil when no touch state was available.
    let inGestureBuckets: [Int]?
    /// Subset of `buckets`: gaps with no contact at one or both ends — idle
    /// between gestures, or the lift boundary. Nil when no touch state was
    /// available.
    let idleBuckets: [Int]?
    /// The longest gaps, largest first.
    let longestGaps: [Gap]

    /// One retained gap: its length and the session-elapsed time it closed at.
    struct Gap: Codable {
        let ms: Double
        /// Milliseconds from session start to the arrival that ended this gap.
        let endedAtSessionMs: Double
    }
}

/// One discriminator-value bucket of `DiscoveryReportSummary
/// .byteStatsByDiscriminator` — the byte stats for every sample of a report
/// where byte 1 held one particular value, plus how many samples that was.
struct DiscoveryDiscriminatedStats: Codable {
    let sampleCount: Int
    var byteStats: [Int: DiscoveryByteStat]
}

/// One reported run of repeating byte-stride structure, at one nesting level.
/// Mirrors `TabletKit.RepeatingRun` for JSON output — see that type's doc
/// comment for what each field claims and how it is scored.
struct DiscoveryRepeatingRun: Codable {
    let startOffset: Int
    let period: Int
    let repeatCount: Int
    let matchFraction: Double
}

/// A detected repeating structure, with an optional one-level-deeper nested
/// run. Mirrors `TabletKit.RepeatingReportStructure`.
struct DiscoveryRepeatingStructure: Codable {
    let outer: DiscoveryRepeatingRun
    let nested: DiscoveryRepeatingRun?
}

/// An interface a capture session can record from, weakly held.
///
/// Exists because a device with more than one such interface (PTH-850's pen
/// and touch interfaces both route through `.driver` independently — see
/// `DeviceContext.hidDevice`'s doc comment) is otherwise only ever reachable
/// via whichever one `hidDevice` happens to pin to. `CaptureGuideView` records
/// every one of these at once.
///
/// Only interfaces the driver actually installed a report callback on are
/// listed — see `WacomKnownDevice.deliversReports(from:)`. An interface
/// without one can never produce a sample, so including it would put a
/// permanently empty bucket in every capture file and misrepresent a silent
/// interface (real evidence) as an unlistened one.
final class CaptureInterfaceCandidate {
    weak var device: IOHIDDevice?
    let usagePage: Int

    init(device: IOHIDDevice, usagePage: Int) {
        self.device = device
        self.usagePage = usagePage
    }
}

// MARK: - Device Context for Capture

/// Lightweight descriptor of a device being captured.
/// Passed to CaptureEngine when collection starts.
struct CaptureDeviceInfo {
    let vendorID: Int
    let productID: Int
    let name: String
    let locationID: String?
    var manufacturer: String? = nil
    var transport: String? = nil
    var parsedDescriptor: LiveHIDDescriptorInspector.Parsed? = nil
    /// HID primary usage page/usage of the specific interface this describes.
    /// Every field above is a property of the *tablet* and is identical across
    /// its interfaces; these two are what tell them apart in the capture file.
    var usagePage: Int? = nil
    var usage: Int? = nil

    var vendorIDHex: String   { String(format: "0x%04X", vendorID) }
    var productIDHex: String  { String(format: "0x%04X", productID) }
}
