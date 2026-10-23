// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Replays hid-recorder files of Wacom tablets through TabletKit and compares
// what each decoder concludes with the tablet's own bits, read the way the
// Linux kernel's wacom_wac.c (input-wacom 4.18) reads them: contact,
// proximity, eraser, barrel buttons, tool identity, pad keys, rings, strips,
// and touch contacts. It counts the reports that disagree and the presses
// that merge, split, or appear from nothing, and ranks the report formats.
//
// Run it through run.sh. -v prints examples for every file, and -n sets how
// many of each kind.

import Foundation
import TabletKit

// MARK: - Recording

struct Event { let dev: Int; let time: Double; let bytes: [UInt8] }
struct Recording { let name: String; var pids: [Int: Int] = [:]; var events: [Event] = [] }

func parse(_ path: String) -> Recording {
    var rec = Recording(name: (path as NSString).lastPathComponent)
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    var dev = 0
    for line in text.split(separator: "\n") {
        let f = line.split(separator: " ")
        guard let tag = f.first else { continue }
        if tag.hasPrefix("D:") {
            // Both "D: 1" and "D:1" appear.
            dev = Int(tag.count > 2 ? tag.dropFirst(2) : f[1]) ?? 0
            continue
        }
        switch tag {
        case "I:": rec.pids[dev] = Int(f[3], radix: 16) ?? -1
        case "E:":
            let bytes = f.dropFirst(3).compactMap { UInt8($0, radix: 16) }
            rec.events.append(Event(dev: dev, time: Double(f[1]) ?? 0, bytes: bytes))
        default: break
        }
    }
    return rec
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }
func be16(_ d: [UInt8], _ i: Int) -> Int { Int(d[i]) << 8 | Int(d[i + 1]) }
func le16(_ d: [UInt8], _ i: Int) -> Int { Int(d[i + 1]) << 8 | Int(d[i]) }
func at(_ d: [UInt8], _ i: Int) -> UInt8 { i < d.count ? d[i] : 0 }

// MARK: - Kernel oracle

enum ToolKind: String { case pen, eraser, mouse, lens, other }

/// Pen state as the kernel last reported it.
struct PenObs {
    var prox = false
    var tool = ToolKind.pen
    var touch = false
    var pressure = 0
    var s1 = false
    var s2 = false
    var toolID = 0
    var serial: UInt64 = 0
    var entered = false
}

/// Pad state from one pad report: kernel button numbers held, ring and strip values.
struct PadObs {
    var buttons: [Int] = []
    var rings: [Int?] = []   // nil = no finger
    var strips: [Int] = []   // raw, 0 = no finger
}

enum Obs { case pen(PenObs), pad(PadObs), touch(Int), penAndPad(PenObs, PadObs), ignored(String) }

enum PadKind { case i4, i5, ux2, hd22, hd24, dtk, generic }
enum Kind {
    case graphire(mo: Bool)
    case bpt
    case intuos(pad: PadKind, pmax: Int, nbuttons: Int, cintiqRdy: Bool, needsI4Bit: Bool, noLens: Bool)
    case dtu, dtus, hdt24
}

/// Kernel feature type per product, from the wacom_features table.
func kernelKind(_ pid: Int) -> Kind? {
    switch pid {
    case 0x13: return .graphire(mo: false)
    case 0x17, 0x65: return .graphire(mo: true)
    case 0xD0, 0xD4, 0x302, 0x303, 0x323, 0x30E: return .bpt
    case 0xC6: return .intuos(pad: .generic, pmax: 1023, nbuttons: 10, cintiqRdy: false, needsI4Bit: false, noLens: false)
    case 0x3F: return .intuos(pad: .generic, pmax: 1023, nbuttons: 8, cintiqRdy: true, needsI4Bit: false, noLens: false)
    case 0xCC: return .intuos(pad: .ux2, pmax: 2047, nbuttons: 18, cintiqRdy: false, needsI4Bit: true, noLens: false)
    case 0x5B, 0xFA: return .intuos(pad: .hd22, pmax: 2047, nbuttons: 18, cintiqRdy: false, needsI4Bit: false, noLens: false)
    case 0xF4: return .intuos(pad: .hd24, pmax: 2047, nbuttons: 16, cintiqRdy: false, needsI4Bit: false, noLens: false)
    case 0x57: return .intuos(pad: .dtk, pmax: 2047, nbuttons: 6, cintiqRdy: false, needsI4Bit: false, noLens: false)
    case 0xB1, 0xB2: return .intuos(pad: .generic, pmax: 1023, nbuttons: 8, cintiqRdy: false, needsI4Bit: false, noLens: true)
    case 0xB8: return .intuos(pad: .i4, pmax: 2047, nbuttons: 7, cintiqRdy: false, needsI4Bit: false, noLens: true)
    case 0xBC: return .intuos(pad: .i4, pmax: 2047, nbuttons: 9, cintiqRdy: false, needsI4Bit: false, noLens: true)
    case 0x26, 0x314: return .intuos(pad: .i5, pmax: 2047, nbuttons: 7, cintiqRdy: false, needsI4Bit: false, noLens: true)
    case 0x27, 0x28, 0x315: return .intuos(pad: .i5, pmax: 2047, nbuttons: 9, cintiqRdy: false, needsI4Bit: false, noLens: true)
    case 0xFB: return .dtus
    case 0xCE: return .dtu
    case 0x5E: return .hdt24
    default: return nil
    }
}

func kernelPressureMax(_ kind: Kind) -> Int {
    switch kind {
    case .graphire, .dtu, .dtus: return 511
    case .bpt: return 1023
    case .intuos(_, let pmax, _, _, _, _): return pmax
    case .hdt24: return 0
    }
}

func intuosToolType(_ id: Int) -> ToolKind {
    switch id {
    case 0x812, 0x801, 0x12802, 0x012, 0x832, 0x032, 0xd12, 0x912, 0x112, 0x913, 0x902, 0x10902: return .other
    case 0x007, 0x09c, 0x094, 0x017, 0x806: return .mouse
    case 0x096, 0x097, 0x006: return .lens
    default: return (id & 0x0008) != 0 ? .eraser : .pen
    }
}

/// One interface's kernel state machine.
struct Oracle {
    let kind: Kind
    var pen = PenObs()
    var id0 = 0
    var reportingData = false
    var padActive = false
    var slots = Set<Int>()
    var hdtLeft = 0

    init(kind: Kind) { self.kind = kind }

    mutating func step(_ d: [UInt8]) -> Obs {
        guard !d.isEmpty else { return .ignored("empty") }
        pen.entered = false
        switch kind {
        case .graphire(let mo): return graphire(d, mo: mo)
        case .bpt:
            if d[0] == 0xC0 { return .ignored("status") }
            switch d.count {
            case 20: return bptTouch(d)
            case 64: return bpt3(d, swapLeftBack: true)
            case 9, 10: return bptPen(d)
            default: return .ignored("len \(d.count)")
            }
        case .intuos:
            if d.count == 64 { return bpt3(d, swapLeftBack: false) }
            if d[0] == 0xC0 { return .ignored("status") }
            return intuos(d)
        case .dtu: return dtu(d)
        case .dtus: return dtus(d)
        case .hdt24: return hdt24(d)
        }
    }

    mutating func graphire(_ d: [UInt8], mo: Bool) -> Obs {
        guard d[0] == 0x02, d.count >= 8 else { return .ignored("id") }
        var penChanged = false
        let prox = d[1] & 0x80 != 0
        if prox || id0 != 0 {
            if prox {
                if !pen.prox { pen.entered = true }
                switch (d[1] >> 5) & 3 {
                case 0: pen.tool = .pen; id0 = 2
                case 1: pen.tool = .eraser; id0 = 0x0A
                default: pen.tool = .mouse; id0 = 6
                }
            }
            if pen.tool != .mouse {
                pen.pressure = Int(d[6]) | Int(d[7] & 0x03) << 8
                pen.touch = d[1] & 0x01 != 0
                pen.s1 = d[1] & 0x02 != 0
                pen.s2 = d[1] & 0x04 != 0
            }
            if !prox { id0 = 0 }
            pen.prox = prox
            penChanged = true
        }
        var pad: PadObs?
        if mo, d.count >= 9 {
            let active = d[7] & 0xF8 != 0 || d[8] != 0
            if active || padActive {
                var p = PadObs()
                // BTN_BACK, BTN_FORWARD, BTN_LEFT, BTN_RIGHT
                for (n, bit) in [(0, 0x08), (1, 0x10), (2, 0x20), (3, 0x40)] where Int(d[7]) & bit != 0 { p.buttons.append(n) }
                p.rings = [d[8] != 0 ? Int(d[8] & 0x7F) : nil]   // 0x80 is a finger at position 0
                pad = p
                padActive = active
            }
        }
        switch (penChanged, pad) {
        case (true, let p?): return .penAndPad(pen, p)
        case (true, nil): return .pen(pen)
        case (false, let p?): return .pad(p)
        default: return .ignored("idle")
        }
    }

    mutating func bptPen(_ d: [UInt8]) -> Obs {
        guard d[0] == 0x02 else { return .ignored("id") }
        let range = d[1] & 0x80 != 0, prox = d[1] & 0x40 != 0, rdy = d[1] & 0x20 != 0
        var p = 0, touch = false, b1 = false, b2 = false
        if rdy { p = le16(d, 6); touch = d[1] & 0x01 != 0; b1 = d[1] & 0x02 != 0; b2 = d[1] & 0x04 != 0 }
        if prox {
            pen.tool = d[1] & 0x08 != 0 ? .eraser : .pen
            reportingData = true
        }
        guard reportingData else { return .ignored("not reporting") }
        if range && !pen.prox { pen.entered = true }
        pen.touch = touch; pen.s1 = b1; pen.s2 = b2; pen.pressure = p
        pen.prox = range
        if !range { reportingData = false }
        return .pen(pen)
    }

    mutating func bptTouch(_ d: [UInt8]) -> Obs {
        guard d[0] == 0x02 else { return .ignored("id") }
        slots = []
        for i in 0..<2 {
            let off = d[1] & 0x80 != 0 ? 8 * i : 9 * i
            if d[off + 3] & 0x80 != 0 { slots.insert(i) }
        }
        return .touch(slots.count)
    }

    mutating func bpt3(_ d: [UInt8], swapLeftBack: Bool) -> Obs {
        guard d[0] == 0x02 else { return .ignored("id") }
        let count = Int(d[1] & 0x07)
        var touched = false
        var pad: PadObs?
        for i in 0..<count {
            let off = 8 * i + 2
            let msg = Int(d[off])
            if (2...17).contains(msg) {
                if d[off + 1] & 0x80 != 0 { slots.insert(msg) } else { slots.remove(msg) }
                touched = true
            } else if msg == 128 {
                var p = PadObs()
                let b = Int(d[off + 1])
                // Bit order 0x01, 0x02, 0x04, 0x08; the kernel names differ by type.
                for (n, bit) in [(0, 0x01), (1, 0x02), (2, 0x04), (3, 0x08)] where b & bit != 0 { p.buttons.append(n) }
                pad = p
            }
        }
        if let pad { return touched ? .ignored("touch+pad") : .pad(pad) }
        return touched ? .touch(slots.count) : .ignored("no msgs")
    }

    mutating func intuos(_ d: [UInt8]) -> Obs {
        guard case let .intuos(padKind, pmax, nbuttons, cintiqRdy, needsI4Bit, noLens) = kind else { return .ignored("") }
        guard d.count >= 10 else { return .ignored("short") }
        if [0x0C, 0x03, 0x11].contains(d[0]) { return intuosPad(d, padKind, nbuttons) }
        guard [0x02, 0x10, 0x05, 0x06].contains(d[0]) else { return .ignored("id") }
        // wacom_intuos_inout: enter, in range, and exit packets.
        if d[1] & 0xFC == 0xC0 {
            pen.serial = UInt64(d[3] & 0x0F) << 28 + UInt64(d[4]) << 20 + UInt64(d[5]) << 12 + UInt64(d[6]) << 4 + UInt64(d[7] >> 4)
            id0 = Int(d[2]) << 4 | Int(d[3] >> 4) | Int(d[7] & 0x0F) << 16 | Int(d[8] & 0xF0) << 8
            pen.toolID = id0
            pen.tool = intuosToolType(id0)
            return .ignored("enter")   // the kernel syncs nothing visible until the first data packet
        }
        if d[1] & 0xFE == 0x20 {
            if reportingData { pen.touch = false; pen.pressure = 0; return .pen(pen) }
            return .ignored("in range")
        }
        if d[1] & 0xFE == 0x80 {
            reportingData = false
            if id0 == 0 { return .ignored("exit, no id") }
            pen.prox = false; pen.touch = false; pen.pressure = 0; pen.s1 = false; pen.s2 = false
            id0 = 0
            return .pen(pen)
        }
        // wacom_intuos_general: data packets.
        guard id0 != 0 else { return .ignored("no id") }
        if needsI4Bit && (id0 >> 16) & 1 == 0 { return .ignored("old I4 stylus") }
        if noLens && pen.tool == .lens { return .ignored("lens") }
        if cintiqRdy && d[1] & 0x40 == 0 { return .ignored("not ready") }
        if !pen.prox { pen.entered = true }
        pen.prox = true
        let type = (d[1] >> 1) & 0x0F
        if type <= 3 {
            var t = Int(d[6]) << 3 | Int(d[7] & 0xC0) >> 5 | Int(d[1] & 1)
            if pmax < 2047 { t >>= 1 }
            pen.pressure = t
            pen.s1 = d[1] & 2 != 0
            pen.s2 = d[1] & 4 != 0
            pen.touch = t > 10
        }
        reportingData = true
        return .pen(pen)
    }

    mutating func intuosPad(_ d: [UInt8], _ pk: PadKind, _ nbuttons: Int) -> Obs {
        var buttons = 0, keys = 0, nkeys = 0, ring1 = 0, ring2 = 0, strip1 = 0, strip2 = 0
        var hasRing1 = false, hasRing2 = false, hasStrips = false
        switch pk {
        case .i4: buttons = Int(d[3]) << 1 | Int(d[2] & 1); ring1 = Int(d[1]); hasRing1 = true
        case .dtk: buttons = Int(d[6])
        case .hd24:
            buttons = Int(d[8]) << 8 | Int(d[6]); ring1 = Int(d[1]); ring2 = Int(d[2]); hasRing1 = true; hasRing2 = true
            nkeys = 3
            keys = (d[3] & 0x1C != 0 ? 4 : 0) | (d[4] & 0xE0 != 0 ? 2 : 0) | (d[4] & 0x07 != 0 ? 1 : 0)
        case .i5: buttons = Int(d[4]) << 1 | Int(d[3] & 1); ring1 = Int(d[2]); hasRing1 = true
        case .ux2, .hd22:
            buttons = Int(d[8]) << 10 | Int(d[7] & 1) << 9 | Int(d[6]) << 1 | Int(d[5] & 1)
            if pk == .hd22 { nkeys = 3; keys = Int(d[9] & 0x07) }
            hasStrips = true
        case .generic:
            buttons = (Int(d[6]) & 0x10) << 5 | (Int(d[5]) & 0x10) << 4 | (Int(d[6]) & 0x0F) << 4 | (Int(d[5]) & 0x0F)
            hasStrips = true
        }
        if hasStrips {
            strip1 = (Int(d[1]) & 0x1F) << 8 | Int(d[2])
            strip2 = (Int(d[3]) & 0x1F) << 8 | Int(d[4])
        }
        var p = PadObs()
        for i in 0..<nbuttons where buttons & (1 << i) != 0 { p.buttons.append(i) }
        for i in 0..<nkeys where keys & (1 << i) != 0 { p.buttons.append(100 + i) }
        if hasRing1 { p.rings.append(ring1 & 0x80 != 0 ? ring1 & 0x7F : nil) }
        if hasRing2 { p.rings.append(ring2 & 0x80 != 0 ? ring2 & 0x7F : nil) }
        if hasStrips { p.strips = [strip1, strip2] }
        return .pad(p)
    }

    mutating func dtu(_ d: [UInt8]) -> Obs {
        guard d.count >= 8 else { return .ignored("short") }
        let prox = d[1] & 0x20 != 0
        if prox {
            pen.tool = d[1] & 0x0C != 0 ? .eraser : .pen
            if !pen.prox { pen.entered = true }
        }
        pen.s1 = d[1] & 0x02 != 0; pen.s2 = d[1] & 0x10 != 0
        pen.pressure = Int(d[7] & 1) << 8 | Int(d[6])
        pen.touch = d[1] & 0x05 != 0
        pen.prox = prox
        return .pen(pen)
    }

    mutating func dtus(_ d: [UInt8]) -> Obs {
        if d[0] == 0x15 {
            var p = PadObs()
            for i in 0..<4 where Int(d[1]) & (1 << i) != 0 { p.buttons.append(i) }
            return .pad(p)
        }
        guard d[0] == 0x11, d.count >= 7 else { return .ignored("id") }
        let prox = d[1] & 0x80 != 0
        if prox {
            switch (d[1] >> 3) & 3 {
            case 1: pen.tool = .eraser
            case 2: pen.tool = .pen
            default: break
            }
            if !pen.prox { pen.entered = true }
        }
        pen.s1 = d[1] & 0x20 != 0; pen.s2 = d[1] & 0x40 != 0
        pen.pressure = Int(d[1] & 0x03) << 8 | Int(d[2])
        pen.touch = pen.pressure > 10
        pen.prox = prox
        return .pen(pen)
    }

    mutating func hdt24(_ d: [UInt8]) -> Obs {
        guard d[0] == 0x01, d.count >= 62 else { return .ignored("id") }
        let current = Int(d[61])
        if current != 0 { hdtLeft = current }
        let send = min(4, hdtLeft)
        for i in 0..<send {
            let off = 14 * i + 1
            let key = Int(d[off + 1])
            if d[off] & 1 != 0 { slots.insert(key) } else { slots.remove(key) }
        }
        hdtLeft -= send
        // A frame spans several packets; compare once it's complete.
        return hdtLeft <= 0 ? .touch(slots.count) : .ignored("partial frame")
    }
}

// MARK: - Decoder view

struct DecView {
    var prox = false
    var pressure = 0
    var maxP = 1
    var eraser = false
    var mouse = false
    var s1 = false
    var s2 = false
    var tool: ToolIdentity?
    var pad: PadState?
    var touchCount = 0
    var sawPen = false
    var sawPad = false
    var sawTouch = false
    var enterThisReport: ToolIdentity?

    var contact: Bool { prox && !mouse && Double(pressure) / Double(maxP) > 0.004 }

    mutating func apply(_ events: [TabletEvent]) {
        sawPen = false; sawPad = false; sawTouch = false
        for e in events {
            switch e {
            case .pen(let p):
                sawPen = true
                prox = p.inProximity
                pressure = p.pressure; maxP = max(1, p.maxPressure)
                eraser = p.eraser; s1 = p.penButton1; s2 = p.penButton2
            case .tool(let t):
                if t.phase == .enter { tool = t.identity; enterThisReport = t.identity; mouse = t.identity.isMouse }
                else { prox = false }
            case .pad(let s): pad = s; sawPad = true
            case .touch(let f): touchCount = f.contacts.count; sawTouch = true
            default: break
            }
        }
    }
}

// MARK: - Comparison

struct Sample {
    let idx: Int
    let time: Double
    let bytes: [UInt8]
    let oProx: Bool, dProx: Bool
    let oTouch: Bool, dTouch: Bool
    let appRuleOnOracle: Bool
    let oPressure: Int, dPressure: Int, dMax: Int
    let oTool: ToolKind, dEraser: Bool
    let oS1: Bool, oS2: Bool, dS1: Bool, dS2: Bool
    let dSaw: Bool
}

struct Press { let start: Int; let end: Int }   // sample indices, inclusive

func presses(_ v: [Bool]) -> [Press] {
    var out: [Press] = [], s: Int?
    for (i, x) in v.enumerated() {
        if x, s == nil { s = i }
        if !x, let a = s { out.append(Press(start: a, end: i - 1)); s = nil }
    }
    if let a = s { out.append(Press(start: a, end: v.count - 1)) }
    return out
}

func overlaps(_ a: Press, _ b: Press) -> Bool { a.start <= b.end && b.start <= a.end }

struct Example { let label: String; let text: String }

struct FileResult {
    var name = ""
    var family = ""
    var format = ""
    var confidence = ""
    var note = ""
    var penReports = 0
    var contactDisagree = 0
    var contactEarlyOrLate = 0      // decoder touching while the firmware isn't
    var contactMissing = 0          // firmware touching while the decoder isn't
    var thresholdOnly = 0           // differs only by 0.004 vs the kernel's rule
    var oPresses = 0, dPresses = 0, merged = 0, split = 0, phantom = 0, missed = 0
    var proxDisagree = 0, proxLongRuns = 0, oEnters = 0, dEnters = 0
    var eraserDisagree = 0
    var buttonDisagree = 0
    var buttonReleaseLag = 0      // decoder holds a released barrel button for a few reports
    var pressureMismatch = 0, pressureMaxDiff = 0.0
    var toolIDMismatch = 0, toolEnters = 0
    var silentPen = 0
    var padReports = 0, padCountDisagree = 0, padSilent = 0, ringDisagree = 0, stripDisagree = 0
    var padMap: [String: Int] = [:]
    var touchReports = 0, touchDisagree = 0
    var examples: [Example] = []
    var score: Int { contactDisagree - thresholdOnly + 5 * (merged + split + phantom + missed) + proxLongRuns * 3 + eraserDisagree + buttonDisagree - buttonReleaseLag + pressureMismatch + 5 * toolIDMismatch + padCountDisagree + ringDisagree + stripDisagree + touchDisagree }
}

var maxExamples = 4
var verbose = false

func run(_ rec: Recording) -> FileResult {
    var res = FileResult(name: rec.name)
    let penPID = rec.pids.values.first { WacomDeviceRegistry.spec(for: $0)?.maxPressure ?? 0 > 0 } ?? rec.pids[0] ?? -1
    guard let spec = WacomDeviceRegistry.spec(for: penPID) else { res.note = String(format: "no registry row for 0x%04X", penPID); return res }
    res.family = "\(spec.format)"; res.format = "\(spec.format)"; res.confidence = "\(spec.confidence)"
    var oracles: [Int: Oracle] = [:]
    var decoders: [Int: DeviceDecoder] = [:]
    var views: [Int: DecView] = [:]
    for (dev, pid) in rec.pids {
        let kpid = pid == 0x5E ? 0x5E : penPID
        guard let kind = kernelKind(kpid) else { res.note = String(format: "no kernel oracle for 0x%04X", kpid); return res }
        oracles[dev] = Oracle(kind: kind)
        if pid == 0x5E, let t = DeviceDecoder.fixedLayoutTouch(productID: pid, digitizer: spec.digitizerSpec, family: spec.family) {
            decoders[dev] = t.decoder
        } else {
            decoders[dev] = spec.makeDecoder()
        }
        views[dev] = DecView()
    }
    if oracles.isEmpty { oracles[0] = Oracle(kind: kernelKind(penPID)!); decoders[0] = spec.makeDecoder(); views[0] = DecView() }
    let kmax = kernelPressureMax(kernelKind(penPID)!)

    var samples: [Sample] = []
    var lastFwButton = -100
    var proxRun = 0
    var proxRunStart = -1
    func flushProxRun() {
        if proxRun > 3 { res.proxLongRuns += 1 }
        if proxRun > 3, res.examples.filter({ $0.label == "prox" }).count < maxExamples, proxRunStart >= 0 {
            let s = samples[proxRunStart]
            res.examples.append(Example(label: "prox", text: String(format: "#%d t=%.3f run %d reports kernel prox=%@ decoder prox=%@  %@", s.idx, s.time, proxRun, "\(s.oProx)", "\(s.dProx)", hex(s.bytes))))
        }
        proxRun = 0; proxRunStart = -1
    }

    for (i, ev) in rec.events.enumerated() {
        guard var o = oracles[ev.dev], var dec = decoders[ev.dev], var v = views[ev.dev] else { continue }
        let obs = o.step(ev.bytes)
        let events = ev.bytes.withUnsafeBufferPointer { dec.events(HIDReport(pointer: $0.baseAddress!, count: $0.count)) }
        v.apply(events)
        oracles[ev.dev] = o; decoders[ev.dev] = dec; views[ev.dev] = v

        var penObs: PenObs?, padObs: PadObs?
        switch obs {
        case .pen(let p): penObs = p
        case .pad(let p): padObs = p
        case .penAndPad(let p, let q): penObs = p; padObs = q
        case .touch(let n):
            res.touchReports += 1
            if n != v.touchCount {
                res.touchDisagree += 1
                if res.examples.filter({ $0.label == "touch" }).count < maxExamples {
                    res.examples.append(Example(label: "touch", text: String(format: "#%d t=%.3f kernel contacts %d decoder %d%@  %@", i, ev.time, n, v.touchCount, v.sawTouch ? "" : " (no touch event)", hex(Array(ev.bytes.prefix(32))))))
                }
            }
        case .ignored: break
        }

        if let p = penObs, p.tool != .mouse, p.tool != .lens {
            defer { views[ev.dev]!.enterThisReport = nil }
            res.penReports += 1
            if !v.sawPen { res.silentPen += 1 }
            if p.entered { res.oEnters += 1 }
            if let e = v.enterThisReport {
                res.dEnters += 1
                if case .intuos = o.kind, p.toolID != 0 {
                    res.toolEnters += 1
                    let id = p.toolID
                    let candidates: Set<Int> = [id & 0xFFFF, (id >> 4) & 0xF000 | (id & 0xFFF)]
                    let eraserOK = e.isEraser == (p.tool == .eraser)
                    if !candidates.contains(Int(e.toolCode)) || !eraserOK {
                        res.toolIDMismatch += 1
                        res.examples.append(Example(label: "toolid", text: String(format: "#%d kernel id 0x%X serial 0x%llX %@ vs decoder code 0x%X serial 0x%X eraser %@", i, id, p.serial, p.tool.rawValue, e.toolCode, e.serial, "\(e.isEraser)")))
                    }
                }
            }
            let oTouch = p.prox && p.touch
            let appRule = p.prox && Double(p.pressure) / Double(kmax) > 0.004
            let s = Sample(idx: i, time: ev.time, bytes: ev.bytes, oProx: p.prox, dProx: v.prox, oTouch: oTouch, dTouch: v.contact,
                           appRuleOnOracle: appRule, oPressure: p.pressure, dPressure: v.pressure, dMax: v.maxP,
                           oTool: p.tool, dEraser: v.eraser, oS1: p.s1, oS2: p.s2, dS1: v.s1, dS2: v.s2, dSaw: v.sawPen)
            samples.append(s)

            if s.oProx != s.dProx {
                res.proxDisagree += 1
                if proxRun == 0 { proxRunStart = samples.count - 1 }
                proxRun += 1
            } else { flushProxRun() }

            if s.oTouch != s.dTouch {
                res.contactDisagree += 1
                if s.dTouch { res.contactEarlyOrLate += 1 } else { res.contactMissing += 1 }
                // Same raw pressure, different threshold: kernel says > 10, the app > 0.004.
                let sameValue = abs(Double(s.dPressure) / Double(s.dMax) - Double(s.oPressure) / Double(kmax)) < 0.002
                let kernelRule: Bool = { if case .intuos = o.kind { return true }; if case .dtus = o.kind { return true }; return false }()
                if kernelRule && sameValue && s.appRuleOnOracle == s.dTouch { res.thresholdOnly += 1 }
                else if res.examples.filter({ $0.label == "contact" }).count < maxExamples {
                    res.examples.append(Example(label: "contact", text: String(format: "#%d t=%.3f firmware touch=%@ p=%d | decoder p=%d/%d contact=%@  %@", i, ev.time, "\(s.oTouch)", s.oPressure, s.dPressure, s.dMax, "\(s.dTouch)", hex(ev.bytes))))
                }
            }
            if s.oProx && s.dProx {
                if (s.oTool == .eraser) != s.dEraser {
                    res.eraserDisagree += 1
                    if res.examples.filter({ $0.label == "eraser" }).count < maxExamples {
                        res.examples.append(Example(label: "eraser", text: String(format: "#%d t=%.3f kernel tool %@ decoder eraser=%@  %@", i, ev.time, s.oTool.rawValue, "\(s.dEraser)", hex(ev.bytes))))
                    }
                }
                if s.oS1 || s.oS2 { lastFwButton = samples.count - 1 }
                if s.oS1 != s.dS1 || s.oS2 != s.dS2 {
                    res.buttonDisagree += 1
                    let lag = !s.oS1 && !s.oS2 && samples.count - 1 - lastFwButton <= 7
                    if lag { res.buttonReleaseLag += 1 }
                    if !lag, res.examples.filter({ $0.label == "button" }).count < maxExamples {
                        res.examples.append(Example(label: "button", text: String(format: "#%d t=%.3f kernel s1=%@ s2=%@ decoder s1=%@ s2=%@  %@", i, ev.time, "\(s.oS1)", "\(s.oS2)", "\(s.dS1)", "\(s.dS2)", hex(ev.bytes))))
                    }
                }
                if s.oTouch || s.dTouch {
                    let diff = abs(Double(s.dPressure) / Double(s.dMax) - Double(s.oPressure) / Double(kmax))
                    if diff > 0.01 {
                        res.pressureMismatch += 1
                        if diff > res.pressureMaxDiff {
                            res.pressureMaxDiff = diff
                            res.examples.removeAll { $0.label == "pressure" }
                            res.examples.append(Example(label: "pressure", text: String(format: "#%d t=%.3f kernel %d/%d decoder %d/%d  %@", i, ev.time, s.oPressure, kmax, s.dPressure, s.dMax, hex(ev.bytes))))
                        }
                    }
                }
            }
        }

        if let q = padObs {
            res.padReports += 1
            let dButtons = v.pad.map { $0.buttons.enumerated().filter { $0.1 }.map { $0.0 } } ?? []
            let dRingButtons = v.pad.map { $0.rings.enumerated().filter { $0.1.buttonDown }.map { 200 + $0.0 } } ?? []
            let dAll = dButtons + dRingButtons
            if !v.sawPad && !(q.buttons.isEmpty && dAll.isEmpty) { res.padSilent += 1 }
            if q.buttons.count != dAll.count {
                res.padCountDisagree += 1
                if res.examples.filter({ $0.label == "pad" }).count < maxExamples {
                    res.examples.append(Example(label: "pad", text: String(format: "#%d t=%.3f kernel buttons %@ decoder %@  %@", i, ev.time, "\(q.buttons)", "\(dAll)", hex(ev.bytes))))
                }
            }
            if q.buttons.count == 1, dAll.count == 1 { res.padMap["\(q.buttons[0])→\(dAll[0])", default: 0] += 1 }
            // Rings and strips the decoder reports where the kernel reads none.
            if let pad = v.pad {
                for r in q.rings.count..<max(q.rings.count, pad.rings.count) where pad.rings[r].position != nil {
                    res.ringDisagree += 1
                    if res.examples.filter({ $0.label == "ring" }).count < maxExamples {
                        res.examples.append(Example(label: "ring", text: String(format: "#%d t=%.3f ring %d kernel has none, decoder %d  %@", i, ev.time, r, pad.rings[r].position!, hex(ev.bytes))))
                    }
                }
                for k in q.strips.count..<max(q.strips.count, pad.strips.count) where pad.strips[k].position != nil { res.stripDisagree += 1 }
            }
            for (r, kv) in q.rings.enumerated() {
                let dv: Int?? = v.pad.map { r < $0.rings.count ? $0.rings[r].position : nil }
                let dpos = dv ?? nil
                if (kv != nil) != (dpos != nil) || (kv != nil && dpos != nil && kv! != dpos!) {
                    res.ringDisagree += 1
                    if res.examples.filter({ $0.label == "ring" }).count < maxExamples {
                        res.examples.append(Example(label: "ring", text: String(format: "#%d t=%.3f ring %d kernel %@ decoder %@  %@", i, ev.time, r, kv.map { "\($0)" } ?? "none", dpos.map { "\($0)" } ?? "none", hex(ev.bytes))))
                    }
                }
            }
            for (k, kv) in q.strips.enumerated() {
                let dpos = v.pad.flatMap { k < $0.strips.count ? $0.strips[k].position : nil }
                if (kv != 0) != (dpos != nil) {
                    res.stripDisagree += 1
                    if res.examples.filter({ $0.label == "strip" }).count < maxExamples {
                        res.examples.append(Example(label: "strip", text: String(format: "#%d t=%.3f strip %d kernel 0x%04X decoder %@  %@", i, ev.time, k, kv, dpos.map { "\($0)" } ?? "none", hex(ev.bytes))))
                    }
                }
            }
        }
    }
    flushProxRun()

    // Presses: maximal runs of contact across pen samples.
    let op = presses(samples.map { $0.oTouch }), dp = presses(samples.map { $0.dTouch })
    res.oPresses = op.count; res.dPresses = dp.count
    for o in op {
        let n = dp.filter { overlaps($0, o) }.count
        if n == 0 { res.missed += 1 }
        if n > 1 { res.split += 1; addPressExample(&res, "split", o, samples) }
    }
    for d in dp {
        let n = op.filter { overlaps($0, d) }.count
        if n == 0 { res.phantom += 1; addPressExample(&res, "phantom", d, samples) }
        if n > 1 { res.merged += 1; addPressExample(&res, "merged", d, samples) }
    }
    return res
}

func addPressExample(_ res: inout FileResult, _ label: String, _ p: Press, _ samples: [Sample]) {
    guard res.examples.filter({ $0.label == label }).count < maxExamples else { return }
    let lo = max(0, p.start - 1), hi = min(samples.count - 1, p.end + 1)
    var lines = [String(format: "samples %d–%d (t=%.3f–%.3f):", p.start, p.end, samples[p.start].time, samples[p.end].time)]
    let span = Array(lo...hi)
    let shown = span.count <= 12 ? span : Array(span.prefix(6)) + Array(span.suffix(6))
    for j in shown {
        let s = samples[j]
        lines.append(String(format: "      fw touch=%d p=%4d | dec contact=%d p=%4d  %@", s.oTouch ? 1 : 0, s.oPressure, s.dTouch ? 1 : 0, s.dPressure, hex(s.bytes)))
    }
    res.examples.append(Example(label: label, text: lines.joined(separator: "\n")))
}

// MARK: - Main

var paths: [String] = []
var args = CommandLine.arguments.dropFirst()
while let a = args.first {
    args = args.dropFirst()
    if a == "-v" { verbose = true }
    else if a == "-n", let n = args.first { maxExamples = Int(n) ?? 4; args = args.dropFirst() }
    else { paths.append(a) }
}

var results: [FileResult] = []
for path in paths { results.append(run(parse(path))) }

for r in results {
    if !r.note.isEmpty { print("\(r.name): \(r.note)\n"); continue }
    print("""
    \(r.name) [\(r.format), \(r.confidence)] score \(r.score)
      pen reports \(r.penReports) (decoder silent on \(r.silentPen))
      contact: \(r.contactDisagree) reports disagree (decoder early/late \(r.contactEarlyOrLate), decoder missing \(r.contactMissing); threshold-only \(r.thresholdOnly))
      presses: firmware \(r.oPresses), decoder \(r.dPresses); merged \(r.merged), split \(r.split), phantom \(r.phantom), missed \(r.missed)
      proximity: \(r.proxDisagree) reports disagree, \(r.proxLongRuns) runs longer than 3 reports; enters firmware \(r.oEnters) decoder \(r.dEnters)
      eraser \(r.eraserDisagree), side buttons \(r.buttonDisagree) (release lag \(r.buttonReleaseLag)), pressure off by >1% \(r.pressureMismatch) (max \(String(format: "%.3f", r.pressureMaxDiff))), tool IDs \(r.toolIDMismatch)/\(r.toolEnters)
      pad reports \(r.padReports): count disagree \(r.padCountDisagree), decoder silent \(r.padSilent), ring \(r.ringDisagree), strip \(r.stripDisagree)
      touch reports \(r.touchReports): count disagree \(r.touchDisagree)
    """)
    if !r.padMap.isEmpty { print("  pad map (kernel→decoder): " + r.padMap.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")) }
    if verbose || r.score > 0 {
        for e in r.examples { print("    [\(e.label)] \(e.text)") }
    }
    print("")
}

// Family ranking
var byFamily: [String: [FileResult]] = [:]
for r in results where r.note.isEmpty { byFamily[r.family, default: []].append(r) }
print("== Families, worst first (score per 1000 pen+pad+touch reports)")
let ranked = byFamily.map { (fam, rs) -> (String, Double, Int, [FileResult]) in
    let total = rs.reduce(0) { $0 + $1.penReports + $1.padReports + $1.touchReports }
    let score = rs.reduce(0) { $0 + $1.score }
    return (fam, total > 0 ? Double(score) * 1000 / Double(total) : 0, score, rs)
}.sorted { $0.1 > $1.1 }
for (fam, rate, score, rs) in ranked {
    print(String(format: "%-10@ %8.1f  (score %d over %d recordings)", fam as NSString, rate, score, rs.count))
}
