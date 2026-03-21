import Foundation
import IOKit.hid

/// Manages IOHIDManager lifecycle and dispatches reports to InputInjector.
/// @MainActor because all IOHIDManager callbacks are scheduled on CFRunLoopGetMain() = main thread.
@MainActor
final class TabletManager: ObservableObject {

    static let shared = TabletManager()

    private let manager: IOHIDManager
    private var devices: [IOHIDDevice: any TabletDevice] = [:]

    @Published var isConnected = false
    @Published var connectedProductID: Int = 0   // most recently connected device
    @Published var connectedProductIDs: [Int] = [] // all currently connected devices

    /// Human-readable name for a product ID, including a hex fallback for unknowns.
    static func deviceName(forProductID pid: Int) -> String {
        switch pid {
        case 0x0317: return "PTH-851"
        case 0x0357: return "PTH-660"
        case 0x0358: return "PTH-860"
        case 0x00B5: return "PTZ-631W"
        default:     return "Wacom 0x\(String(pid, radix: 16, uppercase: true))"
        }
    }

    var connectedDeviceName: String {
        switch connectedProductIDs.count {
        case 0:  return "No tablet"
        case 1:  return Self.deviceName(forProductID: connectedProductIDs[0])
        default:
            let first = Self.deviceName(forProductID: connectedProductIDs[0])
            return "\(first) + \(connectedProductIDs.count - 1) more"
        }
    }

    weak var settings: TabletSettings?
    var injector: InputInjector?

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

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            let mgr = Unmanaged<TabletManager>.fromOpaque(ctx).takeUnretainedValue()
            mgr.deviceConnected(device)
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            let mgr = Unmanaged<TabletManager>.fromOpaque(ctx).takeUnretainedValue()
            mgr.deviceDisconnected(device)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), RunLoop.Mode.common.rawValue as CFString)
        let ret = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if ret != kIOReturnSuccess {
            print("TabletManager: failed to open HID manager (\(ret)). " +
                  "Check Input Monitoring permission or uninstall any existing tablet driver.")
        }
    }

    func stop() {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), RunLoop.Mode.common.rawValue as CFString)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        for (_, dev) in devices { dev.close() }
        devices.removeAll()
    }

    // MARK: - Device lifecycle

    private func deviceConnected(_ device: IOHIDDevice) {
        let productID = hidIntProperty(device, kIOHIDProductIDKey)

        let onTablet: (TabletPoint) -> Void = { [weak self] point in
            guard let self else { return }
            self.injector?.inject(point: point, settings: self.settings)
        }

        let onAux: (AuxButtons) -> Void = { [weak self] aux in
            guard let self else { return }
            self.injector?.injectAux(buttons: aux, settings: self.settings)
        }

        let wacomDevice: (any TabletDevice)?
        switch productID {
        case 0x0317:
            print("TabletManager: PTH-851 connected")
            wacomDevice = PTH851Device(device: device, onTablet: onTablet)
        case 0x0357:
            print("TabletManager: PTH-660 connected")
            wacomDevice = PTH660Device(device: device, onTablet: onTablet, onAux: onAux)
        case 0x0358:
            print("TabletManager: PTH-860 connected")
            wacomDevice = PTH860Device(device: device, onTablet: onTablet, onAux: onAux)
        case 0x00B5:
            print("TabletManager: PTZ-631W connected")
            wacomDevice = PTZ631WDevice(device: device, onTablet: onTablet, onAux: onAux)
        default:
            print("TabletManager: unsupported Wacom product 0x\(String(productID, radix: 16, uppercase: true)) — add a device class to support it")
            return
        }

        if let wacomDevice {
            devices[device] = wacomDevice
            // Tell the injector which physical device is active so it can populate
            // proximity events with the correct vendorID / productID.  Apps like
            // Krita, GIMP, Photoshop and Affinity use these fields to register the
            // virtual tablet and then route pressure to their tablet input path.
            injector?.deviceVendorID  = 0x056A   // Wacom Co., Ltd.
            injector?.deviceProductID = productID
            wacomDevice.open()
            refreshConnectedIDs(mostRecent: productID)
        }
    }

    private func deviceDisconnected(_ device: IOHIDDevice) {
        guard let wacomDevice = devices.removeValue(forKey: device) else { return }
        wacomDevice.close()
        print("TabletManager: \(type(of: wacomDevice)) disconnected")
        refreshConnectedIDs(mostRecent: nil)
    }

    /// Recomputes `connectedProductIDs` / `isConnected` / `connectedProductID` from the live
    /// `devices` dict.  `mostRecent` pins `connectedProductID` to the just-connected product so
    /// the UI auto-selects it even when multiple tablets are present.
    private func refreshConnectedIDs(mostRecent: Int?) {
        connectedProductIDs = devices.keys
            .map { hidIntProperty($0, kIOHIDProductIDKey) }
            .sorted()
        isConnected = !connectedProductIDs.isEmpty
        if let pid = mostRecent, connectedProductIDs.contains(pid) {
            connectedProductID = pid
        } else {
            connectedProductID = connectedProductIDs.last ?? 0
        }
    }
}
