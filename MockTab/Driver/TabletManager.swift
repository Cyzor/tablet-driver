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

import Foundation
import IOKit.hid

/// Manages IOHIDManager lifecycle, per-device contexts, and proximity-based
/// activation for multi-tablet support.
///
/// Each connected tablet gets its own `DeviceContext` (settings, injector,
/// driver).  Only the *active* context posts CGEvents — activation happens
/// automatically when a pen enters proximity on a given tablet.
///
/// @MainActor because all IOHIDManager callbacks are scheduled on
/// CFRunLoopGetMain() = main thread.
@MainActor
final class TabletManager: ObservableObject {

    static let shared = TabletManager()

    private let manager: IOHIDManager

    // MARK: - Per-device state

    @Published var contexts: [Int: DeviceContext] = [:]
    @Published var activeContext: DeviceContext? = nil
    @Published var activeToolID: String? = nil
    @Published var liveButtons = LiveButtonState()
    @Published var livePoint: TabletPoint? = nil

    private var hidDeviceMap: [IOHIDDevice: DeviceContext] = [:]
    private var shimObservers: [NSObjectProtocol] = []

    // MARK: - Legacy published state

    @Published var isConnected = false
    @Published var connectedProductID: Int = 0
    @Published var connectedProductIDs: [Int] = []
    @Published var connectedTransport: String = "—"
    @Published var connectedUSBSpeed: String = "—"
    @Published var hidManagerOpen: Bool = false

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
                Unmanaged<TabletManager>.fromOpaque(ctx).takeUnretainedValue()
                    .deviceConnected(device)
            }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            { ctx, _, _, device in
                guard let ctx else { return }
                Unmanaged<TabletManager>.fromOpaque(ctx).takeUnretainedValue()
                    .deviceDisconnected(device)
            }, ctx)

        setupShimBridge()
        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetMain(), RunLoop.Mode.common.rawValue as CFString)
        let ret = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManagerOpen = (ret == kIOReturnSuccess)
        if !hidManagerOpen {
            print(
                "TabletManager: failed to open HID manager (\(ret)). "
                    + "Check Input Monitoring permission or uninstall any existing tablet driver.")
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
            self?.activeContext?.injector.replayPointerEvent()
        }
        let proximity = dn.addObserver(
            forName: NSNotification.Name("com.cyzor.mocktab.shim.replayProximity"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.activeContext?.injector.replayProximityEvent()
        }
        shimObservers = [pointer, proximity]
    }

    func stop() {
        let dn = DistributedNotificationCenter.default()
        for obs in shimObservers { dn.removeObserver(obs) }
        shimObservers.removeAll()
        IOHIDManagerUnscheduleFromRunLoop(
            manager, CFRunLoopGetMain(), RunLoop.Mode.common.rawValue as CFString)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        for (_, ctx) in hidDeviceMap { ctx.tabletDevice?.close() }
        hidDeviceMap.removeAll()
        contexts.removeAll()
        activeContext = nil
    }

    // MARK: - Device lifecycle

    private func deviceConnected(_ device: IOHIDDevice) {
        let productID = hidIntProperty(device, kIOHIDProductIDKey)
        let usagePage = hidIntProperty(device, kIOHIDPrimaryUsagePageKey)
        let usage = hidIntProperty(device, kIOHIDPrimaryUsageKey)
        let maxRptSize = hidIntProperty(device, kIOHIDMaxInputReportSizeKey)
        let transport =
            IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        let isBLE = transport.lowercased().contains("bluetooth")
        print(
            "TabletManager: device pid=0x\(String(productID, radix:16)) usagePage=0x\(String(usagePage, radix:16)) usage=0x\(String(usage, radix:16)) maxRptSize=\(maxRptSize) transport=\(transport)"
        )

        // BLE tablets expose multiple interfaces. Log all of them; skip ghost mouse only.
        if isBLE && usagePage == 0x01 {
            print(
                "TabletManager: BLE usagePage=0x01 interface — maxRptSize=\(maxRptSize) usage=0x\(String(usage, radix:16)) — skipping ghost mouse"
            )
            return
        }

        let context = contexts[productID] ?? DeviceContext(productID: productID)
        contexts[productID] = context
        context.hidDevice = device

        // ── Tool-enter closure (IntuosV2 only) ──────────────────────────────
        let onToolEnter: (ToolIdentity) -> Void = { [weak self, weak context] identity in
            guard let self, let context else { return }
            context.activeToolSerial = identity.serial
            context.activeToolIsMouse = identity.isMouse
            let toolID = DeviceRegistry.shared.recordTool(identity: identity, forDevice: productID)
            let toolSets = context.settings.toolSettings(forID: toolID, isMouse: identity.isMouse)
            context.activeTool = toolSets
            context.injector.activeToolSettings = toolSets
            context.injector.activeToolIsMouse = identity.isMouse
            self.activeToolID = toolID
        }

        // ── Tablet point closure ─────────────────────────────────────────────
        let onTablet: (TabletPoint) -> Void = { [weak self, weak context] point in
            guard let self, let context else { return }

            // Proximity-enter activates this device's context.
            if point.inProximity && self.activeContext !== context {
                if let old = self.activeContext, old.injector.lastProximity {
                    let exitPoint = TabletPoint(
                        x: 0, y: 0, maxX: 1, maxY: 1,
                        pressure: 0, maxPressure: 1,
                        tiltX: 0, tiltY: 0,
                        penButton1: false, penButton2: false,
                        eraser: false, inProximity: false, hoverDistance: 0)
                    old.injector.inject(point: exitPoint, settings: old.settings)
                }
                self.activeContext = context
            }

            // Proximity-exit from a non-active device: still post so apps
            // don't get stuck with a dangling proximity state.
            if !point.inProximity && context.injector.lastProximity {
                context.injector.inject(point: point, settings: context.settings)
                return
            }

            // Only the active context posts normal events.
            guard self.activeContext === context else { return }

            // ── CGEvent injection — never throttled ──────────────────────────
            context.injector.inject(point: point, settings: context.settings)

            // ── UI state — gated + throttled ─────────────────────────────────
            // Proximity exit always clears state immediately, regardless of app foreground/tab visibility.
            if !point.inProximity {
                self.uiUpdateCounter = 0
                self.activeToolID = nil
                self.liveButtons = LiveButtonState()
                self.livePoint = nil
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
                expressKeys: self.liveButtons.expressKeys
            )
            // Only assign when values changed — avoids spurious objectWillChange.
            if newButtons != self.liveButtons { self.liveButtons = newButtons }
            self.livePoint = point
        }

        // ── Express key closure ──────────────────────────────────────────────
        let onAux: (AuxButtons) -> Void = { [weak self, weak context] aux in
            guard let self, let context else { return }
            // Inject immediately — no throttle on actual key events.
            context.injector.injectAux(buttons: aux, settings: context.settings)
            // Update UI only when app is frontmost, state changed, and Info/Buttons tab is visible.
            guard appIsFrontmost && infoViewVisible else { return }
            let keys = (0..<16).map { aux[$0] }
            if keys != self.liveButtons.expressKeys {
                self.liveButtons.expressKeys = keys
            }
            if aux.touchRingActive != self.liveButtons.touchRingActive {
                self.liveButtons.touchRingActive = aux.touchRingActive
            }
            if aux.touchRing2Active != self.liveButtons.touchRing2Active {
                self.liveButtons.touchRing2Active = aux.touchRing2Active
            }
            if aux.touchRingButtonDown != self.liveButtons.touchRingButtonDown {
                self.liveButtons.touchRingButtonDown = aux.touchRingButtonDown
            }
            if aux.touchStrip1Active != self.liveButtons.touchStrip1Active {
                self.liveButtons.touchStrip1Active = aux.touchStrip1Active
            }
            if aux.touchStrip2Active != self.liveButtons.touchStrip2Active {
                self.liveButtons.touchStrip2Active = aux.touchStrip2Active
            }
        }

        // ── USB HID mouse button closure (KC-100 cordless mouse) ────────────────
        // Called when a 4-byte Report ID 0x01 arrives from the mouse interface
        // (usagePage=0x01, seized).  Routes directly to the injector so buttons
        // fire at the current screen cursor position without a position remap.
        let onMouseButton: (UInt8) -> Void = { [weak context] mask in
            guard let context else { return }
            context.injector.injectMouseButtons(mask: mask, settings: context.settings)
        }

        // ── Create the device driver ─────────────────────────────────────────
        let wacomDevice: (any TabletDevice)?

        switch productID {
        case 0x00F4:
            print("TabletManager: DTK-2400 (Cintiq 24HD) connected")
            wacomDevice = DTK2400Device(
                device: device, onTablet: onTablet, onAux: onAux, onToolEnter: onToolEnter)

        case 0x0084:
            // ACK-40401 RF wireless dongle — presents the same HID interfaces and
            // descriptor as the paired tablet (PTH-x50/x51 family, IntuosV1 format).
            // Query the descriptor now; the RF link may not be established yet so
            // pen events are gated until the 0x80 wireless status report with d[1] bit 0 set.
            print("TabletManager: ACK-40401 wireless dongle connected")
            let (dMaxX, dMaxY, dMaxP, _) = queryHIDDigitizerSpec(device)
            let dongleSpec = WacomDeviceSpec(
                productID: 0x0084,
                name: "ACK-40401 Wireless Dongle",
                parser: .intuosV1,
                maxX: dMaxX, maxY: dMaxY, maxPressure: dMaxP,
                buttonCount: 8, hasTouchRing: true, hasEraser: true,
                featureInit: [0x02, 0x02], seizeUSB: false)
            wacomDevice = WacomUniversalDevice(
                device: device, deviceSpec: dongleSpec, isWireless: true,
                onTablet: onTablet, onAux: onAux, onToolEnter: onToolEnter)

        default:
            // For any recognised PID with a live decoder and a valid spec, use
            // WacomUniversalDevice.  Stub families (Graphire, Bamboo) and truly
            // unrecognised PIDs fall through to WacomGenericDevice.
            if let deviceSpec = WacomDeviceRegistry.spec(for: productID),
                WacomDeviceRegistry.hasLiveDecoder(for: productID),
                deviceSpec.maxX > 0
            {
                let shouldSeize = !isBLE && deviceSpec.seizeUSB && usagePage == 0x01
                print(
                    "TabletManager: \(deviceSpec.name) connected via universal driver"
                        + (shouldSeize ? " (mouse interface, seized)" : ""))
                wacomDevice = WacomUniversalDevice(
                    device: device, deviceSpec: deviceSpec, seize: shouldSeize,
                    onTablet: onTablet, onAux: onAux, onToolEnter: onToolEnter,
                    onMouseButton: shouldSeize ? onMouseButton : nil)
            } else {
                let pid = String(productID, radix: 16, uppercase: true)
                print("TabletManager: unknown Wacom 0x\(pid) — attaching generic driver")
                wacomDevice = WacomGenericDevice(
                    device: device, onTablet: onTablet, onAux: onAux, onToolEnter: onToolEnter)
            }
        }

        if let wacomDevice {
            context.tabletDevice = wacomDevice
            hidDeviceMap[device] = context
            wacomDevice.open()
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
        print("TabletManager: \(Self.deviceName(forProductID: context.productID)) disconnected")
        refreshConnectedIDs(mostRecent: nil)
        if activeContext === context {
            activeContext = hidDeviceMap.values.first
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
