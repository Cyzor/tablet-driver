// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import IOKit

// MARK: - DDC/CI over IOAVService

/// One display's DDC/CI channel, via the private IOAVService calls m1ddc and
/// MonitorControl use. Apple silicon only; Intel Macs return nil.
///
/// Every read poisons its reply buffer first: a failed transaction otherwise
/// leaves the previous reply in place, which once passed for real data.
/// Unchecked: `checksum` is its only mutable state, and each owner drives it
/// from one serial queue.
final class DDCLink: @unchecked Sendable {
    enum Checksum: String { case spec, short }

    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn = @convention(c) (
        CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> IOReturn

    private let service: CFTypeRef
    private let write: I2CFn
    private let read: I2CFn
    let address: UInt32
    /// Class of the display-port controller behind this display, e.g.
    /// `AppleDCPMCDP29XX` for a Mac's own HDMI port (an internal DP-to-HDMI
    /// converter) versus a DisplayPort controller for USB-C/Thunderbolt.
    let epicProvider: String?
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
        epicProvider = provider
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

    /// Set VCP Feature. The panel sends no reply, so success only means the
    /// write left the Mac; read the value back to confirm it landed.
    @discardableResult
    func writeVCP(_ code: UInt8, _ value: Int) -> Bool {
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        packet.append(packet.reduce(checksum == .spec ? 0x6E ^ 0x51 : 0x6E, ^))
        let wrote = packet.withUnsafeMutableBytes {
            write(service, address, 0x51, $0.baseAddress, UInt32($0.count))
        }
        usleep(50_000)
        return wrote == kIOReturnSuccess
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

// MARK: - Finding a pen display's panel

extension DDCLink {
    /// EISA ID "WAC", the manufacturer code in every Wacom display's EDID.
    static let wacomDisplayVendor: UInt32 = 0x5C23

    /// The DDC channel of the Wacom display the tablet named `modelName` is
    /// built into. With several Wacom displays online, picks the one whose
    /// EDID name leads the model name ("Cintiq 27QHDT" for "Cintiq 27QHD
    /// Touch (DTH-2700)"); nil when that can't settle it.
    static func wacomPanel(modelName: String) -> DDCLink? {
        wacomPanelDisplay(modelName: modelName).flatMap { DDCLink(displayLocation: $0.location) }
    }

    /// The display ID and IOKit location of that same panel.
    static func wacomPanelDisplay(
        modelName: String
    ) -> (id: CGDirectDisplayID, location: String)? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }

        let squash = { (s: String) in s.lowercased().filter { !$0.isWhitespace } }
        let model = squash(modelName)
        let panels: [(id: CGDirectDisplayID, name: String, location: String)] =
            ids.prefix(Int(count)).compactMap { id in
            guard CGDisplayVendorNumber(id) == wacomDisplayVendor,
                  let info = HardwareSurveyProbe.coreDisplayInfo(id),
                  let location = info["IODisplayLocation"] as? String
            else { return nil }
            let name = (info["DisplayProductName"] as? [String: String])?.values.first ?? ""
            return (id, name, location)
        }
        let named = panels.filter { !$0.name.isEmpty && model.hasPrefix(squash($0.name)) }
        guard let panel = named.count == 1 ? named[0] : (panels.count == 1 ? panels[0] : nil)
        else { return nil }
        return (panel.id, panel.location)
    }
}
