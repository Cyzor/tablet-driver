// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Watches one Bluetooth-to-USB switch of a Wacom tablet while the pen hovers,
// and records what MockTab posted around it: proximity changes, the gap in
// pen events, and the pressure that followed. Prompts for each step and ends
// on its own. hardware-check.sh runs it once per build and compares the runs.
//
// Watches only. It never opens the tablet or changes an event.
//
// Usage:
//   transport_switch_check --pid <MockTab pid> --label <build> --out <file.json>
//   transport_switch_check --compare <a.json> <b.json>

import AppKit
import Foundation
import IOKit.hid

let args = CommandLine.arguments

func option(_ name: String) -> String? {
    args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

func say(_ s: String) { print(s); fflush(stdout) }

// MARK: - Compare mode

struct Summary: Codable {
    var label: String
    var app: String
    var valid: Bool
    var note: String
    var gapMs: Int?
    var proximityAcrossSwitch: [String]
    var enterBeforeFirstPointer: Bool
    var tabletIDBefore: String?
    var tabletIDAfter: String?
    var maxHoverPressureAfter: Double
    var maxContactPressureAfter: Double?
    var contacts: Int
}

struct Result: Codable {
    var summary: Summary
    var trace: [[String: String]]
}

if let i = args.firstIndex(of: "--compare"), i + 2 < args.count {
    let dec = JSONDecoder()
    let runs = args[(i + 1)...(i + 2)].map { path -> Summary in
        guard let data = FileManager.default.contents(atPath: path),
              let r = try? dec.decode(Result.self, from: data)
        else { say("Can't read \(path)"); exit(1) }
        return r.summary
    }
    func row(_ name: String, _ f: (Summary) -> String) {
        let cells = runs.map { f($0).padding(toLength: 30, withPad: " ", startingAt: 0) }
        say(name.padding(toLength: 30, withPad: " ", startingAt: 0) + cells.joined())
    }
    row("") { $0.label }
    row("Valid run") { $0.valid ? "yes" : "no: \($0.note)" }
    row("Pen gap at switch") { $0.gapMs.map { "\($0) ms" } ?? "?" }
    row("Proximity across switch") { $0.proximityAcrossSwitch.isEmpty ? "none" : $0.proximityAcrossSwitch.joined(separator: ", ") }
    row("Enter before USB pen events") { $0.enterBeforeFirstPointer ? "yes" : "no" }
    row("Tablet ID before → after") { "\($0.tabletIDBefore ?? "?") → \($0.tabletIDAfter ?? "same")" }
    row("Hover pressure after") { String(format: "%.3f", $0.maxHoverPressureAfter) }
    row("Contact pressure after") { $0.maxContactPressureAfter.map { String(format: "%.3f", $0) } ?? "no contact" }
    say("")
    guard runs.allSatisfy(\.valid) else {
        say("Verdict: at least one run is invalid; run it again.")
        exit(2)
    }
    let shape = { (s: Summary) in
        "\(s.proximityAcrossSwitch) \(s.enterBeforeFirstPointer) \(s.tabletIDAfter != nil) \(s.maxHoverPressureAfter > 0)"
    }
    if shape(runs[0]) == shape(runs[1]) {
        say("Verdict: both builds behave the same around the switch. Not a regression.")
        exit(0)
    }
    say("Verdict: the builds differ around the switch. Treat it as a regression until explained.")
    exit(3)
}

// MARK: - Watch mode

let mocktabPID = option("--pid").flatMap { Int64($0) } ?? 0
let outPath = option("--out") ?? ""
if mocktabPID == 0 || outPath.isEmpty {
    say("usage: transport_switch_check --pid <MockTab pid> --label <build> --out <file.json>")
    exit(64)
}
let label = option("--label") ?? "?"
let appPath = NSRunningApplication(processIdentifier: pid_t(mocktabPID))?.bundleURL?.path ?? "?"

func now() -> Double { ProcessInfo.processInfo.systemUptime }
let started = now()

struct Event {
    enum Kind { case pointer, down, up, enter, exit, usbArrived, usbLeft, btArrived, btLeft }
    var t: Double
    var kind: Kind
    var pressure: Double = 0
    var tabletID: Int64 = 0
    var detail = ""
}
var events: [Event] = []

// Tablet presence, by polling the HID registry. Matching needs no open, so
// this never becomes a client of the tablet.
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x056A] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

func transports() -> (usb: Bool, bt: Bool) {
    guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return (false, false) }
    var usb = false, bt = false
    for d in set {
        let t = (IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String) ?? ""
        if t == "USB" { usb = true } else if t.hasPrefix("Bluetooth") { bt = true }
    }
    return (usb, bt)
}
var present = transports()

// MockTab's posted events.
var buttonDown = false
var lastTabletID: Int64 = 0

let callback: CGEventTapCallBack = { _, type, e, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = globalTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(e)
    }
    guard e.getIntegerValueField(.eventSourceUnixProcessID) == mocktabPID else {
        return Unmanaged.passUnretained(e)
    }
    let t = now()
    switch type {
    case .tabletProximity:
        let entering = e.getIntegerValueField(.tabletProximityEventEnterProximity) != 0
        let id = e.getIntegerValueField(.tabletProximityEventTabletID)
        if entering { lastTabletID = id }
        events.append(Event(t: t, kind: entering ? .enter : .exit, tabletID: id))
    case .leftMouseDown:
        buttonDown = true
        events.append(Event(t: t, kind: .down, pressure: e.getDoubleValueField(.mouseEventPressure)))
    case .leftMouseUp:
        buttonDown = false
        events.append(Event(t: t, kind: .up))
    case .mouseMoved, .leftMouseDragged:
        // Subtype 1 is a tablet point; subtype 2 repeats a proximity change.
        guard e.getIntegerValueField(.mouseEventSubtype) == 1 else { break }
        events.append(Event(t: t, kind: .pointer, pressure: e.getDoubleValueField(.mouseEventPressure)))
    default:
        break
    }
    return Unmanaged.passUnretained(e)
}

var globalTap: CFMachPort?
let mask: CGEventMask = [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .tabletProximity]
    .reduce(0) { $0 | (1 << CGEventMask($1.rawValue)) }
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
    eventsOfInterest: mask, callback: callback, userInfo: nil)
else {
    say("Can't watch events. Give your terminal Accessibility access in System Settings.")
    exit(1)
}
globalTap = tap
CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

// MARK: Steps

enum Step { case needBluetooth, needHover, armed, switched }
var step = Step.needBluetooth
var lastPrompt = ""
var armedAt = 0.0
var switchAt = 0.0
let timeout = 120.0

func prompt(_ s: String) {
    if s != lastPrompt { say("  → " + s); lastPrompt = s }
}

func pointers(since t: Double) -> Int {
    events.reversed().prefix { $0.t >= t }.filter { $0.kind == .pointer }.count
}

func finish() -> Never {
    let before = events.filter { $0.t < switchAt }
    let after = events.filter { $0.t >= switchAt }
    let lastPointerBefore = before.last { $0.kind == .pointer }
    let firstPointerAfter = after.first { $0.kind == .pointer }
    let from = lastPointerBefore?.t ?? switchAt
    let to = firstPointerAfter?.t ?? .infinity
    let across = events.filter { $0.t > from && $0.t < to && ($0.kind == .enter || $0.kind == .exit) }
    let exitWhileArmed = events.contains { $0.kind == .exit && $0.t >= armedAt && $0.t <= from }
    let firstDownAfter = after.first { $0.kind == .down }?.t ?? .infinity
    let hover = after.filter { $0.kind == .pointer && $0.t < firstDownAfter }
    let contact = after.filter { ($0.kind == .pointer || $0.kind == .down) && $0.t >= firstDownAfter }
    let enterBefore = before.last { $0.kind == .enter }?.tabletID
    let enterAfter = after.last { $0.kind == .enter }?.tabletID

    var valid = true, note = ""
    if firstPointerAfter == nil { valid = false; note = "no pen events after the switch" }
    else if exitWhileArmed { valid = false; note = "pen left range before the switch" }

    let hex = { (v: Int64?) in v.map { "0x" + String($0, radix: 16) } }
    let summary = Summary(
        label: label, app: appPath, valid: valid, note: note,
        gapMs: firstPointerAfter.map { Int((($0.t - from) * 1000).rounded()) },
        proximityAcrossSwitch: across.map { $0.kind == .enter ? "enter \(hex($0.tabletID)!)" : "exit" },
        enterBeforeFirstPointer: across.last?.kind == .enter,
        tabletIDBefore: hex(enterBefore),
        tabletIDAfter: enterAfter.flatMap { $0 == enterBefore ? nil : hex($0) },
        maxHoverPressureAfter: hover.map(\.pressure).max() ?? 0,
        maxContactPressureAfter: contact.map(\.pressure).max(),
        contacts: after.filter { $0.kind == .down }.count)

    // Keep everything from five seconds before the switch.
    let trace = events.filter { $0.t >= switchAt - 5 }.map { e -> [String: String] in
        var d = ["t": String(format: "%.4f", e.t - switchAt), "kind": "\(e.kind)"]
        if e.kind == .pointer || e.kind == .down { d["pressure"] = String(format: "%.4f", e.pressure) }
        if e.kind == .enter || e.kind == .exit { d["tablet"] = hex(e.tabletID) }
        return d
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileManager.default.createFile(atPath: outPath, contents: try! enc.encode(Result(summary: summary, trace: trace)))
    say(valid ? "  Done." : "  This run doesn't count: \(note).")
    exit(valid ? 0 : 2)
}

Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    let t = now()
    let p = transports()
    if p.usb != present.usb { events.append(Event(t: t, kind: p.usb ? .usbArrived : .usbLeft)) }
    if p.bt != present.bt { events.append(Event(t: t, kind: p.bt ? .btArrived : .btLeft)) }
    present = p

    if t - started > timeout {
        if step == .switched { finish() }
        say("  Gave up after \(Int(timeout)) s.")
        exit(2)
    }
    switch step {
    case .needBluetooth:
        if p.usb { prompt("Unplug the tablet's USB cable.") }
        else if !p.bt { prompt("Connect the tablet over Bluetooth.") }
        else { step = .needHover }
    case .needHover:
        if p.usb { step = .needBluetooth; break }
        prompt("Hover the pen over the tablet, without touching.")
        if pointers(since: t - 0.5) >= 15 && !buttonDown {
            step = .armed
            armedAt = t
            prompt("Keep hovering, and plug in the USB cable.")
        }
    case .armed:
        if p.usb {
            step = .switched
            switchAt = t
            prompt("Keep hovering. When the cursor moves again, touch the tip down once and lift it.")
        } else if pointers(since: t - 3) == 0 {
            step = .needHover
        }
    case .switched:
        let ups = events.filter { $0.t > switchAt && $0.kind == .up }
        if let up = ups.first, t - up.t > 0.5 { finish() }
    }
}

signal(SIGINT) { _ in exit(130) }
say("Bluetooth-to-USB switch, \(label)")
CFRunLoopRun()
