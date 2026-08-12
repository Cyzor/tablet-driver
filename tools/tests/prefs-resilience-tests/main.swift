// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// PrefsResilienceTests.swift — Checks for the version-skew resilience added to
// the composite JSON-blob prefs structs (Profile, AppOverride, BezierCurve,
// ControlSlot): an older build must not silently drop fields a newer build
// wrote when it re-encodes one of these structs.
//
// Covers:
//   1. Round-trip: a struct decoded from JSON containing an unrecognized
//      field (simulating a newer app version's format) must re-emit that
//      field unchanged when re-encoded by this build.
//   2. Decode-failure detection: JSONDecoder throws (rather than silently
//      degrading) when a required field is missing, which is the signal
//      TabletSettings uses to block a save that would clobber unparseable
//      newer-format data. See TabletSettings+Persistence.swift,
//      TabletSettings+Presets.swift, TabletSettings+AppOverrides.swift —
//      each save function is guarded by a `*LoadFailed` flag set only in
//      this branch. That guard isn't exercised here because it lives on
//      TabletSettings, which depends on TabletKit/AppKit runtime state and
//      isn't practical to compile standalone; this test instead verifies
//      the underlying decode behavior the guard relies on.
//
// The app has no XCTest target (by design — see the project's test
// conventions), so this runs as a small executable compiled against the
// real source files. Run via tools/prefs-resilience-tests/run.sh. Exits
// non-zero on the first failure.

import Foundation

// MARK: - Tiny assertion harness

private var failures = 0
private var checks = 0

private func expect(
    _ condition: Bool, _ message: @autoclosure () -> String,
    file: StaticString = #file, line: UInt = #line
) {
    checks += 1
    if !condition {
        failures += 1
        FileHandle.standardError.write(Data("FAIL (\(file):\(line)): \(message())\n".utf8))
    }
}

// MARK: - BezierCurve round-trip

do {
    // A "future" version's payload: adds a hypothetical p3 field this build
    // doesn't know about.
    let futureJSON = """
        {"p1":[0.25,0.25],"p2":[0.75,0.75],"p3":[0.9,0.9],"easing":"custom"}
        """
    let data = Data(futureJSON.utf8)
    let curve = try JSONDecoder().decode(BezierCurve.self, from: data)
    expect(curve.p1.x == 0.25 && curve.p2.y == 0.75, "BezierCurve decodes known fields")

    let reEncoded = try JSONEncoder().encode(curve)
    let roundTripped = try JSONSerialization.jsonObject(with: reEncoded) as? [String: Any]
    expect(roundTripped?["p3"] != nil, "BezierCurve preserves unknown field 'p3' on re-encode")
    expect(
        (roundTripped?["easing"] as? String) == "custom",
        "BezierCurve preserves unknown field 'easing' on re-encode")
}

// MARK: - ControlSlot round-trip

do {
    let bindingJSON = try String(data: JSONEncoder().encode(ButtonBinding.none), encoding: .utf8)!
    let futureJSON = """
        {"id":"9E5A1B2C-1234-4321-ABCD-000000000001","label":"Zoom","action":"scroll",
         "cwBinding":\(bindingJSON),
         "ccwBinding":\(bindingJSON),
         "speed":1.5,"hapticProfile":"soft","gain":42}
        """
    let data = Data(futureJSON.utf8)
    let slot = try JSONDecoder().decode(ControlSlot.self, from: data)
    expect(slot.label == "Zoom" && slot.speed == 1.5, "ControlSlot decodes known fields")

    let reEncoded = try JSONEncoder().encode(slot)
    let roundTripped = try JSONSerialization.jsonObject(with: reEncoded) as? [String: Any]
    expect(
        (roundTripped?["hapticProfile"] as? String) == "soft",
        "ControlSlot preserves unknown field 'hapticProfile' on re-encode")
    expect(
        (roundTripped?["gain"] as? Int) == 42,
        "ControlSlot preserves unknown field 'gain' on re-encode")
}

// MARK: - ButtonBinding round-trip

do {
    let futureJSON = """
        {"kind":"leftClick","keyCode":0,"modifierFlags":0,"keyLabel":"","hapticStrength":7}
        """
    let data = Data(futureJSON.utf8)
    let binding = try JSONDecoder().decode(ButtonBinding.self, from: data)
    expect(binding.kind == .leftClick, "ButtonBinding decodes known fields")

    let reEncoded = try JSONEncoder().encode(binding)
    let roundTripped = try JSONSerialization.jsonObject(with: reEncoded) as? [String: Any]
    expect(
        (roundTripped?["hapticStrength"] as? Int) == 7,
        "ButtonBinding preserves unknown field 'hapticStrength' on re-encode")
}

// MARK: - ControlSlot.LEDColor additive-field precedent (a already exists)

do {
    // Colors saved before the brightness ("a") field existed.
    let legacyJSON = #"{"r":255,"g":0,"b":0}"#
    let color = try JSONDecoder().decode(ControlSlot.LEDColor.self, from: Data(legacyJSON.utf8))
    expect(color.a == 255, "LEDColor defaults missing brightness to full strength")
}

// MARK: - Decode-failure detection (the signal TabletSettings' save guards rely on)

do {
    // Missing a required field ("name") — simulates data written by an even
    // older or malformed build. This must throw so the caller can set its
    // `*LoadFailed` flag and block an overwrite, rather than silently
    // substituting a default and risking a later clobber.
    struct RequiredFieldStruct: Codable {
        var name: String
        var count: Int
    }
    let malformed = Data(#"{"count":3}"#.utf8)
    do {
        _ = try JSONDecoder().decode(RequiredFieldStruct.self, from: malformed)
        expect(false, "Expected decode to throw on missing required field")
    } catch {
        expect(true, "Decode throws on missing required field, as the save guards depend on")
    }
}

// MARK: - Summary

if failures == 0 {
    print("PrefsResilienceTests: \(checks) checks passed")
    exit(0)
} else {
    print("PrefsResilienceTests: \(failures)/\(checks) checks FAILED")
    exit(1)
}
