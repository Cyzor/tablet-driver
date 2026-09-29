// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// Which byte positions of a report hold a hardware serial.
///
/// A capture records report bytes verbatim, and some devices put a serial
/// number in them. That is the one thing in a report which names the user's
/// hardware rather than describing the model, and these files get attached to
/// public issues.
///
/// Free of the capture types on purpose, so the checks can compile it rather
/// than restate it.
enum CaptureSerialRedaction {

    /// Byte positions to withhold, for one device and report ID.
    ///
    /// The ExpressKey Remote puts its serial on the wire twice: report 0x11
    /// carries the sending remote's at bytes 3–5, and report 0x10 — the
    /// receiver's pairing table — repeats one per 6-byte slot at j+4...6.
    /// Both are 24-bit LE. See `ExpressKeyRemoteDecoder` for the layout.
    ///
    /// Only what identifies a unit. Occupancy is all the serial is read for,
    /// and the byte stays listed as present, so a masked pairing table still
    /// answers "was a remote paired" — the question a capture exists to
    /// settle.
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

    /// Salted fingerprints of the serials a report carries, labeled by where
    /// they sit ("sender", "slot0"…), so two captures can say "same remote"
    /// without the serial. Unsalted, a 24-bit serial falls to brute force;
    /// the salt never leaves the Mac, so fingerprints only compare within one
    /// install. Empty and all-FF slots are skipped.
    static func serialFingerprints(
        productID: Int, reportID: UInt8, bytes: [UInt8], salt: Data
    ) -> [String] {
        let offsets = serialByteOffsets(productID: productID, reportID: reportID)
        return stride(from: 0, to: offsets.count, by: 3).compactMap { start in
            let group = offsets[start..<Swift.min(start + 3, offsets.count)]
            guard let last = group.last, last < bytes.count else { return nil }
            let serial = group.map { bytes[$0] }
            if serial.allSatisfy({ $0 == 0 }) || serial.allSatisfy({ $0 == 0xFF }) { return nil }
            let digest = SHA256.hash(data: salt + Data(serial))
            let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
            let label = reportID == 0x10 ? "slot\(start / 3)" : "sender"
            return "\(label):\(hex)"
        }
    }

    private static let expressKeyRemoteProductID = 0x0331
    private static let pairingSlotCount = 5
    private static let pairingSlotStride = 6
}
