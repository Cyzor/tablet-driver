// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid

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
/// Consumed by `TabletKit/tools/triage_discovery.py` and read by hand when adding a new
/// device to the registry.
struct DiscoveryResult: Codable {
    /// 5: `byteSampleValues` replaced by `byteStats` (adds per-byte min/max and
    /// distinct-value counts); adds `maxLength`/`lengthVaried`/`optionalBytes`
    /// and top-level `observedToolCodes`.
    /// 6: adds `byteStatsByDiscriminator` — per-report byte stats further
    /// split by the value at byte position 1, so a report ID that actually
    /// carries more than one packet shape (coordinate data and a tool-change/
    /// status packet sharing one ID and length, on Wacom-family devices)
    /// doesn't get histogrammed as one blob. See `DiscoveryAccumulator
    /// .ReportStats.discriminatorByteIndex`.
    /// 7: adds `interfaces` — a device whose reports arrive on more than one
    /// HID interface is now recorded on all of them at once, each with its own
    /// reports and descriptor, instead of only whichever one was captured.
    /// 8: adds `touchSettings` and `touchPipeline`. A capture until now
    /// recorded only what the *device* sent, which is half the picture when a
    /// report arrives well-formed and produces nothing: the answer is then
    /// somewhere in the app, and the file said nothing about the app. These
    /// two blocks close that — what the user's touch settings were, and how
    /// many contacts each stage of the injection pipeline let through.
    var captureVersion: Int = 8
    let capturedAt: Date
    let mode: String  // always "discovery"
    let duration: TimeInterval
    let deviceInfo: DiscoveryDeviceInfo
    /// The **primary** interface's reports — the pen interface on a tablet
    /// that has one. Duplicated from `interfaces[0]` rather than replaced by
    /// it so a reader that predates `captureVersion` 7 (`TabletKit/tools/
    /// triage_discovery.py` as shipped, and every capture file already
    /// submitted against it) still finds the block it looks for, in the shape
    /// it expects. A few KB of duplication buys that.
    let reports: [String: DiscoveryReportSummary]
    /// Likewise the primary interface's descriptor.
    var hidReportDescriptor: HIDDescriptorReader.Parsed?
    /// Every interface recorded, primary first — present only when there was
    /// more than one, so single-interface captures (the overwhelming majority)
    /// stay byte-for-byte the shape they always were.
    var interfaces: [DiscoveryInterface]?
    /// Device-mode init writes attempted during the session, in order. Empty
    /// when the tester didn't use the advanced control — the common case.
    var initReports: [CaptureInitReport]?
    /// Wacom tool codes observed while collecting, as hex (e.g. `0x0802` pen,
    /// `0x080A` eraser). The clearest evidence of which tools a device reports
    /// distinctly, which no amount of byte-level analysis recovers on its own.
    var observedToolCodes: [String]?
    /// The touch-related settings in force during the session. Present only
    /// for a device whose spec declares finger touch — on everything else
    /// these settings are inert and would be misleading noise.
    var touchSettings: DiscoveryTouchSettings?
    /// Per-stage tallies of what the touch injection pipeline did with the
    /// contacts it decoded. Present only when the pipeline saw at least one
    /// frame, so a pen-only session doesn't carry a block of zeroes.
    var touchPipeline: DiscoveryTouchPipeline?
    var notes: String?
    var submitterContact: String?
}

/// The user's touch configuration at capture time.
///
/// Every field here can independently silence touch, and none of them is
/// visible in a report stream. Recording them turns "touch does nothing" from
/// a question that has to be asked into a fact the file already carries.
struct DiscoveryTouchSettings: Codable {
    let touchEnabled: Bool
    let tapToClick: Bool
    let twoFingerScroll: Bool
    let pinchZoom: Bool
    let sensitivity: Double
    /// Touch-area crop as a fraction of the surface (x, y, width, height).
    /// A crop that excludes where the tester's fingers actually landed drops
    /// every contact at projection — indistinguishable from dead touch
    /// without this.
    let areaX: Double
    let areaY: Double
    let areaWidth: Double
    let areaHeight: Double
}

/// How far touch contacts got through the injection pipeline.
///
/// Read top to bottom, these localize a touch failure to one stage without
/// any further round trip: contacts decoded but zero intents posted, with the
/// drop counted against exactly one gate, names the gate.
///
/// Counts are of *frames* where the whole frame was rejected, and of
/// *contacts* where individual contacts were filtered out of a surviving
/// frame — the distinction matters, since a partially filtered frame still
/// reaches the gesture tracker.
struct DiscoveryTouchPipeline: Codable {
    /// Frames the decoder emitted (`DecodeResult.touch`), and the total
    /// contacts across them. A nonzero `framesDecoded` with everything else
    /// zero means the decode half is working and the loss is downstream.
    var framesDecoded: Int = 0
    var contactsDecoded: Int = 0
    /// Frames dropped because "Enable Finger Touch" was off.
    var framesTouchDisabled: Int = 0
    /// Frames dropped because no injection snapshot existed yet — a startup
    /// race, not a user setting.
    var framesNoSnapshot: Int = 0
    /// Frames dropped by pen arbitration (`touchPenConfirmedBusy` or inside
    /// `touchArbitrationGrace`). A large count here with the pen untouched is
    /// the signature of a latched proximity state.
    var framesPenBusy: Int = 0
    /// Contacts removed by `TouchPalmRejector`. Only ever nonzero on the
    /// calibrated PTH-660/860 family.
    var contactsPalmRejected: Int = 0
    /// Contacts dropped by `TouchStateTracker.screenPoint` returning nil —
    /// i.e. falling outside the touch-area crop above.
    var contactsOffArea: Int = 0
    /// Frames that reached the gesture tracker with at least one contact.
    var framesTracked: Int = 0
    /// Intents the tracker produced, by kind. All zero while `framesTracked`
    /// is large means the gesture tracker is receiving contacts and refusing
    /// to commit to a gesture.
    var pointerMoves: Int = 0
    var scrolls: Int = 0
    var zooms: Int = 0
    var rotates: Int = 0
    var taps: Int = 0

    /// True when the pipeline saw anything at all, so a pen-only capture can
    /// omit the block entirely.
    var isEmpty: Bool {
        framesDecoded == 0 && framesTouchDisabled == 0 && framesNoSnapshot == 0
            && framesPenBusy == 0
    }
}

/// One HID interface of a captured device, with the reports it sent and the
/// descriptor it declared.
///
/// Multi-interface tablets are the reason this exists. A PTH-850 puts pen data
/// on one interface and a 64-byte touch frame on another; before this, a
/// capture recorded exactly one of them and whether it was the interesting one
/// came down to which attached first. Which interface matters is precisely
/// what a tester submitting an unknown device can't be asked to judge, so all
/// of them are recorded and the triage happens later, off the file.
///
/// An interface with `sampleCount` 0 is kept rather than dropped: "this
/// interface exists, we listened, and it said nothing for the whole session"
/// is a real finding — it's what a device sitting in a reduced boot mode looks
/// like, and it's the evidence a mode-switch write is needed.
struct DiscoveryInterface: Codable {
    /// HID primary usage page/usage, as hex. Together these name the
    /// interface's role — `0x000D`/`0x0002` a pen digitizer, `0x000D`/`0x0004`
    /// a touchscreen, `0xFF00`+ a vendor-private tunnel.
    var usagePage: String?
    var usage: String?
    /// True for the interface whose data is also duplicated at the top level
    /// of `DiscoveryResult`. Exactly one interface has this.
    let isPrimary: Bool
    /// Reports recorded on this interface alone.
    let sampleCount: Int
    let reports: [String: DiscoveryReportSummary]
    /// This interface's own descriptor — the one every `descriptorReadable`
    /// flag in `reports` above was judged against.
    var hidReportDescriptor: HIDDescriptorReader.Parsed?
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
    /// `byteStats` further split by the value at byte position 1 — see
    /// `DiscoveryAccumulator.ReportStats.discriminatorByteIndex`. Keyed by
    /// that value as a two-digit uppercase hex string (JSON object keys must
    /// be strings; hex keeps it legible next to `firstSample`).
    ///
    /// Present only when byte 1 looks like a packet-type/status field rather
    /// than more coordinate data: more than one but no more than
    /// `CaptureEngine.discriminatorMaxDistinct` values observed. Below that
    /// threshold this is genuinely absent, not merely omitted — reading a
    /// capture file without it means byte 1 was constant for every sample of
    /// this report, or its own stats already told the whole story.
    var byteStatsByDiscriminator: [String: DiscoveryDiscriminatedStats]?
}

/// One discriminator-value bucket of `DiscoveryReportSummary
/// .byteStatsByDiscriminator` — the byte stats for every sample of a report
/// where byte 1 held one particular value, plus how many samples that was.
struct DiscoveryDiscriminatedStats: Codable {
    let sampleCount: Int
    var byteStats: [Int: DiscoveryByteStat]
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

/// An interface a capture session can record from, weakly held.
///
/// Exists because a device with more than one such interface (PTH-850's pen
/// and touch interfaces both route through `.driver` independently — see
/// `DeviceContext.hidDevice`'s doc comment) is otherwise only ever reachable
/// via whichever one `hidDevice` happens to pin to. `CaptureGuideView` records
/// every one of these at once.
///
/// Only interfaces the driver actually installed a report callback on are
/// listed — see `WacomKnownDevice.deliversReports(from:)`. An interface
/// without one can never produce a sample, so including it would put a
/// permanently empty bucket in every capture file and misrepresent a silent
/// interface (real evidence) as an unlistened one.
final class CaptureInterfaceCandidate {
    weak var device: IOHIDDevice?
    let usagePage: Int

    init(device: IOHIDDevice, usagePage: Int) {
        self.device = device
        self.usagePage = usagePage
    }
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
    /// HID primary usage page/usage of the specific interface this describes.
    /// Every field above is a property of the *tablet* and is identical across
    /// its interfaces; these two are what tell them apart in the capture file.
    var usagePage: Int? = nil
    var usage: Int? = nil

    var vendorIDHex: String   { String(format: "0x%04X", vendorID) }
    var productIDHex: String  { String(format: "0x%04X", productID) }
}
