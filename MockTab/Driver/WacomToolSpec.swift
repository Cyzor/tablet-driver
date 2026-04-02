// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026  This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab.  If not, see <https://www.gnu.org/licenses/>.

import Foundation

// MARK: - Tool Type

/// Categories of tools Wacom devices can report.
enum WacomToolType: String, Codable, CaseIterable {
    case stylus = "Stylus"
    case eraser = "Eraser"
    case mouse = "Mouse"
    case touch = "Touch"
    case airbrush = "Airbrush"
    case artPen = "Art Pen"
    case inkingPen = "Inking Pen"
}

// MARK: - Tool Specification

/// Complete specification for a Wacom tool type.
/// Derived from OpenTabletDriver conventions and Linux input-wacom driver.
struct WacomToolSpec: Codable, Identifiable, Equatable {
    /// The 16-bit Wacom tool code (e.g., 0x0802 for Grip Pen).
    let toolCode: UInt16

    /// Human-readable name (e.g., "Grip Pen", "Pro Pen 2").
    let name: String

    /// Category of tool.
    let toolType: WacomToolType

    /// Number of side buttons on the pen body.
    let buttonCount: Int

    /// Maximum pressure levels (nil = device-dependent).
    let maxPressure: Int?

    /// True if this tool reports tilt data.
    let hasTilt: Bool

    /// True if this tool supports rotation (twist) data.
    let hasRotation: Bool

    /// True if this tool has a scroll wheel (mice only).
    let hasWheel: Bool

    /// True if this tool has an eraser counterpart.
    let hasEraserVariant: Bool

    /// Tool code for the eraser variant (if different from toolCode).
    let eraserToolCode: UInt16?

    /// Device families this tool is commonly shipped with.
    /// Empty means universal.
    let supportedFamilies: [String]

    /// Unique identifier (hex string matching toolCode).
    var id: String { String(format: "0x%04X", toolCode) }

    /// Returns the tool code with eraser bit set (bit 3 of low byte).
    var eraserCode: UInt16 { toolCode | 0x0008 }

    /// Returns true if this is an eraser tool.
    var isEraser: Bool { toolType == .eraser }

    /// Returns true if this is a mouse/cursor tool.
    var isMouse: Bool { toolType == .mouse }

    /// Returns the base tool code without eraser bit.
    var baseCode: UInt16 { toolCode & ~UInt16(0x0008) }

    /// Returns true if this tool is compatible with the given device family.
    /// Empty supportedFamilies means universal compatibility.
    func isSupported(onFamily family: String) -> Bool {
        if supportedFamilies.isEmpty { return true }
        return supportedFamilies.contains(family)
    }

    /// Returns the tool's capabilities adjusted for the given device family.
    /// If the tool is unsupported, returns a fallback with limited features.
    func capabilities(forFamily family: String) -> ToolCapabilities {
        let supported = isSupported(onFamily: family)
        return ToolCapabilities(
            isSupported: supported,
            hasPressure: supported && (maxPressure ?? 0) > 0,
            hasTilt: supported && hasTilt,
            hasRotation: supported && hasRotation,
            hasWheel: supported && hasWheel,
            // If unsupported, fall back to basic position + buttons only
            maxPressure: supported ? (maxPressure ?? 2047) : 0
        )
    }
}

/// Capabilities of a tool on a specific device family.
/// Returned by WacomToolSpec.capabilities(forFamily:) to indicate which
/// features are available when a tool is used with an incompatible tablet.
struct ToolCapabilities {
    /// True if this tool is officially supported on this device family.
    let isSupported: Bool
    /// True if pressure data is available.
    let hasPressure: Bool
    /// True if tilt data is available.
    let hasTilt: Bool
    /// True if rotation data is available (Art Pen).
    let hasRotation: Bool
    /// True if the scroll wheel is available.
    let hasWheel: Bool
    /// Maximum pressure value (0 if pressure unsupported).
    let maxPressure: Int
}

// MARK: - Tool Catalog

/// Registry of all known Wacom tool specifications.
/// Keys are tool codes (UInt16).
enum WacomToolCatalog {

    /// All known tool specifications, keyed by tool code.
    static let allTools: [UInt16: WacomToolSpec] = {
        var catalog: [UInt16: WacomToolSpec] = [:]

        // MARK: - Intuos Pro / Intuos5 Series (0x08xx family)

        // Grip Pen (standard Intuos Pro pen)
        catalog[0x0802] = WacomToolSpec(
            toolCode: 0x0802,
            name: "Grip Pen",
            toolType: .stylus,
            buttonCount: 2,
            maxPressure: nil,
            hasTilt: true,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: true,
            eraserToolCode: 0x080A,
            supportedFamilies: ["intuos3", "intuos4", "intuos5", "intuosProGen1"]
        )

        // Grip Pen Eraser
        catalog[0x080A] = WacomToolSpec(
            toolCode: 0x080A,
            name: "Grip Pen (Eraser)",
            toolType: .eraser,
            buttonCount: 2,
            maxPressure: nil,
            hasTilt: true,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos3", "intuos4", "intuos5", "intuosProGen1"]
        )

        // Marker Pen (Intuos4 — rotation-capable; listed in kernel is_art_pen for 0x804.
        // Likely an OEM or limited-market variant; the primary Intuos4 Art Pen is 0x10804.)
        catalog[0x0804] = WacomToolSpec(
            toolCode: 0x0804,
            name: "Marker Pen",
            toolType: .artPen,
            buttonCount: 2,
            maxPressure: nil,
            hasTilt: true,
            hasRotation: true,
            hasWheel: false,
            hasEraserVariant: true,
            eraserToolCode: 0x080C,
            supportedFamilies: ["intuos4"]
        )

        // Marker Pen Eraser
        catalog[0x080C] = WacomToolSpec(
            toolCode: 0x080C,
            name: "Marker Pen (Eraser)",
            toolType: .eraser,
            buttonCount: 2,
            maxPressure: nil,
            hasTilt: true,
            hasRotation: true,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos4"]
        )

        // Art Pen variant (toolCode 0x1108 — confirmed from live BT capture 2026-04-02).
        // Reports over Bluetooth Classic as Art Pen; rotation available over USB only.
        // Bit3 of toolCode (0x0008) is set, but this pen is NOT an eraser.
        catalog[0x1108] = WacomToolSpec(
            toolCode: 0x1108,
            name: "Art Pen",
            toolType: .artPen,
            buttonCount: 2,
            maxPressure: nil,
            hasTilt: true,
            hasRotation: true,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuosProGen2"]
        )

        // Standard pen for Cintiq 24HD (DTK-2400) - toolCode 0x1802
        // This is the default pen that ships with the DTK-2400
        catalog[0x1802] = WacomToolSpec(
            toolCode: 0x1802,
            name: "Intuos4 Grip Pen",
            toolType: .stylus,
            buttonCount: 2,
            maxPressure: 2047,
            hasTilt: true,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: true,
            eraserToolCode: 0x180A,
            supportedFamilies: ["cintiq", "intuos4", "intuos5"]
        )

        // Intuos4 Grip Pen Eraser (0x180A)
        catalog[0x180A] = WacomToolSpec(
            toolCode: 0x180A,
            name: "Intuos4 Grip Pen (Eraser)",
            toolType: .eraser,
            buttonCount: 2,
            maxPressure: 2047,
            hasTilt: true,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["cintiq", "intuos4", "intuos5"]
        )

        // Art Pen extended ID (0x1804) - appears on Cintiq 24HD (DTK-2400)
        // This is the Art Pen when used with older IntuosV1 devices
        catalog[0x1804] = WacomToolSpec(
            toolCode: 0x1804,
            name: "Art Pen",
            toolType: .artPen,
            buttonCount: 2,
            maxPressure: 2047,
            hasTilt: true,
            hasRotation: true,
            hasWheel: false,
            hasEraserVariant: true,
            eraserToolCode: 0x180C,
            supportedFamilies: ["cintiq", "intuos4", "intuos5"]
        )

        // Art Pen 0x1804 eraser
        catalog[0x180C] = WacomToolSpec(
            toolCode: 0x180C,
            name: "Art Pen (Eraser)",
            toolType: .eraser,
            buttonCount: 2,
            maxPressure: 2047,
            hasTilt: true,
            hasRotation: true,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["cintiq", "intuos4", "intuos5"]
        )

        // Intuos Mouse (cordless)
        catalog[0x0806] = WacomToolSpec(
            toolCode: 0x0806,
            name: "Intuos Mouse",
            toolType: .mouse,
            buttonCount: 2,
            maxPressure: nil,
            hasTilt: false,
            hasRotation: false,
            hasWheel: true,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos4", "intuos5"]
        )

        // MARK: - Intuos Pro Gen2 / IntuosV2 Series (0x08xx extended)

        // Pro Pen 2 (PTH-660, PTH-860)
        catalog[0x0832] = WacomToolSpec(
            toolCode: 0x0832,
            name: "Pro Pen 2",
            toolType: .stylus,
            buttonCount: 2,
            maxPressure: 8191,
            hasTilt: true,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: true,
            eraserToolCode: 0x083A,
            supportedFamilies: ["intuosProGen2"]
        )

        // Pro Pen 2 Eraser
        catalog[0x083A] = WacomToolSpec(
            toolCode: 0x083A,
            name: "Pro Pen 2 (Eraser)",
            toolType: .eraser,
            buttonCount: 2,
            maxPressure: 8191,
            hasTilt: true,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuosProGen2"]
        )

        // Pro Pen 3 (PTH-860)
        catalog[0x0842] = WacomToolSpec(
            toolCode: 0x0842,
            name: "Pro Pen 3",
            toolType: .stylus,
            buttonCount: 2,
            maxPressure: 8191,
            hasTilt: true,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: true,
            eraserToolCode: 0x084A,
            supportedFamilies: ["intuosProGen2"]
        )

        // Pro Pen 3 Eraser
        catalog[0x084A] = WacomToolSpec(
            toolCode: 0x084A,
            name: "Pro Pen 3 (Eraser)",
            toolType: .eraser,
            buttonCount: 2,
            maxPressure: 8191,
            hasTilt: true,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuosProGen2"]
        )

        // Pen 4K (CTL-4100, CTL-6100 series)
        catalog[0x0852] = WacomToolSpec(
            toolCode: 0x0852,
            name: "Pen 4K",
            toolType: .stylus,
            buttonCount: 2,
            maxPressure: 4095,
            hasTilt: true,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: true,
            eraserToolCode: 0x085A,
            supportedFamilies: ["bamboo2", "intuosProGen2"]
        )

        // Pen 4K Eraser
        catalog[0x085A] = WacomToolSpec(
            toolCode: 0x085A,
            name: "Pen 4K (Eraser)",
            toolType: .eraser,
            buttonCount: 2,
            maxPressure: 4095,
            hasTilt: true,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["bamboo2", "intuosProGen2"]
        )

        // Pen 5K (Pro Pen 2 equivalent for older devices)
        catalog[0x0862] = WacomToolSpec(
            toolCode: 0x0862,
            name: "Pen 5K",
            toolType: .stylus,
            buttonCount: 2,
            maxPressure: 2047,
            hasTilt: true,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: true,
            eraserToolCode: 0x086A,
            supportedFamilies: ["intuosProGen1"]
        )

        // Pen 5K Eraser
        catalog[0x086A] = WacomToolSpec(
            toolCode: 0x086A,
            name: "Pen 5K (Eraser)",
            toolType: .eraser,
            buttonCount: 2,
            maxPressure: 2047,
            hasTilt: true,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuosProGen1"]
        )

        // MARK: - Art Pen (rotatable, ABS_Z barrel)

        // Art Marker / Art Pen (Intuos3 ZP-600 + Intuos4 — same code, same kernel is_art_pen flag)
        catalog[0x0885] = WacomToolSpec(
            toolCode: 0x0885,
            name: "Art Pen",
            toolType: .artPen,
            buttonCount: 2,
            maxPressure: 1023,
            hasTilt: true,
            hasRotation: true,
            hasWheel: false,
            hasEraserVariant: true,
            eraserToolCode: 0x088D,
            supportedFamilies: ["intuos3", "intuos4"]
        )

        // Art Pen Eraser
        catalog[0x088D] = WacomToolSpec(
            toolCode: 0x088D,
            name: "Art Pen (Eraser)",
            toolType: .eraser,
            buttonCount: 2,
            maxPressure: 1023,
            hasTilt: true,
            hasRotation: true,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos3", "intuos4"]
        )

        // NOTE: The Intuos4 Art Pen KP-701E-2 reports as 0x10804 (extended ID assembled from
        // multiple nibbles by the kernel's wacom_intuos_id_mangle). This value exceeds UInt16.
        // toolCode must be widened to UInt32 to catalog these extended IDs — tracked separately.

        // Art Pen 2 (Intuos5/Intuos Pro gen1)
        catalog[0x0204] = WacomToolSpec(
            toolCode: 0x0204,
            name: "Art Pen 2",
            toolType: .artPen,
            buttonCount: 2,
            maxPressure: nil,
            hasTilt: true,
            hasRotation: true,
            hasWheel: false,
            hasEraserVariant: true,
            eraserToolCode: 0x020C,
            supportedFamilies: ["intuos5", "intuosProGen1"]
        )

        // Art Pen 2 Eraser
        catalog[0x020C] = WacomToolSpec(
            toolCode: 0x020C,
            name: "Art Pen 2 (Eraser)",
            toolType: .eraser,
            buttonCount: 2,
            maxPressure: nil,
            hasTilt: true,
            hasRotation: true,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos5", "intuosProGen1"]
        )

        // MARK: - Inking Pen

        // Inking Pen (fine tip)
        catalog[0x0812] = WacomToolSpec(
            toolCode: 0x0812,
            name: "Inking Pen",
            toolType: .inkingPen,
            buttonCount: 2,
            maxPressure: 1023,
            hasTilt: true,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: true,
            eraserToolCode: 0x081A,
            supportedFamilies: ["intuos4", "intuos5"]
        )

        // Inking Pen Eraser
        catalog[0x081A] = WacomToolSpec(
            toolCode: 0x081A,
            name: "Inking Pen (Eraser)",
            toolType: .eraser,
            buttonCount: 2,
            maxPressure: 1023,
            hasTilt: true,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos4", "intuos5"]
        )

        // MARK: - Intuos3 / Graphire Era (0x00xx family)

        // Intuos3 Grip Pen
        catalog[0x0002] = WacomToolSpec(
            toolCode: 0x0002,
            name: "Intuos3 Grip Pen",
            toolType: .stylus,
            buttonCount: 2,
            maxPressure: 1023,
            hasTilt: true,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: true,
            eraserToolCode: 0x000A,
            supportedFamilies: ["intuos3"]
        )

        // Intuos3 Grip Pen Eraser
        catalog[0x000A] = WacomToolSpec(
            toolCode: 0x000A,
            name: "Intuos3 Grip Pen (Eraser)",
            toolType: .eraser,
            buttonCount: 2,
            maxPressure: 1023,
            hasTilt: true,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos3"]
        )

        // Intuos3 Inking Pen
        catalog[0x0092] = WacomToolSpec(
            toolCode: 0x0092,
            name: "Intuos3 Inking Pen",
            toolType: .inkingPen,
            buttonCount: 2,
            maxPressure: 1023,
            hasTilt: true,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: true,
            eraserToolCode: 0x0093,
            supportedFamilies: ["intuos3"]
        )

        // Intuos3 Inking Pen Eraser
        catalog[0x0093] = WacomToolSpec(
            toolCode: 0x0093,
            name: "Intuos3 Inking Pen (Eraser)",
            toolType: .eraser,
            buttonCount: 2,
            maxPressure: 1023,
            hasTilt: true,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos3"]
        )

        // Intuos3 Airbrush
        catalog[0x0004] = WacomToolSpec(
            toolCode: 0x0004,
            name: "Intuos3 Airbrush",
            toolType: .airbrush,
            buttonCount: 2,
            maxPressure: 1023,
            hasTilt: true,
            hasRotation: false,
            hasWheel: true,
            hasEraserVariant: true,
            eraserToolCode: 0x000C,
            supportedFamilies: ["intuos3"]
        )

        // Intuos3 Airbrush Eraser
        catalog[0x000C] = WacomToolSpec(
            toolCode: 0x000C,
            name: "Intuos3 Airbrush (Eraser)",
            toolType: .eraser,
            buttonCount: 2,
            maxPressure: 1023,
            hasTilt: true,
            hasRotation: false,
            hasWheel: true,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos3"]
        )

        // MARK: - Mouse and Cursor Tools

        // Lens Cursor (Intuos 1/2 era and Intuos4 — kernel maps 0x006 → BTN_TOOL_LENS)
        catalog[0x0006] = WacomToolSpec(
            toolCode: 0x0006,
            name: "Lens Cursor",
            toolType: .mouse,
            buttonCount: 5,
            maxPressure: nil,
            hasTilt: false,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos4"]
        )

        // Cordless Mouse / 4D Mouse (Intuos 1/2 legacy — kernel 0x007/0x094/0x09C → BTN_TOOL_MOUSE)
        catalog[0x0007] = WacomToolSpec(
            toolCode: 0x0007,
            name: "Cordless Mouse",
            toolType: .mouse,
            buttonCount: 5,
            maxPressure: nil,
            hasTilt: false,
            hasRotation: false,
            hasWheel: true,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: []
        )

        // 4D Mouse Eraser (legacy)
        catalog[0x000E] = WacomToolSpec(
            toolCode: 0x000E,
            name: "4D Mouse (Eraser)",
            toolType: .eraser,
            buttonCount: 2,
            maxPressure: nil,
            hasTilt: false,
            hasRotation: false,
            hasWheel: true,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: []
        )

        // 2D Mouse (Intuos3 ZC-100)
        catalog[0x0017] = WacomToolSpec(
            toolCode: 0x0017,
            name: "2D Mouse",
            toolType: .mouse,
            buttonCount: 5,
            maxPressure: nil,
            hasTilt: false,
            hasRotation: false,
            hasWheel: true,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos3"]
        )

        // Intuos3 Mouse fallback (code from subtype-0x08 path — actual Intuos3 mouse sends 0x0017)
        catalog[0x0016] = WacomToolSpec(
            toolCode: 0x0016,
            name: "Mouse",
            toolType: .mouse,
            buttonCount: 2,
            maxPressure: nil,
            hasTilt: false,
            hasRotation: false,
            hasWheel: true,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos3"]
        )

        // Lens Cursor (Intuos3 — large tablets only: PTZ-930/1231)
        catalog[0x0097] = WacomToolSpec(
            toolCode: 0x0097,
            name: "Lens Cursor",
            toolType: .mouse,
            buttonCount: 5,
            maxPressure: nil,
            hasTilt: false,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos3"]
        )

        // Lens Cursor (unverified legacy code — kept for compatibility)
        catalog[0x0076] = WacomToolSpec(
            toolCode: 0x0076,
            name: "Lens Cursor",
            toolType: .mouse,
            buttonCount: 0,
            maxPressure: nil,
            hasTilt: false,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: []
        )

        // MARK: - Bamboo Series (CTL/CTH)

        // Bamboo Pen (CTL-460, CTH-460, etc.)
        catalog[0x0090] = WacomToolSpec(
            toolCode: 0x0090,
            name: "Bamboo Pen",
            toolType: .stylus,
            buttonCount: 2,
            maxPressure: 1023,
            hasTilt: false,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: true,
            eraserToolCode: 0x0098,
            supportedFamilies: ["bamboo", "bamboo2"]
        )

        // Bamboo Pen Eraser
        catalog[0x0098] = WacomToolSpec(
            toolCode: 0x0098,
            name: "Bamboo Pen (Eraser)",
            toolType: .eraser,
            buttonCount: 0,
            maxPressure: 1023,
            hasTilt: false,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["bamboo", "bamboo2"]
        )

        // Bamboo Touch (finger input on touch-capable devices)
        catalog[0x0094] = WacomToolSpec(
            toolCode: 0x0094,
            name: "Bamboo Touch",
            toolType: .touch,
            buttonCount: 0,
            maxPressure: nil,
            hasTilt: false,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["bamboo2"]
        )

        // MARK: - Graphire / PenPartner (legacy)

        // Graphire Pen
        catalog[0x0020] = WacomToolSpec(
            toolCode: 0x0020,
            name: "Graphire Pen",
            toolType: .stylus,
            buttonCount: 2,
            maxPressure: 511,
            hasTilt: false,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: true,
            eraserToolCode: 0x0028,
            supportedFamilies: ["graphire"]
        )

        // Graphire Pen Eraser
        catalog[0x0028] = WacomToolSpec(
            toolCode: 0x0028,
            name: "Graphire Pen (Eraser)",
            toolType: .eraser,
            buttonCount: 0,
            maxPressure: 511,
            hasTilt: false,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["graphire"]
        )

        // Graphire Mouse
        catalog[0x0024] = WacomToolSpec(
            toolCode: 0x0024,
            name: "Graphire Mouse",
            toolType: .mouse,
            buttonCount: 2,
            maxPressure: nil,
            hasTilt: false,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["graphire"]
        )

        // PenPartner Pen (no eraser)
        catalog[0x0010] = WacomToolSpec(
            toolCode: 0x0010,
            name: "PenPartner Pen",
            toolType: .stylus,
            buttonCount: 0,
            maxPressure: 255,
            hasTilt: false,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["graphire"]
        )

        // MARK: - Airbrush (Intuos3/4)

        // Airbrush (Intuos3 ZP-400E) — 1 side button, ABS_WHEEL fingerwheel
        catalog[0x0913] = WacomToolSpec(
            toolCode: 0x0913,
            name: "Airbrush",
            toolType: .airbrush,
            buttonCount: 1,
            maxPressure: 1023,
            hasTilt: true,
            hasRotation: false,
            hasWheel: true,
            hasEraserVariant: true,
            eraserToolCode: 0x091B,
            supportedFamilies: ["intuos3"]
        )

        catalog[0x091B] = WacomToolSpec(
            toolCode: 0x091B,
            name: "Airbrush (Eraser)",
            toolType: .eraser,
            buttonCount: 1,
            maxPressure: 1023,
            hasTilt: true,
            hasRotation: false,
            hasWheel: true,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos3"]
        )

        // Airbrush (Intuos4 KP-400E-2) — 1 side button, ABS_WHEEL fingerwheel
        catalog[0x0902] = WacomToolSpec(
            toolCode: 0x0902,
            name: "Airbrush",
            toolType: .airbrush,
            buttonCount: 1,
            maxPressure: nil,
            hasTilt: true,
            hasRotation: false,
            hasWheel: true,
            hasEraserVariant: true,
            eraserToolCode: 0x090A,
            supportedFamilies: ["intuos4", "intuos5"]
        )

        catalog[0x090A] = WacomToolSpec(
            toolCode: 0x090A,
            name: "Airbrush (Eraser)",
            toolType: .eraser,
            buttonCount: 1,
            maxPressure: nil,
            hasTilt: true,
            hasRotation: false,
            hasWheel: true,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos4", "intuos5"]
        )

        // NOTE: Intuos4 Airbrush KP-400E-2 extended ID (0x10902), Inking Pen KP-130E (0x12802),
        // Classic Pen KP-300E-2 (0x40802), and Intuos Pro gen2 reference codes (0x10100/0x10224/
        // 0x10184) all exceed UInt16 — they require toolCode widening to UInt32 (tracked separately).
        // The Intuos4 primary Airbrush uses 0x0902 (above); 0x10902 is a secondary extended variant.

        // MARK: - Intuos3/4 Specialty Pens

        // Inking Pen (Intuos3 ZP-130 — ink cartridge, no eraser end, pressure only)
        catalog[0x0801] = WacomToolSpec(
            toolCode: 0x0801,
            name: "Inking Pen",
            toolType: .inkingPen,
            buttonCount: 0,
            maxPressure: 1023,
            hasTilt: false,
            hasRotation: false,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos3"]
        )

        return catalog
    }()

    // MARK: - Lookup Methods

    /// Look up a tool specification by tool code.
    /// Returns nil if the tool code is unknown.
    static func spec(forToolCode toolCode: UInt16) -> WacomToolSpec? {
        return allTools[toolCode]
    }

    /// Look up a tool specification by tool code, handling eraser bit.
    /// If the tool code has the eraser bit set (0x0008), looks up the eraser variant.
    static func spec(forToolCodeRaw toolCode: UInt16) -> WacomToolSpec? {
        // First try exact match
        if let spec = allTools[toolCode] {
            return spec
        }
        // Try with eraser bit masked off
        return allTools[toolCode & ~UInt16(0x0008)]
    }

    /// Returns the human-readable name for a tool code.
    /// Falls back to descriptive names based on tool code patterns for unknown codes.
    static func name(forToolCode toolCode: UInt16) -> String {
        if let spec = spec(forToolCodeRaw: toolCode) {
            return spec.name
        }
        // Fallback heuristics for unknown codes - be more specific
        let highNibble = (toolCode >> 8) & 0xFF
        let lowByte = toolCode & 0xFF

        // Mouse tools (0x06, 0x07 family)
        if (toolCode & 0x000F) == 0x0006 {
            return "Mouse"
        }
        if (toolCode & 0x000F) == 0x0007 {
            return "Cordless Mouse"
        }

        // Eraser (bit 3 set)
        if (toolCode & 0x0008) != 0 {
            // Try to be more specific based on high nibble
            switch highNibble {
            case 0x08: return "Eraser (Intuos Pro)"
            case 0x00: return "Eraser (Intuos3)"
            case 0x09: return "Eraser (Bamboo)"
            case 0x02: return "Eraser (Graphire)"
            default: return "Eraser"
            }
        }

        // Stylus fallback - be specific about the family
        switch highNibble {
        case 0x08: return "Stylus (Intuos Pro)"
        case 0x00: return "Stylus (Intuos3)"
        case 0x09: return "Stylus (Bamboo)"
        case 0x02: return "Stylus (Graphire)"
        case 0x01: return "Stylus (PenPartner)"
        default: return "Stylus (0x\(String(format: "%04X", toolCode)))"
        }
    }

    /// Returns the tool type for a tool code.
    static func toolType(forToolCode toolCode: UInt16) -> WacomToolType {
        if let spec = spec(forToolCodeRaw: toolCode) {
            return spec.toolType
        }
        // Fallback heuristics
        if (toolCode & 0x000F) == 0x0006 {
            return .mouse
        }
        if (toolCode & 0x0008) != 0 {
            return .eraser
        }
        return .stylus
    }

    /// Returns true if the tool code represents a mouse/cursor.
    static func isMouse(toolCode: UInt16) -> Bool {
        if let spec = spec(forToolCodeRaw: toolCode) {
            return spec.isMouse
        }
        return (toolCode & 0x000F) == 0x0006
    }

    /// Returns true if the tool code represents an eraser.
    static func isEraser(toolCode: UInt16) -> Bool {
        if let spec = spec(forToolCodeRaw: toolCode) {
            return spec.isEraser
        }
        return (toolCode & 0x0008) != 0
    }

    /// Returns all tool specifications for a given device family.
    static func tools(forFamily family: String) -> [WacomToolSpec] {
        return allTools.values.filter { spec in
            spec.supportedFamilies.isEmpty || spec.supportedFamilies.contains(family)
        }
    }

    /// Returns tool capabilities for a tool code on a specific device family.
    /// If the tool is unknown, returns a default unsupported capability set.
    static func capabilities(forToolCode toolCode: UInt16, family: String) -> ToolCapabilities {
        if let spec = spec(forToolCodeRaw: toolCode) {
            return spec.capabilities(forFamily: family)
        }
        // Unknown tool - return basic unsupported capabilities
        return ToolCapabilities(
            isSupported: false,
            hasPressure: false,
            hasTilt: false,
            hasRotation: false,
            hasWheel: false,
            maxPressure: 0
        )
    }

    /// Returns all unique tool specifications.
    static var allUniqueTools: [WacomToolSpec] {
        return Array(allTools.values)
    }
}

// MARK: - ToolIdentity Extension

extension ToolIdentity {
    /// Creates a ToolIdentity from a WacomToolSpec.
    init(spec: WacomToolSpec, serial: UInt32) {
        self.serial = serial
        self.toolCode = spec.toolCode
        self.isEraser = spec.isEraser
        self.isMouse = spec.isMouse
    }

    /// Returns the corresponding WacomToolSpec if available.
    var toolSpec: WacomToolSpec? {
        return WacomToolCatalog.spec(forToolCodeRaw: toolCode)
    }

    /// Returns the human-readable name for this tool.
    var displayName: String {
        return WacomToolCatalog.name(forToolCode: toolCode)
    }
}
