// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import os
import TabletKit

let modLog = Logger(subsystem: "com.cyzor.mocktab", category: "modifiers")
let injectLog = Logger(subsystem: "com.cyzor.mocktab", category: "inject")

/// Synthetic modifiers held by aux bindings (ExpressKeys, ring center,
/// Quick Keys), shared by every injector: a Quick Keys Shift must reach drags
/// posted by the pen tablet's injector. Pen-button modifiers stay per
/// instance, reconciled against that device's tool. HIDThread-confined.
final class SharedAuxModifierState {
    static let shared = SharedAuxModifierState()
    private init() {}
    var groundTruthFlags = CGEventFlags()
    var refCounts: [UInt64: Int] = [:]
    var lastChangeAt: Date = .distantPast
}

/// Routes a Pan View gesture to the injector moving the pointer, since its
/// button can live on another device (a Quick Keys key while the pen pans).
/// A no-op for a pen's own barrel button. HIDThread-confined.
final class SharedPanScrollState {
    static let shared = SharedPanScrollState()
    private init() {}
    /// The injector currently hosting the live gesture, if any. Every
    /// engage and close path goes through here, so it also drives the
    /// on-screen indicator.
    weak var driver: InputInjector? {
        didSet {
            let engaged = driver != nil
            guard engaged != (oldValue != nil) else { return }
            DispatchQueue.main.async {
                if engaged { PanIndicator.shared.show() } else { PanIndicator.shared.hide() }
            }
        }
    }
}

/// Converts TabletPoint reports into CGEvents and posts them.
///
/// Per report: a tabletProximity event on proximity change; otherwise a
/// tabletPointer event (for Qt/GTK apps such as Krita and GIMP) and a mouse
/// event. A delta gate skips reports that don't change position or pressure,
/// so a still pen costs nothing. Transitions always post at once.
///
/// Threading: `init`, `deinit`, the flags tap install, and `recompute…` run
/// on main; `inject`, `injectAux`, `injectMouseButtons`, and everything they
/// call run on HIDThread. Settings reach HIDThread as snapshots via
/// CFRunLoopPerformBlock. `@unchecked Sendable` rests on that confinement.
///
/// This file holds the stored properties and setup; the `InputInjector+*`
/// extensions hold the pen path, touch, aux input, and the CGEvent layer.
///
/// ## Latched state and its release paths
///
/// Each row is state that holds something down until a release runs. Five
/// leaks have been fixed here, so the pairings are listed, not rediscovered.
///
/// Release funnels: **proximity exit** (`commitProximityExit`), **tool change
/// and disconnect** (`releaseHeldStateForToolChange`), and **deinit**, which
/// invalidates every timer.
///
/// | State | Armed by | Released by | Leaks if stuck |
/// |---|---|---|---|
/// | `groundTruthSyntheticFlags` | aux/barrel binding posting a modifier | `releaseAllSyntheticModifiers` via proximity exit, 0.4s idle `watchdogTimer`, 1Hz `leakWatchdogTimer`, app switch (`releaseOnAppSwitch`) | Modifier stuck down system-wide |
/// | `heldKeyComboRefCounts` | aux/barrel binding posting a plain (non-modifier) `.keyCombo` key | `releaseAllHeldKeyComboKeys` via the same four paths as `groundTruthSyntheticFlags` above | Letter/number key stuck down system-wide until the app quits |
/// | `lastTipDown` | curved pressure ≥ `tipPressureThreshold`, subject to `tipUpDebounceTimer` on release | tip-up in `inject` (debounce-confirmed), proximity exit (incl. the 1Hz watchdog's forced exit — the only release on an unplug with the tip down) | Stroke never ends; button reads held |
/// | `hoverDragButton` | click binding down, or Click Lock | binding up edge, proximity exit, `releaseBindingHeldButton` on tool change/disconnect | Movement posts drags instead of hover |
/// | `clickLocked` | Click Lock press, or a Click Lock tip's first contact | next press or tip contact, proximity exit (`releaseClickLock`), tool change/disconnect | Left button stuck down |
/// | `tipClickSwallowed` | tip contact with the tip set to None, while Click Lock holds, or firing a contact-deferred button | tip lift, proximity exit | Next lift posts no mouseUp |
/// | `contactDeferredButtons` / `contactFiredButtons` | Hover Click off: click or Pan View barrel button pressed while hovering / its tip contact | button release, proximity exit; the fired bits also tip lift and tool change | Button's action held, or a later release posts an up nothing pressed |
/// | `lastMiddleDown`, `lastUSBMouseMask` / `usbMouseLeftHeld` | puck/KC-100 mouse button down | `releaseHeldPointerButtons` — proximity exit and tool change/disconnect | Mouse button stuck down |
/// | `pendingMouseUp` (timer) | tip-up while still moving, tip-up assist enabled | tip re-down (`cancelPendingMouseUp`), proximity exit, deinit | mouseUp never posted — stroke stays open |
/// | `panScroll` (PanScrollTracker) | `.scrollDrag` binding engaged | binding release edge; deliberately **survives** proximity blips (`suspend()`), `cancelPanScrollSafetyNet` + `panScrollSafetyNetTimer` backstop | Pen motion scrolls instead of moving cursor |
/// | `button1/2/3UpDebounceTimer` | Xencelabs barrel-button up edge | reassert within window, timer fire, proximity exit (invalidates + commits), deinit | Release never committed — button reads held |
/// | `tipUpDebounceTimer` | tip-switch up edge, any device, when `smoothingStrength > 0` | reassert within window, timer fire (commits release, feeds `tipUpAssistDelay`), `commitProximityExit`, 1Hz watchdog's forced exit (via `commitProximityExit`), deinit | Release never committed — `lastTipDown` (and drag/stroke-start state derived from it) reads stuck down |
/// | `proximityExitDebounceTimer` | Xencelabs range loss | pen returning in range, timer fire → `commitProximityExit`, deinit | Exit cleanup never runs |
/// | `watchdogTimer` | rearmed on every inject/injectAux/injectMouseButtons | fires after 0.4s idle → releases synthetic flags; deinit | (Safety net; see leak watchdog) |
/// | `leakWatchdogTimer` (1Hz) | `init`, runs continuously | deinit only — by design, it must outlive quiescence | Backstop absent for the rows above |
/// | `lastProximity` | pen in range | proximity exit; 1Hz watchdog forces exit after `stuckProximityTimeout` | Touch gated off as "pen busy" |
/// | `lastAuxButtons`, `lastRingButtonDown` | express key / ring center down | matching up edge in `injectAux`; 0.4s `watchdogTimer` for modifier flags | Express-key binding stuck held |
/// | `panMomentumTail`, `touchMomentumTail` | flick release with velocity | decay to zero; new gesture (`cancel()`, its `.began` ends the tail); tool change, disconnect, proximity exit, app switch, sleep, quit (`stop()` posts a terminal event, for macOS 27's stuck-gesture timer); `cancel()` in deinit | Scrolling continues; on 27+ the app force-cancels it |
/// | `touchDragPosition` | three-finger tap, then the next touch | `releaseTouchDrag` via lift (`.dragUp`), pen-busy wind-down, touch turned off, tool change/disconnect, 1Hz `leakWatchdogTimer` after 1s without touch frames | Left button stuck down |
/// | `mechanicalDialGestureOpen`, `ring1/2GestureOpen` | `.zoom`/`.rotate` ring slot engaged (dial click or ring contact) | 0.4s `mechanicalDialGestureIdleTimer` after the last click (dial) or ring contact lift (capacitive); explicit `closeRingGestureEnvelopes()` on ring-mode-cycle/select-slot bindings and the modifier-held zoom fallback; **`deinit` closes silently** (timer invalidated, no `.ended` posted — see below) | Frontmost app stuck mid-pinch/-rotate |
///
/// Disconnect releases held buttons but invalidates no timers, so a timer
/// armed at unplug still fires. That is safe by design:
///
/// - Every timer is one-shot, so the window is bounded (at most 4 s).
/// - Handlers post the release, finishing the cleanup the disconnect skipped.
/// - The injector outlives the device: `TabletManager` keeps the context and
///   its `injectionSnapshot`, which the handlers post through.
/// - A tip held at unplug is the one gap; the 1 Hz `leakWatchdogTimer`
///   forces `commitProximityExit` after `stuckProximityTimeout`.
///
/// A new timer must be one-shot, short, and safe after unplug, or the
/// disconnect path must invalidate it.
///
/// `deinit` alone ends gestures silently (no `.ended`): it can't post from
/// HIDThread while the object is being destroyed. That's harmless, since it
/// only runs at quit or long after the idle timer closed everything.
final class InputInjector: @unchecked Sendable {

    // MARK: - Device identity

    var deviceVendorID: Int
    var deviceProductID: Int

    /// The raw ring position counts opposite "positive = clockwise". Hardware
    /// polarity only; scroll direction is applied in `dispatchRingDelta`.
    /// Observed: `.cintiqV1` counts clockwise, `.intuosV1` (PTH-850) counter-
    /// clockwise. `.intuosV2` is assumed clockwise, untested. If a third
    /// convention appears, make this a registry field.
    let ringDeltaIsInverted: Bool

    /// The ring control is a mechanical dial, not a touch ring; see
    /// `WacomDeviceSpec.hasMechanicalDial`. Xencelabs isn't in the Wacom
    /// registry, so its Quick Keys dial comes from `VendorDeviceRegistry`.
    let hasMechanicalDial: Bool

    /// Detents per revolution of this device's mechanical dial; sets how far
    /// one tick rotates or zooms. Per-model: Xencelabs 13, PTK gen-3 24.
    /// Unread without `hasMechanicalDial`.
    let dialStepsPerRevolution: Double

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

    /// Click bookkeeping for `stampClickSequence`, matching hardware: each press
    /// gets an event number its drags and release share, and the release
    /// repeats the click state, or 0 if the pointer strayed.
    var clickEventNumber: Int64 = 0
    var pressClickState: Int64 = 0
    var pressLocation: CGPoint = .zero
    var pressStrayed = false

    /// This device is the active context. Written on main, read on HIDThread,
    /// behind a lock: Swift doesn't guarantee Bool atomicity.
    private let _isActive = OSAllocatedUnfairLock<Bool>(initialState: false)
    var isActive: Bool {
        get { _isActive.withLock { $0 } }
        set { _isActive.withLock { $0 = newValue } }
    }

    /// Every live injector, weakly held, so the shared aux-modifier watchdog can
    /// check all devices before releasing a bit. Locked: `add()` runs on main,
    /// reads on HIDThread. Per-instance fields read here are all HIDThread's.
    private struct LiveInjectors: @unchecked Sendable {
        let table: NSHashTable<InputInjector> = .weakObjects()
    }
    private static let liveInjectorsLock = OSAllocatedUnfairLock(initialState: LiveInjectors())

    /// Every live injector, for cross-device gesture routing. Callers run on
    /// HIDThread; the table itself is lock-protected.
    static var allLiveInjectors: [InputInjector] {
        liveInjectorsLock.withLock { $0.table.allObjects }
    }

    /// Any device still holds an aux control. The shared release must wait:
    /// Quick Keys only report changes, so a long hold looks idle.
    fileprivate static var anyAuxControlHeld: Bool {
        liveInjectorsLock.withLock { live in
            for injector in live.table.allObjects {
                if injector.lastAuxButtons.contains(true) || injector.lastRingButtonDown
                    || injector.lastRing2ButtonDown
                    || injector.lastRingPos != 0x7F || injector.lastRing2Pos != 0x7F
                    || injector.lastStrip1Pos != 0xFF || injector.lastStrip2Pos != 0xFF
                { return true }
            }
            return false
        }
    }

    // MARK: - Natural scrolling (system-wide, not per-device)

    /// Mirrors System Settings' Natural Scrolling. Read fresh each call
    /// (UserDefaults is thread-safe, and updates within a second); the change
    /// notification proved unreliable for a background app. Injected scroll
    /// events skip the OS's own flip, so `dispatchRingDelta` applies it.
    static var naturalScrollingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "com.apple.swipescrolldirection")
    }

    /// Escape hatch: drop physical modifiers from every move event, for a
    /// machine the staleness gate doesn't fix. Costs constraint snapping in
    /// Illustrator, Keynote, and Pages. Read at launch.
    ///
    ///     defaults write com.cyzor.mocktab dropPhysicalModifiersFromMoveEvents -bool YES
    static let forceDropPhysicalMoveFlags: Bool =
        UserDefaults.standard.bool(forKey: "dropPhysicalModifiersFromMoveEvents")

    /// Longest no-contact gap on the touch ring still treated as one touch.
    static let ringDropoutBridge: TimeInterval = 0.4

    /// Stable per-tablet ID for `tabletEventDeviceID` and proximity events,
    /// as Wacom's driver sends one per tablet; a shared constant made two
    /// tablets look like one to apps that pair pointer and proximity events.
    let tabletDeviceID: Int64
    @MainActor private static var nextTabletDeviceID: Int64 = 1

    @MainActor
    init(vendorID: Int = 0x056A, productID: Int = 0) {
        self.deviceVendorID = vendorID
        self.deviceProductID = productID
        self.tabletDeviceID = Self.nextTabletDeviceID
        Self.nextTabletDeviceID += 1
        self.ringDeltaIsInverted =
            WacomDeviceRegistry.spec(for: productID)?.parser == .intuosV1
        if let spec = WacomDeviceRegistry.spec(for: productID) {
            self.hasMechanicalDial = spec.hasMechanicalDial
            self.dialStepsPerRevolution = Self.wacomDialStepsPerRevolution
        } else if vendorID == 0x28BD,
            let profile = VendorDeviceRegistry.drivableProfile(
                forVendorID: vendorID, productID: productID)
        {
            // Mirrors TabletManager.vendorDeviceSpec's isAuxOnly check: only
            // the aux-only Quick Keys puck/dongle has a dial.
            self.hasMechanicalDial = profile.maxX == nil
            self.dialStepsPerRevolution = Self.xencelabsDialStepsPerRevolution
        } else {
            self.hasMechanicalDial = false
            self.dialStepsPerRevolution = Self.xencelabsDialStepsPerRevolution
        }
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
                self.touchPanelNeedsResolve = true
            }
            CFRunLoopWakeUp(HIDThread.shared.runLoop)
        }
        leakWatchdogTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true
        ) { [weak self] _ in self?.checkLeakWatchdog() }
        installFlagsChangedTap()

        // End momentum tails before sleep and at quit: macOS 27 force-cancels a
        // gesture left open, and a tail can't resume after sleep.
        willSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) {
                if self.panMomentumTail.isRunning || self.touchMomentumTail.isRunning {
                    TouchPipelineProbe.note { $0.momentumTailsStoppedOnSleep += 1 }
                }
                self.panMomentumTail.stop()
                self.touchMomentumTail.stop()
            }
            CFRunLoopWakeUp(HIDThread.shared.runLoop)
        }
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) {
                if self.panMomentumTail.isRunning || self.touchMomentumTail.isRunning {
                    TouchPipelineProbe.note { $0.momentumTailsStoppedOnTerminate += 1 }
                }
                self.panMomentumTail.stop()
                self.touchMomentumTail.stop()
            }
            CFRunLoopWakeUp(HIDThread.shared.runLoop)
        }
    }

    deinit {
        if let obs = displayObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = willSleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = willTerminateObserver { NotificationCenter.default.removeObserver(obs) }
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
        ringGlide.cancel()
        dialGlide.cancel()
        mechanicalDialGestureIdleTimer.map { CFRunLoopTimerInvalidate($0) }
        button1UpDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
        button2UpDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
        button3UpDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
        tipUpDebounceTimer.map { CFRunLoopTimerInvalidate($0) }
    }

    // MARK: - State
    //
    // Fields shared with the `InputInjector+*` extensions are internal, since
    // `private` is file-scoped. Ownership and HIDThread confinement are unchanged.

    var lastProximity = false
    var lastTipDown = false
    /// True after the first leftMouseDragged is posted following a tip-down.
    /// Used to guarantee Pages sees at least one drag event even when deltas are tiny.
    var didEmitDragSinceDown = false
    /// True while the tip is down with its binding set to None: the contact
    /// posted no mouseDown, so it must post no drag or mouseUp either.
    var tipClickSwallowed = false
    /// True while a Click Lock binding holds the left button. Released by the
    /// next press, proximity exit, tool change, or disconnect.
    var clickLocked = false
    /// Screen position at the moment the tip went down. Anchor for the drag
    /// threshold gate — see `TabletSettings.dragThreshold`.
    var tipDownOrigin: CGPoint = .zero
    var lastEraserMode = false  // Track eraser/tip flip while in proximity
    // Named fields, not a collection: cheaper at 133 Hz and readable in a debugger.
    var lastButton1Down = false
    var lastButton2Down = false
    var lastButton3Down = false
    /// Hover Click off: barrel buttons held with their action deferred until
    /// tip contact. Bit 0 is button 1.
    var contactDeferredButtons: UInt8 = 0
    /// The deferred buttons whose action fired on contact; the tip's lift
    /// releases them.
    var contactFiredButtons: UInt8 = 0
    var lastMiddleDown = false
    var activeButton: CGMouseButton = .left

    // MARK: - USB mouse button state
    //
    // The KC-100's buttons arrive on a separate mouse interface (report 0x01),
    // handled by injectMouseButtons(). inject() reads usbMouseLeftHeld.
    var lastUSBMouseMask: UInt8 = 0
    var usbMouseLeftHeld: Bool = false

    // MARK: - Report timestamp carrier
    //
    // Kernel receipt time of the report being handled, in CGEvent nanoseconds;
    // 0 for timer-fired posts, which keep the default. Cleared after each report,
    // so a stale stamp never replays. Static: one HIDThread serves every device.
    static var currentReportTimestampNs: UInt64 = 0

    // MARK: - Cursor smoothing, jitter, velocity
    //
    // State and math live in CursorSmoother.swift.

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

    /// Timestamp of the previous pen frame, for the smoothers' real-dt math.
    /// Separate from `lastPanScrollFrameTime`, which only advances during an
    /// active scroll-drag. 0 = unknown; that frame's dt is a fresh start.
    var lastSmoothingFrameTime: CFAbsoluteTime = 0

    // MARK: - Delta gate
    //
    // Skip reports that don't change position or pressure: a still pen sends
    // identical coordinates at 133 Hz.

    static let positionEpsilon: CGFloat = 0.5  // sub-pixel, not worth posting
    static let pressureEpsilon: Double = 0.002
    /// Degrees of barrel twist worth posting. Without this the movement gate
    /// drops twist-only reports and no app sees rotation. One decoded step is
    /// 0.2°, so any real twist passes.
    static let rotationEpsilon: Double = 0.1

    // MARK: - Stale-report suppression
    //
    // Under heavy system load (a local LLM saturating unified memory), reports
    // back up and arrive in a burst. Posting each one animated the cursor through
    // seconds of old positions. Only plain hover moves are dropped; clicks, drags,
    // and stroke data are untouched. Throttling still replayed history, so stale
    // reports are skipped outright (`isStaleHoverMove`).

    /// A report whose kernel timestamp is older than this by the time it's
    /// decoded is backlog, not a live sample — see the section doc above.
    static let staleReportThresholdMs: Double = 50.0

    /// Log a single `event.post` slower than this; normally well under 1 ms.
    static let eventPostWarnThresholdMs: Double = 20.0

    // MARK: - Tip-down pressure threshold
    //
    // Curved pressure above which a report counts as contact; about 4 counts on a
    // 1024-level sensor. Kept as is: a noisy GD-0608-U hovered at 3–7 counts, but
    // raising this would firm up contact on every tablet, unverifiable here.
    // `ToolSettings.pressureThreshold` is the per-tool fix.
    static let tipPressureThreshold: Double = 0.004

    /// Applies a tool's pressure curve. Shared with the Info pane so its tip
    /// readout matches what's injected. Interpolates: plain indexing cut
    /// 8192-level sensors to 256 steps (event-probe, 2026-09-30).
    static func curvedPressure(_ normalized: Double, lut: [Double]) -> Double {
        let pos = Swift.min(Swift.max(normalized, 0), 1) * Double(lut.count - 1)
        let i = Int(pos)
        guard i < lut.count - 1 else { return lut[lut.count - 1] }
        let frac = pos - Double(i)
        return lut[i] + (lut[i + 1] - lut[i]) * frac
    }

    // MARK: - Tip-up assist
    //
    // Above zero, delays the release briefly when the pen lifts mid-motion, so a
    // light lift doesn't end a fast stroke. Cancelled if the tip comes back down.

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

    /// Force-closes a pan whose button release was lost. Armed at proximity
    /// exit with a pan open; cancelled by the release.
    var panScrollSafetyNetTimer: CFRunLoopTimer?
    /// How long a pan may sit suspended (pen out of range, no release seen)
    /// before it's force-closed as a presumed-lost gesture. Matches the
    /// proximity-exit held-button safety interval.
    let panScrollSafetyNetInterval: TimeInterval = 4.0

    /// Momentum tail after a Pan View release in Momentum mode; see
    /// MomentumTail.swift. `[weak self]` avoids a retain cycle.
    lazy var panMomentumTail = MomentumTail { [weak self] dx, dy, phase in
        self?.postPanScrollMomentum(dx: dx, dy: dy, phase: phase)
    }

    /// A separate instance, so a touch scroll's tail can't cancel or blend with
    /// a Pan View tail.
    lazy var touchMomentumTail = MomentumTail { [weak self] dx, dy, phase in
        self?.postTouchScrollMomentum(dx: dx, dy: dy, phase: phase)
    }

    /// Which gesture a zoom or rotate ring mode drives, on rings and dials alike.
    enum RingGestureKind { case zoom, rotate }

    /// Direct-drive glide for capacitive ring/strip scrolling; see
    /// `RingScrollGlide`. Scroll only: `.zoom`/`.rotate` slots dispatch
    /// linearly per raw tick (see `dispatchRingDelta`).
    lazy var ringGlide = RingScrollGlide { [weak self] dy in
        self?.postDialScroll(dy: dy)
    }

    /// Mechanical-dial variant of `ringGlide` (Xencelabs dial; PTK-470/670/870
    /// gen-3 dials — see `hasMechanicalDial`), with stray-reversal rejection.
    lazy var dialGlide = RingScrollGlide(confirmReversals: true) { [weak self] dy in
        self?.postDialScroll(dy: dy)
    }

    /// A zoom or rotate gesture is open on a dial. A dial has no touch to
    /// bracket it, so the first tick opens it and an idle timer closes it.
    var mechanicalDialGestureOpen = false
    /// The open gesture's kind, kept because the mode may change before it closes.
    var mechanicalDialGestureKind: RingGestureKind = .zoom
    /// Idle timer that closes a dial gesture; rearmed on every tick.
    var mechanicalDialGestureIdleTimer: CFRunLoopTimer?
    /// Wait after the last dial click before ending a gesture. Longer than the
    /// gap in a slow, deliberate turn, or one turn splits into several gestures.
    static let mechanicalDialGestureIdleTimeout: TimeInterval = 0.4

    /// Panning method, captured at engage from `ToolSettings.panScrollMomentum`.
    /// `true` (Momentum): phased events plus a momentum tail, which scroll views
    /// (Finder, Xcode) read as a trackpad flick. `false` (Compatible): no phases
    /// and no tail, the shape tools like Smooze use, for apps that ignore
    /// momentum.
    var panScrollUsePhases = true

    var lastPostedPoint: CGPoint = .zero
    var lastPostedPressure: Double = -1.0
    var lastPostedRotation: Double = 0.0
    var hasPostedPoint = false

    /// Consecutive hover moves dropped as stale backlog; logged at most once
    /// a second.
    var staleHoverSuppressCount = 0
    var lastStaleHoverLogAt: Date = .distantPast

    // MARK: - Click state

    private var lastClickPosition: CGPoint = .zero
    private var lastClickTime: CFAbsoluteTime = 0
    private var clickCount: Int = 0
    var activeClickCount: Int = 1

    // MARK: - Express key / touch ring state

    var lastAuxButtons = [Bool](repeating: false, count: 19)
    var lastRingButtonDown = false
    /// Last ring mode the device's firmware reported (ExpressKey Remote).
    var lastHardwareRingMode: Int?
    /// Same as `lastRingButtonDown`, for the second dial's own toggle key
    /// (PTK-670/870's right cluster center). Unused on every other device.
    var lastRing2ButtonDown = false
    /// Last observed touch ring position (0–71). 0x7F = no contact.
    var lastRingPos: UInt8 = 0x7F
    /// Last ring position before contact was lost, and when. Slow fingers
    /// drop out for a frame mid-turn (PTH-660); see `ringDropoutBridge`.
    var ringLiftPos: UInt8 = 0x7F
    var ringLiftTime: CFAbsoluteTime = 0
    /// Last observed right touch ring position (DTK-2400). 0x7F = no contact.
    var lastRing2Pos: UInt8 = 0x7F
    /// Last observed Intuos3 WS touch strip positions. 0xFF = no contact.
    var lastStrip1Pos: UInt8 = 0xFF
    var lastStrip2Pos: UInt8 = 0xFF
    /// Fractional-delta accumulators for ring/strip speed scaling.
    /// Carry sub-integer remainders across pulses so speed < 1.0 fires evenly.
    var ringAccum: Double = 0
    var ring2Accum: Double = 0
    /// A zoom or rotate gesture is open on a touch ring, from contact to lift.
    /// Keyed on `touchRingActive`, never `lastRingButtonDown`: proximity exit
    /// clears the latter, and a blip must not read as a lift.
    var ring1GestureOpen = false
    var ring2GestureOpen = false
    /// The open gesture's kind on each ring, kept because the mode may change
    /// before it closes.
    var ring1GestureKind: RingGestureKind = .zoom
    var ring2GestureKind: RingGestureKind = .zoom
    var strip1Accum: Double = 0
    var strip2Accum: Double = 0
    /// Fractional-delta accumulators for IntuosV3 relative scroll wheels (index 0 and 1).
    var wheel0Accum: Double = 0
    var wheel1Accum: Double = 0

    // MARK: - Synthetic-modifier safety valves

    /// Idle watchdog: if a modifier is held and no tablet activity arrives for
    /// `watchdogInterval`, release synthetic flags. The pen streams at 133 Hz,
    /// so silence means it left. Runs on HIDThread.
    private var watchdogTimer: CFRunLoopTimer?
    private let watchdogInterval: TimeInterval = 0.4

    /// Idle time with `lastProximity` still true before the 1 Hz watchdog forces
    /// an exit. A pen in range streams at 100+ Hz, so this never fires in use.
    private static let stuckProximityTimeout: TimeInterval = 2.0

    /// Xencelabs only: defers proximity-exit cleanup so range loss doesn't cut
    /// a held button short. Its range tag trips sooner than Wacom's, and its own
    /// driver keeps a held button through range loss. With nothing held, a short
    /// debounce absorbs a blip. With a button held, cleanup waits for the pen to
    /// return; the long interval is only a safety net.
    var proximityExitDebounceTimer: CFRunLoopTimer?
    let proximityExitDebounceInterval: TimeInterval = 0.15
    let proximityExitHeldButtonSafetyInterval: TimeInterval = 4.0

    /// Xencelabs only: a small debounce on the barrel-button release. Its
    /// button range is shorter than its position range, so a held button
    /// flickers for a frame or two at the edge. No hand can release and re-press
    /// in ~15 ms, so bridging that window reads intent. Kept small so a real
    /// double-tap (~120 ms) stays two clicks; a 0.15–0.25 s window felt sticky.
    /// Tune live:
    ///   defaults write <bundle-id> MockTabXencelabsButtonDebounceMS 60
    var button1UpDebounceTimer: CFRunLoopTimer?
    var button2UpDebounceTimer: CFRunLoopTimer?
    var button3UpDebounceTimer: CFRunLoopTimer?

    /// How long ago the physical release happened, while a debounced release
    /// is committing; 0 otherwise. Pan View reads it to judge momentum from the
    /// real release (`PanScrollTracker.disengage(backdate:)`).
    var pendingButtonUpBackdate: TimeInterval = 0
    let buttonUpDebounceInterval: TimeInterval = {
        let ms = UserDefaults.standard.integer(forKey: "MockTabXencelabsButtonDebounceMS")
        return ms > 0 ? Double(ms) / 1000.0 : 0.05
    }()

    /// Tip chatter debounce for any device, gated on Steadiness. Press is
    /// immediate; a release waits, and a re-press cancels it. Scales from 0 to
    /// `buttonUpDebounceInterval`'s tuned 50 ms.
    var tipUpDebounceTimer: CFRunLoopTimer?

    /// Longer release debounce for right-click and eraser bindings, so a context
    /// menu survives lifting the pen with the button held. The button bit drops
    /// 55–130 ms before proximity does; the release must not commit before then,
    /// or it picks the highlighted item. A late release is harmless for menus.
    /// A lift slower than 0.25 s can still slip through.
    let buttonUpDebounceMenuInterval: TimeInterval = 0.25

    // MARK: - Time-based leak watchdog
    //
    // A 1 Hz backstop that runs regardless of activity, for when
    // `lastAuxButtons` is stuck (e.g. unplugged mid-press).

    private var leakWatchdogTimer: Timer?
    /// Timestamp of the last groundTruthSyntheticFlags mutation.
    var lastSyntheticFlagChangeAt: Date = .distantPast
    /// Timestamp of the last tablet HID report (inject / injectAux / injectMouseButtons).
    /// Stamped inside rearmWatchdog(), which every entry point calls.
    private var lastInjectCallAt: Date = .distantPast
    /// Time of the last pen report. Touch traffic doesn't refresh it, so a
    /// streaming two-finger gesture can't hide a silent, stuck pen.
    var lastPenInjectCallAt: Date = .distantPast

    // MARK: - Physical modifier state tap
    //
    // Passive tap on hardware flagsChanged events (sourceStateID ==
    // hidSystemState), keeping tapLastPhysicalFlags current. Our own posts write
    // into hidSystemState too, so filter by source and read event.flags.

    var flagsChangedTap: CFMachPort?
    var flagsChangedTapSource: CFRunLoopSource?
    /// Physical modifier bits (⌘⌥⇧⌃) last reported by a hardware flagsChanged event.
    /// Updated only from events with sourceStateID == hidSystemState; immune to our own
    /// synthetic flagsChanged posts.
    var tapLastPhysicalFlags: UInt64 = 0

    /// When `tapLastPhysicalFlags` was written, on `currentReportTimestampNs`'s
    /// clock, so `moveSafeEventFlags` can tell a current cache from a stale one.
    var tapLastPhysicalFlagsAtNs: UInt64 = 0

    /// Move events that dropped physical bits for a stale cache. Reported in
    /// diagnostics: non-zero on a machine losing modifiers confirms the window
    /// is real there; zero rules this mechanism out.
    var staleModifierCacheDrops: UInt64 = 0

    /// True when no physical tablet control is held. If this holds and
    /// `groundTruthSyntheticFlags` is non-empty, the flags are a leak.
    var tabletIsQuiescent: Bool {
        !lastTipDown && !lastButton1Down && !lastButton2Down && !lastButton3Down
            && !lastMiddleDown
            && !lastRingButtonDown && !lastRing2ButtonDown
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
        guard !groundTruthSyntheticFlags.isEmpty || !heldKeyComboRefCounts.isEmpty else { return }
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + watchdogInterval,
            0,  // interval — one-shot
            0, 0
        ) { [weak self] _ in
            guard let self,
                !self.groundTruthSyntheticFlags.isEmpty || !self.heldKeyComboRefCounts.isEmpty
            else { return }
            // Wacom pads stream while a key is held, so a timeout means the stream
            // stopped. Quick Keys report only changes, so trust the last known state;
            // the 1 Hz watchdog catches a stuck "held".
            guard self.tabletIsQuiescent else { return }
            self.releaseAllSyntheticModifiers()
            self.releaseAllHeldKeyComboKeys()
        }
        watchdogTimer = timer
        if let timer { CFRunLoopAddTimer(HIDThread.shared.runLoop, timer, .commonModes) }
    }

    /// 1 Hz leak check, which works even if `lastAuxButtons` is corrupt. Fires
    /// after 3 s with flags unchanged, the tablet idle, and nothing held. Runs
    /// from main and hops to HIDThread.
    private func checkLeakWatchdog() {
        CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            let idleInterval = Date().timeIntervalSince(self.lastInjectCallAt)
            let penIdleInterval = Date().timeIntervalSince(self.lastPenInjectCallAt)

            // Stuck-proximity backstop. If `lastProximity` latches true (a lost exit
            // report), this much pen silence is proof, so force the exit. Gated on pen
            // idleness, not general idleness: touch frames kept the general timer fresh
            // and once hid a stuck pen for a whole session. Touch arbitration itself uses
            // `touchPenConfirmedBusy`.
            if self.lastProximity, penIdleInterval > Self.stuckProximityTimeout,
                let snap = self.injectionSnapshot
            {
                injectLog.notice("leak-watchdog: forcing stuck pen-proximity exit (pen idle \(Int(penIdleInterval))s)")
                TouchPipelineProbe.note { $0.penProximityForcedExits += 1 }
                self.commitProximityExit(snap: snap)
            }

            // Touch streams while a finger is down, so a held drag with no
            // frames for a second lost its lift.
            if self.touchDragPosition != nil,
               CFAbsoluteTimeGetCurrent() - self.lastTouchFrameTime > 1.0,
               let snap = self.injectionSnapshot {
                injectLog.notice("leak-watchdog: releasing stranded touch drag")
                self.releaseTouchDrag(snapshot: snap)
            }

            if !self.groundTruthSyntheticFlags.isEmpty {
                let heldInterval = Date().timeIntervalSince(self.lastSyntheticFlagChangeAt)
                // As with the idle watchdog above, a device that only reports on state
                // change (Xencelabs QuickKeys) can sit idle for a long legitimate hold —
                // trust the last known button state, not just elapsed time.
                if heldInterval > 3.0 && idleInterval > 3.0 && self.tabletIsQuiescent {
                    modLog.notice("leak-watchdog: releasing stuck synthetic flags 0x\(String(self.groundTruthSyntheticFlags.rawValue, radix: 16), privacy: .public) (held \(Int(heldInterval))s, idle \(Int(idleInterval))s)")
                    self.releaseAllSyntheticModifiers()
                }
            }

            // Same check for a plain key held by a `.keyCombo` binding.
            if !self.heldKeyComboRefCounts.isEmpty {
                let heldInterval = Date().timeIntervalSince(self.lastKeyComboChangeAt)
                if heldInterval > 3.0 && idleInterval > 3.0 && self.tabletIsQuiescent {
                    modLog.notice("leak-watchdog: releasing stuck keyCombo keys \(Array(self.heldKeyComboRefCounts.keys), privacy: .public) (held \(Int(heldInterval))s, idle \(Int(idleInterval))s)")
                    self.releaseAllHeldKeyComboKeys()
                }
            }

            // Same check for the shared store, looking across every device.
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

    // MARK: - Last pen sample
    //
    // Updated on every in-range inject(), for posts that happen between
    // reports: proximity re-announcement and the debounced tip-up.

    var shimLastPoint: TabletPoint? = nil
    var shimLastScreen: CGPoint = .zero

    // MARK: - Settings snapshot
    //
    // The hot path's only view of settings, rebuilt on every change and handed
    // to HIDThread, so inject() never hops to the main actor.

    var injectionSnapshot: InjectionSnapshot?

    // MARK: - Display mapping

    /// Display selection, orientation, calibration, and relative mapping; see
    /// DisplayMapper.swift. HIDThread, except `recomputeVirtualScreenBounds()`
    /// on main.
    var displayMapper = DisplayMapper()

    /// Cached touch coordinate maximums, invalidated when `deviceProductID`
    /// changes.  Saves a per-frame linear scan over `WacomDeviceRegistry`.
    var cachedTouchMaxX: Int = 1
    var cachedTouchMaxY: Int = 1
    /// Active-surface size in mm, from the spec's pen area. Using it for touch is
    /// an approximation. Falls back to raw maximums when the spec has none.
    var cachedTouchWidthMM: Double = 1
    var cachedTouchHeightMM: Double = 1
    /// Touch on a pen display is a touchscreen: the finger drives the cursor
    /// to where it lands, never trackpad-style deltas.
    var cachedTouchIsDirect = false
    /// Model name the pen display's own screen is matched by.
    var cachedTouchModelName = ""
    /// That screen's bounds; nil when no Wacom panel matched.
    var cachedTouchPanelBounds: CGRect?
    /// Set when the device or the display arrangement changes.
    var touchPanelNeedsResolve = true
    var cachedTouchSpecPID: Int = -1
    private var displayObserver: NSObjectProtocol?
    /// See the `willSleepObserver`/`willTerminateObserver` registration in
    /// `init` for why these exist — momentum-tail termination on sleep/quit.
    private var willSleepObserver: NSObjectProtocol?
    private var willTerminateObserver: NSObjectProtocol?

    // MARK: - USB HID mouse button injection (KC-100 cordless mouse)
    //
    // Called for each report 0x01 from the mouse interface. Posts button events
    // at the cursor and sets usbMouseLeftHeld, so movement becomes drags.

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
    /// The current touch sequence has had 2+ contacts, and whether it committed
    /// to a gesture. For `DiscoveryTouchPipeline` diagnostics only.
    var touchSequenceSawTwoFingers = false
    var touchSequenceCommitted = false
    /// Gesture components opened during this sequence; a component can join
    /// partway through (see `noteGestureComponentBegan`).
    var touchSequenceSawPinch = false
    var touchSequenceSawRotate = false
    var touchSequenceBothCounted = false
    /// Owned cursor position for relative touch pointer motion — see
    /// `postTouchPointerMove`. `nil` between sequences; seeded from the OS on
    /// the first move of a sequence.
    var touchOwnedPointerPosition: CGPoint?
    /// When `injectTouch` last ran with contacts, for the sub-millisecond-gap
    /// diagnostic that flags batched Bluetooth bursts.
    var lastTouchFrameTime: CFAbsoluteTime = 0
    /// Whether the previous touch frame was already in the "palm rejection
    /// dropped a ≥2-contact frame below two" condition, so
    /// `palmRejectionBrokeTwoFingerFrames` counts entries, not every held frame.
    var palmRejectionBrokeTwoFingerActive = false
    /// The current touch sequence has had a rejected palm in it, and the
    /// contacts already measured against it, for the palm diagnostics.
    var touchSequenceSawPalm = false
    var palmNeighborMeasuredIDs: Set<Int> = []
    /// `touchTracker.mode` as of the previous `injectTouch` frame, for spotting
    /// `.idle` → `.pending` transitions (onset windows) without the tracker
    /// having to report them. `.idle` initially.
    var prevTouchMode: TouchStateTracker.Mode = .idle
    /// When the last touch sequence ended. A new touch within
    /// `DiscoveryTouchPipeline.reArmWindow` is one interrupted drag, not a new touch.
    var lastTouchTeardownTime: CFAbsoluteTime = 0
    /// Wall-clock time the current single-contact pointer drag began, for
    /// `DiscoveryTouchPipeline.longestSingleContactDragMs`. 0 when not in a
    /// single-contact drag.
    var singleContactDragStart: CFAbsoluteTime = 0
    /// When the pen last left range. Touch waits a brief grace window after,
    /// so a finger landing as the pen lifts isn't taken as input.
    var penProximityExitTime: CFAbsoluteTime = 0
    /// Per-Wacom-driver convention; tunable if reports show false positives.
    static let touchArbitrationGrace: CFAbsoluteTime = 0.08
    /// After the pen leaves proximity, the hand most likely still holds it:
    /// a touch starting this soon can scroll, zoom, or rotate, but not click
    /// or move the cursor. Reasoned, not measured.
    static let penInHandWindow: CFAbsoluteTime = 3.0
    /// Contacts already down while the pen was busy: the hand that held the
    /// pen. Ignored until they lift, so a resting hand never turns into
    /// fingers when the pen leaves.
    var touchPenHeldIDs: Set<Int> = []
    /// The current touch sequence included a palm, a pen-held contact, or
    /// began with the pen in hand. Until every contact lifts, it may scroll,
    /// zoom, or rotate, but its clicks and cursor moves are dropped.
    var touchSequenceTainted = false
    /// Last physical key press, from the flagsChanged tap on HIDThread.
    var lastPhysicalKeyDownTime: CFAbsoluteTime = 0
    /// Where a three-finger drag holds the left button; nil when none is
    /// held. See the `touchDragPosition` row in the latch table above.
    var touchDragPosition: CGPoint?
    /// For this long after a keypress, touch can scroll, zoom, or rotate, but not
    /// click or move the cursor: a resting hand, like a trackpad's typing guard.
    /// Reasoned, not measured.
    static let typingHoldOff: CFAbsoluteTime = 0.5
    /// The pen touched down or stayed in range past `touchBusyHoldOff`. Touch
    /// arbitration gates on this, not raw `lastProximity`: Bluetooth proximity
    /// flaps in 5–45 ms bursts while the pen is just held near the tablet
    /// (capture, 2026-08-22), which blocked touch almost constantly.
    var touchPenConfirmedBusy: Bool = false
    /// Wall-clock time the current proximity session began, for measuring
    /// `touchBusyHoldOff` against.
    var proximityConfirmStartTime: CFAbsoluteTime = 0
    /// How long proximity must last before touch treats the pen as in use:
    /// longer than the measured flap bursts, too short to notice. Tip contact
    /// skips it.
    static let touchBusyHoldOff: CFAbsoluteTime = 0.15

    /// Wall-clock time `touchPenConfirmedBusy` most recently flipped true.
    var touchPenBusyConfirmedAt: CFAbsoluteTime = 0
    /// The pen has touched down since this busy episode began; see
    /// `staleBusyTimeout`.
    var touchPenBusyHadTipSinceConfirmed: Bool = false
    /// How long the pen may count as busy with no tip contact before touch is
    /// let through again. Bluetooth proximity can sit in an ambiguous state for
    /// seconds (PTH-860 capture, 2026-08-25), and the decoder deliberately stays
    /// in range then: exiting early once killed proximity for good. So a hand
    /// moving during a touch gesture could block touch indefinitely. Well above
    /// any pause before a stroke; one tip contact resets it.
    static let staleBusyTimeout: CFAbsoluteTime = 3.0

    func currentCursorPosition() -> CGPoint {
        // Cursor in CG global coordinates, safe off main. NSEvent.mouseLocation
        // needed main and a Y-flip that broke on stacked displays.
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

        // Report the real pen position. Snapping the second click to the first
        // teleported the cursor and triggered drags; apps match double-clicks by
        // time and distance, not exact pixels.
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

    /// Keys held by plain `.keyCombo` bindings, ref-counted like modifiers so
    /// the same watchdog, app-switch, and proximity-exit releases catch a lost
    /// key-up.
    var heldKeyComboRefCounts: [CGKeyCode: Int] = [:]
    /// Timestamp of the last `heldKeyComboRefCounts` mutation, for the leak watchdog.
    var lastKeyComboChangeAt: Date = .distantPast

    /// Left-hand keycodes for each modifier: AppKit and Electron ignore
    /// flagsChanged with keycode 0.
    static let modifierKeyCodes: [(CGEventFlags, CGKeyCode)] = [
        (.maskCommand,   55),  // left ⌘
        (.maskShift,     56),  // left ⇧
        (.maskAlternate, 58),  // left ⌥
        (.maskControl,   59),  // left ⌃
    ]

    /// Last managed-bit result returned by currentEventFlags — used to suppress duplicate log lines.
    var lastLoggedManagedFlags: UInt64 = 0

    /// Private-state source. Our posts still write into hidSystemState, so the
    /// flags tap filters by sourceStateID. Created once: a new source per event
    /// leaked WindowServer memory.
    let sessionSource: CGEventSource? = CGEventSource(stateID: .privateState)

    // MARK: - Screen mapping
    //
    // Forwards to DisplayMapper for callers outside inject() and injectTouch.

    /// When set, `.displayToggle` presses are forwarded here instead of
    /// cycling this injector's own display mapping. Assigned once at connect
    /// by TabletManager for aux-only accessory devices; called on HIDThread.
    var displayToggleForwarder: (() -> Void)?

    /// When set, `.relativeModeToggle` forwards here, like
    /// `displayToggleForwarder`, for aux-only accessories. Called on HIDThread.
    var relativeModeToggleForwarder: (() -> Void)?

    /// `.spanDisplaysToggle` counterpart of `displayToggleForwarder`.
    var spanDisplaysForwarder: (() -> Void)?

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
