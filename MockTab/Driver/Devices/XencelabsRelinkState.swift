// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

/// Tracks a wireless Quick Keys puck's link through the receiver relaying it,
/// and says when the driver should send the relink handshake.
///
/// Confirmed 2026-07-06: the dongle only relays a paired puck's live 0xF0
/// aux data once the driver re-sends the tablet-mode init
/// ([0x02, 0xB0, 0x04]) with the puck's own 6-byte hardware identifier
/// appended at offset 10-15 — without it the dongle sits sending
/// connect-time status frames (tags 0xF8/0xF2) forever and never
/// upgrades to real button data. That identifier isn't available from any
/// GetReport call or from the dongle's own descriptors — but the puck
/// broadcasts it unprompted, unconditionally, in the trailer of every
/// single report it sends (status or real data alike, over the dongle
/// *and* direct USB), so we can read it off the wire instead of needing
/// any prior pairing record. One-shot per dongle connection.
///
/// Owned by the driver and used only on HIDThread.
struct XencelabsRelinkState {

    /// Devices whose report-2 tunnel can relay a wireless Quick Keys puck and
    /// therefore need the relink/re-arm/resync handling: the standalone USB
    /// dongle, and the Pen Display — no radio of its own, but when the dongle
    /// sits in the display's USB slot the display firmware aggregates the
    /// puck traffic into its own vendor tunnel (confirmed 2026-07-08 via two
    /// discovery captures — 0xF8/0xF2 status frames with the puck's identity
    /// trailer, plus live 0xF0 aux data, all arriving on 0x520D).
    static let relayProductIDs: Set<Int> = [0x5203, 0x520D]
    static let identityLength = 6

    /// What one report changed about the link.
    enum LinkChange: Equatable {
        /// An online status frame arrived after a relink: send it again.
        case rearmed
        case offline
    }

    struct Outcome: Equatable {
        var linkChange: LinkChange?
        /// Send the relink handshake addressed to this identity.
        var relinkIdentity: [UInt8]?
    }

    private(set) var dongleRelinked = false
    /// True once the display push is scheduled for this relink.
    private(set) var postRelinkResynced = false
    /// Bumped when the puck reconnects or goes offline, so a pending display
    /// push from an earlier connection stands down.
    private(set) var relinkGeneration = 0
    /// The puck's 6-byte identity read off the relink report, kept so the
    /// resync's label-reset write can address the same puck.
    private(set) var dongleIdentity: [UInt8]?

    /// Reads one report from a Xencelabs device with product ID `productID`.
    mutating func noteReport(
        _ report: UnsafePointer<UInt8>, length: Int, productID: Int
    ) -> Outcome {
        var outcome = Outcome()
        guard Self.relayProductIDs.contains(productID) else { return outcome }

        // The receiver's 0xF8 status frame says whether a paired puck is
        // online: byte 2 bit 1, slot in byte 3. Each online frame means the
        // puck (re)connected and needs the handshake and display again; an
        // offline frame means it left. The vendor driver acts on these alone.
        let status: Bool? = {
            guard length >= 4, report[0] == 0x02, report[1] == 0xF8, report[2] != 0,
                (1...2).contains(report[3])
            else { return nil }
            return report[2] & 0x02 != 0
        }()
        if status == true, dongleRelinked {
            outcome.linkChange = .rearmed
            dongleRelinked = false
            postRelinkResynced = false
            relinkGeneration += 1
        } else if status == false {
            outcome.linkChange = .offline
            relinkGeneration += 1
        }

        // Relink: send the tablet-mode init once with the puck's own
        // identifier appended, read straight off this report's trailer. The
        // offset isn't constant across frame shapes: the one-off
        // connect/restart announcement (tag 0xF8, byte[2]==0x02,
        // byte[3]==0x01) carries it at offset 10, but ordinary ongoing
        // traffic (live 0xF0 aux/button frames, and the 0xF2 battery-poll
        // reply) carries it two bytes later, at offset 12 — confirmed
        // 2026-07-14 by diffing a captured aux frame against the announce
        // frame byte-for-byte. Getting this wrong silently "succeeds": the
        // wrong offset still yields a nonzero-looking value (it overlaps the
        // real identity, just shifted), so every subsequent write gets
        // addressed to a garbled identity that the puck quietly drops — no
        // relink ever visibly fails, but nothing it addresses ever arrives
        // either. This is why battery (and potentially OLED/LED) only worked
        // right after a power-cycle: only the announce frame happened to use
        // the offset this code originally assumed.
        let identityOffset = status == true ? 10 : 12
        if status != false, !dongleRelinked, length >= identityOffset + Self.identityLength,
            report[0] == 0x02,  // XencelabsDecoder.penReportID (internal, not visible here)
            report[1] & 0xF0 == 0xF0  // puck tags only; the Pen Display's pen frames share report 2
        {
            let identity = (0..<Self.identityLength).map {
                report[identityOffset + $0]
            }
            if identity.contains(where: { $0 != 0 }) {
                dongleRelinked = true
                dongleIdentity = identity
                outcome.relinkIdentity = identity
            }
        }
        return outcome
    }

    /// Records the relink's result. Returns the generation to schedule the
    /// display push for, or nil when no push is due.
    mutating func relinkSent(succeeded: Bool) -> Int? {
        guard succeeded, !postRelinkResynced else { return nil }
        postRelinkResynced = true
        return relinkGeneration
    }
}
