// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Checks for `discoveryFindings(for:)` — the triage observations computed at
// export from data a capture already carries.
//
// Runs against the real submitted capture set for Cyzor/tablet-driver#14 (a
// Cintiq 27QHD Touch) when it's present, because that case is the reason the
// findings block exists: across nine files and three rounds of follow-up,
// "the pen report never fired" was derivable from the first file and went
// unnoticed. Those fixtures live outside the repo, so their checks are
// skipped rather than failed when absent; the synthetic checks always run.

import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition {
        failures += 1
        FileHandle.standardError.write(Data("FAIL: \(label)\n".utf8))
    }
}

// MARK: - Fixtures

func makeResult(
    productID: String = "0x032B",
    duration: TimeInterval = 21.4,
    declaredInput: [String] = [],
    observed: [String] = [],
    toolCodes: [String]? = nil,
    touchEnabled: Bool? = nil
) -> DiscoveryResult {
    var layouts: [String: LiveHIDDescriptorInspector.ReportLayout] = [:]
    for id in declaredInput {
        layouts["input:\(id)"] = LiveHIDDescriptorInspector.ReportLayout(
            reportID: 0, direction: .input, fields: [])
    }
    var reports: [String: DiscoveryReportSummary] = [:]
    for id in observed {
        reports[id] = DiscoveryReportSummary(
            reportID: 0, length: 10, maxLength: 10, lengthVaried: false, sampleCount: 1,
            varyingBytes: [], constantBytes: [])
    }
    return DiscoveryResult(
        capturedAt: Date(),
        mode: "discovery",
        duration: duration,
        deviceInfo: DiscoveryDeviceInfo(
            vendorID: "0x056A", productID: productID, name: "Test Device"),
        reports: reports,
        hidReportDescriptor: LiveHIDDescriptorInspector.Parsed(
            rawHex: nil, rawLength: 0, reports: layouts),
        observedToolCodes: toolCodes,
        touchSettings: touchEnabled.map { enabled in
            DiscoveryTouchSettings(
                touchEnabled: enabled, tapToClick: false, twoFingerScroll: false,
                pinchZoom: false, sensitivity: 1, areaX: 0, areaY: 0, areaWidth: 1,
                areaHeight: 1)
        })
}

// MARK: - Checks

func runChecks() {
// MARK: Declared-but-never-observed

// The issue #14 shape: five declared input reports, one ever arrives.
let partial = makeResult(
    declaredInput: ["0x01", "0x10", "0x11", "0x63", "0xAC"], observed: ["0x11"])
let partialFindings = discoveryFindings(for: partial)
let missingFinding = partialFindings.first { $0.kind == "declaredReportsNeverObserved" }
check(missingFinding != nil, "reports declared but never observed are reported")
check(
    missingFinding?.detail.contains("0x01, 0x10, 0x63, 0xAC") == true,
    "every missing report is listed, in ascending order")
check(
    missingFinding?.detail.contains("0x11") == false,
    "the report that did arrive is not listed as missing")
check(missingFinding?.productID == "0x032B", "finding is attributed to its device")

// A device that sent everything it declared has nothing to say.
let complete = makeResult(
    declaredInput: ["0x01", "0x10"], observed: ["0x01", "0x10"], toolCodes: ["0x0802"])
check(
    discoveryFindings(for: complete).isEmpty,
    "a capture with nothing notable produces no findings")

// Singular vs. plural, since this text is read by a human.
let single = makeResult(declaredInput: ["0x01", "0x10"], observed: ["0x10"])
let singleDetail = discoveryFindings(for: single)
    .first { $0.kind == "declaredReportsNeverObserved" }?.detail ?? ""
check(singleDetail.contains("Declared input report 0x01"), "one missing report reads singular")
check(!singleDetail.contains("reports"), "one missing report doesn't say 'reports'")

// A device with no readable descriptor can't have this finding claimed about
// it: absence of a declaration is not evidence a report didn't arrive.
var noDescriptor = makeResult(observed: ["0x11"], toolCodes: ["0x0802"])
noDescriptor.hidReportDescriptor = nil
check(
    !discoveryFindings(for: noDescriptor).contains { $0.kind == "declaredReportsNeverObserved" },
    "no descriptor means no declared-report finding")

// MARK: - Proximity and settings

check(
    discoveryFindings(for: makeResult(toolCodes: []))
        .contains { $0.kind == "noToolCodeObserved" },
    "an empty tool-code list reports no pen proximity")
check(
    discoveryFindings(for: makeResult(toolCodes: ["0x0802"]))
        .contains { $0.kind == "noToolCodeObserved" } == false,
    "an observed tool code suppresses the proximity finding")
check(
    discoveryFindings(for: makeResult(toolCodes: ["0x0802"], touchEnabled: false))
        .contains { $0.kind == "touchDisabledInSettings" },
    "touch switched off in settings is reported")
check(
    discoveryFindings(for: makeResult(toolCodes: ["0x0802"], touchEnabled: true))
        .contains { $0.kind == "touchDisabledInSettings" } == false,
    "touch switched on produces no setting finding")

// MARK: - Real submitted captures

// Path is relative to this harness; absent on a fresh clone.
let fixtureDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(
        "Notes/Scratch/Device-Diagnostics/Submitted-Discovery-Data-Capture/Wacom-Cintiq-DTH-2700")

if let files = try? FileManager.default.contentsOfDirectory(atPath: fixtureDir.path) {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var examined = 0
    for name in files.sorted() where name.hasSuffix(".json") {
        guard let data = try? Data(contentsOf: fixtureDir.appendingPathComponent(name)),
            let result = try? decoder.decode(DiscoveryResult.self, from: data)
        else { continue }
        examined += 1
        let found = discoveryFindings(for: result)
        // Every capture in this set observed exactly one of its declared
        // input reports — that is the whole point of the case.
        check(
            found.contains { $0.kind == "declaredReportsNeverObserved" },
            "\(name): silent declared reports are surfaced")
        check(
            found.contains { $0.kind == "noToolCodeObserved" },
            "\(name): no pen ever entered proximity in this set")
    }
    if examined > 0 {
        FileHandle.standardError.write(
            Data("note: checked \(examined) submitted capture files\n".utf8))
    }
}

}

// MARK: - Result

@main
enum CaptureFindingsTestRunner {
    static func main() {
        runChecks()
        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("\(failures) of \(checks) checks failed\n".utf8))
            exit(1)
        }
    }
}
