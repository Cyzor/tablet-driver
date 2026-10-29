// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The --apply flow: pick the tablet, encode it, plan the change, show it,
// save the whole settings domain, then write. Each step stops on trouble
// before anything is written.

import AppKit
import Foundation

struct ApplyOptions {
    var dryRun = false
    var yes = false
    var tablet: Int?
    var pen: UInt32?
    var domain = "com.cyzor.mocktab"
    /// Where the saved copy goes; Application Support/<domain> by default.
    var saveTo: URL?
}

enum ApplyError: Error, CustomStringConvertible {
    case running
    case noKnownTablet
    case chooseTablet([String])
    case badTablet(Int)
    case notConfirmed
    case saveFailed(String)

    var description: String {
        switch self {
        case .running: return "Quit MockTab first; it would overwrite the import with its own settings."
        case .noKnownTablet:
            return "MockTab doesn't know any tablet in this backup. Connect the tablet once with MockTab running, then quit MockTab."
        case .chooseTablet(let list):
            return "More than one tablet in this backup is known to MockTab. Pick one with --tablet:\n"
                + list.map { "  " + $0 }.joined(separator: "\n")
        case .badTablet(let n): return "The backup has no tablet \(n) with a product ID."
        case .notConfirmed: return "Nothing written."
        case .saveFailed(let why): return "Couldn't save a copy of the settings, so nothing was written: \(why)"
        }
    }
}

enum Apply {
    static func run(_ report: Report, _ o: ApplyOptions) throws {
        let current = UserDefaults(suiteName: o.domain)?.persistentDomain(forName: o.domain) ?? [:]
        let index = try chooseTablet(report, current: current, choice: o.tablet)
        let tablet = report.tablets[index]

        let encoded = try WacomEncoder.encode(tablet, pen: o.pen)
        let plan = try WacomWriter.plan(encoded, current: current)
        print(describe(plan, tablet: tablet, number: index + 1, encoded: encoded))
        if o.dryRun {
            print("Dry run: nothing saved or written.")
            return
        }
        // Reading while MockTab runs is fine; writing isn't.
        if o.domain == "com.cyzor.mocktab",
           !NSRunningApplication.runningApplications(withBundleIdentifier: o.domain).isEmpty {
            throw ApplyError.running
        }
        try confirm(o.yes)

        let saved = try save(current, domain: o.domain, to: o.saveTo)
        // `defaults import` merges, so keys the import added would survive it.
        let restore = "defaults delete \(o.domain)\n  defaults import \(o.domain) '\(saved.path)'"
        print("Saved the current settings. To undo, quit MockTab and run:\n  \(restore)")
        WacomWriter.apply(plan, domain: o.domain)
        print("Written. To undo, quit MockTab and run:\n  \(restore)")
    }

    /// The report's tablet to import: the one named, or the only one MockTab knows.
    static func chooseTablet(_ report: Report, current: [String: Any], choice: Int?) throws -> Int {
        if let choice {
            guard report.tablets.indices.contains(choice - 1), report.tablets[choice - 1].productID != nil else {
                throw ApplyError.badTablet(choice)
            }
            return choice - 1
        }
        let rows = (current["_knownTablets"] as? Data)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        let known = Set(rows.compactMap { $0["id"] as? Int })
        let candidates = report.tablets.indices.filter { report.tablets[$0].productID.map(known.contains) ?? false }
        switch candidates.count {
        case 0: throw ApplyError.noKnownTablet
        case 1: return candidates[0]
        default:
            throw ApplyError.chooseTablet(candidates.map { i in
                let t = report.tablets[i]
                return "--tablet \(i + 1): \(t.modelName)" + String(format: " (product ID 0x%04X)", t.productID ?? 0)
                    + (t.nickname.map { ", \"\($0)\"" } ?? "")
            })
        }
    }

    static func describe(_ plan: WritePlan, tablet: TabletReport, number: Int, encoded: EncodedTablet) -> String {
        var out = "\nImport tablet \(number): \(tablet.modelName)"
            + String(format: " (product ID 0x%04X)", encoded.productID) + "\n"
        out += "  \(encoded.pens.count) pen\(encoded.pens.count == 1 ? "" : "s"), "
            + "\(encoded.apps.count) app\(encoded.apps.count == 1 ? "" : "s")\n"
        out += "\nRemoves \(plan.remove.count) settings:\n" + plan.remove.map { "  \($0)\n" }.joined()
        out += "\nSets \(plan.set.count) settings:\n" + plan.set.keys.sorted().map { "  \($0)\n" }.joined()
        if !encoded.leftOut.isEmpty {
            out += "\nNot written (unverified, or no MockTab setting):\n"
                + encoded.leftOut.map { "  \($0.control): \($0.wacom)\n" }.joined()
        }
        if !plan.notes.isEmpty { out += "\n" + plan.notes.map { "\($0)\n" }.joined() }
        return out
    }

    static func confirm(_ yes: Bool) throws {
        if yes { return }
        guard isatty(STDIN_FILENO) != 0 else {
            FileHandle.standardError.write(Data("Not a terminal; add --yes to write.\n".utf8))
            throw ApplyError.notConfirmed
        }
        print("Write these changes? [y/N] ", terminator: "")
        guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else { throw ApplyError.notConfirmed }
    }

    /// The whole domain as a binary plist, named so SettingsBackup's pruning
    /// (which matches `mocktab-settings-`) never deletes it.
    static func save(_ domain: [String: Any], domain name: String, to dir: URL?) throws -> URL {
        let dir = dir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = dir.appendingPathComponent("mocktab-before-wacom-import-\(stamp.string(from: Date())).plist")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw ApplyError.saveFailed("\(url.lastPathComponent) already exists")
            }
            let data = try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
            try data.write(to: url, options: .atomic)
        } catch let e as ApplyError {
            throw e
        } catch {
            throw ApplyError.saveFailed(error.localizedDescription)
        }
        return url
    }
}
