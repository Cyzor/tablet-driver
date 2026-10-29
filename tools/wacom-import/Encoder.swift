// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Turns one tablet's report into the values MockTab stores for the tablet,
// each pen, and each app, keyed by storage name. MockTab's own setting
// types and import decoder produce them, so they match what the app writes.
// Writes nothing.
//
// It covers only controls the backup lists at a checked position; the rest
// keep their MockTab settings. A listed control with no MockTab equivalent
// becomes None or Off. An unverified value is never written.

import AppKit
import Foundation

struct EncodedTablet {
    struct Pen {
        /// MockTab's tool ID for the pen, "0x{SERIAL}".
        let id: String
        let serial: UInt32
        let nickname: String?
        var values: [String: Any]
    }

    struct App {
        let bundleID: String
        let appName: String
        var values: [String: Any]
    }

    let productID: Int
    let nickname: String?
    var device: [String: Any] = [:]
    var pens: [Pen] = []
    var apps: [App] = []
    /// Mapped lines it leaves out: unverified, or with no setting.
    var leftOut: [Line] = []
}

enum EncodeError: Error, CustomStringConvertible, Equatable {
    case noProductID
    /// These pens disagree on the app's settings; --pen picks one.
    case pensDisagree(app: String, pens: [String])

    var description: String {
        switch self {
        case .noProductID: return "The backup names no product ID for this tablet."
        case .pensDisagree(let app, let pens):
            return "\(app) has different pen settings for \(pens.joined(separator: ", ")). Pick one with --pen."
        }
    }
}

enum WacomEncoder {
    static func encode(_ t: TabletReport, pen chosen: UInt32? = nil) throws -> EncodedTablet {
        guard let pid = t.productID else { throw EncodeError.noProductID }
        var out = EncodedTablet(productID: pid, nickname: t.nickname)
        guard let base = t.apps.first else { return out }

        let baseControls = Controls(base, leftOut: &out.leftOut)
        out.device = decoded(baseControls.storedSettings(complete: true))

        for section in base.sections {
            guard let serial = section.pen else { continue }
            guard serial != 0 else {
                out.leftOut += section.lines.filter { !$0.outcome.isSkipped }
                continue
            }
            var settings = PenSettings()
            var nickname: String?
            for line in usable(section.lines, leftOut: &out.leftOut) {
                if case .nickname(let n) = line.action { nickname = n } else { settings.add(line) }
            }
            settings.clearSkipped(section.lines)
            out.pens.append(.init(id: String(format: "0x%08X", serial), serial: serial,
                                  nickname: nickname, values: decoded(settings.stored)))
        }

        for app in t.apps.dropFirst() {
            guard let bundleID = app.bundleID, !app.sections.isEmpty, app.notes.isEmpty else { continue }
            var stored = Controls(app, over: baseControls, leftOut: &out.leftOut).storedSettings(complete: false)
            // MockTab's per-app pen settings cover every pen on the tablet.
            var byPen: [UInt32: PenSettings] = [:]
            for section in app.sections {
                guard let serial = section.pen, serial != 0 else { continue }
                var settings = PenSettings()
                for line in usable(section.lines, leftOut: &out.leftOut) { settings.add(line) }
                settings.clearSkipped(section.lines)
                if !settings.isEmpty { byPen[serial] = settings }
            }
            if let pens = try pick(byPen, chosen: chosen, app: app.name) {
                stored.merge(pens.stored) { a, _ in a }
            }
            let values = decoded(stored)
            if !values.isEmpty { out.apps.append(.init(bundleID: bundleID, appName: app.name, values: values)) }
        }
        return out
    }

    /// Mapped lines it may write: exact or approximate, with a setting.
    static func usable(_ lines: [Line], leftOut: inout [Line]) -> [Line] {
        var keep: [Line] = []
        for line in lines {
            guard case .mapped(_, let c) = line.outcome else { continue }
            if c == .unverified || line.action == nil || line.setting == nil {
                leftOut.append(line)
            } else {
                keep.append(line)
            }
        }
        return keep
    }

    static func pick(_ byPen: [UInt32: PenSettings], chosen: UInt32?, app: String) throws -> PenSettings? {
        guard let first = byPen.values.first else { return nil }
        if let chosen { return byPen[chosen] }
        if byPen.values.allSatisfy({ $0.same(as: first) }) { return first }
        throw EncodeError.pensDisagree(app: app, pens: byPen.keys.sorted().map { String(format: "0x%08X", $0) })
    }

    /// MockTab's import decoder, so stored values are the app's own.
    static func decoded(_ stored: [String: Any]) -> [String: Any] {
        ConfigurationImporter.decodeStoredSettings(stored)
    }

    // MARK: - MockTab values

    static func buttonBinding(_ b: Binding) -> ButtonBinding {
        switch b {
        case .kind(let raw):
            return ButtonBinding(kind: ButtonBinding.Kind(rawValue: raw) ?? .none)
        case .modifiers(let m):
            return ButtonBinding(modifierOnly: nsFlags(m))
        case .key(let code, let m, let label):
            return ButtonBinding(kind: .keyCombo, keyCode: code, modifierFlags: cgFlags(m).rawValue, keyLabel: label)
        }
    }

    static func nsFlags(_ m: KeyModifiers) -> NSEvent.ModifierFlags {
        var f = NSEvent.ModifierFlags()
        if m.contains(.command) { f.insert(.command) }
        if m.contains(.option) { f.insert(.option) }
        if m.contains(.shift) { f.insert(.shift) }
        if m.contains(.control) { f.insert(.control) }
        return f
    }

    static func cgFlags(_ m: KeyModifiers) -> CGEventFlags {
        var f = CGEventFlags()
        if m.contains(.command) { f.insert(.maskCommand) }
        if m.contains(.option) { f.insert(.maskAlternate) }
        if m.contains(.shift) { f.insert(.maskShift) }
        if m.contains(.control) { f.insert(.maskControl) }
        return f
    }

    static func slot(_ mode: RingMode, label: String?) -> ControlSlot {
        var s = ControlSlot()
        switch mode {
        case .scroll: s.action = .scroll
        case .rotate: s.action = .rotate
        case .off: s.action = .off
        case .skip: s.action = .skip
        case .keys(let cw, let ccw):
            s.action = .keyPress
            s.cwBinding = buttonBinding(cw)
            s.ccwBinding = buttonBinding(ccw)
        }
        s.label = label ?? s.action.displayLabel
        return s
    }

    static let offSlot = slot(.off, label: nil)

    /// MockTab's curve runs from its threshold to full pressure. A Bezier
    /// whose control points coincide passes through B(0.5) = 0.75c + 0.125,
    /// so c puts Wacom's midpoint on the curve.
    static func curve(start: Double, midX: Double, midY: Double) -> (threshold: Double, p: [Double]) {
        let u = start < 1 ? (midX - start) / (1 - start) : 0.5
        let c = [u, midY].map { min(max(($0 - 0.125) / 0.75, 0), 1) }
        return (min(max(start, 0), 0.95), c)
    }

    static func jsonObject<T: Encodable>(_ value: T) -> Any? {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    static func put(_ b: ButtonBinding, _ key: String, into d: inout [String: Any]) {
        d[key] = b.displayLabel
        d[key + "Key"] = b.encoded
    }
}

/// Pen settings in export shape, keyed by storage name.
struct PenSettings {
    private(set) var stored: [String: Any] = [:]
    private var signature: [String: String] = [:]

    var isEmpty: Bool { stored.isEmpty }

    mutating func add(_ line: Line) {
        switch (line.action, line.setting) {
        case (.binding(let b)?, .binding(let key)?):
            put(WacomEncoder.buttonBinding(b), key)
        case (.pressure(let start, let x, let y)?, .pressure?):
            let fit = WacomEncoder.curve(start: start, midX: x, midY: y)
            stored["pressureThreshold"] = fit.threshold
            stored["pressureCurve"] = ["p1": fit.p, "p2": fit.p]
            signature["pressure"] = "\(fit.threshold) \(fit.p)"
        default:
            break
        }
    }

    /// A button with no MockTab equivalent becomes None, as ExpressKeys do.
    mutating func clearSkipped(_ lines: [Line]) {
        for line in lines where line.outcome.isSkipped {
            if case .binding(let key)? = line.setting { put(.none, key) }
        }
    }

    private mutating func put(_ b: ButtonBinding, _ key: String) {
        WacomEncoder.put(b, key, into: &stored)
        signature[key] = b.encoded
    }

    func same(as other: PenSettings) -> Bool { signature == other.signature }
}

/// ExpressKeys, ring and dial keys, ring modes, and the tablet area for one
/// app, in export shape. An app starts from All applications' controls.
struct Controls {
    var keys = [ButtonBinding](repeating: .none, count: 16)
    var keysChanged = false
    var singles: [String: ButtonBinding] = [:]
    var ring: [Int: ControlSlot] = [:]
    var ringCount = 0
    var ringChanged = false
    var dials: [Int: [Int: ControlSlot]] = [:]
    var dialCounts: [Int: Int] = [:]
    var dialsChanged = false
    var area: (Double, Double, Double, Double)?

    init(_ app: AppReport, over base: Controls? = nil, leftOut: inout [Line]) {
        if let base {
            keys = base.keys
            ring = base.ring
            ringCount = base.ringCount
            dials = base.dials
            dialCounts = base.dialCounts
        }
        for section in app.sections where section.pen == nil {
            // Every mode the backup lists counts, imported or not.
            for line in section.lines {
                switch line.setting {
                case .ringSlot(let i)?: ringCount = max(ringCount, i + 1)
                case .rotarySlot(let d, let i)?: dialCounts[d] = max(dialCounts[d] ?? 0, i + 1)
                default: break
                }
            }
            for line in section.lines {
                let imported = WacomEncoder.usable([line], leftOut: &leftOut).first
                switch (imported?.action, line.setting) {
                case (.binding(let b)?, .expressKey(let i)?) where i < 16:
                    keys[i] = WacomEncoder.buttonBinding(b)
                    keysChanged = true
                case (_, .expressKey(let i)?) where i < 16:
                    // A key the import can't carry becomes None, as does an
                    // unverified one: None is MockTab's default for keys.
                    keys[i] = .none
                    keysChanged = true
                case (.binding(let b)?, .binding(let key)?):
                    singles[key] = WacomEncoder.buttonBinding(b)
                case (_, .binding(let key)?) where !line.outcome.isUnverified:
                    singles[key] = ButtonBinding.none
                case (.ring(let m, let label)?, .ringSlot(let i)?):
                    ring[i] = WacomEncoder.slot(m, label: label)
                    ringChanged = true
                case (_, .ringSlot(let i)?):
                    ring[i] = WacomEncoder.offSlot
                    ringChanged = true
                case (.ring(let m, let label)?, .rotarySlot(let d, let i)?):
                    dials[d, default: [:]][i] = WacomEncoder.slot(m, label: label)
                    dialsChanged = true
                case (_, .rotarySlot(let d, let i)?):
                    dials[d, default: [:]][i] = WacomEncoder.offSlot
                    dialsChanged = true
                case (.area(let x, let y, let w, let h)?, .tabletArea?):
                    area = (x, y, w, h)
                default:
                    break
                }
            }
        }
    }

    /// Only the categories this app's sections filled. `complete` (All
    /// applications) also starts the ring and dials on their first mode.
    func storedSettings(complete: Bool) -> [String: Any] {
        var d: [String: Any] = [:]
        if keysChanged {
            d["expressKeyBindings"] = keys.map(\.displayLabel)
            d["expressKeyBindingsKey"] = keys.map(\.encoded)
        }
        for (key, b) in singles { WacomEncoder.put(b, key, into: &d) }
        if ringCount > 0, ringChanged {
            let slots = (0..<ringCount).map { ring[$0] ?? WacomEncoder.offSlot }
            d["touchRingSlotsJSON"] = WacomEncoder.jsonObject(slots)
            if complete { d["touchRingActiveSlotIndex"] = 0 }
        }
        if !dialCounts.isEmpty, dialsChanged {
            let configs = (0...(dialCounts.keys.max() ?? 0)).map { d in
                RotaryConfig(slots: (0..<(dialCounts[d] ?? 0)).map { dials[d]?[$0] ?? WacomEncoder.offSlot },
                             activeSlotIndex: 0)
            }
            d["rotariesJSON"] = WacomEncoder.jsonObject(RotarySet(controls: configs))
            if complete { d["touchRingActiveSlotIndex"] = 0; d["touchRingActiveSlotIndex2"] = 0 }
        }
        if let (x, y, w, h) = area {
            d["activeAreaX"] = x
            d["activeAreaY"] = y
            d["activeAreaWidth"] = w
            d["activeAreaHeight"] = h
        }
        return d
    }
}
