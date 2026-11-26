// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import IOKit
import TabletKit
import os
import notify

/// The last few minutes of input-path activity, always kept, so a capture
/// taken after a problem contains it.
///
/// Reports go into a fixed ring written only on HIDThread: one store and an
/// index bump per report, no allocation or lock. State changes, which are
/// rare, go into a small locked log from any thread. Neither holds pen
/// serials, keystrokes, or app names.
final class FlightRecorder: @unchecked Sendable {  // ring: HIDThread writes; events: locked
    static let shared = FlightRecorder()

    /// What MockTab did with a report.
    struct Outcome: OptionSet, Sendable {
        let rawValue: UInt8
        /// The decoder produced a pen point.
        static let decodedPen = Outcome(rawValue: 1 << 0)
        /// That point was in range.
        static let penInRange = Outcome(rawValue: 1 << 1)
        /// A cursor move went out.
        static let postedMove = Outcome(rawValue: 1 << 2)
        /// Another event went out: click, drag, scroll, or proximity.
        static let postedOther = Outcome(rawValue: 1 << 3)
        /// A hover move was skipped as backlog.
        static let staleSkipped = Outcome(rawValue: 1 << 4)
        /// Pan View held the cursor still.
        static let panHeld = Outcome(rawValue: 1 << 5)
        /// The touchdown guard held the sample.
        static let guardHeld = Outcome(rawValue: 1 << 6)
        /// The decoder announced a tool.
        static let toolEnter = Outcome(rawValue: 1 << 7)
    }

    /// One report, 32 bytes.
    struct Report {
        var kernelNs: UInt64 = 0
        /// Kernel receipt to MockTab's callback.
        var callbackUs: UInt32 = 0
        /// Kernel receipt to the end of handling, posts included.
        var doneUs: UInt32 = 0
        var device: UInt8 = 0
        var reportID: UInt8 = 0
        var status: UInt8 = 0
        var outcome: UInt8 = 0
        /// Position in sixteenths of the tablet's range per 65536.
        var x: UInt16 = 0
        var y: UInt16 = 0
        /// Hundredths of full tilt, and hover as the tablet reports it.
        var tiltX: Int8 = 0
        var tiltY: Int8 = 0
        var hover: UInt8 = 0
        /// 1: a weak frame whose position jumped too far, so the pen held its
        /// last position. In the struct's padding; the size stays 32.
        var flags: UInt8 = 0
    }

    /// About 5 minutes of one tablet at 200 Hz; 2 MB.
    static let capacity = 1 << 16

    private let ring: UnsafeMutablePointer<Report>
    // HIDThread-confined.
    private var written: UInt64 = 0
    private var current: Int = -1
    private var deviceIndex: [ObjectIdentifier: UInt8] = [:]

    private struct Event { let ns: UInt64; let text: String }
    private struct Shared {
        var events: [Event] = []
        var eventStart = 0
        var devices: [String] = []
    }
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    static let eventCapacity = 4096

    private let startNs = FlightRecorder.nowNs()

    private init() {
        ring = .allocate(capacity: Self.capacity)
        ring.initialize(repeating: Report(), count: Self.capacity)
    }

    static func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    // MARK: - Reports (HIDThread)

    /// Opens the slot for a report, at callback entry. `ns` is the kernel
    /// receipt time in nanoseconds; 0 when unknown.
    func beginReport(device: ObjectIdentifier, name: @autoclosure () -> String, ns: UInt64, report: HIDReport) {
        let index: UInt8
        if let known = deviceIndex[device] {
            index = known
        } else {
            let label = name()
            index = shared.withLock { s in
                s.devices.append(label)
                return UInt8(truncatingIfNeeded: s.devices.count - 1)
            }
            deviceIndex[device] = index
            note("device \(index) is \(label)")
        }
        let now = Self.nowNs()
        let slot = Int(written & UInt64(Self.capacity - 1))
        var entry = Report()
        entry.kernelNs = ns != 0 ? ns : now
        entry.callbackUs = ns != 0 && now > ns ? UInt32(clamping: (now - ns) / 1000) : 0
        entry.device = index
        if report.count > 0 { entry.reportID = report.pointer[0] }
        if report.count > 1 { entry.status = report.pointer[1] }
        ring[slot] = entry
        written &+= 1
        current = slot
    }

    /// Records what the decoder produced and closes the slot.
    func endReport(events: [TabletEvent]) {
        guard current >= 0 else { return }
        var outcome = Outcome(rawValue: ring[current].outcome)
        for event in events {
            switch event {
            case .pen(let p):
                if !outcome.contains(.decodedPen) {
                    outcome.insert(.decodedPen)
                    // A weak frame counts as out of range here, position kept:
                    // MockTab follows it only while the pen is already in, and
                    // its moves show that.
                    if p.inProximity && !p.weakSignal { outcome.insert(.penInRange) }
                    if p.maxX > 0 { ring[current].x = UInt16(clamping: p.x * 65535 / p.maxX) }
                    if p.maxY > 0 { ring[current].y = UInt16(clamping: p.y * 65535 / p.maxY) }
                    ring[current].tiltX = Int8(clamping: Int((p.tiltX * 100).rounded()))
                    ring[current].tiltY = Int8(clamping: Int((p.tiltY * 100).rounded()))
                    ring[current].hover = UInt8(clamping: p.hoverDistance)
                    if p.weakSignalHeld { ring[current].flags |= 1 }
                }
            case .tool(let t) where t.phase == .enter:
                outcome.insert(.toolEnter)
            default:
                break
            }
        }
        ring[current].outcome = outcome.rawValue
        if outcome.contains(.decodedPen) { trackStillness(inRange: outcome.contains(.penInRange)) }
        if outcome.contains(.penInRange) { lastInRangeNs = ring[current].kernelNs }
        let now = Self.nowNs()
        let ns = ring[current].kernelNs
        ring[current].doneUs = now > ns ? UInt32(clamping: (now - ns) / 1000) : 0
        current = -1
    }

    // A pen that stays in range without moving: one resting on the tablet
    // holds proximity, so the pen in hand isn't seen. HIDThread-confined.
    // A position that holds while tilt or hover keep changing is the pen
    // pivoting on its tip, or the tablet's position freezing; so the first
    // note comes early, and the last says how much tilt and hover moved.
    static let stillEarlyNs: UInt64 = 3_000_000_000
    static let stillNs: UInt64 = 30_000_000_000
    static let stillSpan: UInt16 = 130  // of 65535, about 0.2% of the width
    private var stillDevice: UInt8 = .max
    private var stillSince: UInt64 = 0
    private var stillX: UInt16 = 0
    private var stillY: UInt16 = 0
    private var stillNoted = false
    private var stillLongNoted = false
    private var stillTilt = (xLo: Int8(0), xHi: Int8(0), yLo: Int8(0), yHi: Int8(0))
    private var stillHover = (lo: UInt8(0), hi: UInt8(0))

    private func stillRanges() -> String {
        String(format: "tilt x %.2f to %.2f, y %.2f to %.2f; hover %d to %d",
               Double(stillTilt.xLo) / 100, Double(stillTilt.xHi) / 100,
               Double(stillTilt.yLo) / 100, Double(stillTilt.yHi) / 100, stillHover.lo, stillHover.hi)
    }

    private func trackStillness(inRange: Bool) {
        let r = ring[current]
        func far(_ a: UInt16, _ b: UInt16) -> Bool { (a > b ? a - b : b - a) > Self.stillSpan }
        let moved = r.device != stillDevice || far(r.x, stillX) || far(r.y, stillY)
        if !inRange || moved {
            if stillNoted {
                note(String(format: "pen's position held for %.1f s in range, then it %@; meanwhile %@",
                            Double(r.kernelNs &- stillSince) / 1e9, inRange ? "moved" : "left", stillRanges()))
            }
            stillNoted = false
            stillLongNoted = false
            stillDevice = inRange ? r.device : .max
            stillSince = r.kernelNs
            stillX = r.x
            stillY = r.y
            stillTilt = (r.tiltX, r.tiltX, r.tiltY, r.tiltY)
            stillHover = (r.hover, r.hover)
            return
        }
        stillTilt = (min(stillTilt.xLo, r.tiltX), max(stillTilt.xHi, r.tiltX),
                     min(stillTilt.yLo, r.tiltY), max(stillTilt.yHi, r.tiltY))
        stillHover = (min(stillHover.lo, r.hover), max(stillHover.hi, r.hover))
        if !stillNoted, r.kernelNs &- stillSince >= Self.stillEarlyNs {
            stillNoted = true
            note("pen's position held for 3 s in range; " + stillRanges())
        }
        if !stillLongNoted, r.kernelNs &- stillSince >= Self.stillNs {
            stillLongNoted = true
            note("pen held still in range for 30 s")
        }
    }

    // MARK: - Pen return (HIDThread)

    /// Pen out of range this long counts as a quiet spell.
    static let quietSpellNs: UInt64 = 5_000_000_000
    private var lastInRangeNs: UInt64 = 0
    private let hidSystem = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))

    /// Called as the pen enters range, before its first post. After a quiet
    /// spell, notes when the user was last active and watches delivery for
    /// a while.
    func penEntering() {
        armCursorCheck()
        let now = Self.nowNs()
        let quiet = lastInRangeNs == 0 ? now : now &- lastInRangeNs
        guard quiet >= Self.quietSpellNs else { return }
        openWatch()
        // macOS's idle time ignores MockTab's posts but resets on its activity
        // declarations, which stop with the pen, and on other apps'. Read
        // before the first post.
        let sinceDeclared = UserActivity.lastNs == 0 ? now : now &- UserActivity.lastNs
        let idle = hidIdleNs()
        let key = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        var parts: [String] = []
        if let idle, idle + 50_000_000 < sinceDeclared {
            parts.append(String(format: "user activity %.1f s before (mouse, trackpad, keyboard, or an app's notice)", Double(idle) / 1e9))
        } else {
            parts.append(String(format: "no user activity in the %.0f s before", Double(sinceDeclared) / 1e9))
        }
        parts.append(String(format: "keyboard or a key shortcut %.1f s before", key))
        let lead = lastInRangeNs == 0
            ? "pen in range for the first time since launch; "
            : String(format: "pen returns after %.0f s out of range; ", Double(quiet) / 1e9)
        note(lead + parts.joined(separator: "; "))
    }

    private func hidIdleNs() -> UInt64? {
        guard hidSystem != 0,
              let value = IORegistryEntryCreateCFProperty(hidSystem, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
        else { return nil }
        return value.uint64Value
    }

    /// Adds to the open report's outcome. A post outside any report (a timer)
    /// isn't recorded.
    func mark(_ outcome: Outcome) {
        guard current >= 0 else { return }
        ring[current].outcome |= outcome.rawValue
    }

    // MARK: - State changes (any thread)

    func note(_ text: String) {
        let event = Event(ns: Self.nowNs(), text: text)
        shared.withLock { s in
            if s.events.count < Self.eventCapacity {
                s.events.append(event)
            } else {
                s.events[s.eventStart] = event
                s.eventStart = (s.eventStart + 1) % Self.eventCapacity
            }
        }
    }

    // MARK: - Export

    /// The recording as text, oldest first. Taken on HIDThread so no report
    /// is half written; if that thread doesn't answer within a second, read
    /// anyway, at worst with one torn entry.
    /// `sinceNs`, if given, keeps only what came after it.
    func exportText(sinceNs: UInt64 = 0) -> String {
        final class Box: @unchecked Sendable { var reports: [Report] = [] }
        let box = Box()
        if CFRunLoopGetCurrent() === HIDThread.shared.runLoop {
            box.reports = snapshotReports()
        } else {
            let taken = DispatchSemaphore(value: 0)
            HIDThread.shared.perform { [self] in
                box.reports = snapshotReports()
                taken.signal()
            }
            if taken.wait(timeout: .now() + 1) == .timedOut { box.reports = snapshotReports() }
        }
        let reports = box.reports.filter { $0.kernelNs >= sinceNs }
        let (events, devices) = shared.withLock { s in
            (Array(s.events[s.eventStart...] + s.events[..<s.eventStart]).filter { $0.ns >= sinceNs }, s.devices)
        }
        let text = Self.format(reports: reports, events: events.map { ($0.ns, $0.text) },
                               devices: devices, startNs: startNs, nowNs: Self.nowNs(), sinceNs: sinceNs)
        let taps = Self.eventTaps().map { "  " + $0.summary }
        return text + "\nEvent taps at export (filters hold each event until their app lets it through):\n"
            + (taps.isEmpty ? "  none readable" : taps.joined(separator: "\n")) + "\n"
    }

    // MARK: - Event taps

    /// Another app's filter tap holds every event it takes until it answers,
    /// and input behind that event waits too. macOS keeps each tap's average
    /// and slowest time.
    struct Tap {
        let id: UInt32
        let filters: Bool
        let enabled: Bool
        let owner: String
        let kinds: String
        let avgUs: Float
        let maxUs: Float

        /// Past this, a figure can't be a real hold: Siri's key filter showed
        /// 10 s, then 134 s, while typing worked. What macOS counts there is
        /// unclear, so it's reported once, as is.
        static let silentUs: Float = 5_000_000
        var silent: Bool { maxUs >= Self.silentUs }

        var summary: String {
            if silent {
                return String(format: "%@ %@ (%@)%@: macOS reports %.0f s for it, too long to be a real hold",
                              owner, filters ? "filter" : "listener", kinds, enabled ? "" : ", off",
                              Double(maxUs) / 1e6)
            }
            return String(format: "%@ %@ (%@)%@: average %.1f ms, slowest %.0f ms",
                   owner, filters ? "filter" : "listener", kinds, enabled ? "" : ", off",
                   Double(avgUs) / 1000, Double(maxUs) / 1000)
        }
    }

    static func eventTaps() -> [Tap] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &list, &count) == .success else { return [] }
        return list.prefix(Int(count)).map { t in
            Tap(id: t.eventTapID, filters: t.options != .listenOnly, enabled: t.enabled,
                owner: processName(t.tappingProcess), kinds: kinds(t.eventsOfInterest),
                avgUs: t.avgUsecLatency, maxUs: t.maxUsecLatency)
        }
    }

    /// Recordings go into public issues, so only macOS's own processes
    /// are named; anything else is "another app".
    static func processName(_ pid: pid_t) -> String {
        if pid == getpid() { return "MockTab" }
        guard isApple(pid) else { return "another app" }
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "a macOS process"
    }

    // Immutable once made; Security objects are thread-safe.
    nonisolated(unsafe) private static let appleRequirement: SecRequirement? = {
        var requirement: SecRequirement?
        return SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess
            ? requirement : nil
    }()

    private static func isApple(_ pid: pid_t) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard let appleRequirement,
              SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code
        else { return false }
        return SecCodeCheckValidity(code, [], appleRequirement) == errSecSuccess
    }

    private static func kinds(_ mask: CGEventMask) -> String {
        func has(_ types: [CGEventType]) -> Bool { types.contains { mask & (1 << $0.rawValue) != 0 } }
        var parts: [String] = []
        if has([.keyDown, .keyUp, .flagsChanged]) { parts.append("keys") }
        if has([.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { parts.append("moves") }
        if has([.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]) {
            parts.append("clicks")
        }
        if has([.scrollWheel]) { parts.append("scrolling") }
        if has([.tabletPointer, .tabletProximity]) { parts.append("tablet") }
        return parts.isEmpty ? "other" : parts.joined(separator: ", ")
    }

    private func snapshotReports() -> [Report] {
        let count = Int(min(written, UInt64(Self.capacity)))
        let first = written > UInt64(Self.capacity) ? Int(written & UInt64(Self.capacity - 1)) : 0
        return (0..<count).map { ring[(first + $0) & (Self.capacity - 1)] }
    }

    /// Runs of alike reports collapse to one line; a silence over
    /// `gapNs` breaks a run and gets a line of its own. State changes are
    /// kept verbatim, in time order among the runs.
    static let gapNs: UInt64 = 100_000_000

    static func format(
        reports: [Report], events: [(UInt64, String)], devices: [String], startNs: UInt64, nowNs: UInt64,
        sinceNs: UInt64 = 0
    ) -> String {
        func stamp(_ ns: UInt64) -> String {
            let s = Double(Int64(bitPattern: ns &- startNs)) / 1e9
            let ago = Double(Int64(bitPattern: nowNs &- ns)) / 1e9
            return String(format: "[%9.3f | -%8.3f]", s, ago)
        }
        func flags(_ raw: UInt8) -> String {
            let o = Outcome(rawValue: raw)
            var parts: [String] = []
            if o.contains(.toolEnter) { parts.append("tool") }
            parts.append(o.contains(.decodedPen) ? (o.contains(.penInRange) ? "pen in" : "pen out") : "no pen")
            if o.contains(.staleSkipped) { parts.append("STALE-SKIPPED") }
            if o.contains(.panHeld) { parts.append("PAN-HELD") }
            if o.contains(.guardHeld) { parts.append("GUARD-HELD") }
            return parts.joined(separator: ",")
        }
        var lines: [String] = []
        lines.append("MockTab recent activity")
        // A partial export says how much it covers, not how long since launch.
        let from = sinceNs > startNs ? sinceNs : startNs
        lines.append(String(format: "Recorded %.1f s%@; %d reports; %d state changes. Times: [since launch | before export], seconds.",
                            Double(nowNs &- from) / 1e9, sinceNs > startNs ? " (this collection)" : "",
                            reports.count, events.count))
        for (i, name) in devices.enumerated() { lines.append("Device \(i): \(name)") }
        lines.append("Report runs: device, report ID, status byte, outcome, count, span, cursor moves and other events posted, weak frames held at the last position for jumping, X/Y range (0-65535), tilt range (-1 to 1), hover range, delay to callback and to done (ms, max).")
        lines.append(String(repeating: "─", count: 78))

        var e = 0
        func flushEvents(before ns: UInt64) {
            while e < events.count, events[e].0 <= ns {
                lines.append("\(stamp(events[e].0)) • \(events[e].1)")
                e += 1
            }
        }
        // Posting differs report to report (scrolls, the delta gate), so it's
        // counted within a run rather than splitting it.
        let posts = Outcome.postedMove.rawValue | Outcome.postedOther.rawValue
        var i = 0
        var previousEnd: UInt64?
        while i < reports.count {
            let head = reports[i]
            if let previousEnd, head.kernelNs > previousEnd, head.kernelNs - previousEnd > gapNs {
                lines.append(String(format: "%@ — %.3f s with no reports —", stamp(previousEnd),
                                    Double(head.kernelNs - previousEnd) / 1e9))
            }
            flushEvents(before: head.kernelNs)
            var j = i + 1
            var xLo = head.x, xHi = head.x, yLo = head.y, yHi = head.y
            var txLo = head.tiltX, txHi = head.tiltX, tyLo = head.tiltY, tyHi = head.tiltY
            var hLo = head.hover, hHi = head.hover
            var cbMax = head.callbackUs, doneMax = head.doneUs
            var moved = head.outcome & Outcome.postedMove.rawValue != 0 ? 1 : 0
            var posted = head.outcome & Outcome.postedOther.rawValue != 0 ? 1 : 0
            var held = Int(head.flags & 1)
            while j < reports.count {
                let r = reports[j]
                guard r.device == head.device, r.reportID == head.reportID, r.status == head.status,
                    r.outcome & ~posts == head.outcome & ~posts, r.kernelNs >= reports[j - 1].kernelNs,
                    r.kernelNs - reports[j - 1].kernelNs <= gapNs,
                    e >= events.count || events[e].0 > r.kernelNs
                else { break }
                xLo = min(xLo, r.x); xHi = max(xHi, r.x); yLo = min(yLo, r.y); yHi = max(yHi, r.y)
                txLo = min(txLo, r.tiltX); txHi = max(txHi, r.tiltX); tyLo = min(tyLo, r.tiltY); tyHi = max(tyHi, r.tiltY)
                hLo = min(hLo, r.hover); hHi = max(hHi, r.hover)
                cbMax = max(cbMax, r.callbackUs); doneMax = max(doneMax, r.doneUs)
                if r.outcome & Outcome.postedMove.rawValue != 0 { moved += 1 }
                if r.outcome & Outcome.postedOther.rawValue != 0 { posted += 1 }
                held += Int(r.flags & 1)
                j += 1
            }
            let last = reports[j - 1]
            let span = Double(last.kernelNs &- head.kernelNs) / 1e9
            var line = String(format: "%@ dev%d 0x%02X st=0x%02X %@ ×%d %.3fs", stamp(head.kernelNs),
                              head.device, head.reportID, head.status, flags(head.outcome & ~posts), j - i, span)
            line += " moved \(moved) posted \(posted)"
            if held > 0 { line += " held \(held)" }
            if Outcome(rawValue: head.outcome).contains(.decodedPen) {
                line += " x=\(xLo)-\(xHi) y=\(yLo)-\(yHi)"
                line += String(format: " tilt=%.2f..%.2f,%.2f..%.2f hover=%d-%d",
                               Double(txLo) / 100, Double(txHi) / 100, Double(tyLo) / 100, Double(tyHi) / 100, hLo, hHi)
            }
            line += String(format: " cb≤%.1f done≤%.1f", Double(cbMax) / 1000, Double(doneMax) / 1000)
            lines.append(line)
            previousEnd = last.kernelNs
            i = j
        }
        flushEvents(before: UInt64.max)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - System state

    private var observers: [NSObjectProtocol] = []
    private var memoryPressure: DispatchSourceMemoryPressure?

    /// Notes sleep, wake, display sleep, and session switches. Call once, on main.
    @MainActor
    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [(Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "system going to sleep"),
            (NSWorkspace.didWakeNotification, "system woke"),
            (NSWorkspace.screensDidSleepNotification, "displays slept"),
            (NSWorkspace.screensDidWakeNotification, "displays woke"),
            (NSWorkspace.sessionDidResignActiveNotification, "user session inactive"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "user session active"),
        ]
        for (name, text) in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
                FlightRecorder.shared.note(text)
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { _ in
            let state: String
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: state = "normal"
            case .fair: state = "fair"
            case .serious: state = "serious"
            case .critical: state = "critical"
            @unknown default: state = "unknown"
            }
            FlightRecorder.shared.note("Mac's thermal state: \(state)")
        })
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        pressure.setEventHandler { [weak pressure] in
            guard let event = pressure?.data else { return }
            let level = event.contains(.critical) ? "critical" : event.contains(.warning) ? "warning" : "normal"
            FlightRecorder.shared.note("memory pressure: \(level)")
        }
        pressure.activate()
        memoryPressure = pressure
        note("recording started")
        startDeliveryWatch()
        #if DEBUG
        listenForDebugSave()
        #endif
    }

    // MARK: - Delivery

    // MockTab's posts carry their report's kernel time, so a listen-only tap
    // at the end of the session's chain sees how long macOS took to pass
    // them on. Runs on its own thread: never HIDThread, which posts them.
    // Notes a stretch of late delivery when it starts and when it ends.
    // Watching every move costs about half as much as posting it, and
    // WindowServer as much again to send the copies, so the tap runs only
    // for `watchNs` after the pen returns from a quiet spell, and on while
    // moves still arrive late.
    // A timer on the same thread, running while moves arrive, tells macOS
    // holding the moves apart from this thread being held itself. Its period
    // matches the lateness threshold: any hold that long delays a firing.
    static let lateDeliveryNs: UInt64 = 30_000_000
    private static let heartbeatNs: UInt64 = lateDeliveryNs
    static let watchNs: UInt64 = 10_000_000_000
    private var deliveryTap: CFMachPort?
    private var heartbeat: CFRunLoopTimer?
    /// Set on the watch thread, read on HIDThread.
    private let watchRunLoop = OSAllocatedUnfairLock<CFRunLoop?>(uncheckedState: nil)
    private var watchEnd: CFRunLoopTimer?
    // Delivery-thread-confined.
    private var watching = false
    private var watchPostedStart: UInt64 = 0
    private var watchSeen: UInt64 = 0
    private var lateSince: UInt64 = 0
    private var lateCount = 0
    private var lateWorstNs: UInt64 = 0
    private var heartbeatDueNs: UInt64 = 0  // 0 while idle
    private var lastMoveNs: UInt64 = 0
    private var recentHeldNs: UInt64 = 0
    private var recentHeldAtNs: UInt64 = 0
    private var stretchHeldNs: UInt64 = 0
    private var stretchTimed = false
    private var tapBaseline: [UInt32: Float] = [:]  // filter tap ID: slowest
    private var silentTapsNoted: Set<UInt32> = []
    private let strain = StrainSampler()
    private var lastContextNs: UInt64 = 0
    private var lastPointerNs: UInt64 = 0
    private var lastKeyNs: UInt64 = 0

    private func startDeliveryWatch() {
        let mask = (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue) | (1 << CGEventType.otherMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
        let thread = Thread { [self] in
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, info in
                    guard let info else { return Unmanaged.passUnretained(event) }
                    Unmanaged<FlightRecorder>.fromOpaque(info).takeUnretainedValue().delivered(type, event)
                    return Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque())
            else {
                note("delivery watch unavailable: no event tap")
                return
            }
            deliveryTap = tap
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: false)
            // Repeating, so macOS keeps it valid after a firing; the interval never comes due.
            let end = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 1e9, 0, 0) { [self] _ in endWatch() }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), end, .commonModes)
            watchEnd = end
            let cursor = CFRunLoopTimerCreateWithHandler(
                nil, .greatestFiniteMagnitude, Double(Self.cursorCheckNs) / 1e9, 0, 0
            ) { [self] _ in checkCursor() }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), cursor, .commonModes)
            cursorTimer = cursor
            let timer = CFRunLoopTimerCreateWithHandler(
                nil, .greatestFiniteMagnitude, Double(Self.heartbeatNs) / 1e9, 0, 0
            ) { [self] _ in beat() }
            CFRunLoopTimerSetTolerance(timer, 0)
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
            heartbeat = timer
            _ = slowerFilters()
            let loop = CFRunLoopGetCurrent()
            watchRunLoop.withLockUnchecked { $0 = loop }
            CFRunLoopRun()
        }
        thread.name = "MockTab delivery watch"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private static let ownPID = Int64(getpid())

    private func openWatch() {
        guard let loop = watchRunLoop.withLockUnchecked({ $0 }) else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [self] in
            guard let deliveryTap, let watchEnd else { return }
            if !watching {
                watching = true
                watchPostedStart = postedMoves.withLock { $0.count }
                watchSeen = 0
                lastPointerNs = 0
                lastKeyNs = 0
                CGEvent.tapEnable(tap: deliveryTap, enable: true)
            }
            CFRunLoopTimerSetNextFireDate(watchEnd, CFAbsoluteTimeGetCurrent() + Double(Self.watchNs) / 1e9)
        }
        CFRunLoopWakeUp(loop)
    }

    private func endWatch() {
        guard let deliveryTap, let watchEnd else { return }
        let now = Self.nowNs()
        if lateCount > 0 {
            if now - lastMoveNs < 1_000_000_000 {
                CFRunLoopTimerSetNextFireDate(watchEnd, CFAbsoluteTimeGetCurrent() + 1)
                return
            }
            note(String(format: "watch ended with moves still late: %d over %.2f s, worst %.0f ms, then none for %.1f s",
                        lateCount, Double(lastMoveNs - lateSince) / 1e9, Double(lateWorstNs) / 1e6,
                        Double(now - lastMoveNs) / 1e9))
            lateCount = 0
            lateWorstNs = 0
        }
        let posted = postedMoves.withLock { $0.count } &- watchPostedStart
        if watchSeen + 5 < posted {
            note("while watched, MockTab posted \(posted) moves and \(watchSeen) reached apps")
        }
        watching = false
        CFRunLoopTimerSetNextFireDate(watchEnd, .greatestFiniteMagnitude)
        CGEvent.tapEnable(tap: deliveryTap, enable: false)
        heartbeatDueNs = 0
        if let heartbeat { CFRunLoopTimerSetNextFireDate(heartbeat, .greatestFiniteMagnitude) }
    }

    // MARK: - Cursor

    // Where macOS shows the cursor against where MockTab's last move put it,
    // four times a second while moves flow: the ground truth the delivery
    // watch lacks, since a move macOS never passes on leaves no trace there.
    // On this thread, never HIDThread: asking WindowServer blocks if it's stuck.
    static let cursorCheckNs: UInt64 = 250_000_000
    static let cursorAwayPoints: CGFloat = 40
    private struct PostedMoves {
        var count: UInt64 = 0
        var last = CGPoint.zero
        var lastNs: UInt64 = 0
    }
    private let postedMoves = OSAllocatedUnfairLock(initialState: PostedMoves())
    private var cursorTimer: CFRunLoopTimer?
    // Delivery-thread-confined.
    private var cursorArmed = false
    private var awayChecks = 0
    private var nearChecks = 0
    private var awaySince: UInt64 = 0
    private var awayFirst = CGPoint.zero
    private var awayDrift: CGFloat = 0

    /// HIDThread, for each move or drag posted.
    func notePostedMove(_ location: CGPoint) {
        let now = Self.nowNs()
        postedMoves.withLock {
            $0.count &+= 1
            $0.last = location
            $0.lastNs = now
        }
    }

    private func armCursorCheck() {
        guard let loop = watchRunLoop.withLockUnchecked({ $0 }) else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [self] in
            guard !cursorArmed, let cursorTimer else { return }
            cursorArmed = true
            CFRunLoopTimerSetNextFireDate(cursorTimer, CFAbsoluteTimeGetCurrent() + Double(Self.cursorCheckNs) / 1e9)
        }
        CFRunLoopWakeUp(loop)
    }

    private func checkCursor() {
        let now = Self.nowNs()
        let posted = postedMoves.withLock { $0 }
        let flowing = posted.lastNs != 0 && now &- posted.lastNs < Self.cursorCheckNs
        guard flowing || awayChecks > 0 else {
            // A still pen posts nothing; park until the next entry.
            if now &- posted.lastNs > 2_000_000_000, let cursorTimer {
                cursorArmed = false
                CFRunLoopTimerSetNextFireDate(cursorTimer, .greatestFiniteMagnitude)
            }
            return
        }
        guard let actual = CGEvent(source: nil)?.location else { return }
        let away = hypot(actual.x - posted.last.x, actual.y - posted.last.y)
        if flowing, away > Self.cursorAwayPoints {
            nearChecks = 0
            awayChecks += 1
            if awayChecks == 1 {
                awaySince = now
                awayFirst = actual
                awayDrift = 0
            }
            awayDrift = max(awayDrift, hypot(actual.x - awayFirst.x, actual.y - awayFirst.y))
            if awayChecks == 2 {
                note(String(format: "cursor not where MockTab's moves put it: at (%.0f, %.0f), %.0f points from the last move",
                            actual.x, actual.y, away))
            }
            return
        }
        // Two good checks in a row end a stretch, so a lucky sample doesn't.
        if awayChecks >= 2, flowing, nearChecks == 0 {
            nearChecks = 1
            return
        }
        if awayChecks >= 2 {
            let span = Double(now - awaySince) / 1e9
            note(away > Self.cursorAwayPoints
                 ? String(format: "MockTab's moves stopped with the cursor still %.0f points away, after %.2f s; while away it moved up to %.0f points",
                          away, span, awayDrift)
                 : String(format: "cursor followed MockTab's moves again after %.2f s; while away it moved up to %.0f points",
                          span, awayDrift))
        }
        awayChecks = 0
        nearChecks = 0
    }

    private func beat() {
        let now = Self.nowNs()
        if heartbeatDueNs != 0, now > heartbeatDueNs {
            let held = now - heartbeatDueNs
            if now - recentHeldAtNs > 1_000_000_000 || held >= recentHeldNs {
                recentHeldNs = held
                recentHeldAtNs = now
            }
            if lateCount > 0 { stretchHeldNs = max(stretchHeldNs, held) }
        }
        if now - lastMoveNs > 1_000_000_000 {
            heartbeatDueNs = 0
            if let heartbeat { CFRunLoopTimerSetNextFireDate(heartbeat, .greatestFiniteMagnitude) }
        } else {
            heartbeatDueNs = now + Self.heartbeatNs
            strain.tick(now: now)
        }
    }

    // The mouse, trackpad, or keyboard coming back after a quiet spell: when
    // set beside the pen's reports, shows whether other input preceded the
    // pen's return. Timing only; nothing about what was typed.
    static let quietNs: UInt64 = 3_000_000_000

    private func hardwareInput(_ type: CGEventType, _ event: CGEvent) {
        let state = Int32(truncatingIfNeeded: event.getIntegerValueField(.eventSourceStateID))
        guard state == CGEventSourceStateID.hidSystemState.rawValue else { return }
        let now = Self.nowNs()
        if type == .keyDown {
            if now - lastKeyNs > Self.quietNs { note(quietNote("keyboard used", since: lastKeyNs, now)) }
            lastKeyNs = now
        } else {
            if now - lastPointerNs > Self.quietNs { note(quietNote("mouse or trackpad used", since: lastPointerNs, now)) }
            lastPointerNs = now
        }
    }

    private func quietNote(_ what: String, since: UInt64, _ now: UInt64) -> String {
        since == 0 ? what + " (first since the pen returned)" : String(format: "%@ (first in %.1f s)", what, Double(now - since) / 1e9)
    }

    /// Enabled filter taps whose slowest time rose since the last call.
    private func slowerFilters() -> [Tap] {
        let filters = Self.eventTaps().filter { $0.filters && $0.enabled }
        defer { tapBaseline = Dictionary(filters.map { ($0.id, $0.maxUs) }, uniquingKeysWith: max) }
        return filters.filter { tap in
            if tap.silent { return silentTapsNoted.insert(tap.id).inserted }
            return tap.maxUs > (tapBaseline[tap.id] ?? 0) && tap.maxUs >= 1000
        }
    }

    /// The watcher's own worst lateness in the last second.
    private func recentHeld(at now: UInt64) -> UInt64 {
        now - recentHeldAtNs <= 1_000_000_000 ? recentHeldNs : 0
    }

    private func delivered(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            guard watching, let deliveryTap else { return }
            CGEvent.tapEnable(tap: deliveryTap, enable: true)
            note("delivery watch re-enabled after macOS disabled it")
            return
        }
        guard event.getIntegerValueField(.eventSourceUnixProcessID) == Self.ownPID else {
            hardwareInput(type, event)
            return
        }
        // Timing covers MockTab's moves and drags; its clicks and scrolls aren't stamped alike.
        guard type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged
            || type == .otherMouseDragged else { return }
        let now = Self.nowNs()
        let stamped = event.timestamp
        guard stamped != 0, now > stamped else { return }
        let delay = now - stamped
        lastMoveNs = now
        watchSeen += 1
        let timed = heartbeatDueNs != 0
        if !timed, let heartbeat {
            heartbeatDueNs = now + Self.heartbeatNs
            CFRunLoopTimerSetNextFireDate(heartbeat, CFAbsoluteTimeGetCurrent() + Double(Self.heartbeatNs) / 1e9)
        }
        if delay > Self.lateDeliveryNs {
            if lateCount == 0 {
                lateSince = now
                stretchHeldNs = recentHeld(at: now)
                stretchTimed = timed
                note(String(format: "MockTab's moves start reaching apps late: %.0f ms after the report", Double(delay) / 1e6))
            }
            lateCount += 1
            lateWorstNs = max(lateWorstNs, delay)
        } else {
            if lateCount > 0 {
                let span = Double(now - lateSince) / 1e9
                let held = max(stretchHeldNs, recentHeld(at: now))
                let watcher = stretchTimed || held > 0
                    ? String(format: "the watcher itself ran up to %.0f ms late", Double(held) / 1e6)
                    : "the watcher's own timer started with this stretch"
                note(String(format: "macOS passed on %d of MockTab's moves late over %.2f s; worst %.0f ms after the report; %@",
                            lateCount, span, Double(lateWorstNs) / 1e6, watcher))
                // Once a second at most: stretches often come in bunches.
                if now - lastContextNs >= 1_000_000_000 {
                    lastContextNs = now
                    strain.noteLoad()
                    let slower = slowerFilters()
                    note(slower.isEmpty
                         ? "no filter tap got slower"
                         : "filter taps slower since the last check: " + slower.map(\.summary).joined(separator: "; "))
                }
                lateCount = 0
                lateWorstNs = 0
            }
        }
    }

    #if DEBUG
    /// Debug builds save the recording on `notifyutil -p com.mocktab.debug.save-recent`,
    /// to ~/Library/Logs/MockTab/. For the replay rig.
    private var saveToken: Int32 = 0
    private func listenForDebugSave() {
        notify_register_dispatch("com.mocktab.debug.save-recent", &saveToken, .global(qos: .utility)) { _ in
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/MockTab", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("recent-activity-\(DateStamp.compact(Date())).txt")
            try? FlightRecorder.shared.exportText().write(to: url, atomically: true, encoding: .utf8)
        }
    }
    #endif
}
