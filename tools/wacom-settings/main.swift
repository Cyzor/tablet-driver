// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lists what importing a Wacom settings backup into MockTab would do: each
// setting, what it becomes, and what gets skipped. With --apply it then
// writes one tablet's settings, after saving the whole settings domain.
//
// Run it through run.sh with a .wacomprefs folder from Wacom Center or Tablet
// Utility; Wacom Center keeps them in ~/Library/Application Support/Wacom/Backups.
// It looks up recorded characters on the current keyboard layout, so run it
// on the Mac that made the backup.
//
//   run.sh <backup>                          report only
//   run.sh --apply [options] <backup>        report, then write
//     --tablet N       the report's tablet number, when MockTab knows several
//     --pen 0xSERIAL   whose per-app pen settings to use when pens disagree
//     --dry-run        show what would change, save and write nothing
//     --yes            don't ask before writing
//
// --domain and --save-to point it at a scratch domain and folder for tests.

import Foundation

let usage = "Usage: tools/wacom-settings/run.sh [--apply [--tablet N] [--pen 0xSERIAL] [--dry-run] [--yes]] <backup.wacomprefs>\n"

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data(message.utf8))
    exit(code)
}

var apply = false
var options = ApplyOptions()
var backupPath: String?
var args = Array(CommandLine.arguments.dropFirst())[...]
while let arg = args.popFirst() {
    switch arg {
    case "--apply": apply = true
    case "--dry-run": options.dryRun = true
    case "--yes": options.yes = true
    case "--tablet":
        guard let n = args.popFirst().flatMap({ Int($0) }) else { fail(usage, 2) }
        options.tablet = n
    case "--pen":
        guard let s = args.popFirst(), s.hasPrefix("0x"), let n = UInt32(s.dropFirst(2), radix: 16) else { fail(usage, 2) }
        options.pen = n
    case "--domain":
        guard let d = args.popFirst() else { fail(usage, 2) }
        options.domain = d
    case "--save-to":
        guard let d = args.popFirst() else { fail(usage, 2) }
        options.saveTo = URL(fileURLWithPath: d, isDirectory: true)
    default:
        guard !arg.hasPrefix("-"), backupPath == nil else { fail(usage, 2) }
        backupPath = arg
    }
}
guard let backupPath else { fail(usage, 2) }

do {
    let backup = try WacomBackup.load(URL(fileURLWithPath: backupPath))
    let layouts = KeyboardLayout.current()
    let report = WacomMapper.report(backup, layout: KeyboardLayout.lookup(layouts))
    print(ReportText.render(report, reportOnly: !apply, layout: layouts.first?.name), terminator: "")
    if apply { try Apply.run(report, options) }
} catch {
    fail("\(error)\n", 1)
}
