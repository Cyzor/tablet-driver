// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import IOKit.hid
import OSLog
import TabletKit

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "manager")

/// Standalone publisher for live touch contacts.  Kept off `TabletManager`
/// so the ~30 Hz touch stream invalidates only views that explicitly observe
/// this object, not every view that observes `TabletManager`.
///
/// `isPublishingEnabled` lets the sole consumer (ScratchpadView) gate updates
/// on its own visibility — when the scratchpad tab is hidden or the app
/// resigns active, the HID-thread closure skips both the throttle bookkeeping
/// and the main-thread dispatch entirely.
final class LiveTouchPublisher: ObservableObject {
    @MainActor @Published var contacts: [TouchContact] = []

    /// HID-thread reads, main-thread writes.  Bool reads/writes are atomic on
    /// aarch64; a brief disagreement during a state transition just costs one
    /// or two redundant frames, which is harmless.
    nonisolated(unsafe) var isPublishingEnabled: Bool = false

    /// HID-thread-only.  Last time the throttle let a publish through.
    /// Lives here (rather than on `TabletManager`, which is `@MainActor`)
    /// so the cross-thread read/write is no longer a concurrency violation.
    /// 8-byte loads/stores are atomic on aarch64; a torn read is impossible.
    nonisolated(unsafe) var lastPublishTime: CFAbsoluteTime = 0

    /// Throttle target: ~30 Hz.  HID delivers touch at ~100 Hz under load,
    /// and even after `isPublishingEnabled` gates inactive consumers, the
    /// active scratchpad doesn't benefit from canvas redraws faster than this.
    static let publishInterval: CFAbsoluteTime = 1.0 / 30.0
}

/// Manages IOHIDManager lifecycle, per-device contexts, and proximity-based
/// activation for multi-tablet support.
///
/// Each connected tablet gets its own `DeviceContext` (settings, injector,
/// driver).  Only the *active* context posts CGEvents — activation happens
/// automatically when a pen enters proximity on a given tablet.
///
/// @MainActor because all mutable state and CGEvent posts require the main thread.
/// IOHIDManager is scheduled on HIDThread (a dedicated background run loop) so
/// HID report callbacks arrive immediately regardless of SwiftUI frame work on main.
/// Device-lifecycle and inject() calls hop back to @MainActor via Task.
@MainActor
final class TabletManager: ObservableObject {

    static let shared = TabletManager()

    private let manager: IOHIDManager

    // MARK: - Per-device state

    @Published var contexts: [Int: DeviceContext] = [:]
    /// The device whose injector is currently posting CGEvents.
    /// `didSet` keeps `injector.isActive` in lockstep so the HIDThread fast path in
    /// `onTablet` is gated by a flag that exactly mirrors `activeContext`. Without
    /// this, `injector.isActive` would only flip on a context *change*; the very
    /// first device (where `deviceConnected` does `if activeContext == nil` …)
    /// would have its activation skipped and the cursor would never move.
    @Published var activeContext: DeviceContext? = nil {
        didSet {
            if oldValue !== activeContext { oldValue?.injector.isActive = false }
            activeContext?.injector.isActive = true
        }
    }
    @Published var activeToolID: String? = nil
    @Published var liveButtons = LiveButtonState()
    @Published var livePoint: TabletPoint? = nil
    /// Most-recent touch contacts from the active device's touch surface.
    /// Empty when no contacts are active or the device has no finger touch.
    ///
    /// Lives on its own `ObservableObject` so the ~30 Hz touch-frame stream
    /// invalidates only the one view that consumes it (ScratchpadView) and
    /// not every settings pane that observes `TabletManager`.  Broadcasting
    /// touch updates through `TabletManager` collapsed every pane's body
    /// at touch-frame rate, which was the dominant CPU cost under a palm.
    let liveTouch = LiveTouchPublisher()

    private var hidDeviceMap: [IOHIDDevice: DeviceContext] = [:]
    private var shimObservers: [NSObjectProtocol] = []
    /// Interfaces deferred because they arrived before the control interface (0xFF00) for their PID.
    /// Drained into registerDevice() once a WacomKnownDevice is created for that PID.
    private var pendingInterfaces: [Int: [IOHIDDevice]] = [:]

    // MARK: - Legacy published state

    @Published var isConnected = false
    @Published var connectedProductID: Int = 0
    @Published var connectedProductIDs: [Int] = []
    @Published var connectedTransport: String = "—"
    @Published var connectedUSBSpeed: String = "—"
    @Published var hidManagerOpen: Bool = false

    /// Battery state for the active device, nil when unknown (USB or pre-first-report).
    @Published var batteryPercent: Int? = nil
    @Published var batteryCharging: Bool = false

    // MARK: - UI throttle
    //
    // @Published mutations fire objectWillChange.send() on every write, which
    // triggers SwiftUI diffing on the main thread.  At 133 Hz that's hundreds
    // of invalidations per second even when no values changed.
    //
    // Two-level gate:
    //   1. infoViewVisible — set by SettingsWindowController when the Info tab
    //      is frontmost.  When false, livePoint / liveButtons are never written
    //      at all, so @Published fires zero times during normal use.
    //   2. uiUpdateCounter — when the Info tab IS visible, further throttle to
    //      ~16 Hz so SwiftUI layout work stays negligible.

    /// True when MockTab is the frontmost application. Set by AppDelegate on
    /// didBecomeActive/willResignActive. Combined with infoViewVisible to gate updates.
    ///
    /// Plain `Bool`, not `@Published`: this is read on the HID thread at ~200 Hz
    /// inside the `onTablet` gate. `@Published`'s Combine-wrapped getter showed up
    /// as ~13% of HID-thread time when this was published. No SwiftUI view binds
    /// to this directly — only same-thread gate code and main-thread setters touch it.
    var appIsFrontmost: Bool = false

    /// Set true by SettingsWindowController when the Info or Buttons tab is frontmost
    /// in the active window. Combined with appIsFrontmost: both must be true to update
    /// livePoint/liveButtons, eliminating all SwiftUI overhead when MockTab is in the
    /// background or a different tab is active.
    var infoViewVisible: Bool = false

    /// Optional raw-data callback for calibration. When set, every active-context
    /// TabletPoint is forwarded here *in addition to* the normal injection path.
    /// Always assign through `setCalibrationPointHandler(_:)` so the HID-thread
    /// gate `calibrationActive` stays in sync.
    private(set) var calibrationPointHandler: ((TabletPoint) -> Void)?

    /// Single-word mirror of `calibrationPointHandler != nil`, safe to read from
    /// HID thread. Reading the optional closure itself across threads is unsafe
    /// (two-word load can tear); this Bool is the cheap gate used in `onTablet`.
    private(set) var calibrationActive: Bool = false

    func setCalibrationPointHandler(_ handler: ((TabletPoint) -> Void)?) {
        calibrationPointHandler = handler
        calibrationActive = handler != nil
    }

    private var uiUpdateCounter = 0
    private static let uiUpdateInterval = 8  // every 8th report ≈ 16 Hz at 133 Hz

    // MARK: - Device name helpers

    static func deviceName(forProductID pid: Int) -> String {
        WacomDeviceRegistry.deviceName(forProductID: pid)
    }

    var connectedDeviceName: String {
        switch connectedProductIDs.count {
        case 0: return "No tablet"
        case 1: return Self.deviceName(forProductID: connectedProductIDs[0])
        default:
            let first = Self.deviceName(forProductID: connectedProductIDs[0])
            return "\(first) + \(connectedProductIDs.count - 1) more"
        }
    }

    // MARK: - Legacy single-device accessors

    var settings: TabletSettings? {
        get { activeContext?.settings }
        set { /* no-op: settings are now per-context */  }
    }

    var injector: InputInjector? {
        activeContext?.injector
    }

    // MARK: - Init

    private init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func start() {
        if #available(macOS 10.15, *) {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        // Primary match: Wacom (VID 0x056A) — the only vendor we actually decode.
        //
        // Secondary matches: Huion, Xencelabs/XP-Pen, UC-Logic — vendors covered
        // by VendorDeviceRegistry.  These devices are *not* decoded; deviceConnected
        // logs them by name and returns immediately, so the user can see in
        // `log show --predicate 'subsystem == "com.cyzor.mocktab"'` that the device
        // was recognised even though MockTab can't drive it yet.  This keeps the
        // unknown-device discovery flow honest: "your tablet is a Huion H1060P,
        // and we don't support it" beats "your tablet is invisible to us."
        let matching: [[String: Any]] = [
            [kIOHIDVendorIDKey: 0x056A as NSNumber],  // Wacom
            [kIOHIDVendorIDKey: 0x256C as NSNumber],  // Huion (recognition only)
            [kIOHIDVendorIDKey: 0x28BD as NSNumber],  // Xencelabs / XP-Pen (recognition only)
            [kIOHIDVendorIDKey: 0x5543 as NSNumber],  // UC-Logic OEMs (recognition only)
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let ctx = Unmanaged.passRetained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            { ctx, _, _, device in
                guard let ctx else { return }
                let mgr = Unmanaged<TabletManager>.fromOpaque(ctx).takeUnretainedValue()
                // Hop to main — TabletManager is @MainActor; HIDThread fires this callback.
                Task { @MainActor in mgr.deviceConnected(device) }
            }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            { ctx, _, _, device in
                guard let ctx else { return }
                let mgr = Unmanaged<TabletManager>.fromOpaque(ctx).takeUnretainedValue()
                Task { @MainActor in mgr.deviceDisconnected(device) }
            }, ctx)

        setupShimBridge()
        // Schedule on the dedicated HID thread so report delivery is not gated
        // on main-thread availability (e.g. during SwiftUI rendering passes).
        IOHIDManagerScheduleWithRunLoop(
            manager, HIDThread.shared.runLoop, RunLoop.Mode.common.rawValue as CFString)
        let ret = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManagerOpen = (ret == kIOReturnSuccess)
        if !hidManagerOpen {
            logger.error("TabletManager: failed to open HID manager (\(ret, privacy: .public)). Check Input Monitoring permission or uninstall any existing tablet driver.")
        }
    }

    // MARK: - Adobe shim bridge

    /// Subscribe to distributed notifications posted by WacomShim when Adobe apps
    /// send eSendTabletEvent Apple Events requesting a replay of the last tablet event.
    private func setupShimBridge() {
        let dn = DistributedNotificationCenter.default()
        let pointer = dn.addObserver(
            forName: NSNotification.Name("com.cyzor.mocktab.shim.replayPointer"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeContext?.injector.replayPointerEvent() }
        }
        let proximity = dn.addObserver(
            forName: NSNotification.Name("com.cyzor.mocktab.shim.replayProximity"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeContext?.injector.replayProximityEvent() }
        }
        shimObservers = [pointer, proximity]
    }

    func stop() {
        let dn = DistributedNotificationCenter.default()
        for obs in shimObservers { dn.removeObserver(obs) }
        shimObservers.removeAll()
        IOHIDManagerUnscheduleFromRunLoop(
            manager, HIDThread.shared.runLoop, RunLoop.Mode.common.rawValue as CFString)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        for (_, ctx) in hidDeviceMap { ctx.tabletDevice?.close() }
        hidDeviceMap.removeAll()
        contexts.removeAll()
        activeContext = nil
    }

    // MARK: - Device lifecycle

    private func deviceConnected(_ device: IOHIDDevice) {
        let vendorID = hidIntProperty(device, kIOHIDVendorIDKey)
        let rawProductID = hidIntProperty(device, kIOHIDProductIDKey)

        // Non-Wacom recognition path: name the device via VendorDeviceRegistry,
        // log it, and bail out before any Wacom-specific state touches it.
        // The IOHIDManager match-dict broadens to Huion/Xencelabs/XP-Pen/UC-Logic
        // VIDs so these calls fire instead of the device being invisible — but
        // we have no decoder for them yet, so there's nothing more to do here.
        if vendorID != 0x056A {
            let profiles = VendorDeviceRegistry.profiles(
                forVendorID: vendorID, productID: rawProductID)
            let name = profiles.first?.productName ?? "(unknown product)"
            let vendorName = profiles.first?.vendor
                ?? "non-Wacom vendor 0x\(String(vendorID, radix: 16))"
            let candidateCount = profiles.count
            logger.info("TabletManager: recognised \(vendorName, privacy: .public) device — \(name, privacy: .public) (VID=0x\(String(vendorID, radix: 16), privacy: .public) PID=0x\(String(rawProductID, radix: 16), privacy: .public), \(candidateCount, privacy: .public) profile candidates) — no decoder support yet")
            return
        }

        let productID = WacomDeviceRegistry.canonicalProductID(for: rawProductID)
        let usagePage = hidIntProperty(device, kIOHIDPrimaryUsagePageKey)
        let usage = hidIntProperty(device, kIOHIDPrimaryUsageKey)
        let maxRptSize = hidIntProperty(device, kIOHIDMaxInputReportSizeKey)
        let transport =
            IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        let productString =
            IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
        let isBLE = transport.lowercased().contains("bluetooth")
        let pidStr =
            rawProductID == productID
            ? "0x\(String(productID, radix:16))"
            : "0x\(String(rawProductID, radix:16)) → 0x\(String(productID, radix:16))"
        logger.info("TabletManager: device pid=\(pidStr, privacy: .public) usagePage=0x\(String(usagePage, radix:16), privacy: .public) usage=0x\(String(usage, radix:16), privacy: .public) maxRptSize=\(maxRptSize, privacy: .public) transport=\(transport, privacy: .public) product=\"\(productString, privacy: .public)\"")

        // BLE tablets expose multiple interfaces. Log all of them; skip ghost mouse only.
        if isBLE && usagePage == 0x01 {
            logger.debug("TabletManager: BLE usagePage=0x01 interface — maxRptSize=\(maxRptSize, privacy: .public) usage=0x\(String(usage, radix:16), privacy: .public) — skipping ghost mouse")
            return
        }

        let context =
            contexts[productID] ?? DeviceContext(productID: productID, rawProductID: rawProductID)
        contexts[productID] = context
        context.hidDevice = device

        // Seed the per-app override for whatever app is currently frontmost.
        // AppWatcher seeds existing contexts at start(), but a device may connect
        // after launch (or in dockless mode where no app switch occurred yet).
        if let app = NSWorkspace.shared.frontmostApplication,
            let bundleID = app.bundleIdentifier
        {
            let name = app.localizedName ?? bundleID
            context.settings.handleAppOverrideActivation(bundleID: bundleID, appName: name)
            context.injector.activeAppNeedsTabletPointerEvents =
                AppWatcher.qtGtkBundleIDs.contains(bundleID)
            context.injector.activeAppProfile =
                AppWatcher.plainMouseBundleIDs.contains(bundleID) ? .pagesPlainMouse : .generic
        }

        // Propagate context.objectWillChange to TabletManager so SwiftUI observers
        // get updates when per-device state changes (transport, battery, livePoint, etc).
        if context.cancellables.isEmpty {
            context.objectWillChange
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &context.cancellables)
        }

        // Set initial connection state for this device.
        context.isConnected = true
        context.transport = transport
        if !isBLE {
            // Fetch USB speed only for USB devices (will be fetched in refreshConnectedIDs).
            context.usbSpeed = "—"
        }

        // ── Tool-enter closure (IntuosV2 only) ──────────────────────────────
        // Called on HIDThread — hop to main before touching @Published properties.
        let onToolEnter: (ToolIdentity) -> Void = { [weak self, weak context] identity in
            Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            context.activeToolSerial = identity.serial
            context.activeToolIsMouse = identity.isMouse
            context.activeToolCode = identity.toolCode
            // Propagate tool code to calibration session so tool changes are tracked.
            CaptureEngine.shared.updateToolCode(identity.toolCode)
            let toolID = DeviceRegistry.shared.recordTool(identity: identity, forDevice: productID)
            let toolSets = context.settings.toolSettings(forID: toolID, isMouse: identity.isMouse)
            context.activeTool = toolSets
            context.settings.activeTool = toolSets
            context.injector.activeToolSettings = toolSets
            context.injector.activeToolIsMouse = identity.isMouse
            context.injector.activeToolIsEraser = identity.isEraser
            context.injector.activeToolSerial = identity.serial
            context.injector.activeToolCode = identity.toolCode
            context.activeToolID = toolID
            self.activeToolID = toolID  // Legacy: forward to global for backward compatibility
            } // end Task @MainActor
        }

        // ── Tablet point closure ─────────────────────────────────────────────
        // Called on HIDThread (the dedicated CFRunLoop thread that drives IOHIDManager).
        //
        // Fast path: when this device's injector is the active one, inject() runs
        // inline on HIDThread — no Task @MainActor hop, no scheduler wait. Inject
        // reads everything it needs from `injectionSnapshot`, which the main side
        // pushes via CFRunLoopPerformBlock whenever settings change.
        //
        // Slow path: active-context switching (proximity-enter from a non-active
        // device) and per-report UI updates still hop to main. Throughput-critical
        // CGEvent posting never waits on either.
        let onTablet: (TabletPoint) -> Void = { [weak self, weak context] point in
            guard let context else { return }
            let injector = context.injector

            // ── Fast path: inject inline on HIDThread ─────────────────────────
            let isActive = injector.isActive
            if isActive {
                injector.inject(point: point, settings: context.settings)
            }

            // ── HID-thread gate: skip the Task hop when nothing needs to run.
            // At 200 Hz USB report rate the active-pen-backgrounded case used to
            // spawn a Task per report whose body did nothing; this short-circuit
            // collapses that to zero allocations on the dominant idle path.
            let needsHop: Bool
            if isActive {
                needsHop = !point.inProximity  // proximity-exit cleanup
                    || self?.appIsFrontmost == true && self?.infoViewVisible == true  // UI update
                    || self?.calibrationActive == true  // calibration sample
            } else {
                needsHop = point.inProximity  // proximity-enter → context switch
                    || injector.lastProximity  // dangling-proximity cleanup
            }
            guard needsHop else { return }

            // ── UI / context-switch path: throttled hop to main ───────────────
            Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            let injector = context.injector

            // Proximity-enter activates this device's context.
            // Note: `activeContext`'s `didSet` flips `injector.isActive` for both
            // the outgoing and incoming contexts, so we don't touch it here.
            if point.inProximity && self.activeContext !== context {
                if let old = self.activeContext, old.injector.lastProximity {
                    let exitPoint = TabletPoint(
                        x: 0, y: 0, maxX: 1, maxY: 1,
                        pressure: 0, maxPressure: 1,
                        tiltX: 0, tiltY: 0,
                        penButton1: false, penButton2: false,
                        eraser: false, inProximity: false, hoverDistance: 0)
                    // The outgoing exit must be injected *before* the active-context
                    // change flips `old.injector.isActive` off (didSet hasn't fired yet
                    // because we're still on the prior assignment). Inject still works
                    // because it doesn't gate on isActive — only the HIDThread fast
                    // path does.
                    old.injector.inject(point: exitPoint, settings: old.settings)
                }
                self.activeContext = context
                // Inject this report from main (slow, one-time per switch). Cheap.
                injector.inject(point: point, settings: context.settings)
            }
            // Proximity-exit from a non-active device: still post so apps
            // don't get stuck with a dangling proximity state.
            else if !point.inProximity && injector.lastProximity && self.activeContext !== context {
                injector.inject(point: point, settings: context.settings)
                return
            }

            // Only the active context updates UI.
            guard self.activeContext === context else { return }

            // Forward raw data to calibration session if active.
            self.calibrationPointHandler?(point)

            // ── UI state — gated + throttled ─────────────────────────────────
            // Proximity exit always clears state immediately, regardless of app foreground/tab visibility.
            if !point.inProximity {
                self.uiUpdateCounter = 0
                self.activeToolID = nil
                context.activeToolID = nil
                context.activeToolCode = 0
                self.liveButtons = LiveButtonState()
                context.liveButtons = LiveButtonState()
                self.livePoint = nil
                context.livePoint = nil
                return  // Skip UI updates for proximity-exit state
            }

            // Skip UI updates when MockTab is in the background OR the Info/Buttons
            // tab isn't visible. This eliminates every @Published write during
            // normal drawing use, including when MockTab is backgrounded.
            guard appIsFrontmost && infoViewVisible else { return }

            // Throttle continuous updates to ~16 Hz.
            self.uiUpdateCounter += 1
            guard self.uiUpdateCounter >= Self.uiUpdateInterval else { return }
            self.uiUpdateCounter = 0

            let toolIsMouse = context.activeToolIsMouse
            let tipDown = toolIsMouse ? point.penButton1 : point.normalizedPressure > 0.004
            let newButtons = LiveButtonState(
                tipDown: tipDown && !point.eraser,
                eraserDown: tipDown && point.eraser,
                button1Down: point.penButton1,
                button2Down: point.penButton2,
                button3Down: point.penButton3,
                button4Down: point.penButton4,
                button5Down: point.penButton5,
                expressKeys: self.liveButtons.expressKeys,
                touchRingActive: self.liveButtons.touchRingActive,
                touchRingButtonDown: self.liveButtons.touchRingButtonDown,
                touchRing2Active: self.liveButtons.touchRing2Active,
                touchStrip1Active: self.liveButtons.touchStrip1Active,
                touchStrip2Active: self.liveButtons.touchStrip2Active
            )
            // Only assign when values changed — avoids spurious objectWillChange.
            if newButtons != self.liveButtons { self.liveButtons = newButtons }
            if newButtons != context.liveButtons { context.liveButtons = newButtons }
            self.livePoint = point
            context.livePoint = point
            } // end Task @MainActor
        }

        // ── Express key closure ──────────────────────────────────────────────
        // Called on HIDThread. injectAux runs inline (it reads from injectionSnapshot
        // and posts CGEvents — both thread-safe). UI state mutations hop to main.
        let onAux: (AuxButtons) -> Void = { [weak self, weak context] aux in
            guard let context else { return }
            context.injector.injectAux(buttons: aux, settings: context.settings)
            Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            // Update UI only when app is frontmost, state changed, and Info/Buttons tab is visible.
            guard appIsFrontmost && infoViewVisible else { return }
            let keys = (0..<16).map { aux[$0] }
            if keys != self.liveButtons.expressKeys {
                self.liveButtons.expressKeys = keys
                context.liveButtons.expressKeys = keys
            }
            if aux.touchRingActive != self.liveButtons.touchRingActive {
                self.liveButtons.touchRingActive = aux.touchRingActive
                context.liveButtons.touchRingActive = aux.touchRingActive
            }
            if aux.touchRing2Active != self.liveButtons.touchRing2Active {
                self.liveButtons.touchRing2Active = aux.touchRing2Active
                context.liveButtons.touchRing2Active = aux.touchRing2Active
            }
            if aux.touchRingButtonDown != self.liveButtons.touchRingButtonDown {
                self.liveButtons.touchRingButtonDown = aux.touchRingButtonDown
                context.liveButtons.touchRingButtonDown = aux.touchRingButtonDown
            }
            if aux.touchStrip1Active != self.liveButtons.touchStrip1Active {
                self.liveButtons.touchStrip1Active = aux.touchStrip1Active
                context.liveButtons.touchStrip1Active = aux.touchStrip1Active
            }
            if aux.touchStrip2Active != self.liveButtons.touchStrip2Active {
                self.liveButtons.touchStrip2Active = aux.touchStrip2Active
                context.liveButtons.touchStrip2Active = aux.touchStrip2Active
            }
            } // end Task @MainActor
        }

        // ── Battery status closure ───────────────────────────────────────────
        // Called when a BT device reports its battery state (INTUOSP2_BT family).
        // Only fires when the raw battery byte changes — not on every pen report.
        // Called on HIDThread — hop to main.
        let onBattery: (Int, Bool) -> Void = { [weak self, weak context] percent, charging in
            Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            context.batteryPercent = percent
            context.batteryCharging = charging
            // Also update global for active context (backward compatibility)
            if self.activeContext === context {
                self.batteryPercent = percent
                self.batteryCharging = charging
            }
            } // end Task @MainActor
        }

        // ── USB HID mouse button closure (KC-100 cordless mouse) ────────────────
        // Called when a 4-byte Report ID 0x01 arrives from the mouse interface
        // (usagePage=0x01, seized).  Routes directly to the injector so buttons
        // fire at the current screen cursor position without a position remap.
        // Called on HIDThread; injectMouseButtons runs inline.
        let onMouseButton: (UInt8) -> Void = { [weak context] mask in
            guard let context else { return }
            context.injector.injectMouseButtons(mask: mask, settings: context.settings)
        }

        // ── Hardware serial closure (device unification) ─────────────────────
        // Called when a WACOM_REPORT_USB (Report ID 0x03) feature report query
        // succeeds on USB or wireless dongle. Serial is 0 if the query fails or
        // the device does not support Report ID 0x03 (e.g. old models).
        // Used to unify multi-transport variants of the same physical tablet.
        // Called on HIDThread — hop to main (DeviceRegistry is @MainActor).
        let onHardwareSerial: (UInt32) -> Void = { serial in
            Task { @MainActor in
                DeviceRegistry.shared.recordHardwareSerial(serial, forDevice: productID)
            }
        }

        // ── Create the device driver ─────────────────────────────────────────
        // Multi-interface devices (e.g. ACK-40401 dongle) enumerate separate
        // IOHIDDevices for each interface (digitizer, wireless status, touch,
        // etc). We create one driver per product and reuse it across
        // interfaces; each IOHIDDevice still registers independently for its
        // own reports.
        if let existingDriver = context.tabletDevice as? WacomKnownDevice {
            hidDeviceMap[device] = context
            existingDriver.registerDevice(device)
            return
        }

        // ── Relative wheel closure (IntuosV3 PTK-x70 scroll wheels) ────────────
        // Called on HIDThread; injectWheel runs inline (same threading contract
        // as injectAux).
        let onWheel: (Int, Int) -> Void = { [weak context] index, delta in
            guard let context else { return }
            context.injector.injectWheel(index: index, delta: delta, settings: context.settings)
        }

        // ── Touch closure (capacitive finger input on touch-capable Cintiqs) ───
        // Called on HIDThread when a decoder emits a `.touch` result.  When
        // touch is disabled in settings, return early — the hardware switch
        // on PTH-660/860 streams 0x21 reports at ~100 Hz, and publishing
        // them to `liveTouchContacts` invalidates every view that observes
        // `TabletManager` (which is every settings pane), making the UI
        // choppy and burning CPU even though no input is being injected.
        let onTouch: ([TouchContact]) -> Void = { [weak self, weak context] contacts in
            guard let context, context.settings.touchEnabled else { return }
            context.injector.injectTouch(contacts: contacts, settings: context.settings)
            // Skip the publish path entirely when no UI is observing — the
            // scratchpad sets `isPublishingEnabled` only while it is the
            // active tab and the app is frontmost.
            guard let self else { return }
            let publisher = self.liveTouch
            guard publisher.isPublishingEnabled else { return }
            // Throttle the live-contacts publish to ~30 Hz.  Always let the
            // "empty" frame through so a finger lift updates the UI promptly.
            let now = CFAbsoluteTimeGetCurrent()
            let elapsed = now - publisher.lastPublishTime
            if !contacts.isEmpty && elapsed < LiveTouchPublisher.publishInterval { return }
            publisher.lastPublishTime = now
            DispatchQueue.main.async {
                publisher.contacts = contacts
            }
        }

        let callbacks = DeviceRouter.Callbacks(
            onTablet: onTablet, onAux: onAux, onToolEnter: onToolEnter,
            onMouseButton: onMouseButton, onBattery: onBattery,
            onHardwareSerial: onHardwareSerial, onWheel: onWheel,
            onTouch: onTouch)

        switch DeviceRouter.route(
            device: device, productID: productID, usagePage: usagePage,
            isBLE: isBLE, contexts: contexts, callbacks: callbacks)
        {
        case .deferred:
            pendingInterfaces[productID, default: []].append(device)
            return

        case .ledCompanion(let parentCtx):
            if let driver = parentCtx.tabletDevice as? WacomKnownDevice {
                driver.registerLEDDevice(device)
                hidDeviceMap[device] = parentCtx
            }
            return

        case .skip:
            return

        case .driver(let wacomDevice, _):
            context.tabletDevice = wacomDevice
            hidDeviceMap[device] = context
            wacomDevice.open()
            // Drain any interfaces that arrived before this driver was created.
            for pending in pendingInterfaces.removeValue(forKey: productID) ?? [] {
                hidDeviceMap[pending] = context
                (wacomDevice as? WacomKnownDevice)?.registerDevice(pending)
            }
            context.observeRingLED()  // after open() so initial LED sync reaches the device
            context.observeInjectionSnapshot()
            context.settings.applyExpressKeyDefaults()
            refreshConnectedIDs(mostRecent: productID)

            if productID == 0x00F4 {
                let prefix = "device-0x\(String(productID, radix: 16, uppercase: true))."
                if UserDefaults.standard.object(forKey: prefix + "proportionalMapping") == nil {
                    context.settings.applyPenDisplayDefaults(width: 1920, height: 1200)
                }
            }

            if activeContext == nil { activeContext = context }

            let usbSerial =
                IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
            DeviceRegistry.shared.recordTablet(productID: productID, usbSerial: usbSerial)
        }
    }

    private func deviceDisconnected(_ device: IOHIDDevice) {
        guard let context = hidDeviceMap.removeValue(forKey: device) else { return }
        context.tabletDevice?.close()
        context.tabletDevice = nil
        context.hidDevice = nil
        // Clear per-device state
        context.isConnected = false
        context.transport = "—"
        context.usbSpeed = "—"
        context.batteryPercent = nil
        context.batteryCharging = false
        context.activeToolID = nil
        context.activeToolCode = 0
        context.livePoint = nil
        context.liveButtons = LiveButtonState()
        logger.info("TabletManager: \(Self.deviceName(forProductID: context.productID), privacy: .public) disconnected")
        refreshConnectedIDs(mostRecent: nil)
        if activeContext === context {
            activeContext = hidDeviceMap.values.first
            batteryPercent = nil
            batteryCharging = false
        }
    }

    private func refreshConnectedIDs(mostRecent: Int?) {
        connectedProductIDs = hidDeviceMap.values.map { $0.productID }.sorted()
        isConnected = !connectedProductIDs.isEmpty
        if let pid = mostRecent, connectedProductIDs.contains(pid) {
            connectedProductID = pid
        } else {
            connectedProductID = connectedProductIDs.last ?? 0
        }
        if let primary = hidDeviceMap.keys.first(where: {
            hidIntProperty($0, kIOHIDProductIDKey) == connectedProductID
        }) {
            let info = Self.connectionInfo(for: primary)
            connectedTransport = info.transport
            connectedUSBSpeed = info.speed
        } else {
            connectedTransport = "—"
            connectedUSBSpeed = "—"
        }
    }

    private static func connectionInfo(
        for device: IOHIDDevice
    ) -> (transport: String, speed: String) {
        let transport =
            IOHIDDeviceGetProperty(
                device, kIOHIDTransportKey as CFString) as? String ?? "Unknown"
        guard transport.caseInsensitiveCompare("USB") == .orderedSame else {
            return (transport, "—")
        }
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return ("USB", "USB") }
        for key in ["USB Device Speed", "Device Speed"] as [CFString] {
            if let prop = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, key, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            ) {
                if let n = (prop as? NSNumber)?.intValue {
                    switch n {
                    case 0: return ("USB", "Low Speed (1.5 Mb/s)")
                    case 1: return ("USB", "Full Speed (12 Mb/s)")
                    case 2: return ("USB", "High Speed (480 Mb/s)")
                    case 3: return ("USB", "SuperSpeed (5 Gb/s)")
                    default: break
                    }
                }
            }
        }
        return ("USB", "USB")
    }
}
