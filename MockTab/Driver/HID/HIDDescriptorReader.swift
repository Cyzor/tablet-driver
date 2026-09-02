// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid
import TabletKit

/// Reads and summarises a device's HID report descriptor.
///
/// Two outputs:
///   1. Raw descriptor bytes (hex) — canonical fingerprint; anyone with these
///      bytes can fully reconstruct the report layout offline.
///   2. Parsed per-report element list — usage page / usage / size / range for
///      every leaf element, grouped by report ID and direction.
///
/// Bit offsets within a report are not computed: IOKit doesn't expose a stable
/// per-report ordering, and the raw bytes preserve the layout for offline tools.
enum HIDDescriptorReader {

    struct Field: Codable {
        let usagePage: UInt32
        let usage: UInt32
        let bitSize: UInt32
        let reportCount: UInt32
        let logicalMin: Int
        let logicalMax: Int
        let physicalMin: Int
        let physicalMax: Int
        let unit: UInt32
        let unitExponent: UInt32

        /// A field only carries decodable meaning when its usage page is one we
        /// understand *and* its usage code is itself meaningful within that page.
        ///
        /// Real captures show more than one opacity pattern, and page alone
        /// cannot distinguish them. An Intuos5 touch descriptor sits on the
        /// *correct* Digitizer page (0x0D) with `usage == 0x00` on every field
        /// — opaque despite the right page. A DTH-2420 (Cintiq Pro 24) pen
        /// report does the reverse: it declares tip switch, pressure, tilt,
        /// and position with the *standard* Digitizer usage numbers, but on
        /// Wacom's vendor page (0xFF0D) — fully self-describing despite the
        /// "wrong" page, and a page-only check would call it opaque, which is
        /// backwards for the most legible descriptor this reads.
        ///
        /// Delegates to `TabletKit.DigitizerUsage.isDecodable`, which is what
        /// resolves both cases: usage `0x00` is filler anywhere; a standard
        /// page accepts any named usage; a vendor page accepts only a usage
        /// number from the known digitizer set, so Wacom's structured vendor
        /// reports read as readable while its blob reports still do not.
        var isReadable: Bool {
            DigitizerUsage.isDecodable(usagePage: usagePage, usage: usage)
        }
    }

    enum Direction: String, Codable { case input, output, feature }

    struct ReportLayout: Codable {
        let reportID: UInt32
        let direction: Direction
        var fields: [Field]

        /// True if at least one field in this report is decodable.
        var isReadable: Bool { fields.contains(where: \.isReadable) }
    }

    struct Parsed: Codable {
        /// Raw report-descriptor bytes as lowercase hex. Nil if the property
        /// isn't exposed (rare; some BLE digitizers omit it).
        let rawHex: String?
        let rawLength: Int
        /// Keyed by "<direction>:0x<reportID>" (e.g. "input:0x10").
        let reports: [String: ReportLayout]

        /// True if any report on this device exposes at least one decodable field.
        /// False means the whole descriptor is opaque — every report is either on a
        /// vendor-defined page or uses undefined usage codes on a known page — and
        /// callers must not infer *absence* of a capability from that; treat it as
        /// unknown, not "device lacks this."
        var hasAnyReadableField: Bool {
            reports.values.contains(where: \.isReadable)
        }

        /// True if any report declares a field carrying pen (stylus) meaning:
        /// pressure, tilt, twist, or a barrel/eraser switch. This is what tells
        /// a tablet's pen interface apart from its touch tunnel — the touch
        /// interface declares contact-id/contact-count/width/height instead —
        /// and the PTH-860 USB is the case that needs it: the pen interface
        /// advertises a *Generic Desktop / Mouse* primary usage, so only the
        /// descriptor contents identify it. Standard Digitizer page (0x0D) or
        /// Wacom's vendor digitizer page (0xFF0D+); both carry these usages.
        var declaresPenFields: Bool {
            let penUsages: Set<UInt32> = [
                DigitizerUsage.tipPressure, DigitizerUsage.tiltX, DigitizerUsage.tiltY,
                DigitizerUsage.twist, DigitizerUsage.barrelSwitch, DigitizerUsage.eraserSwitch,
            ]
            return reports.values.contains { report in
                report.fields.contains { field in
                    (field.usagePage == 0x0D || field.usagePage >= 0xFF00)
                        && penUsages.contains(field.usage)
                }
            }
        }
    }

    static func read(_ device: IOHIDDevice) -> Parsed {
        let raw = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data
        let rawHex = raw.map { $0.map { String(format: "%02x", $0) }.joined() }
        let rawLen = raw?.count ?? 0

        var reports: [String: ReportLayout] = [:]

        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) else {
            return Parsed(rawHex: rawHex, rawLength: rawLen, reports: reports)
        }

        let count = CFArrayGetCount(elements)
        for i in 0..<count {
            guard let rawPtr = CFArrayGetValueAtIndex(elements, i) else { continue }
            let elem = Unmanaged<IOHIDElement>.fromOpaque(rawPtr).takeUnretainedValue()

            let direction: Direction
            switch IOHIDElementGetType(elem) {
            case kIOHIDElementTypeInput_Misc,
                 kIOHIDElementTypeInput_Button,
                 kIOHIDElementTypeInput_Axis,
                 kIOHIDElementTypeInput_ScanCodes:
                direction = .input
            case kIOHIDElementTypeOutput:
                direction = .output
            case kIOHIDElementTypeFeature:
                direction = .feature
            default:
                continue
            }

            let reportID = IOHIDElementGetReportID(elem)
            let field = Field(
                usagePage: IOHIDElementGetUsagePage(elem),
                usage: IOHIDElementGetUsage(elem),
                bitSize: IOHIDElementGetReportSize(elem),
                reportCount: IOHIDElementGetReportCount(elem),
                logicalMin: Int(IOHIDElementGetLogicalMin(elem)),
                logicalMax: Int(IOHIDElementGetLogicalMax(elem)),
                physicalMin: Int(IOHIDElementGetPhysicalMin(elem)),
                physicalMax: Int(IOHIDElementGetPhysicalMax(elem)),
                unit: IOHIDElementGetUnit(elem),
                unitExponent: IOHIDElementGetUnitExponent(elem)
            )

            let key = "\(direction.rawValue):0x\(String(format: "%02X", reportID))"
            if var existing = reports[key] {
                existing.fields.append(field)
                reports[key] = existing
            } else {
                reports[key] = ReportLayout(reportID: reportID, direction: direction, fields: [field])
            }
        }

        return Parsed(rawHex: rawHex, rawLength: rawLen, reports: reports)
    }

    /// Build a multi-line human-readable summary suitable for OSLog or display.
    static func summarize(_ parsed: Parsed) -> String {
        var lines: [String] = []
        lines.append("HID descriptor: \(parsed.rawLength) bytes")
        if parsed.reports.isEmpty {
            lines.append("  (no elements exposed)")
            return lines.joined(separator: "\n")
        }
        for key in parsed.reports.keys.sorted() {
            guard let r = parsed.reports[key] else { continue }
            let totalBits = r.fields.reduce(UInt32(0)) { $0 + $1.bitSize * $1.reportCount }
            lines.append("  \(key) (\(r.fields.count) field group(s), \(totalBits) bits):")
            for f in r.fields {
                lines.append("    " + describeField(f))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func describeField(_ f: Field) -> String {
        let header = String(format: "page=0x%02X usage=0x%02X", f.usagePage, f.usage)
        let size = f.reportCount > 1 ? "\(f.bitSize)x\(f.reportCount) bits" : "\(f.bitSize) bits"
        let range = "[\(f.logicalMin)…\(f.logicalMax)]"
        if let label = friendlyName(usagePage: f.usagePage, usage: f.usage) {
            return "\(header)  \(size)  \(range)  \(label)"
        }
        return "\(header)  \(size)  \(range)"
    }

    private static func friendlyName(usagePage: UInt32, usage: UInt32) -> String? {
        switch (usagePage, usage) {
        case (0x01, 0x30): return "X"
        case (0x01, 0x31): return "Y"
        case (0x01, 0x38): return "Wheel"
        case (0x0D, 0x30): return "TipPressure"
        case (0x0D, 0x31): return "BarrelPressure"
        case (0x0D, 0x32): return "InRange"
        case (0x0D, 0x33): return "Touch"
        case (0x0D, 0x3B): return "BatteryStrength"
        case (0x0D, 0x3D): return "XTilt"
        case (0x0D, 0x3E): return "YTilt"
        case (0x0D, 0x42): return "TipSwitch"
        case (0x0D, 0x44): return "BarrelSwitch"
        case (0x0D, 0x45): return "Eraser"
        case (0x0D, 0x5B): return "TransducerSerialNumber"
        case (0x0D, 0x77): return "Twist"
        case (0x09, _):    return "Button\(usage)"
        default:           return nil
        }
    }
}
