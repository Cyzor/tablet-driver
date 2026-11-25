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
    nonisolated(unsafe) static let shared = SharedAuxModifierState()  // HIDThread-confined
    private init() {}
    var groundTruthFlags = CGEventFlags()
    var refCounts: [UInt64: Int] = [:]
    var lastChangeAt: TimeInterval = 0
}

/// Routes a Pan View gesture to the injector moving the pointer, since its
/// button can live on another device (a Quick Keys key while the pen pans).
/// A no-op for a pen's own barrel button. HIDThread-confined.
final class SharedPanScrollState {
    nonisolated(unsafe) static let shared = SharedPanScrollState()  // HIDThread-confined
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
/// | `groundTruthSyntheticFlags` | barrel binding posting a modifier | `releaseAllSyntheticModifiers` via proximity exit, 0.4s idle `watchdogTimer`, 1Hz `leakWatchdogTimer`, app switch (`releaseOnAppSwitch`) | Modifier stuck down system-wide |
/// | `heldKeyComboRefCounts` | pen binding posting a plain (non-modifier) `.keyCombo` key | `releaseAllHeldKeyComboKeys` via the same four paths as `groundTruthSyntheticFlags` above | Letter/number key stuck down system-wide until the app quits |
/// | `heldAuxKeyComboRefCounts`, `SharedAuxModifierState` | aux binding posting a key/modifier | matching captured binding release, disconnect, quit; watchdogs when no control is held | Aux shortcut stuck down across devices |
/// | `lastTipDown` | curved pressure ≥ `tipPressureThreshold`, subject to `tipUpDebounceTimer` on release | tip-up in `inject` (debounce-confirmed), proximity exit (incl. the 1Hz watchdog's forced exit — the only release on an unplug with the tip down) | Stroke never ends; button reads held |
/// | `hoverDragButton` | click binding down, or Click Lock | binding up edge, proximity exit, `releaseBindingHeldButton` on tool change/disconnect | Movement posts drags instead of hover |
/// | `clickLocked` | Click Lock press, or a Click Lock tip's first contact | next press or tip contact, proximity exit (`releaseClickLock`), tool change/disconnect | Left button stuck down |
/// | `tipClickSwallowed` | tip contact with the tip set to None, while Click Lock holds, during Pan View, or firing a contact-deferred button | tip lift, proximity exit, next tip contact | Next lift posts no mouseUp |
/// | `touchdownHeld` / `touchdownWithheld` | tip contact with Drag Threshold on | travel past its radius or its hold time passed (replays the samples), tip lift (posts them at the touchdown point, then the release there), no room to hold more, proximity exit, next tip contact | Pointer pinned at the touchdown point; a later contact replays stale samples |
/// | `contactDeferredButtons` / `contactFiredButtons` | Require Contact: barrel button with a checked action pressed while hovering / its tip contact | button release, proximity exit; the fired bits also tip lift and tool change | Button's action held, or a later release posts an up nothing pressed |
/// | `barrelEraserButtons` / `barrelEraserActive` | barrel button set to Eraser pressed / the switch to the eraser it causes | button release (the switch back waits for tip lift), proximity exit | Pen stays the eraser |
/// | `lastMiddleDown`, `lastUSBMouseMask` / `usbMouseLeftHeld` | puck/KC-100 mouse button down | `releaseHeldPointerButtons` — proximity exit and tool change/disconnect | Mouse button stuck down |
/// | `pendingMouseUp` (timer) | tip-up while still moving, tip-up assist enabled | tip re-down (`cancelPendingMouseUp`), proximity exit, deinit | mouseUp never posted — stroke stays open |
/// | `panScroll` (PanScrollTracker) | `.scrollDrag` binding engaged | binding release edge; deliberately **survives** proximity blips (`suspend()`), `cancelPanScrollSafetyNet` + `panScrollSafetyNetTimer` backstop | Pen motion scrolls instead of moving cursor |
/// | `button1/2/3UpDebounceTimer` | Xencelabs barrel-button up edge | reassert within window, timer fire, proximity exit (invalidates + commits), deinit | Release never committed — button reads held |
/// | `tipUpDebounceTimer` | tip-switch up edge, any device, when `smoothingStrength > 0` | reassert within window, timer fire (commits release, feeds `tipUpAssistDelay`), `commitProximityExit`, 1Hz watchdog's forced exit (via `commitProximityExit`), deinit | Release never committed — `lastTipDown` (and drag/stroke-start state derived from it) reads stuck down |
/// | `proximityExitDebounceTimer` | Xencelabs range loss | pen returning in range, timer fire → `commitProximityExit`, deinit | Exit cleanup never runs |
/// | `watchdogTimer` | rearmed on every inject/injectAux/injectMouseButtons | fires after 0.4s idle → releases synthetic flags; deinit | (Safety net; see leak watchdog) |
/// | `leakWatchdogTimer` (1Hz) | `init`, runs continuously | deinit only — by design, it must outlive quiescence | Backstop absent for the rows above |
/// | `lastProximity` | pen in range | proximity exit; 1Hz watchdog forces exit after `stuckProximityTimeout` | Touch gated off as "pen busy" |
/// | `auxButtons` | express key / bezel / ring center down | matching up edge in `injectAux`, disconnect; deliberately survives pen proximity exits | Express-key binding stuck held |
/// | `panMomentumTail`, `touchMomentumTail` | flick release with velocity | decay to zero; new gesture (`stop()` on two-finger landing or Pan View grab, since `.began` waits for motion); tool change, disconnect, proximity exit, app switch, sleep, quit (`stop()` posts a terminal event, for macOS 27's stuck-gesture timer); `cancel()` in deinit | Scrolling continues; on 27+ the app force-cancels it |
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
    /// `TabletSpec.hasMechanicalDial`. Xencelabs isn't in the Wacom
    /// registry, so its Quick Keys dial comes from `VendorDeviceRegistry`.
    let hasMechanicalDial: Bool

    /// Each strip keeps its own modes, as the first and second rotary.
    let stripsHaveOwnModes: Bool

    /// Detents per revolution of this device's mechanical dial; sets how far
    /// one tick rotates or zooms. Per-model: Xencelabs 13, PTK gen-3 24.
    /// Unread without `hasMechanicalDial`.
    let dialStepsPerRevolution: Double

    var activeToolSettings: ToolSettings? = nil {
        didSet { reconcileSyntheticFlags() }
    }
    /// True when the active tool is a cordless mouse. Tip contact follows
    /// penButton1 instead of pressure, and button1 isn't dispatched separately,
    /// since it already fires the primary click.
    var activeToolIsMouse: Bool = false
    /// Cached eraser flag. `TabletManager.onToolEnter` sets it from
    /// `ToolIdentity.isEraser` when the tool code changes, which covers a flip
    /// without a proximity gap. Proximity entry refreshes it from `point.eraser`,
    /// and proximity exit clears it.
    var activeToolIsEraser: Bool = false
    /// Serial number of the active tool, or 0 if unavailable. Proximity events
    /// carry it so apps key per-tool brush memory on the right identity.
    var activeToolSerial: UInt32 = 0
    /// The current tool's code, for proximity events and identification.
    var activeToolCode: UInt16 = 0x0802

    /// True when the frontmost app consumes `.tabletPointer` CGEvents (Qt and
    /// GTK: Krita, GIMP). Otherwise `postTabletPointerEvent` is skipped, saving
    /// a WindowServer round trip per report. HIDThread owns it; main sets it
    /// through `setActiveAppNeedsTabletPointerEvents(_:)`.
    var activeAppNeedsTabletPointerEvents: Bool = false

    /// Hands the frontmost app's need for `.tabletPointer` events to HIDThread,
    /// which reads it on every report.
    func setActiveAppNeedsTabletPointerEvents(_ needs: Bool) {
        HIDThread.shared.perform { [weak self] in self?.activeAppNeedsTabletPointerEvents = needs }
    }

    /// Click bookkeeping for `stampClickSequence`, matching hardware: each press
    /// gets an event number its drags and release share, and the release
    /// repeats the click state, or 0 if the pointer strayed. The number is
    /// process-wide, so a reconnected tablet doesn't restart it.
    nonisolated(unsafe) static var clickEventNumber: Int64 = 0  // HIDThread-confined
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
                if injector.auxButtons.hasHeldControls || injector.lastRingButtonDown
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

    /// Stable per-tablet ID for `tabletEventDeviceID` and proximity events.
    /// A shared constant would make two tablets look like one to apps that
    /// pair pointer and proximity events.
    let tabletDeviceID: Int64
    @MainActor private static var nextTabletDeviceID: Int64 = 1

    @MainActor
    init(vendorID: Int = 0x056A, productID: Int = 0) {
        self.deviceVendorID = vendorID
        self.deviceProductID = productID
        self.tabletDeviceID = Self.nextTabletDeviceID
        Self.nextTabletDeviceID += 1
        self.ringDeltaIsInverted =
            WacomDeviceRegistry.spec(for: productID)?.format == .intuosV1
        self.stripsHaveOwnModes = WacomDeviceRegistry.spec(for: productID)?.hasTouchStrips == true
        if let spec = WacomDeviceRegistry.spec(for: productID) {
            self.hasMechanicalDial = spec.hasMechanicalDial
            self.dialStepsPerRevolution = Self.wacomDialStepsPerRevolution
        } else if let spec = VendorDeviceRegistry.drivableSpec(
            forVendorID: vendorID, productID: productID)
        {
            self.hasMechanicalDial = spec.hasMechanicalDial
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
            HIDThread.shared.perform {
                self.displayMapper.invalidateDisplayCache()
                self.touchPanelNeedsResolve = true
            }
        }
        installLeakWatchdog()
        installFlagsChangedTap()

        // End momentum tails before sleep and at quit: macOS 27 force-cancels a
        // gesture left open, and a tail can't resume after sleep.
        willSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            HIDThread.shared.perform {
                if self.panMomentumTail.isRunning || self.touchMomentumTail.isRunning {
                    TouchPipelineProbe.note { $0.momentumTailsStoppedOnSleep += 1 }
                }
                self.panMomentumTail.stop()
                self.touchMomentumTail.stop()
            }
        }
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            HIDThread.shared.perform {
                if self.panMomentumTail.isRunning || self.touchMomentumTail.isRunning {
                    TouchPipelineProbe.note { $0.momentumTailsStoppedOnTerminate += 1 }
                }
                self.panMomentumTail.stop()
                self.touchMomentumTail.stop()
            }
        }
    }

    deinit {
        if let obs = displayObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = willSleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = willTerminateObserver { NotificationCenter.default.removeObserver(obs) }
        leakWatchdogTimer.map { CFRunLoopTimerInvalidate($0) }
        if let src = flagsChangedTapSource {
            CFRunLoopRemoveSource(HIDThread.shared.runLoop, src, .commonModes)
            flagsChangedTapSource = nil
        }
        flagsChangedTap.map { CFMachPortInvalidate($0) }
        keyDownTapSource.map { CFRunLoopRemoveSource(HIDThread.shared.runLoop, $0, .commonModes) }
        keyDownTap.map { CFMachPortInvalidate($0) }
        watchdogTimer.map { CFRunLoopTimerInvalidate($0) }
        weakSignalExitTimer.map { CFRunLoopTimerInvalidate($0) }
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

    var lastProximity = false {
        didSet { _proximityForMain.withLock { $0 = lastProximity } }
    }
    /// `lastProximity` for main, which reads it on every proximity exit and
    /// shouldn't wait on the pen thread to do so.
    private let _proximityForMain = OSAllocatedUnfairLock<Bool>(initialState: false)
    var proximityForMain: Bool { _proximityForMain.withLock { $0 } }
    var lastTipDown = false
    /// The front app changed mid-stroke, so the pen's proximity still has to
    /// reach it; sent at tip-up.
    var proximityOwedToFrontApp = false
    /// True while the tip is down with its binding set to None: the contact
    /// posted no mouseDown, so it must post no drag or mouseUp either.
    var tipClickSwallowed = false
    /// True while a Click Lock binding holds the left button. Released by the
    /// next press, proximity exit, tool change, or disconnect.
    var clickLocked = false
    /// Screen position at the moment the tip went down. Anchor for Drag
    /// Threshold (`TouchdownGuard`).
    var tipDownOrigin: CGPoint = .zero
    /// `TouchdownGuard` holds this contact's drags; the pointer stays at
    /// `tipDownOrigin` until the pen travels away or the hold time runs out.
    var touchdownHeld = false
    /// A pen sample a held contact hasn't posted yet.
    struct WithheldPenSample {
        var screen: CGPoint
        var pressure: Double
        var point: TabletPoint
        var pose: (tiltX: Double, tiltY: Double, rotation: Double)
        var timestampNs: UInt64
    }
    /// What a held contact withheld while it might still be a tap, oldest
    /// first. Reserved up front, so the pen path never allocates.
    var touchdownWithheld: [WithheldPenSample] = {
        var samples: [WithheldPenSample] = []
        samples.reserveCapacity(InputInjector.touchdownWithheldCapacity)
        return samples
    }()
    /// Room for the hold time at the fastest report rates; a fuller contact
    /// lets go early.
    static let touchdownWithheldCapacity = 64
    /// When the tip touched down.
    var touchdownTime: TimeInterval = 0
    /// Farthest the pen traveled while held, in points, for the capture log.
    var touchdownMaxTravel: Double = 0
    var lastEraserMode = false  // Track eraser/tip flip while in proximity
    // Named fields, not a collection: cheaper at 133 Hz and readable in a debugger.
    var lastButton1Down = false
    var lastButton2Down = false
    var lastButton3Down = false
    /// Require Contact: barrel buttons held with their action deferred until
    /// tip contact. Bit 0 is button 1.
    var contactDeferredButtons: UInt8 = 0
    /// The deferred buttons whose action fired on contact; the tip's lift
    /// releases them.
    var contactFiredButtons: UInt8 = 0
    /// Barrel buttons set to Eraser, held. Bit 0 is button 1.
    var barrelEraserButtons: UInt8 = 0
    /// True while those buttons have the pen announced as its eraser end.
    var barrelEraserActive = false
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
    nonisolated(unsafe) static var currentReportTimestampNs: UInt64 = 0  // HIDThread-confined

    // MARK: - Cursor smoothing, jitter, velocity
    //
    // State and math live in CursorSmoother.swift.

    var smoother = CursorSmoother()

    /// Holds the pen still through sensor noise, in tablet counts, before
    /// mapping. Width from `penDeadBandWidth(snap:)`.
    var positionDeadBand = PositionDeadBand()

    /// Dead band for tablets whose sensors flicker by several counts on every
    /// report, wide enough to hold a resting pen still.
    static func defaultPenDeadBand(productID: Int) -> Int {
        switch productID {
        // Intuos5 and Intuos Pro (2013): PTH-450/650/850, PTK-450/650,
        // PTH-451/651/851.
        case 0x0026...0x002A, 0x0314, 0x0315, 0x0317: return 10
        // Intuos4, wired and wireless.
        case 0x00B8...0x00BD: return 6
        // Intuos3: 6 still flickers now and then.
        case 0x00B0...0x00B7: return 8
        // Intuos 1 and 2.
        case 0x0020...0x0024, 0x0041...0x0047: return 6
        // Cintiq 21UX, 20WSX, and 12WX: Intuos3's generation.
        case 0x003F, 0x00C5, 0x00C6: return 8
        // Later Cintiqs on the Intuos protocol: 21UX2, 22HD, 24HD, Cintiq 22,
        // 27QHD, 13HD, and Companion 2.
        case 0x0057, 0x0059, 0x005B, 0x005D, 0x005E, 0x00CC, 0x00F4, 0x00F6,
            0x00F8...0x00FA, 0x0304, 0x0325, 0x0326, 0x032A...0x032C, 0x0333,
            0x0335:
            return 6
        // PenPartner, Graphire, Volito, and Bamboo through the CTL-672,
        // including Graphire 3 Wireless.
        case 0x0000, 0x0004, 0x0010...0x0019, 0x0060...0x0065, 0x0069...0x006B,
            0x0081, 0x00D0...0x00DF, 0x0300...0x0303, 0x030E, 0x0318, 0x0319,
            0x0323, 0x037A, 0x037B:
            return 5
        // Intuos Pro (2025): PTK-470/670/870 over USB and Bluetooth, and
        // their USB revisions. A hand-held tip flickers about 5 counts.
        case 0x03F5...0x03FA, 0x0401, 0x042D...0x042F: return 6
        default: return 0
        }
    }

    /// The dead band as it stands, for diagnostics: the width the current
    /// settings give, the width last applied to a report, and the product IDs
    /// the default was chosen from. Read on HIDThread.
    struct PenDeadBandReading: Sendable {
        let width: Int
        let lastApplied: Int
        let setting: Int
        let deviceProductID: Int
        let pairedProductID: Int
    }

    var penDeadBandReading: PenDeadBandReading? {
        guard let snap = injectionSnapshot else { return nil }
        return PenDeadBandReading(
            width: penDeadBandWidth(snap: snap), lastApplied: positionDeadBand.width,
            setting: snap.penDeadBand, deviceProductID: deviceProductID,
            pairedProductID: snap.pairedProductID)
    }

    /// The setting, or the tablet's default when unset. A tablet on the wireless
    /// kit is named by the paired product.
    func penDeadBandWidth(snap: InjectionSnapshot) -> Int {
        if snap.penDeadBand >= 0 { return snap.penDeadBand }
        let productID = snap.pairedProductID != 0 ? snap.pairedProductID : deviceProductID
        return Self.defaultPenDeadBand(productID: productID)
    }

    /// Mean hover-position delta over the rolling window (points per sample).
    /// Spikes above ~3 pt/sample while hovering suggest RF interference.
    var jitterLevel: CGFloat { smoother.jitterLevel }
    var isJittery: Bool { smoother.isJittery }

    /// Per-report pressure smoothing (opens up as pressure rises toward a
    /// firm stroke, unlike the position filter above which opens up with
    /// speed). State and math live in PressureSmoother.swift.
    var pressureSmoother = PressureSmoother()

    /// Timestamp of the previous pen frame, for the smoothers' real `dt`.
    /// Separate from `lastPanScrollFrameTime`, which advances only during a
    /// scroll drag. 0 means unknown, and that frame starts fresh.
    var lastSmoothingFrameTime: TimeInterval = 0

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
    // back up and arrive in a burst, and posting each one animated the cursor
    // through seconds of old positions. Throttling still replayed history, so
    // `isStaleHoverMove` skips stale reports outright. Only plain hover moves
    // are skipped; clicks, drags, and stroke data are untouched.

    /// A report whose kernel timestamp is older than this when decoded is
    /// backlog, not a live sample.
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
    /// readout matches what's injected. Interpolates, since plain indexing
    /// would cut 8192-level sensors to 256 steps.
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
    /// One-shot timer on HIDThread, not the main queue, so a congested main
    /// thread can't stretch the 80 ms delay. It fires and cancels on HIDThread,
    /// with the rest of the per-report state.
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

    /// State machine for the `.scrollDrag` binding (see `PanScrollTracker`).
    /// While engaged, pen movement posts phased pixel scrolls instead of cursor
    /// motion.
    var panScroll = PanScrollTracker()

    /// Timestamp of the previous pen frame, for the tracker's velocity average.
    /// 0 means unknown (the first frame), and that frame skips `dt`.
    var lastPanScrollFrameTime: TimeInterval = 0

    /// Force-closes a pan whose button release was lost. Armed at proximity
    /// exit with a pan open; cancelled by the release.
    var panScrollSafetyNetTimer: CFRunLoopTimer?
    /// How long a pan may sit suspended (pen out of range, no release seen)
    /// before it closes as a lost gesture. Matches the proximity-exit
    /// held-button safety interval.
    let panScrollSafetyNetInterval: TimeInterval = 4.0

    /// Momentum tail after a Pan View release in Momentum mode; see
    /// MomentumTail.swift. `[weak self]` avoids a retain cycle.
    lazy var panMomentumTail = MomentumTail { [weak self] dx, dy, phase in
        self?.postScrollMomentum(dx: dx, dy: dy, phase: phase)
    }

    /// A separate instance, so a touch scroll's tail can't cancel or blend with
    /// a Pan View tail.
    lazy var touchMomentumTail = MomentumTail { [weak self] dx, dy, phase in
        self?.postScrollMomentum(dx: dx, dy: dy, phase: phase)
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

    /// Whether a Pan View release coasts, captured at engage from the tool's
    /// Momentum setting. The pan itself always carries scroll phases.
    var panScrollCoasts = false

    var lastPostedPoint: CGPoint = .zero
    /// Where the last pointer event went, or nil to read the pointer. Pan
    /// View moves `lastPostedPoint` with the pen while the pointer stays put,
    /// so deltas start from here.
    var lastDeltaOrigin: CGPoint?
    var lastPostedPressure: Double = -1.0
    var lastPostedRotation: Double = 0.0
    var hasPostedPoint = false

    /// Consecutive hover moves dropped as stale backlog; logged at most once
    /// a second.
    var staleHoverSuppressCount = 0
    var lastStaleHoverLogAt: TimeInterval = 0

    // MARK: - Click state

    private var lastClickPosition: CGPoint = .zero
    private var lastClickTime: TimeInterval = 0
    private var clickCount: Int = 0
    var activeClickCount: Int = 1

    // MARK: - Express key / touch ring state

    var auxButtons = AuxButtonState()
    var lastRingButtonDown: Bool { hardwareRingButtonDown || auxButtons.isHeld(.ring) }
    /// Firmware-owned mode buttons have no host binding to release.
    var hardwareRingButtonDown = false
    /// Last ring mode the device's firmware reported (ExpressKey Remote).
    var lastHardwareRingMode: Int?
    /// Same as `lastRingButtonDown`, for the second dial's own toggle key
    /// (PTK-670/870's right cluster center). Unused on every other device.
    var lastRing2ButtonDown: Bool { auxButtons.isHeld(.ring2) }
    /// Last accepted touch ring position (0–71). 0x7F = no contact.
    var lastRingPos: UInt8 = 0x7F
    /// Holds back a hand resting on a ring; see `RingStepFilter`.
    var ringSteps = RingStepFilter()
    var ring2Steps = RingStepFilter()
    /// Last ring position before contact was lost, and when. Slow fingers
    /// drop out for a frame mid-turn (PTH-660); see `ringDropoutBridge`.
    var ringLiftPos: UInt8 = 0x7F
    var ringLiftTime: TimeInterval = 0
    /// Last accepted right touch ring position (DTK-2400). 0x7F = no contact.
    var lastRing2Pos: UInt8 = 0x7F
    /// Last observed Intuos3 WS touch strip positions. 0xFF = no contact.
    var lastStrip1Pos: UInt8 = 0xFF
    var lastStrip2Pos: UInt8 = 0xFF
    /// Fractional-delta accumulators for ring/strip speed scaling.
    /// Carry sub-integer remainders across pulses so speed < 1.0 fires evenly.
    var ringAccum: Double = 0
    var ring2Accum: Double = 0
    /// A zoom or rotate gesture is open on a touch ring, from contact to lift.
    /// Keyed on `touchRingActive`, independently of the center button.
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
    /// a held button short. Its range tag trips sooner than Wacom's. With
    /// nothing held, a short debounce absorbs a blip. With a button held,
    /// cleanup waits for the pen to return, and the long interval is only a
    /// safety net.
    var proximityExitDebounceTimer: CFRunLoopTimer?
    let proximityExitDebounceInterval: TimeInterval = 0.15
    let proximityExitHeldButtonSafetyInterval: TimeInterval = 4.0

    /// Xencelabs only: a small debounce on the barrel-button release. Its
    /// button range is shorter than its position range, so a held button
    /// flickers for a frame or two at the edge. No hand can release and re-press
    /// in ~15 ms, so bridging that window reads intent. Kept small so a real
    /// double-tap (~120 ms) stays two clicks; a 0.15–0.25 s window felt sticky.
    var button1UpDebounceTimer: CFRunLoopTimer?
    var button2UpDebounceTimer: CFRunLoopTimer?
    var button3UpDebounceTimer: CFRunLoopTimer?

    /// How long ago the physical release happened, while a debounced release
    /// is committing; 0 otherwise. Pan View reads it to judge momentum from the
    /// real release (`PanScrollTracker.disengage(backdate:)`).
    var pendingButtonUpBackdate: TimeInterval = 0
    let buttonUpDebounceInterval: TimeInterval = 0.05

    /// Tip chatter debounce for any device, gated on Steadiness. Press is
    /// immediate; a release waits, and a re-press cancels it. Scales from 0 to
    /// `buttonUpDebounceInterval`'s tuned 50 ms.
    var tipUpDebounceTimer: CFRunLoopTimer?

    /// Armed by a weak frame at the edge of range, cancelled by any pen
    /// report: a tablet that goes quiet after weak frames has left without
    /// saying so. Several report intervals, so a late report doesn't end it.
    /// One timer, made on first use and moved, so HIDThread allocates nothing
    /// per frame; parked at the distant future when idle.
    var weakSignalExitTimer: CFRunLoopTimer?
    static let weakSignalSilence: CFTimeInterval = 0.06
    /// Weak frames alone keep the pen in range this long at most: sparse
    /// ones can trickle in after the pen has gone.
    static let weakSignalLimit: CFTimeInterval = 1.0
    /// Uptime of the last report with the pen fully in range.
    var lastStrongPenAt: CFTimeInterval = 0

    /// A hovering eraser end tilted this far counts as out of range: the pen
    /// is lying flat, held for typing or turning over, not erasing. Contact
    /// always counts. 1 or more turns it off. Set at launch.
    nonisolated(unsafe) static var eraserFlatTilt: Double = 0.97
    /// How far under `eraserFlatTilt` the tilt must fall before the eraser
    /// counts again.
    static let eraserFlatRelease = 0.05
    /// Whether the eraser end is being ignored as flat.
    var flatEraserIgnored = false

    /// Longer release debounce for right-click and eraser bindings, so a context
    /// menu survives lifting the pen with the button held. The button bit drops
    /// 55–130 ms before proximity does; the release must not commit before then,
    /// or it picks the highlighted item. A late release is harmless for menus.
    /// A lift slower than 0.25 s can still slip through.
    let buttonUpDebounceMenuInterval: TimeInterval = 0.25

    // MARK: - Time-based leak watchdog
    //
    // A 1 Hz backstop that runs regardless of activity, for when
    // aux button state is stuck (e.g. unplugged mid-press).

    private var leakWatchdogTimer: CFRunLoopTimer?
    /// When `groundTruthSyntheticFlags` last changed.
    var lastSyntheticFlagChangeAt: TimeInterval = 0
    /// When the last tablet report arrived (`inject`, `injectAux`, or
    /// `injectMouseButtons`); `rearmWatchdog()` stamps it.
    private var lastInjectCallAt: TimeInterval = 0
    /// Time of the last pen report. Touch traffic doesn't refresh it, so a
    /// streaming two-finger gesture can't hide a silent, stuck pen.
    var lastPenInjectCallAt: TimeInterval = 0

    // MARK: - Physical modifier state tap
    //
    // Passive tap on hardware flagsChanged events, keeping
    // `tapLastPhysicalFlags` current. Our own posts write into hidSystemState
    // too, so it filters on `sourceStateID` and reads `event.flags`.

    var flagsChangedTap: CFMachPort?
    var flagsChangedTapSource: CFRunLoopSource?
    /// Present only while touch is on; see `updateKeyDownTap(wanted:)`.
    var keyDownTap: CFMachPort?
    var keyDownTapSource: CFRunLoopSource?
    /// Physical modifier bits (⌘⌥⇧⌃) from the last hardware flagsChanged event.
    /// Only events with `sourceStateID == hidSystemState` update it, so our own
    /// synthetic posts can't.
    var tapLastPhysicalFlags: UInt64 = 0

    /// When `tapLastPhysicalFlags` was written, on `currentReportTimestampNs`'s
    /// clock, so `moveSafeEventFlags` can tell a current cache from a stale one.
    var tapLastPhysicalFlagsAtNs: UInt64 = 0


    /// True when no physical tablet control is held. If this holds and
    /// `groundTruthSyntheticFlags` is non-empty, the flags are a leak.
    var tabletIsQuiescent: Bool {
        !lastTipDown && !lastButton1Down && !lastButton2Down && !lastButton3Down
            && !lastMiddleDown
            && !lastRingButtonDown && !lastRing2ButtonDown
            && lastRingPos == 0x7F && lastRing2Pos == 0x7F
            && lastStrip1Pos == 0xFF && lastStrip2Pos == 0xFF
            && lastUSBMouseMask == 0
            && !auxButtons.hasHeldControls
    }

    /// Must run on HIDThread (where `watchdogTimer`, `lastInjectCallAt`, and
    /// `groundTruthSyntheticFlags` are owned).
    func rearmWatchdog() {
        lastInjectCallAt = ProcessInfo.processInfo.systemUptime
        if let t = watchdogTimer { CFRunLoopTimerInvalidate(t) }
        watchdogTimer = nil
        guard !groundTruthSyntheticFlags.isEmpty || !heldKeyComboRefCounts.isEmpty
                || !heldAuxKeyComboRefCounts.isEmpty else { return }
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + watchdogInterval,
            0,  // interval — one-shot
            0, 0
        ) { [weak self] _ in
            guard let self,
                !self.groundTruthSyntheticFlags.isEmpty || !self.heldKeyComboRefCounts.isEmpty
                    || !self.heldAuxKeyComboRefCounts.isEmpty
            else { return }
            // Wacom pads stream while a key is held, so a timeout means the stream
            // stopped. Quick Keys report only changes, so trust the last known state;
            // the 1 Hz watchdog catches a stuck "held".
            guard self.tabletIsQuiescent else { return }
            self.releaseAllSyntheticModifiers()
            self.releaseAllHeldKeyComboKeys(includeAux: true)
        }
        watchdogTimer = timer
        if let timer { CFRunLoopAddTimer(HIDThread.shared.runLoop, timer, .commonModes) }
    }

    /// Schedules the 1 Hz leak check on HIDThread in common modes, so a menu,
    /// a modal, or a stalled main thread can't hold it off. Nonisolated, unlike
    /// `init`, so the handler doesn't inherit main's isolation.
    private func installLeakWatchdog() {
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1.0, 1.0, 0, 0
        ) { [weak self] _ in self?.checkLeakWatchdog() }
        leakWatchdogTimer = timer
        CFRunLoopAddTimer(HIDThread.shared.runLoop, timer, .commonModes)
    }

    /// 1 Hz leak check for orphaned keyboard state. It fires after 3 s with
    /// flags unchanged, the tablet idle, and nothing held.
    private func checkLeakWatchdog() {
        let idleInterval = ProcessInfo.processInfo.systemUptime - self.lastInjectCallAt
        let penIdleInterval = ProcessInfo.processInfo.systemUptime - self.lastPenInjectCallAt

        // Stuck-proximity backstop: if `lastProximity` latches true (a lost exit
        // report), this much pen silence is proof, so force the exit. It gates on
        // pen idleness, not general idleness, because touch frames kept the
        // general timer fresh and once hid a stuck pen for a whole session.
        if self.lastProximity, penIdleInterval > Self.stuckProximityTimeout,
            let snap = self.injectionSnapshot
        {
            injectLog.notice("leak-watchdog: forcing stuck pen-proximity exit (pen idle \(Int(penIdleInterval))s)")
            FlightRecorder.shared.note(String(format: "pen leaves range by watchdog: no pen report for %.1f s (0x%04X)", penIdleInterval, deviceProductID))
            TouchPipelineProbe.note { $0.penProximityForcedExits += 1 }
            self.commitProximityExit(snap: snap)
        }

        // Touch streams while a finger is down, so a held drag with no
        // frames for a second lost its lift.
        if self.touchDragPosition != nil,
           ProcessInfo.processInfo.systemUptime - self.lastTouchFrameTime > 1.0,
           let snap = self.injectionSnapshot {
            injectLog.notice("leak-watchdog: releasing stranded touch drag")
            self.releaseTouchDrag(snapshot: snap)
        }

        if !self.groundTruthSyntheticFlags.isEmpty {
            let heldInterval = ProcessInfo.processInfo.systemUptime - self.lastSyntheticFlagChangeAt
            // As in the idle watchdog, a device that reports only changes
            // (Quick Keys) can sit idle through a long legitimate hold, so the
            // last known button state counts, not just elapsed time.
            if heldInterval > 3.0 && idleInterval > 3.0 && self.tabletIsQuiescent {
                modLog.notice("leak-watchdog: releasing stuck synthetic flags 0x\(String(self.groundTruthSyntheticFlags.rawValue, radix: 16), privacy: .public) (held \(Int(heldInterval))s, idle \(Int(idleInterval))s)")
                self.releaseAllSyntheticModifiers()
            }
        }

        // Same check for a plain key held by a `.keyCombo` binding.
        if !self.heldKeyComboRefCounts.isEmpty || !self.heldAuxKeyComboRefCounts.isEmpty {
            let heldInterval = ProcessInfo.processInfo.systemUptime - self.lastKeyComboChangeAt
            if heldInterval > 3.0 && idleInterval > 3.0 && self.tabletIsQuiescent {
                let keys = Set(self.heldKeyComboRefCounts.keys).union(self.heldAuxKeyComboRefCounts.keys)
                modLog.notice("leak-watchdog: releasing stuck keyCombo keys \(Array(keys), privacy: .public) (held \(Int(heldInterval))s, idle \(Int(idleInterval))s)")
                self.releaseAllHeldKeyComboKeys(includeAux: true)
            }
        }

        // Same check for the shared store, looking across every device.
        let shared = SharedAuxModifierState.shared
        if !shared.groundTruthFlags.isEmpty {
            let sharedHeldInterval = ProcessInfo.processInfo.systemUptime - shared.lastChangeAt
            if sharedHeldInterval > 3.0 && idleInterval > 3.0 && !Self.anyAuxControlHeld {
                modLog.notice("leak-watchdog: releasing stuck shared aux flags 0x\(String(shared.groundTruthFlags.rawValue, radix: 16), privacy: .public) (held \(Int(sharedHeldInterval))s)")
                self.releaseSharedAuxModifiers()
            }
        }
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

    var injectionSnapshot: InjectionSnapshot? {
        didSet { updateKeyDownTap(wanted: injectionSnapshot?.touchEnabled == true) }
    }

    // MARK: - Display mapping

    /// Display selection, orientation, calibration, and relative mapping; see
    /// DisplayMapper.swift. HIDThread, except `recomputeVirtualScreenBounds()`
    /// on main.
    var displayMapper = DisplayMapper()

    /// Cached touch coordinate maximums, invalidated when `deviceProductID`
    /// changes, to skip a per-frame registry scan.
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
    /// End momentum tails on sleep and quit; see their registration in `init`.
    private var willSleepObserver: NSObjectProtocol?
    private var willTerminateObserver: NSObjectProtocol?

    // MARK: - USB HID mouse button injection (KC-100 cordless mouse)
    //
    // Called for each report 0x01 from the mouse interface. Posts button events
    // at the cursor and sets usbMouseLeftHeld, so movement becomes drags.

    func injectMouseButtons(mask: UInt8, settings: TabletSettings?) {
        ThreadContract.expectPenThread()
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
    /// to a gesture. For `CaptureTouchPipeline` diagnostics only.
    var touchSequenceSawTwoFingers = false
    var touchSequenceCommitted = false
    /// Gesture components opened during this sequence; a component can join
    /// partway through (see `noteGestureComponentBegan`).
    var touchSequenceSawPinch = false
    var touchSequenceSawRotate = false
    var touchSequenceBothCounted = false
    /// Cursor position this injector owns for relative touch motion (see
    /// `postTouchPointerMove`). `nil` between sequences; the first move seeds
    /// it from the OS.
    var touchOwnedPointerPosition: CGPoint?
    /// When `injectTouch` last ran with contacts, for the sub-millisecond-gap
    /// diagnostic that flags batched Bluetooth bursts.
    var lastTouchFrameTime: TimeInterval = 0
    /// Whether the previous frame already had palm rejection cutting a
    /// two-contact frame below two, so `palmRejectionBrokeTwoFingerFrames`
    /// counts entries, not every held frame.
    var palmRejectionBrokeTwoFingerActive = false
    /// The current touch sequence has had a rejected palm in it, and the
    /// contacts already measured against it, for the palm diagnostics.
    var touchSequenceSawPalm = false
    var palmNeighborMeasuredIDs: Set<Int> = []
    /// `touchTracker.mode` at the previous `injectTouch` frame, to spot
    /// `.idle` → `.pending` transitions (onset windows) without the tracker
    /// reporting them.
    var prevTouchMode: TouchStateTracker.Mode = .idle
    /// When the last touch sequence ended. A new touch within
    /// `CaptureTouchPipeline.reArmWindow` is one interrupted drag, not a new touch.
    var lastTouchTeardownTime: TimeInterval = 0
    /// When the current single-contact pointer drag began, for
    /// `CaptureTouchPipeline.longestSingleContactDragMs`. 0 when not in a
    /// single-contact drag.
    var singleContactDragStart: TimeInterval = 0
    /// When the pen last left range. Touch waits a brief grace window after,
    /// so a finger landing as the pen lifts isn't taken as input.
    var penProximityExitTime: TimeInterval = 0
    /// Starting value; tune if reports show false positives.
    static let touchArbitrationGrace: TimeInterval = 0.08
    /// After the pen leaves proximity, the hand most likely still holds it:
    /// a touch starting this soon can scroll, zoom, or rotate, but not click
    /// or move the cursor. Reasoned, not measured.
    static let penInHandWindow: TimeInterval = 3.0
    /// Contacts already down while the pen was busy: the hand that held the
    /// pen. Ignored until they lift, so a resting hand never turns into
    /// fingers when the pen leaves.
    var touchPenHeldIDs: Set<Int> = []
    /// The current touch sequence included a palm, a pen-held contact, or
    /// began with the pen in hand. Until every contact lifts, it may scroll,
    /// zoom, or rotate, but its clicks and cursor moves are dropped.
    var touchSequenceTainted = false
    /// Last physical key press, from the keyDown tap on HIDThread.
    var lastPhysicalKeyDownTime: TimeInterval = 0
    /// Where a three-finger drag holds the left button; nil when none is
    /// held. See the `touchDragPosition` row in the latch table above.
    var touchDragPosition: CGPoint?
    /// For this long after a keypress, touch can scroll, zoom, or rotate, but not
    /// click or move the cursor: a resting hand, like a trackpad's typing guard.
    /// Reasoned, not measured.
    static let typingHoldOff: TimeInterval = 0.5
    /// The pen touched down or stayed in range past `touchBusyHoldOff`. Touch
    /// arbitration gates on this, not raw `lastProximity`: Bluetooth proximity
    /// flaps in 5–45 ms bursts while the pen is just held near the tablet,
    /// which would block touch almost constantly.
    var touchPenConfirmedBusy: Bool = false
    /// When the current proximity session began, for measuring
    /// `touchBusyHoldOff` against.
    var proximityConfirmStartTime: TimeInterval = 0
    /// How long proximity must last before touch treats the pen as in use:
    /// longer than the measured flap bursts, too short to notice. Tip contact
    /// skips it.
    static let touchBusyHoldOff: TimeInterval = 0.15

    /// When `touchPenConfirmedBusy` most recently flipped true.
    var touchPenBusyConfirmedAt: TimeInterval = 0
    /// The pen has touched down since this busy episode began; see
    /// `staleBusyTimeout`.
    var touchPenBusyHadTipSinceConfirmed: Bool = false
    /// How long the pen may count as busy with no tip contact before touch gets
    /// through again. Bluetooth proximity can sit ambiguous for seconds, and the
    /// decoder deliberately stays in range then, since exiting early once killed
    /// proximity for good. A hand moving during a touch gesture could otherwise
    /// block touch indefinitely. Well above any pause before a stroke; one tip
    /// contact resets it.
    static let staleBusyTimeout: TimeInterval = 3.0

    func currentCursorPosition() -> CGPoint {
        // Cursor in CG global coordinates, safe off main. NSEvent.mouseLocation
        // needed main and a Y-flip that broke on stacked displays.
        CGEvent(source: nil)?.location ?? .zero
    }

    // MARK: - Click resolution

    /// Points a second tap may land from the first and still count as a
    /// double-click, at Double-Click Distance Off.
    static let minimumDoubleClickDistance: Double = 2

    func resolveClick(
        _ candidate: CGPoint,
        snapshot: InjectionSnapshot
    ) -> (CGPoint, Int) {
        let now = ProcessInfo.processInfo.systemUptime
        let dist = hypot(
            candidate.x - lastClickPosition.x,
            candidate.y - lastClickPosition.y)

        // Off (0) still allows a little wobble, and no value counts tighter
        // than Off, so the slider runs one way.
        let countThreshold = max(snapshot.doubleClickDistance, Self.minimumDoubleClickDistance)
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

    /// The synthetic modifiers that tablet button state says should be active.
    var groundTruthSyntheticFlags: CGEventFlags = []

    /// Reference counts per modifier bit, for several buttons mapped to one key.
    var modifierRefCounts: [UInt64: Int] = [
        CGEventFlags.maskCommand.rawValue: 0,
        CGEventFlags.maskShift.rawValue: 0,
        CGEventFlags.maskAlternate.rawValue: 0,
        CGEventFlags.maskControl.rawValue: 0,
    ]

    /// Keys held by plain pen `.keyCombo` bindings, ref-counted like modifiers so
    /// the same watchdog, app-switch, and proximity-exit releases catch a lost
    /// key-up.
    var heldKeyComboRefCounts: [CGKeyCode: Int] = [:]
    /// Aux keys survive pen proximity exits and app switches, like their
    /// modifiers; only their owning buttons or a disconnect release them.
    var heldAuxKeyComboRefCounts: [CGKeyCode: Int] = [:]
    /// When a pen or aux key count last changed, for the leak watchdog.
    var lastKeyComboChangeAt: TimeInterval = 0

    /// Left-hand keycodes for each modifier: AppKit and Electron ignore
    /// flagsChanged with keycode 0.
    static let modifierKeyCodes: [(CGEventFlags, CGKeyCode)] = [
        (.maskCommand,   55),  // left ⌘
        (.maskShift,     56),  // left ⇧
        (.maskAlternate, 58),  // left ⌥
        (.maskControl,   59),  // left ⌃
    ]

    /// Private-state source. Our posts still write into hidSystemState, so the
    /// flags tap filters by sourceStateID. Created once: a new source per event
    /// leaked WindowServer memory.
    let sessionSource: CGEventSource? = CGEventSource(stateID: .privateState)

    // MARK: - Screen mapping
    //
    // Forwards to DisplayMapper for callers outside inject() and injectTouch.

    /// When set, `.displayToggle` presses go here instead of cycling this
    /// injector's own display mapping. `TabletManager` assigns it at connect for
    /// aux-only accessories; it runs on HIDThread.
    var displayToggleForwarder: (() -> Void)?

    /// When set, `.relativeModeToggle` forwards here, like
    /// `displayToggleForwarder`, for aux-only accessories. Called on HIDThread.
    var relativeModeToggleForwarder: (() -> Void)?

    /// `.spanDisplaysToggle` counterpart of `displayToggleForwarder`.
    var spanDisplaysForwarder: (() -> Void)?

    /// Opens this device's settings window for `.showSettings`. Assigned by
    /// TabletManager, which knows the window; called on HIDThread.
    var showSettingsHandler: (() -> Void)?

    /// Advances the toggle rotation to the next display. `fireButtonAction`
    /// calls it on HIDThread when a `.displayToggle` binding fires.
    func cycleToggleDisplay(snapshot: InjectionSnapshot) {
        displayMapper.cycleToggleDisplay(snapshot: snapshot)
    }

    /// Forces a calibration re-read on the next report. Call after calibration
    /// data is stored or cleared. It hops to HIDThread, which owns the display
    /// mapper's cache.
    func invalidateCalibrationCache() {
        CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.displayMapper.invalidateCalibrationCache()
        }
        CFRunLoopWakeUp(HIDThread.shared.runLoop)
    }

    /// Recomputes the virtual-screen union from `NSScreen.screens`. Main only;
    /// `init` and the screen-parameters observer call it.
    @MainActor
    private func recomputeVirtualScreenBounds() {
        displayMapper.recomputeVirtualScreenBounds()
    }
}
