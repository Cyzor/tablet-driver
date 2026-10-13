// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid
import os
import TabletKit

/// Records every report with the events the driver decoded from it, so the
/// driver's move into TabletKit can be checked against what it does today.
///
/// Temporary, and off unless `defaults write com.cyzor.mocktab traceReports
/// -bool true`. Each launch writes one JSON-lines file to
/// `~/Library/Logs/MockTab/Traces/`. Traces hold pen and hardware serials, so
/// they never go into a repo.
enum ReportTrace {
    nonisolated static let isOn = UserDefaults.standard.bool(forKey: "traceReports")

    private enum Entry: Sendable {
        case line(String)
        case report(id: Int, ns: UInt64, bytes: [UInt8], events: [TabletEvent])
    }

    private struct State {
        var entries: [Entry] = []
        var ids: [ObjectIdentifier: Int] = [:]
        var nextID = 0
    }

    private nonisolated static let state = OSAllocatedUnfairLock(initialState: State())
    private nonisolated static let queue = DispatchQueue(label: "com.cyzor.mocktab.report-trace", qos: .utility)
    private nonisolated(unsafe) static var file: FileHandle?
    private nonisolated(unsafe) static var timer: DispatchSourceTimer?

    /// Starts the once-a-second writer. Call at launch; does nothing when off.
    nonisolated static func start() {
        guard isOn else { return }
        queue.async {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { flush() }
            t.resume()
            timer = t
        }
    }

    /// An interface the system attached, with everything the session will
    /// need to route it.
    nonisolated static func attached(_ interface: IOHIDDevice) {
        guard isOn else { return }
        _ = id(for: interface)
    }

    nonisolated static func detached(_ interface: IOHIDDevice) {
        guard isOn else { return }
        let key = ObjectIdentifier(interface)
        let line = state.withLock { s -> String? in
            guard let id = s.ids.removeValue(forKey: key) else { return nil }
            return json(["kind": "detach", "iface": id, "ns": DispatchTime.now().uptimeNanoseconds])
        }
        if let line { state.withLock { $0.entries.append(.line(line)) } }
    }

    /// One report from `interface`, with the events decoded from it.
    nonisolated static func report(
        _ pointer: UnsafePointer<UInt8>, length: CFIndex, from interface: IOHIDDevice,
        ns: UInt64, events: [TabletEvent]
    ) {
        guard isOn else { return }
        let bytes = Array(UnsafeBufferPointer(start: pointer, count: max(0, length)))
        let id = id(for: interface)
        state.withLock { $0.entries.append(.report(id: id, ns: ns, bytes: bytes, events: events)) }
    }

    /// The interface's number in this trace, recording its attach the first
    /// time it's seen.
    private nonisolated static func id(for interface: IOHIDDevice) -> Int {
        let key = ObjectIdentifier(interface)
        if let known = state.withLock({ $0.ids[key] }) { return known }
        let (id, isNew) = state.withLock { s -> (Int, Bool) in
            if let existing = s.ids[key] { return (existing, false) }
            s.nextID += 1
            s.ids[key] = s.nextID
            return (s.nextID, true)
        }
        guard isNew else { return id }
        func string(_ key: String) -> String { IOHIDDeviceGetProperty(interface, key as CFString) as? String ?? "" }
        let pairs = (IOHIDDeviceGetProperty(interface, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] ?? [])
            .map { [($0[kIOHIDDeviceUsagePageKey] as? Int) ?? 0, ($0[kIOHIDDeviceUsageKey] as? Int) ?? 0] }
        let descriptor = IOHIDDeviceGetProperty(interface, kIOHIDReportDescriptorKey as CFString) as? Data
        let line = json([
            "kind": "attach", "iface": id, "ns": DispatchTime.now().uptimeNanoseconds,
            "vendorID": hidIntProperty(interface, kIOHIDVendorIDKey),
            "productID": hidIntProperty(interface, kIOHIDProductIDKey),
            "usagePage": hidIntProperty(interface, kIOHIDPrimaryUsagePageKey),
            "usage": hidIntProperty(interface, kIOHIDPrimaryUsageKey),
            "usagePairs": pairs,
            "transport": string(kIOHIDTransportKey),
            "product": string(kIOHIDProductKey),
            "serial": string(kIOHIDSerialNumberKey),
            "locationID": hidIntProperty(interface, kIOHIDLocationIDKey),
            "maxInput": hidIntProperty(interface, kIOHIDMaxInputReportSizeKey),
            "maxOutput": hidIntProperty(interface, kIOHIDMaxOutputReportSizeKey),
            "descriptor": descriptor.map { hex(Array($0)) } ?? "",
        ])
        state.withLock { $0.entries.append(.line(line)) }
        return id
    }

    /// A connect-time write or read, or a pairing, in the order it happened.
    nonisolated static func note(_ kind: String, _ fields: [String: Any]) {
        guard isOn else { return }
        var fields = fields
        fields["kind"] = kind
        fields["ns"] = DispatchTime.now().uptimeNanoseconds
        let line = json(fields)
        state.withLock { $0.entries.append(.line(line)) }
    }

    private nonisolated static func flush() {
        let entries = state.withLock { s -> [Entry] in
            let taken = s.entries
            s.entries.removeAll(keepingCapacity: true)
            return taken
        }
        guard !entries.isEmpty, let file = openFile() else { return }
        var text = ""
        for entry in entries {
            switch entry {
            case .line(let line):
                text += line + "\n"
            case .report(let id, let ns, let bytes, let events):
                text += json(["kind": "report", "iface": id, "ns": ns, "bytes": hex(bytes),
                              "events": events.map(describe)]) + "\n"
            }
        }
        file.write(Data(text.utf8))
    }

    private nonisolated static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func openFile() -> FileHandle? {
        if let file { return file }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MockTab/Traces", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let url = dir.appendingPathComponent("trace-\(stamp).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
        return file
    }

    private nonisolated static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // Same text as TabletKit's DecoderGoldenTests, so replay tests can
    // compare event for event.
    private nonisolated static func describe(_ event: TabletEvent) -> String {
        func bits(_ flags: [Bool]) -> String { String(flags.map { $0 ? "1" : "0" }) }
        func fixed(_ d: Double) -> String { String(format: "%.4f", d) }
        switch event {
        case .pen(let p):
            let buttons = bits([p.penButton1, p.penButton2, p.penButton3, p.penButton4, p.penButton5,
                                p.eraser, p.inProximity, p.mouseMiddleButton])
            let airbrush = p.airbrushWheel.map(String.init) ?? "-"
            return "pen \(p.x) \(p.y) \(p.maxX) \(p.maxY) \(p.pressure)/\(p.maxPressure)"
                + " tilt \(fixed(p.tiltX)) \(fixed(p.tiltY)) rot \(fixed(p.rotation)) b \(buttons)"
                + " hover \(p.hoverDistance) wheel \(p.mouseWheelDelta) air \(airbrush)"
        case .tool(let t):
            let id = t.identity
            return "tool \(t.phase == .enter ? "enter" : "leave") serial \(id.serial)"
                + " code \(id.toolCode) eraser \(id.isEraser) mouse \(id.isMouse)"
        case .pad(let pad):
            let rings = pad.rings.map { "\($0.position.map(String.init) ?? "-")/\($0.buttonDown ? 1 : 0)" }
            let strips = pad.strips.map { $0.position.map(String.init) ?? "-" }
            let pressed = pad.pressedThisReport.map(String.init).joined(separator: ",")
            return "pad \(bits(pad.buttons)) pressed [\(pressed)]"
                + " rings [\(rings.joined(separator: " "))] strips [\(strips.joined(separator: " "))]"
                + " mode \(pad.hardwareMode.map(String.init) ?? "-")"
        case .dial(let index, let delta):
            return "dial \(index) \(delta)"
        case .touch(let frame):
            let contacts = frame.contacts.map {
                "\($0.id):\($0.x),\($0.y),\($0.contactArea.map(String.init) ?? "-"),\($0.contactMinor.map(String.init) ?? "-")"
            }
            return "touch t \(frame.deviceTime.map(String.init) ?? "-") [\(contacts.joined(separator: " "))]"
        case .device(let e):
            var text = "device \(e.kind.rawValue)"
            if let b = e.battery { text += " \(b.percent) \(b.charging)" }
            if let w = e.wireless { text += " \(w)" }
            if let slots = e.remotePairing {
                text += " [" + slots.map { "\($0.index):\($0.serial):\($0.connected)" }.joined(separator: " ") + "]"
            }
            if let note = e.unsupportedToolNote { text += " \(note)" }
            if let m = e.mouseButtons { text += " \(m)" }
            return text
        }
    }
}
