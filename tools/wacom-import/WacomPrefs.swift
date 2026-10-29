// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reads a Wacom Tablet Utility backup (a .wacomprefs folder) and works out
// what each setting would become in MockTab. Nothing here writes anything.
//
// The backup's com.wacom.wacomtablet.prefs is XML where every element names
// its type: <Name type="integer">3</Name>, with arrays as repeated
// ArrayElement children. Keystrokes are "kestring" values: characters plus
// named keys in &name; form, or &vk=12:cc=31:kb=2b; with a virtual key code.

import Foundation

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
    /// Driver version from version.plist, as Tablet Utility shows it.
    let driverVersion: String?
    let root: WacomNode

    enum LoadError: Error, CustomStringConvertible {
        case notABackup(String)
        case unreadable(String)

        var description: String {
            switch self {
            case .notABackup(let p): return "\(p) is not a Tablet Utility backup: no com.wacom.wacomtablet.prefs inside."
            case .unreadable(let p): return "Could not read \(p) as XML."
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

/// Where a character key sits on the current keyboard layout.
struct LayoutKey {
    let keyCode: UInt16
    /// The character only comes out with Shift held.
    let needsShift: Bool
}

typealias LayoutLookup = (Character) -> LayoutKey?

/// A keystroke resolved to a macOS virtual key code, as MockTab stores it.
struct ResolvedKey: Equatable {
    var keyCode: UInt16?
    var modifiers: KeyModifiers
    var label: String
    var spacebar = false
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
            "kpenter": (76, "⌤"),
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

    /// Splits a kestring into modifiers and one key. More than one key is a
    /// typed sequence, which MockTab can't send from one button.
    static func parse(_ s: String, layout: LayoutLookup) -> Result {
        var mods = KeyModifiers()
        var keys: [(ResolvedKey, Bool)] = []
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
                    keys.append((ResolvedKey(keyCode: code, modifiers: [], label: label), token != "enter"))
                } else if let ch = namedCharacters[token] {
                    keys.append(character(ch, layout: layout))
                } else {
                    return .unsupported("&\(token);")
                }
            } else {
                rest = rest.dropFirst()
                keys.append(character(c, layout: layout))
            }
        }
        if spacebarHold && keys.isEmpty && mods.isEmpty {
            return .key(ResolvedKey(keyCode: 49, modifiers: [], label: "Space", spacebar: true), exact: true)
        }
        if keys.count > 1 { return .unsupported("key sequence \"\(s)\"") }
        guard let (first, exact) = keys.first else { return mods.isEmpty ? .empty : .modifiersOnly(mods) }
        var key = first
        key.modifiers.formUnion(mods)
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
        return ResolvedKey(keyCode: vk, modifiers: [], label: label)
    }

    /// A bare character, found on the current layout. One that needs Shift
    /// gains it, which may not be what the Wacom recording meant.
    private static func character(_ c: Character, layout: LayoutLookup) -> (ResolvedKey, Bool) {
        let label = String(c).uppercased()
        guard let k = layout(Character(String(c).lowercased())) ?? layout(c) else {
            return (ResolvedKey(keyCode: nil, modifiers: [], label: label), false)
        }
        return (ResolvedKey(keyCode: k.keyCode, modifiers: k.needsShift ? .shift : [], label: label), !k.needsShift)
    }
}

// MARK: - Mapping

enum Confidence: String {
    case exact
    case approximate
    /// Mapped on thin evidence; check before writing.
    case unverified
}

enum Outcome {
    case mapped(String, Confidence)
    case skipped(String)

    var isSkipped: Bool { if case .skipped = self { return true } else { return false } }
}

struct Line {
    let control: String
    let wacom: String
    let outcome: Outcome
}

struct Section {
    let title: String
    var lines: [Line]
    var notes: [String] = []
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
    let productID: Int?
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

    /// SensorID packs the USB vendor and product IDs: 0x056A0357 is a
    /// Wacom PTH-660.
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
        let pid = productID(t)
        var report = TabletReport(
            modelName: model, wacomType: t.int("TabletType"), productID: pid,
            nickname: name != model ? customName(name) : nil, apps: [])
        if pid == nil { report.notes.append("No Wacom product ID in the backup; the writer can't pick a tablet for it.") }

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
                report.notes.append("Settings for application \(i) have no entry in the application list; skipped.")
                continue
            }
            var r = AppReport(name: a.name, bundleID: a.bundleID.isEmpty ? nil : a.bundleID, sections: [])
            if a.removed {
                r.notes.append("Removed in Wacom's settings; skipped.")
            } else if a.bundleID.isEmpty {
                r.notes.append("No bundle ID; MockTab can't match it to an app. Skipped.")
            } else if chosen[a.bundleID] != i {
                r.notes.append("Another entry for this app is used instead; MockTab keeps one set per bundle ID. Skipped.")
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
    /// bundle ID. Use the one still installed, else the newest entry.
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
            notes.append("No serial: MockTab keys this pen by tool code, so it shares settings with others of its kind.")
        }
        var lines: [Line] = []
        if base == nil, let name = customName(tr.string("TransducerName")) {
            lines.append(Line(control: "Name", wacom: "\"\(name)\"", outcome: .mapped("tool nickname", .exact)))
        }
        for (element, label, key) in penButtons {
            guard let b = tr.node(element), b.node("ButtonFunction") != nil else { continue }
            if let base, let other = base.node(element), sameButton(b, other) { continue }
            let (wacom, outcome) = function(b, layout: layout)
            lines.append(Line(control: label, wacom: wacom, outcome: outcome.prefixed(key)))
        }
        if let curve = tr.string("TransducerTipButtonSettings/PressureCurveControlPoint"),
           base?.string("TransducerTipButtonSettings/PressureCurveControlPoint") != curve {
            lines.append(pressure(curve))
        }
        return Section(title: title, lines: lines, notes: notes)
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
            outcome: .mapped("pressureThreshold and pressureCurve, fitted", .approximate))
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
            var (wacom, outcome) = function(k, layout: layout)
            guard let target = KeyLayouts.key(name, productID: productID) else {
                if !outcome.isSkipped { outcome = .skipped("where this key sits on this model isn't known") }
                keys.lines.append(Line(control: name, wacom: wacom, outcome: outcome))
                continue
            }
            // A second dial's key cycles that dial's modes.
            if target.setting == "touchRingButtonBinding2", case .mapped("ringCycle", let conf) = outcome {
                outcome = .mapped("ringCycle2", conf)
            }
            keys.lines.append(Line(control: name, wacom: wacom,
                                   outcome: outcome.prefixed(target.setting).capped(target.confidence)))
        }
        sections.append(keys)

        if let ring = c.node("TouchRingSettings") {
            sections.append(ringSection("Touch ring", ring, base: base?.node("TouchRingSettings"),
                                        key: "touchRingSlots", confidence: .exact, layout: layout))
        }
        for dial in c.node("TouchRings")?.children ?? [] {
            let title = "Dial \(dial.name)"
            let base = base?.node("TouchRings/\(dial.name)")
            guard let target = KeyLayouts.dial(dial.name, productID: productID) else {
                var s = ringSection(title, dial, base: base, key: "rotaries", confidence: .exact, layout: layout)
                s.lines = s.lines.map {
                    Line(control: $0.control, wacom: $0.wacom,
                         outcome: $0.outcome.isSkipped ? $0.outcome : .skipped("which dial this is on this model isn't known"))
                }
                sections.append(s)
                continue
            }
            sections.append(ringSection(title, dial, base: base, key: target.setting,
                                        confidence: target.confidence, layout: layout))
        }
        if let mods = c.node("TabletControlsModButtonsArray"), !mods.elements.isEmpty {
            sections.append(Section(title: "Modifier buttons", lines: [], notes: ["\(mods.elements.count) not read yet."]))
        }
        return sections
    }

    static func ringSection(_ title: String, _ ring: WacomNode, base: WacomNode?, key: String,
                            confidence: Confidence, layout: LayoutLookup) -> Section {
        var s = Section(title: title, lines: [])
        let modes = ring.node("TouchStripModes")?.children ?? []
        for m in modes {
            if let b = base?.node("TouchStripModes/\(m.name)"), sameRingMode(m, b) { continue }
            let label = m.string("TouchStripKeystrokeName").flatMap { $0.isEmpty ? nil : $0 }
            var (wacom, outcome) = ringFunction(m, layout: layout)
            if let label { wacom = "\"\(label)\": " + wacom }
            s.lines.append(Line(control: m.name, wacom: wacom, outcome: outcome.prefixed(key).capped(confidence)))
        }
        return s
    }

    static func ringFunction(_ m: WacomNode, layout: LayoutLookup) -> (String, Outcome) {
        let code = m.int("TouchStripFunction") ?? -1
        switch code {
        case 0: return ("off", .mapped("off", .unverified))
        case 8:
            let up = m.string("TouchStripKeystrokeIncrease") ?? ""
            let down = m.string("TouchStripKeystrokeDecrease") ?? ""
            let mods = m.string("TouchStripModifiers") ?? ""
            let a = Keystroke.parse(mods + up, layout: layout)
            let b = Keystroke.parse(mods + down, layout: layout)
            let text = "keys \(describe(a, raw: up)) / \(describe(b, raw: down))"
            guard case .key(let ka, let ea) = a, case .key(let kb, let eb) = b, ka.keyCode != nil, kb.keyCode != nil else {
                return (text, .skipped(skipReason(a, b)))
            }
            let conf: Confidence = ea && eb ? .unverified : .approximate
            return (text, .mapped("keyPress \(symbol(ka)) / \(symbol(kb))", conf))
        case 44: return ("auto scroll and zoom", .mapped("scroll", .approximate))
        case 45: return ("scroll", .mapped("scroll", .exact))
        case 47: return ("skip", .mapped("skip", .exact))
        case 51: return ("rotate", .mapped("rotate", .exact))
        default: return ("Wacom function \(code)", .skipped("unknown ring function"))
        }
    }

    // MARK: Button functions

    /// Each code's meaning comes from the usage history Wacom keeps for the
    /// button; 0 never had a single-entry history, so it stays unverified.
    static func function(_ b: WacomNode, layout: LayoutLookup) -> (String, Outcome) {
        let code = b.int("ButtonFunction") ?? -1
        switch code {
        case 0: return ("disabled", .mapped("none", .unverified))
        case 1: return ("click", .mapped("leftClick", .exact))
        case 2: return ("middle click", .mapped("middleClick", .exact))
        case 3: return ("right click", .mapped("rightClick", .exact))
        case 4: return ("double click", .mapped("doubleClick", .exact))
        case 7: return ("click lock", .mapped("clickLock", .exact))
        case 8: return keystroke(b.string("Keystroke") ?? "", layout: layout)
        case 9: return keystroke(b.string("Modifier") ?? "", layout: layout, modifier: true)
        case 14: return ("erase", .mapped("eraser", .exact))
        case 15: return ("Wacom function 15", .skipped("no MockTab equivalent"))
        case 31: return ("display toggle", .mapped("displayToggle", .exact))
        case 33: return ("pan/scroll", .mapped("scrollDrag", .exact))
        case 40: return ("help", .skipped("no MockTab equivalent"))
        case 42: return ("precision mode", .skipped("no MockTab equivalent"))
        case 61:
            let panel = b.string("Panel").flatMap { $0.isEmpty ? nil : " \"\($0)\"" } ?? ""
            return ("on-screen panel\(panel)", .skipped("no MockTab equivalent"))
        case 104: return ("Wacom settings", .skipped("no MockTab equivalent"))
        case 108: return ("ring mode toggle", .mapped("ringCycle", .exact))
        default: return ("Wacom function \(code)", .skipped("unknown function"))
        }
    }

    static func keystroke(_ s: String, layout: LayoutLookup, modifier: Bool = false) -> (String, Outcome) {
        let r = Keystroke.parse(s, layout: layout)
        let text = (modifier ? "hold " : "keys ") + describe(r, raw: s)
        switch r {
        case .key(let k, let exact) where k.spacebar:
            return (text, .mapped("spacebar", exact ? .exact : .approximate))
        case .key(let k, let exact) where k.keyCode != nil:
            return (text, .mapped("keyCombo \(symbol(k)), key code \(k.keyCode!)", exact ? .exact : .approximate))
        case .modifiersOnly(let m):
            return (text, .mapped("keyCombo \(m.symbols), modifiers only", .exact))
        default:
            return (text, .skipped(skipReason(r)))
        }
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
        case .key(let k, _): return symbol(k)
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
    /// position, MockTab by UUID, so the display is only reported.
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
        s.lines.append(Line(control: "Tablet area", wacom: area, outcome: .mapped("tabletArea", .exact)))
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
}

/// Where each model's Wacom key and dial names land in MockTab. Wacom
/// numbers a side's keys from 1, LeftButton then RightButton; MockTab's
/// ExpressKey index is the tablet's report order, which TabletLayoutTable
/// spells out per model with libwacom's letters.
enum KeyLayouts {
    /// PTK-670 and PTK-870: around each dial, top, right, bottom, then left,
    /// then the center key that switches the dial's mode. Checked against
    /// the PTK-870's report order.
    static let twoDials: Set<Int> = [0x03F7, 0x03F9]
    /// PTK-470: one cluster the same shape, beside one dial.
    static let oneDial: Set<Int> = [0x03F5]
    /// PTH-660 and PTH-860, wired and Bluetooth: eight keys down the side,
    /// top to bottom in libwacom's order. Wacom's numbering isn't checked.
    static let eightDown: Set<Int> = [0x0357, 0x0358, 0x0360, 0x0361]

    static func key(_ name: String, productID: Int?) -> Target? {
        guard let pid = productID else { return nil }
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
    static func render(_ r: Report) -> String {
        var out = "Wacom backup"
        if let v = r.driverVersion { out += " from driver \(v)" }
        if let f = r.formatVersion { out += ", format \(f)" }
        out += "\nNothing is written. This lists what an import would do.\n"
        for (i, t) in r.tablets.enumerated() {
            out += "\nTablet \(i + 1): \(t.modelName)"
            if let pid = t.productID { out += String(format: " (product ID 0x%04X)", pid) }
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
        case .skipped(let why): return "\(head) -- skipped: \(why)"
        }
    }
}
