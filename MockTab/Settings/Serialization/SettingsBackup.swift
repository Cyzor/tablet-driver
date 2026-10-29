// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Whole-domain copies of the settings, so a bad build, a move to an older
/// or newer version, or a factory reset can be undone. They live in
/// Application Support under the bundle ID, beside the plist of the same
/// name. To restore one, quit MockTab and run
/// `defaults delete com.cyzor.mocktab`, then
/// `defaults import com.cyzor.mocktab <backup>.plist`; import alone merges,
/// keeping keys written since the backup.
enum SettingsBackup {
    static let lastBuildKey = "_lastLaunchedBuild"
    static let keepCount = 3

    static func defaultDirectory(for domain: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(domain, isDirectory: true)
    }

    private static let logger = Logger(subsystem: "com.cyzor.mocktab", category: "settings")

    /// Saves the settings the previous build left when `build` differs from
    /// it, then records `build`. Runs before anything reads or migrates
    /// settings, so the copy is exactly what the previous build wrote.
    static func backUpOnBuildChange(
        build: String, domain: String, defaults: UserDefaults = .standard, directory: URL? = nil
    ) {
        let previous = defaults.string(forKey: lastBuildKey)
        guard previous != build else { return }
        // A failed write leaves the key alone so the next launch tries again.
        guard backUp(label: previous.map(fileLabel) ?? "earlier", domain: domain, defaults: defaults,
                     directory: directory) else { return }
        defaults.set(build, forKey: lastBuildKey)
    }

    /// A build's name in a backup file. Snapshots drop their build stamp, so
    /// each one replaces the last and a release's copy outlives them.
    static func fileLabel(for build: String) -> String {
        guard let range = build.range(of: "-snapshot") else { return build }
        return String(build[..<range.upperBound])
    }

    /// Writes the whole settings domain to `directory` as
    /// "mocktab-settings-<label>.plist", replacing an older copy of the same
    /// name, and prunes all but the newest `keepCount`. Returns false only
    /// when there was something to save and the write failed.
    @discardableResult
    static func backUp(
        label: String, domain: String, defaults: UserDefaults = .standard, directory: URL? = nil
    ) -> Bool {
        guard let settings = defaults.persistentDomain(forName: domain), !settings.isEmpty else { return true }
        let directory = directory ?? defaultDirectory(for: domain)
        let url = directory.appendingPathComponent("\(filePrefix)\(fileSafe(label)).plist")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Settings backup failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        prune(directory)
        return true
    }

    private static let filePrefix = "mocktab-settings-"

    /// `label` cut to ASCII letters, digits, dots, and single hyphens, so a
    /// name never needs quoting in a shell.
    static func fileSafe(_ label: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.")
        let mapped = String(label.map { allowed.contains($0) ? $0 : "-" })
        let parts = mapped.split(separator: "-", omittingEmptySubsequences: true)
        return parts.isEmpty ? "unknown" : parts.joined(separator: "-")
    }

    /// Keeps the `keepCount` most recently written backups.
    private static func prune(_ directory: URL) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        let backups = urls
            .filter { $0.lastPathComponent.hasPrefix(filePrefix) && $0.pathExtension == "plist" }
            .sorted { modified($0) > modified($1) }
        for url in backups.dropFirst(keepCount) {
            try? fm.removeItem(at: url)
        }
    }
}
