// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid
import OSLog

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

        /// No action — interface has no digitizer elements and no LED match.
        case skip
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
    static func route(
        device: IOHIDDevice,
        productID: Int,
        usagePage: Int,
        isBLE: Bool,
        contexts: [Int: DeviceContext],
        callbacks: Callbacks
    ) -> Routed {

        // ── ACK-40401 RF wireless dongle ─────────────────────────────────────
        // The dongle presents the same HID descriptor as the paired tablet
        // (PTH-x50/x51 family, IntuosV1 format). We synthesize a spec from the
        // live descriptor — pen events are gated by WacomKnownDevice until the
        // 0x80 wireless status report confirms the RF link.
        if productID == 0x0084 {
            routerLog.info("ACK-40401 wireless dongle connected")
            let (dMaxX, dMaxY, dMaxP, _) = queryHIDDigitizerSpec(device)
            let dongleSpec = WacomDeviceSpec(
                productID: 0x0084,
                name: "ACK-40401 Wireless Dongle",
                parser: .intuosV1,
                maxX: dMaxX, maxY: dMaxY, maxPressure: dMaxP,
                buttonCount: 8, hasTouchRing: true, hasEraser: true,
                seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])])
            let drv = WacomKnownDevice(
                device: device, deviceSpec: dongleSpec, isWireless: true,
                onTablet: callbacks.onTablet, onAux: callbacks.onAux,
                onToolEnter: callbacks.onToolEnter,
                onHardwareSerial: callbacks.onHardwareSerial,
                onWheel: callbacks.onWheel,
                onTouch: callbacks.onTouch)
            return .driver(drv, seized: false)
        }

        // ── Recognised PID with a live decoder ───────────────────────────────
        if let deviceSpec = WacomDeviceRegistry.spec(for: productID),
            WacomDeviceRegistry.hasLiveDecoder(for: productID),
            deviceSpec.maxX > 0
        {
            // Interface routing depends on parser family:
            //
            // IntuosV2 (PTH-x60/x80):  vendor interface 0xFF00 is primary
            //   (featureInit via the InputMode element). Interface 0x01 is
            //   deferred and registered as a secondary without seizure —
            //   seizing 0x01 stops IntuosV2 firmware from sending pen reports.
            //
            // CintiqV1 (DTK-2400 etc): interface 0x01 is the pen digitizer
            //   (reports 0x02, 0x0C). It must be seized so the OS doesn't
            //   interpret tip-switch as a native click, and featureInit
            //   [0x02, 0x02] must be sent there. 0xFF00 carries only the
            //   periodic 0x80 status report; defer until 0x01 has the driver.
            let isCintiqV1 = deviceSpec.parser == .cintiqV1
            let deferrablePage: Int = isCintiqV1 ? 0xFF00 : 0x01
            let shouldDefer = !isBLE && deviceSpec.seizeUSB && usagePage == deferrablePage
            if shouldDefer {
                routerLog.info("\(deviceSpec.name, privacy: .public) — deferring 0x\(String(usagePage, radix: 16), privacy: .public) interface")
                return .deferred
            }

            // Seize the digitizer interface for CintiqV1 to stop the OS from
            // interpreting tip-switch as a native left-click.
            let shouldSeize = !isBLE && isCintiqV1 && deviceSpec.seizeUSB && usagePage == 0x01
            routerLog.info("\(deviceSpec.name, privacy: .public) connected via universal driver\(shouldSeize ? " (seized)" : "", privacy: .public)")
            let drv = WacomKnownDevice(
                device: device, deviceSpec: deviceSpec, seize: shouldSeize,
                onTablet: callbacks.onTablet, onAux: callbacks.onAux,
                onToolEnter: callbacks.onToolEnter,
                onMouseButton: callbacks.onMouseButton,
                onBattery: callbacks.onBattery,
                onHardwareSerial: callbacks.onHardwareSerial,
                onWheel: callbacks.onWheel,
                onTouch: callbacks.onTouch)
            return .driver(drv, seized: shouldSeize)
        }

        // ── Unrecognised PID — probe the descriptor ─────────────────────────
        // Devices with X/Y digitizer elements get the generic fallback driver.
        // Devices without are either non-input interfaces (LED controller,
        // status interface) or LED companions of a previously-attached tablet.
        let pidStr = String(productID, radix: 16, uppercase: true)
        let (probeX, _, _, _) = queryHIDDigitizerSpec(device)
        if probeX > 0 {
            routerLog.info("unknown Wacom 0x\(pidStr, privacy: .public) — attaching generic driver")
            let drv = WacomFallbackDevice(
                device: device,
                onTablet: callbacks.onTablet,
                onAux: callbacks.onAux,
                onToolEnter: callbacks.onToolEnter)
            return .driver(drv, seized: false)
        }

        // No digitizer — is it a known LED companion for an attached tablet?
        let companion = contexts.values.first { ctx in
            guard ctx.tabletDevice is WacomKnownDevice,
                  let companionPID = WacomDeviceRegistry.spec(for: ctx.productID)?.ledCompanionPID
            else { return false }
            return companionPID == productID
        }
        if let parent = companion {
            let parentPID = parent.productID == 0
                ? "unknown"
                : String(parent.productID, radix: 16, uppercase: true)
            routerLog.info("Wacom 0x\(pidStr, privacy: .public) — LED companion for \(parentPID, privacy: .public)")
            return .ledCompanion(parentContext: parent)
        }

        routerLog.debug("Wacom 0x\(pidStr, privacy: .public) — no digitizer elements, skipping")
        return .skip
    }
}
