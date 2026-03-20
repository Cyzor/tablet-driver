import Foundation
import IOKit.hid

/// Digitizer dimensions in device units for a given tablet model.
struct DigitizerSpec {
    var maxX: Int
    var maxY: Int
    var maxPressure: Int
}

protocol TabletDevice: AnyObject {
    var spec: DigitizerSpec { get }
    func open()
    func close()
}

// Convenience: read an integer property from an IOHIDDevice.
func hidIntProperty(_ device: IOHIDDevice, _ key: String) -> Int {
    guard let val = IOHIDDeviceGetProperty(device, key as CFString) else { return 0 }
    return (val as? NSNumber)?.intValue ?? 0
}
