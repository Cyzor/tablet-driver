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

import Combine
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

    let id: Int  // productID — also serves as Identifiable key
    let productID: Int  // canonical (USB) product ID
    let rawProductID: Int  // actual transport-specific PID from hardware
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

    /// True when the tool currently in proximity is a cordless mouse accessory.
    @Published var activeToolIsMouse: Bool = false

    /// Wacom tool code for the pen currently in proximity (e.g. 0x0802 Grip Pen).
    /// 0 when no tool is in proximity.
    @Published var activeToolCode: UInt16 = 0

    /// The ToolSettings for the pen currently in proximity.
    /// Points to the device-default ToolSettings until the first tool-enter fires.
    @Published var activeTool: ToolSettings

    // MARK: - Per-device observable state (synced from driver callbacks)

    /// True when this device is currently connected.
    @Published var isConnected: Bool = false

    /// Transport type for this device: "USB", "Bluetooth", "Other", or "—".
    @Published var transport: String = "—"

    /// USB speed label if connected via USB: "Low Speed", "Full Speed", "High Speed", "Super Speed", etc.
    @Published var usbSpeed: String = "—"

    /// Battery percentage (0–100) if this device is BT; nil if USB or unknown.
    @Published var batteryPercent: Int? = nil

    /// True if the device is currently charging (BT only).
    @Published var batteryCharging: Bool = false

    /// Serial ID (as hex string) of the tool currently in proximity, or nil.
    @Published var activeToolID: String? = nil

    /// Last-seen pen/stylus point at tablet coordinates.
    @Published var livePoint: TabletPoint? = nil

    /// Live button state for the pen/stylus and device.
    @Published var liveButtons: LiveButtonState = .init()

    /// Subscriptions managed by this context (e.g., to TabletManager for change propagation).
    var cancellables: Set<AnyCancellable> = []

    init(productID: Int, rawProductID: Int? = nil) {
        self.id = productID
        self.productID = productID
        self.rawProductID = rawProductID ?? productID
        let s = TabletSettings(productID: productID)
        self.settings = s
        self.injector = InputInjector(vendorID: 0x056A, productID: productID)
        self.activeTool = s.activeTool
    }
}
