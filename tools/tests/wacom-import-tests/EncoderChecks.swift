// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// Checks the encoder against the fixture's report: what each scope would
// store, read back with MockTab's own setting types.

import AppKit
import Foundation

func checkEncoder(_ report: Report, _ expect: (Bool, String) -> Void) {
    func bindings(_ v: Any?) -> [ButtonBinding] { (v as? String).flatMap(ButtonBinding.decodeList) ?? [] }
    func binding(_ v: Any?) -> ButtonBinding? { (v as? String).flatMap { ButtonBinding.decode($0) } }
    func slots(_ v: Any?) -> [ControlSlot] {
        (v as? Data).flatMap { try? JSONDecoder().decode([ControlSlot].self, from: $0) } ?? []
    }
    func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.0005 } ?? false }

    // PTH-660
    guard let pth = try? WacomEncoder.encode(report.tablets[0]) else {
        expect(false, "PTH-660 encodes")
        return
    }
    expect(pth.productID == 0x0357 && pth.nickname == "Studio", "Tablet identity")
    let keys = bindings(pth.device["expressKeyBindings"])
    expect(keys.count == 16, "Sixteen ExpressKeys: \(keys.count)")
    if keys.count == 16 {
        expect(keys[0].kind == .keyCombo && keys[0].keyCode == 18 && keys[0].keyLabel == "1", "Key 1: \(keys[0])")
        expect(keys[1].keyCode == 6 && keys[1].modifierFlags == CGEventFlags.maskCommand.rawValue, "Key 2 is ⌘Z")
        expect(keys[2] == ButtonBinding(modifierOnly: .option), "Key 3 holds ⌥")
        expect(keys[3].kind == .spacebar, "Key 4 holds space")
        expect(keys[4].keyCode == 48 && keys[4].modifierFlags == CGEventFlags.maskShift.rawValue, "Key 5 is ⇧⇥")
        expect(keys[5...].allSatisfy { $0 == .none }, "Keys the import can't carry, and the rest, are None")
    }
    let ring = slots(pth.device["touchRingSlotsJSON"])
    expect(ring.count == 5, "One slot per Wacom mode: \(ring.count)")
    if ring.count == 5 {
        expect(ring[0].action == .keyPress && ring[0].label == "Brush size", "Key mode keeps its name")
        expect(ring[0].cwBinding.keyCode == 33 && ring[0].ccwBinding.keyCode == 30, "Clockwise [, counterclockwise ]")
        expect(ring[1].action == .scroll, "Auto scroll and zoom is Scroll")
        expect(ring[2].action == .rotate, "Rotate")
        expect(ring[3].action == .off && ring[4].action == .off, "Unknown and disabled modes are Off")
    }
    expect(pth.device["touchRingActiveSlotIndex"] as? Int == 0, "Ring starts on its first mode")
    expect(near(pth.device["activeAreaX"] as? Double, 0.1) && near(pth.device["activeAreaY"] as? Double, 0.25)
           && near(pth.device["activeAreaWidth"] as? Double, 0.5) && near(pth.device["activeAreaHeight"] as? Double, 0.5),
           "Tablet area")
    expect(pth.device["rotariesJSON"] == nil, "A ring tablet writes no dial modes")

    expect(pth.pens.map(\.id) == ["0x12345678"], "Only the pen with a serial: \(pth.pens.map(\.id))")
    if let pen = pth.pens.first {
        expect(pen.nickname == "Inking pen", "Pen name")
        expect(binding(pen.values["tipBinding"])?.kind == .leftClick, "Tip")
        expect(binding(pen.values["eraserBinding"])?.kind == .eraser, "Eraser")
        expect(binding(pen.values["penButton1Binding"])?.kind == .rightClick, "Lower button")
        expect(pen.values["penButton2Binding"] == nil, "An unverified button isn't written")
        expect(binding(pen.values["penButton3Binding"]) == ButtonBinding.none, "A button with no equivalent is None")
        expect(near(pen.values["pressureThreshold"] as? Double, 0.0501), "Threshold")
        let curve = (pen.values["pressureCurve"] as? Data).flatMap { try? JSONDecoder().decode(BezierCurve.self, from: $0) }
        expect(near(curve.map { Double($0.p1.x) }, 0.8159) && near(curve.map { Double($0.p1.y) }, 0.1667)
               && curve?.p1 == curve?.p2, "Curve through Wacom's midpoint: \(String(describing: curve))")
    }
    expect(pth.leftOut.contains { $0.control == "Upper button" }, "The unverified button is listed as left out")

    expect(pth.apps.map(\.bundleID) == ["com.example.paint"], "Only the app with differences: \(pth.apps.map(\.bundleID))")
    if let paint = pth.apps.first {
        let appKeys = bindings(paint.values["expressKeyBindings"])
        expect(appKeys.count == 16 && appKeys[1].modifierFlags == (CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue)
               && appKeys[0].keyCode == 18, "App keys: All applications' with the app's change")
        let appRing = slots(paint.values["touchRingSlotsJSON"])
        expect(appRing.count == 5 && appRing[0].action == .scroll && appRing[2].action == .rotate,
               "App ring: All applications' with the app's change")
        expect(binding(paint.values["penButton1Binding"])?.kind == .clickLock, "App pen button")
        expect(paint.values["tipBinding"] == nil && paint.values["activeAreaX"] == nil, "App writes only its changes")
    }

    // PTK-870
    if let ptk = try? WacomEncoder.encode(report.tablets[1]) {
        let k = bindings(ptk.device["expressKeyBindings"])
        expect(k.count == 16 && k[0].keyCode == 126 && k[7].kind == .rightClick, "PTK-870 keys")
        expect(binding(ptk.device["touchRingButtonBinding"])?.kind == .ringCycle
               && binding(ptk.device["touchRingButtonBinding2"])?.kind == .ringCycle2, "Dial keys")
        let set = (ptk.device["rotariesJSON"] as? Data).flatMap { try? JSONDecoder().decode(RotarySet.self, from: $0) }
        expect(set?.controls.count == 2, "Two dials")
        expect(set?.controls.first?.slots.map(\.action) == [.skip]
               && set?.controls.last?.slots.map(\.action) == [.rotate], "Each dial's modes")
    } else {
        expect(false, "PTK-870 encodes")
    }

    // No product ID
    expect((try? WacomEncoder.encode(report.tablets[2])) == nil, "A tablet without a product ID doesn't encode")

    // Unchecked positions and unverified values leave MockTab's settings alone.
    if let intuos = try? WacomEncoder.encode(report.tablets[3]) {
        expect(intuos.device["expressKeyBindings"] == nil, "Unchecked key positions leave ExpressKeys alone")
    } else {
        expect(false, "Intuos encodes")
    }
    var ignored: [Line] = []
    let unsure = AppReport(name: "All applications", bundleID: nil, sections: [Section(title: "ExpressKeys", lines: [Line(
        control: "LeftButton5", wacom: "disabled", outcome: .mapped("touchRingButtonBinding: none", .unverified),
        action: .binding(.kind("none")), setting: .binding("touchRingButtonBinding"))])])
    expect(Controls(unsure, leftOut: &ignored).storedSettings(complete: true)["touchRingButtonBinding"] == nil,
           "An unverified dial key keeps its setting")

    // Pens that disagree on an app's settings
    var two = report.tablets[0]
    if let i = two.apps.firstIndex(where: { $0.bundleID == "com.example.paint" && $0.notes.isEmpty }) {
        var other = two.apps[i].sections.first { $0.pen != nil }!
        other = Section(title: "Pen 0x0000BEEF", lines: [Line(
            control: "Lower button", wacom: "right click", outcome: .mapped("penButton1Binding: rightClick", .exact),
            action: .binding(.kind("rightClick")), setting: .binding("penButton1Binding"))], pen: 0xBEEF)
        two.apps[i].sections.append(other)
        do {
            _ = try WacomEncoder.encode(two)
            expect(false, "Disagreeing pens stop the encode")
        } catch let e as EncodeError {
            expect(e == .pensDisagree(app: "Paint", pens: ["0x0000BEEF", "0x12345678"]), "Error names both pens: \(e)")
        } catch {
            expect(false, "Wrong error: \(error)")
        }
        let picked = try? WacomEncoder.encode(two, pen: 0xBEEF)
        expect(binding(picked?.apps.first?.values["penButton1Binding"])?.kind == .rightClick, "--pen picks one pen")
    } else {
        expect(false, "Fixture has Paint")
    }

    // A second pen with no Paint settings uses All applications in Paint, so
    // it disagrees with the pen that has some.
    var plain = report.tablets[0]
    plain.apps[0].sections.append(Section(title: "Pen 0x0000CAFE", lines: [], pen: 0xCAFE))
    do {
        _ = try WacomEncoder.encode(plain)
        expect(false, "A pen without app settings stops the encode")
    } catch let e as EncodeError {
        expect(e == .pensDisagree(app: "Paint", pens: ["0x0000CAFE", "0x12345678"]), "Error names the plain pen: \(e)")
    } catch {
        expect(false, "Wrong error: \(error)")
    }
    let penKeys = ["tipBinding", "eraserBinding", "penButton1Binding", "penButton2Binding", "penButton3Binding",
                   "pressureThreshold", "pressureCurve"]
    let paint = (try? WacomEncoder.encode(plain, pen: 0xCAFE))?.apps.first { $0.bundleID == "com.example.paint" }
    expect(paint != nil && penKeys.allSatisfy { paint?.values[$0] == nil },
           "--pen with the plain pen writes no Paint pen settings")
    let other = (try? WacomEncoder.encode(plain, pen: 0x12345678))?.apps.first { $0.bundleID == "com.example.paint" }
    expect(penKeys.contains { other?.values[$0] != nil }, "--pen with the other pen writes its Paint settings")

    // --pen naming a pen the tablet lacks
    do {
        _ = try WacomEncoder.encode(report.tablets[0], pen: 0x1234)
        expect(false, "An unknown --pen stops the encode")
    } catch let e as EncodeError {
        expect(e == .unknownPen("0x00001234", known: ["0x12345678"]), "Error lists the tablet's pens: \(e)")
    } catch {
        expect(false, "Wrong error: \(error)")
    }
    expect((try? WacomEncoder.encode(report.tablets[0], pen: 0x12345678)) != nil, "A known --pen encodes")
}
