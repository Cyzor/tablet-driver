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

/// The claim-the-legacy-prefix rule, over an injectable UserDefaults so the
/// standalone harness in `tools/instance-identity-tests/` can exercise it
/// against a scratch suite. `DeviceRegistry` owns the app's live instance
/// (`UserDefaults.standard`); nothing else should construct one.
struct DeviceInstanceClaims {
    let ud: UserDefaults
    /// Called when an unclaimed instance takes the legacy prefix — the
    /// registry hooks its logger in here; the harness leaves it nil.
    var onClaim: ((_ pidHex: String) -> Void)?

    private static let claimsKey = "_instanceClaims"

    /// Resolves the UserDefaults settings prefix for one physical device
    /// instance: the first instance ever seen for a PID permanently claims
    /// the historical `device-0x{PID}.` prefix; any other instance of the
    /// same PID gets a fresh `device-0x{PID}#{instance}.` namespace.
    /// Instances with no token always resolve to the legacy prefix.
    func settingsPrefix(for key: DeviceInstanceKey) -> String {
        let pidHex = String(key.productID, radix: 16, uppercase: true)
        let legacyPrefix = "device-0x\(pidHex)."
        guard !key.instance.isEmpty else { return legacyPrefix }

        var claims = claimMap()
        if let owner = claims[pidHex] {
            return owner == key.instance
                ? legacyPrefix
                : prefix(for: key)
        }
        claims[pidHex] = key.instance
        save(claims)
        onClaim?(pidHex)
        return legacyPrefix
    }

    /// Row-normalized instance token: nil for the claimed unit (its row and
    /// namespace stay in the legacy, un-suffixed form), the raw token for
    /// any additional unit of the same model. Read-only — never claims.
    func rowInstance(for key: DeviceInstanceKey) -> String? {
        guard !key.instance.isEmpty else { return nil }
        let pidHex = String(key.productID, radix: 16, uppercase: true)
        return claimMap()[pidHex] == key.instance ? nil : key.instance
    }

    /// Pure prefix formatting for a row-normalized key (no claim lookup —
    /// use `settingsPrefix(for:)` for live-device resolution).
    func prefix(for key: DeviceInstanceKey) -> String {
        let pidHex = String(key.productID, radix: 16, uppercase: true)
        return key.instance.isEmpty
            ? "device-0x\(pidHex)."
            : "device-0x\(pidHex)#\(key.instance)."
    }

    /// Claim-normalized form: the claimed unit's key folds to the empty
    /// instance (legacy identity), any other unit keeps its token.
    func normalizedKey(_ key: DeviceInstanceKey) -> DeviceInstanceKey {
        DeviceInstanceKey(productID: key.productID, instance: rowInstance(for: key) ?? "")
    }

    private func claimMap() -> [String: String] {
        guard let data = ud.data(forKey: Self.claimsKey),
            let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    private func save(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        ud.set(data, forKey: Self.claimsKey)
    }
}
