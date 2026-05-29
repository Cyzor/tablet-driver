// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

// MARK: - Report protocol family

/// Which HID report decoder handles this device family.
///
/// Used by `WacomDeviceRegistry` to route devices to the correct decoder.
/// The individual per-device Swift classes (PTH660Device, etc.) remain as
/// the live code path during migration; decoders are introduced in Phase 2.
enum ReportParser: String {
    /// Graphire / early consumer line — Report ID 0x02
    /// (kernel `WACOM_REPORT_PENABLED`), 8 bytes.
    /// Covers PenPartner, Graphire 2–4, Volito, Bamboo One (CTF-430).
    /// No tool-change packets; eraser/pen/mouse detected via the tool field
    /// in status byte d[1] bits 5–6. Decoded by `GraphireDecoder`
    /// (experimental — not yet hardware-validated).
    case graphire

    /// IntuosV1 — Report ID 0x02/0x10, 10 bytes, BE16 coordinates.
    /// Covers Intuos 1–5, Intuos3 (PTZ-xxx), Intuos4 (PTK-xxx),
    /// Intuos5 (PTH-xxx first gen), and Cintiq pen-displays.
    /// Tool-change packets: status `(& 0xFC) == 0xC0`.
    /// 10–12 bit pressure depending on generation.
    case intuosV1

    /// IntuosV2 — Report ID 0x10, 192 bytes, LE24 coordinates, 13-bit pressure.
    /// Covers Intuos Pro second-generation (PTH-460/660/860) and newer.
    /// Also used over BLE HOGP (Report ID 0x01 pen, 0x03 pad).
    case intuosV2

    /// IntuosV3 — Report ID 0x1F (pen, 16-bit XY) or 0x1E (extended pen,
    /// 24-bit XY), with 0x11 aux carrying 10 buttons and two relative
    /// scroll wheels. Covers the PTK-470/670/870 Intuos Pro generation
    /// (OTD's `IntuosV3ReportParser`). Distinct byte layout from intuosV2
    /// — pen status byte at [2] not [1], pressure at [7..8] not [8..9],
    /// and 0x1E here is a different shape than intuosV2's offset report
    /// of the same ID. Experimental: no hardware verification yet.
    case intuosV3

    /// DTUS — small entry-level Cintiq / DTU pen displays. Pen report at
    /// ID 0x11 (7 bytes, BE16 coordinates, 10-bit pressure split across
    /// status byte and pressure byte); pad report at ID 0x15 (4 buttons in
    /// the low nibble of one byte). No tilt, no rotation, no hover. Covers
    /// DTK-1651 (0x0343), DTU-1031 (0x00FB), DTU-1031X (0x032F), DTU-1141
    /// (0x0336). Note: report ID 0x11 collides with IntuosV2's aux ID; per-
    /// decoder dispatch keeps them separate. Experimental.
    case dtus

    /// DTU — Wacom DTU pen-display family using the WACOM_REPORT_PENABLED
    /// (0x02) report format parsed by `wacom_dtu_irq`. Single pen report,
    /// 8 bytes: LE16 X/Y, 9-bit pressure, eraser inferred from tool-type
    /// bits. No pad buttons, no tilt. Covers DTU-1631 (0x00F0) and
    /// DTU-2231 (0x00CE). Distinct from DTUS: little-endian coordinates,
    /// 9-bit (not 10-bit) pressure, no pad report. Experimental.
    case dtu

    /// Bamboo — Report ID 0x10, 20 bytes, BE16 coordinates.
    /// Covers Bamboo Pen & Touch, Bamboo Craft/Comic/Fun series (CTL/CTH-xxx).
    /// Decoder not yet implemented; entries present for routing completeness.
    case bamboo

    /// Intuos3 (PTZ-xxx, 2003–2006) — same 10-byte IntuosV1 payload but with
    /// a different status-byte layout: bit 6 (0x40) is the proximity indicator
    /// (vs. bit 5 in IntuosV1).  Aux reports use IDs 0x03/0x0C, not 0x11.
    /// No BLE support.  Two-stage feature init (see `WacomDeviceSpec.initSteps`).
    case intuos3

    /// CintiqV1 — Wacom Cintiq pen-display family using the IntuosV1 10-byte pen
    /// report layout (same as PTH-851) plus a 0x0C aux report for touch rings and
    /// express keys, and a 0x01 tip-switch report that requires device seizure.
    /// Decoded by `CintiqV1Decoder` which handles the WACOM_24HD typeNibble dispatch,
    /// ABS_Z Art Pen rotation, barrel-button debounce, dual-ring 0x0C layout,
    /// tip-switch synthetic pressure, and incompatible-tool suppression.
    case cintiqV1
}

// MARK: - Init step

/// A single step in the device-activation sequence executed when an interface
/// is opened.  Steps run in order; a `.delay` suspends execution and schedules
/// the remainder on the main queue after the specified interval.
///
/// - `.featureReport(_:)`: HID SetReport (feature); first byte is the report ID.
/// - `.outputReport(_:)`: HID output report; first byte is the report ID.
///   Intended for Xencelabs init (`[0x02, 0xB0, 0x04]`) — not yet wired up.
/// - `.delay(_:)`: Pause before the next step, dispatched via `asyncAfter`.
/// - `.stringDescriptor(_:)`: Probe a USB string descriptor at the given index.
///   Intended for Huion frame-button activation — not yet wired up.
public enum InitStep: Equatable {
    case featureReport([UInt8])
    case outputReport([UInt8])
    case delay(TimeInterval)
    case stringDescriptor(Int)
}

// MARK: - Confidence tier

/// How well-vetted a registry entry is. Drives UI honesty (e.g. an
/// "Experimental — please report issues" hint when the active device is
/// `.experimental`) and informs which entries are safe to promote.
///
/// - `.verified`: Hand-tested on real hardware in this project.
/// - `.crossReferenced`: Dimensions/parser agree between Linux input-wacom
///   and OpenTabletDriver; not personally hardware-tested but two
///   independent canonical sources concur.
/// - `.experimental`: Imported from a single source (typically OTD JSON or
///   kernel constants) without independent confirmation. May have wrong
///   dimensions, missing init reports, or only partial protocol support.
enum ConfidenceTier {
    case verified
    case crossReferenced
    case experimental
}

// MARK: - Per-device spec

/// All hardware parameters for a single Wacom USB or BLE product.
///
/// This table is the single source of truth for device names, coordinate
/// ranges, pressure depth, and initialisation requirements.  It drives
/// device-name display today and will route `WacomKnownDevice` once
/// Phase 3 decoders are in place.
///
/// Data sources, in descending priority for *physical dimensions*:
///   1. Live measurement on owned hardware (PTH-851, PTH-660, PTH-860, PTZ-631W, DTK-2400).
///   2. **libwacom** `.tablet` files (https://github.com/linuxwacom/libwacom) —
///      maintained per-device for hardware metadata; backfilled via
///      `tools/backfill_libwacom_dimensions.py`. Authoritative for any
///      Wacom-vid model it covers.
///   3. Linux **input-wacom** driver `drivers/input/tablet/wacom_wac.c` — its
///      `wacom_features_0x…` tables and family resolution constants
///      (`WACOM_PENPRTN_RES`, `_VOLITO_RES`, `_GRAPHIRE_RES`, `_INTUOS_RES`,
///      `_INTUOS3_RES`) are *approximations*. Reliable for `maxX`/`maxY`
///      device-unit coords; dimensions derived as `maxX / resolution` can be
///      off by ~10–25% (e.g. the kernel's Volito resolution constant
///      mis-estimates 0x0060 by 25%; libwacom is correct).
///   4. **OpenTabletDriver** configs `Configurations/Wacom/` — typically
///      derived from libwacom + kernel; useful tiebreaker but rarely the
///      primary source for Wacom hardware.
///   5. **linuxwacom HID descriptors corpus**
///      (https://github.com/linuxwacom/wacom-hid-descriptors) — drives
///      recognition-only newer-device entries and `.experimental` →
///      `.crossReferenced` promotions via `tools/audit_wacom_hid_descriptors.py`.
///
/// For *non-Wacom* hardware (Huion / Xencelabs / XP-Pen / UC-Logic) the
/// priority inverts: OpenTabletDriver configs are the primary public source
/// and the kernel rarely covers them.
/// Entries marked ⚠ are estimated from driver sources and unverified on
/// hardware; the `⚠ recognition-only` variant additionally means the parser
/// family and `maxX`/`maxY` are guesses by similarity — the device will be
/// named correctly but pen decode may produce nonsense until verified.
struct WacomDeviceSpec {
    let productID: Int
    let name: String
    let parser: ReportParser
    let maxX: Int
    let maxY: Int
    let maxPressure: Int
    /// Number of programmable express/side keys (0 if none).
    let buttonCount: Int
    /// True if this model has a capacitive touch ring (Intuos Pro).
    let hasTouchRing: Bool
    /// True if this model has two touch rings (one per bezel), e.g. Cintiq 24HD.
    /// Implies hasTouchRing.  The two rings are independently assignable.
    let hasDualRings: Bool
    /// True if this model has dual capacitive touch strips (Intuos3 WS).
    let hasTouchStrips: Bool
    /// True if this model has a capacitive touch surface for finger input in
    /// addition to the pen digitizer (Cintiq Pro 27, Movink 13, Cintiq 16
    /// touch, Cintiq 24HD/22HD Touch).  Gates the Touch settings pane and
    /// the touch-enable feature-report path.
    let hasFingerTouch: Bool
    /// Maximum simultaneous touch contacts the device reports.  1 for the
    /// single-touch Cintiq 24HD/22HD Touch displays; 10 for the multi-touch
    /// Cintiq Pro 27, Movink 13, and Cintiq 16 family.  Zero when
    /// `hasFingerTouch == false`.
    let maxTouchContacts: Int
    /// Coordinate maximum for the capacitive touch sensor's X axis.
    /// Separate from `maxX` (pen digitizer); confirmed by live capture.
    /// PTH-860: 12439. PTH-660: 8960 (estimated, same 1/5 ratio as pen).
    /// Zero when `hasFingerTouch == false`.
    let touchMaxX: Int
    /// Coordinate maximum for the capacitive touch sensor's Y axis.
    /// PTH-860: 8639. PTH-660: 5920 (estimated).
    /// Zero when `hasFingerTouch == false`.
    let touchMaxY: Int
    /// Number of ring mode slots to expose in the UI.
    /// Defaults to 4, matching Wacom's standard 4-LED toggle ring layout.
    let ringSlotCount: Int
    /// True if the pen family includes an eraser tool type.
    let hasEraser: Bool
    /// True if this device's pen reports include tilt data (Bamboo 4-bit format).
    /// Has no effect on IntuosV1/V2/Intuos3 decoders, which always decode tilt.
    let hasTilt: Bool
    /// True if this device is a pen display (Cintiq-class) with a built-in screen.
    /// Pen displays may need parallax offset calibration due to thick glass layers.
    let isPenDisplay: Bool
    /// Ordered list of steps to execute when the interface is opened (USB/dongle only;
    /// skipped for BLE).  An empty array means no init is required.  The first byte
    /// of each `.featureReport` / `.outputReport` payload is the HID report ID.
    ///
    /// Most devices need a single `.featureReport([0x02, 0x02])`.  Intuos3 (PTZ-xxx)
    /// devices need a two-stage sequence with a 150 ms pause between the stages:
    /// `[.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])]`.
    let initSteps: [InitStep]
    /// True if this interface must be seized (kIOHIDOptionsTypeSeizeDevice)
    /// to prevent macOS's built-in HID mouse driver from consuming reports.
    let seizeUSB: Bool
    /// Product ID of a companion USB interface that handles LED control separately.
    /// When a Wacom device with this PID is enumerated but has no digitizer elements,
    /// TabletManager routes it to this device's WacomKnownDevice as an LED target
    /// rather than attaching a fallback driver or skipping it entirely.
    /// nil = LED control uses the main digitizer interface (single-interface devices).
    let ledCompanionPID: Int?
    /// How well-vetted this entry is (see `ConfidenceTier`).
    /// Defaults to `.experimental` — promote explicitly when verified.
    let confidence: ConfidenceTier
    /// Active-area width in millimetres.  Optional because the registry was
    /// built around device-unit coordinates (`maxX`/`maxY`); physical
    /// dimensions are backfilled incrementally as they're confirmed.
    ///
    /// When present, lets the cursor-mapping layer compute LPI per axis
    /// (`maxX / activeWidthMM × 25.4`) and offer 1:1 mm mapping in the
    /// tablet-area UI.  Matches the canonical (mm, logical-max) data shape
    /// used by Huion and Xencelabs references, easing future cross-vendor
    /// support.  Nil = unknown.
    let activeWidthMM: Double?
    /// Active-area height in millimetres.  See `activeWidthMM`.
    let activeHeightMM: Double?
    /// Optional substring matched against the device's `kIOHIDProductKey`
    /// string when multiple specs share a `productID`.  Used to disambiguate
    /// vendor PID collisions — Wacom has none today, but the plumbing is
    /// shared with future Huion support (Huion PIDs `0x006D`/`0x006E` each
    /// cover dozens of distinct models, discriminated only by firmware
    /// string).  Case-insensitive substring match.  Nil = match any.
    let productStringMatch: String?

    init(
        productID: Int, name: String, parser: ReportParser,
        maxX: Int, maxY: Int, maxPressure: Int,
        buttonCount: Int, hasTouchRing: Bool, hasDualRings: Bool = false,
        hasTouchStrips: Bool = false, ringSlotCount: Int = 4, hasEraser: Bool, hasTilt: Bool = false,
        hasFingerTouch: Bool = false, maxTouchContacts: Int = 0,
        touchMaxX: Int = 0, touchMaxY: Int = 0,
        isPenDisplay: Bool = false,
        seizeUSB: Bool,
        initSteps: [InitStep] = [],
        ledCompanionPID: Int? = nil,
        confidence: ConfidenceTier = .experimental,
        productStringMatch: String? = nil,
        activeWidthMM: Double? = nil,
        activeHeightMM: Double? = nil
    ) {
        self.productID = productID
        self.name = name
        self.parser = parser
        self.maxX = maxX
        self.maxY = maxY
        self.maxPressure = maxPressure
        self.buttonCount = buttonCount
        self.hasTouchRing = hasTouchRing
        self.hasDualRings = hasDualRings
        self.hasTouchStrips = hasTouchStrips
        self.hasFingerTouch = hasFingerTouch
        self.maxTouchContacts = maxTouchContacts
        self.touchMaxX = touchMaxX
        self.touchMaxY = touchMaxY
        self.ringSlotCount = ringSlotCount
        self.hasEraser = hasEraser
        self.hasTilt = hasTilt
        self.isPenDisplay = isPenDisplay
        self.seizeUSB = seizeUSB
        self.initSteps = initSteps
        self.ledCompanionPID = ledCompanionPID
        self.confidence = confidence
        self.productStringMatch = productStringMatch
        self.activeWidthMM = activeWidthMM
        self.activeHeightMM = activeHeightMM
    }

    /// Lines per inch derived from `maxX`/`maxY` and `activeWidthMM`/`activeHeightMM`.
    /// Returns nil unless both physical dimensions are populated.  Useful for
    /// the info pane and for cross-vendor cursor-mapping that needs a real DPI
    /// number rather than device-unit ratios.
    var lpi: (x: Double, y: Double)? {
        guard let w = activeWidthMM, w > 0, let h = activeHeightMM, h > 0 else { return nil }
        return (Double(maxX) / w * 25.4, Double(maxY) / h * 25.4)
    }

    /// Derives the device family identifier from parser and name.
    /// Used to check tool compatibility against `WacomToolSpec.supportedFamilies`.
    var family: String {
        switch parser {
        case .graphire:
            return "bamboo2"
        case .intuos3:
            return "intuos3"
        case .cintiqV1:
            return "cintiq"
        case .intuosV1:
            // Intuos 1-5 and any non-Cintiq pen displays that haven't been migrated.
            if name.contains("Cintiq") || name.contains("DTK") || name.contains("DTH") {
                return "cintiq"
            }
            if name.contains("Intuos 4") || name.contains("PTK") {
                return "intuos4"
            }
            if name.contains("Intuos 5") || name.contains("PTH-8") {
                return "intuos5"
            }
            return "intuosProGen1"
        case .intuosV2:
            return "intuosProGen2"
        case .intuosV3:
            return "intuosProGen3"
        case .dtus:
            return "dtus"
        case .dtu:
            return "dtu"
        case .bamboo:
            return "bamboo"
        }
    }
}

// MARK: - Registry

enum WacomDeviceRegistry {

    // MARK: Known devices

    static let knownDevices: [WacomDeviceSpec] = [

        // ── PenPartner / Graphire 1–4 ─────────────────────────────────────────
        // graphire parser: 8-byte Report ID 0x01, ≤511 pressure levels.
        .init(
            productID: 0x0003, name: "PenPartner",
            // Dimensions and pressure corrected to match kernel
            // wacom_features_0x3 (input-wacom 4.18); previous values
            // (5040×3780×255) were estimation drift.
            parser: .graphire, maxX: 20480, maxY: 15360, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false),
        .init(
            productID: 0x0004, name: "Graphire",
            parser: .graphire, maxX: 10206, maxY: 7422, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            seizeUSB: false),
        .init(
            productID: 0x0010, name: "Graphire",  // cross-referenced: linuxwacom + OTD
            parser: .graphire, maxX: 10206, maxY: 7422, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            // dimensions: libwacom wacom-graphire-usb.tablet (Width=127, Height=102)
            seizeUSB: false, confidence: .crossReferenced,
            activeWidthMM: 127, activeHeightMM: 102),
        .init(
            productID: 0x0011, name: "Graphire 2 (4×5)",  // ⚠ estimated; kernel 0x11 = Graphire2 4×5
            parser: .graphire, maxX: 10206, maxY: 7422, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            // dimensions: libwacom wacom-graphire2-4x5.tablet (Width=127, Height=102)
            seizeUSB: false,
            activeWidthMM: 127, activeHeightMM: 102),
        .init(
            productID: 0x0012, name: "Graphire 2 (5×7)",  // ⚠ estimated; kernel 0x12 = Graphire2 5×7
            parser: .graphire, maxX: 13918, maxY: 10206, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, activeWidthMM: 178, activeHeightMM: 127),
        .init(
            productID: 0x0013, name: "Graphire 3 (4×5)",  // ⚠ estimated
            parser: .graphire, maxX: 10208, maxY: 7424, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            // dimensions: libwacom wacom-graphire3-4x5.tablet (Width=127, Height=102)
            seizeUSB: false,
            confidence: .crossReferenced,
            activeWidthMM: 127, activeHeightMM: 102),
        .init(
            productID: 0x0014, name: "Graphire 3 (6×8)",  // ⚠ estimated
            parser: .graphire, maxX: 16704, maxY: 12064, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 203, activeHeightMM: 152),
        .init(
            productID: 0x0015, name: "Graphire 4 (4×5)",  // ⚠ estimated
            parser: .graphire, maxX: 10208, maxY: 7424, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            // dimensions: libwacom wacom-graphire4-4x5.tablet (Width=127, Height=102)
            seizeUSB: false,
            confidence: .crossReferenced,
            activeWidthMM: 127, activeHeightMM: 102),
        .init(
            productID: 0x0016, name: "Graphire 4 (6×8)",  // ⚠ estimated
            parser: .graphire, maxX: 16704, maxY: 12064, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 203, activeHeightMM: 152),
        .init(
            productID: 0x0017, name: "Bamboo Fun (MTE-450)",  // ⚠ estimated
            parser: .graphire, maxX: 14760, maxY: 9225, maxPressure: 511,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),

        // ── Volito / PenStation ───────────────────────────────────────────────
        .init(
            productID: 0x0060, name: "Volito",  // ⚠ estimated
            parser: .graphire, maxX: 5104, maxY: 3712, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            // dimensions: libwacom wacom-volito-4x5.tablet (Width=127, Height=102).
            // Kernel WACOM_VOLITO_RES=50 lpmm would give 102×74 mm — too small;
            // libwacom measurement supersedes for a 4×5 (FT-0405) tablet.
            seizeUSB: false,
            confidence: .crossReferenced,
            activeWidthMM: 127, activeHeightMM: 102),
        .init(
            // Kernel calls this PenStation2; dimensions/pressure corrected.
            productID: 0x0061, name: "PenStation2",  // ⚠ from kernel
            parser: .graphire, maxX: 3250, maxY: 2320, maxPressure: 255,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            // dimensions: input-wacom 4.18 wacom_features_0x61 (3250/50 lpmm × 2320/50 lpmm).
            // Not in libwacom; the kernel WACOM_VOLITO_RES=50 constant proved
            // ~25% off for 0x0060 — these values may be similarly low.
            seizeUSB: false,
            activeWidthMM: 65, activeHeightMM: 46.4),
        .init(
            productID: 0x0062, name: "Volito 2",  // ⚠ estimated
            parser: .graphire, maxX: 5104, maxY: 3712, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            // dimensions inferred from sibling 0x0060 (Volito) in libwacom
            // wacom-volito-4x5.tablet (Width=127, Height=102). Volito 2 shares
            // identical kernel max coords with Volito 1 → almost certainly the
            // same physical size. Not in libwacom directly.
            seizeUSB: false,
            activeWidthMM: 127, activeHeightMM: 102),
        .init(
            productID: 0x0065, name: "Bamboo One (CTF-430)",  // ⚠ estimated
            parser: .graphire, maxX: 14760, maxY: 9225, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),

        // ── Cintiq 21UX first-gen ─────────────────────────────────────────────
        .init(
            // Kernel wacom_features_0x3F: Cintiq 21UX, 1023 pressure, 8 keys.
            // Parser was .graphire (8-byte report) which would never decode a
            // Cintiq pen-display report; corrected to .cintiqV1 in line with
            // every other CINTIQ-family entry. Still ⚠ until hardware-verified.
            productID: 0x003F, name: "Cintiq 21UX (DTZ-2100)",  // ⚠ from kernel
            parser: .cintiqV1, maxX: 87200, maxY: 65600, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 432, activeHeightMM: 330),

        // ── Intuos 1 (1998–2002) — intuosV1 parser ───────────────────────────
        // 10-byte reports, BE16, 1024-level pressure (10-bit).
        .init(
            productID: 0x0020, name: "Intuos 4×5",  // ⚠ estimated
            parser: .intuosV1, maxX: 12700, maxY: 10600, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 127, activeHeightMM: 102),
        .init(
            productID: 0x0021, name: "Intuos 6×8",  // ⚠ estimated
            parser: .intuosV1, maxX: 20320, maxY: 16240, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 203, activeHeightMM: 152),
        .init(
            productID: 0x0022, name: "Intuos 9×12",  // ⚠ estimated
            parser: .intuosV1, maxX: 30480, maxY: 24060, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 305, activeHeightMM: 229),
        .init(
            productID: 0x0023, name: "Intuos 12×12",  // ⚠ estimated; kernel maxY 31680
            parser: .intuosV1, maxX: 30480, maxY: 31680, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 305, activeHeightMM: 305),
        .init(
            productID: 0x0024, name: "Intuos 12×18",  // ⚠ estimated; kernel maxY 31680
            parser: .intuosV1, maxX: 45720, maxY: 31680, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 457, activeHeightMM: 305),

        // ── Intuos 2 (2002–2004) — intuosV1 parser ───────────────────────────
        .init(
            productID: 0x0041, name: "Intuos 2 (4×5)",  // ⚠ estimated
            parser: .intuosV1, maxX: 12700, maxY: 10600, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 127, activeHeightMM: 102),
        .init(
            productID: 0x0042, name: "Intuos 2 (6×8)",  // ⚠ estimated
            parser: .intuosV1, maxX: 20320, maxY: 16240, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 203, activeHeightMM: 152),
        .init(
            productID: 0x0043, name: "Intuos 2 (9×12)",  // ⚠ estimated
            parser: .intuosV1, maxX: 30480, maxY: 24060, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 305, activeHeightMM: 229),
        .init(
            productID: 0x0044, name: "Intuos 2 (12×12)",  // ⚠ estimated; kernel maxY 31680
            parser: .intuosV1, maxX: 30480, maxY: 31680, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 305, activeHeightMM: 305),
        .init(
            productID: 0x0045, name: "Intuos 2 (12×18)",  // ⚠ estimated; kernel maxY 31680
            parser: .intuosV1, maxX: 45720, maxY: 31680, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 457, activeHeightMM: 305),

        // ── Intuos3 (PTZ-xxx, 2003–2006) — intuos3 parser ───────────────────
        // Status byte layout differs from Intuos5: bit 6 (0x40) is proximity.
        // Aux reports: 0x03 (8 keys in byte 4) and 0x0C (4+4 split).
        // Two-stage feature init: [0x02,0x02] immediately, [0x04,0x00] after 150 ms.
        // PTZ-631W (0x00B5) confirmed live; remaining entries ⚠ estimated but
        // the two-stage init and proximity bit are common to the whole PTZ family.
        .init(
            productID: 0x00B0, name: "Intuos3 4×5 (PTZ-431)",  // ⚠ estimated
            parser: .intuos3, maxX: 25400, maxY: 20320, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])], activeWidthMM: 127, activeHeightMM: 102),
        .init(
            productID: 0x00B1, name: "Intuos3 6×8 (PTZ-631)",  // cross-referenced: linuxwacom + OTD
            parser: .intuos3, maxX: 40640, maxY: 30480, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])],
            confidence: .crossReferenced,
            activeWidthMM: 203, activeHeightMM: 152),
        .init(
            productID: 0x00B2, name: "Intuos3 9×12 (PTZ-930)",  // ⚠ estimated
            parser: .intuos3, maxX: 60960, maxY: 45720, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])], activeWidthMM: 305, activeHeightMM: 229),
        .init(
            productID: 0x00B3, name: "Intuos3 12×12 (PTZ-1231)",  // ⚠ estimated
            parser: .intuos3, maxX: 60960, maxY: 60960, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])], activeWidthMM: 305, activeHeightMM: 305),
        .init(
            productID: 0x00B4, name: "Intuos3 12×19 (PTZ-1231W)",  // ⚠ estimated
            parser: .intuos3, maxX: 97536, maxY: 60960, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])], activeWidthMM: 483, activeHeightMM: 305),
        .init(
            productID: 0x00B5, name: "Intuos3 WS (PTZ-631W)",  // ✓ confirmed live
            parser: .intuos3, maxX: 54204, maxY: 31750, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasTouchStrips: true, hasEraser: true,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])],
            confidence: .verified,
            activeWidthMM: 270.5, activeHeightMM: 158.5),
        .init(
            productID: 0x00B7, name: "Intuos3 4×6 (PTZ-431W)",  // ⚠ estimated
            parser: .intuos3, maxX: 31496, maxY: 19685, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            initSteps: [.featureReport([0x02, 0x02]), .delay(0.15), .featureReport([0x04, 0x00])], activeWidthMM: 152, activeHeightMM: 102),

        // ── Intuos4 (PTK-xxx, 2009–2012) — intuosV1 parser ───────────────────
        // OLED display on each express key; 2048-level pressure (11-bit).
        .init(
            productID: 0x00B8, name: "Intuos4 S (PTK-440)",  // ⚠ estimated
            parser: .intuosV1, maxX: 31496, maxY: 19685, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x00B9, name: "Intuos4 M (PTK-640)",  // ⚠ estimated
            parser: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 229, activeHeightMM: 152),
        .init(
            // Dimensions corrected to kernel wacom_features_0xBA (65024×40640).
            productID: 0x00BA, name: "Intuos4 L (PTK-840)",  // ⚠ from kernel
            parser: .intuosV1, maxX: 65024, maxY: 40640, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 330, activeHeightMM: 203),
        .init(
            productID: 0x00BB, name: "Intuos4 XL (PTK-1240)",  // ⚠ estimated
            parser: .intuosV1, maxX: 97536, maxY: 60960, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 483, activeHeightMM: 305),
        .init(
            // Dimensions corrected to kernel wacom_features_0xBC (40640×25400).
            productID: 0x00BC, name: "Intuos4 WL (PTK-540WL)",  // ⚠ from kernel
            parser: .intuosV1, maxX: 40640, maxY: 25400, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 203, activeHeightMM: 127),

        // ── Intuos5 / Intuos Pro 1st-gen (PTH-x50/x51, 2012–2013) ──────────────
        // IntuosV1 10-byte format, 2047-level pressure (vs Intuos Pro 2nd-gen's 8191).
        // Predate widespread BT support; no known BLE variants (USB only).
        //
        // │ Model  │ Gen │ Name Change         │   USB PID   │  BT Classic  │  BLE │
        // │────────┼─────┼─────────────────────┼─────────────┼──────────────┼──────│
        // │PTH-450 │ 1   │ Intuos5 S           │   0x0026    │    unknown   │  —   │
        // │PTH-650 │ 1   │ Intuos5 M           │   0x0027    │    unknown   │  —   │
        // │PTH-850 │ 1   │ Intuos5 L           │   0x0028    │    unknown   │  —   │
        // │PTH-451 │ 2   │ Intuos Pro S (1st)  │   0x0314    │    unknown   │  —   │
        // │PTH-651 │ 2   │ Intuos Pro M (1st)  │   0x0316    │    unknown   │  —   │
        // │PTH-851 │ 2   │ Intuos Pro L (1st)  │   0x00F8    │    unknown   │  —   │
        // │                                                                          │
        // │ These are all IntuosV1 format. Intuos Pro 2nd-gen (PTH-460/660/860)   │
        // │ switched to IntuosV2 format and added Bluetooth support.              │
        // └──────────────────────────────────────────────────────────────────────────┘
        .init(
            productID: 0x0026, name: "Intuos5 S (PTH-450)",  // ⚠ estimated
            parser: .intuosV1, maxX: 31496, maxY: 19685, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x0027, name: "Intuos5 M (PTH-650)",  // ⚠ estimated
            parser: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 229, activeHeightMM: 152),
        .init(
            productID: 0x0028, name: "Intuos5 L (PTH-850)",
            parser: .intuosV1, maxX: 65024, maxY: 40640, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 330, activeHeightMM: 203),

        // ── Intuos Pro first-gen (PTH-x51, 2013) — intuosV1 parser ───────────
        // Renamed from "Intuos5" to "Intuos Pro"; same HID format.
        .init(
            productID: 0x0314, name: "Intuos Pro S (PTH-451)",  // ⚠ estimated
            parser: .intuosV1, maxX: 31496, maxY: 19685, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x0316, name: "Intuos Pro M (PTH-651)",  // ⚠ estimated
            parser: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 224, activeHeightMM: 140),
        .init(
            // Dimensions corrected to kernel wacom_features_0x317 (65024×40640).
            // Previous values (44704×27940) were the PTH-651 M-size by mistake.
            productID: 0x0317, name: "Intuos Pro L (PTH-851)",  // ✓ confirmed live
            parser: .intuosV1, maxX: 65024, maxY: 40640, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .verified,
            activeWidthMM: 325.1, activeHeightMM: 203.2),

        // ── Intuos Pro second-gen (PTH-x60/x80, 2017–present) — intuosV2 ─────
        // 192-byte reports, LE24 coordinates, 8192-level pressure (13-bit).
        // Also supports BLE HOGP (Report IDs 0x01 pen, 0x03 pad).
        // seizeUSB=true: standard-HID-mouse interface must be seized.
        //
        // ┌─ INTUOS PRO 2ND-GEN DEVICE VARIANTS (PTH-460/660/860) ────────────────┐
        // │ All use IntuosV2 parser; differ only in coordinates (S/M/L sizes).     │
        // │                                                                         │
        // │ Model  │ Size │   USB PID   │  BT Classic PID  │   BLE PID (TBD)      │
        // │────────┼──────┼─────────────┼──────────────────┼──────────────────    │
        // │PTH-460 │  S   │   0x0352    │    0x035B (+9)   │    ? (LE IntuosPro S)│
        // │PTH-660 │  M   │   0x0357    │    0x0360 (+9)   │    ? (LE IntuosPro M)│
        // │PTH-860 │  L   │   0x0358    │    0x0361 (+9)   │    ? (LE IntuosPro L)│
        // │                                                                         │
        // │ Transport notes:                                                       │
        // │  • USB: standard HID, requires initSteps=[] + InputMode init           │
        // │  • BT Classic: 361-byte 0x80 container, initSteps=[], no InputMode    │
        // │  • BLE: GATT always active, limited to trackpad mode on macOS         │
        // │    (AppleBluetoothMultitouch kext conflict — requires device seizure) │
        // │                                                                        │
        // │ Pairing hint: BT Classic = power on with USB disconnected, LED blinks│
        // │              BLE = standard BLE pairing (limited functionality)       │
        // └────────────────────────────────────────────────────────────────────────┘
        .init(
            productID: 0x0352, name: "Intuos Pro S (PTH-460)",  // ⚠ estimated
            parser: .intuosV2, maxX: 31496, maxY: 19685, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: true, activeWidthMM: 160, activeHeightMM: 100),
        .init(
            productID: 0x0357, name: "Intuos Pro M (PTH-660)",  // ✓ confirmed live
            parser: .intuosV2, maxX: 44800, maxY: 29600, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 5,
            // touchMaxX/Y still estimated as pen/5 ratio; both USB and BT
            // paths use this entry (PTH-660 over BT presents this PID).
            // BT touch confirmed working 2026-05-22; exact max coords
            // unverified but cursor positioning feels correct.
            touchMaxX: 8960, touchMaxY: 5920,
            seizeUSB: true,
            confidence: .verified,
            activeWidthMM: 224.0, activeHeightMM: 148.0),
        .init(
            productID: 0x0358, name: "Intuos Pro L (PTH-860)",  // ✓ confirmed live (USB + BT)
            parser: .intuosV2, maxX: 62200, maxY: 43200, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 5,
            // USB coords confirmed 2026-05-21; BT touch confirmed 2026-05-22 via
            // live capture (PID 0x0358 presented over BT, same as PTH-660 pattern).
            touchMaxX: 12439, touchMaxY: 8639,
            seizeUSB: true,
            confidence: .verified,
            activeWidthMM: 311.0, activeHeightMM: 216.0),

        // ── Bamboo / CTL consumer line — bamboo parser ────────────────────────
        // 20-byte Report ID 0x10. Decoder not yet implemented.
        // Entries present for name resolution and future routing.
        .init(
            productID: 0x00D0, name: "Bamboo Touch (CTT-460)",  // ⚠ estimated
            parser: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, activeWidthMM: 127, activeHeightMM: 76),
        .init(
            productID: 0x00D1, name: "Bamboo Pen & Touch (CTH-460)",  // ⚠ estimated
            parser: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x00D4, name: "Bamboo Capture (CTH-470)",  // ⚠ estimated
            parser: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x00D6, name: "Bamboo Pen (CTL-460)",  // ⚠ estimated
            parser: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 2, hasTouchRing: false, hasEraser: false,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x00D7, name: "Bamboo Pen (CTL-660)",  // ⚠ from kernel — dims from kernel 0xD7 (BambooPT 2FG Small); name attribution uncertain
            parser: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 2, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x00DA, name: "Bamboo Pen & Touch 2 (CTH-461)",  // ⚠ estimated
            parser: .bamboo, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: false,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x00DB, name: "Bamboo Connect (CTL-470)",  // ⚠ from kernel — dims from kernel 0xDB (Bamboo 2FG 6x8 SE); name attribution uncertain
            parser: .bamboo, maxX: 21648, maxY: 13700, maxPressure: 1023,
            buttonCount: 2, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, activeWidthMM: 217, activeHeightMM: 137),

        // ── Cintiq pen-display line — cintiqV1 parser ────────────────────────
        // seizeUSB=true: Cintiq pen-displays appear as USB HID devices and
        // require seizure to prevent kernel handling of their pen interface.
        // All old Cintiqs use the WACOM_24HD report layout handled by CintiqV1Decoder:
        //   Report 0x02 — pen (10-byte IntuosV1, WACOM_24HD typeNibble dispatch)
        //   Report 0x0C — express keys + touch rings
        //   Report 0x01 — tip-switch (requires device seizure)
        // 0x00C0 previously listed as "Cintiq 20WSX" and 0x00C4 as "Cintiq
        // 13HD (DTK-1300)"; both were estimation errors. Kernel identifies
        // them as DTF-720 and DTF-521 respectively — small PL-family pen
        // displays from the early 2000s. We have no PL decoder, so those
        // PIDs would not have worked even with corrected dimensions. The
        // real DTK-1300 lives at 0x0304 (an entry that already exists);
        // there is no Cintiq 20WSX in the kernel ID table at all.
        // Entries removed during 2026-05-15 audit; do not re-add under
        // the wrong names.
        .init(
            productID: 0x00C6, name: "Cintiq 12WX",  // ⚠ estimated
            parser: .cintiqV1, maxX: 53020, maxY: 33440, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 261, activeHeightMM: 163),
        .init(
            // Kernel calls this "Cintiq 21UX2" (DTZ-2100B / second gen).
            // Pressure corrected from 1023 to 2047. Renamed to disambiguate
            // from the gen-1 21UX at 0x003F.
            productID: 0x00CC, name: "Cintiq 21UX2 (DTZ-2100B)",  // ⚠ from kernel + OTD
            parser: .cintiqV1, maxX: 87200, maxY: 65600, maxPressure: 2047,
            buttonCount: 18, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 432, activeHeightMM: 330),
        .init(
            productID: 0x00F4, name: "Cintiq 24HD (DTK-2400)",  // ✓ confirmed live
            parser: .cintiqV1, maxX: 104480, maxY: 65600, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasDualRings: true, ringSlotCount: 3, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], ledCompanionPID: 0x0056,
            confidence: .verified,
            activeWidthMM: 519.0, activeHeightMM: 324.0),
        .init(
            productID: 0x00F8, name: "Cintiq 24HD Touch (DTH-2400)",  // ⚠ estimated
            parser: .cintiqV1, maxX: 104480, maxY: 65600, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: true, hasDualRings: true, ringSlotCount: 3, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 1,
            isPenDisplay: true,
            seizeUSB: true, initSteps: [.featureReport([0x02, 0x02])], ledCompanionPID: 0x0056, activeWidthMM: 533, activeHeightMM: 330),
        .init(
            productID: 0x00FA, name: "Cintiq 22HD (DTK-2200)",  // ⚠ from OTD (dims/buttonCount corrected from ⚠ estimated)
            parser: .cintiqV1, maxX: 95040, maxY: 54260, maxPressure: 2047,
            buttonCount: 20, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 483, activeHeightMM: 279),
        // 0x00FB previously listed as "Cintiq 21UX 2 (DTZ-2100B)" but Linux
        // input-wacom's `wacom_features_0xFB` identifies it as DTU-1031 (a
        // small entry-level DTUS pen display). The DTZ-2100B name was an
        // estimation error; corrected during the 2026-05-15 DTUS pass.

        // ── Intuos4 (PTK) additional variants ────────────────────────────────
        .init(
            productID: 0x0029, name: "Wacom PTK-450",  // ⚠ from OTD
            parser: .intuosV1, maxX: 31496, maxY: 19685, maxPressure: 2047,
            buttonCount: 6, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x002A, name: "Wacom PTK-650",  // ⚠ from OTD
            parser: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 229, activeHeightMM: 152),

        // ── Intuos Pro first-gen additional variant ───────────────────────────
        .init(
            productID: 0x0315, name: "Wacom PTH-651",  // ⚠ from OTD
            parser: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 229, activeHeightMM: 152),

        // ── Intuos Pro second-gen Bluetooth Classic PIDs (PTH-460/660/860) ──────
        // These PIDs appear when the tablet connects over BT Classic (transport="Bluetooth").
        // Coordinate ranges match the USB entries; seizeUSB=false (BT Classic needs no seizure).
        .init(
            productID: 0x0360, name: "Wacom PTH-660",  // ⚠ from OTD
            parser: .intuosV2, maxX: 44800, maxY: 29600, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 5,
            // Touch values mirror the USB PTH-660 entry.  In practice this
            // entry is rarely hit: PTH-660 over BT presents the USB PID
            // 0x0357, not 0x0360, so the USB entry's touchMaxX/Y is what
            // actually drives BT touch projection (confirmed working
            // 2026-05-22).  Kept here as a defensive fallback.
            touchMaxX: 8960, touchMaxY: 5920,
            seizeUSB: false, activeWidthMM: 229, activeHeightMM: 152),
        .init(
            productID: 0x0361, name: "Intuos Pro L (PTH-860) BT",  // ✓ confirmed live (BT Classic)
            parser: .intuosV2, maxX: 62200, maxY: 43200, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 5,
            // PTH-860 over BT presents PID 0x0358 (USB PID), not this entry —
            // same pattern as PTH-660/0x0360.  Kept as a defensive fallback.
            // Touch confirmed working 2026-05-22 via 0x0358 path.
            touchMaxX: 12439, touchMaxY: 8639,
            seizeUSB: false,
            confidence: .verified,
            activeWidthMM: 311.0, activeHeightMM: 216.0),
        .init(
            productID: 0x035B, name: "Intuos Pro S (PTH-460) BT",  // ⚠ BT Classic PID (USB 0x0352 + 9)
            parser: .intuosV2, maxX: 31496, maxY: 19685, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: true, hasEraser: true,
            seizeUSB: false, activeWidthMM: 160, activeHeightMM: 100),
        .init(
            productID: 0x0392, name: "Wacom PTH-460",  // ⚠ from OTD
            parser: .intuosV2, maxX: 31920, maxY: 19950, maxPressure: 8191,
            buttonCount: 6, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x03DC, name: "Wacom PTH-460",  // ⚠ from OTD
            parser: .intuosV2, maxX: 31920, maxY: 19950, maxPressure: 8191,
            buttonCount: 6, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, activeWidthMM: 152, activeHeightMM: 102),

        // ── Bamboo / Graphire-era CTE / CTF consumer line ─────────────────────
        // Graphire-era: intuosV1 8-byte format.
        .init(
            productID: 0x006A, name: "Wacom CTE-460",  // ⚠ from kernel
            parser: .intuosV1, maxX: 14760, maxY: 9225, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])]),
        .init(
            productID: 0x006B, name: "Wacom CTE-660",  // ⚠ from kernel
            parser: .bamboo, maxX: 21648, maxY: 13530, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 203, activeHeightMM: 127),
        .init(
            productID: 0x0018, name: "Wacom CTE-650",  // ⚠ from OTD
            parser: .bamboo, maxX: 21648, maxY: 13530, maxPressure: 511,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x0069, name: "Wacom CTF-430",  // ⚠ from OTD
            parser: .bamboo, maxX: 5104, maxY: 3712, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            // dimensions: libwacom wacom-bamboo-one.tablet (Width=127, Height=102)
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced,
            activeWidthMM: 127, activeHeightMM: 102),

        // ── Bamboo CTH (pen + touch) ──────────────────────────────────────────
        .init(
            productID: 0x0319, name: "Wacom CTH-300",  // ⚠ from OTD
            parser: .bamboo, maxX: 10690, maxY: 6680, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            // dimensions: libwacom wacom-bamboo-pad-wireless.tablet (Width=102, Height=76)
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 102, activeHeightMM: 76),
        .init(
            productID: 0x0318, name: "Wacom CTH-301",  // ⚠ from OTD
            parser: .bamboo, maxX: 10690, maxY: 6680, maxPressure: 511,
            buttonCount: 2, hasTouchRing: false, hasEraser: true,
            // dimensions: libwacom wacom-bamboo-pad.tablet (Width=102, Height=76)
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 102, activeHeightMM: 76),
        .init(
            productID: 0x00D2, name: "Wacom CTH-461",  // ⚠ from OTD
            parser: .intuosV1, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x00DE, name: "Wacom CTH-470",  // ⚠ from OTD
            parser: .intuosV1, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x0302, name: "Wacom CTH-480",  // ⚠ from OTD
            parser: .intuosV1, maxX: 15200, maxY: 9500, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x033C, name: "Wacom CTH-490",  // ⚠ from OTD
            parser: .intuosV1, maxX: 15200, maxY: 9500, maxPressure: 2047,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x00D3, name: "Wacom CTH-661",  // ⚠ from OTD
            parser: .intuosV1, maxX: 21648, maxY: 13700, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 217, activeHeightMM: 137),
        .init(
            productID: 0x00D8, name: "Wacom CTH-661",  // ⚠ from OTD
            parser: .intuosV1, maxX: 21648, maxY: 13700, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 217, activeHeightMM: 137),
        .init(
            productID: 0x00DF, name: "Wacom CTH-670",  // ⚠ from OTD
            parser: .intuosV1, maxX: 21648, maxY: 13700, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x0303, name: "Wacom CTH-680",  // ⚠ from OTD
            parser: .intuosV1, maxX: 21600, maxY: 13500, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x033E, name: "Wacom CTH-690",  // ⚠ from OTD
            parser: .intuosV1, maxX: 21600, maxY: 13500, maxPressure: 2047,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),

        // ── Wacom One / Intuos (CTL) pen-only line ────────────────────────────
        .init(
            productID: 0x00DD, name: "Wacom CTL-470",  // ⚠ from OTD
            parser: .intuosV1, maxX: 14720, maxY: 9200, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x0300, name: "Wacom CTL-471",  // ⚠ from kernel
            parser: .intuosV1, maxX: 14720, maxY: 9225, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x037A, name: "Wacom CTL-472",  // ⚠ from OTD
            parser: .intuosV1, maxX: 15200, maxY: 9500, maxPressure: 2047,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x030E, name: "Wacom CTL-480",  // ⚠ from OTD
            parser: .intuosV1, maxX: 15200, maxY: 9500, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x033B, name: "Wacom CTL-490",  // ⚠ from OTD
            parser: .intuosV1, maxX: 15200, maxY: 9500, maxPressure: 2047,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x0301, name: "Wacom CTL-671",  // ⚠ from OTD
            parser: .intuosV1, maxX: 21600, maxY: 13500, maxPressure: 1023,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x037B, name: "Wacom CTL-672",  // ⚠ from OTD
            parser: .intuosV1, maxX: 21600, maxY: 13500, maxPressure: 2047,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x0323, name: "Wacom CTL-680",  // ⚠ from OTD
            parser: .intuosV1, maxX: 21600, maxY: 13500, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x033D, name: "Wacom CTL-690",  // ⚠ from OTD
            parser: .intuosV1, maxX: 21600, maxY: 13500, maxPressure: 2047,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced, activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x0374, name: "Wacom CTL-4100",  // ⚠ from OTD
            parser: .intuosV2, maxX: 15200, maxY: 9500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x0376, name: "Wacom CTL-4100WL",  // ⚠ from OTD
            parser: .intuosV2, maxX: 15200, maxY: 9500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x0377, name: "Wacom CTL-4100WL",  // ⚠ from OTD
            parser: .intuosV2, maxX: 15200, maxY: 9500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false,
            confidence: .crossReferenced, activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x03C5, name: "Wacom CTL-4100WL",  // ⚠ from OTD
            parser: .intuosV2, maxX: 15200, maxY: 9500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 152, activeHeightMM: 102),
        .init(
            productID: 0x0375, name: "Wacom CTL-6100",  // ⚠ from OTD
            parser: .intuosV2, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x0378, name: "Wacom CTL-6100WL",  // ⚠ from OTD
            parser: .intuosV2, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x03C7, name: "Wacom CTL-6100WL",  // ⚠ from OTD
            parser: .intuosV2, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 216, activeHeightMM: 135),

        // ── Wacom One CTC (IntuosV3) consumer line ────────────────────────────
        // CTC-4110WL / CTC-6110WL use the IntuosV3 report parser (same as
        // PTK-470/670/870), not the IntuosV2 used by CTL-4100/6100.
        // Confirmed from OTD Configurations/Wacom/CTC-4110WL.json and
        // CTC-6110WL.json (FeatureInitReport "AgI=" = [0x02, 0x02]).
        // No touch ring, no express keys, no eraser — pen-only AES devices.
        .init(
            productID: 0x0100, name: "Wacom CTC-4110WL",  // ⚠ from OTD
            parser: .intuosV3, maxX: 15200, maxY: 9500, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])]),
        .init(
            productID: 0x0102, name: "Wacom CTC-6110WL",  // ⚠ from OTD
            parser: .intuosV3, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 216, activeHeightMM: 135),
        .init(
            productID: 0x0103, name: "Wacom CTC-6110WL",  // ⚠ from OTD
            parser: .intuosV3, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: false,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 216, activeHeightMM: 135),

        // ── Cintiq pen-display additional models ──────────────────────────────
        .init(
            // Pressure and dimensions corrected to kernel wacom_features_0x304
            // (59552×33848, 1023 pressure). Previous dims were 59800×34200 (~0.4 %
            // drift); aligned during 2026-05-21 audit pass.
            productID: 0x0304, name: "Wacom Cintiq 13HD (DTK-1300)",  // ⚠ from OTD
            parser: .cintiqV1, maxX: 59552, maxY: 33848, maxPressure: 1023,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 305, activeHeightMM: 178),
        .init(
            productID: 0x00F9, name: "Wacom Cintiq 22HD (DTK-2200)",  // ⚠ from OTD
            parser: .cintiqV1, maxX: 95040, maxY: 54260, maxPressure: 2047,
            buttonCount: 20, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 479, activeHeightMM: 271),
        .init(
            productID: 0x034F, name: "Wacom DTH-1320",  // ⚠ from OTD
            parser: .intuosV2, maxX: 59552, maxY: 33848, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 10,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 305, activeHeightMM: 178),
        .init(
            productID: 0x0390, name: "Wacom Cintiq 16 (DTK-1660)",  // ⚠ from OTD
            parser: .intuosV2, maxX: 69632, maxY: 39518, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 356, activeHeightMM: 203),
        .init(
            productID: 0x03AE, name: "Wacom Cintiq 16 (DTK-1660)",  // ⚠ from OTD
            parser: .intuosV2, maxX: 69632, maxY: 39518, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 356, activeHeightMM: 203),
        .init(
            productID: 0x03A6, name: "Wacom DTC-133",  // ⚠ from OTD
            parser: .intuosV2, maxX: 29434, maxY: 16556, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 279, activeHeightMM: 152),
        .init(
            productID: 0x03C0, name: "Wacom Cintiq Pro 27 (DTH-271)",  // cross-referenced: linuxwacom + libwacom + OTD
            parser: .intuosV2, maxX: 120032, maxY: 67868, maxPressure: 8191,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 10,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced,
            activeWidthMM: 610, activeHeightMM: 330),
        .init(
            productID: 0x03F0, name: "Wacom Movink 13 (DTH-135)",  // ⚠ from OTD
            parser: .intuosV3, maxX: 59552, maxY: 33848, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 10,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 294.6, activeHeightMM: 165.1),

        // ── Wireless dongle ───────────────────────────────────────────────────
        // ACK-40401 RF dongle (PID 0x0084) presents the same HID interfaces as
        // the paired tablet.  WacomFallbackDevice auto-detects the report family.
        // Report 0x80 carries wireless status (byte[1]: 0x02=active, 0x05=lost,
        // 0x06=battery low).  maxX/maxY/maxPressure are 0 — queried via HID
        // descriptor on first connection by WacomFallbackDevice.querySpec().
        .init(
            productID: 0x0084, name: "ACK-40401 Wireless Dongle",
            parser: .intuosV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false),

        // ── Wireless receiver dongles (HID-based) ─────────────────────────────
        // Blueto WL tablets (Intuos4 WL, Intuos5 WL, Intuos Pro gen1 WL) pair with
        // USB wireless receivers instead of integrated Bluetooth. The receiver
        // enumerates as HID and presents the paired tablet's report format.
        // These are experimental (untested on owned hardware).
        .init(
            productID: 0x009D, name: "Wireless Receiver (Intuos4/5 WL)",  // ⚠ experimental
            parser: .intuosV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])]),
        .init(
            productID: 0x009A, name: "Wireless Receiver (Intuos Pro gen1 WL)",  // ⚠ experimental
            parser: .intuosV1, maxX: 0, maxY: 0, maxPressure: 0,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])]),

        // ── Upstream OTD sync 2026-05-15 ──────────────────────────────────────
        // Imported from OpenTabletDriver master, not yet in Linux input-wacom
        // (4.18 branch, April 2026). Pen-only; coordinates and pressure
        // extrapolated from OTD configs and unverified on hardware.
        //
        // PTK-470/670/870 require the IntuosV3 decoder (added in the same
        // session as this comment); pen-side events decode but the two
        // relative-step scroll wheels do not — our aux pipeline models
        // absolute touch-ring positions, not encoder deltas. PTK-670/870
        // also have 10 express keys; the first 8 of the primary byte are
        // exposed, the two extras drop until AuxButtons grows past 8.
        //
        // PL-800-U was NOT imported — PLReportParser uses 8-byte reports
        // with bit-6 in-range, incompatible with our IntuosV1 decoder and
        // not worth a dedicated parser for hardware that's effectively gone.
        // See Notes/Scratch/Upstream-Sync-2026-05-15.md for the analysis.
        .init(
            productID: 0x03CE, name: "Wacom DTC-121",  // ⚠ from OTD
            parser: .intuosV2, maxX: 25632, maxY: 14418, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 279, activeHeightMM: 152),
        .init(
            productID: 0x005B, name: "Wacom Cintiq 22HD Touch (DTH-2200)",  // ⚠ from OTD (parser corrected from ⚠ kernel)
            parser: .cintiqV1, maxX: 95600, maxY: 54200, maxPressure: 2047,
            buttonCount: 20, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 1,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 483, activeHeightMM: 279),
        .init(
            productID: 0x03D0, name: "Wacom Cintiq Pro 22 (DTH-227)",  // cross-referenced: linuxwacom + libwacom + OTD
            parser: .intuosV2, maxX: 96012, maxY: 54356, maxPressure: 8191,
            buttonCount: 8, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            confidence: .crossReferenced,
            activeWidthMM: 457, activeHeightMM: 254),
        .init(
            productID: 0x03F5, name: "Wacom PTK-470",  // ⚠ from OTD (IntuosV3)
            parser: .intuosV3, maxX: 37400, maxY: 21000, maxPressure: 8191,
            buttonCount: 5, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 178, activeHeightMM: 102),
        .init(
            productID: 0x03F7, name: "Wacom PTK-670",  // ⚠ from OTD (IntuosV3)
            parser: .intuosV3, maxX: 52600, maxY: 29600, maxPressure: 8191,
            buttonCount: 10, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 254, activeHeightMM: 152),
        .init(
            productID: 0x03F9, name: "Wacom PTK-870",  // ⚠ from OTD (IntuosV3)
            parser: .intuosV3, maxX: 69800, maxY: 39000, maxPressure: 8191,
            buttonCount: 10, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 356, activeHeightMM: 203),

        // ── DTUS family (Linux input-wacom DTUS / DTUSX) ──────────────────────
        // Small entry-level pen displays sharing wacom_dtus_irq.  Dimensions
        // and button counts from input-wacom 4.18 wacom_wac.c, decoded by
        // DTUSDecoder.swift.  Experimental: pen events should decode but no
        // hardware verification yet.  Feature init [0x02, 0x02] sent on the
        // chance some firmware revisions require it; the kernel block does
        // not specify a .feature_init array so it may be unnecessary.
        .init(
            productID: 0x0343, name: "Wacom DTK1651",  // ⚠ from kernel
            parser: .dtus, maxX: 34816, maxY: 19759, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 356, activeHeightMM: 203),
        .init(
            productID: 0x00FB, name: "Wacom DTU-1031",  // ⚠ from kernel
            parser: .dtus, maxX: 22096, maxY: 13960, maxPressure: 511,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            // dimensions: libwacom wacom-dtu-1031.tablet (Width=229, Height=127).
            // Kernel math (22096/100 × 13960/100) gives 221×140 — height is
            // wrong (digitiser maxY over-ranges past the bezel).
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 229, activeHeightMM: 127),
        .init(
            productID: 0x032F, name: "Wacom DTU-1031X",  // ⚠ from kernel
            parser: .dtus, maxX: 22672, maxY: 12928, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 229, activeHeightMM: 127),
        .init(
            productID: 0x0336, name: "Wacom DTU-1141",  // ⚠ from kernel
            parser: .dtus, maxX: 23672, maxY: 13403, maxPressure: 1023,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 229, activeHeightMM: 127),

        // ── DTU family (Linux input-wacom DTU type, wacom_dtu_irq) ────────────
        // Older entry-level pen displays. Single pen report 0x02 (LE16 X/Y,
        // 9-bit pressure). No pad buttons.  Decoded by DTUDecoder.swift.
        // Dimensions and pressure from input-wacom 4.18 wacom_wac.c.
        // Experimental: no hardware verification yet.
        .init(
            productID: 0x00CE, name: "Wacom DTU-2231",  // ⚠ from kernel
            parser: .dtu, maxX: 47864, maxY: 27011, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 483, activeHeightMM: 279),
        .init(
            productID: 0x00F0, name: "Wacom DTU-1631",  // ⚠ from kernel
            parser: .dtu, maxX: 34623, maxY: 19553, maxPressure: 511,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 356, activeHeightMM: 203),

        // ── Imported from wacom-hid-descriptors 2026-05-26 ─────────────────────
        // Recognition-only entries for devices that appear in real linuxwacom
        // sysinfo dumps (https://github.com/linuxwacom/wacom-hid-descriptors)
        // but were absent from this registry.  Parser family, maxX/maxY, and
        // pressure bit-depth are *guesses* by similarity to the closest in-
        // registry relative — these entries name the device and provide
        // libwacom-derived physical dimensions, but the decoder output is not
        // verified.  Each one is `.experimental` and a candidate for promotion
        // once a real capture log (in-app or hid-recorder format) replays
        // cleanly through the assumed parser.
        .init(
            productID: 0x0325, name: "Wacom Cintiq Companion 2 (DTH-W1310)",  // ⚠ recognition-only
            parser: .cintiqV1, maxX: 61000, maxY: 35600, maxPressure: 2047,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 10,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 305, activeHeightMM: 178),
        .init(
            productID: 0x0326, name: "Wacom Cintiq Companion 2 (DTH-W1310, alt)",  // ⚠ recognition-only
            parser: .cintiqV1, maxX: 61000, maxY: 35600, maxPressure: 2047,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 10,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 305, activeHeightMM: 178),
        .init(
            productID: 0x0350, name: "Wacom Cintiq Pro 16 (DTH-1620)",  // ⚠ recognition-only
            parser: .intuosV2, maxX: 71200, maxY: 40600, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 10,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 356, activeHeightMM: 203),
        .init(
            productID: 0x0354, name: "Wacom Cintiq Pro 16 (DTH-1620, alt)",  // ⚠ recognition-only
            parser: .intuosV2, maxX: 71200, maxY: 40600, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 10,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 356, activeHeightMM: 203),
        .init(
            productID: 0x0379, name: "Wacom Intuos BT M (CTL-6100WL)",  // ⚠ recognition-only
            parser: .intuosV2, maxX: 21600, maxY: 13500, maxPressure: 4095,
            buttonCount: 4, hasTouchRing: false, hasEraser: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 229, activeHeightMM: 127),
        .init(
            productID: 0x03C4, name: "Wacom Cintiq Pro 17 (DTH172)",  // ⚠ recognition-only
            parser: .intuosV2, maxX: 76200, maxY: 40600, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 10,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 381, activeHeightMM: 203),
        .init(
            productID: 0x03CB, name: "Wacom One Pen Display 13 (DTH134)",  // ⚠ recognition-only
            parser: .intuosV2, maxX: 34815, maxY: 18779, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 330, activeHeightMM: 178),
        .init(
            productID: 0x03CF, name: "Wacom DTC121 (alt)",  // ⚠ recognition-only
            parser: .intuosV2, maxX: 29434, maxY: 16036, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 279, activeHeightMM: 152),
        .init(
            productID: 0x03EC, name: "Wacom DTH134",  // ⚠ recognition-only
            parser: .intuosV2, maxX: 34815, maxY: 18779, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 330, activeHeightMM: 178),
        .init(
            productID: 0x03ED, name: "Wacom DTC121",  // ⚠ recognition-only
            parser: .intuosV2, maxX: 29434, maxY: 16036, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 279, activeHeightMM: 152),
        .init(
            productID: 0x03F2, name: "Wacom Movink 13 (DTH-135, alt)",  // ⚠ recognition-only
            parser: .intuosV3, maxX: 59552, maxY: 33848, maxPressure: 8191,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            hasFingerTouch: true, maxTouchContacts: 10,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])], activeWidthMM: 294.6, activeHeightMM: 165.1),
        .init(
            productID: 0x4900, name: "Wacom DTC121 (alt 2)",  // ⚠ recognition-only
            parser: .intuosV2, maxX: 29434, maxY: 16036, maxPressure: 4095,
            buttonCount: 0, hasTouchRing: false, hasEraser: true,
            isPenDisplay: true,
            seizeUSB: false, initSteps: [.featureReport([0x02, 0x02])],
            activeWidthMM: 279, activeHeightMM: 152),

        // ── Legacy Bluetooth devices (serial-port based, out-of-scope) ─────────
        // CTE-630BT (Graphire4 Bluetooth, PID 0x0081) and XD-0608-BT (Intuos2
        // Bluetooth, PID 0x0CA) use RFCOMM/SPP (serial port over Bluetooth)
        // instead of the HID Profile. They do NOT enumerate as IOHIDDevices;
        // instead they appear as /dev/cu.* serial ports. These require a
        // completely different driver architecture (serial I/O, not IOHIDManager).
        // Not implemented; documented for reference.
        // .init(productID: 0x0081, name: "CTE-630BT (Graphire4 BT) — SPP/RFCOMM", ...),
        // .init(productID: 0x0CA, name: "XD-0608-BT (Intuos2 BT) — SPP/RFCOMM", ...),
    ]

    // MARK: - Transport-variant unification

    /// Maps Bluetooth Classic and wireless dongle PIDs to the canonical (USB) PID for their model family.
    ///
    /// Wacom assigns distinct product IDs per transport (USB, Bluetooth, wireless dongle).
    /// This map normalizes them so that all three transports of the same physical tablet
    /// share one `DeviceContext` and one settings namespace.
    ///
    /// The USB PID is canonical because it's the reference for HID feature reports and
    /// is always enumerable first. Example: PTH-660 family maps to 0x0357 (USB).
    ///
    /// Note: PTH-460 wireless dongle PID (if it exists as a separate entry) needs hardware
    /// verification before adding, as there may be a collision with PTH-860 USB 0x0358.
    static let canonicalPIDMap: [Int: Int] = [
        // Intuos Pro S (PTH-460 family)
        0x035B: 0x0352,  // PTH-460 BT Classic (USB PID 0x0352 not yet in registry)
        0x035F: 0x0356,  // PTH-460 BT Classic (alternative USB variant?)

        // Intuos Pro M (PTH-660 family)
        0x0359: 0x0357,  // Wireless dongle
        0x0360: 0x0357,  // BT Classic

        // Intuos Pro L (PTH-860 family)
        0x035A: 0x0358,  // Wireless dongle
        0x0361: 0x0358,  // BT Classic
    ]

    // MARK: Lookups

    /// Returns the spec for `productID`, or nil if unrecognised.
    static func spec(for productID: Int) -> WacomDeviceSpec? {
        knownDevices.first { $0.productID == productID }
    }

    /// Returns the best-matching spec for `productID`, optionally using the
    /// device's `kIOHIDProductKey` string to disambiguate when more than one
    /// entry shares the PID.
    ///
    /// Selection order among entries with matching `productID`:
    ///   1. An entry whose `productStringMatch` is a case-insensitive
    ///      substring of `productString` (when `productString != nil`).
    ///   2. An entry with `productStringMatch == nil` (the catch-all).
    ///   3. The first entry, as a last resort.
    ///
    /// Wacom has no PID collisions today, so this returns the same result as
    /// `spec(for:)` for every current device.  The overload exists so the
    /// app-side lookup path is already vendor-neutral when Huion / Xencelabs
    /// support arrives.
    static func spec(forProductID productID: Int, productString: String?) -> WacomDeviceSpec? {
        let matches = knownDevices.filter { $0.productID == productID }
        guard !matches.isEmpty else { return nil }
        if let needle = productString?.lowercased() {
            if let hit = matches.first(where: {
                guard let m = $0.productStringMatch?.lowercased(), !m.isEmpty else { return false }
                return needle.contains(m)
            }) {
                return hit
            }
        }
        return matches.first(where: { $0.productStringMatch == nil }) ?? matches.first
    }

    /// Human-readable display name for any Wacom product.
    /// Returns "Wacom 0xXXXX" for PIDs not yet in the table.
    static func deviceName(forProductID productID: Int) -> String {
        spec(for: productID)?.name
            ?? "Wacom 0x\(String(productID, radix: 16, uppercase: true))"
    }

    /// True when a real decoder exists for this device.
    /// All five parser families have decoders as of Phase 4 (2026-05-07).
    /// `.graphire` is wired up but routes carry `confidence: .experimental` —
    /// the decoder is kernel-canonical but not yet hardware-validated.
    static func hasLiveDecoder(for productID: Int) -> Bool {
        spec(for: productID) != nil
    }

    /// Returns the canonical (USB) product ID for any transport variant of a tablet.
    ///
    /// If `productID` is a Bluetooth or wireless dongle variant, returns the equivalent USB PID.
    /// If `productID` is already canonical (USB) or unmapped, returns it unchanged.
    ///
    /// Used at device connection to unify multi-transport tablets: USB PTH-660 (0x0357),
    /// BT PTH-660 (0x0360), and wireless PTH-660 (0x0359) all normalize to 0x0357, so they
    /// share the same `DeviceContext` and settings namespace.
    static func canonicalProductID(for productID: Int) -> Int {
        canonicalPIDMap[productID] ?? productID
    }
}
