import Foundation

// MARK: - Report protocol family

/// Which HID report decoder handles this device family.
///
/// Used by `WacomDeviceRegistry` to route devices to the correct decoder.
/// The individual per-device Swift classes (PTH660Device, etc.) remain as
/// the live code path during migration; decoders are introduced in Phase 2.
enum ReportParser: String {
    /// Graphire / early consumer line — Report ID 0x01, 8 bytes.
    /// Covers PenPartner, Graphire 1–4, Volito, Bamboo One (CTF-430).
    /// No tool-change packets; eraser detected via tool entry.
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

    /// Bamboo — Report ID 0x10, 20 bytes, BE16 coordinates.
    /// Covers Bamboo Pen & Touch, Bamboo Craft/Comic/Fun series (CTL/CTH-xxx).
    /// Decoder not yet implemented; entries present for routing completeness.
    case bamboo

    /// Intuos3 (PTZ-xxx, 2003–2006) — same 10-byte IntuosV1 payload but with
    /// a different status-byte layout: bit 6 (0x40) is the proximity indicator
    /// (vs. bit 5 in IntuosV1).  Aux reports use IDs 0x03/0x0C, not 0x11.
    /// No BLE support.  Two-stage feature init (see `WacomDeviceSpec.featureInit2`).
    case intuos3
}

// MARK: - Per-device spec

/// All hardware parameters for a single Wacom USB or BLE product.
///
/// This table is the single source of truth for device names, coordinate
/// ranges, pressure depth, and initialisation requirements.  It drives
/// device-name display today and will route `WacomUniversalDevice` once
/// Phase 3 decoders are in place.
///
/// Coordinate-range sources:
///   • Live capture on owned hardware (PTH-851, PTH-660, PTH-860, PTZ-631W, DTK-2400)
///   • Linux input-wacom driver `drivers/input/tablet/wacom_wac.c`
///   • OpenTabletDriver JSON configs `Configurations/Wacom/`
/// Entries marked ⚠ are estimated from driver sources and unverified on hardware.
struct WacomDeviceSpec {
    let productID:    Int
    let name:         String
    let parser:       ReportParser
    let maxX:         Int
    let maxY:         Int
    let maxPressure:  Int
    /// Number of programmable express/side keys (0 if none).
    let buttonCount:  Int
    /// True if this model has a capacitive touch ring or touch strip.
    let hasTouchRing: Bool
    /// True if the pen family includes an eraser tool type.
    let hasEraser:    Bool
    /// Feature report bytes to send once on open (first stage).
    /// nil = no feature init required.
    /// First byte is the HID report ID; remaining bytes are the payload.
    let featureInit:       [UInt8]?
    /// Optional second-stage feature report, sent after `featureInit2Delay` seconds.
    /// Used by Intuos3 devices (PTZ-xxx) which require [0x02,0x02] then [0x04,0x00].
    /// nil = single-stage init only.
    let featureInit2:      [UInt8]?
    /// Delay in seconds before sending `featureInit2`. Default 0.15.
    let featureInit2Delay: Double
    /// True if this interface must be seized (kIOHIDOptionsTypeSeizeDevice)
    /// to prevent macOS's built-in HID mouse driver from consuming reports.
    let seizeUSB:          Bool

    init(
        productID: Int, name: String, parser: ReportParser,
        maxX: Int, maxY: Int, maxPressure: Int,
        buttonCount: Int, hasTouchRing: Bool, hasEraser: Bool,
        featureInit: [UInt8]?, seizeUSB: Bool,
        featureInit2: [UInt8]? = nil,
        featureInit2Delay: Double = 0.15
    ) {
        self.productID         = productID
        self.name              = name
        self.parser            = parser
        self.maxX              = maxX
        self.maxY              = maxY
        self.maxPressure       = maxPressure
        self.buttonCount       = buttonCount
        self.hasTouchRing      = hasTouchRing
        self.hasEraser         = hasEraser
        self.featureInit       = featureInit
        self.seizeUSB          = seizeUSB
        self.featureInit2      = featureInit2
        self.featureInit2Delay = featureInit2Delay
    }
}

// MARK: - Registry

enum WacomDeviceRegistry {

    // MARK: Known devices

    static let knownDevices: [WacomDeviceSpec] = [

        // ── PenPartner / Graphire 1–4 ─────────────────────────────────────────
        // graphire parser: 8-byte Report ID 0x01, ≤511 pressure levels.
        .init(productID: 0x0003, name: "PenPartner",
              parser: .graphire, maxX:  5040, maxY:  3780, maxPressure:  255,
              buttonCount: 0, hasTouchRing: false, hasEraser: false,
              featureInit: nil, seizeUSB: false),
        .init(productID: 0x0004, name: "Graphire",
              parser: .graphire, maxX: 10206, maxY:  7422, maxPressure:  511,
              buttonCount: 2, hasTouchRing: false, hasEraser: true,
              featureInit: nil, seizeUSB: false),
        .init(productID: 0x0010, name: "Graphire 2 (4×5)",   // ⚠ estimated
              parser: .graphire, maxX: 10206, maxY:  7422, maxPressure:  511,
              buttonCount: 2, hasTouchRing: false, hasEraser: true,
              featureInit: nil, seizeUSB: false),
        .init(productID: 0x0011, name: "Graphire 2 (5×7)",   // ⚠ estimated
              parser: .graphire, maxX: 13918, maxY: 10206, maxPressure:  511,
              buttonCount: 2, hasTouchRing: false, hasEraser: true,
              featureInit: nil, seizeUSB: false),
        .init(productID: 0x0013, name: "Graphire 3 (4×5)",   // ⚠ estimated
              parser: .graphire, maxX: 10208, maxY:  7424, maxPressure:  511,
              buttonCount: 2, hasTouchRing: false, hasEraser: true,
              featureInit: nil, seizeUSB: false),
        .init(productID: 0x0014, name: "Graphire 3 (6×8)",   // ⚠ estimated
              parser: .graphire, maxX: 16704, maxY: 12064, maxPressure:  511,
              buttonCount: 2, hasTouchRing: false, hasEraser: true,
              featureInit: nil, seizeUSB: false),
        .init(productID: 0x0015, name: "Graphire 4 (4×5)",   // ⚠ estimated
              parser: .graphire, maxX: 10208, maxY:  7424, maxPressure:  511,
              buttonCount: 2, hasTouchRing: false, hasEraser: true,
              featureInit: nil, seizeUSB: false),
        .init(productID: 0x0016, name: "Graphire 4 (6×8)",   // ⚠ estimated
              parser: .graphire, maxX: 16704, maxY: 12064, maxPressure:  511,
              buttonCount: 2, hasTouchRing: false, hasEraser: true,
              featureInit: nil, seizeUSB: false),
        .init(productID: 0x0017, name: "Bamboo Fun (MTE-450)", // ⚠ estimated
              parser: .graphire, maxX: 14760, maxY:  9225, maxPressure:  511,
              buttonCount: 4, hasTouchRing: false, hasEraser: true,
              featureInit: nil, seizeUSB: false),

        // ── Volito / PenStation ───────────────────────────────────────────────
        .init(productID: 0x0060, name: "Volito",              // ⚠ estimated
              parser: .graphire, maxX:  5104, maxY:  3712, maxPressure:  511,
              buttonCount: 0, hasTouchRing: false, hasEraser: false,
              featureInit: nil, seizeUSB: false),
        .init(productID: 0x0061, name: "PenStation",          // ⚠ estimated
              parser: .graphire, maxX:  3540, maxY:  2468, maxPressure:  511,
              buttonCount: 0, hasTouchRing: false, hasEraser: false,
              featureInit: nil, seizeUSB: false),
        .init(productID: 0x0062, name: "Volito 2",            // ⚠ estimated
              parser: .graphire, maxX:  5104, maxY:  3712, maxPressure:  511,
              buttonCount: 0, hasTouchRing: false, hasEraser: false,
              featureInit: nil, seizeUSB: false),
        .init(productID: 0x0065, name: "Bamboo One (CTF-430)", // ⚠ estimated
              parser: .graphire, maxX: 14760, maxY:  9225, maxPressure:  511,
              buttonCount: 0, hasTouchRing: false, hasEraser: true,
              featureInit: nil, seizeUSB: false),

        // ── Cintiq 21UX first-gen ─────────────────────────────────────────────
        .init(productID: 0x003F, name: "Cintiq 21UX (DTZ-2100)", // ⚠ estimated
              parser: .graphire, maxX: 87200, maxY: 65600, maxPressure: 1023,
              buttonCount: 0, hasTouchRing: false, hasEraser: true,
              featureInit: nil, seizeUSB: true),

        // ── Intuos 1 (1998–2002) — intuosV1 parser ───────────────────────────
        // 10-byte reports, BE16, 1024-level pressure (10-bit).
        .init(productID: 0x0020, name: "Intuos 4×5",          // ⚠ estimated
              parser: .intuosV1, maxX: 12700, maxY: 10600, maxPressure: 1023,
              buttonCount: 0, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),
        .init(productID: 0x0021, name: "Intuos 6×8",          // ⚠ estimated
              parser: .intuosV1, maxX: 20320, maxY: 16240, maxPressure: 1023,
              buttonCount: 0, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),
        .init(productID: 0x0022, name: "Intuos 9×12",         // ⚠ estimated
              parser: .intuosV1, maxX: 30480, maxY: 24060, maxPressure: 1023,
              buttonCount: 0, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),
        .init(productID: 0x0023, name: "Intuos 12×12",        // ⚠ estimated
              parser: .intuosV1, maxX: 30480, maxY: 30480, maxPressure: 1023,
              buttonCount: 0, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),
        .init(productID: 0x0024, name: "Intuos 12×18",        // ⚠ estimated
              parser: .intuosV1, maxX: 45720, maxY: 30480, maxPressure: 1023,
              buttonCount: 0, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),

        // ── Intuos 2 (2002–2004) — intuosV1 parser ───────────────────────────
        .init(productID: 0x0041, name: "Intuos 2 (4×5)",      // ⚠ estimated
              parser: .intuosV1, maxX: 12700, maxY: 10600, maxPressure: 1023,
              buttonCount: 0, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),
        .init(productID: 0x0042, name: "Intuos 2 (6×8)",      // ⚠ estimated
              parser: .intuosV1, maxX: 20320, maxY: 16240, maxPressure: 1023,
              buttonCount: 0, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),
        .init(productID: 0x0043, name: "Intuos 2 (9×12)",     // ⚠ estimated
              parser: .intuosV1, maxX: 30480, maxY: 24060, maxPressure: 1023,
              buttonCount: 0, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),
        .init(productID: 0x0044, name: "Intuos 2 (12×12)",    // ⚠ estimated
              parser: .intuosV1, maxX: 30480, maxY: 30480, maxPressure: 1023,
              buttonCount: 0, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),
        .init(productID: 0x0045, name: "Intuos 2 (12×18)",    // ⚠ estimated
              parser: .intuosV1, maxX: 45720, maxY: 30480, maxPressure: 1023,
              buttonCount: 0, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),

        // ── Intuos3 (PTZ-xxx, 2003–2006) — intuos3 parser ───────────────────
        // Status byte layout differs from Intuos5: bit 6 (0x40) is proximity.
        // Aux reports: 0x03 (8 keys in byte 4) and 0x0C (4+4 split).
        // Two-stage feature init: [0x02,0x02] immediately, [0x04,0x00] after 150 ms.
        // PTZ-631W (0x00B5) confirmed live; remaining entries ⚠ estimated but
        // the two-stage init and proximity bit are common to the whole PTZ family.
        .init(productID: 0x00B0, name: "Intuos3 4×5 (PTZ-431)",    // ⚠ estimated
              parser: .intuos3, maxX: 25400, maxY: 20320, maxPressure: 1023,
              buttonCount: 4, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false,
              featureInit2: [0x04, 0x00]),
        .init(productID: 0x00B1, name: "Intuos3 6×8 (PTZ-631)",    // ⚠ estimated
              parser: .intuos3, maxX: 40640, maxY: 30480, maxPressure: 1023,
              buttonCount: 8, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false,
              featureInit2: [0x04, 0x00]),
        .init(productID: 0x00B2, name: "Intuos3 9×12 (PTZ-930)",   // ⚠ estimated
              parser: .intuos3, maxX: 60960, maxY: 45720, maxPressure: 1023,
              buttonCount: 8, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false,
              featureInit2: [0x04, 0x00]),
        .init(productID: 0x00B3, name: "Intuos3 12×12 (PTZ-1231)", // ⚠ estimated
              parser: .intuos3, maxX: 60960, maxY: 60960, maxPressure: 1023,
              buttonCount: 8, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false,
              featureInit2: [0x04, 0x00]),
        .init(productID: 0x00B4, name: "Intuos3 12×19 (PTZ-1231W)",// ⚠ estimated
              parser: .intuos3, maxX: 97536, maxY: 60960, maxPressure: 1023,
              buttonCount: 8, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false,
              featureInit2: [0x04, 0x00]),
        .init(productID: 0x00B5, name: "Intuos3 WS (PTZ-631W)",    // ✓ confirmed live
              parser: .intuos3, maxX: 54204, maxY: 31750, maxPressure: 2046,
              buttonCount: 8, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false,
              featureInit2: [0x04, 0x00]),
        .init(productID: 0x00B7, name: "Intuos3 4×6 (PTZ-431W)",   // ⚠ estimated
              parser: .intuos3, maxX: 31496, maxY: 19685, maxPressure: 1023,
              buttonCount: 4, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false,
              featureInit2: [0x04, 0x00]),

        // ── Intuos4 (PTK-xxx, 2009–2012) — intuosV1 parser ───────────────────
        // OLED display on each express key; 2048-level pressure (11-bit).
        .init(productID: 0x00B8, name: "Intuos4 S (PTK-440)",      // ⚠ estimated
              parser: .intuosV1, maxX: 31496, maxY: 19685, maxPressure: 2047,
              buttonCount: 8, hasTouchRing: true, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),
        .init(productID: 0x00B9, name: "Intuos4 M (PTK-640)",      // ⚠ estimated
              parser: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
              buttonCount: 8, hasTouchRing: true, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),
        .init(productID: 0x00BA, name: "Intuos4 L (PTK-840)",      // ⚠ estimated
              parser: .intuosV1, maxX: 63494, maxY: 39370, maxPressure: 2047,
              buttonCount: 8, hasTouchRing: true, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),
        .init(productID: 0x00BB, name: "Intuos4 XL (PTK-1240)",    // ⚠ estimated
              parser: .intuosV1, maxX: 97536, maxY: 60960, maxPressure: 2047,
              buttonCount: 8, hasTouchRing: true, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),
        .init(productID: 0x00BC, name: "Intuos4 WL (PTK-540WL)",   // ⚠ estimated
              parser: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
              buttonCount: 8, hasTouchRing: true, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),

        // ── Intuos5 first-gen (PTH-x50, 2012) — intuosV1 parser ──────────────
        .init(productID: 0x0026, name: "Intuos5 S (PTH-450)",      // ⚠ estimated
              parser: .intuosV1, maxX: 31496, maxY: 19685, maxPressure: 2047,
              buttonCount: 8, hasTouchRing: true, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),
        .init(productID: 0x0027, name: "Intuos5 M (PTH-650)",      // ⚠ estimated
              parser: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
              buttonCount: 8, hasTouchRing: true, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),
        .init(productID: 0x0028, name: "Intuos5 L (PTH-850)",      // ⚠ estimated
              parser: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
              buttonCount: 8, hasTouchRing: true, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),

        // ── Intuos Pro first-gen (PTH-x51, 2013) — intuosV1 parser ───────────
        // Renamed from "Intuos5" to "Intuos Pro"; same HID format.
        .init(productID: 0x0314, name: "Intuos Pro S (PTH-451)",   // ⚠ estimated
              parser: .intuosV1, maxX: 31496, maxY: 19685, maxPressure: 2047,
              buttonCount: 8, hasTouchRing: true, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),
        .init(productID: 0x0316, name: "Intuos Pro M (PTH-651)",   // ⚠ estimated
              parser: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 2047,
              buttonCount: 8, hasTouchRing: true, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),
        .init(productID: 0x0317, name: "Intuos Pro L (PTH-851)",   // ✓ confirmed live
              parser: .intuosV1, maxX: 44704, maxY: 27940, maxPressure: 1023,
              buttonCount: 8, hasTouchRing: true, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: false),

        // ── Intuos Pro second-gen (PTH-x60/x80, 2017–present) — intuosV2 ─────
        // 192-byte reports, LE24 coordinates, 8192-level pressure (13-bit).
        // Also supports BLE HOGP (Report IDs 0x01 pen, 0x03 pad).
        // seizeUSB=true: standard-HID-mouse interface must be seized.
        .init(productID: 0x0352, name: "Intuos Pro S (PTH-460)",   // ⚠ estimated
              parser: .intuosV2, maxX: 31496, maxY: 19685, maxPressure: 8191,
              buttonCount: 8, hasTouchRing: true, hasEraser: true,
              featureInit: nil, seizeUSB: true),
        .init(productID: 0x0357, name: "Intuos Pro M (PTH-660)",   // ✓ confirmed live
              parser: .intuosV2, maxX: 44800, maxY: 29600, maxPressure: 8191,
              buttonCount: 8, hasTouchRing: true, hasEraser: true,
              featureInit: nil, seizeUSB: true),
        .init(productID: 0x0358, name: "Intuos Pro L (PTH-860)",   // ✓ confirmed live
              parser: .intuosV2, maxX: 62200, maxY: 43200, maxPressure: 8191,
              buttonCount: 8, hasTouchRing: true, hasEraser: true,
              featureInit: nil, seizeUSB: true),

        // ── Bamboo / CTL consumer line — bamboo parser ────────────────────────
        // 20-byte Report ID 0x10. Decoder not yet implemented.
        // Entries present for name resolution and future routing.
        .init(productID: 0x00D0, name: "Bamboo Touch (CTT-460)",   // ⚠ estimated
              parser: .bamboo, maxX: 14720, maxY:  9200, maxPressure:    0,
              buttonCount: 0, hasTouchRing: false, hasEraser: false,
              featureInit: nil, seizeUSB: false),
        .init(productID: 0x00D1, name: "Bamboo Pen & Touch (CTH-460)", // ⚠ estimated
              parser: .bamboo, maxX: 14720, maxY:  9200, maxPressure: 1023,
              buttonCount: 4, hasTouchRing: false, hasEraser: false,
              featureInit: nil, seizeUSB: false),
        .init(productID: 0x00D4, name: "Bamboo Capture (CTH-470)", // ⚠ estimated
              parser: .bamboo, maxX: 14720, maxY:  9200, maxPressure: 1023,
              buttonCount: 4, hasTouchRing: false, hasEraser: false,
              featureInit: nil, seizeUSB: false),
        .init(productID: 0x00D6, name: "Bamboo Pen (CTL-460)",     // ⚠ estimated
              parser: .bamboo, maxX: 14720, maxY:  9200, maxPressure: 1023,
              buttonCount: 2, hasTouchRing: false, hasEraser: false,
              featureInit: nil, seizeUSB: false),
        .init(productID: 0x00D7, name: "Bamboo Pen (CTL-660)",     // ⚠ estimated
              parser: .bamboo, maxX: 21648, maxY: 13530, maxPressure: 1023,
              buttonCount: 2, hasTouchRing: false, hasEraser: false,
              featureInit: nil, seizeUSB: false),
        .init(productID: 0x00DA, name: "Bamboo Pen & Touch 2 (CTH-461)", // ⚠ estimated
              parser: .bamboo, maxX: 14720, maxY:  9200, maxPressure: 1023,
              buttonCount: 4, hasTouchRing: false, hasEraser: false,
              featureInit: nil, seizeUSB: false),
        .init(productID: 0x00DB, name: "Bamboo Connect (CTL-470)", // ⚠ estimated
              parser: .bamboo, maxX: 14720, maxY:  9200, maxPressure: 1023,
              buttonCount: 2, hasTouchRing: false, hasEraser: false,
              featureInit: nil, seizeUSB: false),

        // ── Cintiq pen-display line — intuosV1 parser ────────────────────────
        // seizeUSB=true: Cintiq pen-displays appear as USB HID devices and
        // require seizure to prevent kernel handling of their pen interface.
        .init(productID: 0x00C0, name: "Cintiq 20WSX",             // ⚠ estimated
              parser: .intuosV1, maxX: 86680, maxY: 54180, maxPressure: 1023,
              buttonCount: 4, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: true),
        .init(productID: 0x00C4, name: "Cintiq 13HD (DTK-1300)",   // ⚠ estimated
              parser: .intuosV1, maxX: 59152, maxY: 33448, maxPressure: 2047,
              buttonCount: 0, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: true),
        .init(productID: 0x00C6, name: "Cintiq 12WX",              // ⚠ estimated
              parser: .intuosV1, maxX: 53020, maxY: 33440, maxPressure: 1023,
              buttonCount: 8, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: true),
        .init(productID: 0x00CC, name: "Cintiq 21UX (DTZ-2100)",   // ⚠ estimated
              parser: .intuosV1, maxX: 87200, maxY: 65600, maxPressure: 1023,
              buttonCount: 8, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: true),
        .init(productID: 0x00F4, name: "Cintiq 24HD (DTK-2400)",   // ✓ confirmed live
              parser: .intuosV1, maxX: 104480, maxY: 65600, maxPressure: 2047,
              buttonCount: 8, hasTouchRing: true, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: true),
        .init(productID: 0x00F8, name: "Cintiq 24HD Touch (DTH-2400)", // ⚠ estimated
              parser: .intuosV1, maxX: 104480, maxY: 65600, maxPressure: 2047,
              buttonCount: 8, hasTouchRing: true, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: true),
        .init(productID: 0x00FA, name: "Cintiq 22HD (DTK-2200)",   // ⚠ estimated
              parser: .intuosV1, maxX:  95840, maxY: 54090, maxPressure: 2047,
              buttonCount: 8, hasTouchRing: true, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: true),
        .init(productID: 0x00FB, name: "Cintiq 21UX 2 (DTZ-2100B)", // ⚠ estimated
              parser: .intuosV1, maxX:  87200, maxY: 65600, maxPressure: 1023,
              buttonCount: 8, hasTouchRing: false, hasEraser: true,
              featureInit: [0x02, 0x02], seizeUSB: true),

        // ── Wireless dongle ───────────────────────────────────────────────────
        // ACK-40401 RF dongle (PID 0x0084) presents the same HID interfaces as
        // the paired tablet.  WacomGenericDevice auto-detects the report family.
        // Report 0x80 carries wireless status (byte[1]: 0x02=active, 0x05=lost,
        // 0x06=battery low).  maxX/maxY/maxPressure are 0 — queried via HID
        // descriptor on first connection by WacomGenericDevice.querySpec().
        .init(productID: 0x0084, name: "ACK-40401 Wireless Dongle",
              parser: .intuosV1, maxX: 0, maxY: 0, maxPressure: 0,
              buttonCount: 0, hasTouchRing: false, hasEraser: true,
              featureInit: nil, seizeUSB: false),
    ]

    // MARK: Lookups

    /// Returns the spec for `productID`, or nil if unrecognised.
    static func spec(for productID: Int) -> WacomDeviceSpec? {
        knownDevices.first { $0.productID == productID }
    }

    /// Human-readable display name for any Wacom product.
    /// Returns "Wacom 0xXXXX" for PIDs not yet in the table.
    static func deviceName(forProductID productID: Int) -> String {
        spec(for: productID)?.name
            ?? "Wacom 0x\(String(productID, radix: 16, uppercase: true))"
    }

    /// True when a fully-tested decoder exists for this device.
    /// IntuosV1 and IntuosV2 are live; graphire and bamboo are stubs for
    /// future Phase 2 decoder work.
    static func hasLiveDecoder(for productID: Int) -> Bool {
        guard let s = spec(for: productID) else { return false }
        return s.parser == .intuosV1 || s.parser == .intuosV2 || s.parser == .intuos3
    }
}
