// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026  This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab.  If not, see <https://www.gnu.org/licenses/>.

import AppKit
import Foundation
import IOKit.hid
import OSLog

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "manager")

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
    @Published var appIsFrontmost: Bool = false

    /// Set true by SettingsWindowController when the Info or Buttons tab is frontmost
    /// in the active window. Combined with appIsFrontmost: both must be true to update
    /// livePoint/liveButtons, eliminating all SwiftUI overhead when MockTab is in the
    /// background or a different tab is active.
    var infoViewVisible: Bool = false

    /// Optional raw-data callback for calibration. When set, every active-context
    /// TabletPoint is forwarded here *in addition to* the normal injection path.
    var calibrationPointHandler: ((TabletPoint) -> Void)?

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

        let matching: [String: Any] = [kIOHIDVendorIDKey: 0x056A as NSNumber]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

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
        let rawProductID = hidIntProperty(device, kIOHIDProductIDKey)
        let productID = WacomDeviceRegistry.canonicalProductID(for: rawProductID)
        let usagePage = hidIntProperty(device, kIOHIDPrimaryUsagePageKey)
        let usage = hidIntProperty(device, kIOHIDPrimaryUsageKey)
        let maxRptSize = hidIntProperty(device, kIOHIDMaxInputReportSizeKey)
        let transport =
            IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        let isBLE = transport.lowercased().contains("bluetooth")
        let pidStr =
            rawProductID == productID
            ? "0x\(String(productID, radix:16))"
            : "0x\(String(rawProductID, radix:16)) → 0x\(String(productID, radix:16))"
        logger.info("TabletManager: device pid=\(pidStr, privacy: .public) usagePage=0x\(String(usagePage, radix:16), privacy: .public) usage=0x\(String(usage, radix:16), privacy: .public) maxRptSize=\(maxRptSize, privacy: .public) transport=\(transport, privacy: .public)")

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
            if injector.isActive {
                injector.inject(point: point, settings: context.settings)
            }

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
        // Multi-interface devices (e.g. ACK-40401 dongle) enumerate separate IOHIDDevices
        // for each interface (digitizer, wireless status, touch, etc). We create one driver
        // for the product and reuse it for all interfaces. Each IOHIDDevice still registers
        // independently for its own reports.
        if let existingDriver = context.tabletDevice as? WacomKnownDevice {
            // Already have a driver for this product; register this interface for reports.
            hidDeviceMap[device] = context
            existingDriver.registerDevice(device)
            return
        }

        let wacomDevice: (any TabletDevice)?

        switch productID {
        case 0x0084:
            // ACK-40401 RF wireless dongle — presents the same HID interfaces and
            // descriptor as the paired tablet (PTH-x50/x51 family, IntuosV1 format).
            // Query the descriptor now; the RF link may not be established yet so
            // pen events are gated until the 0x80 wireless status report with d[1] bit 0 set.
            logger.info("TabletManager: ACK-40401 wireless dongle connected")
            let (dMaxX, dMaxY, dMaxP, _) = queryHIDDigitizerSpec(device)
            let dongleSpec = WacomDeviceSpec(
                productID: 0x0084,
                name: "ACK-40401 Wireless Dongle",
                parser: .intuosV1,
                maxX: dMaxX, maxY: dMaxY, maxPressure: dMaxP,
                buttonCount: 8, hasTouchRing: true, hasEraser: true,
                featureInit: [0x02, 0x02], seizeUSB: false)
            wacomDevice = WacomKnownDevice(
                device: device, deviceSpec: dongleSpec, isWireless: true,
                onTablet: onTablet, onAux: onAux, onToolEnter: onToolEnter,
                onHardwareSerial: onHardwareSerial)

        default:
            // For any recognised PID with a live decoder and a valid spec, use
            // WacomKnownDevice.  Stub families (Graphire, Bamboo) and truly
            // unrecognised PIDs fall through to WacomFallbackDevice.
            if let deviceSpec = WacomDeviceRegistry.spec(for: productID),
                WacomDeviceRegistry.hasLiveDecoder(for: productID),
                deviceSpec.maxX > 0
            {
                // Interface routing depends on parser family.
                //
                // IntuosV2 (PTH-x60/x80):  0xFF00 vendor interface is primary (featureInit
                //   via InputMode element).  0x01 is deferred and registered as secondary without
                //   seizure — seizing 0x01 stops the IntuosV2 firmware from sending pen reports.
                //
                // CintiqV1 (DTK-2400 etc): 0x01 is the pen digitizer (reports 0x02, 0x0C).
                //   It must be seized so the OS doesn't interpret tip-switch as a native click,
                //   and featureInit [0x02, 0x02] must be sent there to activate tablet mode.
                //   0xFF00 only carries the periodic 0x80 status report; defer it until 0x01
                //   has created the driver, then register it as secondary.
                let isCintiqV1 = deviceSpec.parser == .cintiqV1
                let deferrableInterface: Bool
                if isCintiqV1 {
                    // Defer the vendor interface; wait for the digitizer (0x01) to be primary.
                    deferrableInterface = !isBLE && deviceSpec.seizeUSB && usagePage == 0xFF00
                } else {
                    // Defer the mouse interface; wait for the vendor interface (0xFF00) to be primary.
                    deferrableInterface = !isBLE && deviceSpec.seizeUSB && usagePage == 0x01
                }
                if deferrableInterface {
                    logger.info("TabletManager: \(deviceSpec.name, privacy: .public) — deferring 0x\(String(usagePage, radix: 16), privacy: .public) interface")
                    pendingInterfaces[productID, default: []].append(device)
                    return
                }
                // For CintiqV1 with 0x01 as primary: seize the interface so the OS cannot
                // interpret tip-switch (report 0x01) as a native left-click alongside our events.
                let shouldSeize = !isBLE && isCintiqV1 && deviceSpec.seizeUSB && usagePage == 0x01
                logger.info("TabletManager: \(deviceSpec.name, privacy: .public) connected via universal driver\(shouldSeize ? " (seized)" : "", privacy: .public)")
                wacomDevice = WacomKnownDevice(
                    device: device, deviceSpec: deviceSpec, seize: shouldSeize,
                    onTablet: onTablet, onAux: onAux, onToolEnter: onToolEnter,
                    onMouseButton: onMouseButton,
                    onBattery: onBattery, onHardwareSerial: onHardwareSerial)
            } else {
                let pid = String(productID, radix: 16, uppercase: true)
                // Probe HID descriptor before attaching a fallback driver.
                // If the device has no X/Y digitizer elements (maxX == 0), it is
                // a non-input interface (e.g. LED controller, status interface) and
                // should not receive feature-init reports or be treated as a tablet.
                let (probeX, _, _, _) = queryHIDDigitizerSpec(device)
                if probeX > 0 {
                    logger.info("TabletManager: unknown Wacom 0x\(pid, privacy: .public) — attaching generic driver")
                    wacomDevice = WacomFallbackDevice(
                        device: device, onTablet: onTablet, onAux: onAux, onToolEnter: onToolEnter)
                } else {
                    // No digitizer — check if this is a known LED companion interface.
                    // If a WacomKnownDevice for the parent tablet is already running,
                    // hand the device off for LED control rather than skipping it entirely.
                    let matched = contexts.values.first {
                        guard $0.tabletDevice is WacomKnownDevice,
                              let companionPID = WacomDeviceRegistry.spec(for: $0.productID)?.ledCompanionPID
                        else { return false }
                        return companionPID == productID
                    }
                    if let ctx = matched, let driver = ctx.tabletDevice as? WacomKnownDevice {
                        logger.info("TabletManager: Wacom 0x\(pid, privacy: .public) — LED companion for \(ctx.productID == 0 ? "unknown" : String(ctx.productID, radix: 16, uppercase: true), privacy: .public)")
                        driver.registerLEDDevice(device)
                        hidDeviceMap[device] = ctx
                    } else {
                        logger.debug("TabletManager: Wacom 0x\(pid, privacy: .public) — no digitizer elements, skipping")
                    }
                    wacomDevice = nil
                }
            }
        }

        if let wacomDevice {
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
