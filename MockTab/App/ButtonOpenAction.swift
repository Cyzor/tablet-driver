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

    /// The type a record dragged from DEVONthink carries. Its file URL
    /// points inside the database, so the drag is refused; DEVONthink's Copy
    /// Item Link and Edit URL bind a record instead. A legacy type name, so
    /// only the pasteboard itself, not its items, recognizes it.
    static func isDEVONthinkDrag(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.init("DTItemLinksPboardType")]) != nil
    }

    /// Whether a drag might hold something `openTarget(on:)` takes, judged
    /// from its types alone: nothing is read while a drag only passes over.
    static func mightOpenTarget(on pasteboard: NSPasteboard) -> Bool {
        guard pasteboard.pasteboardItems?.count == 1, let types = pasteboard.types,
            !isDEVONthinkDrag(pasteboard)
        else { return false }
        return !Set(types).isDisjoint(with: openTargetTypes)
    }

    /// What the one item on `pasteboard` would open, and its name: a Keyboard
    /// Maestro macro, an app, file, or folder, a link, or text that reads as
    /// a link. Nil for anything else, several items, a DEVONthink record, a
    /// link longer than `maxLinkLength`, or one no app on this Mac opens.
    /// Reads only types already on the pasteboard, never a promised file.
    static func openTarget(on pasteboard: NSPasteboard) -> (url: URL, name: String)? {
        guard pasteboard.pasteboardItems?.count == 1, !isDEVONthinkDrag(pasteboard) else { return nil }
        var found = keyboardMaestroMacro(on: pasteboard)
        if found == nil, let url = pasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL {
            // A file's name comes from Finder, so it follows a rename.
            found = (url, url.isFileURL ? "" : linkName(on: pasteboard))
        }
        if found == nil, let text = pasteboard.string(forType: .string),
            text.utf8.count <= maxLinkLength, let url = link(from: text) {
            found = (url, "")
        }
        guard let found, found.url.absoluteString.utf8.count <= maxLinkLength, canOpen(found.url) else { return nil }
        return found
    }

    /// The URL typed or pasted into Edit URL, read like dragged text. Nil
    /// when it isn't a URL, names a file, is too long, or nothing on this
    /// Mac opens it.
    nonisolated static func typedLink(_ text: String) -> URL? {
        guard text.utf8.count <= maxLinkLength, let url = link(from: text), !url.isFileURL,
            url.absoluteString.utf8.count <= maxLinkLength, canOpen(url)
        else { return nil }
        return url
    }

    /// Longer than any link a person would put on a button, and short
    /// enough that a stray paste of a document is refused.
    nonisolated static let maxLinkLength = 2048

    /// A file that exists outside the Trash, or a link some app on this Mac
    /// claims. macOS won't launch an app from the Trash.
    nonisolated static func canOpen(_ url: URL) -> Bool {
        if url.isFileURL { return FileManager.default.fileExists(atPath: url.path) && !isInTrash(url) }
        return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    /// In the user's Trash or a volume's, where a path check would miss it.
    nonisolated static func isInTrash(_ url: URL) -> Bool {
        var relationship = FileManager.URLRelationship.other
        try? FileManager.default.getRelationship(&relationship, of: .trashDirectory, in: .allDomainsMask, toItemAt: url)
        return relationship == .contains
    }

    /// Types `openTarget(on:)` reads, for a drop target to register.
    static let openTargetTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .URL, .string, .init(keyboardMaestroMacroIDsType),
    ]

    /// The name a dragged link carries, such as a message's subject or a
    /// page's title. Empty when it has none.
    static func linkName(on pasteboard: NSPasteboard) -> String {
        guard let items = pasteboard.pasteboardItems, items.count == 1 else { return "" }
        let name = items[0].string(forType: .init("public.url-name")) ?? ""
        return String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }

    /// A link from dragged text: one word with a scheme, or a bare address
    /// like example.com, which gets https. Other text, including a file's
    /// path, isn't a link.
    nonisolated static func link(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        if let url = URL(string: trimmed), url.scheme?.isEmpty == false { return url }
        guard let url = URL(string: "https://" + trimmed), let host = url.host, isHostName(host) else { return nil }
        return url
    }

    /// Dotted labels of letters, digits, and hyphens, like example.com.
    private nonisolated static func isHostName(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count > 1 && labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    /// Whether typed text names a file rather than a link: a path, or a
    /// file URL. Files go onto a row by drag, which follows a rename.
    nonisolated static func looksLikeFile(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.lowercased().hasPrefix("file:")
    }
}
