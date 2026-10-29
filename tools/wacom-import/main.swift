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
// Characters in recorded keystrokes are looked up on the current keyboard
// layout, so run it on the Mac the settings came from.
//
//   run.sh <backup>                          report only
//   run.sh --apply [options] <backup>        report, then write
//     --tablet N       the report's tablet number, when MockTab knows several
//     --pen 0xSERIAL   whose per-app pen settings to use when pens disagree
//     --dry-run        show what would change, save and write nothing
//     --yes            don't ask before writing
//
// --domain and --save-to point it at a scratch domain and folder for tests.

import Carbon
import Foundation

/// Finds each character's key on the current layout, preferring the one
/// that types it without Shift.
func currentLayout() -> LayoutLookup {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return { _ in nil } }
    let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    var table: [Character: LayoutKey] = [:]
    data.withUnsafeBytes { raw in
        guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
        for shift in [false, true] {
            for code in UInt16(0)..<128 {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let mods: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
                guard status == noErr, length == 1,
                      let c = String(utf16CodeUnits: chars, count: length).first,
                      !c.isWhitespace, c.asciiValue.map({ $0 >= 0x20 }) ?? true
                else { continue }
                if table[c] == nil { table[c] = LayoutKey(keyCode: code, needsShift: shift) }
            }
        }
    }
    return { table[$0] }
}

let usage = "Usage: tools/wacom-import/run.sh [--apply [--tablet N] [--pen 0xSERIAL] [--dry-run] [--yes]] <backup.wacomprefs>\n"

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
    let report = WacomMapper.report(backup, layout: currentLayout())
    print(ReportText.render(report), terminator: "")
    if apply { try Apply.run(report, options) }
} catch {
    fail("\(error)\n", 1)
}
