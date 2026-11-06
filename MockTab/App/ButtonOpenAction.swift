// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import os

private let openLog = Logger(subsystem: "com.cyzor.mocktab", category: "open")

/// Opens what an `.open` button binding names, through Launch Services: no
/// script, no child process, and no Apple Events entitlement.
@MainActor
enum ButtonOpenAction {
    /// A switch that bounces would otherwise open one target many times.
    private static let repeatInterval: TimeInterval = 0.3
    private static var lastOpen: (url: URL, at: TimeInterval)?

    static func open(_ url: URL) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastOpen, last.url == url, now - last.at < repeatInterval { return }
        lastOpen = (url, now)

        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
            openLog.error("open target is missing: \(url.path, privacy: .private)")
            NSSound.beep()
            return
        }
        if url.isFileURL, url.pathExtension == "app" {
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
                if let error { openLog.error("open app failed: \(error.localizedDescription, privacy: .public)") }
            }
        } else {
            // A link for a menu bar app, like a Keyboard Maestro macro, would
            // otherwise take focus from the front window for a moment.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = !handlerRunsInBackground(url)
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                guard error != nil else { return }
                openLog.error("open failed for a \(url.scheme ?? "?", privacy: .public) link")
                Task { @MainActor in NSSound.beep() }
            }
        }
    }

    /// Whether the app that opens `url` has no Dock icon or menu bar.
    private static func handlerRunsInBackground(_ url: URL) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url),
            let info = Bundle(url: app)?.infoDictionary
        else { return false }
        return ["LSUIElement", "LSBackgroundOnly"].contains { key in
            (info[key] as? NSNumber)?.boolValue == true || (info[key] as? String) == "1"
        }
    }

    // MARK: Dragged items

    /// The type a macro dragged from Keyboard Maestro's editor carries: a
    /// property list array of macro UUIDs. Its plain text is the name.
    nonisolated static let keyboardMaestroMacroIDsType = "com.stairways.keyboardmaestro.macrouidsarray"

    /// The one macro a drag from Keyboard Maestro carries, as a link and its
    /// name. Read from the pasteboard itself: the ID list's type isn't
    /// declared to macOS, so SwiftUI's drop leaves it out.
    static func keyboardMaestroMacro(on pasteboard: NSPasteboard) -> (url: URL, name: String)? {
        guard let items = pasteboard.pasteboardItems, items.count == 1,
            let data = items[0].data(forType: .init(keyboardMaestroMacroIDsType)),
            let url = keyboardMaestroLink(fromMacroIDs: data)
        else { return nil }
        return (url, items[0].string(forType: .string) ?? "")
    }

    /// A link that runs the one macro in `data`, by UUID so a rename
    /// doesn't break it. Nil for several macros or anything unreadable.
    nonisolated static func keyboardMaestroLink(fromMacroIDs data: Data) -> URL? {
        guard let ids = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String],
            ids.count == 1, UUID(uuidString: ids[0]) != nil
        else { return nil }
        return URL(string: "kmtrigger://macro=" + ids[0])
    }

    /// The type a record dragged from DEVONthink carries: a property list
    /// array with each record's item link and name. Its file URL points
    /// inside the database, and groups have none.
    nonisolated static let devonthinkItemLinksType = "DTItemLinksPboardType"

    /// The one record a drag from DEVONthink carries, as its item link and
    /// name. Read from the pasteboard itself, like a Keyboard Maestro macro;
    /// only the pasteboard translates this legacy type name, not its items.
    static func devonthinkRecord(on pasteboard: NSPasteboard) -> (url: URL, name: String)? {
        guard pasteboard.pasteboardItems?.count == 1,
            let data = pasteboard.data(forType: .init(devonthinkItemLinksType))
        else { return nil }
        return devonthinkRecord(fromItemLinks: data)
    }

    /// The item link and name of the one record in `data`. The link opens
    /// the record in DEVONthink and survives a rename or move. Nil for
    /// several records or anything unreadable.
    nonisolated static func devonthinkRecord(fromItemLinks data: Data) -> (url: URL, name: String)? {
        guard let records = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]],
            records.count == 1, let link = records[0]["URL"] as? String,
            link.hasPrefix("x-devonthink-item://"), let url = URL(string: link)
        else { return nil }
        return (url, records[0]["Name"] as? String ?? "")
    }

    /// A link from dragged text: one word with a scheme, or a bare address
    /// like example.com, which gets https. Other text isn't a link.
    nonisolated static func link(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        if let url = URL(string: trimmed), url.scheme?.isEmpty == false { return url }
        guard trimmed.contains("."), !trimmed.hasPrefix(".") else { return nil }
        return URL(string: "https://" + trimmed)
    }
}
