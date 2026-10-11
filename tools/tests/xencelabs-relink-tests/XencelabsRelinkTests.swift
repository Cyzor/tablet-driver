// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

// XencelabsRelinkTests.swift — Standalone checks for the puck relink state
// machine. Frames are synthetic, built from the shapes the source documents.
// Run via tools/tests/xencelabs-relink-tests/run.sh.

import Foundation

private var failures = 0
private var checks = 0

private func expect(
    _ condition: Bool, _ message: @autoclosure () -> String,
    file: StaticString = #file, line: UInt = #line
) {
    checks += 1
    guard !condition else { return }
    failures += 1
    FileHandle.standardError.write(Data("FAIL (\(file):\(line)): \(message())\n".utf8))
}

private let dongle = 0x5203
private let penDisplay = 0x520D
private let wiredPuck = 0x5202
private let identity: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66]

/// A 0xF8 status frame: identity at offset 10.
private func status(online: Bool, slot: UInt8 = 1) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: 32)
    r[0] = 0x02; r[1] = 0xF8; r[2] = online ? 0x02 : 0x01; r[3] = slot
    r.replaceSubrange(10..<16, with: identity)
    return r
}

/// Ordinary puck traffic (0xF0 aux, 0xF2 battery): identity at offset 12.
private func traffic(tag: UInt8 = 0xF0, id: [UInt8] = identity) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: 32)
    r[0] = 0x02; r[1] = tag
    r.replaceSubrange(12..<18, with: id)
    return r
}

private func note(
    _ s: inout XencelabsRelinkState, _ r: [UInt8], pid: Int = dongle
) -> XencelabsRelinkState.Outcome {
    r.withUnsafeBufferPointer { s.noteReport($0.baseAddress!, length: r.count, productID: pid) }
}

@main
enum XencelabsRelinkTests {
    static func main() {
        // Ordinary traffic relinks once, from offset 12.
        do {
            var s = XencelabsRelinkState()
            let first = note(&s, traffic())
            expect(first.relinkIdentity == identity, "traffic relinks with offset-12 identity: \(first)")
            expect(first.linkChange == nil, "traffic changes no link state")
            expect(note(&s, traffic()).relinkIdentity == nil, "relink is one-shot")
            expect(s.dongleIdentity == identity, "identity kept")
        }

        // An online announce relinks from offset 10.
        do {
            var s = XencelabsRelinkState()
            let o = note(&s, status(online: true))
            expect(o.relinkIdentity == identity, "announce relinks with offset-10 identity: \(o)")
            expect(o.linkChange == nil, "first online frame isn't a re-arm")
        }

        // A later online frame re-arms and relinks in the same report, and bumps the generation.
        do {
            var s = XencelabsRelinkState()
            _ = note(&s, traffic())
            let gen = s.relinkGeneration
            let o = note(&s, status(online: true, slot: 2))
            expect(o.linkChange == .rearmed, "online after relink re-arms")
            expect(o.relinkIdentity == identity, "re-arm relinks in the same frame")
            expect(s.relinkGeneration == gen + 1, "re-arm bumps generation")
        }

        // Offline bumps the generation, sends nothing, and doesn't re-arm.
        do {
            var s = XencelabsRelinkState()
            _ = note(&s, traffic())
            let gen = s.relinkGeneration
            let o = note(&s, status(online: false))
            expect(o == .init(linkChange: .offline, relinkIdentity: nil), "offline: \(o)")
            expect(s.relinkGeneration == gen + 1, "offline bumps generation")
            expect(s.dongleRelinked, "offline leaves relinked set")
            expect(note(&s, traffic()).relinkIdentity == nil, "no relink after offline until online")
        }

        // Offline before any relink doesn't relink off its own trailer.
        do {
            var s = XencelabsRelinkState()
            expect(note(&s, status(online: false)).relinkIdentity == nil, "offline frame never relinks")
        }

        // Status frames outside slots 1–2, or with byte 2 zero, aren't status.
        do {
            var s = XencelabsRelinkState()
            var r = status(online: true, slot: 3)
            _ = note(&s, traffic())
            expect(note(&s, r).linkChange == nil, "slot 3 ignored")
            r = status(online: true); r[2] = 0
            expect(note(&s, r).linkChange == nil, "byte 2 zero ignored")
        }

        // Pen Display: its own pen frames (tag not 0xF?) never relink; puck traffic does.
        do {
            var s = XencelabsRelinkState()
            var pen = traffic(tag: 0x80)
            pen[12] = 0x7F
            expect(note(&s, pen, pid: penDisplay).relinkIdentity == nil, "pen frame ignored")
            expect(note(&s, traffic(), pid: penDisplay).relinkIdentity == identity, "relayed puck relinks")
        }

        // Wired puck and non-relay devices are ignored.
        do {
            var s = XencelabsRelinkState()
            expect(note(&s, traffic(), pid: wiredPuck) == .init(), "wired puck ignored")
            expect(note(&s, status(online: false), pid: wiredPuck) == .init(), "wired status ignored")
            expect(s.relinkGeneration == 0, "no generation change")
        }

        // All-zero identity, wrong report ID, and short reports don't relink.
        do {
            var s = XencelabsRelinkState()
            expect(note(&s, traffic(id: [0, 0, 0, 0, 0, 0])).relinkIdentity == nil, "zero identity")
            var r = traffic(); r[0] = 0x01
            expect(note(&s, r).relinkIdentity == nil, "report ID 1")
            expect(note(&s, Array(traffic().prefix(17))).relinkIdentity == nil, "17 bytes too short at offset 12")
            expect(note(&s, Array(traffic().prefix(18))).relinkIdentity == identity, "18 bytes enough")
        }

        // Display push: scheduled once per relink, only on success, for the current generation.
        do {
            var s = XencelabsRelinkState()
            _ = note(&s, traffic())
            expect(s.relinkSent(succeeded: false) == nil, "failed relink schedules nothing")
            let gen = s.relinkSent(succeeded: true)
            expect(gen == s.relinkGeneration, "push scheduled for current generation")
            expect(s.relinkSent(succeeded: true) == nil, "push scheduled once")
            _ = note(&s, status(online: true))
            expect(s.relinkGeneration != gen, "re-arm makes the old push stale")
            expect(s.relinkSent(succeeded: true) == s.relinkGeneration, "re-arm allows a new push")
        }

        if failures > 0 {
            FileHandle.standardError.write(Data("\(failures) of \(checks) checks failed\n".utf8))
            exit(1)
        }
        print("ok — \(checks) checks passed")
    }
}
