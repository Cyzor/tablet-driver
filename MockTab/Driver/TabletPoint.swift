import Foundation

struct TabletPoint {
    /// Raw digitizer X coordinate (device units)
    var x: Int
    /// Raw digitizer Y coordinate (device units)
    var y: Int
    /// Maximum X value in device units (device-specific)
    var maxX: Int
    /// Maximum Y value in device units (device-specific)
    var maxY: Int
    /// Pressure value, 0..maxPressure
    var pressure: Int
    /// Maximum pressure value for this device (1023 for PTH-851, 8191 for PTH-860)
    var maxPressure: Int
    /// Normalized pressure, 0.0..1.0
    var normalizedPressure: Double { Double(pressure) / Double(maxPressure) }
    /// Tilt X, -1.0..1.0
    var tiltX: Double
    /// Tilt Y, -1.0..1.0
    var tiltY: Double
    var penButton1: Bool
    var penButton2: Bool
    var eraser: Bool
    var inProximity: Bool
    var hoverDistance: Int
}

/// Identity of a physical pen as reported by the tablet firmware.
/// Fires once per `onToolEnter` callback whenever the active tool changes.
struct ToolIdentity {
    /// Unique 32-bit serial per physical pen body.  0 means not available (IntuosV1).
    let serial:   UInt32
    /// Wacom product code — e.g. 0x0802 Grip Pen, 0x0832 Pro Pen 2, 0x0842 Pro Pen 3.
    let toolCode: UInt16
    /// True for the eraser end.  Derived from toolCode: bit 3 of the low byte is set.
    let isEraser: Bool
}

struct AuxButtons {
    var buttons: [Bool]  // up to 8 express key buttons

    subscript(index: Int) -> Bool {
        guard index < buttons.count else { return false }
        return buttons[index]
    }
}
