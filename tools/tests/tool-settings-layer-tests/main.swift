// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab contributors
// SPDX-License-Identifier: GPL-3.0-or-later

// Each pen owns its pen-feel values. The real `ToolSettings` resolves a
// serial pen as app override → its own → active profile → device, and the
// generic pen as app override → profile → device; edits land in the layer
// that rule implies and say so. `TabletSettings` sets the layers in the
// app; here they're set by hand, the way `configureToolLayers` does.

import Foundation

let ud = UserDefaults.standard
let domain = ProcessInfo.processInfo.processName
ud.removePersistentDomain(forName: domain)

let device = "device-0x0358."
let penA = device + "tool-0xA."
let penB = device + "tool-0xB."
let penC = device + "tool-0xC."
let profile = device + "preset-P."
let override = device + "appOverride-com.example.paint."

func store(_ curve: BezierCurve, at prefix: String) {
    ud.set(try! JSONEncoder().encode(curve), forKey: prefix + "pressureCurve")
}
func stored(at prefix: String) -> BezierCurve? {
    ud.data(forKey: prefix + "pressureCurve").flatMap { try? JSONDecoder().decode(BezierCurve.self, from: $0) }
}

MainActor.assumeIsolated {
    @MainActor func serialPen(_ prefix: String) -> ToolSettings {
        ToolSettings(prefix: prefix, fallbackPrefix: device, toolID: prefix)
    }
    @MainActor func genericPen() -> ToolSettings { ToolSettings(prefix: device, toolID: "stylus") }

    var overrideMarks: [String] = []
    var profileMarks: [String] = []
    @MainActor func layer(_ tool: ToolSettings, override op: String? = nil, profileKeys keys: Set<String>? = nil) {
        tool.overridePrefix = op
        tool.profilePrefix = keys == nil ? nil : profile
        tool.profileKeys = keys ?? []
        tool.onOverrideKeyWritten = { overrideMarks.append($0) }
        tool.onProfileKeyWritten = { profileMarks.append($0) }
        tool.reload()
    }

    // 1. No profile, no override: each serial pen keeps its own curve, and
    //    a reload doesn't spread one pen's curve to the other.
    store(.soft, at: penA)
    store(.firm, at: penB)
    let a = serialPen(penA), b = serialPen(penB)
    layer(a); layer(b)
    expectEqual(a.pressureCurve, .soft, "pen A keeps its own curve")
    expectEqual(b.pressureCurve, .firm, "pen B keeps its own curve")
    a.reload(); b.reload()
    expectEqual(a.pressureCurve, .soft, "pen A after reload")
    expectEqual(b.pressureCurve, .firm, "pen B after reload")

    // 2. A profile holding a curve: a pen's own value beats it; a pen with
    //    none, and the generic pen, take the profile's.
    store(.linear, at: profile)
    let c = serialPen(penC), generic = genericPen()
    store(.soft, at: device)
    for t in [a, b, c, generic] { layer(t, profileKeys: ["pressureCurve"]) }
    expectEqual(a.pressureCurve, .soft, "pen A's own beats the profile")
    expectEqual(b.pressureCurve, .firm, "pen B's own beats the profile")
    expectEqual(c.pressureCurve, .linear, "pen with no own curve takes the profile's")
    expectEqual(generic.pressureCurve, .linear, "generic pen takes the profile's")
    expectEqual(c.valueSource("pressureCurve"), .builtIn, "valueSource reads string keys only")

    // 3. A profile key that isn't marked is ignored: the device applies.
    for t in [c, generic] { layer(t, profileKeys: []) }
    expectEqual(c.pressureCurve, .soft, "unmarked profile curve ignored; device curve applies")
    expectEqual(generic.pressureCurve, .soft, "generic pen: unmarked profile curve ignored")

    // 4. Edits with the profile active land by rule.
    for t in [a, generic] { layer(t, profileKeys: ["pressureCurve"]) }
    profileMarks.removeAll()
    a.pressureCurve = .firm
    expectEqual(stored(at: penA), .firm, "serial pen edit goes to the pen")
    expectEqual(stored(at: profile), .linear, "serial pen edit leaves the profile alone")
    expect(profileMarks.isEmpty, "serial pen edit marks nothing in the profile")
    generic.pressureCurve = .soft
    expectEqual(stored(at: profile), .soft, "generic pen edit goes to the active profile")
    expectEqual(profileMarks, ["pressureCurve"], "generic pen edit marks the profile key")
    expectEqual(stored(at: device), .soft, "generic pen edit leaves the device alone")

    // 5. No profile: the generic pen writes the device.
    layer(generic)
    generic.pressureCurve = .firm
    expectEqual(stored(at: device), .firm, "generic pen edit without a profile goes to the device")

    // 6. An app override beats everything, and edits go there, marked.
    store(.linear, at: override)
    for t in [a, b, generic] { layer(t, override: override, profileKeys: ["pressureCurve"]) }
    expectEqual(a.pressureCurve, .linear, "override beats pen A's own")
    expectEqual(b.pressureCurve, .linear, "override beats pen B's own")
    overrideMarks.removeAll()
    b.smoothingStrength = 0.4
    expectClose(ud.double(forKey: override + "smoothingStrength"), 0.4, 1e-9, "pen edit under an override goes to it")
    expect(ud.object(forKey: penB + "smoothingStrength") == nil, "and not to the pen")
    expectEqual(overrideMarks, ["smoothingStrength"], "and marks the override key")

    // 7. Leaving the override: each pen's own value is back.
    for t in [a, b] { layer(t) }
    expectEqual(a.pressureCurve, .firm, "pen A's own after the override")
    expectEqual(b.pressureCurve, .firm, "pen B's own after the override")
    expectClose(b.smoothingStrength, 0, 1e-9, "override smoothing doesn't stick to pen B")

    // 8. No layer holds a curve: back to linear, not the last one shown.
    ud.removeObject(forKey: penC + "pressureCurve")
    ud.removeObject(forKey: device + "pressureCurve")
    c.pressureCurve = .soft  // shown before the switch
    ud.removeObject(forKey: penC + "pressureCurve")
    layer(c)
    expectEqual(c.pressureCurve, .linear, "no stored curve resets to linear")

    // 9. Bindings use the same chain, and valueSource names the layer.
    ud.set("{\"kind\":\"rightClick\"}", forKey: profile + "penButton1Binding")
    ud.set("{\"kind\":\"middleClick\"}", forKey: penA + "penButton1Binding")
    layer(a, profileKeys: ["penButton1Binding"])
    layer(c, profileKeys: ["penButton1Binding"])
    layer(generic, profileKeys: ["penButton1Binding"])
    expectEqual(a.valueSource("penButton1Binding"), .pen, "pen's own binding beats the profile")
    expectEqual(c.valueSource("penButton1Binding"), .profile, "pen with none reads the profile")
    expectEqual(generic.valueSource("penButton1Binding"), .profile, "generic pen reads the profile")
    layer(a, override: override, profileKeys: ["penButton1Binding"])
    ud.set("{\"kind\":\"none\"}", forKey: override + "penButton1Binding")
    expectEqual(a.valueSource("penButton1Binding"), .appOverride, "override binding wins")
    layer(generic)
    expectEqual(generic.valueSource("penButton1Binding"), .builtIn, "no layer: built-in")

    // 10. Loading doesn't write: a reload with layers set leaves storage alone.
    let before = ud.dictionaryRepresentation().filter { $0.key.hasPrefix(device) }.count
    for t in [a, b, c, generic] { layer(t, override: override, profileKeys: ["pressureCurve"]) }
    let after = ud.dictionaryRepresentation().filter { $0.key.hasPrefix(device) }.count
    expectEqual(after, before, "reloading writes nothing")
}

ud.removePersistentDomain(forName: domain)
finish()
