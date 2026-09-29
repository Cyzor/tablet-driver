// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import IOKit

/// Surveys the hardware a tablet's HID interfaces don't show: external
/// displays and what DDC/CI answers over the video cable, and the USB
/// devices around each Wacom device with the driver that claimed them.
///
/// Pen displays control their panels over one of these, never over the pen
/// interface. The Cintiq 27QHD, for one, answers standard DDC/CI over the
/// cable and also carries an FTDI USB-to-I2C bridge on its internal hub.
///
/// Read-only: the only DDC traffic is Get VCP Feature and Capabilities
/// requests. Slow (tens of milliseconds per request), so run it off the
/// main thread.
enum HardwareSurveyProbe {

    static func run() -> DiscoveryHardwareSurvey {
        DiscoveryHardwareSurvey(displays: displays(), usbDevices: usbDevices())
    }

    // MARK: - Displays

    /// Read when a panel has no capabilities string: brightness, contrast,
    /// color preset, RGB gain, audio volume, gamma, scaling.
    private static let fallbackCodes: [UInt8] = [0x10, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x62, 0x72, 0x86]
    /// Write-only actions (degauss, resets, settings save). Get VCP on them
    /// is harmless per MCCS, but nothing is learned, so they're skipped.
    private static let writeOnlyCodes: Set<UInt8> = [0x01, 0x04, 0x05, 0x06, 0x08, 0x0A, 0xB0]
    private static let maxCodes = 48

    /// Feature codes listed in `vcp(...)`, ignoring each one's value list.
    static func advertisedCodes(in capabilities: String) -> [UInt8] {
        guard let start = capabilities.range(of: "vcp(") else { return [] }
        var depth = 1
        var token = ""
        var codes: [UInt8] = []
        func flush() {
            if depth == 1, let code = UInt8(token, radix: 16), !codes.contains(code) {
                codes.append(code)
            }
            token = ""
        }
        for ch in capabilities[start.upperBound...] {
            switch ch {
            case "(":
                flush()
                depth += 1
            case ")":
                flush()
                depth -= 1
                if depth == 0 { return codes }
            case " ":
                flush()
            default:
                token.append(ch)
            }
        }
        return codes
    }

    private static func displays() -> [DiscoveryDisplay] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }

        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.map { id in
            let info = coreDisplayInfo(id)
            var display = DiscoveryDisplay(
                name: (info?["DisplayProductName"] as? [String: String])?.values.first,
                vendorID: String(format: "0x%04X", CGDisplayVendorNumber(id)),
                productID: String(format: "0x%04X", CGDisplayModelNumber(id)),
                ddc: "noTransport")
            display.hdmi = info?["IODisplayIsHDMISink"] as? Bool
            guard let location = info?["IODisplayLocation"] as? String,
                  let link = DDCLink(displayLocation: location)
            else { return display }

            display.epicProvider = link.epicProvider
            display.ddc = "noReply"
            let capabilities = link.readCapabilities()
            let advertised = capabilities.map(advertisedCodes(in:)) ?? []
            let codes = (advertised.isEmpty ? fallbackCodes : advertised)
                .filter { !writeOnlyCodes.contains($0) }
                .prefix(maxCodes)
            var values: [String: DiscoveryVCPValue] = [:]
            for code in codes {
                if let value = link.readVCP(code) {
                    values[String(format: "0x%02X", code)] = value
                }
            }
            if !values.isEmpty || capabilities != nil {
                display.ddc = "answered"
                display.ddcAddress = String(format: "0x%02X", link.address)
                display.ddcChecksum = link.checksum.rawValue
                display.vcp = values.isEmpty ? nil : values
                display.capabilities = capabilities
            }
            return display
        }
    }

    static func coreDisplayInfo(_ id: CGDirectDisplayID) -> [String: Any]? {
        typealias Fn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
        guard let fn = symbol("CoreDisplay_DisplayCreateInfoDictionary", as: Fn.self) else {
            return nil
        }
        return fn(id)?.takeRetainedValue() as? [String: Any]
    }

    static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    // MARK: - USB

    /// Wacom, Xencelabs.
    private static let tabletVendors: Set<Int> = [0x056A, 0x28BD]
    /// FTDI, Silicon Labs, Texas Instruments: the bridge chips Wacom Display
    /// Settings drives.
    private static let bridgeVendors: Set<Int> = [0x0403, 0x10C4, 0x0451]

    private struct USBEntry {
        let registryID: UInt64
        let parentHubID: UInt64?
        let vendorID: Int
        let productID: Int
        let name: String?
        let locationID: Int
        let drivers: [String]
    }

    private static func usbDevices() -> [DiscoveryUSBDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var entries: [USBEntry] = []
        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            if let entry = usbEntry(service) { entries.append(entry) }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        // A pen display's internals sit behind its own hub, sometimes two
        // nested ones made by the tablet's vendor (Cintiq Pro 16 DTH-1620).
        // From each tablet, climb through vendor hubs to the outermost, or
        // take the immediate hub when it's generic; list that hub's tree.
        let byID = Dictionary(entries.map { ($0.registryID, $0) }, uniquingKeysWith: { a, _ in a })
        var roots = Set<UInt64>()
        for tablet in entries where tabletVendors.contains(tablet.vendorID) {
            guard var root = tablet.parentHubID else { continue }
            while let hub = byID[root], tabletVendors.contains(hub.vendorID),
                  let up = hub.parentHubID {
                root = up
            }
            roots.insert(root)
        }
        func underRoot(_ entry: USBEntry) -> Bool {
            var hub = entry.parentHubID
            for _ in 0..<16 {
                guard let id = hub else { return false }
                if roots.contains(id) { return true }
                hub = byID[id]?.parentHubID
            }
            return false
        }

        return entries.compactMap { entry -> DiscoveryUSBDevice? in
            let reason: String
            if tabletVendors.contains(entry.vendorID) {
                reason = "tablet"
            } else if bridgeVendors.contains(entry.vendorID) {
                reason = "bridgeChip"
            } else if roots.contains(entry.registryID) {
                reason = "hub"
            } else if underRoot(entry) {
                reason = "underHub"
            } else {
                return nil
            }
            return DiscoveryUSBDevice(
                vendorID: String(format: "0x%04X", entry.vendorID),
                productID: String(format: "0x%04X", entry.productID),
                name: entry.name,
                locationID: String(format: "0x%08X", entry.locationID),
                reason: reason,
                drivers: entry.drivers)
        }
        .sorted { $0.locationID < $1.locationID }
    }

    private static func usbEntry(_ device: io_service_t) -> USBEntry? {
        guard let vendor = intProperty(device, "idVendor"),
              let product = intProperty(device, "idProduct")
        else { return nil }
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(device, &id)
        return USBEntry(
            registryID: id,
            parentHubID: parentHubID(of: device),
            vendorID: vendor,
            productID: product,
            name: IORegistryEntryCreateCFProperty(
                device, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String,
            locationID: intProperty(device, "locationID") ?? 0,
            drivers: drivers(below: device))
    }

    private static func intProperty(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
    }

    /// Nearest ancestor that is itself a USB device, i.e. the hub.
    private static func parentHubID(of device: io_service_t) -> UInt64? {
        var current = device
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<16 {
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS
            else { return nil }
            IOObjectRelease(current)
            current = parent
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 {
                var id: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(current, &id)
                return id
            }
        }
        return nil
    }

    /// Class names of what attached below a device, minus the USB plumbing
    /// every device has.
    private static let plumbing: Set<String> = [
        "IOUSBHostInterface", "IOUSBHostPipe", "AppleUSBHostCompositeDevice",
        "IOUSBHostDevice", "AppleUSB20HubPort", "AppleUSB30HubPort",
    ]

    private static func drivers(below device: io_service_t) -> [String] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            device, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator)
            == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var names = Set<String>()
        var child = IOIteratorNext(iterator)
        while child != IO_OBJECT_NULL, names.count < 16 {
            if let cls = IOObjectCopyClass(child)?.takeRetainedValue() as String?,
               !plumbing.contains(cls) {
                names.insert(cls)
            }
            IOObjectRelease(child)
            child = IOIteratorNext(iterator)
        }
        return names.sorted()
    }
}
