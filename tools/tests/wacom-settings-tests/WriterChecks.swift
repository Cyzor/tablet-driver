// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// Writes the fixture's PTH-660 into a scratch settings domain seeded with
// older values and unrelated settings, then reads the domain back: what the
// import replaced, what it kept, and that the lists still decode.

import Foundation

func checkWriter(_ report: Report, _ expect: (Bool, String) -> Void) {
    let domain = "com.cyzor.mocktab.wacom-settings-tests"
    let p = "device-0x357."
    let tp = p + "tool-0x12345678."
    func json(_ v: Any) -> Data { try! JSONSerialization.data(withJSONObject: v) }
    func list(_ v: Any?) -> [[String: Any]] {
        (v as? Data).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
    }

    var seed: [String: Any] = [
        "_knownTablets": json([
            ["id": 0x357, "nickname": "Old name", "modelName": "PTH-660", "fieldFromNewerBuild": 1],
            ["id": 0x358, "nickname": "Other tablet", "modelName": "PTH-860"],
        ]),
        "_lastLaunchedBuild": "0.6.0",
        p + "expressKeyBindings": "[]",
        p + "touchRingButtonBinding": "{}",
        p + "calibrationJSON": "keep",
        p + "smoothingStrength": 0.3,
        p + "_activeProfile": "some-profile",
        p + "_appOverrides": json([["bundleID": "com.old.app", "appName": "Old", "overriddenKeys": ["tipBinding"]]]),
        p + "appOverride-com.old.app.tipBinding": "old",
        tp + "tipBinding": "old",
        tp + "penButton2Binding": "old",
        tp + "penButton4Binding": "old",
        tp + "smoothingStrength": 0.2,
        p + "_knownTools": json([["id": "0x12345678", "nickname": "Old pen", "kind": "Pro Pen 2",
                                  "serial": 0x12345678, "toolCode": 0x842, "isSupported": true]]),
        "device-0x358.expressKeyBindings": "other tablet",
        "device-0x357#second.expressKeyBindings": "second unit",
    ]
    expect(WacomWriter.prefix(0x03F9) == "device-0x3F9.", "Prefix in MockTab's case: \(WacomWriter.prefix(0x03F9))")
    guard let ud = UserDefaults(suiteName: domain), let encoded = try? WacomEncoder.encode(report.tablets[0]),
          let paintValues = encoded.apps.first(where: { $0.bundleID == "com.example.paint" })?.values,
          let coveredOnly = encoded.device.keys.sorted().first(where: { paintValues[$0] == nil }) else {
        expect(false, "Scratch domain and encode")
        return
    }
    // MockTab already overrides Paint: one setting the import doesn't cover,
    // and one it covers but Paint doesn't change in Wacom.
    let pp = p + "appOverride-com.example.paint."
    seed[p + "_appOverrides"] = json([
        ["bundleID": "com.old.app", "appName": "Old", "overriddenKeys": ["tipBinding"]],
        ["bundleID": "com.example.paint", "appName": "Paint in MockTab", "fieldFromNewerBuild": 1,
         "overriddenKeys": ["smoothingStrength", coveredOnly]],
    ])
    seed[pp + "smoothingStrength"] = 0.7
    seed[pp + coveredOnly] = "old"
    ud.removePersistentDomain(forName: domain)
    ud.setPersistentDomain(seed, forName: domain)
    defer { ud.removePersistentDomain(forName: domain) }

    guard let plan = try? WacomWriter.plan(encoded, current: ud.persistentDomain(forName: domain) ?? [:]) else {
        expect(false, "Plan")
        return
    }
    let touched = plan.remove + Array(plan.set.keys)
    expect(touched.allSatisfy { $0.hasPrefix(p) || $0 == "_knownTablets" },
           "Only this tablet's keys and the tablet list: \(touched.filter { !$0.hasPrefix(p) })")
    expect(Set(plan.remove).isDisjoint(with: plan.set.keys), "No key is both removed and set")

    WacomWriter.apply(plan, domain: domain)
    let after = UserDefaults(suiteName: domain)?.persistentDomain(forName: domain) ?? [:]

    // Kept
    expect(after[p + "calibrationJSON"] as? String == "keep" && after[p + "smoothingStrength"] as? Double == 0.3,
           "Tablet settings outside the import stay")
    expect(after[tp + "smoothingStrength"] as? Double == 0.2, "Pen settings outside the import stay")
    expect(after["device-0x358.expressKeyBindings"] as? String == "other tablet", "Other tablets stay")
    expect(after["device-0x357#second.expressKeyBindings"] as? String == "second unit", "A second unit stays")
    expect(after["_lastLaunchedBuild"] as? String == "0.6.0", "Global settings stay")
    expect(after[tp + "penButton2Binding"] as? String == "old", "An unverified pen button keeps its setting")
    expect(after[tp + "penButton4Binding"] as? String == "old", "A pen button the backup doesn't have stays")
    expect(after[p + "touchRingButtonBinding"] as? String == "{}", "A control the backup doesn't have stays")

    // Replaced
    expect(after[p + "_activeProfile"] == nil, "Active profile cleared")
    expect(ButtonBinding.decode(after[tp + "penButton3Binding"] as? String ?? "") == ButtonBinding.none,
           "A pen button with no equivalent becomes None")
    let keys = (after[p + "expressKeyBindings"] as? String).flatMap(ButtonBinding.decodeList) ?? []
    expect(keys.count == 16 && keys[0].keyCode == 18, "ExpressKeys written")
    expect(after[p + "touchRingSlotsJSON"] is Data, "Ring modes stored as data, as the app reads them")
    expect(ButtonBinding.decode(after[tp + "tipBinding"] as? String ?? "")?.kind == .leftClick, "Pen tip written")
    expect(after[tp + "pressureCurve"] is Data, "Pressure curve stored as data")

    // Apps merge
    let overrides = list(after[p + "_appOverrides"])
    expect(overrides.map { $0["bundleID"] as? String } == ["com.old.app", "com.example.paint"],
           "Apps merge, in their order: \(overrides.map { $0["bundleID"] ?? "" })")
    expect(after[p + "appOverride-com.old.app.tipBinding"] as? String == "old"
           && overrides.first?["overriddenKeys"] as? [String] == ["tipBinding"], "An app the backup doesn't set stays")
    if let paint = overrides.last, let keys = paint["overriddenKeys"] as? [String] {
        expect(keys == (Array(paintValues.keys) + ["smoothingStrength"]).sorted(),
               "Paint overrides the imported values plus its own: \(keys)")
        expect(keys.allSatisfy { after[pp + $0] != nil }, "Every overridden key has a value")
        expect(after[pp + "smoothingStrength"] as? Double == 0.7, "A setting the import doesn't cover stays")
        expect(after[pp + coveredOnly] == nil, "A covered setting Paint doesn't change follows All applications")
        expect(paint["appName"] as? String == "Paint in MockTab" && paint["fieldFromNewerBuild"] as? Int == 1,
               "MockTab's name and unknown fields stay")
    } else {
        expect(false, "Paint in the app list")
    }
    var noApps = encoded
    noApps.apps = []
    let quiet = try? WacomWriter.plan(noApps, current: seed)
    expect(quiet?.set[p + "_appOverrides"] == nil && quiet?.remove.contains { $0.contains("appOverride") } == false,
           "A backup with no app settings leaves the app list alone")

    let tablets = list(after["_knownTablets"])
    let mine = tablets.first { $0["id"] as? Int == 0x357 }
    expect(mine?["nickname"] as? String == "Studio" && mine?["fieldFromNewerBuild"] as? Int == 1,
           "Tablet renamed, unknown fields kept")
    expect(tablets.first { $0["id"] as? Int == 0x358 }?["nickname"] as? String == "Other tablet", "Other tablet's row kept")

    let tools = list(after[p + "_knownTools"])
    expect(tools.count == 1 && tools[0]["nickname"] as? String == "Inking pen"
           && tools[0]["toolCode"] as? Int == 0x842 && tools[0]["kind"] as? String == "Pro Pen 2",
           "Known pen renamed, the rest kept: \(tools)")

    // A pen MockTab hasn't seen gets an entry the app completes later.
    var fresh = seed
    fresh[p + "_knownTools"] = nil
    if let plan = try? WacomWriter.plan(encoded, current: fresh) {
        let added = list(plan.set[p + "_knownTools"])
        expect(added.count == 1 && added[0]["id"] as? String == "0x12345678" && added[0]["kind"] as? String == ""
               && added[0]["serial"] as? Int == 0x12345678 && added[0]["isSupported"] as? Bool == true
               && added[0]["toolCode"] == nil && added[0]["nickname"] as? String == "Inking pen",
               "New pen entry: \(added)")
    } else {
        expect(false, "Plan with no known pens")
    }

    // Refusals
    var unknown = seed
    unknown["_knownTablets"] = json([["id": 0x358, "nickname": "Other", "modelName": "PTH-860"]])
    do {
        _ = try WacomWriter.plan(encoded, current: unknown)
        expect(false, "A tablet MockTab doesn't know is refused")
    } catch {
        expect(error as? WriteError == .unknownTablet(0x357), "Unknown tablet error: \(error)")
    }
    var unreadable = seed
    unreadable[p + "_knownTools"] = "not a list"
    do {
        _ = try WacomWriter.plan(encoded, current: unreadable)
        expect(false, "An unreadable list is refused")
    } catch {
        expect(error as? WriteError == .unreadableList(p + "_knownTools"), "Unreadable list error: \(error)")
    }
}
