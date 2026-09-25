// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "capture")

/// Bundles one session's outputs into a single file to hand over.
///
/// Asking a user to find and attach two files is where submissions lose half
/// their content. Zipped rather than merged into one JSON: the log's value is
/// that it's plain aligned text, which a JSON string would escape away.
///
/// Uses `/usr/bin/ditto` — the app is unsandboxed and dependency-free, and a
/// package for one zip call would be the wrong trade.
enum DiagnosticPackage {

    /// Build a zip beside `summaryURL` holding it, the raw log if any, and a
    /// README. Nil if it couldn't be written — the caller then keeps its loose
    /// files, since a failed zip must never mean a lost capture.
    static func build(summaryURL: URL, rawLogURL: URL?, productID: String, date: Date = Date())
        -> URL?
    {
        let stem = "mocktab-diagnostics-\(productID)-\(stamp(date))"
        let destination = summaryURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem).zip")

        // Staged so `--keepParent` expands to one folder rather than
        // scattering files where the user unzips.
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(stem, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: summaryURL, to: staging.appendingPathComponent("summary.json"))
            if let rawLogURL, FileManager.default.fileExists(atPath: rawLogURL.path) {
                try FileManager.default.copyItem(
                    at: rawLogURL, to: staging.appendingPathComponent("full-log.txt"))
            }
            try readme(hasRawLog: rawLogURL != nil, date: date)
                .write(
                    to: staging.appendingPathComponent("README.txt"), atomically: true,
                    encoding: .utf8)
        } catch {
            logger.error("diagnostic package staging failed — \(error.localizedDescription, privacy: .public)")
            return nil
        }

        stripExtendedAttributes(in: staging)

        guard runDitto(from: staging, to: destination) else { return nil }
        return destination
    }

    /// Remove extended attributes from the staged copies so the archive holds
    /// only the files themselves.
    ///
    /// `ditto` writes an AppleDouble `._name` sidecar for every file carrying
    /// xattrs, and `copyItem` brings them along — a file Finder has touched
    /// picks up `kMDItemWhereFroms` or a quarantine flag. One attribute is
    /// enough to produce a sidecar. Nothing in these text and JSON resource
    /// forks is worth shipping.
    ///
    /// Staging copies only, never the user's files. Best-effort: failing here
    /// costs cosmetics, not the capture. `runDitto` is what actually
    /// guarantees no sidecars; this keeps the staged files clean besides.
    private static func stripExtendedAttributes(in directory: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else { return }
        for url in entries {
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return }
                // Size the name buffer from the actual list, then remove each.
                let length = listxattr(path, nil, 0, 0)
                guard length > 0 else { return }
                var names = [CChar](repeating: 0, count: length)
                guard listxattr(path, &names, length, 0) == length else { return }
                // The list is a flat run of NUL-terminated names.
                var start = 0
                for i in 0..<length where names[i] == 0 {
                    if i > start {
                        names.withUnsafeBufferPointer { buffer in
                            _ = removexattr(path, buffer.baseAddress! + start, 0)
                        }
                    }
                    start = i + 1
                }
            }
        }
    }

    /// Without `--sequesterRsrc`, which is what *creates* the `__MACOSX/._*`
    /// entries rather than suppressing them — confirmed on a real archive,
    /// three phantom files for three real ones.
    ///
    /// `--noextattr`/`--norsrc` because stripping the staged copies is not
    /// enough on its own: a submitted archive built by the signed app still
    /// carried a `._` sidecar per file, each holding only
    /// `com.apple.provenance`, which the system applies to files the app
    /// writes. Telling `ditto` not to serialize attributes does not depend on
    /// winning that race.
    private static func runDitto(from source: URL, to destination: URL) -> Bool {
        try? FileManager.default.removeItem(at: destination)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c", "-k", "--norsrc", "--noextattr", "--keepParent",
            source.path, destination.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("ditto failed to launch — \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard process.terminationStatus == 0 else {
            logger.error("ditto exited \(process.terminationStatus, privacy: .public)")
            return false
        }
        return true
    }

    /// Plain-text note, first thing anyone sees on unzip.
    ///
    /// The no-keystrokes claim holds by construction: keyboards and
    /// Consumer-page devices are excluded by top-level usage in both sweeps
    /// (`CaptureGuideView.isTextEntryDevice`,
    /// `DiagnosticSession.knownVendorDevices`). Change that filtering and
    /// this text must change too.
    static func readme(hasRawLog: Bool, date: Date = Date()) -> String {
        var lines = [
            "MockTab diagnostics",
            "",
            "summary.json   What your tablet reported, and statistics about it.",
        ]
        if hasRawLog {
            lines.append("full-log.txt   Every report received, as plain text.")
        }
        lines.append(contentsOf: [
            "",
            "This contains tablet, pen, and button activity only. No keystrokes,",
            "no personal files, no screen contents. Everything here is readable",
            "text — open it and look before you send it.",
            "",
            "MockTab MockTap Metrics",
            readmeDate(date),
            "",
        ])
        return lines.joined(separator: "\n")
    }

    /// Pinned the same way `stamp` is, for the same reason.
    private static func readmeDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Matches `CaptureEngine.fileStamp`, pinned so a user's region can't
    /// change the calendar — one capture came back stamped with a Persian
    /// year.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
