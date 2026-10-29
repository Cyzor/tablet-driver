// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// Checks the Wacom import report against a made-up backup in fixtures/:
// names, pen serials, button functions, keystrokes in each encoding, ring
// modes, the mapping area, per-app differences, and the app entries it
// skips. A fixed layout table stands in for the keyboard layout.

import Foundation

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

/// US layout, only the keys the fixture uses.
let usLayout: [Character: LayoutKey] = [
    "a": LayoutKey(keyCode: 0, needsShift: false), "b": LayoutKey(keyCode: 11, needsShift: false),
    "c": LayoutKey(keyCode: 8, needsShift: false), "z": LayoutKey(keyCode: 6, needsShift: false),
    "1": LayoutKey(keyCode: 18, needsShift: false), "[": LayoutKey(keyCode: 33, needsShift: false),
    "]": LayoutKey(keyCode: 30, needsShift: false), "#": LayoutKey(keyCode: 20, needsShift: true),
]
let layout: LayoutLookup = { usLayout[$0] }

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let backup = try! WacomBackup.load(dir.appendingPathComponent("sample.wacomprefs"))
let report = WacomMapper.report(backup, layout: layout)
let text = ReportText.render(report)

func find(_ tablet: Int, _ app: String, _ section: String, _ control: String) -> Line? {
    report.tablets[tablet].apps.first { $0.name == app }?
        .sections.first { $0.title.hasPrefix(section) }?
        .lines.first { $0.control == control }
}

func mapped(_ l: Line?, _ what: String, _ c: Confidence = .exact) -> Bool {
    if case .mapped(let w, let conf) = l?.outcome { return w == what && conf == c }
    return false
}

func skipped(_ l: Line?, _ reason: String) -> Bool {
    if case .skipped(let r) = l?.outcome { return r.contains(reason) }
    return false
}

func show(_ l: Line?) -> String { l.map(ReportText.line) ?? "missing" }

// Backup and tablets
expect(backup.driverVersion == "6.4.9-2", "Driver version: \(backup.driverVersion ?? "nil")")
expect(report.formatVersion == 6, "Format version")
expect(report.tablets.count == 2, "Two tablets")
expect(report.tablets[0].nickname == "Studio", "Renamed tablet keeps its name")
expect(report.tablets[1].nickname == nil, "Unrenamed tablet has no nickname")
expect(report.tablets[0].notes.contains { $0.contains("application 9") }, "Settings for an unlisted app are noted")

// Pens
let pen = "Pen 0x12345678"
expect(report.tablets[0].apps[0].sections.contains { $0.title == "Pen 0x12345678 (tool code 0x842)" },
       "Pen serial is the low 32 bits of Wacom's sequence")
expect(mapped(find(0, "All applications", pen, "Name"), "tool nickname"), "Custom pen name")
expect(mapped(find(0, "All applications", pen, "Tip"), "tipBinding: leftClick"), show(find(0, "All applications", pen, "Tip")))
expect(mapped(find(0, "All applications", pen, "Eraser"), "eraserBinding: eraser"), "Eraser")
expect(mapped(find(0, "All applications", pen, "Lower button"), "penButton1Binding: rightClick"), "Lower button is button 1")
expect(mapped(find(0, "All applications", pen, "Upper button"), "penButton2Binding: none", .unverified),
       "Function 0 is unverified")
let feel = find(0, "All applications", pen, "Tip feel")
expect(feel?.wacom == "starts at 5.0%, midpoint (0.75, 0.25)", "Curve: \(show(feel))")
let serialless = report.tablets[0].apps[0].sections.first { $0.title.hasPrefix("Pen with tool code 0x2") }
expect(serialless?.notes.first?.contains("No serial") == true, "A pen without a serial is noted")
expect(serialless?.lines.contains { $0.control == "Name" } == false, "A Wacom default name isn't imported")
expect(mapped(serialless?.lines.first { $0.control == "Lower button" }, "penButton1Binding: scrollDrag"), "Pan/scroll")

// ExpressKeys
func key(_ name: String) -> Line? { find(0, "All applications", "ExpressKeys", name) }
expect(mapped(key("LeftButton1"), "expressKeyBindings: keyCombo 1, key code 18"), "Virtual key: \(show(key("LeftButton1")))")
expect(mapped(key("LeftButton2"), "expressKeyBindings: keyCombo ⌘Z, key code 6"), "Character key: \(show(key("LeftButton2")))")
expect(mapped(key("LeftButton3"), "expressKeyBindings: keyCombo ⌥, modifiers only"), "Modifier: \(show(key("LeftButton3")))")
expect(mapped(key("LeftButton4"), "expressKeyBindings: spacebar"), "Held space: \(show(key("LeftButton4")))")
expect(mapped(key("LeftButton5"), "expressKeyBindings: keyCombo ⇧⇥, key code 48"), "Named key: \(show(key("LeftButton5")))")
expect(skipped(key("LeftButton6"), "key sequence"), "Typed sequence: \(show(key("LeftButton6")))")
expect(skipped(key("LeftButton7"), "&volumeup;"), "Unknown key name: \(show(key("LeftButton7")))")
expect(skipped(key("LeftButton8"), "no MockTab equivalent") && key("LeftButton8")?.wacom.contains("Radial menu") == true,
       "On-screen panel: \(show(key("LeftButton8")))")
expect(skipped(key("RightButton1"), "unknown function"), "Unknown code: \(show(key("RightButton1")))")
expect(mapped(key("RightButton2"), "expressKeyBindings: keyCombo ⇧#, key code 20", .approximate),
       "A character that needs Shift: \(show(key("RightButton2")))")

// Ring and dial
func ring(_ mode: String) -> Line? { find(0, "All applications", "Touch ring", mode) }
expect(mapped(ring("mode1"), "touchRingSlots: keyPress ] / [", .unverified), "Key ring: \(show(ring("mode1")))")
expect(ring("mode1")?.wacom.hasPrefix("\"Brush size\"") == true, "Ring mode label")
expect(mapped(ring("mode2"), "touchRingSlots: scroll", .approximate), "Auto scroll and zoom")
expect(mapped(ring("mode3"), "touchRingSlots: rotate"), "Rotate")
expect(skipped(ring("mode4"), "unknown ring function"), "Unknown ring code")
expect(mapped(find(1, "All applications", "Dial leftdial", "mode1"), "rotaries (first dial): skip"), "Dial skip")

// Mapping
let area = find(0, "All applications", "Mapping", "Tablet area")
expect(area?.wacom == "x 0.100, y 0.250, width 0.500, height 0.500", "Area: \(show(area))")
expect(skipped(find(0, "All applications", "Mapping", "Display"), "by position"), "Display isn't mapped")

// Apps
let apps = report.tablets[0].apps
let paints = apps.filter { $0.bundleID == "com.example.paint" }
expect(paints.count == 2, "Both Paint entries listed")
expect(paints.first?.notes.first?.contains("Another entry") == true, "Older duplicate skipped")
let paint = paints.last
expect(paint?.notes.isEmpty == true, "Newer duplicate used")
let paintPen = paint?.sections.first { $0.title.hasPrefix(pen) }
expect(paintPen?.lines.map(\.control) == ["Lower button"], "Only the changed pen button: \(paintPen?.lines.map(\.control) ?? [])")
expect(mapped(paintPen?.lines.first, "penButton1Binding: clickLock"), "Per-app click lock")
let paintKeys = paint?.sections.first { $0.title == "ExpressKeys" }
expect(paintKeys?.lines.map(\.control) == ["LeftButton2"], "Only the changed key")
expect(mapped(paintKeys?.lines.first, "expressKeyBindings: keyCombo ⌥⌘Z, key code 6"), "Per-app keystroke")
expect(paintKeys?.notes.isEmpty == true, "Position note only on All applications")
expect(mapped(paint?.sections.first { $0.title == "Touch ring" }?.lines.first, "touchRingSlots: scroll"), "Per-app ring")
expect(apps.first { $0.name == "Notes" }?.notes == ["Same as All applications."], "App with no differences")
expect(apps.first { $0.name == "Old Tool" }?.notes.first?.contains("Removed") == true, "Removed app")
expect(apps.first { $0.name == "Script" }?.notes.first?.contains("No bundle ID") == true, "App without bundle ID")

// Nothing private reaches the report.
expect(!text.contains("Count") && !text.contains("/nonexistent"), "No usage counts or app paths in the report")
expect(text.contains("Summary: "), "Summary line")

// Keystroke parsing
expect(Keystroke.parse("", layout: layout) == .empty, "Empty keystroke")
expect(Keystroke.parse("&command;&shift;", layout: layout) == .modifiersOnly([.command, .shift]), "Modifiers only")
if case .key(let k, let exact) = Keystroke.parse("&enter;", layout: layout) {
    expect(k.keyCode == 36 && !exact, "Enter could be either Return or keypad Enter")
} else {
    expect(false, "Enter parses")
}
if case .key(let k, _) = Keystroke.parse("q", layout: layout) {
    expect(k.keyCode == nil, "A character missing from the layout has no key code")
} else {
    expect(false, "Missing character parses")
}

// Load errors
let empty = FileManager.default.temporaryDirectory.appendingPathComponent("wacom-import-tests-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
do {
    _ = try WacomBackup.load(empty)
    expect(false, "A folder without prefs is rejected")
} catch WacomBackup.LoadError.notABackup {
} catch {
    expect(false, "Wrong error: \(error)")
}
try? FileManager.default.removeItem(at: empty)

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
