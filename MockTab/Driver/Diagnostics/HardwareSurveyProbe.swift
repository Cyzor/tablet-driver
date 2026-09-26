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

    private static func coreDisplayInfo(_ id: CGDirectDisplayID) -> [String: Any]? {
        typealias Fn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
        guard let fn = symbol("CoreDisplay_DisplayCreateInfoDictionary", as: Fn.self) else {
            return nil
        }
        return fn(id)?.takeRetainedValue() as? [String: Any]
    }

    fileprivate static func symbol<T>(_ name: String, as type: T.Type) -> T? {
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

// MARK: - DDC/CI over IOAVService

/// One display's DDC/CI channel, via the private IOAVService calls m1ddc and
/// MonitorControl use. Apple silicon only; Intel Macs return nil.
///
/// Every read poisons its reply buffer first: a failed transaction otherwise
/// leaves the previous reply in place, which once passed for real data.
private final class DDCLink {
    enum Checksum: String { case spec, short }

    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn = @convention(c) (
        CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> IOReturn

    private let service: CFTypeRef
    private let write: I2CFn
    private let read: I2CFn
    let address: UInt32
    private(set) var checksum: Checksum = .spec

    init?(displayLocation: String) {
        guard let create = HardwareSurveyProbe.symbol("IOAVServiceCreateWithService", as: CreateFn.self),
              let write = HardwareSurveyProbe.symbol("IOAVServiceWriteI2C", as: I2CFn.self),
              let read = HardwareSurveyProbe.symbol("IOAVServiceReadI2C", as: I2CFn.self),
              let proxy = Self.avServiceProxy(forDisplayLocation: displayLocation)
        else { return nil }
        defer { IOObjectRelease(proxy) }
        guard let av = create(kCFAllocatorDefault, proxy)?.takeRetainedValue() else { return nil }
        service = av
        self.write = write
        self.read = read
        // Panels behind an MCDP29xx bridge answer at 0xB7 (m1ddc's check).
        let provider = IORegistryEntrySearchCFProperty(
            proxy, kIOServicePlane, "EPICProviderClass" as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String
        address = provider == "AppleDCPMCDP29XX" ? 0xB7 : 0x37
    }

    /// The DCPAVServiceProxy under the framebuffer driving this display.
    private static func avServiceProxy(forDisplayLocation location: String) -> io_service_t? {
        let adapter = IORegistryEntryFromPath(kIOMainPortDefault, location)
        guard adapter != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(adapter) }
        var adapterID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(adapter, &adapterID) == KERN_SUCCESS else { return nil }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            IORegistryGetRootEntry(kIOMainPortDefault), kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var underAdapter = false
        let name = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
        defer { name.deallocate() }
        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            if IOObjectConformsTo(entry, "IOMobileFramebuffer") != 0 {
                var id: UInt64 = 0
                underAdapter = IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS
                    && id == adapterID
            } else if underAdapter {
                name.initialize(repeating: 0, count: 128)
                if IORegistryEntryGetName(entry, name) == KERN_SUCCESS,
                   String(cString: name) == "DCPAVServiceProxy" {
                    return entry  // caller releases
                }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return nil
    }

    /// Get VCP Feature. Nil unless the reply echoes the code with a nonzero
    /// maximum; an unimplemented code still echoes, with max 0.
    func readVCP(_ code: UInt8) -> DiscoveryVCPValue? {
        for variant in orderedChecksums() {
            guard let reply = transact([0x82, 0x01, code], checksum: variant, replyLength: 12),
                  reply[2] == 0x02, reply[4] == code
            else { continue }
            let max = Int(reply[6]) << 8 | Int(reply[7])
            guard max > 0 else { return nil }
            checksum = variant
            return DiscoveryVCPValue(current: Int(reply[8]) << 8 | Int(reply[9]), max: max)
        }
        return nil
    }

    /// Capabilities string, read in fragments until the panel sends an empty
    /// one. Returns what arrived if it stops early.
    func readCapabilities() -> String? {
        var bytes: [UInt8] = []
        for variant in orderedChecksums() {
            bytes = []
            while bytes.count < 1024 {
                let offset = bytes.count
                guard let reply = transact(
                    [0x83, 0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)],
                    checksum: variant, replyLength: 38),
                    reply[2] == 0xE3,
                    Int(reply[3]) << 8 | Int(reply[4]) == offset
                else { break }
                let payload = Int(reply[1] & 0x7F) - 3
                guard payload > 0 else { break }
                bytes += reply[5..<min(5 + payload, reply.count - 1)]
            }
            if !bytes.isEmpty {
                checksum = variant
                break
            }
        }
        let text = String(decoding: bytes.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    private func orderedChecksums() -> [Checksum] {
        checksum == .spec ? [.spec, .short] : [.short, .spec]
    }

    /// Writes one request, waits the 50 ms MCCS asks for, reads the reply.
    private func transact(_ body: [UInt8], checksum variant: Checksum, replyLength: Int) -> [UInt8]? {
        var packet = body
        var sum: UInt8 = variant == .spec ? 0x6E ^ 0x51 : 0x6E
        for byte in body { sum ^= byte }
        packet.append(sum)
        let wrote = packet.withUnsafeMutableBytes {
            write(service, address, 0x51, $0.baseAddress, UInt32($0.count))
        }
        guard wrote == kIOReturnSuccess else { return nil }
        usleep(50_000)
        var reply = [UInt8](repeating: 0xEE, count: replyLength)
        let got = reply.withUnsafeMutableBytes {
            read(service, address, 0x51, $0.baseAddress, UInt32($0.count))
        }
        usleep(10_000)
        return got == kIOReturnSuccess ? reply : nil
    }
}
