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

testCurrentFormat()
testOlderFormat()
testParsedFile()

if failures == 0 {
    print("configuration-tool-tests: \(checks) checks passed")
    exit(0)
}
FileHandle.standardError.write(Data("configuration-tool-tests: \(failures) of \(checks) checks failed\n".utf8))
exit(1)
