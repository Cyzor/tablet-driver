// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// InstanceIdentityTests.swift — Standalone checks for the instance-identity
// claim rule (DeviceInstanceKey + DeviceInstanceClaims).
//
// The app has no XCTest target (by design — see the project's test
// conventions), so these run as a small executable compiled against the real
// DeviceInstanceKey.swift, seeded into a scratch UserDefaults suite. Run via
// tools/instance-identity-tests/run.sh. Exits non-zero on the first failure.

import Foundation

// MARK: - Tiny assertion harness

private var failures = 0
private var checks = 0

private func expect(_ condition: Bool, _ message: @autoclosure () -> String,
                    file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition {
        failures += 1
        FileHandle.standardError.write(Data("FAIL (\(file):\(line)): \(message())\n".utf8))
    }
}

private func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: @autoclosure () -> String,
                                       file: StaticString = #file, line: UInt = #line) {
    expect(a == b, "\(message()) — got \(a), expected \(b)", file: file, line: line)
}

/// Fresh scratch defaults per test, wiped before use.
private func scratchDefaults(_ name: String) -> UserDefaults {
    let suite = "com.cyzor.mocktab.instance-identity-tests.\(name)"
    let ud = UserDefaults(suiteName: suite)!
    ud.removePersistentDomain(forName: suite)
    return ud
}

private let pth860 = 0x0357

// MARK: - Key string round-trip

private func testKeyStringRoundTrip() {
    let cases = [
        DeviceInstanceKey(productID: pth860, instance: ""),
        DeviceInstanceKey(productID: pth860, instance: "9KL0123456"),
        DeviceInstanceKey(productID: 0x5202, instance: "loc-14200000"),
        DeviceInstanceKey(productID: 0xF4, instance: "serial with spaces"),
    ]
    for key in cases {
        expectEqual(DeviceInstanceKey(stringValue: key.stringValue), key,
                    "round-trip \(key.stringValue)")
    }
    expectEqual(DeviceInstanceKey(productID: pth860, instance: "").stringValue, "0x357",
                "empty-instance string form")
    expect(DeviceInstanceKey(stringValue: "357") == nil, "missing 0x prefix rejected")
    expect(DeviceInstanceKey(stringValue: "0xZZ") == nil, "non-hex PID rejected")
}

private func testTokenSelection() {
    expectEqual(
        DeviceInstanceKey(productID: pth860, usbSerial: "ABC", locationID: 0x14200000).instance,
        "ABC", "serial wins over locationID")
    expectEqual(
        DeviceInstanceKey(productID: pth860, usbSerial: "", locationID: 0x14200000).instance,
        "loc-14200000", "empty serial falls back to locationID")
    expectEqual(
        DeviceInstanceKey(productID: pth860, usbSerial: nil, locationID: 0).instance,
        "", "neither → empty token (legacy identity)")
}

/// The Xencelabs Quick Keys wireless dongle relay reports the puck's serial
/// as a literal all-zero string rather than omitting it — that must not be
/// taken as a real instance token (it used to split a wirelessly-connected
/// puck into its own row and settings namespace next to the wired one).
private func testPlaceholderSerialTreatedAsAbsent() {
    expect(DeviceInstanceKey.isPlaceholderSerial("000000000000"),
           "all-zero serial recognized as placeholder")
    expect(DeviceInstanceKey.isPlaceholderSerial("00:00:00:00:00:00"),
           "all-zero MAC-style serial recognized as placeholder")
    expect(!DeviceInstanceKey.isPlaceholderSerial("XP213BV1001188"),
           "real serial not mistaken for placeholder")
    expectEqual(
        DeviceInstanceKey(productID: 0x5202, usbSerial: "000000000000", locationID: 0x14200000)
            .instance,
        "loc-14200000", "placeholder serial falls back to locationID like an absent one")
    expectEqual(
        DeviceInstanceKey(productID: 0x5202, usbSerial: "000000000000", locationID: 0).instance,
        "", "placeholder serial with no locationID falls back to legacy identity")
}

// MARK: - Claim rule

/// An existing install: the first instance seen for a PID claims the legacy
/// prefix, and every pre-existing key under it stays readable as-is.
private func testFirstInstanceClaimsLegacyPrefix() {
    let ud = scratchDefaults("claim")
    // Realistic legacy key set, written the way the app writes them.
    let legacy = "device-0x357."
    ud.set(0.42, forKey: legacy + "pressureCurve")
    ud.set("{\"samples\":[]}", forKey: legacy + "calibrationJSON")
    ud.set(["p1", "p2"], forKey: legacy + "presetNames")

    let claims = DeviceInstanceClaims(ud: ud)
    let unit = DeviceInstanceKey(productID: pth860, instance: "9KL0123456")

    expectEqual(claims.settingsPrefix(for: unit), legacy, "first instance claims legacy prefix")
    // Every pre-existing key remains readable through the resolved prefix.
    expectEqual(ud.double(forKey: claims.settingsPrefix(for: unit) + "pressureCurve"), 0.42,
                "legacy value readable after claim")
    expectEqual(ud.stringArray(forKey: legacy + "presetNames") ?? [], ["p1", "p2"],
                "untouched sibling key intact")
}

/// The claim is persisted: deterministic across "reboots" (new instances over
/// the same suite) and not connect-order dependent afterward.
private func testClaimIsSticky() {
    let ud = scratchDefaults("sticky")
    let first = DeviceInstanceKey(productID: pth860, instance: "AAA")
    let second = DeviceInstanceKey(productID: pth860, instance: "BBB")

    _ = DeviceInstanceClaims(ud: ud).settingsPrefix(for: first)
    // "Relaunch": a fresh value over the same defaults. The second unit
    // connecting first now must NOT steal the claim.
    let relaunch = DeviceInstanceClaims(ud: ud)
    expectEqual(relaunch.settingsPrefix(for: second), "device-0x357#BBB.",
                "second unit gets suffixed namespace")
    expectEqual(relaunch.settingsPrefix(for: first), "device-0x357.",
                "claimed unit keeps legacy prefix across relaunch")
}

/// A second synthetic instance inherits nothing from the claimed one.
private func testSecondInstanceInheritsNothing() {
    let ud = scratchDefaults("fresh")
    ud.set(0.42, forKey: "device-0x357.pressureCurve")
    let claims = DeviceInstanceClaims(ud: ud)
    _ = claims.settingsPrefix(for: DeviceInstanceKey(productID: pth860, instance: "AAA"))
    let secondPrefix = claims.settingsPrefix(
        for: DeviceInstanceKey(productID: pth860, instance: "BBB"))
    expect(ud.object(forKey: secondPrefix + "pressureCurve") == nil,
           "second unit's namespace starts empty")
}

/// An empty token always resolves to the legacy prefix and never claims —
/// PID-only degradation must not lock out the real serial seen later.
private func testEmptyTokenNeverClaims() {
    let ud = scratchDefaults("empty")
    let claims = DeviceInstanceClaims(ud: ud)
    expectEqual(claims.settingsPrefix(for: DeviceInstanceKey(productID: pth860, instance: "")),
                "device-0x357.", "empty token resolves to legacy prefix")
    // The real unit connecting later still claims.
    expectEqual(claims.settingsPrefix(for: DeviceInstanceKey(productID: pth860, instance: "AAA")),
                "device-0x357.", "serial seen after empty token still claims legacy prefix")
}

/// Two models don't share claims; same serial under different PIDs is fine.
private func testClaimsArePerModel() {
    let ud = scratchDefaults("permodel")
    let claims = DeviceInstanceClaims(ud: ud)
    expectEqual(claims.settingsPrefix(for: DeviceInstanceKey(productID: 0x0357, instance: "S")),
                "device-0x357.", "model A claims")
    expectEqual(claims.settingsPrefix(for: DeviceInstanceKey(productID: 0x0358, instance: "S")),
                "device-0x358.", "model B claims independently")
}

// MARK: - Normalization

/// The claimed unit and the legacy empty-instance identity normalize equal —
/// what window matching and restore rely on.
private func testNormalization() {
    let ud = scratchDefaults("normalize")
    let claims = DeviceInstanceClaims(ud: ud)
    let claimed = DeviceInstanceKey(productID: pth860, instance: "AAA")
    let other = DeviceInstanceKey(productID: pth860, instance: "BBB")
    let legacy = DeviceInstanceKey(productID: pth860, instance: "")
    _ = claims.settingsPrefix(for: claimed)

    expectEqual(claims.normalizedKey(claimed), legacy, "claimed unit folds to legacy identity")
    expectEqual(claims.normalizedKey(legacy), legacy, "legacy identity is a fixed point")
    expectEqual(claims.normalizedKey(other), other, "second unit keeps its token")
    expect(claims.normalizedKey(claimed) != claims.normalizedKey(other),
           "distinct units stay distinct")
    // rowInstance is read-only: normalizing an unclaimed model must not claim.
    let ud2 = scratchDefaults("normalize-readonly")
    let claims2 = DeviceInstanceClaims(ud: ud2)
    _ = claims2.normalizedKey(DeviceInstanceKey(productID: pth860, instance: "CCC"))
    expectEqual(claims2.settingsPrefix(for: DeviceInstanceKey(productID: pth860, instance: "DDD")),
                "device-0x357.", "normalization did not consume the claim")
}

// MARK: - Runner

@main
enum InstanceIdentityTestRunner {
    static func main() {
        testKeyStringRoundTrip()
        testTokenSelection()
        testPlaceholderSerialTreatedAsAbsent()
        testFirstInstanceClaimsLegacyPrefix()
        testClaimIsSticky()
        testSecondInstanceInheritsNothing()
        testEmptyTokenNeverClaims()
        testClaimsArePerModel()
        testNormalization()

        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("\(failures) of \(checks) checks failed\n".utf8))
            exit(1)
        }
    }
}
