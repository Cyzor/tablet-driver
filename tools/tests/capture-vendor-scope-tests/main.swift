// Checks the rule that keeps unrelated hardware out of capture files.
//
// A capture started with no tablet present profiles every HID device on the
// bus — if the tablet is invisible to the OS, that absence is the diagnosis.
// The bug this pins: such a session kept everything even after the real tablet
// turned up. One 11-interface capture recorded a Bluetooth trackpad and a Mac
// accelerometer, and took the accelerometer as its primary device. Capture
// files get attached to public issues, so that is a privacy leak.
//
// Mirrors `CaptureEngine.tabletOnly` and `TabletManager.knownVendorIDs`, kept
// standalone because those live on @MainActor types that drag in IOKit and
// TabletKit; the rule itself is pure vendor-ID logic.

import Foundation

let knownVendorIDs: [Int] = [0x056A, 0x0531, 0x256C, 0x28BD, 0x5543]

struct Interface {
    let vendorID: Int
    let label: String
}

func tabletOnly(_ sessions: [Interface]) -> [Interface] {
    let tabletVendors = Set(knownVendorIDs)
    guard sessions.contains(where: { tabletVendors.contains($0.vendorID) })
    else { return sessions }
    return sessions.filter { tabletVendors.contains($0.vendorID) }
}

var checks = 0
var failures = 0
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        failures += 1
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    }
}

let wacomPen = Interface(vendorID: 0x056A, label: "PTK-870 pen")
let wacomVendorIface = Interface(vendorID: 0x056A, label: "PTK-870 vendor")
let appleTrackpad = Interface(vendorID: 0x004C, label: "GlossyFrostyTrackpad")
let appleAccel = Interface(vendorID: 0x05AC, label: "accel")
let xencelabs = Interface(vendorID: 0x28BD, label: "Xencelabs pen")

// The reported capture: two tablet interfaces swept up with nine Apple ones.
do {
    let mixed = [appleAccel, wacomPen, appleTrackpad, wacomVendorIface, appleAccel]
    let kept = tabletOnly(mixed)
    expect(kept.count == 2, "only the two tablet interfaces survive, got \(kept.count)")
    expect(
        !kept.contains { $0.vendorID == 0x004C || $0.vendorID == 0x05AC },
        "no Apple-vendor interface may reach a capture file once a tablet is present")
}

// The case the broad sweep exists for: nothing recognized, so keep it all.
// Narrowing here would destroy the only evidence an unknown-device report has.
do {
    let unknownOnly = [appleAccel, appleTrackpad]
    let kept = tabletOnly(unknownOnly)
    expect(
        kept.count == 2,
        "with no known tablet present every interface is kept — that is the unrecognized-hardware case")
}

// A second tablet vendor on the desk is legitimate company, not noise.
do {
    let twoVendors = [wacomPen, xencelabs, appleTrackpad]
    let kept = tabletOnly(twoVendors)
    expect(kept.count == 2, "both tablet vendors survive, got \(kept.count)")
    expect(
        kept.contains { $0.vendorID == 0x28BD },
        "a Xencelabs device must not be dropped just because a Wacom is present")
}

// Ordering must survive: the first entry names the hardware in the header.
do {
    let kept = tabletOnly([appleAccel, wacomPen, appleTrackpad, wacomVendorIface])
    expect(
        kept.first?.label == "PTK-870 pen",
        "filtering must preserve order so the header still names the tablet, got \(kept.first?.label ?? "<none>")")
}

// Already-clean sessions pass through untouched.
do {
    let clean = [wacomPen, wacomVendorIface]
    expect(tabletOnly(clean).count == 2, "an all-tablet session is unchanged")
    expect(tabletOnly([]).isEmpty, "an empty session stays empty")
}

if failures > 0 {
    FileHandle.standardError.write(
        Data("capture-vendor-scope-tests: \(failures)/\(checks) checks FAILED\n".utf8))
    exit(1)
}
print("ok — \(checks) checks passed")
