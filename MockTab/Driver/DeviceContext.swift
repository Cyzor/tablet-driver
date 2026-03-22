import Foundation
import IOKit.hid

/// Per-device bundle of settings, input injector, and tablet driver.
///
/// Each connected tablet gets its own context so that smoothing history,
/// click counters, proximity state, and user preferences are fully isolated.
/// `TabletManager` keeps a dictionary of these keyed by product ID and
/// tracks which one is currently active (posting CGEvents).
@MainActor
final class DeviceContext: ObservableObject, Identifiable {

    let id: Int                     // productID — also serves as Identifiable key
    let productID: Int
    let settings: TabletSettings
    let injector: InputInjector

    /// The decoded HID driver for this tablet.  Set when the IOHIDDevice
    /// connects and cleared on disconnect (but the context itself survives
    /// so settings are preserved for reconnection).
    var tabletDevice: (any TabletDevice)?

    /// The raw IOHIDDevice handle — weak because IOKit owns the lifetime.
    weak var hidDevice: IOHIDDevice?

    /// Serial number of the pen currently in proximity on this device.
    /// 0 = unknown (IntuosV1) or no pen in proximity.
    @Published var activeToolSerial: UInt32 = 0

    /// The ToolSettings for the pen currently in proximity.
    /// Points to the device-default ToolSettings until the first tool-enter fires.
    @Published var activeTool: ToolSettings

    init(productID: Int) {
        self.id        = productID
        self.productID = productID
        let s = TabletSettings(productID: productID)
        self.settings  = s
        self.injector  = InputInjector(vendorID: 0x056A, productID: productID)
        self.activeTool = s.activeTool
    }
}
