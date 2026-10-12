// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid
import OSLog
import TabletKit

private let routerLog = Logger(subsystem: "com.cyzor.mocktab", category: "router")

/// Decides what to do with a freshly-enumerated Wacom HID interface.
///
/// `TabletManager.deviceConnected(_:)` extracts HID properties and constructs the
/// per-device callbacks; this type then answers the question "what concrete
/// driver, if any, should be wired up for this interface?" Lifecycle (open,
/// observe, set as active context) stays in `TabletManager` — the router does
/// not mutate any state.
///
/// Routing inputs come from the device descriptor and the existing context
/// table; outputs are an enum so the caller can keep deferral / LED-companion
/// bookkeeping localized to the manager.
@MainActor
enum DeviceRouter {

    /// Per-device closures handed to a driver at construction time. Constructed
    /// once per `deviceConnected` call and reused across multi-interface devices.
    struct Callbacks {
        let onTablet: (TabletPoint) -> Void
        let onAux: (AuxButtons) -> Void
        let onToolEnter: (ToolIdentity) -> Void
        let onMouseButton: (UInt8) -> Void
        let onBattery: (Int, Bool) -> Void
        let onHardwareSerial: (UInt32) -> Void
        let onWheel: (Int, Int) -> Void
        /// Per-frame finger-touch contact set.  Empty array signals all
        /// fingers lifted.  No shipping decoder emits this yet; reserved
        /// for the DTH-* touch-capable devices (Phase 1 plumbing).
        let onTouch: ([TouchContact]) -> Void
        /// Called once when a wireless dongle (ACK-40401) identifies the
        /// paired tablet's PID from the 0x80 status report.
        let onPairedPID: (Int) -> Void
        /// Called when `IOHIDDeviceOpen` fails for this interface — see
        /// `WacomKnownDevice.onOpenFailed`'s doc comment.
        let onOpenFailed: (IOReturn) -> Void
    }

    /// The decision made for a single HID interface.
    enum Routed {
        /// A driver was constructed. Caller attaches it to the context, opens
        /// it, drains pending interfaces, and registers the tablet.
        ///
        /// `seized == true` means the driver was opened with `kIOHIDOptionsTypeSeizeDevice`
        /// and the caller should be aware (currently informational only).
        case driver(any TabletDevice, seized: Bool)

        /// This interface arrived before its sibling (the one carrying the
        /// primary digitizer reports). Caller stores `device` in
        /// `pendingInterfaces[productID]` until the primary creates the driver.
        case deferred

        /// Non-digitizer interface that matches the `ledCompanionPID` of an
        /// already-attached tablet. Caller calls `registerLEDDevice(device)`
        /// on that driver.
        case ledCompanion(parentContext: DeviceContext)

        /// Touch-sensor interface enumerating under its own PID, matching the
        /// `touchCompanionPID` of an already-attached tablet. Caller calls
        /// `registerDevice(device)` on that tablet's driver, so the sensor's
        /// descriptor is read by a driver whose spec has `hasFingerTouch` —
        /// the gate `deriveTouchDecoders` checks.
        case touchCompanion(parentContext: DeviceContext)

        /// A touch sensor whose claiming tablet hasn't enumerated yet. Caller
        /// holds `device` in `pendingTouchCompanions` until it does. Distinct
        /// from `.deferred`, which is keyed by the driver's own raw PID and so
        /// can't hold an interface belonging to a different PID.
        case deferredTouchCompanion

        /// No action — interface has no digitizer elements and no LED match.
        case skip
    }

    /// The interface's top-level collections, as IOKit reports them.
    static func usagePairs(_ device: IOHIDDevice) -> [InterfaceRouting.UsagePair] {
        let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString)
            as? [[String: Any]] ?? []
        return pairs.map {
            (page: $0[kIOHIDDeviceUsagePageKey] as? Int ?? 0, usage: $0[kIOHIDDeviceUsageKey] as? Int ?? 0)
        }
    }

    /// Decide what to do with `device`.
    ///
    /// - Parameters:
    ///   - device: The freshly-enumerated `IOHIDDevice`.
    ///   - productID: Canonical product ID (after wireless-dongle remap).
    ///   - usagePage: Primary HID usage page from the descriptor.
    ///   - isBLE: True if the transport string starts with "Bluetooth".
    ///   - contexts: Current context table — read-only, used to find LED
    ///     companion parents.
    ///   - callbacks: Event closures to hand to the new driver.
    /// - Parameter overrideSpec: A spec synthesized outside the Wacom registry
    ///   (drivable non-Wacom devices, e.g. Xencelabs). When non-nil it takes
    ///   the place of the `WacomDeviceRegistry` lookup; all interface-routing
    ///   logic downstream is identical.
    static func route(
        device: IOHIDDevice,
        productID: Int,
        usagePage: Int,
        isBLE: Bool,
        contexts: [DeviceInstanceKey: DeviceContext],
        callbacks: Callbacks,
        overrideSpec: TabletSpec? = nil,
        holdTouchCompanion: Bool = true
    ) -> Routed {

        // The decision is TabletKit's (`InterfaceRouting.decide`); this builds
        // what it names. Non-Wacom PIDs can collide with Wacom registry rows,
        // so the decision gates on vendor; Xencelabs arrives as `overrideSpec`.
        let vendorID = hidIntProperty(device, kIOHIDVendorIDKey)
        let pidStr = String(productID, radix: 16, uppercase: true)
        let facts = InterfaceRouting.Facts(
            vendorID: vendorID, productID: productID, usagePage: usagePage,
            usagePairs: usagePairs(device), isBluetooth: isBLE, overrideSpec: overrideSpec)
        let attached = contexts.values.filter { $0.tabletDevice is WacomKnownDevice }
        let decision = InterfaceRouting.decide(
            facts, attachedProductIDs: attached.map(\.productID),
            holdTouchCompanion: holdTouchCompanion
        ) {
            let (maxX, _, _, _) = queryHIDDigitizerSpec(device)
            // Classified only when there is X/Y to classify, as before.
            return .init(
                hasXY: maxX > 0,
                kind: maxX > 0 ? classifyDigitizerInterface(device) : .undetermined)
        }
        func parent(_ pid: Int) -> DeviceContext? {
            attached.first { $0.productID == pid }
        }

        switch decision {
        case .wirelessDongle:
            // Same descriptor as the paired tablet (PTH-x50/x51, IntuosV1), so
            // the spec comes from the live descriptor. Pen events wait for the
            // 0x80 status report to confirm the RF link.
            routerLog.info("ACK-40401 wireless dongle connected")
            let (dMaxX, dMaxY, dMaxP, _) = queryHIDDigitizerSpec(device)
            let dongleSpec = TabletSpec(
                productID: 0x0084,
                name: "ACK-40401 Wireless Dongle",
                format: .intuosV1,
                maxX: dMaxX, maxY: dMaxY, maxPressure: dMaxP,
                buttonCount: 8, hasTouchRing: true, hasEraser: true,
                hasFingerTouch: true, maxTouchContacts: 5,
                seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])])
            let drv = WacomKnownDevice(
                device: device, deviceSpec: dongleSpec, isWireless: true,
                onTablet: callbacks.onTablet, onAux: callbacks.onAux,
                onToolEnter: callbacks.onToolEnter,
                onHardwareSerial: callbacks.onHardwareSerial,
                onWheel: callbacks.onWheel,
                onTouch: callbacks.onTouch,
                onPairedPID: callbacks.onPairedPID,
                onOpenFailed: callbacks.onOpenFailed)
            return .driver(drv, seized: false)

        case .touchCompanion(let parentPID):
            guard let parent = parent(parentPID) else { return .skip }
            routerLog.info("Wacom 0x\(pidStr, privacy: .public) — touch sensor for 0x\(String(parent.productID, radix: 16, uppercase: true), privacy: .public)")
            return .touchCompanion(parentContext: parent)

        case .holdTouchCompanion:
            routerLog.info("Wacom 0x\(pidStr, privacy: .public) — touch sensor, holding until its tablet enumerates")
            return .deferredTouchCompanion

        case .deferToSibling:
            let name = (overrideSpec ?? WacomDeviceRegistry.spec(for: productID))?.name ?? pidStr
            routerLog.info("\(name, privacy: .public) — deferring 0x\(String(usagePage, radix: 16), privacy: .public) interface")
            return .deferred

        case .driver(let deviceSpec, let shouldSeize):
            routerLog.info("\(deviceSpec.name, privacy: .public) connected via universal driver\(shouldSeize ? " (seized)" : "", privacy: .public)")
            let drv = WacomKnownDevice(
                device: device, deviceSpec: deviceSpec, seize: shouldSeize,
                onTablet: callbacks.onTablet, onAux: callbacks.onAux,
                onToolEnter: callbacks.onToolEnter,
                onMouseButton: callbacks.onMouseButton,
                onBattery: callbacks.onBattery,
                onHardwareSerial: callbacks.onHardwareSerial,
                onWheel: callbacks.onWheel,
                onTouch: callbacks.onTouch,
                onOpenFailed: callbacks.onOpenFailed)
            return .driver(drv, seized: shouldSeize)

        case .observeTouchOnly:
            // Observed rather than skipped: a device with no driver gets no
            // `DeviceContext`, which would hide novel touch hardware from the
            // capture flow that exists to onboard it.
            routerLog.info("0x\(pidStr, privacy: .public) — multitouch-only interface, observing without cursor input")
            let drv = GenericHIDDigitizer(
                device: device, onTablet: callbacks.onTablet, observeOnly: true)
            return .driver(drv, seized: false)

        case .wacomFallback:
            routerLog.info("unknown Wacom 0x\(pidStr, privacy: .public) — attaching Wacom fallback driver")
            let drv = WacomFallbackDevice(
                device: device,
                onTablet: callbacks.onTablet,
                onAux: callbacks.onAux,
                onToolEnter: callbacks.onToolEnter)
            return .driver(drv, seized: false)

        case .genericDigitizer:
            let drv = GenericHIDDigitizer(device: device, onTablet: callbacks.onTablet)
            let brandNote = drv.detectedBrand.map { " (looks like \($0))" } ?? ""
            routerLog.info("0x\(String(vendorID, radix: 16), privacy: .public)/0x\(pidStr, privacy: .public)\(brandNote, privacy: .public) — attaching generic HID digitizer (universal floor)")
            return .driver(drv, seized: false)

        case .ledCompanion(let parentPID):
            guard let parent = parent(parentPID) else { return .skip }
            let parentName = parent.productID == 0
                ? "unknown"
                : String(parent.productID, radix: 16, uppercase: true)
            routerLog.info("Wacom 0x\(pidStr, privacy: .public) — LED companion for \(parentName, privacy: .public)")
            return .ledCompanion(parentContext: parent)

        case .skip:
            routerLog.debug("Wacom 0x\(pidStr, privacy: .public) — no digitizer elements, skipping")
            return .skip
        }
    }
}
