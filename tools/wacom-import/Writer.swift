// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Plans and applies an encoded tablet against a settings domain: which keys
// to remove and which to set. Planning reads only; applying writes through
// UserDefaults, never the plist file.
//
// The import replaces whole categories for the tablet's claimed unit
// (`device-0x{PID}.`): ExpressKeys, ring and dial keys and modes, the tablet
// area, the imported pens' buttons and pressure, every app override, and the
// active profile. The app and pen lists keep fields this tool doesn't know.

import Foundation

struct WritePlan {
    var remove: [String] = []
    var set: [String: Any] = [:]
    var notes: [String] = []
}

enum WriteError: Error, CustomStringConvertible, Equatable {
    case unknownTablet(Int)
    case unreadableList(String)

    var description: String {
        switch self {
        case .unknownTablet(let pid):
            return String(format: "MockTab doesn't know tablet 0x%04X yet. Connect it once with MockTab running, then quit MockTab.", pid)
        case .unreadableList(let key):
            return "\(key) holds data this tool can't read, likely from a newer MockTab. Nothing was written."
        }
    }
}

enum WacomWriter {
    static func prefix(_ productID: Int) -> String {
        "device-0x\(String(productID, radix: 16, uppercase: true))."
    }

    static let deviceKeys = [
        "expressKeyBindings", "touchRingButtonBinding", "touchRingButtonBinding2",
        "touchRingSlotsJSON", "rotariesJSON", "touchRingActiveSlotIndex", "touchRingActiveSlotIndex2",
        "activeAreaX", "activeAreaY", "activeAreaWidth", "activeAreaHeight",
        "_activeProfile",
    ]

    static let penKeys = [
        "tipBinding", "eraserBinding", "penButton1Binding", "penButton2Binding", "penButton3Binding",
        "penButton4Binding", "penButton5Binding", "pressureThreshold", "pressureCurve",
    ]

    /// `current` is the domain as it stands: `UserDefaults.persistentDomain(forName:)`.
    static func plan(_ e: EncodedTablet, current: [String: Any]) throws -> WritePlan {
        var plan = WritePlan()
        let p = prefix(e.productID)
        func removeIfPresent(_ key: String) { if current[key] != nil { plan.remove.append(key) } }

        // The tablet itself, which must already be known.
        var tablets = try list(current["_knownTablets"], key: "_knownTablets")
        let units = tablets.indices.filter { tablets[$0]["id"] as? Int == e.productID }
        guard let unit = units.first(where: { (tablets[$0]["instance"] as? String ?? "").isEmpty }) else {
            throw WriteError.unknownTablet(e.productID)
        }
        if units.count > 1 { plan.notes.append("MockTab knows more than one of this model; only the first one is changed.") }
        if let nickname = e.nickname, tablets[unit]["nickname"] as? String != nickname {
            tablets[unit]["nickname"] = nickname
            plan.set["_knownTablets"] = try data(tablets)
        }

        for key in deviceKeys { removeIfPresent(p + key) }
        for (key, value) in e.device { plan.set[p + key] = value }

        var tools = try list(current[p + "_knownTools"], key: p + "_knownTools")
        for pen in e.pens {
            let tp = "\(p)tool-\(pen.id)."
            for key in penKeys { removeIfPresent(tp + key) }
            for (key, value) in pen.values { plan.set[tp + key] = value }
            if let i = tools.firstIndex(where: { $0["id"] as? String == pen.id }) {
                if let nickname = pen.nickname { tools[i]["nickname"] = nickname }
            } else {
                // The app fills kind, tool code, and support when it loads the
                // list and when the pen first touches the tablet.
                tools.append(["id": pen.id, "nickname": pen.nickname ?? "", "kind": "",
                              "serial": Int(pen.serial), "isSupported": true])
            }
        }
        if !e.pens.isEmpty { plan.set[p + "_knownTools"] = try data(tools) }

        removeIfPresent(p + "_appOverrides")
        for key in current.keys.sorted() where key.hasPrefix(p + "appOverride-") { plan.remove.append(key) }
        var overrides: [[String: Any]] = []
        for app in e.apps {
            let ap = "\(p)appOverride-\(app.bundleID)."
            for (key, value) in app.values { plan.set[ap + key] = value }
            overrides.append(["bundleID": app.bundleID, "appName": app.appName,
                              "overriddenKeys": app.values.keys.sorted()])
        }
        plan.set[p + "_appOverrides"] = try data(overrides)

        // A key both removed and set is simply set.
        plan.remove.removeAll { plan.set[$0] != nil }
        plan.remove.sort()
        return plan
    }

    static func apply(_ plan: WritePlan, domain: String) {
        guard let ud = UserDefaults(suiteName: domain) else { return }
        for key in plan.remove { ud.removeObject(forKey: key) }
        for (key, value) in plan.set { ud.set(value, forKey: key) }
        CFPreferencesAppSynchronize(domain as CFString)
    }

    private static func list(_ value: Any?, key: String) throws -> [[String: Any]] {
        guard let value else { return [] }
        guard let d = value as? Data,
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]]
        else { throw WriteError.unreadableList(key) }
        return arr
    }

    private static func data(_ arr: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys])
    }
}
