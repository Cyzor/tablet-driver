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

struct AuxButtons {
    var buttons: [Bool]  // up to 8 express key buttons

    subscript(index: Int) -> Bool {
        guard index < buttons.count else { return false }
        return buttons[index]
    }
}
