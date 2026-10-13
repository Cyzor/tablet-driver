// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Use every control on a Xencelabs Quick Keys or Pen Display, in any order.
// Reads the device's own reports to tell which control each press was,
// records what happened on the Mac while it was held, and ends once every
// control on the devices in use has been pressed. The one failure it judges:
// a modifier still held after every control is up.
//
// Opens the device without seizing it, so MockTab keeps receiving everything.
// The terminal needs Accessibility and Input Monitoring.
//
// Usage: xencelabs_check --pid <MockTab pid> --label <build> --out <dir>
//
// Writes one result per device, named after the build and product ID, and
// skips a device whose saved run used every control.

import AppKit
import Foundation
import IOKit.hid

let args = CommandLine.arguments

func option(_ name: String) -> String? {
    args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

func say(_ s: String) { print(s); fflush(stdout) }

let mocktabPID = option("--pid").flatMap { Int64($0) } ?? 0
let outPath = option("--out") ?? ""
if mocktabPID == 0 || outPath.isEmpty {
    say("usage: xencelabs_check --pid <MockTab pid> --label <build> --out <dir>")
    exit(64)
}
let label = option("--label") ?? "?"

func now() -> Double { ProcessInfo.processInfo.systemUptime }

func resultPath(_ pid: Int) -> String {
    let build = label.split(separator: " ").last.map(String.init) ?? label
    return "\(outPath)/xencelabs-\(build)-\(String(format: "%04x", pid)).json"
}
/// Done means a saved run that used every control; anything less is redone.
func isDone(_ pid: Int) -> Bool {
    guard let data = FileManager.default.contents(atPath: resultPath(pid)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    return json["complete"] as? Bool == true
}

// Report layout from TabletKit's XencelabsDecoder: report 2, tag 0xF0. On the
// Quick Keys, byte 2 holds keys 1–8, byte 3 bit 0 the mode button and bit 1
// the dial press, and byte 7 a dial step (1 counterclockwise, 2 clockwise).
// Keys 1–4 are the top row and 5–8 the bottom row, left to right, with the
// dial on the right. The Pen Display's three bezel buttons are byte 2 bits 0–2.
let quickKeysControls =
    ["top row, 1st", "top row, 2nd", "top row, 3rd", "top row, 4th",
     "bottom row, 1st", "bottom row, 2nd", "bottom row, 3rd", "bottom row, 4th",
     "mode button", "dial press", "dial clockwise", "dial counterclockwise"]
let penDisplayControls = ["bezel button 1", "bezel button 2", "bezel button 3"]

let models: [Int: (name: String, controls: [String])] = [
    0x5202: ("Quick Keys", quickKeysControls),
    0x5203: ("Quick Keys (wireless)", quickKeysControls),
    0x520D: ("Pen Display 24", penDisplayControls),
    0x520B: ("Pen Display 16", penDisplayControls),
]

final class Device {
    let pid: Int
    let name: String
    let controls: [String]
    var seen: [String: Int] = [:]
    var effects: [String: [String]] = [:]
    var held: Set<String> = []
    var lastKeys: UInt8 = 0
    var lastExtra: UInt8 = 0

    init(pid: Int, name: String, controls: [String]) {
        self.pid = pid
        self.name = name
        self.controls = controls
    }

    var isQuickKeys: Bool { controls == quickKeysControls }
    var complete: Bool { controls.allSatisfy { seen[$0] != nil } }
    var touched: Bool { !seen.isEmpty }
}

var devices: [Int: Device] = [:]
var leaks: [String] = []
var allUpAt: Double? = nil

// What happens on the Mac is credited to every control held, or released in
// the last moment (the dial has no release, so each step counts as one).
var recent: [(device: Device, control: String, until: Double)] = []
let afterRelease = 0.3

func showRemaining(_ d: Device) {
    let left = d.controls.filter { d.seen[$0] == nil }
    if left.isEmpty { say("  \(d.name): all done"); return }
    say(left.count <= 4 ? "  Left: " + left.joined(separator: "; ") : "  \(left.count) left")
}

func press(_ d: Device, _ c: String, momentary: Bool = false) {
    let first = d.seen[c] == nil
    d.seen[c, default: 0] += 1
    if momentary { recent.append((d, c, now() + afterRelease)) } else { d.held.insert(c) }
    if first {
        say("  ✓ \(d.name): \(c)")
        showRemaining(d)
    }
}

func release(_ d: Device, _ c: String) {
    d.held.remove(c)
    recent.append((d, c, now() + afterRelease))
}

// MARK: Device reports

let reportCallback: IOHIDReportCallback = { _, _, sender, _, _, report, length in
    guard let sender, length >= 8, report[0] == 0x02, report[1] == 0xF0 else { return }
    let hid = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
    let pid = (IOHIDDeviceGetProperty(hid, kIOHIDProductIDKey as CFString) as? Int) ?? 0
    guard let d = devices[pid] else { return }

    let hadHeld = !d.held.isEmpty
    let keys = report[2] & (d.isQuickKeys ? 0xFF : 0x07)
    let extra = d.isQuickKeys ? report[3] & 0x03 : 0
    for i in 0..<(d.isQuickKeys ? 8 : 3) {
        let bit: UInt8 = 1 << i
        if keys & bit != 0, d.lastKeys & bit == 0 { press(d, d.controls[i]) }
        if keys & bit == 0, d.lastKeys & bit != 0 { release(d, d.controls[i]) }
    }
    if d.isQuickKeys {
        for (i, name) in [(0, "mode button"), (1, "dial press")] {
            let bit: UInt8 = 1 << i
            if extra & bit != 0, d.lastExtra & bit == 0 { press(d, name) }
            if extra & bit == 0, d.lastExtra & bit != 0 { release(d, name) }
        }
        switch report[7] {
        case 1: press(d, "dial counterclockwise", momentary: true)
        case 2: press(d, "dial clockwise", momentary: true)
        default: break
        }
    }
    d.lastKeys = keys
    d.lastExtra = extra
    // Start the leak check when the last held control comes up.
    if hadHeld && d.held.isEmpty { allUpAt = now() } else if !d.held.isEmpty { allUpAt = nil }
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatchingMultiple(
    manager, models.keys.map { [kIOHIDVendorIDKey: 0x28BD, kIOHIDProductIDKey: $0] } as CFArray)
IOHIDManagerRegisterInputReportCallback(manager, reportCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    say("Can't read the device. Give your terminal Input Monitoring in System Settings.")
    exit(1)
}

// Devices match once the run loop turns.
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    let present = Set((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []).compactMap {
        IOHIDDeviceGetProperty($0, kIOHIDProductIDKey as CFString) as? Int
    })
    if present.isEmpty {
        say("No Quick Keys or Pen Display connected.")
        exit(1)
    }
    for pid in present.sorted() {
        guard let m = models[pid] else { continue }
        if isDone(pid) {
            say("  \(m.name): already done")
        } else {
            devices[pid] = Device(pid: pid, name: m.name, controls: m.controls)
            say("  \(m.name): \(m.controls.count) controls")
        }
    }
    if devices.isEmpty { exit(0) }
}

// MARK: What happened on the Mac

// Modifiers as of the last flagsChanged anyone posted.
var lastPostedFlags: CGEventFlags = []
let modifierMask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]

func modifierNames(_ f: CGEventFlags) -> String {
    var s = ""
    if f.contains(.maskControl) { s += "⌃" }
    if f.contains(.maskAlternate) { s += "⌥" }
    if f.contains(.maskShift) { s += "⇧" }
    if f.contains(.maskCommand) { s += "⌘" }
    return s
}

let keyNames: [Int64: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
    12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P",
    37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 27: "-", 24: "=", 33: "[", 30: "]",
    36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape", 117: "Forward Delete",
    115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
    123: "←", 124: "→", 125: "↓", 126: "↑",
]

func describe(_ type: CGEventType, _ e: CGEvent) -> String? {
    switch type {
    case .keyDown:
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        return modifierNames(e.flags.intersection(modifierMask)) + (keyNames[code] ?? "key \(code)")
    case .leftMouseDown: return "left click"
    case .rightMouseDown: return "right click"
    case .otherMouseDown: return "button \(e.getIntegerValueField(.mouseEventButtonNumber) + 1) click"
    case .scrollWheel: return "scroll"
    case .flagsChanged:
        let mods = e.flags.intersection(modifierMask)
        lastPostedFlags = mods
        return mods.isEmpty ? nil : "holds " + modifierNames(mods)
    default:
        // 29 is a gesture (zoom or rotate); 14 a system key such as volume.
        if type.rawValue == 29 { return "gesture" }
        if type.rawValue == 14 { return "system key" }
        return nil
    }
}

func note(_ effect: String) {
    let t = now()
    var targets: [(Device, String)] = []
    for d in devices.values { targets += d.held.map { (d, $0) } }
    targets += recent.filter { $0.until >= t }.map { ($0.device, $0.control) }
    for (d, c) in targets where !(d.effects[c] ?? []).contains(effect) {
        d.effects[c, default: []].append(effect)
    }
}

var globalTap: CFMachPort?
let tapCallback: CGEventTapCallBack = { _, type, e, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = globalTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(e)
    }
    if var d = describe(type, e) {
        if e.getIntegerValueField(.eventSourceUnixProcessID) != mocktabPID { d += " (not from MockTab)" }
        note(d)
    }
    return Unmanaged.passUnretained(e)
}
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
    eventsOfInterest: CGEventMask.max, callback: tapCallback, userInfo: nil)
else {
    say("Can't watch events. Give your terminal Accessibility access in System Settings.")
    exit(1)
}
globalTap = tap
CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

/// Modifiers held now. MockTab posts at the HID level, so its modifiers can't
/// be told apart from the keyboard's; keep hands off the keyboard meanwhile.
func heldModifiers() -> CGEventFlags {
    CGEventSource.flagsState(.combinedSessionState).intersection(modifierMask).union(lastPostedFlags)
}

// MARK: Finish

struct Result: Codable {
    var label: String
    var device: String
    var complete: Bool
    var controls: [String: [String]]
    var leaks: [String]
}

func finish() -> Never {
    let used = devices.values.filter(\.touched).sorted { $0.name < $1.name }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    for d in used {
        let result = Result(
            label: label, device: d.name, complete: d.complete,
            controls: Dictionary(uniqueKeysWithValues: d.controls.compactMap { c in
                d.seen[c] == nil ? nil : (c, d.effects[c] ?? [])
            }),
            leaks: leaks)
        FileManager.default.createFile(atPath: resultPath(d.pid), contents: try! enc.encode(result))
        say("")
        say("  \(d.name)")
        for c in d.controls {
            let effects = d.effects[c] ?? []
            let what = d.seen[c] == nil ? "not pressed"
                : effects.isEmpty ? "nothing visible (fine for a mode or pen action)" : effects.joined(separator: ", ")
            say("    " + c.padding(toLength: 24, withPad: " ", startingAt: 0) + what)
        }
    }
    say("")
    if !leaks.isEmpty { say("  ✗ A modifier stayed held after every control was up: " + leaks.joined(separator: ", ")) }
    let ok = !used.isEmpty && used.allSatisfy(\.complete) && leaks.isEmpty
    say(ok ? "  Done. Check the list matches your settings." : "  Done, with problems above.")
    exit(ok ? 0 : 2)
}

var finishAt: Double? = nil
Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    let t = now()
    recent.removeAll { $0.until < t }
    let anyHeld = devices.values.contains { !$0.held.isEmpty }
    // A modifier binding shows up as held modifiers, not always as an event.
    let mods = heldModifiers()
    if !mods.isEmpty, anyHeld { note("holds " + modifierNames(mods)) }
    if let up = allUpAt, t - up > 0.5, !anyHeld {
        allUpAt = nil
        if !mods.isEmpty {
            leaks.append(modifierNames(mods))
            say("  ✗ \(modifierNames(mods)) still held with every control up")
        }
    }
    // Finish a moment after the last control on every device in use.
    let used = devices.values.filter(\.touched)
    if finishAt == nil, !used.isEmpty, used.allSatisfy(\.complete), !anyHeld { finishAt = t + 0.8 }
    if let f = finishAt, t >= f { finish() }
}

let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { finish() }
sigint.resume()
signal(SIGINT, SIG_IGN)

say("Xencelabs controls, \(label)")
say("  Press every key and button, press the dial, and turn it both ways.")
say("  Any order. Keep your hands off the keyboard. Control-C stops early.")
CFRunLoopRun()
