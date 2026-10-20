// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Checks a Wacom tablet's key order: shows one key at a time by where it sits
// on the tablet, and records which control the tablet reports for it. The
// Buttons pane's tablet diagram uses a family's order only once a run like
// this agrees with it.
//
// Positions come from libwacom's layout, drawn with the tablet in landscape,
// as a right-handed user holds it. Expected controls come from
// `TabletControlMap`, without its verification gate.
//
// Opens the tablet without seizing it. Keep MockTab running so the tablet is
// set up as usual; keys may fire their bindings meanwhile. The terminal needs
// Input Monitoring. Built by key-order.sh.
//
// Usage: wacom_key_order [--out <dir>]
//
// Writes wacom-key-order-<product ID>.json to the output directory, with the
// raw report behind each key for decoder fixtures.

import Foundation
import IOKit.hid
import TabletKit

@main
enum KeyOrderCheck {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--out"), i + 1 < args.count { outDir = args[i + 1] }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x056A] as CFDictionary)
        IOHIDManagerRegisterInputReportCallback(manager, reportCallback, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            say("Can't read the tablet. Give your terminal Input Monitoring in System Settings.")
            exit(1)
        }
        // Pick the tablet once devices have matched.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
            let pids = Set(devices.compactMap { IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? Int })
            var skipped: [String] = []
            for pid in pids.sorted() {
                guard let spec = WacomDeviceRegistry.spec(for: pid) else { continue }
                guard let walk = Walk(pid: pid, spec: spec) else {
                    if spec.buttonCount > 0 { skipped.append(spec.name) }
                    continue
                }
                current = walk
                break
            }
            guard let walk = current else {
                say(skipped.isEmpty ? "No Wacom tablet with keys connected."
                    : "No family rule yet for: " + skipped.joined(separator: ", "))
                exit(1)
            }
            say("\(walk.name): \(walk.steps.count) keys, \(walk.family) rule")
            say("  Hold the tablet in landscape, as a right-handed user would. Press each key")
            say("  shown, then let go. Control-C stops early.")
            walk.prompt()
        }
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { current?.finish() ?? exit(1) }
        sigint.resume()
        signal(SIGINT, SIG_IGN)
        CFRunLoopRun()
    }
}

nonisolated(unsafe) var outDir = "/tmp/mocktab-hwcheck/results"
nonisolated(unsafe) var current: Walk?

func say(_ s: String) { print(s); fflush(stdout) }

let reportCallback: IOHIDReportCallback = { _, _, sender, _, _, report, length in
    guard let sender, let walk = current else { return }
    let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
    let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
    guard pid == walk.pid else { return }
    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
    let events = HIDReport.withReport(bytes) { walk.decoder.events($0) }
    for case .pad(let pad) in events { walk.handle(pad, report: bytes) }
}

// MARK: - The walk

final class Walk {
    struct Step {
        var group: String
        var letter: Character
        var expected: ControlTarget
        var picture: [String]
        var actual: ControlTarget?
        /// The report that pressed it, so a run can seed decoder fixtures.
        var report: [UInt8] = []
    }

    let pid: Int
    let name: String
    let family: TabletControlMap.Family
    var decoder: DeviceDecoder
    var steps: [Step] = []
    var index = 0
    var held: Set<ControlTarget> = []
    /// Set once the current step's key is recorded, until everything is let go.
    var waitingForRelease = false
    /// False between steps, so a key pressed before its prompt shows doesn't count.
    var ready = false

    init?(pid: Int, spec: TabletSpec) {
        guard let family = TabletControlMap.family(for: spec),
              let identity = TabletLayoutIdentity.all[pid],
              let parts = TabletFigure.layouts[pid]
        else { return nil }
        let map = TabletControlMap.make(identity, family: family)
        self.pid = pid
        name = spec.name
        self.family = family
        decoder = spec.makeDecoder()

        for (i, (entry, part)) in zip(identity.entries, parts).enumerated() {
            let group = Self.groupName(i, parts: parts)
            let grid: TabletLayoutIdentity.Grid
            switch entry {
            case let .run(letters): grid = .init(rows: letters.map { [.key($0)] })
            case let .cluster(g): grid = g
            case let .ring(_, .beside(g)), let .dial(_, .beside(g)): grid = g
            case let .ring(_, .center(letter)), let .dial(_, .center(letter)):
                grid = .init(rows: [[.key(letter)]])
            case .ring, .dial, .strip: continue
            }
            // Nearest the edge first, then along it.
            let columns = grid.rows.first?.count ?? 0
            var order: [Character] = []
            for c in 0..<columns {
                for row in grid.rows {
                    if case let .key(letter) = row[c], !order.contains(letter) { order.append(letter) }
                }
            }
            let centered: Bool
            if case .ring(_, .center) = entry { centered = true } else if case .dial(_, .center) = entry { centered = true } else { centered = false }
            for letter in order {
                guard let target = map.parts[i].keys[letter] else { continue }
                let picture = centered
                    ? ["(■)  the button in the middle of the ring"]
                    : Self.draw(grid, side: part.side, marking: letter)
                steps.append(Step(group: group, letter: letter, expected: target, picture: picture))
            }
        }
        if steps.isEmpty { return nil }
    }

    /// "left edge, group 2 of 3 from the top", counting every part on that edge.
    static func groupName(_ i: Int, parts: [TabletFigure.Part]) -> String {
        let side = parts[i].side
        let edge: String, from: String
        switch side {
        case .left: (edge, from) = ("left edge", "the top")
        case .right: (edge, from) = ("right edge", "the top")
        case .top: (edge, from) = ("top edge", "the left")
        case .bottom: (edge, from) = ("bottom edge", "the left")
        }
        let same = parts.indices.filter { parts[$0].side == side }.sorted { parts[$0].start < parts[$1].start }
        guard same.count > 1, let n = same.firstIndex(of: i) else { return edge }
        return "\(edge), group \(n + 1) of \(same.count) from \(from)"
    }

    /// The group as it sits on the tablet, the key to press filled in.
    static func draw(_ grid: TabletLayoutIdentity.Grid, side: TabletFigure.Side, marking target: Character) -> [String] {
        func cell(_ c: TabletLayoutIdentity.Cell) -> String {
            switch c {
            case .empty: return "   "
            case .body: return "(○)"
            case let .key(letter): return letter == target ? "[■]" : "[ ]"
            }
        }
        let rows = grid.rows, columns = rows.first?.count ?? 0
        var lines: [String] = []
        switch side {
        case .left, .right:
            for row in rows {
                let cells = side == .left ? row : row.reversed()
                lines.append(cells.map(cell).joined())
            }
            lines.append(side == .left ? "← tablet edge on this side" : "tablet edge on this side →")
        case .top, .bottom:
            let order = side == .top ? Array(0..<columns) : Array((0..<columns).reversed())
            for c in order { lines.append(rows.map { cell($0[c]) }.joined()) }
            if side == .top { lines.insert("↑ tablet edge", at: 0) } else { lines.append("↓ tablet edge") }
        }
        return lines
    }

    func prompt() {
        guard index < steps.count else { finish() }
        let step = steps[index]
        say("")
        say("  \(index + 1) of \(steps.count): \(step.group)")
        for line in step.picture { say("      " + line) }
        ready = true
    }

    func handle(_ pad: PadState, report: [UInt8]) {
        let down = ControlTarget.down(in: pad, includingPresses: true)
        let fresh = down.subtracting(held)
        held = ControlTarget.down(in: pad)
        if waitingForRelease {
            guard held.isEmpty else { return }
            waitingForRelease = false
            ready = false
            index += 1
            // A moment's pause, so a bounce doesn't count for the next key.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.prompt() }
            return
        }
        guard ready, index < steps.count, let actual = fresh.sorted(by: { $0.bit < $1.bit }).first else { return }
        steps[index].actual = actual
        steps[index].report = report
        let expected = steps[index].expected
        say(actual == expected ? "      ✓ \(Self.describe(actual))"
            : "      ✗ expected \(Self.describe(expected)), got \(Self.describe(actual))")
        waitingForRelease = true
        if held.isEmpty { handle(pad, report: report) }
    }

    static func describe(_ t: ControlTarget) -> String {
        switch t {
        case let .expressKey(i): return "ExpressKey \(i + 1)"
        case let .bezel(i): return "bezel button \(i + 1)"
        case let .ringCenter(i): return i == 0 ? "ring center or dial toggle" : "second ring center or dial toggle"
        case let .ring(i): return "ring \(i + 1)"
        case let .dial(i): return "dial \(i + 1)"
        case let .strip(i): return "strip \(i + 1)"
        }
    }

    struct Result: Codable {
        struct Entry: Codable {
            var group: String
            var letter: String
            var expected: String
            var actual: String?
            /// The raw report, in hex.
            var report: String?
        }
        var name: String
        var productID: String
        var family: String
        var complete: Bool
        var mismatches: Int
        var steps: [Entry]
    }

    func finish() -> Never {
        let done = steps.filter { $0.actual != nil }
        let wrong = done.filter { $0.actual != $0.expected }
        let result = Result(
            name: name, productID: String(format: "0x%04X", pid), family: "\(family)",
            complete: done.count == steps.count, mismatches: wrong.count,
            steps: steps.map { .init(group: $0.group, letter: String($0.letter), expected: Self.describe($0.expected),
                                     actual: $0.actual.map(Self.describe),
                                     report: $0.report.isEmpty ? nil : $0.report.map { String(format: "%02x", $0) }.joined(separator: " ")) })
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let path = "\(outDir)/wacom-key-order-\(String(format: "%04x", pid)).json"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: try! enc.encode(result))
        say("")
        say("  \(name): \(done.count) of \(steps.count) keys checked, \(wrong.count) not as expected")
        for step in wrong {
            say("    ✗ \(step.group), key \(step.letter): expected \(Self.describe(step.expected)), got \(Self.describe(step.actual!))")
        }
        say("  Wrote \(path)")
        exit(wrong.isEmpty && done.count == steps.count ? 0 : 2)
    }
}
