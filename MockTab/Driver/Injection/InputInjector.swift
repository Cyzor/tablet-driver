// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import os
import TabletKit

let modLog = Logger(subsystem: "com.cyzor.mocktab", category: "modifiers")
let injectLog = Logger(subsystem: "com.cyzor.mocktab", category: "inject")

/// Synthetic-modifier ground truth contributed by aux/express-key bindings
/// (Wacom pad Express Keys, touch-ring center click, and standalone accessories
/// like Xencelabs's QuickKeys puck), shared across every `InputInjector` instance.
///
/// Each physical device gets its own `InputInjector` (see `DeviceContext`), but
/// an aux-only accessory such as QuickKeys is its own device — a Shift it holds
/// has to be visible to whichever *other* InputInjector is actually posting the
/// pointer-drag events (the pen tablet's). Pen-barrel-button modifiers stay on
/// each instance's own `groundTruthSyntheticFlags` instead of here because
/// they're reconciled against that device's own active tool
/// (`InputInjector.reconcileSyntheticFlags`); sharing them globally would let an
/// unrelated device's tool change strip them.
///
/// HIDThread-confined, like the per-instance state it mirrors — all devices'
/// hot paths run on the one shared `HIDThread.shared` run loop.
final class SharedAuxModifierState {
    static let shared = SharedAuxModifierState()
    private init() {}
    var groundTruthFlags = CGEventFlags()
    var refCounts: [UInt64: Int] = [:]
    var lastChangeAt: Date = .distantPast
}

/// Process-wide Scroll Drag gesture routing.
///
/// Each physical device has its own `InputInjector` (see `DeviceContext`), but
/// a Scroll Drag binding can live on a *different* device than the one moving
/// the pointer — e.g. assigned to a Quick Keys puck button while the pen does
/// the panning. The puck's injector sees the button edge; the pen's injector
/// sees the motion. This shared object lets the edge-firing injector engage
/// the gesture on whichever injector is currently driving the pointer (the
/// active pen tablet), so the binding works regardless of which device it's
/// physically on. Barrel-button bindings on the pen itself resolve to the
/// same single instance, so this is a no-op for the common case.
///
/// HIDThread-confined, like the per-injector `panScroll` state it coordinates.
final class SharedPanScrollState {
    static let shared = SharedPanScrollState()
    private init() {}
    /// The injector currently hosting the live gesture, if any.
    weak var driver: InputInjector?
}

/// Converts raw TabletPoint reports into CGEvents and posts them to the HID event tap.
///
/// Event sequence per report:
///   • Proximity change  → tabletProximity event (immediate)
///   • Every in-proximity report:
///       1. tabletPointer  — raw pressure/tilt for Qt/GTK (Krita, GIMP)
///       2. mouse event    — leftMouseDown / leftMouseDragged / leftMouseUp / mouseMoved
///          with .mouseEventPressure + .mouseEventSubtype=tabletPoint + .mouseEventClickState
///
/// Throughput strategy:
///   Posts CGEvents only when position or pressure changes meaningfully (delta gate).
///   When the pen is stationary the tablet still sends 133 Hz reports with identical
///   coordinates; the gate suppresses all of them — zero Mach IPC, zero wakeups.
///   Tip/button/proximity transitions always post immediately regardless of delta.
///
/// Hot-path state owned by HIDThread; configuration writes from main are documented
/// per-property below. `init`, `deinit`, `installFlagsChangedTap`, and the
/// `recompute…` helpers run on main; `inject`, `injectAux`, `injectMouseButtons`,
/// and everything they transitively call run on HIDThread (the dedicated CFRunLoop
/// thread declared in HIDThread.swift). Snapshot updates from the @MainActor
/// `TabletSettings` are pushed via CFRunLoopPerformBlock onto HIDThread so the
/// hot path never needs to read @Published storage directly.
///
/// `@unchecked Sendable`: cross-thread access is synchronized manually per the
/// scheme above (HIDThread confinement for hot-path state, locks elsewhere).
///
/// The class spans five files: this one holds every stored property (Swift
/// extensions can't) plus init/teardown and the cross-cutting helpers, while
/// the sibling `InputInjector+*.swift` extensions hold the pen hot path
/// (+PenInjection), finger touch (+Touch), express keys/rings/wheels
/// (+AuxInput), and the CGEvent posting layer (+CGEvents). The threading rules
/// above apply unchanged across all of them.
final class InputInjector: @unchecked Sendable {

    // MARK: - Device identity

    var deviceVendorID: Int
    var deviceProductID: Int

    /// Whether this device's raw touch-ring position counts opposite the
    /// normalized convention (positive delta = physically clockwise).
    ///
    /// This flag only normalizes raw hardware polarity — it says nothing about
    /// which way clockwise should scroll. That's applied once, uniformly,
    /// downstream in `dispatchRingDelta` from `InputInjector.naturalScrollingEnabled`.
    ///
    /// Ring polarity is a per-firmware-family hardware fact, not a universal
    /// one. Hardware-observed so far: `.cintiqV1` (DTK-2400, both bezel rings)
    /// counts clockwise; `.intuosV1` (PTH-850) counts counter-clockwise, so it
    /// needs the flip. `.intuosV2` (PTH-660/860) is assumed clockwise (grouped
    /// with `.cintiqV1`) but is untested — the only family resting on that
    /// assumption. Resolved once at init rather than per report. If a third
    /// polarity convention ever appears, promote this to a registry field next
    /// to the other per-device hardware facts.
    let ringDeltaIsInverted: Bool
    var activeToolSettings: ToolSettings? = nil {
        didSet { reconcileSyntheticFlags() }
    }
    /// When true the active tool is a cordless mouse.
    /// tipDown is driven by penButton1 instead of pressure, and button1 is
    /// not dispatched as a separate button action (it already fires the primary click).
    var activeToolIsMouse: Bool = false
    /// Cached eraser flag. Primary source: set by TabletManager.onToolEnter from ToolIdentity.isEraser
    /// when the tool code changes (covers tool-flip without a proximity gap). Also refreshed at
    /// proximity entry from point.eraser as defense-in-depth; cleared at proximity exit.
    var activeToolIsEraser: Bool = false
    /// Serial number of the active tool. Set by TabletManager.onToolEnter; 0 if unavailable.
    /// Used in proximity events so apps key per-tool brush memory on the correct identity.
    var activeToolSerial: UInt32 = 0
    /// The tool code for the current tool. Used for proximity events and tool identification.
    var activeToolCode: UInt16 = 0x0802

    /// When true, the frontmost app consumes `.tabletPointer` CGEvents (Qt/GTK: Krita, GIMP).
    /// Set by AppWatcher on every app switch. When false, postTabletPointerEvent is skipped,
    /// saving one WindowServer IPC round-trip per inject() call.
    var activeAppNeedsTabletPointerEvents: Bool = false

    /// Per-app input profile, set by AppWatcher on every app switch.
    ///
    /// `finderPlainMouse` (Finder): pressure fluctuation while the tip is held
    /// on one spot must not emit drag events — Finder's desktop icon view
    /// cancels its pending rename-edit on any leftMouseDragged after the
    /// down, so a stationary pen click could never enter rename mode (window
    /// views tolerate the sub-threshold drags; the desktop does not). Like
    /// `pagesPlainMouse`, it also opts out of proximity events and tip-up
    /// assist (the `== .generic` gates); unlike it, tablet fields stay on
    /// the events — Finder ignores them and the smaller diff is safer.
    enum AppInputProfile { case generic, pagesPlainMouse, finderPlainMouse }
    var activeAppProfile: AppInputProfile = .generic

    /// True when this device is the active context (TabletManager.activeContext === me).
    /// Set from main when active changes; read from HIDThread to gate the inline
    /// inject path. Backed by `OSAllocatedUnfairLock` so cross-thread reads/writes
    /// don't rely on incidental Bool atomicity, which the Swift language model
    /// does not guarantee even on Apple Silicon.
    private let _isActive = OSAllocatedUnfairLock<Bool>(initialState: false)
    var isActive: Bool {
        get { _isActive.withLock { $0 } }
        set { _isActive.withLock { $0 = newValue } }
    }

    /// Every live `InputInjector` (weakly held), so the shared-aux-modifier leak
    /// watchdog can ask "is any device anywhere still holding an aux button?"
    /// before releasing a bit contributed by a *different* device's aux binding.
    /// `add()` happens on main (init); the read happens on HIDThread (leak
    /// watchdog) — `NSHashTable` itself isn't synchronized across that, so both
    /// sides go through this lock. (Per-instance fields it reads, like
    /// `lastAuxButtons`, are safe to read unlocked here because every device's
    /// hot path is confined to the one shared `HIDThread.shared` run loop, so
    /// the reader and the writer of those fields are always the same thread.)
    ///
    /// `NSHashTable` isn't `Sendable`; the wrapper vouches for it because
    /// every access goes through the lock.
    private struct LiveInjectors: @unchecked Sendable {
        let table: NSHashTable<InputInjector> = .weakObjects()
    }
    private static let liveInjectorsLock = OSAllocatedUnfairLock(initialState: LiveInjectors())

    /// Every live injector, for cross-device gesture routing. Callers run on
    /// HIDThread; the table itself is lock-protected.
    static var allLiveInjectors: [InputInjector] {
        liveInjectorsLock.withLock { $0.table.allObjects }
    }

    /// True while any registered device still shows an aux button, touch-ring
    /// center click, or touch-ring/strip contact held — the shared aux-modifier
    /// release check must not fire while this is true, even if the specific
    /// device that raised the modifier has gone idle (QuickKeys-style accessories
    /// only report on state change, so idle IS the normal shape of a long hold).
    fileprivate static var anyAuxControlHeld: Bool {
        liveInjectorsLock.withLock { live in
            for injector in live.table.allObjects {
                if injector.lastAuxButtons.contains(true) || injector.lastRingButtonDown
                    || injector.lastRingPos != 0x7F || injector.lastRing2Pos != 0x7F
                    || injector.lastStrip1Pos != 0xFF || injector.lastStrip2Pos != 0xFF
                { return true }
            }
            return false
        }
    }

    // MARK: - Natural scrolling (system-wide, not per-device)

    /// Mirrors `com.apple.swipescrolldirection`: true when System Settings ›
    /// Mouse/Trackpad › "Natural Scrolling" is on. This is a machine-wide fact,
    /// not a per-tablet one, so it's `static` rather than threaded through
    /// `InjectionSnapshot`.
    ///
    /// Read fresh from `UserDefaults` on every call rather than cached —
    /// `UserDefaults` is documented thread-safe, so this is safe to call from
    /// HIDThread inside `dispatchRingDelta` without extra locking. Confirmed by
    /// direct observation (2026-08-06) that this reflects the system value
    /// within about a second of the switch being toggled, with no distributed-
    /// notification plumbing needed: `SwipeScrollDirectionDidChangeNotification`
    /// exists but distributed-notification delivery to a background utility
    /// app was seen to be unreliable (macOS suspends/coalesces delivery while
    /// the app isn't frontmost), so don't reintroduce a cached+notified flag
    /// here without re-verifying delivery is reliable for a backgrounded app.
    ///
    /// Ring/dial scroll injection posts `CGEvent` scroll-wheel events directly,
    /// which bypass the OS's own natural-scrolling flip (that inversion happens
    /// below CGEvent, for real HID devices) — so `dispatchRingDelta` applies it
    /// itself, using this flag, to reproduce what a real device's driver does.
    static var naturalScrollingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "com.apple.swipescrolldirection")
    }

    @MainActor
    init(vendorID: Int = 0x056A, productID: Int = 0) {
        self.deviceVendorID = vendorID
        self.deviceProductID = productID
        self.ringDeltaIsInverted =
            WacomDeviceRegistry.spec(for: productID)?.parser == .intuosV1
        Self.liveInjectorsLock.withLock { $0.table.add(self) }
        recomputeVirtualScreenBounds()
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Recompute the virtual-screen union on main (NSScreen is AppKit-only),
            // then push display-cache invalidation onto HIDThread where the cached
            // fields are read by inject().
            guard let self else { return }
            MainActor.assumeIsolated { self.recomputeVirtualScreenBounds() }
            CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) {
                self.displayMapper.invalidateDisplayCache()
            }
            CFRunLoopWakeUp(HIDThread.shared.runLoop)
        }
        leakWatchdogTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true
        ) { [weak self] _ in self?.checkLeakWatchdog() }
        installFlagsChangedTap()
    }

    deinit {
        if let obs = displayObserver { NotificationCenter.default.removeObserver(obs) }
        leakWatchdogTimer?.invalidate()
        if let src = flagsChangedTapSource {
            CFRunLoopRemoveSource(HIDThread.shared.runLoop, src, .commonModes)
            flagsChangedTapSource = nil
        }
        if let tap = flagsChangedTap { CGEvent.tapEnable(tap: tap, enable: false) }
        watchdogTimer.map { CFRunLoopTimerInvalidate($0) }
        pendingMouseUp.map { CFRunLoopTimerInvalidate($0) }
        proximityExitDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
        panScrollSafetyNetTimer.map { CFRunLoopTimerInvalidate($0) }
        panMomentumTail.cancel()
        touchMomentumTail.cancel()
        dialCoaster.cancel()
        button1UpDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
        button2UpDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
        button3UpDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
    }

    // MARK: - State
    //
    // Several fields below are `internal` (no `private`) rather than truly
    // private: the injection paths were split across InputInjector+*.swift
    // extension files, and Swift's `private` is file-scoped, so state shared
    // with those extensions has to be visible module-wide. It's still
    // conceptually owned here and HIDThread-confined exactly as each comment
    // describes — the access level widened, the ownership contract did not.

    var lastProximity = false
    var lastTipDown = false
    /// True after the first leftMouseDragged is posted following a tip-down.
    /// Used to guarantee Pages sees at least one drag event even when deltas are tiny.
    var didEmitDragSinceDown = false
    /// Screen position at the moment the tip went down. Anchor for the drag
    /// threshold gate — see `TabletSettings.dragThreshold`.
    var tipDownOrigin: CGPoint = .zero
    var lastEraserMode = false  // Track eraser/tip flip while in proximity
    // Named per-button fields rather than an array/dictionary, deliberately:
    // this runs at 133 Hz on the HID hot path, where a direct field read beats
    // a collection's bounds-check/hash overhead, and named fields stay readable
    // in a debugger during real-hardware sessions.
    var lastButton1Down = false
    var lastButton2Down = false
    var lastButton3Down = false
    var lastMiddleDown = false
    var activeButton: CGMouseButton = .left

    // MARK: - USB mouse button state
    //
    // For KC-100 cordless mouse over USB: buttons arrive on a separate standard
    // HID mouse interface (Report ID 0x01) rather than in the digitizer 0x10 stream.
    // injectMouseButtons() is called from that interface's device driver; inject()
    // reads usbMouseLeftHeld to decide drag vs hover when emitting movement events.
    var lastUSBMouseMask: UInt8 = 0
    var usbMouseLeftHeld: Bool = false

    // MARK: - Report timestamp carrier
    //
    // Kernel receipt time of the HID report currently being handled, already
    // converted to CGEventTimestamp nanoseconds; 0 when the current post is
    // not driven by a timestamped report (timer-fired deferred mouseUps,
    // debounce releases, proximity-exit commits — those correctly keep the
    // default now-timestamp, and clearing on report exit guarantees a stale
    // stamp is never replayed after fresher events have posted).
    //
    // Static and HIDThread-confined: one HIDThread serves every device
    // context, set by WacomKnownDevice.handleReport around each report and
    // read only in finalizeAndPost on the same thread.
    static var currentReportTimestampNs: UInt64 = 0

    // MARK: - Cursor smoothing, jitter, velocity
    //
    // Per-report position smoothing (EMA), rolling jitter window, and short-window
    // velocity for tip-up assist. State and math live in CursorSmoother.swift;
    // InputInjector holds the instance and forwards reads where needed.

    var smoother = CursorSmoother()

    /// Mean hover-position delta over the rolling window (points per sample).
    /// Spikes above ~3 pt/sample while hovering suggest RF interference.
    var jitterLevel: CGFloat { smoother.jitterLevel }
    var isJittery: Bool { smoother.isJittery }
    /// Cumulative histogram of hover-jitter samples, never reset by
    /// tip-down/proximity-exit transitions — see `CursorSmoother.jitterHistogram`.
    var jitterHistogram: [UInt64] { smoother.jitterHistogram }

    /// Per-report pressure smoothing (opens up as pressure rises toward a
    /// firm stroke, unlike the position filter above which opens up with
    /// speed). State and math live in PressureSmoother.swift.
    var pressureSmoother = PressureSmoother()

    // MARK: - Delta gate
    //
    // Skip posting to the Window Server when position and pressure haven't changed
    // meaningfully. The tablet sends identical coordinates at 133 Hz while stationary;
    // suppressing those drops Mach IPC to zero and eliminates idle wakeups entirely.

    static let positionEpsilon: CGFloat = 0.5  // sub-pixel, not worth posting
    static let pressureEpsilon: Double = 0.002

    // MARK: - Stale-report suppression
    //
    // Under severe system-wide scheduling starvation (observed with a local
    // LLM saturating GPU/unified memory), HID reports back up somewhere
    // upstream of HIDThread and arrive in a rapid burst once the OS resumes
    // scheduling us. Each report is still decoded and cheap to post
    // individually (LatencyProbe's stage-2 − stage-1 delta stays under a
    // millisecond even during a multi-second backlog — posting was never the
    // bottleneck), but faithfully posting every backlogged point makes the
    // cursor visibly animate through several seconds of stale history before
    // catching up to the pen's real position — a "ghost cursor" trailing
    // behind. This only suppresses the *plain hover-move* post
    // (`postMouseMoved` in the final `else` branch of the movement gate in
    // `inject()`) — drag/pan/tablet-pointer-event posts are untouched, so
    // clicks, drags, and stroke data are never suppressed or delayed.
    //
    // A rate-limited "post a throttled sample of the backlog" version was
    // tried first and was hardware-tested unconvincing — it still visibly
    // played through old intermediate positions, just fewer of them. Full
    // suppression while stale (`isStaleHoverMove` in
    // InputInjector+PenInjection.swift) freezes the cursor and jumps once,
    // directly to the real position, when live data resumes — no
    // intermediate history shown at all, hence no per-flush state needed
    // here beyond the threshold itself.

    /// A report whose kernel timestamp is older than this by the time it's
    /// decoded is backlog, not a live sample — see the section doc above.
    static let staleReportThresholdMs: Double = 50.0

    // MARK: - Tip-down pressure threshold
    //
    // Curve-mapped pressure above which a report counts as tip contact (drives
    // tipDown detection, the tabletEventPointButtons tip bit, and the Info
    // pane's button readout). ~4 raw counts on a 10-bit/1023 sensor.
    //
    // Deliberately left where it has always been. A GD-0608-U (Intuos 6×8,
    // 1024-level EMR pressure) field report showed hover-only sensor noise at
    // 3-4 raw counts spiking to ~7 — right on top of this threshold, producing
    // phantom tip-down clicks and hairline strokes while the pen never touched
    // the surface. Raising this constant would fix that tablet by firming up
    // contact onset on every device, including 8191-level sensors where the
    // same fraction is a far larger absolute step, and none of those can be
    // re-verified here. `ToolSettings.pressureThreshold` is the scoped fix: a
    // per-tool dead zone that covers a noisy baseline without moving this
    // shared floor. Revisit only if bug reports show the dial is insufficient.
    static let tipPressureThreshold: Double = 0.004

    /// Applies a tool's pressure LUT (dead zone + response curve) to a raw
    /// normalized sensor reading. Shared by the injection path and the Info
    /// pane so the pane's tip indicator can't disagree with what gets injected.
    static func curvedPressure(_ normalized: Double, lut: [Double]) -> Double {
        let idx = Swift.min(Swift.max(Int((normalized * 255.0).rounded()), 0), 255)
        return lut[idx]
    }

    // MARK: - Tip-up assist
    //
    // When the delay (TabletSettings.tipUpAssistDelay, ms) is above zero, delays the
    // mouseUp briefly after the tip lifts if the pen is still in motion. This prevents
    // accidental stroke termination from light tip-release during fast strokes. The
    // pending mouseUp is cancelled if the tip comes back down.

    static let tipUpAssistVelocityThreshold: CGFloat = 2.0  // pts/sample
    /// One-shot CFRunLoopTimer scheduled on HIDThread (NOT the main queue —
    /// a congested main thread must not be able to stretch the 80 ms delay).
    /// Fires and is cancelled on HIDThread, same thread as all per-report state.
    var pendingMouseUp: CFRunLoopTimer? = nil

    /// Must run on HIDThread (or deinit, after all callbacks are unregistered).
    func cancelPendingMouseUp() {
        if let t = pendingMouseUp { CFRunLoopTimerInvalidate(t) }
        pendingMouseUp = nil
    }

    /// Set while a barrel-button click binding is held, so the movement path posts
    /// otherMouseDragged / rightMouseDragged instead of mouseMoved.
    var hoverDragButton: CGMouseButton? = nil

    // MARK: - Scroll Drag (pan/scroll button binding)

    /// State machine for the .scrollDrag binding — see PanScrollTracker.swift.
    /// While engaged, the pen movement path posts phased pixel scroll events
    /// instead of cursor motion.
    var panScroll = PanScrollTracker()

    /// Timestamp of the previous pen frame, for the tracker's velocity EMA.
    /// 0 = unknown (first frame after launch); dt is skipped that frame.
    var lastPanScrollFrameTime: CFAbsoluteTime = 0

    /// One-shot HIDThread timer that force-closes a pan gesture whose owning
    /// button's release was genuinely lost (pen set down out of range and the
    /// release report never arrived). Scheduled when proximity exits with a
    /// pan active; cancelled on the normal release edge. Without it a lost
    /// release would leave the gesture — and its held button state — on
    /// forever, since the gesture now (correctly) survives proximity exit.
    var panScrollSafetyNetTimer: CFRunLoopTimer?
    /// How long a pan may sit suspended (pen out of range, no release seen)
    /// before it's force-closed as a presumed-lost gesture. Matches the
    /// proximity-exit held-button safety interval.
    let panScrollSafetyNetInterval: TimeInterval = 4.0

    /// Synthetic momentum decay tail posted after a Scroll Drag release in
    /// Natural mode. See MomentumTail.swift for the decay model.
    ///
    /// `[weak self]` is load-bearing: this object owns the tail, so a strong
    /// capture in the post closure would be a retain cycle.
    lazy var panMomentumTail = MomentumTail { [weak self] dx, dy, phase in
        self?.postPanScrollMomentum(dx: dx, dy: dy, phase: phase)
    }

    /// Same mechanism, deliberately a *separate instance* so a touch scroll's
    /// tail can't cancel or blend with an in-flight Scroll Drag tail. Only
    /// matters on non-`NSScrollView` apps — `NSScrollView` already synthesizes
    /// its own coast from the phased began/changed/ended stream
    /// `postTouchScroll` posts either way.
    lazy var touchMomentumTail = MomentumTail { [weak self] dx, dy, phase in
        self?.postTouchScrollMomentum(dx: dx, dy: dy, phase: phase)
    }

    /// Inertial emitter for the Xencelabs dial. Unlike the two tails above this
    /// one is the *only* thing that posts scroll for its input — see
    /// `DialScrollCoaster` for why the dial needs that shape.
    lazy var dialCoaster = DialScrollCoaster { [weak self] dy in
        self?.postDialScroll(dy: dy)
    }

    /// Panning method, captured at engage from `ToolSettings.panScrollMomentum`.
    /// `true` (Momentum, default): the stream carries the phased began/changed/
    /// ended envelope plus a synthetic momentum tail. NSScrollView-based apps
    /// (Finder, Xcode) read that as a real trackpad flick — rubber-banding and
    /// coasting. Gesture-keyed recognizers (Calendar Month/Year, WebKit
    /// gesture-scroll / overscroll-behavior, Adobe palettes) ignore it — turn
    /// momentum off for those.
    ///
    /// `false` (Compatible): the pan stream is deliberately phase-FREE
    /// (`scrollWheelEventScrollPhase = 0`, no began/changed/ended envelope, no
    /// momentum tail). A real trackpad wraps its continuous deltas in a phase
    /// lifecycle plus a companion gesture-event stream, but that gesture backing
    /// can't be forged through the public CGEvent API — and without it, the
    /// phased envelope is rejected by the recognizers named above. Captured
    /// third-party scroll tools (Smooze) that pan those apps smoothly emit
    /// exactly this phase-free shape. Per-app opt-out where momentum isn't
    /// honored.
    var panScrollUsePhases = true

    var lastPostedPoint: CGPoint = .zero
    var lastPostedPressure: Double = -1.0
    var hasPostedPoint = false

    // MARK: - Click state

    private var lastClickPosition: CGPoint = .zero
    private var lastClickTime: CFAbsoluteTime = 0
    private var clickCount: Int = 0
    var activeClickCount: Int = 1

    // MARK: - Express key / touch ring state

    var lastAuxButtons = [Bool](repeating: false, count: 19)
    var lastRingButtonDown = false
    /// Last observed touch ring position (0–71). 0x7F = no contact.
    var lastRingPos: UInt8 = 0x7F
    /// Last observed right touch ring position (DTK-2400). 0x7F = no contact.
    var lastRing2Pos: UInt8 = 0x7F
    /// Last observed Intuos3 WS touch strip positions. 0xFF = no contact.
    var lastStrip1Pos: UInt8 = 0xFF
    var lastStrip2Pos: UInt8 = 0xFF
    /// Fractional-delta accumulators for ring/strip speed scaling.
    /// Carry sub-integer remainders across pulses so speed < 1.0 fires evenly.
    var ringAccum: Double = 0
    var ring2Accum: Double = 0
    var strip1Accum: Double = 0
    var strip2Accum: Double = 0
    /// Fractional-delta accumulators for IntuosV3 relative scroll wheels (index 0 and 1).
    var wheel0Accum: Double = 0
    var wheel1Accum: Double = 0

    // MARK: - Synthetic-modifier safety valves

    /// Idle watchdog. If the driver thinks a modifier is held but no tablet
    /// activity arrives for `watchdogInterval`, release all synthetic flags.
    /// Rearmed on every inject/injectAux/injectMouseButtons/fireButtonAction.
    /// At 133 Hz pen reporting this never expires during legitimate holds —
    /// the pen leaving the tablet is what stops the stream, at which point
    /// any still-held synthetic flag is by definition a leak.
    /// CFRunLoopTimer scheduled on HIDThread. The handler reads/writes
    /// HIDThread-owned modifier state without crossing a thread boundary.
    private var watchdogTimer: CFRunLoopTimer?
    private let watchdogInterval: TimeInterval = 0.4

    /// How long the tablet may sit idle while `lastProximity` is still true
    /// before the 1Hz leak watchdog forces a proximity exit. See that
    /// watchdog's stuck-proximity block for the decoder-side asymmetry this
    /// backstops. A pen genuinely in proximity reports continuously at
    /// 100+ Hz, so this never fires during real use.
    private static let stuckProximityTimeout: TimeInterval = 2.0

    /// Xencelabs-only: holds off the proximity-exit cleanup below so range
    /// loss doesn't cut a held barrel-button click/modifier short. This
    /// hardware's out-of-range tag (`XencelabsDecoder.tagOutOfRange`) trips
    /// at a noticeably shorter distance than Wacom's, so ordinary tilt/lift
    /// during a gesture crosses it far more readily; confirmed against
    /// Xencelabs's own driver, which visibly keeps a barrel-button click
    /// (e.g. a context menu opened via right-click) held through range loss
    /// and only releases it once the pen returns and reports the button
    /// actually up. Wacom tablets don't need this — gated to vendorID
    /// 0x28BD to avoid adding mouse-up latency to every pen lift elsewhere.
    ///
    /// Two regimes, chosen when the exit is scheduled (see the scheduling
    /// site): if no tip/barrel/mouse button is held, a short fixed debounce
    /// just absorbs a stray hover blip. If one *is* held, cleanup is deferred
    /// for much longer — genuinely indefinitely, in spirit — because the
    /// correct resolution is "wait for the pen to come back and tell us
    /// the real button state," not "guess after some safe delay." The long
    /// interval is purely a safety net (disconnect, pen set down and
    /// forgotten) so a click can't get stuck forever.
    var proximityExitDebounceTimer: CFRunLoopTimer?
    let proximityExitDebounceInterval: TimeInterval = 0.15
    let proximityExitHeldButtonSafetyInterval: TimeInterval = 4.0

    /// Xencelabs-only: a *small* debounce on the barrel-button up edge, and
    /// deliberately nothing more. This hardware's button-contact sensing
    /// range is shorter than its position range, so a held button chatters
    /// off/on for a frame or two while the pen rides that boundary even with
    /// proximity fully maintained — the proximity-exit path above never sees
    /// these because proximity never drops. Left raw, each blip is a real
    /// release+re-press: a held right-click menu flickers, a held pan
    /// hiccups. No hand can release and re-press a button in ~15 ms, so
    /// bridging only that sub-perceptual window reads the hardware's intent
    /// more faithfully than a naive frame-by-frame reading — it doesn't
    /// fight the hardware, it declines to believe the physically impossible.
    ///
    /// Only the up edge is deferred (a press always fires instantly); a
    /// reassert within the window cancels the pending release so nothing
    /// downstream saw it. The window is small on purpose: chatter clusters
    /// under ~30 ms, but its tail overlaps the fastest deliberate
    /// double-tap (~120 ms), so a wider window can't separate the two
    /// without merging a real double-click into one hold. It sits at the
    /// bottom of the deliberate range — long dropouts (a real pen lift
    /// mid-flick) pass through as honest re-clicks rather than being glued
    /// shut, which is the sticky feel an earlier 0.15–0.25 s window was
    /// rejected for. Override live for tuning without a rebuild:
    ///   defaults write <bundle-id> MockTabXencelabsButtonDebounceMS 60
    var button1UpDebounceTimer: CFRunLoopTimer?
    var button2UpDebounceTimer: CFRunLoopTimer?
    var button3UpDebounceTimer: CFRunLoopTimer?

    /// How long ago the physical button-up happened, for a release currently
    /// being committed out of the debounce above. Nonzero only for the
    /// duration of that deferred `fireButtonAction` call; 0 for every
    /// immediate (Wacom, and all non-barrel) release. Read by `.scrollDrag`
    /// so a flick's momentum is judged as of the real release edge — see
    /// `PanScrollTracker.disengage(backdate:)`.
    var pendingButtonUpBackdate: TimeInterval = 0
    let buttonUpDebounceInterval: TimeInterval = {
        let ms = UserDefaults.standard.integer(forKey: "MockTabXencelabsButtonDebounceMS")
        return ms > 0 ? Double(ms) / 1000.0 : 0.05
    }()

    /// Longer up-debounce used *only* for right-click / eraser bindings, so a
    /// contextual menu opened with the barrel button stays engaged when the
    /// pen is lifted out of proximity while the button is physically held.
    ///
    /// The mechanism: this hardware's button-sensing range is shorter than
    /// its proximity range, so on a lift the button *bit* drops a beat
    /// (~55–130 ms observed) before full proximity loss. The held-through-
    /// lift behavior relies on the proximity-exit deferral cancelling the
    /// pending release once proximity drops — which only happens if the
    /// release hasn't already committed. So the window must outlast that
    /// travel gap; 0.05 s (the pan/flick value) is far too short and would
    /// fire rightMouseUp mid-lift, activating the highlighted menu item.
    ///
    /// Keyed on binding *kind*, not inferred intent: the user declared this
    /// button a right-click, and menu release-latency is imperceptible (the
    /// menu opens on button-down; a late up just delays committing the
    /// highlighted item), so erring long is free. 0.25 s clears every
    /// travel gap in the captures with margin. Left/middle/drag bindings
    /// stay on the short window — they're latency-sensitive (tap, pan) and
    /// were never part of the hold-through-lift behavior.
    ///
    /// Residual limit: a lift slower than 0.25 s reopens the same physics
    /// hole (release commits before proximity drops). Rare, not impossible.
    let buttonUpDebounceMenuInterval: TimeInterval = 0.25

    // MARK: - Time-based leak watchdog
    //
    // Second safety net that fires even when lastAuxButtons is stuck (e.g. USB
    // disconnect mid-press). Unlike the DispatchWorkItem watchdog above, which
    // is only armed while tablet activity is flowing, this 1 Hz timer runs
    // continuously and does not depend on quiescence flags being correct.

    private var leakWatchdogTimer: Timer?
    /// Timestamp of the last groundTruthSyntheticFlags mutation.
    var lastSyntheticFlagChangeAt: Date = .distantPast
    /// Timestamp of the last tablet HID report (inject / injectAux / injectMouseButtons).
    /// Stamped inside rearmWatchdog(), which every entry point calls.
    private var lastInjectCallAt: Date = .distantPast

    // MARK: - Physical modifier state tap
    //
    // Passive CGEvent tap that watches for flagsChanged events at the session level,
    // filtered to hardware-originated events only (sourceStateID == hidSystemState).
    // Keeps tapLastPhysicalFlags current so currentEventFlags can combine physical
    // and synthetic modifier state for state-change events (mouseDown/mouseUp).
    //
    // IMPORTANT: our own injected flagsChanged events (posted via .cghidEventTap from
    // sessionSource = .privateState) DO write into hidSystemState — the earlier comment
    // claiming otherwise was wrong.  Reading hidSystemState inside the callback would
    // therefore reflect our own synthetic presses, poisoning tapLastPhysicalFlags.
    // Filtering by sourceStateID and reading event.flags directly avoids this entirely.

    var flagsChangedTap: CFMachPort?
    var flagsChangedTapSource: CFRunLoopSource?
    /// Physical modifier bits (⌘⌥⇧⌃) last reported by a hardware flagsChanged event.
    /// Updated only from events with sourceStateID == hidSystemState; immune to our own
    /// synthetic flagsChanged posts.
    var tapLastPhysicalFlags: UInt64 = 0

    /// True when no physical tablet control is held. If this holds and
    /// `groundTruthSyntheticFlags` is non-empty, the flags are a leak.
    var tabletIsQuiescent: Bool {
        !lastTipDown && !lastButton1Down && !lastButton2Down && !lastButton3Down
            && !lastMiddleDown
            && !lastRingButtonDown
            && lastRingPos == 0x7F && lastRing2Pos == 0x7F
            && lastStrip1Pos == 0xFF && lastStrip2Pos == 0xFF
            && lastUSBMouseMask == 0
            && !lastAuxButtons.contains(true)
    }

    /// Must run on HIDThread (where `watchdogTimer`, `lastInjectCallAt`, and
    /// `groundTruthSyntheticFlags` are owned).
    func rearmWatchdog() {
        lastInjectCallAt = Date()
        if let t = watchdogTimer { CFRunLoopTimerInvalidate(t) }
        watchdogTimer = nil
        guard !groundTruthSyntheticFlags.isEmpty else { return }
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + watchdogInterval,
            0,  // interval — one-shot
            0, 0
        ) { [weak self] _ in
            guard let self, !self.groundTruthSyntheticFlags.isEmpty else { return }
            // Wacom pads stream reports continuously while a key is held (~133 Hz),
            // so reaching this timeout there unambiguously means the stream stopped
            // (proximity loss, disconnect). Xencelabs's QuickKeys puck instead sends
            // one report per state change and nothing while a button sits held — the
            // same idle gap is the *normal* shape of a long hold, not a stall. Trust
            // the last known button state instead of pure idle time; a genuine leak
            // (state stuck with nothing actually down) still gets caught here, and a
            // stuck-but-"held" leak is caught later by the 1 Hz leak watchdog.
            guard self.tabletIsQuiescent else { return }
            self.releaseAllSyntheticModifiers()
        }
        watchdogTimer = timer
        if let timer { CFRunLoopAddTimer(HIDThread.shared.runLoop, timer, .commonModes) }
    }

    /// 1 Hz time-based leak detection. Fires even when `lastAuxButtons` is corrupt
    /// (e.g. USB disconnect mid-press), a scenario where the DispatchWorkItem watchdog
    /// above is never rearmed and therefore never fires.
    ///
    /// Condition: synthetic flags have been stuck in the same state for > 3 s, the
    /// tablet has been completely idle for > 3 s, AND `tabletIsQuiescent` — i.e. no
    /// known button/aux state is still down. That last check matters for devices like
    /// Xencelabs's QuickKeys puck that only report on state change: a long legitimate
    /// hold looks idle by elapsed time alone, but `lastAuxButtons` still shows it down.
    /// Called from main (Timer fires on the runloop the timer was scheduled on).
    /// Hops to HIDThread to read/mutate modifier state without races.
    private func checkLeakWatchdog() {
        CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            let idleInterval = Date().timeIntervalSince(self.lastInjectCallAt)

            // Stuck-pen-proximity backstop. `IntuosV2Decoder+BT` (TabletKit,
            // decodeBTPen) debounces *exit* two ways — an immediate signal
            // when both prox and inRange clear, or a 3-frame threshold for
            // ambiguous boundary noise — but hardcodes `inProximity: true`
            // unconditionally for any frame that survives those checks,
            // including the "continue to decode point data" boundary-noise
            // path (see that file, the frame loop around the `!inRange`
            // branch). There is no equivalent debounce on entry. Confirmed
            // on hardware (2026-08-22): a clean exit fires correctly, but a
            // single noisy report arriving ~11ms later — ordinary BT
            // boundary chatter as the pen actually leaves range — can
            // satisfy the unguarded "valid, not-a-clean-exit" case and
            // re-assert `inProximity: true`. If the tablet then goes truly
            // idle (confirmed separately: zero raw HID reports arrive while
            // genuinely out of range), nothing ever corrects it again —
            // `lastProximity` latches true forever, which silently kills
            // touch (`injectTouch`'s `penBusy` gate reads it) until the
            // process restarts. This is a backstop, not the fix — the real
            // asymmetry lives in the decoder, a separate public repo serving
            // multiple device families, and belongs in its own release
            // rather than a patch under tonight's time pressure. A pen
            // genuinely in proximity streams at 100+ Hz, so idling this long
            // while `lastProximity` is true is unambiguous — no false-fire
            // risk during real use.
            if self.lastProximity, idleInterval > Self.stuckProximityTimeout,
                let snap = self.injectionSnapshot
            {
                injectLog.notice("leak-watchdog: forcing stuck pen-proximity exit (idle \(Int(idleInterval))s) — see IntuosV2Decoder+BT entry-debounce asymmetry")
                self.commitProximityExit(snap: snap)
            }

            guard !self.groundTruthSyntheticFlags.isEmpty else { return }
            let heldInterval = Date().timeIntervalSince(self.lastSyntheticFlagChangeAt)
            // As with the idle watchdog above, a device that only reports on state
            // change (Xencelabs QuickKeys) can sit idle for a long legitimate hold —
            // trust the last known button state, not just elapsed time.
            if heldInterval > 3.0 && idleInterval > 3.0 && self.tabletIsQuiescent {
                modLog.notice("leak-watchdog: releasing stuck synthetic flags 0x\(String(self.groundTruthSyntheticFlags.rawValue, radix: 16), privacy: .public) (held \(Int(heldInterval))s, idle \(Int(idleInterval))s)")
                self.releaseAllSyntheticModifiers()
            }

            // Same leak check for the shared aux-modifier store, but the "is anything
            // still held" question has to look across every device, not just this one —
            // the accessory that raised the bit (e.g. QuickKeys) may be a different
            // InputInjector than the one whose timer happens to be ticking right now.
            let shared = SharedAuxModifierState.shared
            if !shared.groundTruthFlags.isEmpty {
                let sharedHeldInterval = Date().timeIntervalSince(shared.lastChangeAt)
                if sharedHeldInterval > 3.0 && idleInterval > 3.0 && !Self.anyAuxControlHeld {
                    modLog.notice("leak-watchdog: releasing stuck shared aux flags 0x\(String(shared.groundTruthFlags.rawValue, radix: 16), privacy: .public) (held \(Int(sharedHeldInterval))s)")
                    self.releaseSharedAuxModifiers()
                }
            }
        }
        CFRunLoopWakeUp(HIDThread.shared.runLoop)
    }

    // MARK: - Adobe shim replay cache
    //
    // Populated on every inject() call so WacomShim can re-emit the last
    // tablet event in response to an Apple Events eSendTabletEvent request.

    var shimLastPoint: TabletPoint? = nil
    var shimLastScreen: CGPoint = .zero
    var shimLastPressure: Double = 0.0

    // MARK: - Settings snapshot
    //
    // The hot path's only view of settings/tool configuration. Rebuilt by
    // DeviceContext.observeInjectionSnapshot() on every settings/tool change
    // and published onto HIDThread via CFRunLoopPerformBlock, so inject()
    // reads it inline on the same thread that wrote it — no @MainActor hop.

    var injectionSnapshot: InjectionSnapshot?

    // MARK: - Display mapping

    /// Display selection, orientation/crop, calibration, and relative-mode
    /// mapping. See `DisplayMapper.swift`. Caching/threading contract is
    /// unchanged from when this state lived directly on InputInjector: reads
    /// and writes happen on HIDThread except `recomputeVirtualScreenBounds()`,
    /// which callers must invoke on main.
    var displayMapper = DisplayMapper()

    /// Cached touch coordinate maximums, invalidated when `deviceProductID`
    /// changes.  Saves a per-frame linear scan over `WacomDeviceRegistry`.
    var cachedTouchMaxX: Int = 1
    var cachedTouchMaxY: Int = 1
    /// Physical active-surface size, mm. From `WacomDeviceSpec.activeWidthMM`/
    /// `activeHeightMM` — those describe the *pen* active area; treating them
    /// as the touch surface's physical size is an approximation, not a
    /// verified equivalence, but it's what's available. Falls back to the
    /// raw coordinate maximums (i.e. no correction) when the spec has none.
    var cachedTouchWidthMM: Double = 1
    var cachedTouchHeightMM: Double = 1
    var cachedTouchSpecPID: Int = -1
    private var displayObserver: NSObjectProtocol?

    // MARK: - Adobe shim replay

    /// Re-emits the last tablet pointer event.
    /// Called by TabletManager when WacomShim receives an eSendTabletEvent(eEventPointer)
    /// Apple Event from Adobe Photoshop / Illustrator.
    func replayPointerEvent() {
        guard let point = shimLastPoint, let snap = injectionSnapshot else { return }
        let pose = resolveEffectivePose(point: point, snapshot: snap)
        postTabletPointerEvent(
            at: shimLastScreen, pressure: shimLastPressure, point: point, pose: pose,
            snapshot: snap)
        let dragging = lastTipDown || (activeToolIsMouse && usbMouseLeftHeld)
        if dragging {
            postMouseDrag(
                button: activeButton, at: shimLastScreen, pressure: shimLastPressure, point: point,
                pose: pose, snapshot: snap)
        } else {
            postMouseMoved(at: shimLastScreen, point: point, pose: pose, snapshot: snap)
        }
    }

    /// Re-emits the last proximity event.
    /// Called when WacomShim receives eSendTabletEvent(eEventProximity) from Adobe.
    func replayProximityEvent() {
        guard shimLastPoint != nil else { return }
        postProximityEvent(
            entering: lastProximity, at: shimLastScreen,
            eraser: shimLastPoint?.eraser ?? false)
    }

    // MARK: - USB HID mouse button injection (KC-100 cordless mouse)
    //
    // Called by WacomKnownDevice when a 4-byte Report ID 0x01 arrives from the
    // standard mouse interface (usagePage=0x01).  Fires left/right/middle down/up
    // CGEvents at the current cursor location; sets usbMouseLeftHeld so inject()
    // promotes subsequent mouseMoved events to leftMouseDragged while left is held.

    func injectMouseButtons(mask: UInt8, settings: TabletSettings?) {
        rearmWatchdog()
        guard mask != lastUSBMouseMask else { return }
        guard let snap = injectionSnapshot else { return }
        let tool = snap.activeTool
        let loc = currentCursorPosition()
        let oldMask = lastUSBMouseMask
        lastUSBMouseMask = mask

        let leftNow = (mask & 0x01) != 0
        let leftWas = (oldMask & 0x01) != 0
        let rightNow = (mask & 0x02) != 0
        let rightWas = (oldMask & 0x02) != 0
        let midNow = (mask & 0x04) != 0
        let midWas = (oldMask & 0x04) != 0

        if leftNow != leftWas {
            usbMouseLeftHeld = leftNow
            activeButton = .left
            if leftNow {
                let (clickPt, count) = resolveClick(loc, snapshot: snap)
                activeClickCount = count
                postMouseDown(
                    button: .left, at: clickPt, pressure: 1.0, clickCount: count, snapshot: snap)
            } else {
                postMouseUp(button: .left, at: loc, clickCount: activeClickCount, snapshot: snap)
            }
            lastPostedPoint = loc
            hasPostedPoint = true
        }
        if rightNow != rightWas {
            if rightNow {
                postMouseDown(button: .right, at: loc, pressure: 1.0, clickCount: 1, snapshot: snap)
            } else {
                postMouseUp(button: .right, at: loc, clickCount: 1, snapshot: snap)
            }
        }
        // Button 3 (bit 2) — routed through configured binding
        if midNow != midWas {
            fireButtonAction(tool.penButton3Binding, down: midNow, at: loc,
                             snapshot: snap, settings: settings)
        }
        // Button 4 (bit 3) — routed through configured binding
        let btn4Now = (mask & 0x08) != 0
        let btn4Was = (oldMask & 0x08) != 0
        if btn4Now != btn4Was {
            fireButtonAction(tool.penButton4Binding, down: btn4Now, at: loc,
                             snapshot: snap, settings: settings)
        }
        // Button 5 (bit 4) — routed through configured binding
        let btn5Now = (mask & 0x10) != 0
        let btn5Was = (oldMask & 0x10) != 0
        if btn5Now != btn5Was {
            fireButtonAction(tool.penButton5Binding, down: btn5Now, at: loc,
                             snapshot: snap, settings: settings)
        }
    }

    // MARK: - Finger-touch state (injection in InputInjector+Touch.swift)

    /// Mutable per-sequence state for capacitive touch.  HIDThread-owned.
    var touchTracker = TouchStateTracker()
    /// Per-contact palm classification. HIDThread-owned alongside the
    /// tracker, so a palm can never enter its gesture state.
    var touchPalmRejector = TouchPalmRejector()
    /// CFAbsoluteTime when the pen last left proximity.  Touch is suppressed
    /// while the pen is in proximity and for a brief grace window after exit
    /// so palm-rejection bounces (finger contact arriving 1–2 frames after
    /// pen-up) don't slip through as cursor jumps.
    var penProximityExitTime: CFAbsoluteTime = 0
    /// Per-Wacom-driver convention; tunable if reports show false positives.
    static let touchArbitrationGrace: CFAbsoluteTime = 0.08

    // ── Screen-edge pinning (Dock reveal / hot corners) ─────────────────────
    // A hidden Dock and hot corners never trigger from injected moves that
    // stop at the integer bounds edge; the OS detector wants the pointer
    // fractionally *at* the edge. Xencelabs' own driver works around this the
    // same way (PostTabletDockMove posts a sub-pixel Y pinned against the
    // display-bounds bottom), which is where these constants come from.

    /// How close (points) a mapped position must get to a bounds edge
    /// before it is pinned onto that edge.
    static let edgePinThreshold: CGFloat = 2.0
    /// Sub-pixel inset from the exact edge, matching the vendor driver.
    static let edgePinInset: CGFloat = 0.1196

    /// Pins coordinates within `edgePinThreshold` of a bounds edge to a
    /// fractional position hard against that edge.
    static func pinNearScreenEdges(_ p: CGPoint, in bounds: CGRect) -> CGPoint {
        var p = p
        if p.x - bounds.minX < edgePinThreshold { p.x = bounds.minX + edgePinInset }
        else if bounds.maxX - p.x < edgePinThreshold { p.x = bounds.maxX - edgePinInset }
        if p.y - bounds.minY < edgePinThreshold { p.y = bounds.minY + edgePinInset }
        else if bounds.maxY - p.y < edgePinThreshold { p.y = bounds.maxY - edgePinInset }
        return p
    }

    func currentCursorPosition() -> CGPoint {
        // CGEvent(source: nil).location is the cursor in CG global (top-left
        // origin) coordinates and is safe off the main thread — unlike
        // NSEvent.mouseLocation (AppKit, main-thread) which this previously
        // used with a manual Y-flip against the main display's height (wrong
        // on multi-display layouts where a secondary screen extends above or
        // below the primary).
        CGEvent(source: nil)?.location ?? .zero
    }

    // MARK: - Click resolution

    func resolveClick(
        _ candidate: CGPoint,
        snapshot: InjectionSnapshot
    ) -> (CGPoint, Int) {
        let now = CFAbsoluteTimeGetCurrent()
        let dist = hypot(
            candidate.x - lastClickPosition.x,
            candidate.y - lastClickPosition.y)

        let snapThreshold = snapshot.doubleClickDistance
        let countThreshold = snapThreshold > 0 ? snapThreshold : 8.0
        let withinTime = now - lastClickTime < snapshot.doubleClickInterval
        let withinDist = dist < countThreshold

        if withinTime && withinDist { clickCount += 1 } else { clickCount = 1 }

        // Always report the actual pen position. The position snap (returning
        // lastClickPosition when within threshold) was intended to land both clicks
        // of a double-click at exactly the same pixel, but it causes a visible cursor
        // teleport whenever two presses fall within snapThreshold of each other:
        // postMouseDown moves the cursor to lastClickPosition while lastPostedPoint
        // remains at screenPoint, so the delta gate fires drag events on every
        // micro-movement of the pen, bouncing the cursor between the old click
        // position and the pen's actual position until mouseUp corrects it.
        // Double-click count detection works correctly without position snapping —
        // apps use time + proximity for double-click, not exact pixel identity.
        lastClickPosition = candidate
        lastClickTime = now
        return (candidate, clickCount)
    }

    // MARK: - Synthetic-modifier state (posting layer in InputInjector+CGEvents.swift)

    /// Ground-truth of what synthetic modifiers should be active based on tablet button state.
    var groundTruthSyntheticFlags: CGEventFlags = []

    /// Reference counts for each modifier bit to support multiple buttons mapped to the same key.
    var modifierRefCounts: [UInt64: Int] = [
        CGEventFlags.maskCommand.rawValue: 0,
        CGEventFlags.maskShift.rawValue: 0,
        CGEventFlags.maskAlternate.rawValue: 0,
        CGEventFlags.maskControl.rawValue: 0,
    ]

    /// Left-hand canonical keycodes for each managed modifier bit.
    /// Electron and AppKit text input only update their internal modifier state when
    /// a flagsChanged event carries a keycode that matches the actual modifier key —
    /// keycode 0 is silently ignored by many apps.
    static let modifierKeyCodes: [(CGEventFlags, CGKeyCode)] = [
        (.maskCommand,   55),  // left ⌘
        (.maskShift,     56),  // left ⇧
        (.maskAlternate, 58),  // left ⌥
        (.maskControl,   59),  // left ⌃
    ]

    /// Last managed-bit result returned by currentEventFlags — used to suppress duplicate log lines.
    var lastLoggedManagedFlags: UInt64 = 0

    /// CGEventSource backed by privateState.  Note: despite documentation implications,
    /// events posted via .cghidEventTap from this source DO write into hidSystemState —
    /// so we filter our own events out of the flagsChangedTap by sourceStateID rather
    /// than relying on hidSystemState to reflect only physical keyboard state.
    ///
    /// Stored once at init — NOT a computed property.  Creating a new CGEventSource on
    /// every event (400+/s at 133 Hz) allocates a private-state slab in the WindowServer
    /// on each call, causing the memory leak observed when a pen is in proximity.
    let sessionSource: CGEventSource? = CGEventSource(stateID: .privateState)

    // MARK: - Screen mapping
    //
    // Display selection, orientation/crop, calibration, and relative-mode
    // mapping live in DisplayMapper.swift. These forward to it for the
    // handful of call sites outside inject()/injectTouch (button actions,
    // settings/calibration edits from main).

    /// When set, `.displayToggle` presses are forwarded here instead of
    /// cycling this injector's own display mapping. Assigned once at connect
    /// by TabletManager for aux-only accessory devices; called on HIDThread.
    var displayToggleForwarder: (() -> Void)?

    /// When set, `.relativeModeToggle` presses are forwarded here instead of
    /// flipping this injector's own (inert, for an aux-only accessory)
    /// `relativeCursorMovement` setting. Assigned once at connect by
    /// TabletManager for aux-only accessory devices, mirroring
    /// `displayToggleForwarder` above; called on HIDThread.
    var relativeModeToggleForwarder: (() -> Void)?

    /// Advances the toggle rotation to the next display in the sequence.
    /// Called from fireButtonAction (HIDThread) when a `.displayToggle` binding fires.
    func cycleToggleDisplay(snapshot: InjectionSnapshot) {
        displayMapper.cycleToggleDisplay(snapshot: snapshot)
    }

    /// Force re-read of calibration data on next inject.
    /// Call after calibration data is stored or cleared. Hops to HIDThread because
    /// the display mapper's cache is owned there.
    func invalidateCalibrationCache() {
        CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.displayMapper.invalidateCalibrationCache()
        }
        CFRunLoopWakeUp(HIDThread.shared.runLoop)
    }

    /// Recomputes the virtual-screen union from `NSScreen.screens`.
    /// Must be called on main. Invoked from init and from the
    /// didChangeScreenParametersNotification observer.
    @MainActor
    private func recomputeVirtualScreenBounds() {
        displayMapper.recomputeVirtualScreenBounds()
    }
}
