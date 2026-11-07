// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab contributors
// SPDX-License-Identifier: GPL-3.0-or-later

// main.swift — Checks for what an item dragged onto a button row opens. The
// payloads match what Keyboard Maestro 11 and DEVONthink 3 put on the drag
// pasteboard. Run via tools/tests/open-drop-tests/run.sh.

import AppKit

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

private func plist(_ value: Any) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
}

private let board = NSPasteboard(name: .init("open-drop-tests-\(getpid())"))

/// Puts `items` on a private pasteboard, as a drag would, and reads it.
@MainActor private func drag(_ items: [[NSPasteboard.PasteboardType: String]]) -> (url: URL, name: String)? {
    board.clearContents()
    board.writeObjects(items.map { types in
        let item = NSPasteboardItem()
        for (type, value) in types { item.setString(value, forType: type) }
        return item
    })
    return ButtonOpenAction.openTarget(on: board)
}

let macroID = "F2E047F7-2C14-4BAC-9161-7591E1EE9E31"
let recordID = "5D014A74-FFBA-45E6-826F-99D74D35ECA0"

// Keyboard Maestro: one macro runs by UUID; anything else isn't a macro.
do {
    let url = ButtonOpenAction.keyboardMaestroLink(fromMacroIDs: plist([macroID]))
    expect(url?.absoluteString == "kmtrigger://macro=" + macroID, "One macro runs by UUID: \(String(describing: url))")
    expect(ButtonOpenAction.keyboardMaestroLink(fromMacroIDs: plist([macroID, macroID])) == nil,
           "Several macros are refused")
    expect(ButtonOpenAction.keyboardMaestroLink(fromMacroIDs: plist(["Some Macro"])) == nil,
           "A name isn't a macro ID")
    expect(ButtonOpenAction.keyboardMaestroLink(fromMacroIDs: Data("junk".utf8)) == nil, "Junk is refused")
}

// DEVONthink: a record opens by item link, groups included.
do {
    let group: [String: Any] = ["Name": "Movies", "Path": "", "URL": "x-devonthink-item://" + recordID, "UUID": recordID]
    let record = ButtonOpenAction.devonthinkRecord(fromItemLinks: plist([group]))
    expect(record?.url.absoluteString == "x-devonthink-item://" + recordID, "A group opens by item link")
    expect(record?.name == "Movies", "It's named as in DEVONthink: \(String(describing: record?.name))")
    expect(ButtonOpenAction.devonthinkRecord(fromItemLinks: plist([group, group])) == nil, "Several records are refused")
    var web = group
    web["URL"] = "https://example.com/paper.pdf"
    expect(ButtonOpenAction.devonthinkRecord(fromItemLinks: plist([web])) == nil, "Only item links count")
}

// Dragged text: one word with a scheme, or a bare address.
do {
    expect(ButtonOpenAction.link(from: "kando://menu?name=Main")?.absoluteString == "kando://menu?name=Main",
           "A link with a scheme is kept")
    expect(ButtonOpenAction.link(from: " example.com\n")?.absoluteString == "https://example.com",
           "A bare address gets https")
    expect(ButtonOpenAction.link(from: "two words") == nil, "Text with spaces isn't a link")
    expect(ButtonOpenAction.link(from: "clean up this graphic:\nhttp://example.com") == nil,
           "A reminder's title and link aren't a link")
    expect(ButtonOpenAction.link(from: ".hidden") == nil, "A leading dot isn't an address")
    expect(ButtonOpenAction.link(from: "") == nil, "Nothing isn't a link")
}

// The Trash: macOS won't launch from it, so nothing there counts.
do {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("open-drop-tests-\(getpid()).txt")
    FileManager.default.createFile(atPath: scratch.path, contents: Data("x".utf8))
    expect(ButtonOpenAction.canOpen(scratch), "A file outside the Trash opens")
    expect(!ButtonOpenAction.isInTrash(scratch), "A temporary file isn't in the Trash")
    var trashed: NSURL?
    if (try? FileManager.default.trashItem(at: scratch, resultingItemURL: &trashed)) != nil, let trashed = trashed as URL? {
        expect(ButtonOpenAction.isInTrash(trashed), "A trashed file is in the Trash: \(trashed.path)")
        expect(!ButtonOpenAction.canOpen(trashed), "A trashed file doesn't open")
        try? FileManager.default.removeItem(at: trashed)
    } else {
        print("open-drop-tests: no Trash here, skipping the Trash checks")
        try? FileManager.default.removeItem(at: scratch)
    }
}

// A whole drag: what the row's drop target reads from the pasteboard.
MainActor.assumeIsolated {
    defer { board.releaseGlobally() }
    // Some CI sessions have no pasteboard server; the checks above still run.
    board.clearContents()
    board.setString("probe", forType: .string)
    guard board.string(forType: .string) == "probe" else {
        print("open-drop-tests: no pasteboard here, skipping the drag checks")
        return
    }
    let app = drag([[.fileURL: "file:///System/Applications/Calculator.app/"]])
    expect(app?.url.path == "/System/Applications/Calculator.app", "An app opens: \(String(describing: app))")
    expect(app?.name == "", "An app's name comes from Finder")
    let message = drag([[.URL: "message:%3Cabc@example.com%3E", .init("public.url-name"): "Lunch?", .string: "Lunch?"]])
    expect(message?.url.scheme == "message", "A message opens by link: \(String(describing: message?.url))")
    expect(message?.name == "Lunch?", "It's named by its subject: \(String(describing: message?.name))")
    expect(drag([[.string: "https://example.com/menu"]])?.url.host == "example.com", "Link text opens")
    expect(drag([[.string: "mocktab-test-unclaimed://menu"]]) == nil, "A link no app opens is refused")
    expect(drag([[.string: "https://example.com/" + String(repeating: "a", count: 3000)]]) == nil,
           "An over-long link is refused")
    expect(drag([[.fileURL: "file:///nonexistent-\(getpid()).app/"]]) == nil, "A missing file is refused")
    expect(drag([[.string: "A draft\nwith lines",
                  .init("com.apple.pasteboard.promised-file-content-type"): "public.utf8-plain-text",
                  .init("com.agiletortoise.Drafts.draft"): "{}"]]) == nil,
           "A draft's text isn't taken, and its promised file isn't touched")
    expect(ButtonOpenAction.mightOpenTarget(on: board), "Hovering judges by types, so text lights the field")
    expect(drag([[.fileURL: "file:///System/Applications/Calculator.app/"],
                 [.fileURL: "file:///System/Applications/Chess.app/"]]) == nil,
           "Several items are refused")
    expect(!ButtonOpenAction.mightOpenTarget(on: board), "Several items don't light the field")
}

if failures > 0 {
    print("open-drop-tests: \(checks - failures)/\(checks) checks passed")
    exit(1)
}
print("All \(checks) open-drop checks passed.")
