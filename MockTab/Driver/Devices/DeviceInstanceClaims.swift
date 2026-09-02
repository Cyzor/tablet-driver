// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TabletKit

/// The claim-the-legacy-prefix rule for per-device settings namespaces.
///
/// `DeviceInstanceKey` (the identity value itself) lives in TabletKit; this is
/// the host policy that maps an instance to a `UserDefaults` prefix, and it
/// stays in the app because it owns a `UserDefaults` key layout the library
/// must not promise.
///
/// The rule: the first instance ever seen for a PID permanently claims the
/// historical `device-0x{PID}.` prefix (so existing installs lose nothing);
/// any other instance of the same PID gets a fresh
/// `device-0x{PID}#{instance}.` namespace.
///
/// Over an injectable `UserDefaults` so the standalone harness in
/// `tools/tests/instance-identity-tests/` can exercise it against a scratch
/// suite. `DeviceRegistry` owns the app's live instance
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
