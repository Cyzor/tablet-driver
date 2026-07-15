// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import os
import TabletKit

private let modLog = Logger(subsystem: "com.cyzor.mocktab", category: "modifiers")
private let injectLog = Logger(subsystem: "com.cyzor.mocktab", category: "inject")

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
final class InputInjector: @unchecked Sendable {

    // MARK: - Device identity

    var deviceVendorID: Int
    var deviceProductID: Int
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
    enum AppInputProfile { case generic, pagesPlainMouse }
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

    @MainActor
    init(vendorID: Int = 0x056A, productID: Int = 0) {
        self.deviceVendorID = vendorID
        self.deviceProductID = productID
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
    var lastEraserMode = false  // Track eraser/tip flip while in proximity
    // Named per-button fields rather than an array/dictionary, deliberately:
    // this runs at 133 Hz on the HID hot path, where a direct field read beats
    // a collection's bounds-check/hash overhead, and named fields stay readable
    // in a debugger during real-hardware sessions. See BarrelButtonSlot below
    // for where a small fixed enum already substitutes for a collection where
    // dispatch (not just storage) is needed.
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

    // MARK: - Delta gate
    //
    // Skip posting to the Window Server when position and pressure haven't changed
    // meaningfully. The tablet sends identical coordinates at 133 Hz while stationary;
    // suppressing those drops Mach IPC to zero and eliminates idle wakeups entirely.

    static let positionEpsilon: CGFloat = 0.5  // sub-pixel, not worth posting
    static let pressureEpsilon: Double = 0.002

    // MARK: - Tip-up assist
    //
    // When enabled, delays the mouseUp briefly after the tip lifts if the pen is still
    // in motion. This prevents accidental stroke termination from light tip-release
    // during fast strokes. The pending mouseUp is cancelled if the tip comes back down.

    static let tipUpAssistDelay: Double = 0.08  // seconds
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

    /// Xencelabs-only: debounces the barrel-button *bits themselves*, not
    /// just full proximity loss. This hardware's button-contact sensing
    /// range is shorter than its position-sensing range — a button can
    /// report released while the pen is still tracked and fully in
    /// proximity, then reassert a moment later, so hovering right at that
    /// boundary makes a held click flicker off and on even without a
    /// proximity transition at all. Only the up edge is deferred (a press
    /// should always feel instant); if the button reasserts before the
    /// timer fires, the release never happened as far as anything
    /// downstream is concerned. Gated to vendorID 0x28BD; Wacom hardware's
    /// button and position sensing share one range, so this doesn't apply.
    ///
    /// The window trades two feels against each other: too short and a
    /// sweeping, loosely-held pan (which rides the button-sensing boundary
    /// far longer than the ~80 ms a stationary hover blip lasts) flickers
    /// its held click off mid-drag; too long and every genuine release —
    /// including the end of that same pan — commits noticeably late. The
    /// frames carry no signal that separates a boundary flicker from a
    /// deliberate release, so this is a hand-tuned compromise: 0.25 made
    /// release feel sticky in practice, 0.15 keeps roughly double the
    /// original forgiveness while staying under the lag most hands notice.
    /// (Full proximity loss with a button held is handled separately by
    /// `proximityExitHeldButtonSafetyInterval` and can afford to be long.)
    var button1UpDebounceTimer: CFRunLoopTimer?
    var button2UpDebounceTimer: CFRunLoopTimer?
    var button3UpDebounceTimer: CFRunLoopTimer?
    let buttonUpDebounceInterval: TimeInterval = 0.15

    // MARK: - Time-based leak watchdog
    //
    // Second safety net that fires even when lastAuxButtons is stuck (e.g. USB
    // disconnect mid-press). Unlike the DispatchWorkItem watchdog above, which
    // is only armed while tablet activity is flowing, this 1 Hz timer runs
    // continuously and does not depend on quiescence flags being correct.

    private var leakWatchdogTimer: Timer?
    /// Timestamp of the last groundTruthSyntheticFlags mutation.
    private var lastSyntheticFlagChangeAt: Date = .distantPast
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

    private var flagsChangedTap: CFMachPort?
    private var flagsChangedTapSource: CFRunLoopSource?
    /// Physical modifier bits (⌘⌥⇧⌃) last reported by a hardware flagsChanged event.
    /// Updated only from events with sourceStateID == hidSystemState; immune to our own
    /// synthetic flagsChanged posts.
    private var tapLastPhysicalFlags: UInt64 = 0

    /// True when no physical tablet control is held. If this holds and
    /// `groundTruthSyntheticFlags` is non-empty, the flags are a leak.
    private var tabletIsQuiescent: Bool {
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
            guard let self, !self.groundTruthSyntheticFlags.isEmpty else { return }
            let heldInterval = Date().timeIntervalSince(self.lastSyntheticFlagChangeAt)
            let idleInterval = Date().timeIntervalSince(self.lastInjectCallAt)
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
    var cachedTouchSpecPID: Int = -1
    private var displayObserver: NSObjectProtocol?

    // MARK: - Adobe shim replay

    /// Re-emits the last tablet pointer event.
    /// Called by TabletManager when WacomShim receives an eSendTabletEvent(eEventPointer)
    /// Apple Event from Adobe Photoshop / Illustrator.
    func replayPointerEvent() {
        guard let point = shimLastPoint, let snap = injectionSnapshot else { return }
        postTabletPointerEvent(
            at: shimLastScreen, pressure: shimLastPressure, point: point, snapshot: snap)
        let dragging = lastTipDown || (activeToolIsMouse && usbMouseLeftHeld)
        if dragging {
            postMouseDrag(
                button: activeButton, at: shimLastScreen, pressure: shimLastPressure, point: point,
                snapshot: snap)
        } else {
            postMouseMoved(at: shimLastScreen, point: point, snapshot: snap)
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

    // MARK: - Mouse event helpers

    /// Ground-truth of what synthetic modifiers should be active based on tablet button state.
    private var groundTruthSyntheticFlags: CGEventFlags = []

    /// Reference counts for each modifier bit to support multiple buttons mapped to the same key.
    private var modifierRefCounts: [UInt64: Int] = [
        CGEventFlags.maskCommand.rawValue: 0,
        CGEventFlags.maskShift.rawValue: 0,
        CGEventFlags.maskAlternate.rawValue: 0,
        CGEventFlags.maskControl.rawValue: 0,
    ]

    /// Left-hand canonical keycodes for each managed modifier bit.
    /// Electron and AppKit text input only update their internal modifier state when
    /// a flagsChanged event carries a keycode that matches the actual modifier key —
    /// keycode 0 is silently ignored by many apps.
    private static let modifierKeyCodes: [(CGEventFlags, CGKeyCode)] = [
        (.maskCommand,   55),  // left ⌘
        (.maskShift,     56),  // left ⇧
        (.maskAlternate, 58),  // left ⌥
        (.maskControl,   59),  // left ⌃
    ]

    /// Last managed-bit result returned by currentEventFlags — used to suppress duplicate log lines.
    var lastLoggedManagedFlags: UInt64 = 0

    /// Full modifier flags for state-change events (down/up/click/scroll/flagsChanged).
    ///
    /// Combines physical modifier state with synthetic modifiers from tablet button bindings.
    /// For managed bits (⌘⌥⇧⌃), uses `tapLastPhysicalFlags` rather than reading
    /// `hidSystemState` directly.  `hidSystemState` does not update atomically after posting
    /// events (see OTD PR #4014) — it can lag by one or more run-loop cycles, causing stale
    /// managed bits to re-appear in the next outbound event.  `tapLastPhysicalFlags` is set
    /// inside the flagsChanged session tap, at the exact moment the OS delivers the change to
    /// apps, making it the freshest available physical-state source for managed bits.
    /// Non-managed bits (capslock, numlock, fn …) continue to come from `hidSystemState`.
    /// Logs every transition in managed bits for diagnostics.
    var currentEventFlags: CGEventFlags {
        let result = CGEventFlags(rawValue: ModifierMath.currentEventFlags(
            systemFlags: CGEventSource.flagsState(.hidSystemState).rawValue,
            tapPhysicalManaged: tapLastPhysicalFlags,
            syntheticFlags: groundTruthSyntheticFlags.rawValue
                | SharedAuxModifierState.shared.groundTruthFlags.rawValue))
        let managedNow = result.rawValue & ModifierMath.managedMask
        if managedNow != lastLoggedManagedFlags {
            _ = groundTruthSyntheticFlags.rawValue & ModifierMath.managedMask
            _ = lastLoggedManagedFlags
            // modLog.info("flags: 0x\(String(prev, radix: 16), privacy: .public) → 0x\(String(managedNow, radix: 16), privacy: .public) [hid=0x\(String(physManaged, radix: 16), privacy: .public) synth=0x\(String(synth, radix: 16), privacy: .public)]")
            lastLoggedManagedFlags = managedNow
        }
        return result
    }

    /// Modifier flags for high-frequency move/drag events (mouseMoved, leftMouseDragged, etc.).
    ///
    /// Includes physical (keyboard) modifiers so apps like Illustrator and Keynote can
    /// read ⇧/⌘/⌥/⌃ from drag events for constraint-snapping.  The tap callback is
    /// scheduled on HIDThread (same as inject()), so tapLastPhysicalFlags is written and
    /// read on one thread — the cross-thread race that previously caused stuck modifiers
    /// is eliminated at the source rather than worked around by dropping physical state.
    var moveSafeEventFlags: CGEventFlags {
        let synth = groundTruthSyntheticFlags.rawValue
            | SharedAuxModifierState.shared.groundTruthFlags.rawValue
        return CGEventFlags(rawValue:
            (tapLastPhysicalFlags & ModifierMath.managedMask)
            | synth
            | ModifierMath.leftDeviceBits(for: synth))
    }

    /// The union of modifier flags justified by currently-held pen barrel buttons.
    /// Used by `reconcileSyntheticFlags` to identify orphaned bits after a tool change.
    /// Express-key modifiers are excluded — they arrive via `injectAux` with their own
    /// settings context and are handled by the DispatchWorkItem / time-based watchdogs.
    private func expectedSyntheticFlagsForHeldPenButtons() -> CGEventFlags {
        // Pen-button bindings live on the active tool's snapshot (refreshed on every
        // ToolSettings change). When no snapshot has been seeded yet — e.g. during
        // the brief window before DeviceContext.observeInjectionSnapshot() runs —
        // there are no held pen buttons either, so an empty result is correct.
        guard let snap = injectionSnapshot else { return [] }
        var flags = CGEventFlags()
        if lastButton1Down {
            flags.formUnion(CGEventFlags(rawValue: snap.activeTool.penButton1Binding.modifierFlags))
        }
        if lastButton2Down {
            flags.formUnion(CGEventFlags(rawValue: snap.activeTool.penButton2Binding.modifierFlags))
        }
        if lastButton3Down {
            flags.formUnion(CGEventFlags(rawValue: snap.activeTool.penButton3Binding.modifierFlags))
        }
        return flags
    }

    /// Called whenever `activeToolSettings` changes. Releases any synthetic modifier bits
    /// that are no longer justified by the current pen button bindings. This handles the
    /// eraser-flip / tool-switch scenario: if the user held a barrel button mapped to ⌥
    /// and the tool identity changed mid-hold, the up-edge fires against the new binding
    /// and ⌥ would otherwise be orphaned in `groundTruthSyntheticFlags` forever.
    private func reconcileSyntheticFlags() {
        guard !groundTruthSyntheticFlags.isEmpty else { return }
        let expected = expectedSyntheticFlagsForHeldPenButtons()
        let excessRaw = ModifierMath.excessSyntheticBits(
            groundTruth: groundTruthSyntheticFlags.rawValue,
            expected: expected.rawValue)
        guard excessRaw != 0 else { return }
        let excess = CGEventFlags(rawValue: excessRaw)
        modLog.info("reconcile: tool change orphaned bits 0x\(String(excessRaw, radix: 16), privacy: .public)")

        // Clear excess bits first (mirroring releaseAllSyntheticModifiers ordering):
        // history stays intact so stale-bit detection strips them from outbound events.
        for (bit, _) in Self.modifierKeyCodes where excess.contains(bit) {
            modifierRefCounts[bit.rawValue] = 0
            groundTruthSyntheticFlags.remove(bit)
        }
        lastSyntheticFlagChangeAt = Date()

        // Build explicit release flags: managed bits come from remaining-held synthetic
        // bits (excess already cleared above); non-managed bits from system. Same
        // rationale as releaseAllSyntheticModifiers — hidSystemState is contaminated
        // with our earlier synthetic posts; don't let it re-assert the bits.
        let reconcileFlags = CGEventFlags(rawValue: ModifierMath.releaseEventFlags(
            systemFlags: CGEventSource.flagsState(.hidSystemState).rawValue,
            remainingSyntheticFlags: groundTruthSyntheticFlags.rawValue))

        for (bit, keyCode) in Self.modifierKeyCodes where excess.contains(bit) {
            guard let e = CGEvent(source: sessionSource) else { continue }
            e.type = .flagsChanged
            e.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
            e.flags = reconcileFlags
            e.post(tap: .cghidEventTap)
        }
    }

    /// Releases any synthetic modifier keys currently held by an aux/express-key
    /// binding on ANY device (see `SharedAuxModifierState`). Mirrors
    /// `releaseAllSyntheticModifiers` but clears the shared store instead of this
    /// instance's own ground truth. Safe to call from any instance — the shared
    /// state, and hidSystemState, don't belong to a particular device.
    private func releaseSharedAuxModifiers() {
        let shared = SharedAuxModifierState.shared
        guard !shared.groundTruthFlags.isEmpty else { return }
        let toRelease = shared.groundTruthFlags

        shared.groundTruthFlags = []
        for key in shared.refCounts.keys { shared.refCounts[key] = 0 }
        shared.lastChangeAt = Date()

        let releaseFlags = CGEventFlags(rawValue: ModifierMath.releaseEventFlags(
            systemFlags: CGEventSource.flagsState(.hidSystemState).rawValue,
            remainingSyntheticFlags: groundTruthSyntheticFlags.rawValue))

        for (bit, keyCode) in Self.modifierKeyCodes where toRelease.contains(bit) {
            guard let e = CGEvent(source: sessionSource) else { continue }
            e.type = .flagsChanged
            e.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
            e.flags = releaseFlags
            e.post(tap: .cghidEventTap)
        }
    }

    /// Releases any synthetic modifier keys currently held by tablet button bindings.
    /// Posts one `.flagsChanged` event per held modifier bit, then clears all state.
    /// Safe to call when `groundTruthSyntheticFlags` is already empty (no-op).
    func releaseAllSyntheticModifiers() {
        guard !groundTruthSyntheticFlags.isEmpty else { return }
        let toRelease = groundTruthSyntheticFlags
        let systemBefore = CGEventSource.flagsState(.hidSystemState).rawValue & ModifierMath.managedMask
        modLog.info("releaseAll: clearing 0x\(String(toRelease.rawValue, radix: 16), privacy: .public) (system=0x\(String(systemBefore, radix: 16), privacy: .public))")

        // Clear ground truth and ref counts BEFORE posting.
        groundTruthSyntheticFlags = []
        for key in modifierRefCounts.keys { modifierRefCounts[key] = 0 }
        lastSyntheticFlagChangeAt = Date()

        // Build the explicit release flags: non-managed system bits unchanged;
        // managed bits = 0 for everything being released, 0 for all remaining synthetic
        // bits (ground truth is already cleared).  We do NOT read hidSystemState for
        // managed bits because hidSystemState is polluted by our own earlier synthetic
        // flagsChanged events posted via cghidEventTap — it would re-assert the very
        // bit we are trying to release.  tapLastPhysicalFlags has the same contamination,
        // so we also exclude it for managed bits and start from a clean managed=0 base.
        // If the user is simultaneously holding the same modifier physically on the
        // keyboard, the OS will re-assert it via its own flagsChanged as the key stays
        // held — we don't need to preserve it in this event.
        // Managed bits all clear; non-managed bits preserved from system.
        let releaseFlags = CGEventFlags(rawValue: ModifierMath.releaseEventFlags(
            systemFlags: CGEventSource.flagsState(.hidSystemState).rawValue,
            remainingSyntheticFlags: 0))

        // One flagsChanged per bit with its canonical keycode. Posted DIRECTLY (not via
        // finalizeAndPost) to avoid having currentEventFlags re-stamp the stale system value
        // back in.  Many apps (Electron, Cocoa text input) silently ignore keycode-0 events.
        for (bit, keyCode) in Self.modifierKeyCodes where toRelease.contains(bit) {
            guard let e = CGEvent(source: sessionSource) else { continue }
            e.type = .flagsChanged
            e.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
            e.flags = releaseFlags
            e.post(tap: .cghidEventTap)
        }

        // Audit: re-read hidSystemState shortly after, log if any "released" bit is
        // still set there. Captures the case where the release events were posted but
        // the OS still reports the modifier as held — points to event-tap interference
        // or a state-source mismatch. Async so we sample after WindowServer settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard self != nil else { return }
            let systemAfter = CGEventSource.flagsState(.hidSystemState).rawValue & ModifierMath.managedMask
            let stillStuck = toRelease.rawValue & systemAfter
            if stillStuck != 0 {
                modLog.error("releaseAll: post-audit FAILED — bits 0x\(String(stillStuck, radix: 16), privacy: .public) STILL set in hidSystemState 50ms after release events posted")
            } else {
                modLog.debug("releaseAll: post-audit ok — hidSystemState clean")
            }
        }
    }

    /// Called when the frontmost application changes. Releases any synthetic modifier
    /// keys so the new app receives a clean keyboard state.
    ///
    /// To disable this behavior, remove the call in AppWatcher.appDidActivate — the
    /// proximity-exit safety valve (which calls releaseAllSyntheticModifiers) is
    /// unaffected and continues to operate independently.
    func releaseOnAppSwitch() {
        // groundTruthSyntheticFlags / modifierRefCounts are HIDThread-owned.
        CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.releaseAllSyntheticModifiers()
        }
        CFRunLoopWakeUp(HIDThread.shared.runLoop)
    }

    /// Post a completed CGEvent.
    ///
    /// The caller is responsible for setting `event.flags` before calling:
    /// use `currentEventFlags` for state-change events (mouseDown/Up, click,
    /// scroll, flagsChanged) and `moveSafeEventFlags` for high-frequency
    /// movement events (mouseMoved, leftMouseDragged, tabletPointer).
    /// Keeping the flags decision at the call site avoids invoking
    /// `CGEventSource.flagsState` — a kernel round-trip — on every pen report.
    func finalizeAndPost(_ event: CGEvent) {
        #if DEBUG
        assert(
            groundTruthSyntheticFlags.rawValue & ModifierMath.managedMask
                == groundTruthSyntheticFlags.rawValue,
            "groundTruthSyntheticFlags contains bits outside ModifierMath.managedMask"
        )
        #endif
        event.post(tap: .cghidEventTap)
    }

    @MainActor
    private func installFlagsChangedTap() {
        // Listen-only tap at the session level for .flagsChanged events only.
        // Passive: we never modify events, just observe them.
        let selfPtr = Unmanaged.passUnretained(self)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: { _, _, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passRetained(event) }
                let injector = Unmanaged<InputInjector>.fromOpaque(userInfo).takeUnretainedValue()
                // Only update tapLastPhysicalFlags for hardware keyboard events.
                // Our own injected flagsChanged events use .privateState source and DO
                // write into hidSystemState — reading hidSystemState here would reflect
                // them and corrupt tapLastPhysicalFlags with phantom physical key state.
                // Filter by sourceStateID: hardware events have .hidSystemState (raw=1);
                // our events have a private state ID.  Read event.flags directly to get
                // the exact post-event modifier state without hidSystemState lag/pollution.
                let stateID = Int32(truncatingIfNeeded:
                    event.getIntegerValueField(.eventSourceStateID))
                guard ModifierMath.shouldUpdatePhysicalCache(sourceStateID: stateID) else {
                    return Unmanaged.passRetained(event)
                }
                injector.tapLastPhysicalFlags =
                    event.flags.rawValue & ModifierMath.managedMask
                return Unmanaged.passRetained(event)
            },
            userInfo: selfPtr.toOpaque()
        )
        guard let tap else {
            modLog.error("flagsChanged tap: CGEvent.tap failed (accessibility permission missing?)")
            return
        }
        flagsChangedTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // Register on HIDThread so the tap callback and inject() share one thread.
        // tapLastPhysicalFlags is therefore written and read without cross-thread races.
        CFRunLoopAddSource(HIDThread.shared.runLoop, runLoopSource, .commonModes)
        flagsChangedTapSource = runLoopSource
        // Warm the cache before enabling so the first tap callback has a valid baseline.
        tapLastPhysicalFlags = CGEventSource.flagsState(.hidSystemState).rawValue & ModifierMath.managedMask
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// CGEventSource backed by privateState.  Note: despite documentation implications,
    /// events posted via .cghidEventTap from this source DO write into hidSystemState —
    /// so we filter our own events out of the flagsChangedTap by sourceStateID rather
    /// than relying on hidSystemState to reflect only physical keyboard state.
    ///
    /// Stored once at init — NOT a computed property.  Creating a new CGEventSource on
    /// every event (400+/s at 133 Hz) allocates a private-state slab in the WindowServer
    /// on each call, causing the memory leak observed when a pen is in proximity.
    let sessionSource: CGEventSource? = CGEventSource(stateID: .privateState)

    /// Resolves effective pen pose for CGEvent stamping.
    /// When useRotationAsTilt is true on the active tool, real tilt is suppressed and
    /// barrel rotation is sent as synthetic tilt instead — a "bait and switch" so
    /// Photoshop's Pen Tilt brush dynamics respond to barrel twist.
    private func resolveEffectivePose(
        point: TabletPoint,
        snapshot: InjectionSnapshot
    ) -> (tiltX: Double, tiltY: Double, rotation: Double) {
        let tool = snapshot.activeTool

        var tiltX = point.tiltX
        var tiltY = point.tiltY
        let rotation = point.rotation

        if tool.useRotationAsTilt && point.rotation != 0.0 {
            var degrees = point.rotation

            if snapshot.invertRotation {
                degrees = (360.0 - degrees).truncatingRemainder(dividingBy: 360.0)
            }

            degrees += tool.rotationTiltOffsetDegrees
            // Rotation gives 0–360° but Photoshop's tilt range is only 0–180°.
            // Double the rotation so a full barrel sweep covers the full tilt span.
            let radians = degrees * 2.0 * .pi / 180.0
            let magnitude = tool.rotationTiltMagnitude

            tiltX = magnitude * cos(radians)
            tiltY = magnitude * sin(radians)
        }

        return (tiltX, tiltY, rotation)
    }

    func postMouseDown(
        button: CGMouseButton, at location: CGPoint,
        pressure: Double, clickCount: Int,
        point: TabletPoint? = nil,
        snapshot: InjectionSnapshot
    ) {
        let type: CGEventType
        switch button {
        case .right: type = .rightMouseDown
        case .center: type = .otherMouseDown
        default: type = .leftMouseDown
        }
        guard
            let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: location, mouseButton: button)
        else { return }
        if activeAppProfile != .pagesPlainMouse {
            // subtype must be set first — tabletEvent fields are stored in a union
            // keyed by subtype; Photoshop reads tabletEventPointPressure (the tablet
            // union), not mouseEventPressure; both must be set for full app coverage.
            // Pages text engine is confused by subtype=1 and treats the event as a
            // tablet gesture rather than a plain mouse click, breaking text selection.
            e.setIntegerValueField(.mouseEventSubtype, value: 1)
            e.setIntegerValueField(.tabletEventDeviceID, value: 1)
            e.setIntegerValueField(.tabletEventPointButtons, value: 1)
            e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
            e.setDoubleValueField(.mouseEventPressure, value: pressure)
            if let p = point {
                let pose = resolveEffectivePose(point: p, snapshot: snapshot)
                e.setDoubleValueField(.tabletEventTiltX, value: pose.tiltX)
                e.setDoubleValueField(.tabletEventTiltY, value: pose.tiltY)
                e.setDoubleValueField(.tabletEventRotation, value: pose.rotation)
            }
        }
        // Synthetic CGEvents default to click count 0. Always set it so that
        // double-clicks are recognised (e.g. entering floating text-box edit mode
        // in Pages/Keynote/Numbers requires clickState=2 even in plain-mouse mode).
        //
        // In plain-mouse mode only inject click state for multi-clicks: Quartz
        // already tracks single-click state internally, and explicitly setting
        // clickState=1 disrupts Pages' drag-selection state machine.
        if activeAppProfile != .pagesPlainMouse || clickCount > 1 {
            e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        e.flags = currentEventFlags
        finalizeAndPost(e)
    }

    func postMouseUp(
        button: CGMouseButton, at location: CGPoint,
        clickCount: Int, point: TabletPoint? = nil,
        snapshot: InjectionSnapshot
    ) {
        let type: CGEventType
        switch button {
        case .right: type = .rightMouseUp
        case .center: type = .otherMouseUp
        default: type = .leftMouseUp
        }
        guard
            let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: location, mouseButton: button)
        else { return }
        if activeAppProfile != .pagesPlainMouse {
            e.setIntegerValueField(.mouseEventSubtype, value: 1)
            e.setIntegerValueField(.tabletEventDeviceID, value: 1)
            e.setIntegerValueField(.tabletEventPointButtons, value: 0)
            e.setDoubleValueField(.tabletEventPointPressure, value: 0)
            e.setDoubleValueField(.mouseEventPressure, value: 0)
            if let p = point {
                let pose = resolveEffectivePose(point: p, snapshot: snapshot)
                e.setDoubleValueField(.tabletEventTiltX, value: pose.tiltX)
                e.setDoubleValueField(.tabletEventTiltY, value: pose.tiltY)
                e.setDoubleValueField(.tabletEventRotation, value: pose.rotation)
            }
        }
        if activeAppProfile != .pagesPlainMouse || clickCount > 1 {
            e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        e.flags = currentEventFlags
        finalizeAndPost(e)
    }

    func postMouseDrag(
        button: CGMouseButton, at location: CGPoint,
        pressure: Double, point: TabletPoint? = nil,
        snapshot: InjectionSnapshot
    ) {
        let type: CGEventType
        switch button {
        case .right: type = .rightMouseDragged
        case .center: type = .otherMouseDragged
        default: type = .leftMouseDragged
        }
        guard
            let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: location, mouseButton: button)
        else { return }
        if activeAppProfile != .pagesPlainMouse {
            e.setIntegerValueField(.mouseEventSubtype, value: 1)
            e.setIntegerValueField(.tabletEventDeviceID, value: 1)
            e.setIntegerValueField(.tabletEventPointButtons, value: pressure > 0.004 ? 1 : 0)
            e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
            e.setDoubleValueField(.mouseEventPressure, value: pressure)
            if let p = point {
                let pose = resolveEffectivePose(point: p, snapshot: snapshot)
                e.setDoubleValueField(.tabletEventTiltX, value: pose.tiltX)
                e.setDoubleValueField(.tabletEventTiltY, value: pose.tiltY)
                e.setDoubleValueField(.tabletEventRotation, value: pose.rotation)
            }
        }
        // Synthetic CGEvents default to zero deltas, breaking AppKit controls (e.g.
        // Xcode's minimap) that read event.deltaX/Y rather than diffing absolute
        // positions themselves. CG Y=0 is top; NSEvent deltaY is positive-upward,
        // so negate the Y component.
        e.setIntegerValueField(
            .mouseEventDeltaX, value: Int64((location.x - lastPostedPoint.x).rounded()))
        e.setIntegerValueField(
            .mouseEventDeltaY, value: Int64((location.y - lastPostedPoint.y).rounded()))
        e.flags = moveSafeEventFlags
        finalizeAndPost(e)
    }

    func postMouseMoved(
        at location: CGPoint, point: TabletPoint? = nil, snapshot: InjectionSnapshot
    ) {
        guard
            let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: .mouseMoved,
                mouseCursorPosition: location, mouseButton: .left)
        else { return }
        if activeAppProfile != .pagesPlainMouse {
            if let p = point {
                let pose = resolveEffectivePose(point: p, snapshot: snapshot)
                e.setIntegerValueField(.mouseEventSubtype, value: 1)
                e.setIntegerValueField(.tabletEventDeviceID, value: 1)
                e.setDoubleValueField(.tabletEventTiltX, value: pose.tiltX)
                e.setDoubleValueField(.tabletEventTiltY, value: pose.tiltY)
                e.setDoubleValueField(.tabletEventRotation, value: pose.rotation)
            }
        }
        e.setIntegerValueField(
            .mouseEventDeltaX, value: Int64((location.x - lastPostedPoint.x).rounded()))
        e.setIntegerValueField(
            .mouseEventDeltaY, value: Int64((location.y - lastPostedPoint.y).rounded()))
        e.flags = moveSafeEventFlags
        finalizeAndPost(e)
    }

    // MARK: - Raw tablet pointer event

    func postTabletPointerEvent(
        at location: CGPoint, pressure: Double,
        point: TabletPoint, snapshot: InjectionSnapshot
    ) {
        guard let e = CGEvent(source: sessionSource) else {
            injectLog.error("postTabletPointerEvent: CGEvent creation failed — pen point dropped")
            return
        }
        e.type = .tabletPointer
        e.location = location
        e.setIntegerValueField(.tabletEventDeviceID, value: 1)
        e.setIntegerValueField(.tabletEventPointX, value: Int64(point.x))
        e.setIntegerValueField(.tabletEventPointY, value: Int64(point.y))
        e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        let pose = resolveEffectivePose(point: point, snapshot: snapshot)
        e.setDoubleValueField(.tabletEventTiltX, value: pose.tiltX)
        e.setDoubleValueField(.tabletEventTiltY, value: pose.tiltY)
        e.setDoubleValueField(.tabletEventRotation, value: pose.rotation)
        let buttons: Int64 =
            (pressure > 0.004 ? 1 : 0)
            | (point.penButton1 ? 2 : 0)
            | (point.penButton2 ? 4 : 0)
            | (activeToolIsEraser && pressure > 0.004 ? 8 : 0)
        e.setIntegerValueField(.tabletEventPointButtons, value: buttons)
        e.flags = moveSafeEventFlags
        finalizeAndPost(e)
    }

    // MARK: - Proximity event

    func postProximityEvent(
        entering: Bool, at location: CGPoint,
        eraser: Bool
    ) {
        guard let e = CGEvent(source: sessionSource) else {
            injectLog.error("postProximityEvent: CGEvent creation failed — entering=\(entering) eraser=\(eraser)")
            return
        }
        e.type = .tabletProximity
        e.location = location

        e.setIntegerValueField(
            .tabletProximityEventVendorID,
            value: Int64(deviceVendorID))
        e.setIntegerValueField(
            .tabletProximityEventTabletID,
            value: Int64(deviceProductID))
        // Tip and eraser ends get distinct pointerIDs so apps that track tool identity
        // separately (e.g. Procreate, Clip Studio) don't conflate the two ends.
        // 0x0002 = pen tip, 0x0082 = eraser (high bit marks the "other end" of the same pen).
        let pointerID: Int64 = eraser ? 0x0082 : 0x0002
        e.setIntegerValueField(.tabletProximityEventPointerID, value: pointerID)
        e.setIntegerValueField(.tabletProximityEventDeviceID, value: 1)

        // Serial lets apps maintain per-tool brush memories (e.g. Photoshop's tool presets).
        // Eraser end uses serial | 0x80000000 so tip and eraser each get an independent slot.
        // kCGTabletProximityEventPointerSerialNumber = 172 (raw value; not exposed in Swift).
        if activeToolSerial != 0 {
            let serial: Int64 =
                eraser
                ? Int64(bitPattern: UInt64(activeToolSerial) | 0x8000_0000)
                : Int64(activeToolSerial)
            if let serialField = CGEventField(rawValue: 172) {
                e.setIntegerValueField(serialField, value: serial)
            }
        }
        e.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 0)

        // pointerType: 0 = leaving, 1 = pen, 2 = cursor/mouse, 3 = eraser
        let ptrType: Int64 = entering ? (eraser ? 3 : (activeToolIsMouse ? 2 : 1)) : 0
        e.setIntegerValueField(.tabletProximityEventPointerType, value: ptrType)

        // Use activeToolCode for vendor pointer type; default to Grip Pen (0x0802).
        // Art Pen variants use 0x0812 (rotation-capable pen subtype) so apps like Krita
        // and Rebelle categorise the tool correctly and use rotation rather than tilt.
        // Previously reported as 0x0802 to work around a barrel-button debounce bug
        // (EA/E0 sub-frame; barrel bits read from rotation packets) — now fixed.
        let toolCode = activeToolCode
        let vendorPtr: Int64
        if eraser {
            vendorPtr = 0x080A  // Grip Pen Eraser
        } else if activeToolIsMouse {
            vendorPtr = 0x0006  // Intuos Mouse
        } else {
            switch toolCode {
            case 0x0804, 0x1108, 0x1804:  // Art Pen variants
                vendorPtr = 0x0812  // Art Pen / rotation-capable pen
            case 0x0842:  // Pro Pen 3
                vendorPtr = 0x0842
            case 0x0832:  // Pro Pen 2
                vendorPtr = 0x0832
            case 0x0852:  // Pen 4K
                vendorPtr = 0x0852
            default:
                vendorPtr = 0x0802  // Grip Pen fallback
            }
        }
        e.setIntegerValueField(.tabletProximityEventVendorPointerType, value: vendorPtr)
        e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x05C7)
        e.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        e.flags = currentEventFlags
        finalizeAndPost(e)
    }

    // MARK: - Button binding execution

    /// Settings writes for `.displayToggle` / `.ringCycle` / `.ringSelectSlot` are
    /// dispatched to main; everything else runs synchronously on the caller's thread
    /// (HIDThread for inject/injectAux/injectMouseButtons).
    func fireButtonAction(
        _ binding: ButtonBinding, down: Bool,
        at location: CGPoint,
        snapshot: InjectionSnapshot,
        settings: TabletSettings? = nil,
        isAux: Bool = false
    ) {
        switch binding.kind {
        case .none:
            break
        case .leftClick:
            hoverDragButton = down ? .left : nil
            let type: CGEventType = down ? .leftMouseDown : .leftMouseUp
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: location, mouseButton: .left)
            {
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }
        case .rightClick, .eraser:
            hoverDragButton = down ? .right : nil
            let type: CGEventType = down ? .rightMouseDown : .rightMouseUp
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: location, mouseButton: .right)
            {
                // Match OTD's event format: subtype=1 + devID + ptBtns, pressure explicitly 0.
                // CGEvent auto-sets mouseEventPressure=1.0 on mouseDown; zeroing it prevents
                // apps like QGIS, SketchUp from treating the button press as a tip contact.
                e.setIntegerValueField(.mouseEventSubtype, value: 1)
                e.setIntegerValueField(.tabletEventDeviceID, value: 1)
                e.setIntegerValueField(.tabletEventPointButtons, value: down ? 2 : 0)  // bit 1 = right
                e.setDoubleValueField(.tabletEventPointPressure, value: 0.0)
                e.setDoubleValueField(.mouseEventPressure, value: 0.0)
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }
        case .middleClick:
            hoverDragButton = down ? .center : nil
            let type: CGEventType = down ? .otherMouseDown : .otherMouseUp
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: location, mouseButton: .center)
            {
                // Match OTD's event format: subtype=1 + devID + ptBtns, pressure explicitly 0.
                // CGEvent auto-sets mouseEventPressure=1.0 on mouseDown; zeroing it prevents
                // apps like SketchUp from treating the button press as a tip contact.
                e.setIntegerValueField(.mouseEventSubtype, value: 1)
                e.setIntegerValueField(.tabletEventDeviceID, value: 1)
                e.setIntegerValueField(.tabletEventPointButtons, value: down ? 4 : 0)
                e.setDoubleValueField(.tabletEventPointPressure, value: 0.0)
                e.setDoubleValueField(.mouseEventPressure, value: 0.0)
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }
        case .middleClickWithTip:
            hoverDragButton = down ? .center : nil
            // Like middleClick, but stamps tablet tip-down fields so apps that gate
            // on tip contact (SketchUp, some CAD tools) accept the event.
            let type: CGEventType = down ? .otherMouseDown : .otherMouseUp
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: location, mouseButton: .center)
            {
                e.setIntegerValueField(.mouseEventSubtype, value: 1)
                e.setIntegerValueField(.tabletEventDeviceID, value: 1)
                e.setIntegerValueField(.tabletEventPointButtons, value: down ? 4 : 0)  // bit 2 = middle
                e.setDoubleValueField(.tabletEventPointPressure, value: down ? 1.0 : 0.0)
                e.setDoubleValueField(.mouseEventPressure, value: down ? 1.0 : 0.0)
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }
        case .keyCombo:
            let bindingFlags = CGEventFlags(rawValue: binding.modifierFlags)
            let modBits: [CGEventFlags] = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

            // Build the CGEvent BEFORE mutating state. If construction fails (rare, but
            // can happen under memory pressure or CoreGraphics saturation), we bail without
            // touching groundTruthSyntheticFlags or modifierRefCounts. The old code mutated
            // state first, leaving orphaned modifier bits when the event never reached the OS.
            let isModifierOnly = binding.keyLabel.isEmpty && binding.modifierFlags != 0
            let event: CGEvent?
            if isModifierOnly {
                let e = CGEvent(source: sessionSource)
                e?.type = .flagsChanged
                e?.setIntegerValueField(.keyboardEventKeycode, value: Int64(binding.keyCode))
                event = e
            } else {
                event = CGEvent(
                    keyboardEventSource: sessionSource,
                    virtualKey: CGKeyCode(binding.keyCode),
                    keyDown: down)
            }

            if event == nil {
                modLog.error("CGEvent creation failed — keyCombo '\(binding.keyLabel, privacy: .public)' down=\(down); state NOT mutated")
            }
            guard let e = event else { break }

            // Real keyboards bracket a modified keystroke with flagsChanged
            // events (⌘ down → Space down → Space up → ⌘ up); apps that track
            // modifier state from flagsChanged transitions alone (Rebelle)
            // never saw a modifier release when we only stamped flags on the
            // keyDown/keyUp pair. Post in hardware order: modifiers assert
            // before the keyDown; the keyUp still carries the held modifiers
            // (so it goes out before the state decrement below); the release
            // flagsChanged comes last.
            let bracketModifiers = !isModifierOnly && binding.modifierFlags != 0
            if bracketModifiers && !down {
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }

            // Event created successfully — now commit the state delta.
            //
            // Aux-sourced bindings (express keys, touch-ring center click) go to the
            // process-wide shared store instead of this instance's own ground truth.
            // An aux-only accessory (Xencelabs QuickKeys) is its own physical device
            // with its own InputInjector — a Shift it asserts must still show up in
            // the flags on drag events posted by whichever InputInjector is actually
            // driving the pointer (the pen tablet's), which never sees this instance's
            // local groundTruthSyntheticFlags. Pen-button bindings (barrel buttons)
            // keep using local state because they're reconciled against this device's
            // own active tool (see reconcileSyntheticFlags) — sharing them globally
            // would let an unrelated device's tool change strip them.
            if isAux {
                let shared = SharedAuxModifierState.shared
                let flagsBefore = shared.groundTruthFlags
                for bit in modBits {
                    if bindingFlags.contains(bit) {
                        let raw = bit.rawValue
                        let currentCount = shared.refCounts[raw] ?? 0
                        if down {
                            shared.refCounts[raw] = currentCount + 1
                            shared.groundTruthFlags.insert(bit)
                        } else {
                            let newCount = Swift.max(0, currentCount - 1)
                            shared.refCounts[raw] = newCount
                            if newCount == 0 { shared.groundTruthFlags.remove(bit) }
                        }
                    }
                }
                if shared.groundTruthFlags != flagsBefore {
                    shared.lastChangeAt = Date()
                    modLog.debug("keyCombo(aux) \(down ? "DOWN" : "UP", privacy: .public) bindFlags=0x\(String(binding.modifierFlags, radix: 16), privacy: .public) keyCode=\(binding.keyCode) shared: 0x\(String(flagsBefore.rawValue, radix: 16), privacy: .public) → 0x\(String(shared.groundTruthFlags.rawValue, radix: 16), privacy: .public)")
                }
            } else {
                let flagsBefore = groundTruthSyntheticFlags
                for bit in modBits {
                    if bindingFlags.contains(bit) {
                        let raw = bit.rawValue
                        let currentCount = modifierRefCounts[raw] ?? 0
                        if down {
                            modifierRefCounts[raw] = currentCount + 1
                            groundTruthSyntheticFlags.insert(bit)
                        } else {
                            let newCount = Swift.max(0, currentCount - 1)
                            modifierRefCounts[raw] = newCount
                            if newCount == 0 { groundTruthSyntheticFlags.remove(bit) }
                        }
                    }
                }
                if groundTruthSyntheticFlags != flagsBefore {
                    lastSyntheticFlagChangeAt = Date()
                    modLog.debug("keyCombo \(down ? "DOWN" : "UP", privacy: .public) bindFlags=0x\(String(binding.modifierFlags, radix: 16), privacy: .public) keyCode=\(binding.keyCode) groundTruth: 0x\(String(flagsBefore.rawValue, radix: 16), privacy: .public) → 0x\(String(self.groundTruthSyntheticFlags.rawValue, radix: 16), privacy: .public)")
                }
            }
            // State is committed — post the flagsChanged bracket(s) with the
            // post-commit flags: on DOWN they assert the modifiers ahead of the
            // keyDown; on UP they carry the released state after the keyUp that
            // already went out above. One event per modifier bit with its
            // canonical left-hand keycode (keycode-0 events are ignored by
            // many apps — see modifierKeyCodes).
            if bracketModifiers {
                for (bit, keyCode) in Self.modifierKeyCodes where bindingFlags.contains(bit) {
                    guard let fc = CGEvent(source: sessionSource) else { continue }
                    fc.type = .flagsChanged
                    fc.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
                    fc.flags = currentEventFlags
                    finalizeAndPost(fc)
                }
            }
            if !(bracketModifiers && !down) {
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }
        case .displayToggle:
            guard down else { break }
            // Aux-only accessories (Xencelabs Quick Keys) move no pointer of
            // their own, so cycling this injector's mapping would do nothing
            // visible — TabletManager wires a forwarder that steers the
            // tablet actually driving the cursor. Never set on pen-bearing
            // devices, so their toggle path below is unchanged.
            if let forward = displayToggleForwarder {
                forward()
                break
            }
            // Cache invalidation is local to HIDThread; only the persisted
            // index needs to round-trip through main.
            cycleToggleDisplay(snapshot: snapshot)
            if let s = settings {
                Task { @MainActor in s.targetDisplayIndex = TabletSettings.displayModeToggle }
            }
        case .ringCycle:
            guard down else { break }
            if let s = settings {
                Task { @MainActor in
                    // Slots set to Skip are left out of the rotation —
                    // Wacom's native way to shorten the mode cycle when only
                    // one or two modes matter. If every slot is set to Skip,
                    // stay where we are.
                    let count = max(1, s.touchRingSlots.count)
                    var next = s.touchRingActiveSlotIndex
                    for _ in 0..<count {
                        next = (next + 1) % count
                        if s.touchRingSlots.indices.contains(next),
                            s.touchRingSlots[next].action != .skip
                        { break }
                    }
                    s.touchRingActiveSlotIndex = next
                }
            }
        case .ringSelectSlot:
            guard down else { break }
            let target = min(Int(binding.keyCode), max(0, snapshot.touchRingSlots.count - 1))
            if let s = settings {
                Task { @MainActor in s.touchRingActiveSlotIndex = target }
            }
        case .doubleClick:
            guard down else { break }
            for clickState in [1, 2] {
                for isDown in [true, false] {
                    let type: CGEventType = isDown ? .leftMouseDown : .leftMouseUp
                    if let e = CGEvent(
                        mouseEventSource: sessionSource, mouseType: type,
                        mouseCursorPosition: location, mouseButton: .left)
                    {
                        e.flags = currentEventFlags
                        e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
                        finalizeAndPost(e)
                    }
                }
            }
        case .spacebar:
            if let e = CGEvent(keyboardEventSource: sessionSource, virtualKey: 49, keyDown: down) {
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }
        }

        // Safety valve: if nothing is physically held on the tablet but we still
        // believe a synthetic modifier is pressed, it is by definition a leak.
        if tabletIsQuiescent && !groundTruthSyntheticFlags.isEmpty {
            releaseAllSyntheticModifiers()
        }
        rearmWatchdog()
    }

    // MARK: - Scroll wheel

    /// Scales `rawDelta` by `slot.speed`, accumulates fractional remainder, then
    /// fires scroll lines or key taps. Caps key repeat at 4 per pulse to prevent
    /// runaway at high speed + large delta.
    func dispatchRingDelta(
        rawDelta: Int, slot: ControlSlot, accum: inout Double,
        at location: CGPoint, snapshot: InjectionSnapshot, settings: TabletSettings?
    ) {
        accum += Double(rawDelta) * slot.speed
        let lines = Int(accum)
        guard lines != 0 else { return }
        accum -= Double(lines)
        switch slot.action {
        case .scroll:
            postScrollWheelEvent(delta: lines, at: location)
        case .keyPress:
            let binding = lines > 0 ? slot.cwBinding : slot.ccwBinding
            let count = min(abs(lines), 4)
            for _ in 0..<count {
                fireKeyTap(binding, at: location, snapshot: snapshot, settings: settings)
            }
        case .off, .skip:
            break
        }
    }

    func postScrollWheelEvent(delta: Int, at location: CGPoint) {
        // .line units: one detent = one scroll line, consistent with trackpad / Magic Mouse.
        guard
            let e = CGEvent(
                scrollWheelEvent2Source: sessionSource, units: .line,
                wheelCount: 1, wheel1: Int32(delta * 3), wheel2: 0, wheel3: 0)
        else { return }
        e.location = location
        e.flags = currentEventFlags
        finalizeAndPost(e)
    }

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
