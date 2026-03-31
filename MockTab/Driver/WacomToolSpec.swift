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
            supportedFamilies: ["intuos5", "intuos4", "intuosProGen1"]
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
            supportedFamilies: ["intuos5", "intuos4", "intuosProGen1"]
        )

        // Airbrush
        catalog[0x0804] = WacomToolSpec(
            toolCode: 0x0804,
            name: "Airbrush",
            toolType: .airbrush,
            buttonCount: 2,
            maxPressure: nil,
            hasTilt: true,
            hasRotation: false,
            hasWheel: true,
            hasEraserVariant: true,
            eraserToolCode: 0x080C,
            supportedFamilies: ["intuos4", "intuos5"]
        )

        // Airbrush Eraser
        catalog[0x080C] = WacomToolSpec(
            toolCode: 0x080C,
            name: "Airbrush (Eraser)",
            toolType: .eraser,
            buttonCount: 2,
            maxPressure: nil,
            hasTilt: true,
            hasRotation: false,
            hasWheel: true,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos4", "intuos5"]
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

        // MARK: - Art Pen / Marker Pen (rotatable)

        // Art Pen (rotatable, standard)
        catalog[0x07A0] = WacomToolSpec(
            toolCode: 0x07A0,
            name: "Art Pen",
            toolType: .artPen,
            buttonCount: 2,
            maxPressure: 1023,
            hasTilt: true,
            hasRotation: true,
            hasWheel: false,
            hasEraserVariant: true,
            eraserToolCode: 0x07A1,
            supportedFamilies: ["intuos4", "intuos5", "intuosProGen1"]
        )

        // Art Pen Eraser
        catalog[0x07A1] = WacomToolSpec(
            toolCode: 0x07A1,
            name: "Art Pen (Eraser)",
            toolType: .eraser,
            buttonCount: 2,
            maxPressure: 1023,
            hasTilt: true,
            hasRotation: true,
            hasWheel: false,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos4", "intuos5", "intuosProGen1"]
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

        // MARK: - Mouse Tools (0x00x6 / 0x001x family)

        // 4D Mouse (Intuos series)
        catalog[0x0006] = WacomToolSpec(
            toolCode: 0x0006,
            name: "4D Mouse",
            toolType: .mouse,
            buttonCount: 2,
            maxPressure: nil,
            hasTilt: false,
            hasRotation: false,
            hasWheel: true,
            hasEraserVariant: false,
            eraserToolCode: nil,
            supportedFamilies: ["intuos3", "intuos4", "intuos5"]
        )

        // 4D Mouse Eraser (rare)
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
            supportedFamilies: ["intuos3"]
        )

        // Intuos3 Mouse (older)
        catalog[0x0016] = WacomToolSpec(
            toolCode: 0x0016,
            name: "Intuos3 Mouse",
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

        // Lens Cursor (no buttons, used for precise positioning)
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
            supportedFamilies: ["intuos3", "intuos4", "intuos5"]
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
    /// Falls back to "Stylus", "Eraser", or "Mouse" for unknown codes.
    static func name(forToolCode toolCode: UInt16) -> String {
        if let spec = spec(forToolCodeRaw: toolCode) {
            return spec.name
        }
        // Fallback heuristics for unknown codes
        if (toolCode & 0x000F) == 0x0006 {
            return "Mouse"
        }
        if (toolCode & 0x0008) != 0 {
            return "Eraser"
        }
        return "Stylus"
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
