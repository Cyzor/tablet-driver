// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// Replays real Wacom report descriptors through TabletKit's path for a Wacom
// the registry doesn't know: InterfaceRouting.decide with the product marked
// unregistered, GenericPenLayout.derive, and TabletSpec.guessed. Each device
// becomes one summary line, checked against goldens.txt.
//
// Modes:
//   (no arguments)        check fixtures.txt against goldens.txt
//   --write-goldens       rewrite goldens.txt from fixtures.txt
//   --survey <dir>        print one JSON object per Wacom device found in a
//                         wacom-hid-descriptors checkout, with the registry
//                         row alongside where the product is registered

import Foundation
import TabletKit

// MARK: - One device through the fallback

/// One interface: its descriptor and what the fallback makes of it.
struct InterfaceResult {
    var pairs: [(page: Int, usage: Int)]
    var maxInputReportSize: Int
    var route: String
    var pens: [GenericPenLayout]
    var guess: TabletSpec
    var pad: PadFeatures
    var touch: [PrecisionTouchLayout]
    var hasFingerCollection: Bool
}

/// What a descriptor declares for the pad, which the fallback doesn't read.
struct PadFeatures: Equatable {
    var buttons = 0
    /// Touch rings and the PTK-x70 dial both declare Wacom's ring usage.
    var rings = 0
    var strip = false
    var wheel = false

    var summary: String {
        var parts: [String] = []
        if buttons > 0 { parts.append("btn\(buttons)") }
        if rings > 0 { parts.append(rings > 1 ? "ring\(rings)" : "ring") }
        if strip { parts.append("strip") }
        if wheel { parts.append("wheel") }
        return parts.isEmpty ? "-" : parts.joined(separator: "+")
    }
}

/// Wacom's pad collections, as Linux's wacom driver finds them: Tablet
/// Function Keys on the Digitizer page or Wacom's digitizer page.
private let padCollections: Set<UInt32> = [0x000D_0039, 0xFF0D_0039]

private func padFeatures(_ layout: DescriptorLayout) -> PadFeatures {
    var pad = PadFeatures()
    var buttons = Set<UInt32>()
    for field in layout.reports.filter({ $0.direction == .input }).flatMap(\.fields) where !field.isConstant {
        let inPad = field.collectionPath.contains(where: padCollections.contains)
        switch field.extendedUsage {
        case 0xFF0D_0138: pad.rings += 1
        case 0xFF0D_0136, 0xFF0D_0137: pad.strip = true
        // Outside the pad, 0xFF0D0D03 is the airbrush finger wheel.
        case 0xFF0D_0D03 where inPad, 0x0001_0038 where inPad: pad.wheel = true
        default:
            let isButton = field.usagePage == 0x09
                || (field.usagePage == 0xFF0D && (0x0910...0x092F).contains(field.usage))
            if inPad, isButton { buttons.insert(field.extendedUsage) }
        }
    }
    pad.buttons = buttons.count
    return pad
}

/// A field in a Finger collection, on the Digitizer page or a vendor page,
/// as GenericPenLayout reads it.
private func isFinger(_ field: DescriptorField) -> Bool {
    field.collectionPath.contains { ($0 >> 16 == 0x0D || $0 >> 16 >= 0xFF00) && $0 & 0xFFFF == 0x22 }
}

private func topLevelPairs(_ layout: DescriptorLayout) -> [(page: Int, usage: Int)] {
    var seen: [UInt32] = []
    for field in layout.reports.flatMap(\.fields) {
        if let top = field.collectionPath.first, !seen.contains(top) { seen.append(top) }
    }
    return seen.map { (page: Int($0 >> 16), usage: Int($0 & 0xFFFF)) }
}

/// IOKit's MaxInputReportSize: the longest input report, report ID included.
private func maxInputReportSize(_ layout: DescriptorLayout) -> Int {
    layout.reports.filter { $0.direction == .input }
        .map { ($0.totalBits + 7) / 8 + ($0.reportID == 0 ? 0 : 1) }
        .max() ?? 0
}

func analyze(productID: Int, isBluetooth: Bool, descriptor: [UInt8]) -> InterfaceResult? {
    guard let layout = try? HIDReportDescriptorParser.parse(descriptor) else { return nil }
    let pairs = topLevelPairs(layout)
    var recorded = ReplayRecording.Interface()
    recorded.vendorID = 0x056A
    recorded.productID = productID
    recorded.usagePage = pairs.first?.page ?? 0
    recorded.usage = pairs.first?.usage ?? 0
    recorded.usagePairs = pairs.map { HIDUsagePair(page: $0.page, usage: $0.usage) }
    recorded.transport = isBluetooth ? "Bluetooth" : "USB"
    recorded.maxInputReportSize = maxInputReportSize(layout)
    recorded.reportDescriptor = descriptor
    let interface = ReplayInterface(recorded)

    let facts = InterfaceRouting.Facts(
        vendorID: 0x056A, productID: WacomDeviceRegistry.canonicalProductID(for: productID),
        usagePage: recorded.usagePage, usagePairs: pairs, isBluetooth: isBluetooth,
        isUnregistered: true)
    let route: String
    let decision = InterfaceRouting.decide(facts, attachedProductIDs: []) {
        SessionRouting.descriptorProbe(of: interface)
    }
    switch decision {
    case .wacomFallback: route = "fallback"
    case .observeTouchOnly: route = "observe"
    case .skip: route = "skip"
    case let other: route = "\(other)"
    }
    let inputs = layout.reports.filter { $0.direction == .input }.flatMap(\.fields)
    return InterfaceResult(
        pairs: pairs, maxInputReportSize: recorded.maxInputReportSize, route: route,
        pens: GenericPenLayout.derive(from: layout),
        guess: .guessed(
            forUnknownWacom: productID, name: "", maxInputReportSize: recorded.maxInputReportSize,
            descriptor: descriptor),
        pad: padFeatures(layout),
        touch: PrecisionTouchLayout.derive(from: layout),
        hasFingerCollection: inputs.contains(where: isFinger))
}

/// A device the way the session assembles it: the first interface routed to
/// the fallback is primary and supplies the spec; every interface's pen
/// reports join it.
struct DeviceResult {
    var productID: Int
    var isBluetooth: Bool
    var interfaces: [InterfaceResult]

    var primary: InterfaceResult? { interfaces.first { $0.route == "fallback" } }
    /// Pen reports by report ID, first interface wins, as DescriptorPenDecoder keeps them.
    var pens: [GenericPenLayout] {
        var byID: [UInt8: GenericPenLayout] = [:]
        for pen in interfaces.flatMap(\.pens) where byID[pen.reportID] == nil { byID[pen.reportID] = pen }
        return byID.values.sorted { $0.reportID < $1.reportID }
    }
    var pad: PadFeatures {
        interfaces.map(\.pad).reduce(into: PadFeatures()) {
            $0.buttons = max($0.buttons, $1.buttons)
            $0.rings = max($0.rings, $1.rings)
            $0.strip = $0.strip || $1.strip
            $0.wheel = $0.wheel || $1.wheel
        }
    }
    var touch: [PrecisionTouchLayout] { interfaces.flatMap(\.touch) }
}

private func hex(_ v: Int, _ width: Int = 4) -> String {
    "0x" + String(format: "%0\(width)X", v)
}

private func penFields(_ pen: GenericPenLayout) -> String {
    let named: [(String, DescriptorField?)] = [
        ("tip", pen.tipSwitch), ("range", pen.inRange), ("press", pen.tipPressure),
        ("barrel", pen.barrelSwitch), ("barrel2", pen.secondaryBarrel),
        ("eraser", pen.eraserSwitch), ("invert", pen.invert),
        ("tiltx", pen.tiltX), ("tilty", pen.tiltY), ("twist", pen.twist),
        ("hover", pen.hoverDistance), ("serial", pen.transducerSerial), ("tool", pen.toolType),
    ]
    return named.filter { $0.1 != nil }.map(\.0).joined(separator: ",")
}

private func penSummary(_ pen: GenericPenLayout) -> String {
    "r\(pen.reportID) \(pen.logicalMaxX)x\(pen.logicalMaxY) p\(pen.logicalMaxPressure) [\(penFields(pen))]"
}

private func initSummary(_ steps: [InitStep]) -> String {
    steps.map { step in
        switch step {
        case .featureReport(let b): "feature " + b.map { String(format: "%02x", $0) }.joined(separator: " ")
        default: "\(step)"
        }
    }.joined(separator: "; ")
}

extension DeviceResult {
    /// One line per device: every routing verdict, the descriptor pens, the
    /// guessed spec, and what the fallback leaves unread.
    var golden: String {
        let routes = interfaces.map(\.route).joined(separator: ",")
        let pens = self.pens.map(penSummary).joined(separator: " | ")
        let spec: String
        if let g = primary?.guess {
            spec = "\(g.format) \(g.maxX)x\(g.maxY) p\(g.maxPressure) btn\(g.buttonCount)"
                + " ring=\(g.hasTouchRing) eraser=\(g.hasEraser) touch=\(g.hasFingerTouch)"
                + " init=\(initSummary(g.initSteps))"
        } else {
            spec = "none"
        }
        let touch = self.touch.map { "r\($0.reportID) c\($0.slots.count) \($0.logicalMaxX)x\($0.logicalMaxY)" }
            .joined(separator: " | ")
        return "\(hex(productID)) \(isBluetooth ? "bt" : "usb") routes=\(routes)"
            + " pens=\(pens.isEmpty ? "-" : pens) spec=\(spec)"
            + " pad=\(pad.summary) touch=\(touch.isEmpty ? "-" : touch)"
    }
}

// MARK: - Fixtures

/// fixtures.txt: "device <pid> <usb|bt> <label>" starts a device; each
/// following "hex <bytes>" line is one of its interfaces.
func loadFixtures(_ url: URL) throws -> [(label: String, device: DeviceResult)] {
    var out: [(String, DeviceResult)] = []
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
        guard let tag = parts.first, !tag.hasPrefix("#") else { continue }
        if tag == "device", parts.count >= 3, let pid = Int(parts[1].dropFirst(2), radix: 16) {
            out.append((parts.count > 3 ? parts[3] : "", DeviceResult(productID: pid, isBluetooth: parts[2] == "bt", interfaces: [])))
        } else if tag == "hex", parts.count >= 2, !out.isEmpty {
            let hexString = line.dropFirst(4).filter { !$0.isWhitespace }
            var bytes: [UInt8] = []
            var i = hexString.startIndex
            while i < hexString.endIndex, let j = hexString.index(i, offsetBy: 2, limitedBy: hexString.endIndex) {
                bytes.append(UInt8(hexString[i..<j], radix: 16)!)
                i = j
            }
            let d = out[out.count - 1].1
            if let result = analyze(productID: d.productID, isBluetooth: d.isBluetooth, descriptor: bytes) {
                out[out.count - 1].1.interfaces.append(result)
            }
        }
    }
    return out
}

// MARK: - Survey

private func registryJSON(_ s: TabletSpec?) -> Any {
    guard let s else { return NSNull() }
    return [
        "name": s.name, "format": "\(s.format)", "maxX": s.maxX, "maxY": s.maxY,
        "maxPressure": s.maxPressure, "buttonCount": s.buttonCount,
        "bezelButtonCount": s.bezelButtonCount, "ring": s.hasTouchRing,
        "dualRings": s.hasDualRings, "strips": s.hasTouchStrips, "dial": s.hasMechanicalDial,
        "fingerTouch": s.hasFingerTouch, "maxTouchContacts": s.maxTouchContacts,
        "touchMaxX": s.touchMaxX, "touchMaxY": s.touchMaxY, "eraser": s.hasEraser,
        "tilt": s.hasTilt, "init": initSummary(s.initSteps), "touchCompanionPID": s.touchCompanionPID.map { $0 as Any } ?? NSNull(),
    ] as [String: Any]
}

private func penJSON(_ p: GenericPenLayout) -> [String: Any] {
    ["reportID": Int(p.reportID), "maxX": p.logicalMaxX, "maxY": p.logicalMaxY,
     "maxPressure": p.logicalMaxPressure, "fields": penFields(p)]
}

func survey(_ root: URL) throws {
    let name = try NSRegularExpression(pattern: #"^([0-9A-Fa-f]{4}):056[Aa]:([0-9A-Fa-f]{4})\.([0-9A-Fa-f]+)\.hid\.bin$"#)
    var groups: [String: [(instance: Int, bus: Int, pid: Int, url: URL)]] = [:]
    var empty = 0
    let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
    for case let url as URL in walker {
        let url = url.resolvingSymlinksInPath()
        let file = url.lastPathComponent
        guard let m = name.firstMatch(in: file, range: NSRange(file.startIndex..., in: file)) else { continue }
        func group(_ i: Int) -> Int { Int(file[Range(m.range(at: i), in: file)!], radix: 16)! }
        let bus = group(1), pid = group(2)
        let key = "\(url.deletingLastPathComponent().path)|\(bus)|\(pid)"
        groups[key, default: []].append((group(3), bus, pid, url))
    }
    let encoder = { (o: Any) in String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)! }
    for key in groups.keys.sorted() {
        let files = groups[key]!.sorted { $0.instance < $1.instance }
        let bus = files[0].bus, pid = files[0].pid
        var device = DeviceResult(productID: pid, isBluetooth: bus == 5, interfaces: [])
        var descriptors: [String] = []
        for f in files {
            let bytes = [UInt8]((try? Data(contentsOf: f.url)) ?? Data())
            if bytes.isEmpty { empty += 1; continue }
            descriptors.append(bytes.map { String(format: "%02x", $0) }.joined())
            if let r = analyze(productID: pid, isBluetooth: bus == 5, descriptor: bytes) { device.interfaces.append(r) }
        }
        guard !device.interfaces.isEmpty else { continue }
        let canonical = WacomDeviceRegistry.canonicalProductID(for: pid)
        let row = WacomDeviceRegistry.spec(for: canonical)
        let companion = row?.touchCompanionPID.flatMap { WacomDeviceRegistry.spec(for: $0) }
        let parent = WacomDeviceRegistry.knownDevices.first { $0.touchCompanionPID == canonical }
        let g = device.primary?.guess
        let obj: [String: Any] = [
            "dir": key.split(separator: "|")[0].replacingOccurrences(of: root.resolvingSymlinksInPath().path + "/", with: ""),
            "bus": bus, "pid": hex(pid), "canonical": hex(canonical),
            "descriptors": descriptors,
            "routes": device.interfaces.map(\.route),
            "pairs": device.interfaces.map { $0.pairs.map { hex($0.page) + "/" + hex($0.usage) } },
            "maxInputReportSizes": device.interfaces.map(\.maxInputReportSize),
            "pens": device.pens.map(penJSON),
            "penInterfaces": device.interfaces.enumerated().filter { !$0.element.pens.isEmpty }.map(\.offset),
            "guess": g.map { [
                "format": "\($0.format)", "maxX": $0.maxX, "maxY": $0.maxY, "maxPressure": $0.maxPressure,
                "buttonCount": $0.buttonCount, "init": initSummary($0.initSteps),
                "eraser": $0.hasEraser, "tilt": $0.hasTilt,
            ] as [String: Any] } ?? NSNull(),
            "guessesPerInterface": device.interfaces.map { "\($0.guess.format) \($0.guess.maxX)x\($0.guess.maxY) p\($0.guess.maxPressure)" },
            "pad": ["buttons": device.pad.buttons, "rings": device.pad.rings, "strip": device.pad.strip, "wheel": device.pad.wheel],
            "touch": device.touch.map { ["reportID": Int($0.reportID), "contacts": $0.slots.count, "maxX": $0.logicalMaxX, "maxY": $0.logicalMaxY] },
            "fingerCollection": device.interfaces.contains(where: \.hasFingerCollection),
            "registry": registryJSON(row),
            "registryCompanion": registryJSON(companion),
            "registryParent": registryJSON(parent),
            "golden": device.golden,
        ]
        print(encoder(obj))
    }
    FileHandle.standardError.write(Data("skipped \(empty) empty descriptor files\n".utf8))
}

// MARK: - Main

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let args = CommandLine.arguments.dropFirst()
if args.first == "--survey", let path = args.dropFirst().first {
    try survey(URL(fileURLWithPath: path))
    exit(0)
}
let fixtures = try loadFixtures(dir.appendingPathComponent("fixtures.txt"))
let lines = fixtures.map { "# \($0.label)\n\($0.device.golden)" }
let goldensURL = dir.appendingPathComponent("goldens.txt")
if args.first == "--write-goldens" {
    try (lines.joined(separator: "\n") + "\n").write(to: goldensURL, atomically: true, encoding: .utf8)
    print("Wrote \(fixtures.count) goldens")
    exit(0)
}
let expected = try String(contentsOf: goldensURL, encoding: .utf8)
    .split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init)
var failures = 0
if expected.count != fixtures.count {
    print("FAIL: \(fixtures.count) fixtures, \(expected.count) goldens")
    failures += 1
}
for (i, f) in fixtures.enumerated() where i < expected.count && f.device.golden != expected[i] {
    print("FAIL: \(f.label)\n  expected: \(expected[i])\n  actual:   \(f.device.golden)")
    failures += 1
}
if failures > 0 {
    print("\(failures) of \(fixtures.count) devices changed. If intended, rerun with --write-goldens.")
    exit(1)
}
print("All \(fixtures.count) unknown-Wacom fallback checks passed.")
