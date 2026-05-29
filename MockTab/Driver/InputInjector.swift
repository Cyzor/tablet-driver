// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import os

private let modLog = Logger(subsystem: "com.cyzor.mocktab", category: "modifiers")
private let injectLog = Logger(subsystem: "com.cyzor.mocktab", category: "inject")

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
final class InputInjector {

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
    /// May be overridden by forcedToolCode from DeviceRegistry if set by the user.
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

    @MainActor
    init(vendorID: Int = 0x056A, productID: Int = 0) {
        self.deviceVendorID = vendorID
        self.deviceProductID = productID
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
                self.cachedDisplayIndex = Int.min
                self.cachedCalibrationOrientation = -1
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
    }

    // MARK: - State

    private(set) var lastProximity = false
    private var lastTipDown = false
    /// True after the first leftMouseDragged is posted following a tip-down.
    /// Used to guarantee Pages sees at least one drag event even when deltas are tiny.
    private var didEmitDragSinceDown = false
    private var lastEraserMode = false  // Track eraser/tip flip while in proximity
    private var lastButton1Down = false
    private var lastButton2Down = false
    private var lastMiddleDown = false
    private var activeButton: CGMouseButton = .left

    // MARK: - USB mouse button state
    //
    // For KC-100 cordless mouse over USB: buttons arrive on a separate standard
    // HID mouse interface (Report ID 0x01) rather than in the digitizer 0x10 stream.
    // injectMouseButtons() is called from that interface's device driver; inject()
    // reads usbMouseLeftHeld to decide drag vs hover when emitting movement events.
    private var lastUSBMouseMask: UInt8 = 0
    private var usbMouseLeftHeld: Bool = false

    // MARK: - Cursor smoothing, jitter, velocity
    //
    // Per-report position smoothing (EMA), rolling jitter window, and short-window
    // velocity for tip-up assist. State and math live in CursorSmoother.swift;
    // InputInjector holds the instance and forwards reads where needed.

    private var smoother = CursorSmoother()

    /// Mean hover-position delta over the rolling window (points per sample).
    /// Spikes above ~3 pt/sample while hovering suggest RF interference.
    var jitterLevel: CGFloat { smoother.jitterLevel }
    var isJittery: Bool { smoother.isJittery }

    // MARK: - Relative movement
    //
    // When relativeCursorMovement is enabled, the pen acts like a mouse: each report
    // moves the cursor by the delta from the previous normalized tablet position,
    // scaled to the display size.  lastRelativeNorm is cleared at proximity exit so
    // the first report after hover-entry doesn't produce a large jump.

    private var lastRelativeNorm: CGPoint? = nil

    // MARK: - Delta gate
    //
    // Skip posting to the Window Server when position and pressure haven't changed
    // meaningfully. The tablet sends identical coordinates at 133 Hz while stationary;
    // suppressing those drops Mach IPC to zero and eliminates idle wakeups entirely.

    private static let positionEpsilon: CGFloat = 0.5  // sub-pixel, not worth posting
    private static let pressureEpsilon: Double = 0.002

    // MARK: - Tip-up assist
    //
    // When enabled, delays the mouseUp briefly after the tip lifts if the pen is still
    // in motion. This prevents accidental stroke termination from light tip-release
    // during fast strokes. The pending mouseUp is cancelled if the tip comes back down.

    private static let tipUpAssistDelay: Double = 0.08  // seconds
    private static let tipUpAssistVelocityThreshold: CGFloat = 2.0  // pts/sample
    private var pendingMouseUp: DispatchWorkItem? = nil

    /// Set while a barrel-button click binding is held, so the movement path posts
    /// otherMouseDragged / rightMouseDragged instead of mouseMoved.
    private var hoverDragButton: CGMouseButton? = nil

    private var lastPostedPoint: CGPoint = .zero
    private var lastPostedPressure: Double = -1.0
    private var hasPostedPoint = false

    // MARK: - Click state

    private var lastClickPosition: CGPoint = .zero
    private var lastClickTime: CFAbsoluteTime = 0
    private var clickCount: Int = 0
    private var activeClickCount: Int = 1

    // MARK: - Express key / touch ring state

    private var lastAuxButtons = [Bool](repeating: false, count: 16)
    private var lastRingButtonDown = false
    /// Last observed touch ring position (0–71). 0x7F = no contact.
    private var lastRingPos: UInt8 = 0x7F
    /// Last observed right touch ring position (DTK-2400). 0x7F = no contact.
    private var lastRing2Pos: UInt8 = 0x7F
    /// Last observed Intuos3 WS touch strip positions. 0xFF = no contact.
    private var lastStrip1Pos: UInt8 = 0xFF
    private var lastStrip2Pos: UInt8 = 0xFF
    /// Fractional-delta accumulators for ring/strip speed scaling.
    /// Carry sub-integer remainders across pulses so speed < 1.0 fires evenly.
    private var ringAccum: Double = 0
    private var ring2Accum: Double = 0
    private var strip1Accum: Double = 0
    private var strip2Accum: Double = 0
    /// Fractional-delta accumulators for IntuosV3 relative scroll wheels (index 0 and 1).
    private var wheel0Accum: Double = 0
    private var wheel1Accum: Double = 0

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
        !lastTipDown && !lastButton1Down && !lastButton2Down
            && !lastRingButtonDown
            && lastRingPos == 0x7F && lastRing2Pos == 0x7F
            && lastStrip1Pos == 0xFF && lastStrip2Pos == 0xFF
            && lastUSBMouseMask == 0
            && !lastAuxButtons.contains(true)
    }

    /// Must run on HIDThread (where `watchdogTimer`, `lastInjectCallAt`, and
    /// `groundTruthSyntheticFlags` are owned).
    private func rearmWatchdog() {
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
            self.releaseAllSyntheticModifiers()
        }
        watchdogTimer = timer
        if let timer { CFRunLoopAddTimer(HIDThread.shared.runLoop, timer, .commonModes) }
    }

    /// 1 Hz time-based leak detection. Fires even when `lastAuxButtons` is corrupt
    /// (e.g. USB disconnect mid-press), a scenario where the DispatchWorkItem watchdog
    /// above is never rearmed and therefore never fires.
    ///
    /// Condition: synthetic flags have been stuck in the same state for > 3 s AND the
    /// tablet has been completely idle for > 3 s. A legitimately held express-key keeps
    /// resetting `lastInjectCallAt` via `rearmWatchdog`, so this never fires during real use.
    /// Called from main (Timer fires on the runloop the timer was scheduled on).
    /// Hops to HIDThread to read/mutate modifier state without races.
    private func checkLeakWatchdog() {
        CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self, !self.groundTruthSyntheticFlags.isEmpty else { return }
            let heldInterval = Date().timeIntervalSince(self.lastSyntheticFlagChangeAt)
            let idleInterval = Date().timeIntervalSince(self.lastInjectCallAt)
            if heldInterval > 3.0 && idleInterval > 3.0 {
                modLog.notice("leak-watchdog: releasing stuck synthetic flags 0x\(String(self.groundTruthSyntheticFlags.rawValue, radix: 16), privacy: .public) (held \(Int(heldInterval))s, idle \(Int(idleInterval))s)")
                self.releaseAllSyntheticModifiers()
            }
        }
        CFRunLoopWakeUp(HIDThread.shared.runLoop)
    }

    // MARK: - Adobe shim replay cache
    //
    // Populated on every inject() call so WacomShim can re-emit the last
    // tablet event in response to an Apple Events eSendTabletEvent request.

    private(set) var shimLastPoint: TabletPoint? = nil
    private(set) var shimLastScreen: CGPoint = .zero
    private(set) var shimLastPressure: Double = 0.0

    // MARK: - Settings snapshot (Phase 2 — populated, not yet read)
    //
    // Owned by main actor for now. Refreshed by DeviceContext on every
    // settings/tool change. Phase 3 will switch this to nonisolated(unsafe)
    // and route writes through CFRunLoopPerformBlock(HIDThread.shared.runLoop)
    // so inject() can read it inline on HIDThread without the @MainActor hop.

    var injectionSnapshot: InjectionSnapshot?

    // MARK: - Display bounds cache

    private var cachedDisplayBounds: CGRect = .zero
    private var cachedDisplayIndex: Int = Int.min
    private var cachedDisplayUUID: String = ""
    private var cachedCalibration: CalibrationEntry?
    private var cachedCalibrationOrientation: Int = -1
    /// Cached touch coordinate maximums, invalidated when `deviceProductID`
    /// changes.  Saves a per-frame linear scan over `WacomDeviceRegistry`.
    private var cachedTouchMaxX: Int = 1
    private var cachedTouchMaxY: Int = 1
    private var cachedTouchSpecPID: Int = -1
    private var currentToggleIndex: Int = 0
    private var displayObserver: NSObjectProtocol?

    /// Union of all NSScreen frames in CG (top-left origin) coordinates, used by
    /// relative-mode mapping. NSScreen is AppKit and main-thread-only; reading it
    /// inside `resolveRelativePoint` blocks moving inject() off the main actor.
    /// Recomputed on main when displays change (didChangeScreenParametersNotification).
    private var cachedVirtualScreenBounds: CGRect = .zero

    // MARK: - Pen injection

    func inject(point: TabletPoint, settings: TabletSettings?) {
        rearmWatchdog()
        // The snapshot is seeded synchronously in DeviceContext.observeInjectionSnapshot()
        // before any HID report can arrive, so this guard is defense-in-depth.
        guard let snap = injectionSnapshot else { return }
        let tool = snap.activeTool
        var point = point
        if snap.invertRotation && point.rotation != 0.0 {
            point.rotation = (360.0 - point.rotation).truncatingRemainder(dividingBy: 360.0)
        }
        let rawPoint: CGPoint
        if snap.relativeCursorMovement {
            rawPoint = resolveRelativePoint(point, snapshot: snap)
        } else {
            guard let absPoint = mapToScreen(point, snapshot: snap) else {
                // Pen outside active area — deadzone, no events
                lastRelativeNorm = nil
                return
            }
            rawPoint = absPoint
        }
        let lutIdx = Swift.min(Swift.max(Int((point.normalizedPressure * 255.0).rounded()), 0), 255)
        let pressure = tool.pressureLUT[lutIdx]
        // Mouse tools have no tip pressure — button1 is the primary click trigger.
        // For KC-100 over USB, the left button arrives via the separate 0x01 mouse interface
        // and injectMouseButtons() has already fired leftMouseDown/Up.  Keep tipDown false
        // so inject() doesn't re-fire the click; usbMouseLeftHeld drives drag vs hover below.
        let tipDown =
            activeToolIsMouse
            ? (usbMouseLeftHeld ? false : point.penButton1)
            : pressure > 0.004

        let enteringProximity = point.inProximity && !lastProximity
        let eraserFlipped = point.inProximity && lastProximity && (point.eraser != lastEraserMode)

        // ── Proximity transitions (always immediate) ───────────────────────────
        if point.inProximity != lastProximity {
            // Suppress tabletProximity for plain-mouse profiles: receiving this event
            // triggers NSTextView's tablet-tracking code path, causing it to route
            // subsequent mouse events through pressure-selection logic that breaks
            // normal text selection (drag doesn't extend, only Shift/Command drag works).
            if activeAppProfile == .generic {
                postProximityEvent(
                    entering: point.inProximity, at: rawPoint,
                    eraser: point.eraser)
            }
            if point.inProximity {
                activeToolIsEraser = point.eraser
                lastEraserMode = point.eraser
                let s = tool.smoothingStrength
                smoother.smoothingAlpha = s > 0 ? 1.0 - s * 0.85 : 1.0
            } else {
                activeToolIsEraser = false
                lastEraserMode = false
                let exitPoint = smoother.smoothedPoint
                if lastTipDown {
                    postMouseUp(
                        button: activeButton, at: exitPoint,
                        clickCount: activeClickCount,
                        snapshot: snap)
                    lastTipDown = false
                }
                // Release any USB HID mouse buttons that were held when the tool left
                // the tablet (e.g. user yanked the KC-100 off the surface mid-drag).
                if lastUSBMouseMask != 0 {
                    if usbMouseLeftHeld {
                        postMouseUp(
                            button: .left, at: exitPoint,
                            clickCount: activeClickCount,
                            snapshot: snap)
                        usbMouseLeftHeld = false
                    }
                    if (lastUSBMouseMask & 0x02) != 0 {
                        postMouseUp(
                            button: .right, at: exitPoint, clickCount: 1,
                            snapshot: snap)
                    }
                    if (lastUSBMouseMask & 0x04) != 0 {
                        if let e = CGEvent(
                            mouseEventSource: sessionSource, mouseType: .otherMouseUp,
                            mouseCursorPosition: exitPoint, mouseButton: .center)
                        {
                            e.flags = currentEventFlags
                            finalizeAndPost(e)
                        }
                    }
                    lastUSBMouseMask = 0
                }
                if lastMiddleDown {
                    if let e = CGEvent(
                        mouseEventSource: sessionSource, mouseType: .otherMouseUp,
                        mouseCursorPosition: exitPoint, mouseButton: .center)
                    {
                        e.flags = currentEventFlags
                        finalizeAndPost(e)
                    }
                    lastMiddleDown = false
                }
                // Safety valve: release any modifier keys stranded by a missed decoder
                // release event (e.g. BT packet drop leaving lastBTPadKeys non-zero).
                // Per-transport fixes (Defect A/B) prevent accumulation; this ensures
                // proximity exit is always a clean slate regardless.
                releaseAllSyntheticModifiers()

                // Do NOT post proximity-exit flagsChanged events for physical modifiers.
                // flagsChanged events posted via cghidEventTap update the system keyboard
                // state (Keyboard Viewer, hidSystemState), so posting one with a modifier
                // bit SET because tapLastPhysicalFlags still reflects a held key causes the
                // Keyboard Viewer to show it as stuck.  The physical keyboard's own
                // flagsChanged events are the authoritative source for physical modifier
                // state; apps receive them independently of our event stream.
                // The race this sync tried to fix (our last move event arriving after the
                // physical key-up, leaving apps with stale modifier state) is now handled
                // by moveSafeEventFlags including tapLastPhysicalFlags, so the last move
                // event already carries the correct physical state.
                lastLoggedManagedFlags = 0  // reset for clean logging on next proximity entry

                // Reset aux state so the next injectAux fires fresh transitions.
                pendingMouseUp?.cancel()
                pendingMouseUp = nil
                hoverDragButton = nil
                lastAuxButtons = [Bool](repeating: false, count: 16)
                lastRingButtonDown = false
                hasPostedPoint = false
                lastRelativeNorm = nil
                lastPostedPressure = -1.0
                smoother.resetOnProximityExit()
            }
            // Record the moment the pen leaves proximity so finger-touch can
            // apply a short grace window (touchArbitrationGrace) before
            // accepting contacts again — prevents the palm rejection failure
            // pattern where lifting the pen drops a stray finger on the
            // tablet and the touch path races the pen-up.
            if lastProximity && !point.inProximity {
                penProximityExitTime = CFAbsoluteTimeGetCurrent()
            }
            lastProximity = point.inProximity
        }

        // ── Eraser/tip flip (while in proximity) ───────────────────────────────
        if eraserFlipped {
            // Pen was flipped between tip and eraser while in proximity.
            // Post synthetic proximity exit/enter so apps re-register the tool identity.
            // This ensures distinct pointerType (1=pen, 3=eraser) and serial registration.
            postProximityEvent(entering: false, at: rawPoint, eraser: !point.eraser)
            activeToolIsEraser = point.eraser
            lastEraserMode = point.eraser
            postProximityEvent(entering: true, at: rawPoint, eraser: point.eraser)
        }

        guard point.inProximity else { return }

        // ── Position smoothing (every report) ─────────────────────────────────
        let screenPoint = smoother.applySmoothing(
            rawPoint: rawPoint, enteringProximity: enteringProximity)
        shimLastPoint = point
        shimLastScreen = screenPoint
        shimLastPressure = pressure

        // ── Jitter tracking (hover only, every report) ─────────────────────────
        if !tipDown {
            smoother.observeHoverRaw(rawPoint)
        } else {
            smoother.endHover()
        }

        // ── Tip press transitions (always immediate) ───────────────────────────
        if tipDown != lastTipDown {
            if !activeToolIsMouse && activeAppNeedsTabletPointerEvents {
                postTabletPointerEvent(
                    at: screenPoint, pressure: pressure, point: point, snapshot: snap)
            }
            if tipDown {
                // Cancel any pending deferred mouseUp — tip is back down.
                pendingMouseUp?.cancel()
                pendingMouseUp = nil
                didEmitDragSinceDown = false
                let tipAction = activeToolIsEraser ? tool.eraserBinding : tool.tipBinding
                activeButton = tipAction.mouseButton ?? .left
                let (clickPt, count) = resolveClick(screenPoint, snapshot: snap)
                activeClickCount = count
                postMouseDown(
                    button: activeButton, at: clickPt,
                    pressure: pressure, clickCount: count,
                    point: point,
                    snapshot: snap)
            } else {
                let btn = activeButton
                let count = activeClickCount
                let pt = point

                if activeAppProfile == .generic
                    && snap.tipUpAssist
                    && smoother.recentVelocity > Self.tipUpAssistVelocityThreshold {
                    // Defer the mouseUp briefly so fast strokes aren't cut short.
                    // The deferred mouseUp captures `snap` so it has all the values it
                    // needs; the live snapshot may have rolled over by the time it fires.
                    let capturedSnap = snap
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.pendingMouseUp != nil else { return }
                        self.pendingMouseUp = nil
                        // Fire at lastPostedPoint, not at the tip-lift position.
                        // By the time this fires (~80ms after physical tip-lift),
                        // mouseMoved events have advanced lastPostedPoint to wherever
                        // the pen currently is.  Firing at the original lift-off would
                        // warp the cursor back, then snap forward on the next inject(),
                        // creating a visible cursor zap and spurious drag.  For drawing
                        // strokes the pen travels only a few pixels in 80ms, so
                        // stroke-end fidelity is effectively unchanged.
                        // Hop to HIDThread to keep all per-report state on its owning
                        // run loop — this handler is scheduled via DispatchQueue.main
                        // to honor the 80ms delay using the existing run-loop timer
                        // semantics, but the state mutations belong to HIDThread.
                        CFRunLoopPerformBlock(
                            HIDThread.shared.runLoop,
                            CFRunLoopMode.commonModes.rawValue
                        ) {
                            self.postMouseUp(
                                button: btn, at: self.lastPostedPoint, clickCount: count,
                                point: pt, snapshot: capturedSnap)
                        }
                        CFRunLoopWakeUp(HIDThread.shared.runLoop)
                    }
                    pendingMouseUp = work
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + Self.tipUpAssistDelay, execute: work)
                } else {
                    postMouseUp(
                        button: activeButton, at: screenPoint,
                        clickCount: activeClickCount, point: point,
                        snapshot: snap)
                }
            }
            lastPostedPoint = screenPoint
            lastPostedPressure = pressure
            hasPostedPoint = true

        } else {
            // ── Continuous movement: delta gate ────────────────────────────────
            let moved =
                !hasPostedPoint
                || (screenPoint.x - lastPostedPoint.x).magnitude > Self.positionEpsilon
                || (screenPoint.y - lastPostedPoint.y).magnitude > Self.positionEpsilon
                || (tipDown && (pressure - lastPostedPressure).magnitude > Self.pressureEpsilon)

            // USB mouse left button held (KC-100): injectMouseButtons() already sent
            // leftMouseDown; use leftMouseDragged so apps receive proper drag events.
            let dragging = tipDown || (activeToolIsMouse && usbMouseLeftHeld)

            // Pages text engine requires a leftMouseDragged immediately after
            // leftMouseDown to start selection; tiny sub-epsilon pen movement on
            // the first contact frame can cause the gate to suppress that first drag
            // event, leaving Pages in a state where selection never begins.
            let forceFirstDrag = dragging && activeAppProfile == .pagesPlainMouse && !didEmitDragSinceDown

            if moved || forceFirstDrag {
                // Track velocity for tip-up assist.
                if hasPostedPoint {
                    let delta = hypot(
                        screenPoint.x - lastPostedPoint.x,
                        screenPoint.y - lastPostedPoint.y)
                    smoother.recordMoveDelta(delta)
                }
                if !activeToolIsMouse && activeAppNeedsTabletPointerEvents {
                    postTabletPointerEvent(
                        at: screenPoint, pressure: pressure, point: point, snapshot: snap)
                }
                if dragging {
                    postMouseDrag(
                        button: activeButton, at: screenPoint, pressure: pressure, point: point,
                        snapshot: snap)
                    didEmitDragSinceDown = true
                } else if let dragBtn = hoverDragButton {
                    // Barrel button held while hovering — send otherMouseDragged /
                    // rightMouseDragged so apps like SketchUp receive a proper drag stream.
                    postMouseDrag(
                        button: dragBtn, at: screenPoint, pressure: 0, point: point,
                        snapshot: snap)
                } else {
                    postMouseMoved(
                        at: screenPoint, point: point,
                        snapshot: snap)
                }
                lastPostedPoint = screenPoint
                lastPostedPressure = pressure
                hasPostedPoint = true
            }
        }
        lastTipDown = tipDown

        // ── Pen button transitions (always immediate) ──────────────────────────
        let btn1 = tool.penButton1Binding
        let btn2 = tool.penButton2Binding

        if point.penButton1 != lastButton1Down {
            // Update tracking state first so the quiescent check inside
            // fireButtonAction sees the current button state, not the pre-transition state.
            lastButton1Down = point.penButton1
            // For mouse tools button1 drives the primary click (tipDown above);
            // dispatching it again as a button action would double-fire.
            if !activeToolIsMouse {
                fireButtonAction(btn1, down: point.penButton1, at: screenPoint,
                                 snapshot: snap, settings: settings)
            }
        }
        if point.penButton2 != lastButton2Down {
            lastButton2Down = point.penButton2
            fireButtonAction(btn2, down: point.penButton2, at: screenPoint,
                             snapshot: snap, settings: settings)
        }

        // ── Middle button (mouse tool only, always immediate) ──────────────────
        if point.mouseMiddleButton != lastMiddleDown {
            let type: CGEventType = point.mouseMiddleButton ? .otherMouseDown : .otherMouseUp
            if let e = CGEvent(
                mouseEventSource: sessionSource, mouseType: type,
                mouseCursorPosition: screenPoint, mouseButton: .center)
            {
                e.flags = currentEventFlags
                finalizeAndPost(e)
            }
            lastMiddleDown = point.mouseMiddleButton
        }

        // ── Scroll wheel (mouse tool only, always immediate) ───────────────────
        if point.mouseWheelDelta != 0 {
            postScrollWheelEvent(delta: point.mouseWheelDelta, at: screenPoint)
        }
    }

    // MARK: - Adobe shim replay

    /// Re-emits the last tablet pointer event.
    /// Called by TabletManager when WacomShim receives an eSendTabletEvent(eEventPointer)
    /// Apple Event from Adobe Photoshop / Illustrator.
    func replayPointerEvent(settings: TabletSettings? = nil) {
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

    // MARK: - Express key injection

    /// Ring/strip rotations are discrete pulses, not holds. Pairing down+up in a
    /// single call prevents modifier bits in the binding from leaking into
    /// `groundTruthSyntheticFlags` across rotation samples.
    private func fireKeyTap(_ binding: ButtonBinding,
                            at loc: CGPoint,
                            snapshot: InjectionSnapshot,
                            settings: TabletSettings?) {
        fireButtonAction(binding, down: true, at: loc, snapshot: snapshot, settings: settings)
        fireButtonAction(binding, down: false, at: loc, snapshot: snapshot, settings: settings)
    }

    func injectAux(buttons: AuxButtons, settings: TabletSettings?) {
        rearmWatchdog()
        guard let snap = injectionSnapshot else { return }
        let bindings = snap.expressKeyBindings
        let cursorPos = currentCursorPosition()

        // ── Express keys ───────────────────────────────────────────────────────
        for i in 0..<16 {
            let down = buttons[i]
            let hasMechanicalPulse = i < 8 && (buttons.mechanicalMask >> i) & 1 != 0
            if down != lastAuxButtons[i] {
                // Update tracking state first so the quiescent check inside
                // fireButtonAction sees the current button state, not the pre-transition state.
                lastAuxButtons[i] = down
                fireButtonAction(bindings[i], down: down, at: cursorPos,
                                 snapshot: snap, settings: settings)
            } else if down && hasMechanicalPulse {
                // Button is already tracked as down, but a new mechanical pulse arrived —
                // the user re-pressed before the release event was seen. Force a complete
                // up→down cycle so the key fires correctly without getting swallowed.
                fireButtonAction(bindings[i], down: false, at: cursorPos,
                                 snapshot: snap, settings: settings)
                fireButtonAction(bindings[i], down: true, at: cursorPos,
                                 snapshot: snap, settings: settings)
                // lastAuxButtons[i] stays true — the button is still down after this cycle
            }
        }

        // ── Touch ring center button ───────────────────────────────────────────
        let ringButtonDown = buttons.touchRingButtonDown
        if ringButtonDown != lastRingButtonDown {
            lastRingButtonDown = ringButtonDown
            fireButtonAction(snap.touchRingButtonBinding, down: ringButtonDown,
                             at: cursorPos, snapshot: snap, settings: settings)
        }

        // ── Touch ring ─────────────────────────────────────────────────────────
        // Position 0x7F means no contact.  Compute a wrap-aware delta when a
        // finger is actively moving (both current and previous positions valid).
        // The ring has 72 steps (0–71, ~5° each); wrap threshold is 36.
        let activeSlot: ControlSlot? = snap.touchRingSlots.indices.contains(snap.touchRingActiveSlotIndex)
            ? snap.touchRingSlots[snap.touchRingActiveSlotIndex] : nil

        let ringPos = buttons.touchRingPosition
        if buttons.touchRingActive, lastRingPos != 0x7F {
            var delta = Int(ringPos) - Int(lastRingPos)
            if delta > 36 { delta -= 72 }
            if delta < -36 { delta += 72 }
            if delta != 0, let slot = activeSlot {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &ringAccum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            }
        }
        if !buttons.touchRingActive { ringAccum = 0 }
        lastRingPos = buttons.touchRingActive ? ringPos : 0x7F

        // ── Touch ring 2 (DTK-2400 right bezel) — shares touchRingSlots ──
        let ring2Pos = buttons.touchRing2Position
        if buttons.touchRing2Active, lastRing2Pos != 0x7F {
            var delta = Int(ring2Pos) - Int(lastRing2Pos)
            if delta > 36 { delta -= 72 }
            if delta < -36 { delta += 72 }
            if delta != 0, let slot = activeSlot {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &ring2Accum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            }
        }
        if !buttons.touchRing2Active { ring2Accum = 0 }
        lastRing2Pos = buttons.touchRing2Active ? ring2Pos : 0x7F

        // ── Touch strips (Intuos3 WS) — share touchRingSlots ───────────────────
        // Strips are linear (no wrap); each zone step maps 1:1 to a scroll event.

        // Strip 1 (left).
        let s1pos = buttons.touchStrip1Position
        if buttons.touchStrip1Active, lastStrip1Pos != 0xFF {
            let delta = Int(s1pos) - Int(lastStrip1Pos)
            if delta != 0, let slot = activeSlot {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &strip1Accum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            }
        }
        if !buttons.touchStrip1Active { strip1Accum = 0 }
        lastStrip1Pos = buttons.touchStrip1Active ? s1pos : 0xFF

        // Strip 2 (right).
        let s2pos = buttons.touchStrip2Position
        if buttons.touchStrip2Active, lastStrip2Pos != 0xFF {
            let delta = Int(s2pos) - Int(lastStrip2Pos)
            if delta != 0, let slot = activeSlot {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &strip2Accum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            }
        }
        if !buttons.touchStrip2Active { strip2Accum = 0 }
        lastStrip2Pos = buttons.touchStrip2Active ? s2pos : 0xFF
    }

    // MARK: - Relative wheel (IntuosV3 PTK-x70 side scroll wheels)

    /// Called on HIDThread for each non-zero wheel step from a device with
    /// physical rotary encoders (e.g. PTK-470/670/870).  Routes through
    /// `touchRingSlots[index]` so the user can configure scroll vs. key-press
    /// behaviour through the ring settings UI.  Falls back to a direct scroll
    /// event if no slot is defined for that index.
    // MARK: - Finger-touch injection

    /// Mutable per-sequence state for capacitive touch.  HIDThread-owned.
    private var touchTracker = TouchStateTracker()
    /// CFAbsoluteTime when the pen last left proximity.  Touch is suppressed
    /// while the pen is in proximity and for a brief grace window after exit
    /// so palm-rejection bounces (finger contact arriving 1–2 frames after
    /// pen-up) don't slip through as cursor jumps.
    private var penProximityExitTime: CFAbsoluteTime = 0
    /// Per-Wacom-driver convention; tunable if reports show false positives.
    private static let touchArbitrationGrace: CFAbsoluteTime = 0.08

    /// Inject a touch contact frame.
    ///
    /// Behaviour:
    ///   • `touchEnabled == false` → no-op.
    ///   • Pen in proximity, or pen lifted within `touchArbitrationGrace`
    ///     → drop the frame (and reset tracker so a stale gesture mid-touch
    ///     doesn't persist when the pen interrupts).
    ///   • Otherwise project each contact through the user's touch-area
    ///     mapping into screen-space, hand to `TouchStateTracker`, and
    ///     translate its `Intent` into CGEvents:
    ///       - `.pointerMove` → `mouseMoved`
    ///       - `.scrollDelta` → smooth scroll-wheel event with phase
    ///       - `.tapClick`    → left-click at the current cursor position
    ///
    /// No shipping decoder produces touch frames yet; this is hot-path
    /// plumbing for when a per-family touch decoder lands.
    func injectTouch(contacts: [TouchContact], settings: TabletSettings?) {
        rearmWatchdog()
        guard let snap = injectionSnapshot, snap.touchEnabled else { return }

        // Pen arbitration: pen takes priority.  Drop frames and reset tracker
        // so a half-formed gesture doesn't resume after the pen lifts.
        let now = CFAbsoluteTimeGetCurrent()
        if lastProximity || now - penProximityExitTime < Self.touchArbitrationGrace {
            if !contacts.isEmpty {
                _ = touchTracker.process(
                    contacts: [], tapToClick: false, twoFingerScroll: false,
                    reverseScrollDirection: false, sensitivity: 1.0, now: now)
            }
            return
        }

        // Resolve display bounds — touch shares the pen's target display.
        let idx = snap.targetDisplayIndex
        if cachedDisplayIndex != idx {
            let (bounds, displayID) = resolveDisplayBoundsAndID(snapshot: snap)
            cachedDisplayBounds = bounds
            cachedDisplayUUID = CalibrationKey.uuidString(for: displayID)
            cachedDisplayIndex = idx
            cachedCalibrationOrientation = -1
        }
        let displayBounds = cachedDisplayBounds

        // Cache touch coordinate maximums per device.  Without this, the
        // registry lookup (linear scan over ~80 specs) ran on every HID
        // frame — at 100 Hz with a palm on the tablet, that alone was a
        // measurable CPU contributor.
        if cachedTouchSpecPID != deviceProductID {
            let spec = WacomDeviceRegistry.spec(for: deviceProductID)
            cachedTouchMaxX = Swift.max(1, spec?.touchMaxX ?? 1)
            cachedTouchMaxY = Swift.max(1, spec?.touchMaxY ?? 1)
            cachedTouchSpecPID = deviceProductID
        }

        // Project each contact to screen-space using the touch-area mapping.
        // Contacts whose raw position falls outside the crop rect return nil
        // and are dropped entirely (no clamping to the rect edge — that would
        // leave the deadzone partially responsive).
        var projected: [(id: Int, screen: CGPoint)] = []
        projected.reserveCapacity(contacts.count)
        for c in contacts {
            guard let p = TouchStateTracker.screenPoint(
                for: c, maxX: cachedTouchMaxX, maxY: cachedTouchMaxY,
                areaX: snap.touchAreaX, areaY: snap.touchAreaY,
                areaWidth: snap.touchAreaWidth, areaHeight: snap.touchAreaHeight,
                displayBounds: displayBounds)
            else { continue }
            projected.append((id: c.id, screen: p))
        }

        let intent = touchTracker.process(
            contacts: projected,
            tapToClick: snap.tapToClick,
            twoFingerScroll: snap.twoFingerScroll,
            reverseScrollDirection: snap.reverseScrollDirection,
            sensitivity: snap.touchSensitivity,
            now: now)

        switch intent {
        case .none:
            return
        case .pointerMove(let dx, let dy):
            postTouchPointerMove(dx: dx, dy: dy)
        case .scrollDelta(let dx, let dy, let phase):
            postTouchScroll(dx: dx, dy: dy, phase: phase)
        case .tapClick:
            postTouchTapClick(snapshot: snap, settings: settings)
        }
    }

    private func postTouchPointerMove(dx: Double, dy: Double) {
        let loc = currentCursorPosition()
        let target = CGPoint(x: loc.x + dx, y: loc.y + dy)
        guard let e = CGEvent(
            mouseEventSource: sessionSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: target,
            mouseButton: .left)
        else { return }
        e.flags = moveSafeEventFlags
        finalizeAndPost(e)
    }

    private func postTouchScroll(dx: Double, dy: Double, phase: TouchStateTracker.ScrollPhase) {
        let loc = currentCursorPosition()
        // .pixel units + the scroll-phase field is what makes apps treat the
        // stream as a trackpad scroll (smooth, with rubber-banding) rather
        // than a discrete wheel-tick scroll.
        guard let e = CGEvent(
            scrollWheelEvent2Source: sessionSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(dy.rounded()),
            wheel2: Int32(dx.rounded()),
            wheel3: 0)
        else { return }
        e.location = loc
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        e.flags = moveSafeEventFlags
        finalizeAndPost(e)
    }

    private func postTouchTapClick(snapshot: InjectionSnapshot, settings: TabletSettings?) {
        let loc = currentCursorPosition()
        let (clickPt, count) = resolveClick(loc, snapshot: snapshot)
        postMouseDown(
            button: .left, at: clickPt, pressure: 1.0, clickCount: count, snapshot: snapshot)
        postMouseUp(button: .left, at: clickPt, clickCount: count, snapshot: snapshot)
    }

    func injectWheel(index: Int, delta: Int, settings: TabletSettings?) {
        rearmWatchdog()
        guard let snap = injectionSnapshot else { return }
        let cursorPos = currentCursorPosition()
        let slot: ControlSlot? = snap.touchRingSlots.indices.contains(index)
            ? snap.touchRingSlots[index] : nil
        if let slot {
            if index == 0 {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &wheel0Accum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            } else {
                dispatchRingDelta(rawDelta: delta, slot: slot, accum: &wheel1Accum,
                                  at: cursorPos, snapshot: snap, settings: settings)
            }
        } else {
            postScrollWheelEvent(delta: delta, at: cursorPos)
        }
    }

    private func currentCursorPosition() -> CGPoint {
        let loc = NSEvent.mouseLocation
        let screenH = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        return CGPoint(x: loc.x, y: screenH - loc.y)
    }

    // MARK: - Click resolution

    private func resolveClick(
        _ candidate: CGPoint,
        snapshot: InjectionSnapshot
    ) -> (CGPoint, Int) {
        let now = CFAbsoluteTimeGetCurrent()
        let dist = hypot(
            candidate.x - lastClickPosition.x,
            candidate.y - lastClickPosition.y)

        let snapThreshold = snapshot.doubleClickDistance
        let countThreshold = snapThreshold > 0 ? snapThreshold : 8.0
        let withinTime = now - lastClickTime < NSEvent.doubleClickInterval
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
    private var lastLoggedManagedFlags: UInt64 = 0

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
    private var currentEventFlags: CGEventFlags {
        let result = CGEventFlags(rawValue: ModifierMath.currentEventFlags(
            systemFlags: CGEventSource.flagsState(.hidSystemState).rawValue,
            tapPhysicalManaged: tapLastPhysicalFlags,
            syntheticFlags: groundTruthSyntheticFlags.rawValue))
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
    private var moveSafeEventFlags: CGEventFlags {
        CGEventFlags(rawValue:
            (tapLastPhysicalFlags & ModifierMath.managedMask)
            | groundTruthSyntheticFlags.rawValue)
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

    /// Releases any synthetic modifier keys currently held by tablet button bindings.
    /// Posts one `.flagsChanged` event per held modifier bit, then clears all state.
    /// Safe to call when `groundTruthSyntheticFlags` is already empty (no-op).
    private func releaseAllSyntheticModifiers() {
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
    private func finalizeAndPost(_ event: CGEvent) {
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
    private let sessionSource: CGEventSource? = CGEventSource(stateID: .privateState)

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

    private func postMouseDown(
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

    private func postMouseUp(
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

    private func postMouseDrag(
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

    private func postMouseMoved(
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

    private func postTabletPointerEvent(
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

    private func postProximityEvent(
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
    private func fireButtonAction(
        _ binding: ButtonBinding, down: Bool,
        at location: CGPoint,
        snapshot: InjectionSnapshot,
        settings: TabletSettings? = nil
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
            let event: CGEvent?
            if binding.keyLabel.isEmpty && binding.modifierFlags != 0 {
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

            // Event created successfully — now commit the state delta.
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
            e.flags = currentEventFlags
            finalizeAndPost(e)

        case .displayToggle:
            guard down else { break }
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
                    let nextIndex = (s.touchRingActiveSlotIndex + 1) % max(1, s.touchRingSlots.count)
                    s.touchRingActiveSlotIndex = nextIndex
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
    private func dispatchRingDelta(
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
        case .off:
            break
        }
    }

    private func postScrollWheelEvent(delta: Int, at location: CGPoint) {
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

    /// In relative mode: computes a delta from the previous normalized tablet position
    /// and applies it to the current cursor location.
    ///
    /// Display mapping is intentionally ignored — it makes no sense for mouse-like input.
    /// Deltas are scaled by the total virtual screen space (union of all displays), so a
    /// full active-area sweep traverses the entire available screen real estate.  The
    /// cursor is clamped to the same total bounds so it can reach any display.
    ///
    /// Active-area crop is still respected: a smaller crop = higher sensitivity.
    private func resolveRelativePoint(_ point: TabletPoint, snapshot: InjectionSnapshot) -> CGPoint {
        // Virtual screen bounds (union of all displays in CG coordinates) are cached
        // on main and refreshed via didChangeScreenParametersNotification — see
        // recomputeVirtualScreenBounds(). NSScreen.screens is AppKit and must not be
        // touched on the HID thread.
        let virtualBounds = cachedVirtualScreenBounds
        let screen =
            virtualBounds.isEmpty
            ? CGRect(
                x: 0, y: 0,
                width: CGFloat(CGDisplayPixelsWide(CGMainDisplayID())),
                height: CGFloat(CGDisplayPixelsHigh(CGMainDisplayID())))
            : virtualBounds

        // Compute normalized position within the active area (same orientation math
        // as mapToScreen; active-area crop controls sensitivity).
        let rawX = Double(point.x)
        let rawY = Double(point.y)
        let rawMaxX = Double(point.maxX)
        let rawMaxY = Double(point.maxY)
        let ox: Double
        let oy: Double
        let effMaxX: Double
        let effMaxY: Double
        let orientation = snapshot.tabletOrientation
        switch orientation {
        case .landscape:
            ox = rawX
            oy = rawY
            effMaxX = rawMaxX
            effMaxY = rawMaxY
        case .portrait:
            ox = rawY
            oy = rawMaxX - rawX
            effMaxX = rawMaxY
            effMaxY = rawMaxX
        case .landscapeFlipped:
            ox = rawMaxX - rawX
            oy = rawMaxY - rawY
            effMaxX = rawMaxX
            effMaxY = rawMaxY
        case .portraitFlipped:
            ox = rawMaxY - rawY
            oy = rawX
            effMaxX = rawMaxY
            effMaxY = rawMaxX
        }
        let areaW = Swift.max(snapshot.activeAreaWidth, 0.001) * effMaxX
        let areaH = Swift.max(snapshot.activeAreaHeight, 0.001) * effMaxY
        let norm = CGPoint(
            x: (ox - snapshot.activeAreaX * effMaxX) / areaW,
            y: (oy - snapshot.activeAreaY * effMaxY) / areaH)

        // First report after proximity entry: anchor without moving.
        guard let prev = lastRelativeNorm else {
            lastRelativeNorm = norm
            return currentCursorPosition()
        }
        lastRelativeNorm = norm

        let dx = (norm.x - prev.x) * screen.width
        let dy = (norm.y - prev.y) * screen.height
        let cur = currentCursorPosition()
        return CGPoint(
            x: Swift.min(Swift.max(cur.x + dx, screen.minX), screen.maxX),
            y: Swift.min(Swift.max(cur.y + dy, screen.minY), screen.maxY))
    }

    /// Maps a tablet point to screen coordinates, accounting for orientation and active area cropping.
    /// Returns nil if the pen is outside the active area (deadzone).
    private func mapToScreen(_ point: TabletPoint, snapshot: InjectionSnapshot) -> CGPoint? {
        let idx = snapshot.targetDisplayIndex
        if cachedDisplayIndex != idx {
            let (bounds, displayID) = resolveDisplayBoundsAndID(snapshot: snapshot)
            cachedDisplayBounds = bounds
            cachedDisplayUUID = CalibrationKey.uuidString(for: displayID)
            cachedDisplayIndex = idx
            // Invalidate calibration cache when display changes.
            cachedCalibrationOrientation = -1
        }
        let displayBounds = cachedDisplayBounds

        // Apply orientation transform before the active-area crop.
        // The active-area fractions are defined in oriented (post-rotation) space,
        // so we transform raw hardware coordinates first, then apply the crop.
        let rawX = Double(point.x)
        let rawY = Double(point.y)
        let rawMaxX = Double(point.maxX)
        let rawMaxY = Double(point.maxY)

        let ox: Double  // oriented x
        let oy: Double  // oriented y
        let effMaxX: Double  // range of oriented x axis
        let effMaxY: Double  // range of oriented y axis

        let orientation = snapshot.tabletOrientation
        switch orientation {
        case .landscape:
            ox = rawX
            oy = rawY
            effMaxX = rawMaxX
            effMaxY = rawMaxY
        case .portrait:  // 90° CW — USB port moves to left
            ox = rawY
            oy = rawMaxX - rawX
            effMaxX = rawMaxY
            effMaxY = rawMaxX
        case .landscapeFlipped:  // 180° — USB port at top
            ox = rawMaxX - rawX
            oy = rawMaxY - rawY
            effMaxX = rawMaxX
            effMaxY = rawMaxY
        case .portraitFlipped:  // 90° CCW — USB port moves to right
            ox = rawMaxY - rawY
            oy = rawX
            effMaxX = rawMaxY
            effMaxY = rawMaxX
        }

        var areaX = snapshot.activeAreaX * effMaxX
        var areaY = snapshot.activeAreaY * effMaxY
        var areaW = Swift.max(snapshot.activeAreaWidth, 0.001) * effMaxX
        var areaH = Swift.max(snapshot.activeAreaHeight, 0.001) * effMaxY

        if snapshot.proportionalMapping {
            let tabletAspect = areaW / areaH
            let displayAspect = Double(displayBounds.width) / Double(displayBounds.height)
            if tabletAspect > displayAspect {
                let effectiveW = areaH * displayAspect
                areaX += (areaW - effectiveW) / 2
                areaW = effectiveW
            } else if tabletAspect < displayAspect {
                let effectiveH = areaW / displayAspect
                areaY += (areaH - effectiveH) / 2
                areaH = effectiveH
            }
        }

        let relX = (ox - areaX) / areaW
        let relY = (oy - areaY) / areaH

        // Outside active area — deadzone
        guard relX >= 0, relX <= 1, relY >= 0, relY <= 1 else { return nil }

        // Apply multi-point calibration transform in normalized space (if available).
        var calX = relX, calY = relY
        let orientRaw = orientation.rawValue
        if cachedCalibrationOrientation != orientRaw {
            cachedCalibration = snapshot.calibration(for: orientation,
                                                     displayUUID: cachedDisplayUUID)
            cachedCalibrationOrientation = orientRaw
        }
        if let cal = cachedCalibration {
            (calX, calY) = cal.apply(to: (relX, relY))
        }

        var sx = displayBounds.minX + calX * displayBounds.width
        var sy = displayBounds.minY + calY * displayBounds.height

        // Additive fine-tune offset (points, user-configured) — stacks on top of calibration.
        sx += snapshot.parallaxOffsetX
        sy += snapshot.parallaxOffsetY

        sx = Swift.min(Swift.max(sx, displayBounds.minX), displayBounds.maxX)
        sy = Swift.min(Swift.max(sy, displayBounds.minY), displayBounds.maxY)
        return CGPoint(x: sx, y: sy)
    }

    /// Queries the OS display list and returns the target display's bounds and ID.
    /// Only called on cache miss; results stored in cachedDisplayBounds/cachedDisplayUUID.
    private func resolveDisplayBoundsAndID(snapshot: InjectionSnapshot) -> (CGRect, CGDirectDisplayID) {
        let mainID = CGMainDisplayID()
        let fallback = CGRect(
            x: 0, y: 0,
            width: CGFloat(CGDisplayPixelsWide(mainID)),
            height: CGFloat(CGDisplayPixelsHigh(mainID))
        )
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            injectLog.error("displayUnion: CGGetActiveDisplayList(count) failed or zero displays — falling back to main display")
            return (fallback, mainID)
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            injectLog.error("displayUnion: CGGetActiveDisplayList(ids) failed — falling back to main display")
            return (fallback, mainID)
        }
        let idx = snapshot.targetDisplayIndex
        if idx == TabletSettings.displayModeAll {
            // Union bounding rect spanning every active display — no single display ID.
            return (ids.map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }, 0)
        }
        if idx == TabletSettings.displayModeToggle {
            let rotation = toggleRotation(snapshot: snapshot, allIDs: ids)
            guard !rotation.isEmpty else { return (CGDisplayBounds(mainID), mainID) }
            let toggleID = rotation[currentToggleIndex % rotation.count]
            return (CGDisplayBounds(toggleID), toggleID)
        }
        if idx > 0, idx <= ids.count {
            let targetID = ids[idx - 1]
            return (CGDisplayBounds(targetID), targetID)
        }
        return (CGDisplayBounds(mainID), mainID)
    }

    /// Returns the ordered list of display IDs in the toggle rotation,
    /// filtered by the IDs stored in settings (empty = all included).
    private func toggleRotation(
        snapshot: InjectionSnapshot,
        allIDs: [CGDirectDisplayID]
    ) -> [CGDirectDisplayID] {
        let stored = snapshot.toggleDisplayIDs
        if stored.isEmpty { return allIDs }
        return allIDs.filter { stored.contains($0) }
    }

    /// Advances the toggle rotation to the next display in the sequence.
    /// No-op when fewer than two displays are in the rotation.
    /// Called from fireButtonAction (HIDThread) when a `.displayToggle` binding fires.
    func cycleToggleDisplay(snapshot: InjectionSnapshot) {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return }
        let rotation = toggleRotation(snapshot: snapshot, allIDs: ids)
        guard rotation.count > 1 else { return }
        currentToggleIndex = (currentToggleIndex + 1) % rotation.count
        cachedDisplayIndex = Int.min  // force cache miss on next inject
        cachedCalibrationOrientation = -1
    }

    /// Force re-read of calibration data on next inject.
    /// Call after calibration data is stored or cleared. Hops to HIDThread because
    /// `cachedCalibrationOrientation` is owned there.
    func invalidateCalibrationCache() {
        CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.cachedCalibrationOrientation = -1
        }
        CFRunLoopWakeUp(HIDThread.shared.runLoop)
    }

    /// Recomputes `cachedVirtualScreenBounds` from `NSScreen.screens`.
    /// Must be called on main. Invoked from init and from the
    /// didChangeScreenParametersNotification observer.
    @MainActor
    private func recomputeVirtualScreenBounds() {
        let primaryH = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        let union: CGRect = NSScreen.screens.reduce(CGRect.null) { acc, screen in
            // Convert AppKit frame (bottom-left origin) → CG frame (top-left origin).
            let f = screen.frame
            let cgRect = CGRect(
                x: f.minX, y: primaryH - f.maxY,
                width: f.width, height: f.height)
            return acc.union(cgRect)
        }
        cachedVirtualScreenBounds = union
    }
}
