// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Use every control on a Wacom tablet, in any order: ExpressKeys, bezel
// buttons, rings, strips, the pen, and touch. Decodes the tablet's own reports
// with TabletKit, so it knows which control each report was and which
// controls the tablet has, records what happened on the Mac meanwhile, and
// ends once every control has been used.
//
// Judges three things: a modifier still held after every control is up,
// cursor events from outside MockTab while the pen or a finger is down (the
// tablet isn't held by MockTab alone), and errors MockTab logs during the run.
// Ring lights can't be seen from here, so tablets with them end on a question.
//
// Opens the tablet without seizing it, so MockTab keeps receiving everything.
// The terminal needs Accessibility and Input Monitoring. Built against
// TabletKit by hardware-check.sh.
//
// Usage: wacom_pad_check --pid <MockTab pid> --label <build> --out <dir>
//
// Writes one result per tablet, named after the build and product ID, and
// skips a tablet whose saved run used every control.

import AppKit
import Foundation
import IOKit.hid
import TabletKit

let args = CommandLine.arguments

func option(_ name: String) -> String? {
    args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

func say(_ s: String) { print(s); fflush(stdout) }

let mocktabPID = option("--pid").flatMap { Int64($0) } ?? 0
let outPath = option("--out") ?? ""
if mocktabPID == 0 || outPath.isEmpty {
    say("usage: wacom_pad_check --pid <MockTab pid> --label <build> --out <dir>")
    exit(64)
}
let label = option("--label") ?? "?"

func now() -> Double { ProcessInfo.processInfo.systemUptime }

/// A tablet reached through a wireless receiver gets its own result, apart
/// from the same tablet on a cable.
func resultPath(_ pid: Int, via receiver: Int? = nil) -> String {
    let build = label.split(separator: " ").last.map(String.init) ?? label
    let via = receiver.map { String(format: "-via-%04x", $0) } ?? ""
    return "\(outPath)/wacom-\(build)-\(String(format: "%04x", pid))\(via).json"
}
/// Done means a saved run that used every control; anything less is redone.
func isDone(_ pid: Int, via receiver: Int? = nil) -> Bool {
    guard let data = FileManager.default.contents(atPath: resultPath(pid, via: receiver)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tablet = json["tablet"] as? [String: Any]
    else { return false }
    return tablet["complete"] as? Bool == true
}

// Touch sensors that enumerate under their own product ID, and the decoder
// MockTab reads them with (WacomKnownDevice's touch-sensor table).
let separateTouchSensors: Set<Int> = [0x0335, 0x00F6, 0x005E, 0x005D]

// MARK: Tablets

final class Tablet {
    let pid: Int
    /// The wireless receiver the tablet reports through, if any.
    let receiver: Int?
    let name: String
    let controls: [String]
    let keyNames: [String]
    let bezelNames: [String]
    let ringNames: [String]
    let hasLEDs: Bool
    /// Two touch rings with their own modes and lights (Cintiq 24HD).
    let hasTwoTouchRings: Bool
    var decoder: DeviceDecoder
    var touchDecoder: DeviceDecoder?
    /// Uses per control, and what happened on the Mac meanwhile.
    var seen: [String: Int] = [:]
    var effects: [String: [String]] = [:]
    var held: Set<String> = []
    var lastButtons: [Bool] = []
    var lastRingButtons: [Bool] = []
    var lastRings: [Int?] = []
    var lastStrips: [Int?] = []
    /// Directions seen per ring or strip, so "both ways" can tick.
    var directions: [String: Set<Int>] = [:]
    var penReports = 0
    var touchReports = 0
    var foreignWhilePen = 0
    var foreignWhileTouch = 0
    var foreignSources: Set<String> = []
    var lightsAnswer: Bool?
    /// Per side, whether only that side's light moved when its mode changed.
    var lightAloneAnswers: [String: Bool] = [:]
    var linkLost = false
    var penReportsSinceRelink = 0
    /// Optional, since nobody can be sure of making the link drop: "worked"
    /// once the pen drives the cursor again after one.
    var reconnect: String?
    /// The receiver's raw status bytes (report 0x80, byte 1) and how often
    /// each arrived, to learn what it sends when the tablet goes away.
    var receiverStatus: [String: Int] = [:]

    /// `receiverSpec` is the wireless receiver's row: its decoder reads the
    /// relayed reports against the paired tablet's ranges, as MockTab does.
    init(spec: TabletSpec, pid: Int, receiver: Int? = nil, receiverSpec: TabletSpec? = nil) {
        self.pid = pid
        self.receiver = receiver
        if let receiverSpec {
            name = "\(spec.name) via \(receiverSpec.name)"
            decoder = receiverSpec.makeDecoder()
            decoder.digitizer = spec.digitizerSpec
        } else {
            name = spec.name
            decoder = spec.makeDecoder()
        }
        // The 24HD's pad is two eight-key columns, whatever buttonCount says;
        // MockTab's Buttons pane lays it out the same way.
        if spec.format == .cintiqV1 && spec.hasDualRings {
            keyNames = (1...8).map { "left key \($0)" } + (1...8).map { "right key \($0)" }
        } else {
            keyNames = (0..<spec.buttonCount).map { "key \($0 + 1)" }
        }
        bezelNames = spec.bezelButtonCount == 3
            ? ["bezel left", "bezel middle", "bezel right"]
            : (0..<spec.bezelButtonCount).map { "bezel button \($0 + 1)" }
        let rings = spec.hasDualRings ? 2 : (spec.hasTouchRing || spec.hasMechanicalDial ? 1 : 0)
        ringNames = rings == 2 ? ["left ring", "right ring"] : ["ring"]
        var c = keyNames + bezelNames
        for ring in ringNames.prefix(rings) {
            c.append("\(ring), both ways")
            if !spec.hasMechanicalDial && !spec.hasDualRings { c.append("\(ring) center") }
        }
        if spec.hasTouchStrips { c += ["left strip, both ways", "right strip, both ways"] }
        if spec.maxX > 0 { c.append("pen") }
        if spec.hasFingerTouch { c.append("touch") }
        controls = c
        hasLEDs = spec.ledCompanionPID != nil
        hasTwoTouchRings = spec.hasDualRings && !spec.hasMechanicalDial
        if let sensor = spec.touchCompanionPID, separateTouchSensors.contains(sensor) {
            touchDecoder = DeviceDecoder.fixedLayoutTouch(
                productID: sensor, digitizer: spec.digitizerSpec, family: spec.family)?.decoder
        }
    }

    var complete: Bool { controls.allSatisfy { seen[$0] != nil } }
    var touched: Bool { !seen.isEmpty }

    func buttonName(_ i: Int) -> String {
        if i < keyNames.count { return keyNames[i] }
        let b = i - keyNames.count
        return b < bezelNames.count ? bezelNames[b] : "extra button \(i + 1)"
    }
}

var tablets: [Int: Tablet] = [:]
/// Touch sensor product ID → the tablet it belongs to.
var sensorOwner: [Int: Int] = [:]
var leaks: [String] = []
var mocktabErrors: [String] = []

// What happens on the Mac is credited to every control held, or used in the
// last moment (rings and strips have no press, so each step counts as one).
var recent: [(tablet: Tablet, control: String, until: Double)] = []
let afterRelease = 0.3
var penActiveUntil = 0.0
var touchActiveUntil = 0.0

func showRemaining(_ t: Tablet) {
    let left = t.controls.filter { t.seen[$0] == nil }
    if left.isEmpty { say("  \(t.name): all done"); return }
    say(left.count <= 4 ? "  Left: " + left.joined(separator: "; ") : "  \(left.count) left")
}

/// Ticks a control, if it's on the checklist, and credits it with what
/// happens on the Mac while it's held or just after.
func use(_ t: Tablet, _ control: String, held isHeld: Bool = false) {
    if isHeld { t.held.insert(control) } else { recent.append((t, control, now() + afterRelease)) }
    guard t.controls.contains(control) else { return }
    let first = t.seen[control] == nil
    t.seen[control, default: 0] += 1
    if first {
        say("  ✓ \(t.name): \(control)")
        showRemaining(t)
    }
}

func release(_ t: Tablet, _ control: String) {
    t.held.remove(control)
    recent.append((t, control, now() + afterRelease))
}

func moved(_ t: Tablet, _ name: String, direction: Int) {
    guard direction != 0 else { return }
    t.directions[name, default: []].insert(direction > 0 ? 1 : -1)
    // Credit effects while it moves, before both ways are seen.
    recent.append((t, "\(name), both ways", now() + afterRelease))
    if t.directions[name]!.count == 2 { use(t, "\(name), both ways") }
}

var allUpAt: Double? = nil

func handle(_ t: Tablet, _ pad: PadState) {
    let hadHeld = !t.held.isEmpty
    for (i, down) in pad.buttons.enumerated() {
        let was = i < t.lastButtons.count ? t.lastButtons[i] : false
        let name = t.buttonName(i)
        if (down && !was) || pad.pressedThisReport.contains(i) { use(t, name, held: true) }
        if !down && was { release(t, name) }
    }
    t.lastButtons = pad.buttons

    // A ring missing from the report is idle, as MockTab reads it: a
    // receiver's decoder lists a ring only while it's in use.
    let idleRing = RingState(position: nil, buttonDown: false)
    let rings = t.ringNames.indices.map { $0 < pad.rings.count ? pad.rings[$0] : idleRing }
    for (i, ring) in rings.enumerated() {
        let name = t.ringNames[i]
        let wasDown = i < t.lastRingButtons.count ? t.lastRingButtons[i] : false
        if ring.buttonDown && !wasDown { use(t, "\(name) center", held: true) }
        if !ring.buttonDown && wasDown { release(t, "\(name) center") }
        // Positions wrap at 72 (5° steps); take the short way round.
        if let p = ring.position, i < t.lastRings.count, let q = t.lastRings[i], p != q {
            var d = (p - q) % 72
            if d > 36 { d -= 72 } else if d < -36 { d += 72 }
            moved(t, name, direction: d)
        }
    }
    t.lastRingButtons = rings.map(\.buttonDown)
    t.lastRings = rings.map(\.position)

    let strips = (0..<2).map { $0 < pad.strips.count ? pad.strips[$0] : StripState(position: nil) }
    for (i, strip) in strips.enumerated() {
        let name = i == 0 ? "left strip" : "right strip"
        if let p = strip.position, i < t.lastStrips.count, let q = t.lastStrips[i], p != q {
            moved(t, name, direction: p - q)
        }
    }
    t.lastStrips = strips.map(\.position)

    // Start the leak check when the last held control comes up.
    if hadHeld && t.held.isEmpty { allUpAt = now() } else if !t.held.isEmpty { allUpAt = nil }
}

func handlePen(_ t: Tablet, _ point: TabletPoint) {
    guard point.inProximity else { return }
    penActiveUntil = now() + 0.1
    t.penReports += 1
    // A short hover that MockTab turns into cursor movement is enough; the
    // check for movement from elsewhere runs the whole time.
    if t.seen["pen"] == nil, t.penReports >= 60, now() - lastMockTabPointerAt < 0.2 { use(t, "pen") }
    if t.linkLost {
        t.penReportsSinceRelink += 1
        if t.penReportsSinceRelink >= 30, now() - lastMockTabPointerAt < 0.2 {
            t.linkLost = false
            t.reconnect = "worked"
            say("  ✓ \(t.name): picked up again after the link dropped")
        }
    }
}

var lastMockTabPointerAt = 0.0

func handleTouch(_ t: Tablet, contacts: Int) {
    guard contacts > 0 else {
        if t.held.contains("touch") { release(t, "touch") }
        return
    }
    touchActiveUntil = now() + 0.1
    t.touchReports += 1
    if t.touchReports == 1 { t.held.insert("touch") }
    if t.touchReports == 30 { use(t, "touch", held: true) }
}

// MARK: Reports

/// Wireless receivers waiting to say which tablet they're paired with.
var receivers: [Int: DonglePairingWatcher] = [:]
var receiversSeenAt: [Int: Double] = [:]
/// Receivers whose tablet already passed, so they're announced once.
var finishedReceivers: Set<Int> = []

func tablet(for pid: Int) -> Tablet? {
    if let t = tablets[pid] { return t }
    guard !isDone(pid), let spec = WacomDeviceRegistry.spec(for: pid) else { return nil }
    // A receiver's own row has no surface; its tablet comes from pairing.
    if spec.maxX == 0 && spec.buttonCount == 0 && !separateTouchSensors.contains(pid)
        && !sensorOwner.keys.contains(pid) && !finishedReceivers.contains(pid) {
        if receivers[pid] == nil { receivers[pid] = DonglePairingWatcher(); receiversSeenAt[pid] = now() }
        return nil
    }
    let t = Tablet(spec: spec, pid: pid)
    guard !t.controls.isEmpty else { return nil }
    tablets[pid] = t
    if let sensor = spec.touchCompanionPID { sensorOwner[sensor] = pid }
    return t
}

let reportCallback: IOHIDReportCallback = { _, _, sender, _, _, report, length in
    guard let sender else { return }
    let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
    let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
    let bytes = Array(UnsafeBufferPointer(start: report, count: length))

    if let owner = sensorOwner[pid], let t = tablets[owner] {
        guard var touchDecoder = t.touchDecoder else { return }
        let events = HIDReport.withReport(bytes) { touchDecoder.events($0) }
        t.touchDecoder = touchDecoder
        for case .touch(let frame) in events { handleTouch(t, contacts: frame.contacts.count) }
        return
    }
    if var watcher = receivers[pid], tablets[pid] == nil {
        let paired = HIDReport.withReport(bytes) { watcher.observe($0) }
        receivers[pid] = watcher
        guard let paired, let pairedSpec = WacomDeviceRegistry.spec(for: paired),
              let receiverSpec = WacomDeviceRegistry.spec(for: pid) else { return }
        if isDone(paired, via: pid) {
            say("  \(pairedSpec.name) via \(receiverSpec.name): already done")
            receivers[pid] = nil
            finishedReceivers.insert(pid)
            if tablets.isEmpty && receivers.isEmpty { exit(0) }
            return
        }
        let t = Tablet(spec: pairedSpec, pid: paired, receiver: pid, receiverSpec: receiverSpec)
        tablets[pid] = t
        say("  \(t.name): \(t.controls.count) controls")
        return
    }
    guard let t = tablet(for: pid) else { return }
    if t.receiver != nil, bytes.count >= 2, bytes[0] == 0x80 {
        t.receiverStatus[String(format: "0x%02x", bytes[1]), default: 0] += 1
    }
    let events = HIDReport.withReport(bytes) { t.decoder.events($0) }
    for event in events {
        switch event {
        case .pad(let pad): handle(t, pad)
        case .dial(let index, let delta) where index < t.ringNames.count:
            moved(t, t.ringNames[index], direction: delta)
        case .pen(let point): handlePen(t, point)
        case .touch(let frame): handleTouch(t, contacts: frame.contacts.count)
        case .device(let d) where d.kind == .wireless:
            if case .lost? = d.wireless, t.receiver != nil, !t.linkLost {
                t.linkLost = true
                t.penReportsSinceRelink = 0
                t.reconnect = "dropped, not back yet"
                say("  \(t.name): link dropped; turn it back on and hover the pen")
            }
        default: break
        }
    }
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x056A] as CFDictionary)
IOHIDManagerRegisterInputReportCallback(manager, reportCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    say("Can't read the tablet. Give your terminal Input Monitoring in System Settings.")
    exit(1)
}

// List what's connected once devices have matched, and claim each tablet's
// touch sensor before its first report arrives.
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
    var names: [Int: String] = [:]
    for d in devices {
        let pid = (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        guard let spec = WacomDeviceRegistry.spec(for: pid) else { continue }
        if isDone(pid) {
            names[pid] = "\(spec.name): already done"
        } else if let t = tablet(for: pid) {
            names[pid] = "\(t.name): \(t.controls.count) controls"
        } else if receivers[pid] != nil, tablets[pid] == nil {
            names[pid] = "\(spec.name): waiting to learn which tablet is paired"
        }
    }
    if names.isEmpty {
        say("No Wacom tablet with controls connected.")
        exit(1)
    }
    for n in names.values.sorted() { say("  " + n) }
    if names.keys.allSatisfy({ isDone($0) }) { exit(0) }
}

// MARK: MockTab's errors

let logStream = Process()
logStream.executableURL = URL(fileURLWithPath: "/usr/bin/log")
logStream.arguments = ["stream", "--style", "compact", "--predicate",
                       "subsystem == \"com.cyzor.mocktab\" AND (messageType == error OR messageType == fault)"]
let logPipe = Pipe()
logStream.standardOutput = logPipe
logStream.standardError = FileHandle.nullDevice
logPipe.fileHandleForReading.readabilityHandler = { h in
    guard let text = String(data: h.availableData, encoding: .utf8) else { return }
    let lines = text.split(separator: "\n").map(String.init).filter { $0.contains("MockTab") }
    DispatchQueue.main.async { mocktabErrors += lines }
}
try? logStream.run()

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
    var targets: [(Tablet, String)] = []
    for tab in tablets.values { targets += tab.held.map { (tab, $0) } }
    targets += recent.filter { $0.until >= t }.map { ($0.tablet, $0.control) }
    for (tab, c) in targets where tab.controls.contains(c) && !(tab.effects[c] ?? []).contains(effect) {
        tab.effects[c, default: []].append(effect)
    }
}

let pointerTypes: Set<CGEventType> = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]

func sourceName(_ pid: Int64) -> String {
    pid == 0 ? "a pointing device" : NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName ?? "pid \(pid)"
}

var globalTap: CFMachPort?
let tapCallback: CGEventTapCallBack = { _, type, e, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = globalTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(e)
    }
    let source = e.getIntegerValueField(.eventSourceUnixProcessID)
    if source == mocktabPID, type == .mouseMoved || type == .leftMouseDragged,
       e.getIntegerValueField(.mouseEventSubtype) == 1 {
        lastMockTabPointerAt = now()
    }
    if pointerTypes.contains(type), source != mocktabPID {
        let t = now()
        for tab in tablets.values {
            if t < penActiveUntil && tab.penReports > 0 { tab.foreignWhilePen += 1 }
            if t < touchActiveUntil && tab.touchReports > 0 { tab.foreignWhileTouch += 1 }
            if t < penActiveUntil || t < touchActiveUntil { tab.foreignSources.insert(sourceName(source)) }
        }
    }
    // Only MockTab's events count; anything else is the keyboard or mouse.
    if source == mocktabPID, let d = describe(type, e) { note(d) }
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

/// A handful of stray events is a bumped mouse; a stream is a second driver.
let foreignThreshold = 10

struct TabletResult: Codable {
    var name: String
    var complete: Bool
    var controls: [String: [String]]
    var unused: [String]
    var cursorEventsFromElsewhereWhilePen: Int
    var cursorEventsFromElsewhereWhileTouch: Int
    var ringLightsFollowed: Bool?
    var ringLightMovedAlone: [String: Bool]?
    var reconnect: String?
    var receiverStatus: [String: Int]?
}

struct Result: Codable {
    var label: String
    var tablet: TabletResult
    var leaks: [String]
    var mocktabErrors: [String]
}

@Sendable func problemsFound(_ t: Tablet) -> [String] {
    var p: [String] = []
    if !t.complete { p.append("not every control was used") }
    if t.foreignWhilePen >= foreignThreshold {
        p.append("\(t.foreignWhilePen) cursor events came from \(t.foreignSources.sorted().joined(separator: ", ")) while the pen was in range, so MockTab doesn't hold the pen alone")
    }
    if t.foreignWhileTouch >= foreignThreshold {
        p.append("\(t.foreignWhileTouch) cursor events came from \(t.foreignSources.sorted().joined(separator: ", ")) while a finger was down, so MockTab doesn't hold touch alone")
    }
    if t.lightsAnswer == false { p.append("the ring lights didn't follow the mode buttons") }
    for (side, alone) in t.lightAloneAnswers.sorted(by: { $0.key < $1.key }) where !alone {
        p.append("changing the \(side) ring's mode didn't move its light alone")
    }
    if t.reconnect == "dropped, not back yet" { p.append("the tablet didn't come back after the link dropped") }
    return p
}

func finish() -> Never {
    logStream.terminate()
    let used = tablets.values.filter(\.touched).sorted { $0.name < $1.name }

    // Ring lights are output reports, which nothing here can see.
    for t in used where t.hasLEDs {
        print("  \(t.name): did the ring lights move with the ring mode buttons? [y/n] ", terminator: "")
        fflush(stdout)
        t.lightsAnswer = (readLine() ?? "").lowercased().hasPrefix("y")
    }
    // Each ring has its own modes; bind a key per side to cycle that ring.
    for t in used where t.hasLEDs && t.hasTwoTouchRings {
        for side in ["left", "right"] {
            print("  \(t.name): when the \(side) ring's mode changed, did only the \(side) light move? [y/n] ", terminator: "")
            fflush(stdout)
            t.lightAloneAnswers[side] = (readLine() ?? "").lowercased().hasPrefix("y")
        }
    }

    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    var ok = !used.isEmpty && leaks.isEmpty && mocktabErrors.isEmpty
    for t in used {
        let result = Result(
            label: label,
            tablet: TabletResult(
                name: t.name, complete: t.complete,
                controls: Dictionary(uniqueKeysWithValues: t.controls.compactMap { c in
                    t.seen[c] == nil ? nil : (c, t.effects[c] ?? [])
                }),
                unused: t.controls.filter { t.seen[$0] == nil },
                cursorEventsFromElsewhereWhilePen: t.foreignWhilePen,
                cursorEventsFromElsewhereWhileTouch: t.foreignWhileTouch,
                ringLightsFollowed: t.lightsAnswer,
                ringLightMovedAlone: t.lightAloneAnswers.isEmpty ? nil : t.lightAloneAnswers,
                reconnect: t.receiver == nil ? nil : (t.reconnect ?? "not tried"),
                receiverStatus: t.receiver == nil ? nil : t.receiverStatus),
            leaks: leaks, mocktabErrors: mocktabErrors)
        FileManager.default.createFile(atPath: resultPath(t.pid, via: t.receiver), contents: try! enc.encode(result))

        say("")
        say("  \(t.name)")
        for c in t.controls {
            let effects = t.effects[c] ?? []
            let what = t.seen[c] == nil ? "not used"
                : effects.isEmpty ? "nothing visible (fine for a mode or pen action)" : effects.joined(separator: ", ")
            say("    " + c.padding(toLength: 24, withPad: " ", startingAt: 0) + what)
        }
        if t.receiver != nil {
            say("    " + "reconnect".padding(toLength: 24, withPad: " ", startingAt: 0) + (t.reconnect ?? "not tried (optional)"))
            let status = t.receiverStatus.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }
            say("    " + "receiver status".padding(toLength: 24, withPad: " ", startingAt: 0)
                + (status.isEmpty ? "none received" : status.joined(separator: ", ")))
        }
        for p in problemsFound(t) { say("    ✗ " + p); ok = false }
    }
    say("")
    if !leaks.isEmpty { say("  ✗ A modifier stayed held after every control was up: " + leaks.joined(separator: ", ")) }
    if !mocktabErrors.isEmpty {
        say("  ✗ MockTab logged \(mocktabErrors.count) error(s):")
        for line in mocktabErrors.prefix(10) { say("    " + line) }
    }
    say(ok ? "  Done. Check the list matches your settings." : "  Done, with problems above.")
    exit(ok ? 0 : 2)
}

var finishAt: Double? = nil
Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    let t = now()
    recent.removeAll { $0.until < t }
    for (pid, seenAt) in receiversSeenAt where tablets[pid] == nil && receivers[pid] != nil && t - seenAt > 8 {
        receiversSeenAt[pid] = .infinity
        say("  The wireless receiver hasn't named its tablet yet. Turn the tablet off and on.")
    }
    // A finger lifted without a final empty frame still counts as lifted.
    if t > touchActiveUntil + 0.3 {
        for tab in tablets.values where tab.held.contains("touch") { release(tab, "touch") }
    }
    let anyHeld = tablets.values.contains { !$0.held.subtracting(["touch"]).isEmpty }
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
    // Finish a moment after the last control on every tablet in use.
    let used = tablets.values.filter(\.touched)
    if finishAt == nil, !used.isEmpty, used.allSatisfy(\.complete), !anyHeld { finishAt = t + 0.8 }
    if let f = finishAt, t >= f { finish() }
}

let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { finish() }
sigint.resume()
signal(SIGINT, SIG_IGN)

say("Wacom tablet controls, \(label)")
say("  Press every key and bezel button and each ring's center, turn each ring and")
say("  slide each strip both ways, hover the pen, and touch the surface if it has")
say("  touch. On a wireless receiver you may also turn the tablet off and on;")
say("  that part is optional.")
say("  Any order. Keep your hands off the keyboard and mouse.")
say("  Control-C stops early.")
CFRunLoopRun()
