// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Device Mode Init

/// One device-mode init attempt made during a capture session.
///
/// Modern Wacom devices boot emitting a reduced (or no) pen stream until the
/// host writes a data-mode feature report; a read-only capture then records
/// nothing useful and looks like "the device reports no tilt". Legacy families
/// use feature report `0x02` value `2`; on current `HID_GENERIC` devices the
/// report ID is whatever carries the vendor DATAMODE usage (`0xff0d1002`), and
/// on Precision-Touchpad-style multitouch interfaces the standard Device Mode
/// usage (`0x0d`/`0x52`) plays the same role. Either must be read out of the raw
/// descriptor — IOKit surfaces those fields as `usage 0x00`, so we can't
/// discover it from the element list. Hence the manual entry: a tester
/// with modern hardware can try candidate report IDs and ship the outcome back
/// in the capture file. See Notes/Wacom-HID-Post-2020-Preliminary-Research.md.
struct CaptureInitReport: Codable, Identifiable {
    let reportID: Int
    let value: Int
    let succeeded: Bool
    /// `IOReturn` as hex when the write failed; nil on success.
    var ioReturn: String?

    var id: String { "\(reportID)-\(value)-\(ioReturn ?? "ok")" }

    var reportIDHex: String { String(format: "0x%02X", reportID) }
    var valueHex: String { String(format: "0x%02X", value) }
}

// MARK: - Discovery Result

/// Output of a discovery session. Records every report ID seen and, for each,
/// which byte positions varied and what values they took.
///
/// Consumed by `tools/triage_discovery.py` and read by hand when adding a new
/// device to the registry.
struct DiscoveryResult: Codable {
    /// 5: `byteSampleValues` replaced by `byteStats` (adds per-byte min/max and
    /// distinct-value counts); adds `maxLength`/`lengthVaried`/`optionalBytes`
    /// and top-level `observedToolCodes`.
    var captureVersion: Int = 5
    let capturedAt: Date
    let mode: String  // always "discovery"
    let duration: TimeInterval
    let deviceInfo: DiscoveryDeviceInfo
    let reports: [String: DiscoveryReportSummary]
    var hidReportDescriptor: HIDDescriptorReader.Parsed?
    /// Device-mode init writes attempted during the session, in order. Empty
    /// when the tester didn't use the advanced control — the common case.
    var initReports: [CaptureInitReport]?
    /// Wacom tool codes observed while collecting, as hex (e.g. `0x0802` pen,
    /// `0x080A` eraser). The clearest evidence of which tools a device reports
    /// distinctly, which no amount of byte-level analysis recovers on its own.
    var observedToolCodes: [String]?
    var notes: String?
    var submitterContact: String?
}

struct DiscoveryDeviceInfo: Codable {
    let vendorID: String
    let productID: String
    let name: String
    var manufacturer: String?
    var transport: String?
    var locationID: String?
}

/// What one byte position did across every sample of a report.
struct DiscoveryByteStat: Codable {
    let min: Int
    let max: Int
    /// Number of distinct values observed at this position.
    let distinctCount: Int
    /// Observed values, ascending. Complete when `distinctCount` is small;
    /// otherwise the lowest and highest dozen, so the *range* stays visible.
    /// (Naively truncating a sorted list hides a pressure byte's ceiling.)
    let values: [Int]
    /// True when `values` omits some observed values.
    var truncated: Bool?
    /// Bit positions that took both 0 and 1 across the session.
    ///
    /// On a device whose descriptor is opaque — every classic Wacom pad and
    /// remote — this is the closest thing to a button map the capture can
    /// offer, because each key is one toggling bit. Reading it beats deriving
    /// it from `values` by hand, which is what triaging such a device
    /// otherwise requires.
    var bitsToggled: Int?
    /// Bit positions set in at least one sample. A bit present here but
    /// absent from `bitsToggled` was set in every sample, marking it a
    /// constant flag rather than a control.
    var bitsSet: Int?
}

struct DiscoveryReportSummary: Codable {
    let reportID: UInt8
    /// Length of the first sample seen. Equal to `maxLength` unless
    /// `lengthVaried`.
    let length: Int
    /// Longest sample seen for this report ID.
    var maxLength: Int
    /// True when this report ID arrived with more than one length. Byte
    /// positions beyond the shortest sample are reported in `optionalBytes`
    /// rather than being called constant or varying.
    var lengthVaried: Bool
    let sampleCount: Int
    var varyingBytes: [Int]           // positions present in every sample that took >1 value
    var constantBytes: [Int]          // positions present in every sample that took exactly 1
    /// Positions present in only *some* samples (short reports). Neither
    /// constant nor varying can be claimed honestly for these.
    var optionalBytes: [Int]?
    var firstSample: String?          // hex string of first captured sample
    var constantValues: [Int]?        // values at `constantBytes`, same order
    /// Per-byte statistics, keyed by byte index. Covers every position that
    /// took more than one value, plus every optional position.
    var byteStats: [Int: DiscoveryByteStat]?
    /// Whether the HID report descriptor exposes at least one standard-usage
    /// field for this report ID (see `HIDDescriptorReader.Field.isReadable`).
    /// `false` flags a report whose bytes vary (real signal, per the above
    /// fields) but whose meaning is opaque from the descriptor alone — the
    /// triage-relevant case, since those bytes need a captured-sample
    /// correlation pass instead of a descriptor read. `nil` if no descriptor
    /// was available to check.
    var descriptorReadable: Bool?
    /// Repeating byte-stride structure found in this report's own varying
    /// bytes — see `RepeatingReportStructureDetector` in TabletKit.
    ///
    /// Exists for exactly the reports `descriptorReadable == false` flags:
    /// with no descriptor to read, `varyingBytes` is otherwise a flat list of
    /// positions with no hint that they are, say, four repeats of a 43-byte
    /// touch frame rather than one 174-byte record. That repeat is the single
    /// most useful fact in a capture of an unrecognized device, and the
    /// hardest one to notice by reading the byte list. `nil` when no
    /// structure cleared the detector's thresholds, which is the correct and
    /// common answer for reports with real varying bytes and no repeat.
    var repeatingStructure: DiscoveryRepeatingStructure?
}

/// One reported run of repeating byte-stride structure, at one nesting level.
/// Mirrors `TabletKit.RepeatingRun` for JSON output — see that type's doc
/// comment for what each field claims and how it is scored.
struct DiscoveryRepeatingRun: Codable {
    let startOffset: Int
    let period: Int
    let repeatCount: Int
    let matchFraction: Double
}

/// A detected repeating structure, with an optional one-level-deeper nested
/// run. Mirrors `TabletKit.RepeatingReportStructure`.
struct DiscoveryRepeatingStructure: Codable {
    let outer: DiscoveryRepeatingRun
    let nested: DiscoveryRepeatingRun?
}

// MARK: - Device Context for Capture

/// Lightweight descriptor of a device being captured.
/// Passed to CaptureEngine when collection starts.
struct CaptureDeviceInfo {
    let vendorID: Int
    let productID: Int
    let name: String
    let locationID: String?
    var manufacturer: String? = nil
    var transport: String? = nil
    var parsedDescriptor: HIDDescriptorReader.Parsed? = nil

    var vendorIDHex: String   { String(format: "0x%04X", vendorID) }
    var productIDHex: String  { String(format: "0x%04X", productID) }
}
