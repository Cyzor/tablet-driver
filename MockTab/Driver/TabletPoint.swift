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
    /// Pen rotation (twist), 0.0..360.0 degrees (approximate)
    var rotation: Double = 0.0
    var penButton1: Bool
    var penButton2: Bool
    var eraser: Bool
    var inProximity: Bool
    var hoverDistance: Int
    /// For mouse tools only: middle-button state.
    var mouseMiddleButton: Bool = false
    /// For mouse tools only: scroll-wheel step this report (+1 up / -1 down / 0 none).
    var mouseWheelDelta: Int = 0
}

/// Identity of a physical pen as reported by the tablet firmware.
/// Fires once per `onToolEnter` callback whenever the active tool changes.
struct ToolIdentity {
    /// Unique 32-bit serial per physical pen body.  0 means not available (IntuosV1).
    let serial: UInt32
    /// Wacom product code — e.g. 0x0802 Grip Pen, 0x0832 Pro Pen 2, 0x0842 Pro Pen 3.
    let toolCode: UInt16
    /// True for the eraser end.  Derived from toolCode: bit 3 of the low byte is set.
    let isEraser: Bool
    /// True for cordless mouse / cursor accessories (Intuos Mouse).
    /// On IntuosV2 devices: detected by the absence of the pen bit (0x0800) in toolCode.
    let isMouse: Bool
}

struct AuxButtons {
    var buttons: [Bool]  // up to 8 express key buttons
    /// True while a finger is resting on the touch ring (position is valid).
    var touchRingActive: Bool = false
    /// True while the center click button of the touch ring is physically pressed.
    var touchRingButtonDown: Bool = false
    /// Absolute touch ring position, 0–71 (5° resolution).  0x7F = idle/no contact.
    var touchRingPosition: UInt8 = 0x7F
    /// Second touch ring (DTK-2400 right bezel).  Same encoding as touchRingPosition.
    var touchRing2Active: Bool = false
    var touchRing2Position: UInt8 = 0x7F
    /// Intuos3 WS left touch strip.  0xFF = no contact; 0 = bottom zone, higher = up.
    var touchStrip1Active: Bool = false
    var touchStrip1Position: UInt8 = 0xFF
    /// Intuos3 WS right touch strip.  Same encoding as strip 1.
    var touchStrip2Active: Bool = false
    var touchStrip2Position: UInt8 = 0xFF

    subscript(index: Int) -> Bool {
        guard index < buttons.count else { return false }
        return buttons[index]
    }
}

/// Snapshot of which hardware buttons are currently held down.
/// Published by TabletManager so the Buttons pane can light up rows
/// in real time, like a keyboard viewer for the tablet.
struct LiveButtonState: Equatable {
    /// Pen tip pressed (non-eraser end).
    var tipDown: Bool = false
    /// Eraser tip pressed.
    var eraserDown: Bool = false
    /// Side button 1 held.
    var button1Down: Bool = false
    /// Side button 2 held.
    var button2Down: Bool = false
    /// Express key states (up to 8).
    var expressKeys: [Bool] = Array(repeating: false, count: 16)
    /// True while a finger is actively touching the touch ring.
    var touchRingActive: Bool = false
    /// True while the touch ring center button is physically pressed.
    var touchRingButtonDown: Bool = false
    /// Second touch ring (DTK-2400 right bezel).
    var touchRing2Active: Bool = false
    /// Intuos3 WS touch strip states (0xFF = no contact, otherwise 0–12 zone).
    var touchStrip1Active: Bool = false
    var touchStrip2Active: Bool = false
}
