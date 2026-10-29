// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// main.swift — Import checks for values the importer can't read. Files from
// before 0.4.0 carry labels only, and the importer reads English ones; a label
// it can't read, as one in another language isn't, must leave the setting
// alone rather than reset it. The same holds for an ExpressKey entry that
// doesn't decode. Run via tools/tests/configuration-label-tests/run.sh.

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

private func deviceValues(_ s: [String: Any]) -> [String: Any] {
    var values: [String: Any] = [:]
    ConfigurationImporter.decodeDeviceSettings(s, into: &values)
    return values
}

private func bindings(_ values: [String: Any], _ key: String) -> [ButtonBinding]? {
    (values[key] as? String).flatMap(ButtonBinding.decodeList)
}

/// A pre-0.4.0 export from a German-language app.
private let germanFile: [String: Any] = [
    "tabletArea": ["orientation": "Hochformat"],
    "penButton1": "Rechtsklick", "penButton2": "Keine",
    "touchRing": "Scrollen", "touchStrip1": "Aus",
    "expressKeys": ["Linksklick", "⌘Z", "Keine"],
]

/// The same file exported in English.
private let englishFile: [String: Any] = [
    "tabletArea": ["orientation": "Portrait"],
    "penButton1": "Right Click", "penButton2": "None",
    "touchRing": "Scroll", "touchStrip1": "Off",
    "expressKeys": ["Left Click", "⌘Z", "None", ""],
]

private func testExpressKeyMachineValues() {
    let future = #"{"kind":"futureAction","keyCode":0,"modifierFlags":0,"keyLabel":""}"#
    let readable = deviceValues(["expressKeysKey": [ButtonBinding.rightClick.encoded, future, ""]])
    let keys = bindings(readable, "expressKeyBindings")
    expect(keys?.count == 16, "a readable ExpressKey list imports, padded to 16")
    expect(keys?.first == .rightClick, "a readable entry keeps its action")
    expect(keys?[1].unrecognizedKindName == "futureAction", "an action from another build survives")
    expect(keys?[2] == ButtonBinding.none, "an empty entry imports as None")

    let garbled = [ButtonBinding.rightClick.encoded, #"{"kind":"leftClick"}"#]
    expect(
        deviceValues(["expressKeysKey": garbled])["expressKeyBindings"] == nil,
        "an entry that doesn't decode leaves the whole ExpressKey list unset")
    expect(
        deviceValues(["expressKeysKey": garbled, "expressKeys": ["Right Click", "Left Click"]])["expressKeyBindings"] == nil,
        "the labels beside an unreadable machine value aren't used in its place")
    let profile = ConfigurationImporter.decodeStoredSettings(
        ["expressKeyBindings": ["", ""], "expressKeyBindingsKey": garbled])
    expect(profile["expressKeyBindings"] == nil, "a profile's unreadable ExpressKey entry leaves its list unset")
}

private func testForeignLabelsLeaveSettingsAlone() {
    let values = deviceValues(germanFile)
    expect(values["tabletOrientation"] == nil, "a foreign orientation label leaves orientation unset, not upright")
    expect(values["penButton1Binding"] == nil, "a foreign action label leaves the button unset, not None")
    expect(values["penButton2Binding"] == nil, "a foreign None label leaves the button unset")
    expect(values["touchRingMode"] == nil, "a foreign ring mode label leaves the mode unset, not Off")
    expect(values["touchStrip1Mode"] == nil, "a foreign strip mode label leaves the mode unset")
    expect(values["expressKeyBindings"] == nil, "a list with any foreign label leaves every ExpressKey unset")
}

private func testEnglishLabelsStillImport() {
    let values = deviceValues(englishFile)
    expect(values["tabletOrientation"] as? Int == 1, "an English orientation label imports")
    expect(
        (values["penButton1Binding"] as? String).flatMap(ButtonBinding.decode) == .rightClick,
        "an English action label imports")
    expect(
        (values["penButton2Binding"] as? String).flatMap(ButtonBinding.decode) == ButtonBinding.none,
        "an English None label imports as None")
    expect(values["touchRingMode"] as? String == TouchRingMode.scroll.rawValue, "an English ring mode imports")
    expect(values["touchStrip1Mode"] as? String == TouchRingMode.off.rawValue, "an English Off imports as Off")
    let keys = bindings(values, "expressKeyBindings")
    expect(keys?.count == 16, "an English ExpressKey list imports, padded to 16")
    expect(keys?.first == .leftClick, "the first ExpressKey keeps its action")
    expect(keys?[1].kind == .keyCombo, "a shortcut label imports in any language")
    expect(keys?[2] == ButtonBinding.none && keys?[3] == ButtonBinding.none, "None and empty labels import as None")
    expect(
        deviceValues(["tabletArea": ["orientation": "Landscape"]])["tabletOrientation"] as? Int == 0,
        "an English Landscape label imports as upright")
}

private func testStoredSettingsLabels() {
    let foreign = ConfigurationImporter.decodeStoredSettings([
        "tabletOrientation": "Hochformat", "tipBinding": "Linksklick",
        "touchRingMode": "Scrollen", "expressKeyBindings": ["Linksklick"],
    ])
    expect(foreign.isEmpty, "a profile's foreign labels import nothing, not resets")
    let english = ConfigurationImporter.decodeStoredSettings([
        "tabletOrientation": "Portrait Flipped", "tipBinding": "Left Click",
    ])
    expect(english["tabletOrientation"] as? Int == 3, "a profile's English orientation imports")
    expect(
        (english["tipBinding"] as? String).flatMap(ButtonBinding.decode) == .leftClick,
        "a profile's English action imports")
}

testForeignLabelsLeaveSettingsAlone()
testEnglishLabelsStillImport()
testStoredSettingsLabels()
testExpressKeyMachineValues()

if failures == 0 {
    print("configuration-label-tests: \(checks) checks passed")
    exit(0)
}
FileHandle.standardError.write(Data("configuration-label-tests: \(failures) of \(checks) checks failed\n".utf8))
exit(1)
