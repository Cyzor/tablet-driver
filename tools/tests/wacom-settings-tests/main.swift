// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// Checks the Wacom import report against a made-up backup in fixtures/:
// names, pen serials, button functions, keystrokes in each encoding, ring
// modes, the mapping area, per-app differences, and the app entries it
// skips. A fixed layout table stands in for the keyboard layout here;
// LayoutChecks.swift tries every layout installed.

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
    "a": LayoutKey(keyCode: 0), "b": LayoutKey(keyCode: 11),
    "c": LayoutKey(keyCode: 8), "z": LayoutKey(keyCode: 6),
    "1": LayoutKey(keyCode: 18), "[": LayoutKey(keyCode: 33),
    "]": LayoutKey(keyCode: 30), "#": LayoutKey(keyCode: 20, adds: .shift, exact: false),
]
let layout: LayoutLookup = { c, _ in usLayout[c] }

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
expect(report.tablets.count == 4, "Four tablets")
expect(report.tablets[0].productID == 0x0357, "Product ID from SensorID")
expect(report.tablets[1].productID == 0x03F9 && report.tablets[1].lastConnectedAs == 0x03FA,
       "A Bluetooth product ID folds onto the wired one")
expect(report.tablets[0].lastConnectedAs == nil, "A wired tablet has no other connection to name")
expect(report.tablets[2].productID == nil && report.tablets[2].notes.contains { $0.contains("No product ID") },
       "A tablet without SensorID is noted")
expect(report.tablets[0].nickname == "Studio", "Renamed tablet keeps its name")
expect(report.tablets[1].nickname == nil, "Unrenamed tablet has no nickname")
expect(report.tablets[0].notes.contains { $0.contains("App 9") }, "Settings for an unlisted app are noted")

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
let third = find(0, "All applications", pen, "Third button")
expect(skipped(third, "no MockTab equivalent") && third.map(ReportText.line)?.hasSuffix("(becomes None)") == true,
       "A pen button with no equivalent becomes None: \(show(third))")
let feel = find(0, "All applications", pen, "Tip feel")
expect(feel?.wacom == "starts at 5.0%, midpoint (0.75, 0.25)", "Curve: \(show(feel))")
let serialless = report.tablets[0].apps[0].sections.first { $0.title.hasPrefix("Pen with tool code 0x2") }
expect(serialless?.notes.first?.contains("No serial") == true, "A pen without a serial is noted")
expect(serialless?.lines.contains { $0.control == "Name" } == false, "A Wacom default name isn't imported")
expect(mapped(serialless?.lines.first { $0.control == "Lower button" }, "penButton1Binding: scrollDrag"), "Pan/scroll")

// ExpressKeys on a PTH-660, numbered top to bottom.
func key(_ name: String) -> Line? { find(0, "All applications", "ExpressKeys", name) }
func keyIs(_ name: String, _ what: String, _ c: Confidence = .exact) -> Bool { mapped(key(name), what, c) }
expect(keyIs("LeftButton1", "expressKeyBindings[0]: keyCombo 1, key code 18"), "Virtual key: \(show(key("LeftButton1")))")
expect(keyIs("LeftButton2", "expressKeyBindings[1]: keyCombo ⌘Z, key code 6"), "Character key: \(show(key("LeftButton2")))")
expect(keyIs("LeftButton3", "expressKeyBindings[2]: keyCombo ⌥, modifiers only"), "Modifier: \(show(key("LeftButton3")))")
expect(keyIs("LeftButton4", "expressKeyBindings[3]: spacebar"), "Held space: \(show(key("LeftButton4")))")
expect(keyIs("LeftButton5", "expressKeyBindings[4]: keyCombo ⇧⇥, key code 48"), "Named key: \(show(key("LeftButton5")))")
expect(skipped(key("LeftButton6"), "key sequence"), "Typed sequence: \(show(key("LeftButton6")))")
expect(skipped(key("LeftButton7"), "&volumeup;"), "Unknown key name: \(show(key("LeftButton7")))")
expect(skipped(key("LeftButton8"), "no MockTab equivalent") && key("LeftButton8")?.wacom.contains("Radial menu") == true,
       "On-screen panel: \(show(key("LeftButton8")))")
expect(skipped(key("RightButton1"), "unknown function"), "Unknown code: \(show(key("RightButton1")))")
expect(skipped(key("RightButton2"), "key position unknown"), "A key the model doesn't have: \(show(key("RightButton2")))")

// ExpressKeys and dials on a PTK-870: checked positions.
func ptk(_ section: String, _ control: String) -> Line? { find(1, "All applications", section, control) }
expect(mapped(ptk("ExpressKeys", "LeftButton1"), "expressKeyBindings[0]: keyCombo ↑, key code 126"), show(ptk("ExpressKeys", "LeftButton1")))
expect(mapped(ptk("ExpressKeys", "LeftButton5"), "touchRingButtonBinding: ringCycle"), show(ptk("ExpressKeys", "LeftButton5")))
expect(mapped(ptk("ExpressKeys", "RightButton4"), "expressKeyBindings[7]: rightClick"), show(ptk("ExpressKeys", "RightButton4")))
expect(mapped(ptk("ExpressKeys", "RightButton5"), "touchRingButtonBinding2: ringCycle2"), "Second dial's key cycles the second dial")
expect(skipped(ptk("ExpressKeys", "RightButton6"), "key position unknown"), "No sixth key")
expect(mapped(ptk("Dial leftdial", "mode1"), "rotaries[0]: skip"), "Left dial is the first")
expect(mapped(ptk("Dial rightdial", "mode1"), "rotaries[1]: rotate"), "Right dial is the second")

// Intuos (CTL-4100 family): Button1-4, positions not checked.
func intuos(_ control: String) -> Line? { find(3, "All applications", "ExpressKeys", control) }
expect(skipped(intuos("Button1"), "no MockTab equivalent") && intuos("Button1")?.wacom == "radial menu", "Radial menu")
expect(skipped(intuos("Button2"), "no MockTab equivalent") && intuos("Button2")?.wacom == "touch on/off", "Touch on/off")
expect(mapped(intuos("Button4"), "expressKeyBindings[3]: rightClick", .unverified), show(intuos("Button4")))
expect(intuos("Button4")?.setting == nil && intuos("Button1")?.setting == nil,
       "An unchecked position names no setting, so the import leaves it alone")
expect(!show(intuos("Button1")).contains("becomes") && show(key("LeftButton8")).hasSuffix("(becomes None)"),
       "Only a checked control says what it becomes: \(show(intuos("Button1")))")

// A model with no key table skips its keys and dials.
expect(skipped(find(2, "All applications", "ExpressKeys", "LeftButton1"), "key position unknown"), "Unknown model's key")
expect(skipped(find(2, "All applications", "Dial leftdial", "mode1"), "dial unknown"), "Unknown model's dial")

// Ring and dial
func ring(_ mode: String) -> Line? { find(0, "All applications", "Touch ring", mode) }
expect(mapped(ring("mode1"), "touchRingSlots: keyPress, cwBinding [, ccwBinding ]"),
       "Increase is counterclockwise: \(show(ring("mode1")))")
expect(ring("mode1")?.wacom.hasPrefix("\"Brush size\"") == true, "Ring mode label")
expect(mapped(ring("mode2"), "touchRingSlots: scroll", .approximate), "Auto scroll and zoom")
expect(mapped(ring("mode3"), "touchRingSlots: rotate"), "Rotate")
expect(skipped(ring("mode4"), "unknown ring function") && show(ring("mode4")).hasSuffix("(becomes Off)"), "Unknown ring code")
expect(mapped(ring("mode5"), "touchRingSlots: off") && ring("mode5")?.wacom == "disabled",
       "Disabled ignores a keystroke left over from an earlier choice")

// Mapping
let area = find(0, "All applications", "Mapping", "Tablet area")
expect(area?.wacom == "x 0.100, y 0.250, width 0.500, height 0.500", "Area: \(show(area))")
expect(skipped(find(0, "All applications", "Mapping", "Display"), "by position"), "Display isn't mapped")

// Apps
let apps = report.tablets[0].apps
let paints = apps.filter { $0.bundleID == "com.example.paint" }
expect(paints.count == 2, "Both Paint entries listed")
expect(paints.first?.notes.first?.contains("another entry for this app wins") == true, "Older duplicate skipped")
let paint = paints.last
expect(paint?.notes.isEmpty == true, "Newer duplicate used")
let paintPen = paint?.sections.first { $0.title.hasPrefix(pen) }
expect(paintPen?.lines.map(\.control) == ["Lower button"], "Only the changed pen button: \(paintPen?.lines.map(\.control) ?? [])")
expect(mapped(paintPen?.lines.first, "penButton1Binding: clickLock"), "Per-app click lock")
let paintKeys = paint?.sections.first { $0.title == "ExpressKeys" }
expect(paintKeys?.lines.map(\.control) == ["LeftButton2"], "Only the changed key")
expect(mapped(paintKeys?.lines.first, "expressKeyBindings[1]: keyCombo ⌥⌘Z, key code 6"), "Per-app keystroke")
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
if case .key(let k, let exact) = Keystroke.parse("&shift;#", layout: layout) {
    expect(k.keyCode == 20 && k.modifiers == .shift && !exact, "A character that needs Shift is approximate")
} else {
    expect(false, "Shifted character parses")
}
if case .key(let k, _) = Keystroke.parse("q", layout: layout) {
    expect(k.keyCode == nil, "A character missing from the layout has no key code")
} else {
    expect(false, "Missing character parses")
}
// # and ⇧# from a German layout both need ⇧3 on a U.S. one, so a ring mode
// using them would turn the same way in both directions.
let german = WacomNode(name: "mode1", children: [
    WacomNode(name: "TouchStripFunction", text: "8"),
    WacomNode(name: "TouchStripKeystrokeIncrease", text: "&shift;#"),
    WacomNode(name: "TouchStripKeystrokeDecrease", text: "#"),
])
let collapsed = WacomMapper.ringFunction(german, layout: layout)
expect(collapsed.1.isSkipped && collapsed.2 == nil, "Directions that land on one key are skipped: \(collapsed.1)")
// Dvorak – QWERTY ⌘ types z on key 44, but on key 6 while ⌘ is down.
let dvorak: LayoutLookup = { c, command in c == "z" ? LayoutKey(keyCode: command ? 6 : 44) : nil }
if case .key(let k, _) = Keystroke.parse("&command;z", layout: dvorak),
   case .key(let plain, _) = Keystroke.parse("z", layout: dvorak) {
    expect(k.keyCode == 6 && plain.keyCode == 44, "⌘ shortcuts use the keys ⌘ types: \(k), \(plain)")
} else {
    expect(false, "Dvorak keystrokes parse")
}

checkEncoder(report) { condition, message in expect(condition, message) }
checkWriter(report) { condition, message in expect(condition, message) }
checkLayouts { condition, message in expect(condition, message) }
checkAmbiguity(layout: layout) { condition, message in expect(condition, message) }
checkCodes { condition, message in expect(condition, message) }

// Load errors
let empty = FileManager.default.temporaryDirectory.appendingPathComponent("wacom-settings-tests-\(UUID().uuidString)")
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
