// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// main.swift — Import checks for per-pen settings in backup files.
//
// Per-pen entries were written under export-only names (`tip`, `smoothing`)
// as translated labels, which the importer didn't recognize, so a pen's
// settings never imported. Exports now use storage-key names with machine
// values; older files still import what their labels can say.
// Run via tools/tests/configuration-tool-tests/run.sh.

import Foundation

private func binding(_ values: [String: Any], _ key: String) -> ButtonBinding? {
    (values[key] as? String).flatMap(ButtonBinding.decode)
}

private let futureAction = #"{"kind":"futureAction","keyCode":0,"modifierFlags":0,"keyLabel":""}"#

/// A tool entry as the exporter writes it, from a German-language app.
private let exportedTool: [String: Any] = [
    "tipBinding": "Linksklick", "tipBindingKey": ButtonBinding.leftClick.encoded,
    "penButton2Binding": "Pan View", "penButton2BindingKey": ButtonBinding(kind: .scrollDrag).encoded,
    "penButton3Binding": "Doppelklick", "penButton3BindingKey": ButtonBinding(kind: .doubleClick).encoded,
    "wheelBinding": "", "eraserBinding": futureAction, "eraserBindingKey": futureAction,
    "smoothingStrength": 0.3, "pressureThreshold": 0.05, "panScrollSpeed": 1.5, "panScrollMomentum": true,
]

private func testCurrentFormat() {
    let values = ConfigurationImporter.decodeToolSettings(exportedTool)
    expect(binding(values, "tipBinding") == .leftClick, "the tip imports from its machine value, whatever the label's language")
    expect(binding(values, "penButton2Binding")?.kind == .scrollDrag, "side button 2 imports")
    expect(binding(values, "penButton3Binding")?.kind == .doubleClick, "side button 3 imports")
    expect(values["wheelBinding"] == nil, "an empty action with no machine value imports nothing")
    expect(
        binding(values, "eraserBinding")?.unrecognizedKindName == "futureAction",
        "an action this build can't read imports as written, not None")
    expect(values["smoothingStrength"] as? Double == 0.3, "smoothing imports")
    expect(values["pressureThreshold"] as? Double == 0.05, "the pressure threshold imports")
    expect(values["panScrollSpeed"] as? Double == 1.5, "Pan View speed imports")
    expect(values["panScrollMomentum"] as? Bool == true, "Pan View momentum imports")
}

private func testOlderFormat() {
    let values = ConfigurationImporter.decodeToolSettings([
        "tip": "Left Click", "eraser": "Eraser", "penButton1": "Rechtsklick", "penButton2": "None",
        "smoothing": 0.2,
    ])
    expect(binding(values, "tipBinding") == .leftClick, "an older file's tip label imports")
    expect(binding(values, "eraserBinding")?.kind == .eraser, "an older file's eraser label imports")
    expect(values["penButton1Binding"] == nil, "a label naming no action is skipped, not imported as None")
    expect(binding(values, "penButton2Binding") == ButtonBinding.none, "an older file's None stays None")
    expect(values["smoothingStrength"] as? Double == 0.2, "an older file's smoothing imports")
}

private func testParsedFile() {
    let file: [String: Any] = [
        "version": 2,
        "tablets": [[
            "productID": "0x0358", "modelName": "Intuos Pro L (PTH-860)",
            "tools": [["id": "0x1A2B3C4D", "kind": "Grip Pen", "settings": exportedTool]],
        ]],
    ]
    let data = try! JSONSerialization.data(withJSONObject: file)
    let plan = MainActor.assumeIsolated { try? ConfigurationImporter.parse(data, registry: DeviceRegistry()) }
    guard let tool = plan?.entries.first?.toolSettings.first else {
        return expect(false, "the file's pen must reach the import plan")
    }
    expect(tool.toolID == "0x1A2B3C4D", "the pen keeps its ID")
    expect(binding(tool.values, "tipBinding") == .leftClick, "the pen's tip reaches the import plan")
}

/// Settings the importer has no case for come back as stored: a flag, a
/// number, or a string, read the way a parsed file delivers them.
func testUnlistedKeysRoundTrip() {
    let json = """
    {"dragThreshold": 7.5, "tipUpAssistDelay": 80, "touchEnabled": true,
     "bezelButtonBindings": "[]", "someData": {"a": 1}, "someList": [1, 2]}
    """
    let parsed = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    let values = ConfigurationImporter.decodeStoredSettings(parsed)
    expectEqual(values["dragThreshold"] as? Double, 7.5, "unlisted number imports")
    expectEqual(values["tipUpAssistDelay"] as? Double, 80, "unlisted whole number imports")
    expect(values["touchEnabled"] is Bool, "unlisted flag imports as a flag, not a number")
    expectEqual(values["touchEnabled"] as? Bool, true, "unlisted flag keeps its value")
    expectEqual(values["bezelButtonBindings"] as? String, "[]", "unlisted string imports")
    expect(values["someData"] == nil, "a dictionary isn't taken as a plain value")
    expect(values["someList"] == nil, "a list isn't taken as a plain value")
    let plainNumber = ConfigurationImporter.plainValue(NSNumber(value: 1))
    expect(plainNumber is Double, "a stored 1 exports as a number, not a flag")
}

testCurrentFormat()
testOlderFormat()
testParsedFile()
testUnlistedKeysRoundTrip()

finish()
