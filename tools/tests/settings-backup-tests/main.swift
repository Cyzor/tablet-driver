// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// Checks SettingsBackup against a scratch defaults suite and a temporary
// directory: a backup on each build change and none on a relaunch, the copy
// matching what the previous build left, snapshots sharing one file, nothing
// written for empty settings, plain names, and pruning to the newest `keepCount`.

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

let domain = "com.cyzor.mocktab.settings-backup-tests"
let defaults = UserDefaults(suiteName: domain)!
defaults.removePersistentDomain(forName: domain)
let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("settings-backup-tests-\(UUID().uuidString)", isDirectory: true)

func backups() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
}

func backUp(_ build: String) {
    SettingsBackup.backUpOnBuildChange(build: build, domain: domain, defaults: defaults, directory: dir)
    usleep(20_000)  // distinct modification times for pruning
}

func saved(_ name: String) -> [String: Any]? {
    FileManager.default.contents(atPath: dir.appendingPathComponent(name).path)
        .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
}

// Empty settings: nothing to save, but the build is still recorded.
backUp("0.5.2")
expect(backups().isEmpty, "Empty settings write no backup")
expect(defaults.string(forKey: SettingsBackup.lastBuildKey) == "0.5.2", "Build is recorded")

// Same build again: no backup.
defaults.set("[1,2,3]", forKey: "device-0x0390.expressKeyBindings")
backUp("0.5.2")
expect(backups().isEmpty, "Relaunching the same build writes no backup")

// New build: one backup, named after the previous build, holding its settings.
backUp("0.5.3")
expect(backups() == ["mocktab-settings-0.5.2.plist"], "A build change writes one backup named after the previous build")
expect(saved("mocktab-settings-0.5.2.plist")?["device-0x0390.expressKeyBindings"] as? String == "[1,2,3]",
       "Backup holds the settings")
expect(defaults.string(forKey: SettingsBackup.lastBuildKey) == "0.5.3", "New build is recorded")

// Snapshots share one file, and a release's copy outlives them.
backUp("0.5.3-snapshot-20261101T1200Z")
defaults.set("damaged", forKey: "device-0x0390.expressKeyBindings")
backUp("0.5.3-snapshot-20261102T1200Z")
expect(backups().filter { $0.contains("snapshot") } == ["mocktab-settings-0.5.3-snapshot.plist"],
       "Snapshots share one backup: \(backups())")
expect(saved("mocktab-settings-0.5.3-snapshot.plist")?["device-0x0390.expressKeyBindings"] as? String == "damaged",
       "The snapshot backup holds the latest snapshot's settings")
expect(saved("mocktab-settings-0.5.3.plist")?["device-0x0390.expressKeyBindings"] as? String == "[1,2,3]",
       "The release backup still holds the settings from before the snapshots")
expect(SettingsBackup.fileLabel(for: "0.5.2") == "0.5.2", "A release keeps its label")
expect(SettingsBackup.fileLabel(for: "0.5.2-snapshot-20260928T1538Z") == "0.5.2-snapshot", "A snapshot drops its stamp")

// Labels reduce to letters, digits, dots, and single hyphens.
expect(SettingsBackup.fileSafe("a/b:c") == "a-b-c", "Path separators are replaced")
expect(SettingsBackup.fileSafe(" before  reset ") == "before-reset", "Spaces collapse to one hyphen")
expect(SettingsBackup.fileSafe("Ünïcode✏️") == "n-code", "Non-ASCII characters are replaced")
expect(SettingsBackup.fileSafe("///") == "unknown", "A label with nothing left gets a placeholder")
let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
expect(backups().allSatisfy { $0.allSatisfy(plain.contains) && $0.hasPrefix("mocktab-settings-") },
       "Every backup name is plain and prefixed: \(backups())")

// Pruning keeps the most recently written `keepCount`, whatever their names.
for i in 0..<(SettingsBackup.keepCount + 2) {
    backUp("0.9.\(9 - i)")
}
backUp("1.0")
let kept = backups()
expect(kept.count == SettingsBackup.keepCount, "Pruned to \(SettingsBackup.keepCount): \(kept)")
expect(kept.contains("mocktab-settings-0.9.5.plist"), "Newest backup survives: \(kept)")
expect(!kept.contains("mocktab-settings-0.5.2.plist"), "Oldest backup is pruned")

defaults.removePersistentDomain(forName: domain)
try? FileManager.default.removeItem(at: dir)

if failures == 0 {
    print("SettingsBackupTests: \(checks) checks passed")
    exit(0)
} else {
    print("SettingsBackupTests: \(failures)/\(checks) checks FAILED")
    exit(1)
}
