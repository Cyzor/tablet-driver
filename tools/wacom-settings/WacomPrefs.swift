// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reads a Wacom settings backup (a .wacomprefs folder from Wacom Center or
// Tablet Utility) and works out what each setting becomes in MockTab.
// Writes nothing.
//
// In the backup's com.wacom.wacomtablet.prefs, every XML element names its
// type, as in <Name type="integer">3</Name>, and arrays repeat ArrayElement.
// Keystrokes ("kestring") mix characters with &name; keys, or give a virtual
// key code as &vk=12:cc=31:kb=2b;.

import Foundation
import TabletKit

// MARK: - File

/// One element of the preferences file.
struct WacomNode {
    let name: String
    let type: String
    let text: String
    let children: [WacomNode]

    func node(_ path: String) -> WacomNode? {
        var n: WacomNode? = self
        for part in path.split(separator: "/") {
            n = n?.children.first { $0.name == part }
        }
        return n
    }

    func string(_ path: String) -> String? { node(path)?.text }
    func int(_ path: String) -> Int? { string(path).flatMap { Int($0) } }
    var elements: [WacomNode] { children.filter { $0.name == "ArrayElement" } }

    init(name: String, type: String = "", text: String = "", children: [WacomNode] = []) {
        self.name = name
        self.type = type
        self.text = text
        self.children = children
    }

    init(_ e: XMLElement) {
        let kids = (e.children ?? []).compactMap { $0 as? XMLElement }
        self.init(
            name: e.name ?? "", type: e.attribute(forName: "type")?.stringValue ?? "",
            text: kids.isEmpty ? (e.stringValue ?? "") : "", children: kids.map(WacomNode.init))
    }
}

struct WacomBackup {
    /// Driver version from version.plist, as Wacom shows it.
    let driverVersion: String?
    let root: WacomNode

    enum LoadError: Error, CustomStringConvertible {
        case notABackup(String)
        case unreadable(String)

        var description: String {
            switch self {
            case .notABackup(let p): return "\(p) is not a Wacom settings backup: no com.wacom.wacomtablet.prefs inside."
            case .unreadable(let p): return "Couldn't read \(p) as XML."
            }
        }
    }

    /// Accepts the .wacomprefs folder or the prefs file inside it.
    static func load(_ url: URL) throws -> WacomBackup {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
        let prefs = folder.appendingPathComponent("com.wacom.wacomtablet.prefs")
        guard FileManager.default.fileExists(atPath: prefs.path) else { throw LoadError.notABackup(url.path) }
        guard let doc = try? XMLDocument(contentsOf: prefs, options: []), let root = doc.rootElement() else {
            throw LoadError.unreadable(prefs.path)
        }
        return WacomBackup(
            driverVersion: driverVersion(folder.appendingPathComponent("version.plist")), root: WacomNode(root))
    }

    private static func driverVersion(_ url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let major = p["VersionKeyMajor"] as? Int, let minor = p["VersionKeyMinor"] as? Int
        else { return nil }
        // 6.4.15-1 is Major.Minor.Variation-Build.
        var v = "\(major).\(minor)"
        if let variation = p["VersionKeyVariation"] as? Int { v += ".\(variation)" }
        if let build = p["VersionKeyBuild"] as? Int { v += "-\(build)" }
        return v
    }
}

// MARK: - Keystrokes

struct KeyModifiers: OptionSet, Hashable {
    let rawValue: Int
    static let control = KeyModifiers(rawValue: 1)
    static let option = KeyModifiers(rawValue: 2)
    static let shift = KeyModifiers(rawValue: 4)
    static let command = KeyModifiers(rawValue: 8)

    /// In the order macOS menus show them.
    var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// A keystroke resolved to a macOS virtual key code, as MockTab stores it.
struct ResolvedKey: Equatable {
    var keyCode: UInt16?
    var modifiers: KeyModifiers
    /// The key as MockTab labels it, which can differ from Wacom's character:
    /// [ on a German layout is ⌥5.
    var label: String
    var spacebar = false
    /// The keystroke as Wacom recorded it, for the report.
    var recorded = ""
}

enum Keystroke {
    /// Keys MockTab can record, by Wacom's name. `delete` is Forward Delete;
    /// `backspace` is the key labeled Delete.
    static let namedKeys: [String: (UInt16, String)] = {
        var t: [String: (UInt16, String)] = [
            "tab": (48, "⇥"), "enter": (36, "↩"), "return": (36, "↩"), "space": (49, "Space"),
            "backspace": (51, "⌫"), "delete": (117, "⌦"), "esc": (53, "⎋"),
            "up": (126, "↑"), "down": (125, "↓"), "left": (123, "←"), "right": (124, "→"),
            "pageup": (116, "⇞"), "pagedown": (121, "⇟"), "home": (115, "↖"), "end": (119, "↘"),
            "kp=": (81, "Keypad ="), "kp/": (75, "Keypad /"), "kp*": (67, "Keypad *"),
            "kp-": (78, "Keypad -"), "kp+": (69, "Keypad +"), "kp.": (65, "Keypad ."),
            "kpenter": (76, "⌅"),
        ]
        let keypad: [UInt16] = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        for (i, code) in keypad.enumerated() { t["kp\(i)"] = (code, "Keypad \(i)") }
        let fkeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (i, code) in fkeys.enumerated() { t["f\(i + 1)"] = (code, "F\(i + 1)") }
        return t
    }()

    /// Characters Wacom writes by name.
    static let namedCharacters: [String: Character] = [
        "rsqbracket": "]", "lsqbracket": "[", "amp": "&", "semicolon": ";",
    ]

    static let modifierNames: [String: KeyModifiers] = [
        "command": .command, "option": .option, "alt": .option, "shift": .shift, "control": .control,
    ]

    enum Result: Equatable {
        case key(ResolvedKey, exact: Bool)
        case modifiersOnly(KeyModifiers)
        case empty
        case unsupported(String)
    }

    /// Splits a kestring into modifiers and one key. More than one key makes
    /// a typed sequence, which one button can't send.
    static func parse(_ s: String, layout: LayoutLookup) -> Result {
        var mods = KeyModifiers()
        var keys: [(ResolvedKey, Bool)] = []
        var characters: [Character] = []
        var spacebarHold = false
        var rest = Substring(s)
        while let c = rest.first {
            if c == "&", let end = rest.firstIndex(of: ";") {
                let token = String(rest[rest.index(after: rest.startIndex)..<end])
                rest = rest[rest.index(after: end)...]
                if let m = modifierNames[token] {
                    mods.insert(m)
                } else if token == "spacem" {
                    spacebarHold = true
                } else if token.hasPrefix("vk=") {
                    guard let k = virtualKey(token) else { return .unsupported("&\(token);") }
                    keys.append((k, true))
                } else if let (code, label) = namedKeys[token] {
                    keys.append((ResolvedKey(keyCode: code, modifiers: [], label: label, recorded: label), token != "enter"))
                } else if let ch = namedCharacters[token] {
                    characters.append(ch)
                } else {
                    return .unsupported("&\(token);")
                }
            } else {
                rest = rest.dropFirst()
                characters.append(c)
            }
        }
        // Find each character's key after reading every modifier: ⌘ can change it.
        keys += characters.map { character($0, command: mods.contains(.command), layout: layout) }
        if spacebarHold && keys.isEmpty && mods.isEmpty {
            return .key(ResolvedKey(keyCode: 49, modifiers: [], label: "Space", spacebar: true, recorded: "Space"), exact: true)
        }
        if keys.count > 1 { return .unsupported("key sequence \"\(s)\"") }
        guard let (first, exact) = keys.first else { return mods.isEmpty ? .empty : .modifiersOnly(mods) }
        var key = first
        key.modifiers.formUnion(mods)
        key.recorded = mods.symbols + key.recorded
        return .key(key, exact: exact)
    }

    /// &vk=12:cc=31:kb=2b;: key code and character code in hex.
    private static func virtualKey(_ token: String) -> ResolvedKey? {
        var fields: [String: String] = [:]
        for part in token.split(separator: ":") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        guard let vk = fields["vk"].flatMap({ UInt16($0, radix: 16) }) else { return nil }
        let label = fields["cc"].flatMap { UInt32($0, radix: 16) }.flatMap(Unicode.Scalar.init)
            .map { String($0).uppercased() } ?? "key \(vk)"
        return ResolvedKey(keyCode: vk, modifiers: [], label: label, recorded: label)
    }

    /// Finds a bare character on the keyboard layout, adding Shift or Option
    /// when the character needs them, which the Wacom recording may not have
    /// meant.
    private static func character(_ c: Character, command: Bool, layout: LayoutLookup) -> (ResolvedKey, Bool) {
        let label = keyCap(String(c))
        guard let k = layout(Character(String(c).lowercased()), command) ?? layout(c, command) else {
            return (ResolvedKey(keyCode: nil, modifiers: [], label: label, recorded: label), false)
        }
        return (ResolvedKey(keyCode: k.keyCode, modifiers: k.adds, label: k.label ?? label, recorded: label), k.exact)
    }
}

// MARK: - Mapping

enum Confidence: String {
    case exact
    case approximate
    /// Thin evidence; never written.
    case unverified
}

enum Outcome {
    case mapped(String, Confidence)
    case skipped(String)

    var isSkipped: Bool { if case .skipped = self { return true } else { return false } }
    var isUnverified: Bool { if case .mapped(_, .unverified) = self { return true } else { return false } }
}

/// What a mapped line asks of MockTab, in MockTab's terms but not its
/// types, so the report builds without the app.
enum Binding: Equatable {
    /// A `ButtonBinding.Kind` raw value with no key: leftClick, eraser, etc.
    case kind(String)
    case key(keyCode: UInt16, modifiers: KeyModifiers, label: String)
    case modifiers(KeyModifiers)
}

enum RingMode: Equatable {
    case scroll, rotate, off, skip
    case keys(cw: Binding, ccw: Binding)
}

enum Action: Equatable {
    case binding(Binding)
    /// A ring or dial mode, with the label Wacom shows for it.
    case ring(RingMode, label: String?)
    /// Wacom's three curve points as fractions of full pressure.
    case pressure(start: Double, midX: Double, midY: Double)
    case area(x: Double, y: Double, width: Double, height: Double)
    case nickname(String)
}

/// The MockTab setting a mapped line writes.
enum Setting: Equatable {
    /// A binding key: tipBinding, penButton1Binding, and so on.
    case binding(String)
    case expressKey(Int)
    /// A mode of the touch ring, from 0.
    case ringSlot(Int)
    /// A mode of a dial: which dial, then which mode, from 0.
    case rotarySlot(dial: Int, slot: Int)
    case pressure
    case tabletArea
    case toolNickname
}

struct Line {
    let control: String
    let wacom: String
    let outcome: Outcome
    var action: Action? = nil
    var setting: Setting? = nil
}

struct Section {
    let title: String
    var lines: [Line]
    var notes: [String] = []
    /// A pen section's serial; 0 when the pen has none.
    var pen: UInt32? = nil
}

struct AppReport {
    let name: String
    let bundleID: String?
    var sections: [Section]
    var notes: [String] = []
}

struct TabletReport {
    let modelName: String
    let wacomType: Int?
    /// The wired product ID. MockTab stores the tablet's settings under it,
    /// however the tablet connects.
    let productID: Int?
    /// The product ID Wacom saw last, when that was another connection.
    let lastConnectedAs: Int?
    let nickname: String?
    var apps: [AppReport]
    var notes: [String] = []
}

struct Report {
    let driverVersion: String?
    let formatVersion: Int?
    var tablets: [TabletReport]

    var lines: [Line] { tablets.flatMap { $0.apps.flatMap { $0.sections.flatMap(\.lines) } } }
}

enum WacomMapper {
    static func report(_ backup: WacomBackup, layout: LayoutLookup) -> Report {
        let root = backup.root
        let apps = applications(root)
        let tablets = (root.node("TabletArray")?.elements ?? []).map { tablet($0, apps: apps, layout: layout) }
        return Report(driverVersion: backup.driverVersion, formatVersion: root.int("ImportFileVersion"), tablets: tablets)
    }

    struct WacomApp {
        let index: Int
        let name: String
        let bundleID: String
        let path: String
        let removed: Bool
    }

    static func applications(_ root: WacomNode) -> [Int: WacomApp] {
        var apps: [Int: WacomApp] = [:]
        for a in root.node("OSInterface/ApplicationMap")?.children ?? [] {
            guard a.name.hasPrefix("AppID"), let i = Int(a.name.dropFirst(5)) else { continue }
            apps[i] = WacomApp(
                index: i, name: a.string("ApplicationName") ?? a.name,
                bundleID: a.string("ApplicationSecondaryId") ?? "",
                path: a.string("ApplicationLongName") ?? "",
                removed: a.string("ApplicationRemoved") == "true")
        }
        return apps
    }

    /// SensorID packs the USB vendor and product IDs (0x056A0357 is a
    /// PTH-660). Wacom keeps one entry per tablet and rewrites it for the
    /// last connection, wired or Bluetooth.
    static func productID(_ t: WacomNode) -> Int? {
        guard let id = t.int("SensorID"), id >> 16 == 0x056A else { return nil }
        return id & 0xFFFF
    }

    /// Wacom writes `\~106:0` for a name it fills in itself.
    static func customName(_ s: String?) -> String? {
        guard let s, !s.isEmpty, !s.hasPrefix("\\~") else { return nil }
        return s
    }

    static func tablet(_ t: WacomNode, apps: [Int: WacomApp], layout: LayoutLookup) -> TabletReport {
        let model = t.string("DefaultTabName") ?? t.string("TabletName") ?? "Unknown tablet"
        let name = t.string("TabletName")
        let seen = productID(t)
        let pid = seen.map(WacomDeviceRegistry.canonicalProductID)
        var report = TabletReport(
            modelName: model, wacomType: t.int("TabletType"), productID: pid,
            lastConnectedAs: seen != pid ? seen : nil,
            nickname: name != model ? customName(name) : nil, apps: [])
        if pid == nil { report.notes.append("No product ID in the backup, so --apply can't import this tablet.") }

        let containers = t.node("TabletControlContainerArray")?.elements ?? []
        let transducers = t.node("TabletTransducerArray")?.elements ?? []
        func app(_ n: WacomNode) -> Int { n.int("ApplicationAssociated") ?? 0 }

        let baseContainer = containers.first { app($0) == 0 }
        let baseTransducers = transducers.filter { app($0) == 0 }

        var base = AppReport(name: "All applications", bundleID: nil, sections: [])
        base.sections += baseTransducers.map { pen($0, against: nil, layout: layout) }
        if let c = baseContainer { base.sections += controls(c, against: nil, productID: pid, layout: layout) }
        if let area = mappingArea(t) { base.sections.append(area) }
        report.apps.append(base)

        let indices = Set(containers.map(app) + transducers.map(app)).subtracting([0]).sorted()
        let chosen = chosenEntries(indices.compactMap { apps[$0] })
        for i in indices {
            guard let a = apps[i] else {
                report.notes.append("App \(i) has settings but no entry in Wacom's app list; skipped.")
                continue
            }
            var r = AppReport(name: a.name, bundleID: a.bundleID.isEmpty ? nil : a.bundleID, sections: [])
            if a.removed {
                r.notes.append("Removed in Wacom's settings; skipped.")
            } else if a.bundleID.isEmpty {
                r.notes.append("No bundle ID, so MockTab can't match it to an app; skipped.")
            } else if chosen[a.bundleID] != i {
                r.notes.append("MockTab keeps one set per bundle ID, and another entry for this app wins; skipped.")
            } else {
                for tr in transducers where app(tr) == i {
                    let match = baseTransducers.first { sameTool($0, tr) }
                    let s = pen(tr, against: match, layout: layout)
                    if !s.lines.isEmpty { r.sections.append(s) }
                }
                if let c = containers.first(where: { app($0) == i }) {
                    r.sections += controls(c, against: baseContainer, productID: pid, layout: layout).filter { !$0.lines.isEmpty }
                }
                if r.sections.isEmpty { r.notes.append("Same as All applications.") }
            }
            report.apps.append(r)
        }
        return report
    }

    /// Wacom keeps an entry per installed version of an app, all with one
    /// bundle ID. Uses the installed one, else the newest.
    static func chosenEntries(_ apps: [WacomApp]) -> [String: Int] {
        var chosen: [String: Int] = [:]
        let installed = { (a: WacomApp) in !a.path.isEmpty && FileManager.default.fileExists(atPath: a.path) }
        for a in apps where !a.removed && !a.bundleID.isEmpty {
            guard let current = chosen[a.bundleID], let c = apps.first(where: { $0.index == current }) else {
                chosen[a.bundleID] = a.index
                continue
            }
            if installed(a) || !installed(c) { chosen[a.bundleID] = a.index }
        }
        return chosen
    }

    // MARK: Pens

    static func serial(_ tr: WacomNode) -> UInt32? {
        guard let seq = tr.string("TransducerID/Sequence").flatMap({ UInt64($0) }) else { return nil }
        return UInt32(truncatingIfNeeded: seq)
    }

    static func sameTool(_ a: WacomNode, _ b: WacomNode) -> Bool {
        a.string("TransducerID/Sequence") == b.string("TransducerID/Sequence")
            && a.string("TransducerID/Type") == b.string("TransducerID/Type")
    }

    /// Wacom button element, its label, and the MockTab setting it feeds.
    /// Button numbers follow the pen's switch order: barrel is the lower.
    static let penButtons: [(String, String, String)] = [
        ("TransducerTipButtonSettings", "Tip", "tipBinding"),
        ("TransducerEraserSettings", "Eraser", "eraserBinding"),
        ("TransducerLowerButtonSettings", "Lower button", "penButton1Binding"),
        ("TransducerUpperButtonSettings", "Upper button", "penButton2Binding"),
        ("TransducerThirdButtonSettings", "Third button", "penButton3Binding"),
    ]

    static func pen(_ tr: WacomNode, against base: WacomNode?, layout: LayoutLookup) -> Section {
        let code = tr.int("TransducerID/Type")
        var title = "Pen"
        var notes: [String] = []
        if let s = serial(tr), s != 0 {
            title += String(format: " 0x%08X", s)
            if let code { title += String(format: " (tool code 0x%X)", code) }
        } else if let code {
            title += String(format: " with tool code 0x%X, no serial", code)
            notes.append("No serial, so MockTab shares this pen's settings with every pen of its kind.")
        }
        var lines: [Line] = []
        if base == nil, let name = customName(tr.string("TransducerName")) {
            lines.append(Line(control: "Name", wacom: "\"\(name)\"", outcome: .mapped("tool nickname", .exact),
                              action: .nickname(name), setting: .toolNickname))
        }
        for (element, label, key) in penButtons {
            guard let b = tr.node(element), b.node("ButtonFunction") != nil else { continue }
            if let base, let other = base.node(element), sameButton(b, other) { continue }
            let (wacom, outcome, binding) = function(b, layout: layout)
            lines.append(Line(control: label, wacom: wacom, outcome: outcome.prefixed(key),
                              action: binding.map(Action.binding), setting: .binding(key)))
        }
        if let curve = tr.string("TransducerTipButtonSettings/PressureCurveControlPoint"),
           base?.string("TransducerTipButtonSettings/PressureCurveControlPoint") != curve {
            lines.append(pressure(curve))
        }
        return Section(title: title, lines: lines, notes: notes, pen: serial(tr) ?? 0)
    }

    static func pressure(_ s: String) -> Line {
        let v = s.split(separator: " ").compactMap { Double($0) }
        guard v.count == 6, v[4] > 0, v[5] > 0 else {
            return Line(control: "Tip feel", wacom: s, outcome: .skipped("unreadable curve"))
        }
        let threshold = v[0] / v[4] * 100
        let mid = String(format: "(%.2f, %.2f)", v[2] / v[4], v[3] / v[5])
        return Line(
            control: "Tip feel", wacom: String(format: "starts at %.1f%%, midpoint %@", threshold, mid),
            outcome: .mapped("pressureThreshold and pressureCurve, fitted", .approximate),
            action: .pressure(start: v[0] / v[4], midX: v[2] / v[4], midY: v[3] / v[5]), setting: .pressure)
    }

    // MARK: ExpressKeys and rings

    static func controls(_ c: WacomNode, against base: WacomNode?, productID: Int?,
                         layout: LayoutLookup) -> [Section] {
        var sections: [Section] = []
        let baseKeys = base?.node("TabletControlsButtonsArray")?.elements ?? []
        var keys = Section(title: "ExpressKeys", lines: [])
        for k in c.node("TabletControlsButtonsArray")?.elements ?? [] {
            let name = k.string("ButtonName") ?? "?"
            if let other = baseKeys.first(where: { $0.string("ButtonName") == name }), sameButton(k, other) { continue }
            var (wacom, outcome, binding) = function(k, layout: layout)
            guard let target = KeyLayouts.key(name, productID: productID) else {
                if !outcome.isSkipped { outcome = .skipped("key position unknown on this model") }
                keys.lines.append(Line(control: name, wacom: wacom, outcome: outcome))
                continue
            }
            // A second dial's key cycles that dial's modes.
            if target.setting == "touchRingButtonBinding2", case .mapped("ringCycle", let conf) = outcome {
                outcome = .mapped("ringCycle2", conf)
                binding = .kind("ringCycle2")
            }
            keys.lines.append(Line(control: name, wacom: wacom,
                                   outcome: outcome.prefixed(target.setting).capped(target.confidence),
                                   action: binding.map(Action.binding), setting: target.slot))
        }
        sections.append(keys)

        if let ring = c.node("TouchRingSettings") {
            sections.append(ringSection("Touch ring", ring, base: base?.node("TouchRingSettings"),
                                        key: "touchRingSlots", confidence: .exact,
                                        slot: { .ringSlot($0) }, layout: layout))
        }
        for dial in c.node("TouchRings")?.children ?? [] {
            let title = "Dial \(dial.name)"
            let base = base?.node("TouchRings/\(dial.name)")
            guard let target = KeyLayouts.dial(dial.name, productID: productID) else {
                var s = ringSection(title, dial, base: base, key: "rotaries", confidence: .exact,
                                    slot: { _ in nil }, layout: layout)
                s.lines = s.lines.map {
                    Line(control: $0.control, wacom: $0.wacom,
                         outcome: $0.outcome.isSkipped ? $0.outcome : .skipped("dial unknown on this model"),
                         action: $0.action)
                }
                sections.append(s)
                continue
            }
            let dialIndex = target.setting == "rotaries[1]" ? 1 : 0
            let checked = target.confidence != .unverified
            sections.append(ringSection(title, dial, base: base, key: target.setting,
                                        confidence: target.confidence,
                                        slot: { checked ? .rotarySlot(dial: dialIndex, slot: $0) : nil }, layout: layout))
        }
        if let mods = c.node("TabletControlsModButtonsArray"), !mods.elements.isEmpty {
            sections.append(Section(title: "Modifier buttons", lines: [], notes: ["\(mods.elements.count) not read yet."]))
        }
        return sections
    }

    static func ringSection(_ title: String, _ ring: WacomNode, base: WacomNode?, key: String,
                            confidence: Confidence, slot: (Int) -> Setting?, layout: LayoutLookup) -> Section {
        var s = Section(title: title, lines: [])
        let modes = ring.node("TouchStripModes")?.children ?? []
        for m in modes {
            if let b = base?.node("TouchStripModes/\(m.name)"), sameRingMode(m, b) { continue }
            let label = m.string("TouchStripKeystrokeName").flatMap { $0.isEmpty ? nil : $0 }
            var (wacom, outcome, mode) = ringFunction(m, layout: layout)
            if let label { wacom = "\"\(label)\": " + wacom }
            let index = m.name.hasPrefix("mode") ? Int(m.name.dropFirst(4)).map { $0 - 1 } : nil
            s.lines.append(Line(
                control: m.name, wacom: wacom, outcome: outcome.prefixed(key).capped(confidence),
                action: mode.map { .ring($0, label: label) }, setting: index.flatMap(slot)))
        }
        return s
    }

    static func ringFunction(_ m: WacomNode, layout: LayoutLookup) -> (String, Outcome, RingMode?) {
        let code = m.int("TouchStripFunction") ?? -1
        switch code {
        // Wacom's menu offers Disabled where it once had Skip.
        case 0: return ("disabled", .mapped("off", .exact), .off)
        case 8:
            // Wacom's dialog puts the counterclockwise key first and saves
            // it as Increase, on rings and dials alike.
            let ccwRaw = m.string("TouchStripKeystrokeIncrease") ?? ""
            let cwRaw = m.string("TouchStripKeystrokeDecrease") ?? ""
            let mods = m.string("TouchStripModifiers") ?? ""
            let ccw = Keystroke.parse(mods + ccwRaw, layout: layout)
            let cw = Keystroke.parse(mods + cwRaw, layout: layout)
            let text = "keys \(describe(cw, raw: cwRaw)) clockwise, \(describe(ccw, raw: ccwRaw)) counterclockwise"
            guard case .key(let kcw, let ecw) = cw, case .key(let kccw, let eccw) = ccw,
                  kcw.keyCode != nil, kccw.keyCode != nil else {
                return (text, .skipped(skipReason(cw, ccw)), nil)
            }
            // Keys recorded on another layout can land on one key here, as #
            // and ⇧# from a German layout both need ⇧3 on a U.S. one.
            if binding(kcw) == binding(kccw) && cwRaw != ccwRaw {
                return (text, .skipped("both directions would send \(symbol(kcw)) on this keyboard layout"), nil)
            }
            let conf: Confidence = ecw && eccw ? .exact : .approximate
            return (text, .mapped("keyPress, cwBinding \(symbol(kcw)), ccwBinding \(symbol(kccw))", conf),
                    .keys(cw: binding(kcw), ccw: binding(kccw)))
        case 44: return ("auto scroll and zoom", .mapped("scroll", .approximate), .scroll)
        case 45: return ("scroll", .mapped("scroll", .exact), .scroll)
        case 47: return ("skip", .mapped("skip", .exact), .skip)
        case 51: return ("rotate", .mapped("rotate", .exact), .rotate)
        default: return ("Wacom function \(code)", .skipped("unknown ring function"), nil)
        }
    }

    // MARK: Button functions

    /// The usage history Wacom keeps per button names each code. Code 0
    /// never appears alone in one, so it stays unverified.
    static func function(_ b: WacomNode, layout: LayoutLookup) -> (String, Outcome, Binding?) {
        func kind(_ wacom: String, _ k: String, _ c: Confidence = .exact) -> (String, Outcome, Binding?) {
            (wacom, .mapped(k, c), .kind(k))
        }
        let code = b.int("ButtonFunction") ?? -1
        switch code {
        case 0: return kind("disabled", "none", .unverified)
        case 1: return kind("click", "leftClick")
        case 2: return kind("middle click", "middleClick")
        case 3: return kind("right click", "rightClick")
        case 4: return kind("double click", "doubleClick")
        case 7: return kind("click lock", "clickLock")
        case 8: return keystroke(b.string("Keystroke") ?? "", layout: layout)
        case 9: return keystroke(b.string("Modifier") ?? "", layout: layout, modifier: true)
        case 14: return kind("erase", "eraser")
        case 15: return ("Wacom function 15", .skipped("no MockTab equivalent"), nil)
        case 31: return kind("display toggle", "displayToggle")
        case 33: return kind("pan/scroll", "scrollDrag")
        case 40: return ("help", .skipped("no MockTab equivalent"), nil)
        case 41: return ("radial menu", .skipped("no MockTab equivalent"), nil)
        case 42: return ("precision mode", .skipped("no MockTab equivalent"), nil)
        case 43: return ("touch on/off", .skipped("no MockTab equivalent"), nil)
        case 61:
            let panel = b.string("Panel").flatMap { $0.isEmpty ? nil : " \"\($0)\"" } ?? ""
            return ("on-screen panel\(panel)", .skipped("no MockTab equivalent"), nil)
        case 104: return ("Wacom settings", .skipped("no MockTab equivalent"), nil)
        case 108: return kind("ring mode toggle", "ringCycle")
        default: return ("Wacom function \(code)", .skipped("unknown function"), nil)
        }
    }

    static func keystroke(_ s: String, layout: LayoutLookup, modifier: Bool = false) -> (String, Outcome, Binding?) {
        let r = Keystroke.parse(s, layout: layout)
        let text = (modifier ? "hold " : "keys ") + describe(r, raw: s)
        switch r {
        case .key(let k, let exact) where k.spacebar:
            return (text, .mapped("spacebar", exact ? .exact : .approximate), .kind("spacebar"))
        case .key(let k, let exact) where k.keyCode != nil:
            return (text, .mapped("keyCombo \(symbol(k)), key code \(k.keyCode!)", exact ? .exact : .approximate),
                    binding(k))
        case .modifiersOnly(let m):
            return (text, .mapped("keyCombo \(m.symbols), modifiers only", .exact), .modifiers(m))
        default:
            return (text, .skipped(skipReason(r)), nil)
        }
    }

    static func binding(_ k: ResolvedKey) -> Binding {
        .key(keyCode: k.keyCode ?? 0, modifiers: k.modifiers, label: k.label)
    }

    static func skipReason(_ results: Keystroke.Result...) -> String {
        for r in results {
            switch r {
            case .empty: return "no keys recorded"
            case .unsupported(let what): return "can't send \(what)"
            case .key(let k, _) where k.keyCode == nil: return "\"\(k.label)\" isn't on the current keyboard layout"
            default: continue
            }
        }
        return "not a single key"
    }

    static func symbol(_ k: ResolvedKey) -> String { k.modifiers.symbols + k.label }

    static func describe(_ r: Keystroke.Result, raw: String) -> String {
        switch r {
        case .key(let k, _): return k.recorded.isEmpty ? symbol(k) : k.recorded
        case .modifiersOnly(let m): return m.symbols
        case .empty: return "(none)"
        case .unsupported: return "\"\(raw)\""
        }
    }

    // MARK: Comparison

    static func sameButton(_ a: WacomNode, _ b: WacomNode) -> Bool {
        ["ButtonFunction", "Keystroke", "Modifier", "Panel"].allSatisfy { a.string($0) == b.string($0) }
    }

    static func sameRingMode(_ a: WacomNode, _ b: WacomNode) -> Bool {
        ["TouchStripFunction", "TouchStripKeystrokeIncrease", "TouchStripKeystrokeDecrease", "TouchStripModifiers"]
            .allSatisfy { a.string($0) == b.string($0) }
    }

    // MARK: Mapping area

    /// The tablet's own mapping, not a pen's. Wacom names displays by
    /// position and MockTab by UUID, so the report only shows the display.
    static func mappingArea(_ t: WacomNode) -> Section? {
        let sets = t.node("ContextManager/MappingGroupArray")?.elements.first?.node("MappingSetArray")?.elements ?? []
        guard let set = sets.first(where: { $0.node("TransducerID/Type") == nil }) ?? sets.first,
              let w = t.int("TabletXDimension"), let h = t.int("TabletYDimension"), w > 0, h > 0,
              let ox = set.int("OutputArea/TabletOutputArea/Origin/X"),
              let oy = set.int("OutputArea/TabletOutputArea/Origin/Y"),
              let ex = set.int("OutputArea/TabletOutputArea/Extent/X"),
              let ey = set.int("OutputArea/TabletOutputArea/Extent/Y")
        else { return nil }
        var s = Section(title: "Mapping", lines: [])
        let full = ox == 0 && oy == 0 && ex == w && ey == h
        let area = full ? "whole tablet" : String(
            format: "x %.3f, y %.3f, width %.3f, height %.3f",
            Double(ox) / Double(w), Double(oy) / Double(h), Double(ex) / Double(w), Double(ey) / Double(h))
        s.lines.append(Line(
            control: "Tablet area", wacom: area, outcome: .mapped("tabletArea", .exact),
            action: .area(x: Double(ox) / Double(w), y: Double(oy) / Double(h),
                          width: Double(ex) / Double(w), height: Double(ey) / Double(h)),
            setting: .tabletArea))
        if let screen = set.node("InputScreenAreaArray")?.elements.first?.string("ScreenArea/WhichMonitor") {
            s.lines.append(Line(control: "Display", wacom: screen, outcome: .skipped("Wacom names displays by position")))
        }
        return s
    }
}

extension Confidence {
    /// Exact, then approximate, then unverified.
    var rank: Int { self == .exact ? 0 : self == .approximate ? 1 : 2 }
}

extension Outcome {
    /// Lowers a mapping's confidence to `limit` when the target is less sure
    /// than the value.
    func capped(_ limit: Confidence) -> Outcome {
        if case .mapped(let what, let c) = self, limit.rank > c.rank { return .mapped(what, limit) }
        return self
    }

    /// Names the MockTab setting in front of the value.
    func prefixed(_ key: String) -> Outcome {
        if case .mapped(let what, let c) = self { return .mapped("\(key): \(what)", c) }
        return self
    }
}

// MARK: - Key positions

/// A MockTab setting a Wacom control name lands on, and how sure that is.
struct Target {
    let setting: String
    let confidence: Confidence

    /// The setting as data: `expressKeyBindings[3]` is ExpressKey 3. An
    /// unchecked position has none, so the import leaves it alone.
    var slot: Setting? {
        guard confidence != .unverified else { return nil }
        if setting.hasPrefix("expressKeyBindings["), let i = Int(setting.dropFirst(19).dropLast()) {
            return .expressKey(i)
        }
        return setting.hasPrefix("rotaries") ? nil : .binding(setting)
    }
}

/// Where each model's Wacom key and dial names land in MockTab, by wired
/// product ID. Wacom numbers each side's keys from 1, LeftButton then
/// RightButton. MockTab's ExpressKey index follows the tablet's report
/// order, which TabletLayoutTable lists per model in libwacom's letters.
enum KeyLayouts {
    /// PTK-670 and PTK-870: around each dial, top, right, bottom, then left,
    /// then the center key that switches the dial's mode. Checked against
    /// the PTK-870's report order.
    static let twoDials: Set<Int> = [0x03F7, 0x03F9]
    /// PTK-470: one cluster the same shape, beside one dial.
    static let oneDial: Set<Int> = [0x03F5]
    /// PTH-660 and PTH-860: eight keys down the side, numbered top to
    /// bottom, as libwacom lists them.
    static let eightDown: Set<Int> = [0x0357, 0x0358]
    /// Intuos Pro S (PTH-451): six keys beside the ring, assumed top to
    /// bottom like the PTH-660. Not checked.
    static let sixDown: Set<Int> = [0x0314]
    /// Intuos (CTL-4100/6100): four keys along the top edge, named Button1-4,
    /// assumed left to right in libwacom's order. Not checked.
    static let fourAcross: Set<Int> = [0x0374, 0x0375, 0x0376, 0x0377, 0x0378, 0x0379, 0x03C5, 0x03C6, 0x03C7, 0x03C8]

    static func key(_ name: String, productID: Int?) -> Target? {
        guard let pid = productID else { return nil }
        if fourAcross.contains(pid), name.hasPrefix("Button"), let n = Int(name.dropFirst(6)), (1...4).contains(n) {
            return Target(setting: "expressKeyBindings[\(n - 1)]", confidence: .unverified)
        }
        let side: Int
        let n: Int
        if name.hasPrefix("LeftButton"), let i = Int(name.dropFirst(10)) {
            (side, n) = (0, i)
        } else if name.hasPrefix("RightButton"), let i = Int(name.dropFirst(11)) {
            (side, n) = (1, i)
        } else {
            return nil
        }
        if twoDials.contains(pid) || oneDial.contains(pid) {
            let conf: Confidence = twoDials.contains(pid) ? .exact : .unverified
            if oneDial.contains(pid) && side == 1 { return nil }
            switch n {
            case 1...4: return Target(setting: "expressKeyBindings[\(side * 4 + n - 1)]", confidence: conf)
            case 5: return Target(setting: side == 0 ? "touchRingButtonBinding" : "touchRingButtonBinding2", confidence: conf)
            default: return nil
            }
        }
        if eightDown.contains(pid), side == 0, (1...8).contains(n) {
            return Target(setting: "expressKeyBindings[\(n - 1)]", confidence: .exact)
        }
        if sixDown.contains(pid), side == 0, (1...6).contains(n) {
            return Target(setting: "expressKeyBindings[\(n - 1)]", confidence: .unverified)
        }
        return nil
    }

    /// libwacom numbers the PTK-670/870's dials from the left.
    static func dial(_ name: String, productID: Int?) -> Target? {
        guard let pid = productID else { return nil }
        if twoDials.contains(pid) {
            switch name {
            case "leftdial": return Target(setting: "rotaries[0]", confidence: .exact)
            case "rightdial": return Target(setting: "rotaries[1]", confidence: .exact)
            default: return nil
            }
        }
        if oneDial.contains(pid), name == "leftdial" { return Target(setting: "rotaries[0]", confidence: .unverified) }
        return nil
    }
}

// MARK: - Text

enum ReportText {
    /// `reportOnly` says so up front, since --apply follows the same report.
    /// `layout` names the keyboard layout keystrokes were found on.
    static func render(_ r: Report, reportOnly: Bool = true, layout: String? = nil) -> String {
        var out = "Wacom backup"
        if let v = r.driverVersion { out += " from driver \(v)" }
        if let f = r.formatVersion { out += ", format \(f)" }
        if let layout { out += "\nKeyboard layout: \(layout)" }
        out += reportOnly ? "\nReport only; nothing written. Add --apply to import a tablet.\n" : "\n"
        for (i, t) in r.tablets.enumerated() {
            out += "\nTablet \(i + 1): \(t.modelName)"
            if let pid = t.productID {
                out += String(format: " (product ID 0x%04X", pid)
                if let seen = t.lastConnectedAs { out += String(format: ", last connected as 0x%04X", seen) }
                out += ")"
            }
            out += "\n"
            if let n = t.nickname { out += "  Name \"\(n)\" -> tablet nickname\n" }
            for note in t.notes { out += "  \(note)\n" }
            for a in t.apps {
                out += "\n  \(a.name)" + (a.bundleID.map { " (\($0))" } ?? "") + "\n"
                for note in a.notes { out += "    \(note)\n" }
                for s in a.sections where !s.lines.isEmpty || !s.notes.isEmpty {
                    out += "    \(s.title)\n"
                    for note in s.notes { out += "      \(note)\n" }
                    for l in s.lines { out += "      " + line(l) + "\n" }
                }
            }
        }
        let all = r.lines
        func count(_ c: Confidence) -> Int {
            all.filter { if case .mapped(_, c) = $0.outcome { return true } else { return false } }.count
        }
        out += "\nSummary: \(count(.exact)) exact, \(count(.approximate)) approximate, "
            + "\(count(.unverified)) unverified, \(all.filter(\.outcome.isSkipped).count) skipped\n"
        return out
    }

    static func line(_ l: Line) -> String {
        let head = l.control.padding(toLength: 14, withPad: " ", startingAt: 0) + " " + l.wacom
        switch l.outcome {
        case .mapped(let what, .exact): return "\(head) -> \(what)"
        case .mapped(let what, let c): return "\(head) -> \(what) [\(c.rawValue)]"
        case .skipped(let why):
            // A control with a setting still changes on import.
            switch l.setting {
            case .ringSlot?, .rotarySlot?: return "\(head) -- skipped: \(why) (becomes Off)"
            case .some: return "\(head) -- skipped: \(why) (becomes None)"
            case nil: return "\(head) -- skipped: \(why)"
            }
        }
    }
}
