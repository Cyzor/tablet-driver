// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid
import OSLog
import TabletKit

private let routerLog = Logger(subsystem: "com.cyzor.mocktab", category: "router")

/// The app's callbacks for one tablet's events, and the fallback drivers
/// for interfaces TabletKit's session leaves unclaimed.
@MainActor
enum DeviceRouter {

    /// Per-device closures, called on HIDThread.
    struct Callbacks {
        let onTablet: @Sendable (TabletPoint) -> Void
        let onAux: @Sendable (PadState) -> Void
        let onToolEnter: @Sendable (ToolIdentity) -> Void
        let onMouseButton: @Sendable (UInt8) -> Void
        let onBattery: @Sendable (Int, Bool) -> Void
        let onWheel: @Sendable (Int, Int) -> Void
        /// Per-frame finger contacts; an empty array means every finger lifted.
        let onTouch: @Sendable ([TouchContact]) -> Void
    }

    /// The driver for an interface the session doesn't drive itself.
    static func fallbackDriver(
        _ kind: UnclaimedKind, device: IOHIDDevice, callbacks: Callbacks
    ) -> (any TabletDevice)? {
        let vendorID = hidIntProperty(device, kIOHIDVendorIDKey)
        let pidStr = String(hidIntProperty(device, kIOHIDProductIDKey), radix: 16, uppercase: true)
        switch kind {
        case .observeTouchOnly:
            // Observed rather than skipped: a device with no driver gets no
            // `DeviceContext`, which would hide novel touch hardware from the
            // capture flow that exists to onboard it.
            routerLog.info("0x\(pidStr, privacy: .public) — multitouch-only interface, observing without cursor input")
            return GenericHIDDigitizer(device: device, onTablet: callbacks.onTablet, observeOnly: true)
        case .wacomFallback:
            routerLog.info("unknown Wacom 0x\(pidStr, privacy: .public) — attaching Wacom fallback driver")
            return WacomFallbackDevice(
                device: device, onTablet: callbacks.onTablet, onAux: callbacks.onAux,
                onToolEnter: callbacks.onToolEnter)
        case .genericDigitizer:
            let drv = GenericHIDDigitizer(device: device, onTablet: callbacks.onTablet)
            let brandNote = drv.detectedBrand.map { " (looks like \($0))" } ?? ""
            routerLog.info("0x\(String(vendorID, radix: 16), privacy: .public)/0x\(pidStr, privacy: .public)\(brandNote, privacy: .public) — attaching generic HID digitizer (universal floor)")
            return drv
        case .recognizedOnly:
            return nil
        }
    }
}
