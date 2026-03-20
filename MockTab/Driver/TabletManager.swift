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

        let wacomDevice: (any TabletDevice)?
        switch productID {
        case 0x0317:
            print("TabletManager: PTH-851 connected")
            wacomDevice = PTH851Device(device: device, onTablet: onTablet)
        case 0x0358:
            print("TabletManager: PTH-860 connected")
            wacomDevice = PTH860Device(device: device, onTablet: onTablet)
        default:
            print("TabletManager: unsupported product 0x\(String(productID, radix: 16))")
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
            isConnected = true
        }
    }

    private func deviceDisconnected(_ device: IOHIDDevice) {
        guard let wacomDevice = devices.removeValue(forKey: device) else { return }
        wacomDevice.close()
        isConnected = !devices.isEmpty
        print("TabletManager: \(type(of: wacomDevice)) disconnected")
    }
}
