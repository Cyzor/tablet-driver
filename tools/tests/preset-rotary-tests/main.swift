// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// main.swift — Import checks for ring/dial mode lists in backup files.
//
// Mode lists are stored as Data and exported as embedded JSON. Older code
// expected a JSON string, and older files carry neither, so all three shapes
// are exercised here. Run via tools/tests/preset-rotary-tests/run.sh.

import Foundation

private var failures = 0
private var checks = 0

private func expect(
    _ condition: Bool, _ message: @autoclosure () -> String,
    file: StaticString = #file, line: UInt = #line
) {
    checks += 1
    guard !condition else { return }
    failures += 1
    FileHandle.standardError.write(Data("FAIL (\(file):\(line)): \(message())\n".utf8))
}

private func slots(_ actions: [ControlSlot.Action]) -> [ControlSlot] {
    actions.map { ControlSlot(label: "", action: $0) }
}

/// What the exporter writes: the stored bytes, parsed to a JSON object.
private func exported<T: Encodable>(_ value: T) -> Any {
    try! JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}

private let twoDials = RotarySet(
    controls: [RotaryConfig(slots: slots([.zoom, .scroll]), activeSlotIndex: 1),
               RotaryConfig(slots: slots([.rotate, .skip]), activeSlotIndex: 0)],
    controlsAreIndependent: true)

private func decodedRotaries(_ values: [String: Any]) -> RotarySet? {
    (values["rotariesJSON"] as? Data).flatMap { try? JSONDecoder().decode(RotarySet.self, from: $0) }
}

private func testStoredRotariesRoundTrip() {
    let values = PresetImporter.decodeStoredSettings(["rotariesJSON": exported(twoDials)])
    guard let set = decodedRotaries(values) else {
        return expect(false, "rotariesJSON must import as decodable Data")
    }
    expect(set.controls.count == 2, "both dials survive")
    expect(set.controls[0].slots.first?.action == .zoom, "left dial keeps its modes")
    expect(set.controls[1].slots.first?.action == .rotate, "right dial keeps its own modes")
    expect(set.controls[0].activeSlotIndex == 1, "active mode survives")
}

private func testStoredSlotsRoundTrip() {
    let values = PresetImporter.decodeStoredSettings(["touchRingSlotsJSON": exported(slots([.rotate, .zoom]))])
    let decoded = (values["touchRingSlotsJSON"] as? Data)
        .flatMap { try? JSONDecoder().decode([ControlSlot].self, from: $0) }
    expect(decoded?.map(\.action) == [.rotate, .zoom], "ring modes import as Data")
}

private func testStringFormAccepted() {
    let json = String(data: try! JSONEncoder().encode(slots([.scroll])), encoding: .utf8)!
    let values = PresetImporter.decodeStoredSettings(["touchRingSlotsJSON": json])
    expect(values["touchRingSlotsJSON"] is Data, "a JSON string still imports, stored as Data")
}

private func testMalformedRejected() {
    let values = PresetImporter.decodeStoredSettings([
        "touchRingSlotsJSON": ["not": "a list"],
        "rotariesJSON": "{broken",
    ])
    expect(values["touchRingSlotsJSON"] == nil, "wrong shape is dropped")
    expect(values["rotariesJSON"] == nil, "unparseable JSON is dropped")
}

private func testOldFileLeavesDialsUnset() {
    var values: [String: Any] = [:]
    PresetImporter.decodeDeviceSettings(["smoothing": 0.5], into: &values)
    for key in ["rotariesJSON", "touchRingSlotsJSON", "touchRingButtonBinding2",
                "reverseRingDirection", "touchRingActiveSlotIndex2"] {
        expect(values[key] == nil, "\(key) stays unset for a file that predates it")
    }
}

private func testDeviceSettingsCarrySecondDial() {
    var values: [String: Any] = [:]
    PresetImporter.decodeDeviceSettings([
        "rotaries": exported(twoDials),
        "touchRingButton2Key": ButtonBinding(kind: .ringCycle2).encoded,
        "reverseRingDirection": true,
        "touchRingActiveSlotIndex2": 1,
    ], into: &values)
    expect(decodedRotaries(values)?.controls.count == 2, "device-level rotaries import")
    expect(values["touchRingButtonBinding2"] as? String == ButtonBinding(kind: .ringCycle2).encoded,
           "second toggle key imports")
    expect(values["reverseRingDirection"] as? Bool == true, "direction imports")
    expect(values["touchRingActiveSlotIndex2"] as? Int == 1, "second active index imports")
}

testStoredRotariesRoundTrip()
testStoredSlotsRoundTrip()
testStringFormAccepted()
testMalformedRejected()
testOldFileLeavesDialsUnset()
testDeviceSettingsCarrySecondDial()

if failures == 0 {
    print("preset-rotary-tests: \(checks) checks passed")
    exit(0)
}
FileHandle.standardError.write(Data("preset-rotary-tests: \(failures) of \(checks) checks failed\n".utf8))
exit(1)
