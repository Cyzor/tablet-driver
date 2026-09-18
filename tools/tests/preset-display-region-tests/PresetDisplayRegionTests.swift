// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// PresetDisplayRegionTests.swift — Standalone checks for the displayRegion
// preset-import backward compatibility added for tablet-driver#15.
//
// The app has no XCTest target, so these run as a small executable compiled
// against the real PresetImporter.swift (decodeDeviceSettings/decodeStoredSettings)
// plus a stand-in for the two types only `parse` (never called here) needs —
// see StubTypes.swift for why. Run via
// tools/tests/preset-display-region-tests/run.sh. Exits non-zero on failure.

import Foundation

private var failures = 0
private var checks = 0

private func expect(
    _ condition: Bool,
    _ message: @autoclosure () -> String,
    file: StaticString = #file,
    line: UInt = #line
) {
    checks += 1
    guard !condition else { return }
    failures += 1
    FileHandle.standardError.write(
        Data("FAIL (\(file):\(line)): \(message())\n".utf8)
    )
}

/// Old backup files (exported before tablet-driver#15) have no "displayRegion"
/// key at all in their "settings" dict — decodeDeviceSettings must leave the
/// four displayRegion* values unset in that case, so TabletSettings.reloadAll()'s
/// compiled-in defaults (0,0,1,1 = full display) apply, matching every build's
/// behavior before this feature existed.
private func testDeviceSettingsMissingDisplayRegionStaysUnset() {
    let deviceSettings: [String: Any] = [
        "tabletArea": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0, "proportionalMapping": true],
        "display": "primary"
    ]
    var values: [String: Any] = [:]
    PresetImporter.decodeDeviceSettings(deviceSettings, into: &values)
    for key in ["displayRegionX", "displayRegionY", "displayRegionWidth", "displayRegionHeight"] {
        expect(values[key] == nil, "\(key) must stay unset when the source file predates displayRegion")
    }
}

/// A file that does carry "displayRegion" (current export format) must
/// decode all four fields through.
private func testDeviceSettingsDecodesDisplayRegion() {
    let deviceSettings: [String: Any] = [
        "display": "display-1",
        "displayRegion": ["x": 0.0, "y": 0.0, "width": 0.6667, "height": 1.0]
    ]
    var values: [String: Any] = [:]
    PresetImporter.decodeDeviceSettings(deviceSettings, into: &values)
    expect(values["displayRegionX"] as? Double == 0.0, "displayRegionX round-trip")
    expect(values["displayRegionY"] as? Double == 0.0, "displayRegionY round-trip")
    expect(values["displayRegionWidth"] as? Double == 0.6667, "displayRegionWidth round-trip")
    expect(values["displayRegionHeight"] as? Double == 1.0, "displayRegionHeight round-trip")
}

/// Out-of-range or non-finite values must be rejected (left unset), same
/// validation discipline as the existing activeArea* fields — guards against
/// a hand-edited or corrupted backup file writing a nonsensical mapping.
private func testDeviceSettingsRejectsInvalidDisplayRegion() {
    let deviceSettings: [String: Any] = [
        "displayRegion": ["x": 1.5, "y": -0.2, "width": 0.0, "height": Double.nan]
    ]
    var values: [String: Any] = [:]
    PresetImporter.decodeDeviceSettings(deviceSettings, into: &values)
    for key in ["displayRegionX", "displayRegionY", "displayRegionWidth", "displayRegionHeight"] {
        expect(values[key] == nil, "\(key) must be rejected when out of range or non-finite")
    }
}

/// decodeStoredSettings (the profile/app-override/tool-settings path, keyed
/// by literal storage key names) must also round-trip the four fields, and
/// must leave them absent from `values` when the source dict doesn't have them.
private func testStoredSettingsRoundTripsDisplayRegion() {
    let stored: [String: Any] = [
        "displayRegionX": 0.25,
        "displayRegionY": 0.0,
        "displayRegionWidth": 0.5,
        "displayRegionHeight": 1.0
    ]
    let values = PresetImporter.decodeStoredSettings(stored)
    expect(values["displayRegionX"] as? Double == 0.25, "decodeStoredSettings displayRegionX")
    expect(values["displayRegionWidth"] as? Double == 0.5, "decodeStoredSettings displayRegionWidth")

    let missing = PresetImporter.decodeStoredSettings(["activeAreaX": 0.1])
    for key in ["displayRegionX", "displayRegionY", "displayRegionWidth", "displayRegionHeight"] {
        expect(missing[key] == nil, "decodeStoredSettings must leave \(key) absent when the source preset predates it")
    }
}

@main
enum PresetDisplayRegionTestRunner {
    static func main() {
        testDeviceSettingsMissingDisplayRegionStaysUnset()
        testDeviceSettingsDecodesDisplayRegion()
        testDeviceSettingsRejectsInvalidDisplayRegion()
        testStoredSettingsRoundTripsDisplayRegion()

        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        }
        FileHandle.standardError.write(Data("\(failures) of \(checks) checks failed\n".utf8))
        exit(1)
    }
}
