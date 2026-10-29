// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// Swaps hardware serials in captured reports for stand-ins.
///
/// Captures get attached to public issues. Free of the capture types so the
/// checks can compile it.
enum CaptureSerialRedaction {

    /// Byte positions holding the remote's serial, for one device and report ID.
    ///
    /// The ExpressKey Remote puts its serial on the wire twice: report 0x11
    /// carries the sending remote's at bytes 3–5, and report 0x10 — the
    /// receiver's pairing table — repeats one per 6-byte slot at j+4...6.
    /// Both are 24-bit LE. See `ExpressKeyRemoteDecoder` for the layout.
    ///
    static func serialByteOffsets(productID: Int, reportID: UInt8) -> [Int] {
        guard productID == expressKeyRemoteProductID else { return [] }
        switch reportID {
        case 0x11:
            return [3, 4, 5]
        case 0x10:
            var offsets: [Int] = []
            for slot in 0..<pairingSlotCount {
                let base: Int = slot * pairingSlotStride
                offsets.append(base + 4)
                offsets.append(base + 5)
                offsets.append(base + 6)
            }
            return offsets
        default:
            return []
        }
    }

    // MARK: - Stand-in serials

    /// A report's bytes with every hardware serial swapped for a stand-in.
    /// One device keeps one stand-in, matching across captures from the
    /// same Mac.
    static func redacted(_ bytes: [UInt8], productID: Int) -> [UInt8] {
        guard let reportID = bytes.first else { return bytes }
        var out = bytes
        let offsets = serialByteOffsets(productID: productID, reportID: reportID)
        for start in stride(from: 0, to: offsets.count, by: 3) {
            let group = offsets[start..<Swift.min(start + 3, offsets.count)]
            guard let last = group.last, last < out.count else { continue }
            let serial = group.enumerated().reduce(UInt32(0)) {
                $0 | UInt32(out[$1.element]) << ($1.offset * 8)
            }
            // Keep empty slots readable as empty.
            guard serial != 0, serial != 0xFF_FFFF else { continue }
            let decoy = standIn(for: serial, bits: 24)
            for (i, idx) in group.enumerated() {
                out[idx] = UInt8(truncatingIfNeeded: decoy >> (i * 8))
            }
        }
        let key = PositionKey(productID: productID, reportID: reportID)
        let (serials, known) = seen.withLock { ($0.penSerials, $0.positions[key] ?? []) }
        guard !serials.isEmpty else { return out }
        // A pen already in range when the capture starts never announces
        // itself, so look for it too, in whole bytes only: a short serial
        // matched anywhere rewrote ordinary fields.
        var positions = known
        for serial in serials.keys where serial > distinctiveSerialFloor {
            for offset in littleEndianOffsets(of: serial, in: out) {
                positions.insert(.littleEndian(offset))
            }
        }
        if positions != known {
            seen.withLock { $0.positions[key, default: []].formUnion(positions) }
        }
        for position in positions {
            switch position {
            case .littleEndian(let offset):
                guard offset + 4 <= out.count, let decoy = serials[littleEndian(out, at: offset)]
                else { continue }
                for i in 0..<4 { out[offset + i] = UInt8(truncatingIfNeeded: decoy >> (i * 8)) }
            case .bigEndianBit(let bit):
                guard bit + 32 <= out.count * 8, let decoy = serials[readBits(out, at: bit)]
                else { continue }
                writeBits(&out, decoy, at: bit)
            }
        }
        return out
    }

    /// Note a pen's serial so `redacted` can swap it. A serial known before
    /// the capture starts has no report to place it; see `redacted`.
    static func noteToolEnter(serial: UInt32) {
        guard serial != 0, seen.withLock({ $0.penSerials[serial] }) == nil else { return }
        let decoy = standIn(for: serial, bits: 32)
        seen.withLock { $0.penSerials[serial] = decoy }
    }

    /// Note a pen's serial and where `report`, which announced it, carries
    /// it: whole bytes little-endian, or else big-endian from a bit offset.
    /// Later reports with this ID get swapped only there.
    static func noteToolEnter(serial: UInt32, in report: [UInt8], productID: Int) {
        guard serial != 0, let reportID = report.first else { return }
        noteToolEnter(serial: serial)
        var found = Set(littleEndianOffsets(of: serial, in: report).map { SerialPosition.littleEndian($0) })
        if found.isEmpty, serial > distinctiveSerialFloor {
            found = Set(bigEndianBitOffsets(of: serial, in: report).map { SerialPosition.bigEndianBit($0) })
        }
        guard !found.isEmpty else { return }
        let key = PositionKey(productID: productID, reportID: reportID)
        seen.withLock { $0.positions[key, default: []].formUnion(found) }
    }

    /// Bytes where a pen serial turned up in this device's reports with this
    /// ID, so the summary withholds their values.
    static func penSerialByteOffsets(productID: Int, reportID: UInt8) -> [Int] {
        let key = PositionKey(productID: productID, reportID: reportID)
        let positions = seen.withLock { $0.positions[key] ?? [] }
        return Set(positions.flatMap { position -> ClosedRange<Int> in
            switch position {
            case .littleEndian(let offset): return offset...(offset + 3)
            case .bigEndianBit(let bit): return (bit / 8)...((bit + 31) / 8)
            }
        }).sorted()
    }

    /// The stand-in a decoded log line prints for a pen serial.
    static func standIn(forPenSerial serial: UInt32) -> UInt32 {
        guard serial != 0 else { return 0 }
        return seen.withLock { $0.penSerials[serial] } ?? standIn(for: serial, bits: 32)
    }

    /// Serials at or below this are too short to search for: they match
    /// ordinary fields, such as a hover distance of 63.
    private static let distinctiveSerialFloor: UInt32 = 0xFFFF

    /// Where a report carries a pen serial.
    private enum SerialPosition: Hashable {
        /// Four whole bytes from this offset, little-endian.
        case littleEndian(Int)
        /// 32 bits from this bit offset, big-endian.
        case bigEndianBit(Int)
    }

    private struct PositionKey: Hashable {
        let productID: Int
        let reportID: UInt8
    }

    private static func littleEndian(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func littleEndianOffsets(of serial: UInt32, in bytes: [UInt8]) -> [Int] {
        guard bytes.count >= 5 else { return [] }
        return (1...(bytes.count - 4)).filter { littleEndian(bytes, at: $0) == serial }
    }

    private static func bigEndianBitOffsets(of serial: UInt32, in bytes: [UInt8]) -> [Int] {
        guard bytes.count >= 5 else { return [] }
        return (8...(bytes.count * 8 - 32)).filter { readBits(bytes, at: $0) == serial }
    }

    /// The 32 bits starting at `bit`, big-endian.
    private static func readBits(_ bytes: [UInt8], at bit: Int) -> UInt32 {
        let first = bit / 8
        var window: UInt64 = 0
        var i = 0
        while i < 5 {
            let index = first + i
            window = window << 8 | UInt64(index < bytes.count ? bytes[index] : 0)
            i += 1
        }
        return UInt32(truncatingIfNeeded: window >> (8 - bit % 8))
    }

    private static func writeBits(_ bytes: inout [UInt8], _ value: UInt32, at bit: Int) {
        for i in 0..<32 {
            let b = bit + i
            let mask = UInt8(1 << (7 - b % 8))
            if value >> (31 - i) & 1 == 1 { bytes[b / 8] |= mask } else { bytes[b / 8] &= ~mask }
        }
    }

    /// Never 0 or all-ones, which read as an empty slot.
    private static func standIn(for serial: UInt32, bits: Int) -> UInt32 {
        let mask: UInt32 = bits == 32 ? .max : (1 << bits) - 1
        let input = (0..<4).map { UInt8(truncatingIfNeeded: serial >> ($0 * 8)) } + [UInt8(bits)]
        let digest = Array(SHA256.hash(data: installSalt + Data(input)))
        var value = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } & mask
        if value == 0 || value == mask { value = 1 }
        return value
    }

    /// Created on first use.
    private static let installSalt: Data = {
        let key = "_captureFingerprintSalt"
        if let salt = UserDefaults.standard.data(forKey: key) { return salt }
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        UserDefaults.standard.set(salt, forKey: key)
        return salt
    }()

    private struct Seen {
        /// Each serial with its stand-in, hashed once.
        var penSerials: [UInt32: UInt32] = [:]
        /// Where each device's reports carry a pen serial, by report ID.
        var positions: [PositionKey: Set<SerialPosition>] = [:]
    }

    private static let seen = Locked(Seen())

    private final class Locked<Value>: @unchecked Sendable {
        private var value: Value
        private let lock = NSLock()
        init(_ value: Value) { self.value = value }
        func withLock<R>(_ body: (inout Value) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    private static let expressKeyRemoteProductID = 0x0331
    private static let pairingSlotCount = 5
    private static let pairingSlotStride = 6
}
