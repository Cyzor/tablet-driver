// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Passive CGEvent tap that dumps every field of mouse-button events, so a
// real USB mouse and MockTab's synthetic pen events can be compared payload
// for payload in the same session.
//
// Built to answer one question the iWork click-state trilemma note leaves
// open: what does a *working* double-click into a Pages header actually look
// like at the CGEvent layer? The note eliminates subtype, pressure/tilt,
// proximity wrapping, and move suppression by experiment, but never compared
// against real hardware — so "Pages requires clickState=1" is inference, not
// measurement. This measures it.
//
// Listen-only: never modifies, swallows, or delays an event.

import AppKit
import ApplicationServices
import Foundation

// MARK: - Options

let args = CommandLine.arguments
let wantsAX = !args.contains("--no-ax")
let onlyFrontApp: String? = args.firstIndex(of: "--app").flatMap {
    $0 + 1 < args.count ? args[$0 + 1] : nil
}

if args.contains("-h") || args.contains("--help") {
    print("""
    Usage: pages-click-probe [--app <name>] [--no-ax]

      --app <name>   Only log clicks while this app is frontmost
                     (substring match, case-insensitive). e.g. --app Pages
      --no-ax        Skip the accessibility hit-test under the cursor.

    Logs every mouse-button event with all CGEvent fields. Ctrl-C to stop.
    """)
    exit(0)
}

// MARK: - Field tables

// Split by value type — reading a double field with the integer getter (or the
// reverse) silently returns garbage rather than failing.
let intFields: [(String, CGEventField)] = [
    ("mouseEventNumber", .mouseEventNumber),
    ("mouseEventClickState", .mouseEventClickState),
    ("mouseEventButtonNumber", .mouseEventButtonNumber),
    ("mouseEventSubtype", .mouseEventSubtype),
    ("mouseEventInstantMouser", .mouseEventInstantMouser),
    ("tabletEventPointButtons", .tabletEventPointButtons),
    ("tabletEventDeviceID", .tabletEventDeviceID),
    ("tabletEventVendor1", .tabletEventVendor1),
    ("tabletEventVendor2", .tabletEventVendor2),
    ("tabletEventVendor3", .tabletEventVendor3),
    ("eventSourceUnixProcessID", .eventSourceUnixProcessID),
    ("eventSourceUserData", .eventSourceUserData),
    ("eventSourceUserID", .eventSourceUserID),
    ("eventSourceGroupID", .eventSourceGroupID),
    ("eventSourceStateID", .eventSourceStateID),
    ("eventTargetUnixProcessID", .eventTargetUnixProcessID),
]

let doubleFields: [(String, CGEventField)] = [
    ("mouseEventPressure", .mouseEventPressure),
    ("mouseEventDeltaX", .mouseEventDeltaX),
    ("mouseEventDeltaY", .mouseEventDeltaY),
    ("tabletEventPointPressure", .tabletEventPointPressure),
    ("tabletEventTiltX", .tabletEventTiltX),
    ("tabletEventTiltY", .tabletEventTiltY),
    ("tabletEventRotation", .tabletEventRotation),
    ("tabletEventTangentialPressure", .tabletEventTangentialPressure),
]

func typeName(_ t: CGEventType) -> String {
    switch t {
    case .leftMouseDown: return "leftMouseDown"
    case .leftMouseUp: return "leftMouseUp"
    case .rightMouseDown: return "rightMouseDown"
    case .rightMouseUp: return "rightMouseUp"
    case .otherMouseDown: return "otherMouseDown"
    case .otherMouseUp: return "otherMouseUp"
    default: return "type(\(t.rawValue))"
    }
}

/// `.privateState` is what MockTab injects from; `.hidSystemState` is real
/// hardware. This is the field the trilemma note never varied, and the reason
/// this probe exists.
///
/// Values are from `CGEventTypes.h`: private is **-1**, combined-session **0**,
/// HID-system **1**. A source created with `.privateState` does not report -1
/// though — it reports a unique runtime ID (a large positive number), so
/// anything unrecognized here is a private source, which in practice means a
/// userspace injector like us.
func sourceStateName(_ v: Int64) -> String {
    switch v {
    case -1: return "privateState(-1) — synthetic"
    case 0: return "combinedSessionState(0)"
    case 1: return "hidSystemState(1) — hardware"
    default: return "privateState id \(v) — synthetic (userspace injector)"
    }
}

// MARK: - Context helpers

func frontmostAppName() -> String {
    NSWorkspace.shared.frontmostApplication?.localizedName ?? "(unknown)"
}

let systemWide = AXUIElementCreateSystemWide()

/// Role/subrole of the AX element under the cursor.
///
/// Doubles as a live check on the "discriminate by region" idea: if Pages
/// reports a distinct role or subrole over a header/footer versus body text,
/// the click-state rule could be made positional instead of global, and the
/// trilemma dissolves. Timeout is deliberately short — a busy Pages must not
/// stall the tap.
func axDescription(at point: CGPoint) -> String {
    guard wantsAX else { return "-" }
    AXUIElementSetMessagingTimeout(systemWide, 0.05)
    var element: AXUIElement?
    let err = AXUIElementCopyElementAtPosition(
        systemWide, Float(point.x), Float(point.y), &element)
    guard err == .success, let element else { return "ax:err(\(err.rawValue))" }

    func attr(_ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return (value as? String)
    }
    var parts: [String] = []
    if let r = attr(kAXRoleAttribute as String) { parts.append(r) }
    if let s = attr(kAXSubroleAttribute as String) { parts.append(s) }
    if let d = attr(kAXDescriptionAttribute as String), !d.isEmpty { parts.append("“\(d)”") }
    return parts.isEmpty ? "(no role)" : parts.joined(separator: " / ")
}

// MARK: - Logging

var eventIndex = 0
let started = Date()

func log(_ type: CGEventType, _ event: CGEvent) {
    let front = frontmostAppName()
    if let want = onlyFrontApp,
        front.range(of: want, options: .caseInsensitive) == nil
    { return }

    eventIndex += 1
    let loc = event.location
    let stateID = event.getIntegerValueField(.eventSourceStateID)

    print("")
    print(String(repeating: "─", count: 78))
    print(String(
        format: "#%d  %@  t=+%.3fs  at (%.1f, %.1f)",
        eventIndex, typeName(type), Date().timeIntervalSince(started), loc.x, loc.y))
    print("  frontmost      : \(front)")
    print("  sourceStateID  : \(sourceStateName(stateID))")
    print("  flags          : 0x\(String(event.flags.rawValue, radix: 16))")
    print("  under cursor   : \(axDescription(at: loc))")
    print("  ── integer fields ──")
    for (name, field) in intFields {
        let v = event.getIntegerValueField(field)
        // clickState is the whole point; never let it hide among the zeros.
        let mark = (field == .mouseEventClickState) ? "  ← clickState" : ""
        if v != 0 || field == .mouseEventClickState || field == .mouseEventSubtype {
            print(String(format: "    %-28@ %d%@", name as NSString, v, mark))
        }
    }
    print("  ── double fields (nonzero only) ──")
    var anyDouble = false
    for (name, field) in doubleFields {
        let v = event.getDoubleValueField(field)
        if v != 0 {
            print(String(format: "    %-28@ %.4f", name as NSString, v))
            anyDouble = true
        }
    }
    if !anyDouble { print("    (all zero)") }
    fflush(stdout)
}

// MARK: - Tap

let mask: CGEventMask =
    (1 << CGEventType.leftMouseDown.rawValue)
    | (1 << CGEventType.leftMouseUp.rawValue)
    | (1 << CGEventType.rightMouseDown.rawValue)
    | (1 << CGEventType.rightMouseUp.rawValue)
    | (1 << CGEventType.otherMouseDown.rawValue)
    | (1 << CGEventType.otherMouseUp.rawValue)

let callback: CGEventTapCallBack = { _, type, event, _ in
    // A tap disabled by timeout stays dead until re-enabled; without this the
    // probe goes silent partway through a session and looks like "no events."
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = globalTap { CGEvent.tapEnable(tap: tap, enable: true) }
        FileHandle.standardError.write(Data("[probe] tap re-enabled\n".utf8))
        return Unmanaged.passUnretained(event)
    }
    log(type, event)
    return Unmanaged.passUnretained(event)
}

var globalTap: CFMachPort?

guard
    let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: callback,
        userInfo: nil)
else {
    FileHandle.standardError.write(Data("""
        [probe] Could not create the event tap.

        This needs Accessibility permission for the program running it — that is
        your terminal, not this binary. Grant it in:
          System Settings → Privacy & Security → Accessibility
        add/enable Terminal (or iTerm), then run again.

        """.utf8))
    exit(1)
}
globalTap = tap

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

print("""
pages-click-probe — listening for mouse-button events. Ctrl-C to stop.
\(onlyFrontApp.map { "Filtered to frontmost app matching: \($0)" } ?? "Logging clicks in every app.")
Accessibility hit-test: \(wantsAX ? "on" : "off")

Look for `sourceStateID`: 1 = hardware, a large id = synthetic (userspace),
and compare `mouseEventClickState` between them on the same interaction.
""")
fflush(stdout)

CFRunLoopRun()
