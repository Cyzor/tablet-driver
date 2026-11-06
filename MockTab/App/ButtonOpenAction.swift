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
        } else if !NSWorkspace.shared.open(url) {
            openLog.error("open failed for a \(url.scheme ?? "?", privacy: .public) link")
            NSSound.beep()
        }
    }

    // MARK: Dragged text

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
