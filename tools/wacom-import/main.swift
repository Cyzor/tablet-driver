// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lists what importing a Wacom Tablet Utility backup into MockTab would do:
// each setting, what it becomes, and what gets skipped. Writes nothing.
//
// Run it through run.sh with the .wacomprefs folder Tablet Utility saved.
// Characters in recorded keystrokes are looked up on the current keyboard
// layout, so run it on the Mac the settings came from.

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

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 1, !args[0].hasPrefix("-") else {
    FileHandle.standardError.write(Data("Usage: tools/wacom-import/run.sh <backup.wacomprefs>\n".utf8))
    exit(2)
}

do {
    let backup = try WacomBackup.load(URL(fileURLWithPath: args[0]))
    print(ReportText.render(WacomMapper.report(backup, layout: currentLayout())), terminator: "")
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
