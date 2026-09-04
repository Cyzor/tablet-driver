// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// DescriptorOpacityTests.swift — Standalone checks for LiveHIDDescriptorInspector's
// readability primitive, against three real hardware captures:
//   - Wacom CTH-690:        Notes/Scratch/Discovery-Data-Caputure/mocktab_discovery_0x033E_20260703_004619.json
//   - Wacom Intuos5 touch L: Notes/Scratch/Discovery-Data-Caputure/descriptor_wacom_intuos5touch_0x0028_20260717.txt
//   - Xencelabs (pen + Quick Keys interfaces): Notes/Scratch/Discovery-Data-Caputure/descriptor_xencelabs_0x28bd_20260717.txt
//
// The app has no XCTest target (by design — see the project's test conventions),
// so this runs as a small executable compiled against the real LiveHIDDescriptorInspector.swift.
// Run via tools/tests/descriptor-opacity-tests/run.sh. Exits non-zero on the first failure.

import Foundation

// MARK: - Tiny assertion harness

private var failures = 0
private var checks = 0

private func expect(_ condition: Bool, _ message: @autoclosure () -> String,
                    file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition {
        failures += 1
        FileHandle.standardError.write(Data("FAIL (\(file):\(line)): \(message())\n".utf8))
    }
}

// MARK: - Field fixture helper

private func field(page: UInt32, usage: UInt32) -> LiveHIDDescriptorInspector.Field {
    LiveHIDDescriptorInspector.Field(
        usagePage: page, usage: usage, bitSize: 8, reportCount: 1,
        logicalMin: 0, logicalMax: 255, physicalMin: 0, physicalMax: 0,
        unit: 0, unitExponent: 0)
}

// MARK: - Fixtures (transcribed from real hardware captures, 2026-07-17)

/// Wacom CTH-690, USB 0x056A:0x033E — both input reports live entirely on a
/// vendor-defined page. The obvious opacity case.
private func cth690() -> LiveHIDDescriptorInspector.Parsed {
    let reports: [String: LiveHIDDescriptorInspector.ReportLayout] = [
        "input:0x02": .init(reportID: 0x02, direction: .input,
                             fields: [field(page: 0xFF00, usage: 0x01)]),
        "input:0x03": .init(reportID: 0x03, direction: .input,
                             fields: [field(page: 0xFF00, usage: 0x01)]),
    ]
    return .init(rawHex: nil, rawLength: 0, reports: reports)
}

/// Wacom Intuos5 touch L, USB 0x056A:0x0028 — pen/touch reports sit on the
/// *correct* Digitizer page (0x0D) but every usage code is 0x00 (undefined).
/// The trap: page alone says "Digitizer," usage says "meaningless."
private func intuos5TouchL() -> LiveHIDDescriptorInspector.Parsed {
    let reports: [String: LiveHIDDescriptorInspector.ReportLayout] = [
        // Readable: standard button/X/Y/wheel report.
        "input:0x01": .init(reportID: 0x01, direction: .input, fields: [
            field(page: 0x09, usage: 0x01),
            field(page: 0x09, usage: 0x02),
            field(page: 0x09, usage: 0x03),
            field(page: 0x01, usage: 0x30),
            field(page: 0x01, usage: 0x31),
            field(page: 0x01, usage: 0x38),
        ]),
        // Opaque: right usage page, meaningless usage codes.
        "input:0x02": .init(reportID: 0x02, direction: .input,
                             fields: [field(page: 0x0D, usage: 0x00)]),
        "input:0x03": .init(reportID: 0x03, direction: .input,
                             fields: [field(page: 0x0D, usage: 0x00)]),
        "input:0xc0": .init(reportID: 0xC0, direction: .input,
                             fields: [field(page: 0x0D, usage: 0x00)]),
        // Fully vendor-defined second interface (distinct report ID; the real
        // device exposes this on a separate IOHIDDevice interface entirely).
        "input:0x91": .init(reportID: 0x91, direction: .input,
                             fields: [field(page: 0xFF00, usage: 0x01)]),
    ]
    return .init(rawHex: nil, rawLength: 0, reports: reports)
}

/// Xencelabs Pen Display, USB 0x28BD:0x520D — pen interface uses real Digitizer/
/// Generic-Desktop usages; a separate interface opaques its LED/OLED control
/// channel behind a vendor-defined page. Opacity here is scoped to one channel,
/// not the whole device.
private func xencelabsPenDisplay() -> LiveHIDDescriptorInspector.Parsed {
    let reports: [String: LiveHIDDescriptorInspector.ReportLayout] = [
        "input:0x07": .init(reportID: 0x07, direction: .input, fields: [
            field(page: 0x0D, usage: 0x42), // TipSwitch
            field(page: 0x0D, usage: 0x44), // BarrelSwitch
            field(page: 0x0D, usage: 0x45), // Eraser
            field(page: 0x0D, usage: 0x32), // InRange
            field(page: 0x01, usage: 0x30), // X
            field(page: 0x01, usage: 0x31), // Y
            field(page: 0x0D, usage: 0x30), // TipPressure
            field(page: 0x0D, usage: 0x3D), // XTilt
            field(page: 0x0D, usage: 0x3E), // YTilt
        ]),
        "input:0x02": .init(reportID: 0x02, direction: .input,
                             fields: [field(page: 0xFF0A, usage: 0x02)]),
        "output:0x02": .init(reportID: 0x02, direction: .output,
                              fields: [field(page: 0xFF0A, usage: 0x03)]),
    ]
    return .init(rawHex: nil, rawLength: 0, reports: reports)
}

// MARK: - Tests

private func testCTH690IsFullyOpaque() {
    let p = cth690()
    expect(!p.hasAnyReadableField, "CTH-690 should have no readable fields")
    for (key, report) in p.reports {
        expect(!report.isReadable, "CTH-690 report \(key) should be opaque")
    }
}

private func testIntuos5TouchLMixedButOverallReadable() {
    let p = intuos5TouchL()
    expect(p.hasAnyReadableField,
           "Intuos5 touch L has one standard report; hasAnyReadableField must be true")
    expect(p.reports["input:0x01"]?.isReadable == true,
           "input:0x01 (button/X/Y/wheel) should be readable")
    expect(p.reports["input:0x02"]?.isReadable == false,
           "input:0x02 sits on page 0x0D with usage 0x00 — must NOT be readable "
           + "despite being on the Digitizer page (the trap this primitive exists to catch)")
    expect(p.reports["input:0x03"]?.isReadable == false,
           "input:0x03 sits on page 0x0D with usage 0x00 — must NOT be readable")
}

private func testDigitizerPageWithZeroUsageIsOpaque() {
    // Isolated regression guard for the specific trap: page 0x0D alone must never
    // be treated as sufficient evidence of readability.
    let f = field(page: 0x0D, usage: 0x00)
    expect(!f.isReadable, "page=0x0D usage=0x00 must be opaque, not readable")
}

private func testXencelabsPenInterfaceIsReadable() {
    let p = xencelabsPenDisplay()
    expect(p.reports["input:0x07"]?.isReadable == true,
           "Xencelabs pen interface uses real Digitizer/Generic-Desktop usages")
}

private func testXencelabsControlChannelIsOpaque() {
    let p = xencelabsPenDisplay()
    expect(p.reports["input:0x02"]?.isReadable == false,
           "Xencelabs LED/OLED control channel (0xFF0A) should be opaque")
    expect(p.reports["output:0x02"]?.isReadable == false,
           "Xencelabs LED/OLED control channel (0xFF0A) should be opaque")
}

private func testXencelabsIsNotUniformlyOpaque() {
    let p = xencelabsPenDisplay()
    expect(p.hasAnyReadableField,
           "Xencelabs opacity is scoped to one interface, not the whole device")
}

private func testVendorPageAboveFF00ThresholdIsOpaque() {
    expect(!field(page: 0xFF00, usage: 0x01).isReadable, "0xFF00 must be opaque")
    expect(!field(page: 0xFFFF, usage: 0x01).isReadable, "0xFFFF must be opaque")
}

private func testKnownPagesWithNonzeroUsageAreReadable() {
    expect(field(page: 0x01, usage: 0x30).isReadable, "Generic Desktop X should be readable")
    expect(field(page: 0x09, usage: 0x01).isReadable, "Button page should be readable")
    expect(field(page: 0x0C, usage: 0x01).isReadable, "Consumer page should be readable")
}

// MARK: - Runner

@main
enum DescriptorOpacityTestRunner {
    static func main() {
        testCTH690IsFullyOpaque()
        testIntuos5TouchLMixedButOverallReadable()
        testDigitizerPageWithZeroUsageIsOpaque()
        testXencelabsPenInterfaceIsReadable()
        testXencelabsControlChannelIsOpaque()
        testXencelabsIsNotUniformlyOpaque()
        testVendorPageAboveFF00ThresholdIsOpaque()
        testKnownPagesWithNonzeroUsageAreReadable()

        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("\(failures) of \(checks) checks failed\n".utf8))
            exit(1)
        }
    }
}
