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

    init(productID: Int) {
        self.id        = productID
        self.productID = productID
        self.settings  = TabletSettings(productID: productID)
        self.injector  = InputInjector(vendorID: 0x056A, productID: productID)
    }
}
