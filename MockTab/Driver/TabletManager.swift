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

    /// Set true by SettingsWindowController when the Info tab is frontmost.
    /// When false, livePoint and liveButtons are never written, eliminating
    /// all SwiftUI rendering overhead while other tabs or no window is open.
    var infoViewVisible: Bool = false

    private var uiUpdateCounter = 0
    private static let uiUpdateInterval = 8   // every 8th report ≈ 16 Hz at 133 Hz

    // MARK: - Device name helpers

    static func deviceName(forProductID pid: Int) -> String {
        switch pid {
        case 0x0317: return "PTH-851"
        case 0x0357: return "PTH-660"
        case 0x0358: return "PTH-860"
        case 0x00B5: return "PTZ-631W"
        case 0x00F4: return "DTK-2400"
        case 0x0084: return "Wireless Dongle"
        default: return "Wacom 0x\(String(pid, radix: 16, uppercase: true))"
        }
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
        set { /* no-op: settings are now per-context */ }
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

    func stop() {
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
        let productID    = hidIntProperty(device, kIOHIDProductIDKey)
        let usagePage    = hidIntProperty(device, kIOHIDPrimaryUsagePageKey)
        let usage        = hidIntProperty(device, kIOHIDPrimaryUsageKey)
        let maxRptSize   = hidIntProperty(device, kIOHIDMaxInputReportSizeKey)
        print("TabletManager: device pid=0x\(String(productID, radix:16)) usagePage=0x\(String(usagePage, radix:16)) usage=0x\(String(usage, radix:16)) maxRptSize=\(maxRptSize)")

        let context = contexts[productID] ?? DeviceContext(productID: productID)
        contexts[productID] = context
        context.hidDevice = device

        // ── Tool-enter closure (IntuosV2 only) ──────────────────────────────
        let onToolEnter: (ToolIdentity) -> Void = { [weak self, weak context] identity in
            guard let self, let context else { return }
            context.activeToolSerial           = identity.serial
            context.activeToolIsMouse          = identity.isMouse
            DeviceRegistry.shared.recordTool(identity: identity, forDevice: productID)
            let toolID   = DeviceRegistry.toolID(for: identity)
            let toolSets = context.settings.toolSettings(forID: toolID, isMouse: identity.isMouse)
            context.activeTool                  = toolSets
            context.injector.activeToolSettings = toolSets
            context.injector.activeToolIsMouse  = identity.isMouse
            self.activeToolID = toolID
        }

        // ── Tablet point closure ─────────────────────────────────────────────
        let onTablet: (TabletPoint) -> Void = { [weak self, weak context] point in
            guard let self, let context else { return }

            // Record tool type for devices that don't fire onToolEnter.
            // All current drivers fire onToolEnter except PTH-850 (legacy, no onToolEnter closure).
            if point.inProximity && productID == 0x0028 {
                let identity = ToolIdentity(
                    serial: 0,
                    toolCode: point.eraser ? 0x080A : 0x0802,
                    isEraser: point.eraser,
                    isMouse: false)
                DeviceRegistry.shared.recordTool(identity: identity, forDevice: productID)
                self.activeToolID = DeviceRegistry.toolID(for: identity)
            }

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
            // Skip entirely when the Info tab isn't visible.  This eliminates
            // every @Published write — and therefore every SwiftUI invalidation —
            // during normal drawing use.
            guard infoViewVisible else { return }

            if !point.inProximity {
                // Proximity exit always publishes immediately so UI clears.
                self.uiUpdateCounter = 0
                self.activeToolID    = nil
                self.liveButtons     = LiveButtonState()
                self.livePoint       = nil
            } else {
                // Throttle continuous updates to ~16 Hz.
                self.uiUpdateCounter += 1
                guard self.uiUpdateCounter >= Self.uiUpdateInterval else { return }
                self.uiUpdateCounter = 0

                let toolIsMouse = context.activeToolIsMouse
                let tipDown     = toolIsMouse ? point.penButton1 : point.normalizedPressure > 0.004
                let newButtons = LiveButtonState(
                    tipDown:     tipDown && !point.eraser,
                    eraserDown:  tipDown && point.eraser,
                    button1Down: point.penButton1,
                    button2Down: point.penButton2,
                    expressKeys: self.liveButtons.expressKeys
                )
                // Only assign when values changed — avoids spurious objectWillChange.
                if newButtons != self.liveButtons { self.liveButtons = newButtons }
                self.livePoint = point
            }
        }

        // ── Express key closure ──────────────────────────────────────────────
        let onAux: (AuxButtons) -> Void = { [weak self, weak context] aux in
            guard let self, let context else { return }
            // Inject immediately — no throttle on actual key events.
            context.injector.injectAux(buttons: aux, settings: context.settings)
            // Update UI only when state changed and Info tab is visible.
            guard infoViewVisible else { return }
            let keys = (0..<8).map { aux[$0] }
            if keys != self.liveButtons.expressKeys {
                self.liveButtons.expressKeys = keys
            }
        }

        // ── Create the device driver ─────────────────────────────────────────
        let wacomDevice: (any TabletDevice)?

        switch productID {
        case 0x0317:
            print("TabletManager: PTH-851 connected")
            wacomDevice = PTH851Device(
                device: device, onTablet: onTablet, onAux: onAux, onToolEnter: onToolEnter)

        case 0x0028:
            print("TabletManager: PTH-850 (Intuos Pro Medium) connected")
            wacomDevice = PTH850Device(
                device: device, onTablet: onTablet, onAux: onAux, onToolEnter: nil)

        case 0x0357:
            print("TabletManager: PTH-660 connected")
            // Seize the standard-mouse interface (usagePage=0x01) so the kernel's HID
            // mouse driver doesn't consume button/wheel reports before we see them.
            // The vendor-specific interface (0xFF00) is opened non-exclusively.
            let shouldSeize = (usagePage == 0x01)
            wacomDevice = PTH660Device(
                device: device, seize: shouldSeize,
                onTablet: onTablet, onAux: onAux, onToolEnter: onToolEnter)

        case 0x0358:
            print("TabletManager: PTH-860 connected")
            wacomDevice = PTH860Device(
                device: device, onTablet: onTablet, onAux: onAux, onToolEnter: onToolEnter)

        case 0x00B5:
            print("TabletManager: PTZ-631W connected")
            wacomDevice = PTZ631WDevice(
                device: device, onTablet: onTablet, onAux: onAux, onToolEnter: onToolEnter)

        case 0x00F4:
            print("TabletManager: DTK-2400 (Cintiq 24HD) connected")
            wacomDevice = DTK2400Device(
                device: device, onTablet: onTablet, onAux: onAux, onToolEnter: onToolEnter)

        case 0x0084:
            // ACK-40401 RF wireless dongle — presents same HID interfaces as the
            // paired tablet.  WacomGenericDevice auto-detects IntuosV1 format and
            // handles the wireless status report (0x80).
            print("TabletManager: ACK-40401 wireless dongle connected")
            wacomDevice = WacomGenericDevice(
                device: device, onTablet: onTablet, onAux: onAux, onToolEnter: onToolEnter)

        default:
            let pid = String(productID, radix: 16, uppercase: true)
            print("TabletManager: unknown Wacom 0x\(pid) — attaching generic driver")
            wacomDevice = WacomGenericDevice(
                device: device, onTablet: onTablet, onAux: onAux, onToolEnter: onToolEnter)
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
        context.hidDevice    = nil
        print("TabletManager: \(Self.deviceName(forProductID: context.productID)) disconnected")
        refreshConnectedIDs(mostRecent: nil)
        if activeContext === context {
            activeContext = hidDeviceMap.values.first
        }
    }

    private func refreshConnectedIDs(mostRecent: Int?) {
        connectedProductIDs = hidDeviceMap.values.map { $0.productID }.sorted()
        isConnected         = !connectedProductIDs.isEmpty
        if let pid = mostRecent, connectedProductIDs.contains(pid) {
            connectedProductID = pid
        } else {
            connectedProductID = connectedProductIDs.last ?? 0
        }
        if let primary = hidDeviceMap.keys.first(where: {
            hidIntProperty($0, kIOHIDProductIDKey) == connectedProductID
        }) {
            let info           = Self.connectionInfo(for: primary)
            connectedTransport = info.transport
            connectedUSBSpeed  = info.speed
        } else {
            connectedTransport = "—"
            connectedUSBSpeed  = "—"
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
