// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Identity of one physical device instance.
///
/// The app has two identity axes that historically shared one key:
/// - **Model** — the canonical USB product ID. Correct for decoder, spec, and
///   capability lookups (how Wacom's tables and libwacom key everything).
/// - **Instance** — the physical unit. Nicknames, settings namespaces,
///   contexts, battery state, and windows belong to an instance, and keying
///   them by PID alone silently collapses two identical devices into one.
///
/// This type carries both. The instance token comes from the USB serial when
/// the device reports one, else the IOKit locationID (stable per port), else
/// empty — which degrades to today's PID-only behavior.
///
/// Settings namespaces follow the claim-the-legacy-prefix rule: the first
/// instance ever seen for a PID keeps the historical `device-0x{PID}.`
/// prefix (so existing installs lose nothing); later instances of the same
/// PID get `device-0x{PID}#{instance}.` fresh namespaces. The claim map
/// lives in DeviceRegistry.
struct DeviceInstanceKey: Hashable, Codable {
    /// Canonical model PID (transport variants already folded by
    /// `canonicalProductID`).
    let productID: Int
    /// Instance token: USB serial, `loc-XXXXXXXX` from locationID, or ""
    /// when the device exposes neither.
    let instance: String

    init(productID: Int, instance: String) {
        self.productID = productID
        self.instance = instance
    }

    /// Builds the key from what IOKit exposes at connect time.
    init(productID: Int, usbSerial: String?, locationID: Int) {
        let token: String
        if let serial = usbSerial, !serial.isEmpty {
            token = serial
        } else if locationID != 0 {
            token = String(format: "loc-%08X", locationID)
        } else {
            token = ""
        }
        self.init(productID: productID, instance: token)
    }

    /// Stable string form for persistence, window restore, and logs:
    /// `"0x{PID}"` when the instance token is empty, else
    /// `"0x{PID}#{instance}"`.
    var stringValue: String {
        let pidHex = "0x" + String(productID, radix: 16, uppercase: true)
        return instance.isEmpty ? pidHex : "\(pidHex)#\(instance)"
    }

    /// Parses `stringValue` back; nil if the PID portion isn't valid hex.
    init?(stringValue: String) {
        let parts = stringValue.split(separator: "#", maxSplits: 1)
        guard let first = parts.first, first.hasPrefix("0x"),
            let pid = Int(first.dropFirst(2), radix: 16)
        else { return nil }
        self.init(productID: pid, instance: parts.count > 1 ? String(parts[1]) : "")
    }
}
