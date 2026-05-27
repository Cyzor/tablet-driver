// SPDX-License-Identifier: MPL-2.0
//
// Vendor-neutral device recognition record.
//
// `WacomDeviceSpec` carries everything needed to actually decode Wacom HID
// reports.  This type is intentionally weaker: just enough metadata to *name*
// a device that the app doesn't yet have a decoder for, so the unknown-device
// UX can say "Huion H1060P — protocol unsupported, please submit a capture
// log" instead of "Unrecognized device, VID 0x256C, PID 0x006D."
//
// Data is bulk-imported from OpenTabletDriver's per-vendor JSON configs (see
// `tools/import_vendor_configs.py`).  No decoder dispatch is wired up — that
// is G1 work and depends on hardware.
//
// Same-PID-many-products is the norm for Huion (PIDs 0x006D / 0x006E each
// cover dozens of products, discriminated only by USB string descriptor #201
// matching a per-product regex).  Lookups therefore return `[Profile]`, not
// `Profile?` — callers showing the result to a human should surface every
// candidate.

import Foundation

public struct VendorDeviceProfile: Equatable {
    /// Vendor brand string as it appears in OTD ("Huion", "Xencelabs", "XP-Pen").
    public let vendor: String
    /// USB Vendor ID.
    public let vendorID: Int
    /// USB Product ID.  May be shared across many products from the same vendor.
    public let productID: Int
    /// Marketing name as published by OTD (e.g. "H1060P", "Pen Tablet Medium").
    public let productName: String
    /// Active-area width in millimetres, when published.
    public let activeWidthMM: Double?
    /// Active-area height in millimetres, when published.
    public let activeHeightMM: Double?
    /// Logical X coordinate maximum (device units), when published.
    public let maxX: Int?
    /// Logical Y coordinate maximum (device units), when published.
    public let maxY: Int?
    /// Pen pressure bit-depth ceiling, when published.
    public let maxPressure: Int?
    /// Number of pen barrel buttons, when published.
    public let penButtonCount: Int?
    /// Number of frame / express buttons, when published.
    public let auxButtonCount: Int?
    /// OTD's report-parser class name (e.g. "UCLogicTiltReportParser").
    /// Records OTD's parser hint verbatim — useful when picking a decoder
    /// family later without re-deriving from raw bytes.
    public let otdParser: String?
    /// Regex matched against USB string descriptor #201 (or similar) to
    /// disambiguate same-PID products.  Stored as a string — interpreting it
    /// is the caller's job, since the matching strategy is vendor-specific.
    public let productStringRegex: String?

    public init(
        vendor: String, vendorID: Int, productID: Int, productName: String,
        activeWidthMM: Double? = nil, activeHeightMM: Double? = nil,
        maxX: Int? = nil, maxY: Int? = nil, maxPressure: Int? = nil,
        penButtonCount: Int? = nil, auxButtonCount: Int? = nil,
        otdParser: String? = nil, productStringRegex: String? = nil
    ) {
        self.vendor = vendor
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.activeWidthMM = activeWidthMM
        self.activeHeightMM = activeHeightMM
        self.maxX = maxX
        self.maxY = maxY
        self.maxPressure = maxPressure
        self.penButtonCount = penButtonCount
        self.auxButtonCount = auxButtonCount
        self.otdParser = otdParser
        self.productStringRegex = productStringRegex
    }

    /// Lines per inch derived from `maxX`/`activeWidthMM`.  Returns nil unless
    /// both physical and logical dimensions are populated on both axes.
    /// Matches the shape of `WacomDeviceSpec.lpi` for cross-vendor consistency.
    public var lpi: (x: Double, y: Double)? {
        guard let w = activeWidthMM, w > 0,
              let h = activeHeightMM, h > 0,
              let mx = maxX, let my = maxY else { return nil }
        return (Double(mx) / w * 25.4, Double(my) / h * 25.4)
    }
}
