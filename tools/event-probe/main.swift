// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Passive CGEvent tap that records every event of every type, with every
// nonzero field slot (documented or not), as JSON lines. Pair a capture of a
// working source (hardware, Wacom's driver, a trackpad) with one of MockTab
// doing the same thing, then run compare.py to see which fields differ.
//
// This is how the iWork click fix and the Photoshop rotation fix were found:
// both "platform limits" turned out to be fields we never sent.
//
// Listen-only: never modifies, swallows, or delays an event.

import AppKit
import Foundation

let args = CommandLine.arguments

func option(_ name: String) -> String? {
    args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

if args.contains("-h") || args.contains("--help") {
    print("""
    Usage: event-probe [--out FILE] [--app NAME] [--skip TYPES] [--raw]

      --out FILE    Write JSON lines here (default: stdout).
      --app NAME    Only record while the frontmost app matches (substring).
      --skip TYPES  Comma-separated type numbers to ignore, e.g. 5 for mouseMoved.
      --raw         Also store each event's full serialized blob (base64).

    Then: compare.py mocktab.jsonl reference.jsonl
    Needs Accessibility permission for the terminal. Ctrl-C to stop.
    """)
    exit(0)
}

let onlyApp = option("--app")
let skipTypes = Set((option("--skip") ?? "").split(separator: ",").compactMap { UInt32($0) })
let wantsRaw = args.contains("--raw")
let out: FileHandle = {
    guard let path = option("--out") else { return .standardOutput }
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)!
}()

// Field slots are sparse and partly undocumented (gesture data, for one,
// lives in unnamed slots). Scanning the whole range catches them; 0–255
// covers every slot seen in practice.
let fieldRange: ClosedRange<UInt32> = 0...255

/// Fields whose values are doubles. Everything else is read as an integer;
/// reading a double slot with the integer getter returns a truncated value.
let doubleSlots: Set<UInt32> = [
    CGEventField.mouseEventPressure, .tabletEventPointPressure, .tabletEventTiltX,
    .tabletEventTiltY, .tabletEventRotation, .tabletEventTangentialPressure,
    .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
    .scrollWheelEventFixedPtDeltaAxis3,
].reduce(into: Set<UInt32>()) { $0.insert($1.rawValue) }

let names: [UInt32: String] = {
    let known: [(String, CGEventField)] = [
        ("mouseEventNumber", .mouseEventNumber), ("mouseEventClickState", .mouseEventClickState),
        ("mouseEventPressure", .mouseEventPressure), ("mouseEventButtonNumber", .mouseEventButtonNumber),
        ("mouseEventDeltaX", .mouseEventDeltaX), ("mouseEventDeltaY", .mouseEventDeltaY),
        ("mouseEventInstantMouser", .mouseEventInstantMouser), ("mouseEventSubtype", .mouseEventSubtype),
        ("keyboardEventAutorepeat", .keyboardEventAutorepeat), ("keyboardEventKeycode", .keyboardEventKeycode),
        ("keyboardEventKeyboardType", .keyboardEventKeyboardType),
        ("scrollDeltaAxis1", .scrollWheelEventDeltaAxis1), ("scrollDeltaAxis2", .scrollWheelEventDeltaAxis2),
        ("scrollFixedPtDeltaAxis1", .scrollWheelEventFixedPtDeltaAxis1),
        ("scrollFixedPtDeltaAxis2", .scrollWheelEventFixedPtDeltaAxis2),
        ("scrollPointDeltaAxis1", .scrollWheelEventPointDeltaAxis1),
        ("scrollPointDeltaAxis2", .scrollWheelEventPointDeltaAxis2),
        ("scrollInstantMouser", .scrollWheelEventInstantMouser),
        ("scrollIsContinuous", .scrollWheelEventIsContinuous),
        ("scrollPhase", .scrollWheelEventScrollPhase), ("scrollCount", .scrollWheelEventScrollCount),
        ("scrollMomentumPhase", .scrollWheelEventMomentumPhase),
        ("tabletPointX", .tabletEventPointX), ("tabletPointY", .tabletEventPointY),
        ("tabletPointZ", .tabletEventPointZ), ("tabletPointButtons", .tabletEventPointButtons),
        ("tabletPointPressure", .tabletEventPointPressure), ("tabletTiltX", .tabletEventTiltX),
        ("tabletTiltY", .tabletEventTiltY), ("tabletRotation", .tabletEventRotation),
        ("tabletTangentialPressure", .tabletEventTangentialPressure),
        ("tabletDeviceID", .tabletEventDeviceID), ("tabletVendor1", .tabletEventVendor1),
        ("tabletVendor2", .tabletEventVendor2), ("tabletVendor3", .tabletEventVendor3),
        ("proxVendorID", .tabletProximityEventVendorID), ("proxTabletID", .tabletProximityEventTabletID),
        ("proxPointerID", .tabletProximityEventPointerID), ("proxDeviceID", .tabletProximityEventDeviceID),
        ("proxSystemTabletID", .tabletProximityEventSystemTabletID),
        ("proxVendorPointerType", .tabletProximityEventVendorPointerType),
        ("proxPointerSerial", .tabletProximityEventVendorPointerSerialNumber),
        ("proxVendorUniqueID", .tabletProximityEventVendorUniqueID),
        ("proxCapabilityMask", .tabletProximityEventCapabilityMask),
        ("proxPointerType", .tabletProximityEventPointerType),
        ("proxEnterProximity", .tabletProximityEventEnterProximity),
        ("eventTargetProcessSerialNumber", .eventTargetProcessSerialNumber),
        ("eventTargetUnixProcessID", .eventTargetUnixProcessID),
        ("eventSourceUnixProcessID", .eventSourceUnixProcessID),
        ("eventSourceUserData", .eventSourceUserData), ("eventSourceUserID", .eventSourceUserID),
        ("eventSourceGroupID", .eventSourceGroupID), ("eventSourceStateID", .eventSourceStateID),
    ]
    return Dictionary(known.map { ($1.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
}()

var processNames: [Int64: String] = [:]

func processName(_ pid: Int64) -> String {
    if let n = processNames[pid] { return n }
    let n = NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName
        ?? (pid == 0 ? "kernel/hardware" : "pid \(pid)")
    processNames[pid] = n
    return n
}

let started = Date()

func record(_ type: CGEventType, _ e: CGEvent) {
    if skipTypes.contains(type.rawValue) { return }
    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    if let onlyApp, front.range(of: onlyApp, options: .caseInsensitive) == nil { return }

    var fields: [String: Any] = [:]
    for slot in fieldRange {
        guard let f = CGEventField(rawValue: slot) else { continue }
        let key = names[slot] ?? "f\(slot)"
        if doubleSlots.contains(slot) {
            let v = e.getDoubleValueField(f)
            if v != 0 { fields[key] = v }
        } else {
            let v = e.getIntegerValueField(f)
            if v != 0 { fields[key] = v }
        }
    }
    var entry: [String: Any] = [
        "t": (Date().timeIntervalSince(started) * 1000).rounded() / 1000,
        "type": Int(type.rawValue),
        "x": e.location.x, "y": e.location.y,
        "flags": e.flags.rawValue,
        "front": front,
        "source": processName(e.getIntegerValueField(.eventSourceUnixProcessID)),
        "fields": fields,
    ]
    if wantsRaw, let data = e.data as Data? { entry["raw"] = data.base64EncodedString() }
    if let json = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) {
        out.write(json)
        out.write(Data("\n".utf8))
    }
}

var globalTap: CFMachPort?

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = globalTap { CGEvent.tapEnable(tap: tap, enable: true) }
        FileHandle.standardError.write(Data("[probe] tap re-enabled\n".utf8))
        return Unmanaged.passUnretained(event)
    }
    record(type, event)
    return Unmanaged.passUnretained(event)
}

guard
    let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
        eventsOfInterest: CGEventMask.max, callback: callback, userInfo: nil)
else {
    FileHandle.standardError.write(Data(
        "[probe] Could not create the event tap. Grant Accessibility to your terminal.\n".utf8))
    exit(1)
}
globalTap = tap
CFRunLoopAddSource(
    CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

signal(SIGINT) { _ in exit(0) }
FileHandle.standardError.write(Data("[probe] recording all events. Ctrl-C to stop.\n".utf8))
CFRunLoopRun()
