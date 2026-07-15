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
