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

/// A portable snapshot of device and tool settings that can be exported to
/// or imported from JSON.
///
/// Profiles are transport-agnostic: they can be copied between machines,
/// shared online, or loaded by a future CLI without the GUI running.
/// All nested types (`BezierCurve`, `ButtonBinding`) are already `Codable`.
///
/// Phase 2 additions (when per-serial tool support is complete):
///   - `toolSettingsPerSerial` populated with `ToolSnapshot` entries
///   - `expressKeyBindings` array for the full 16-key layout
struct TabletSnapshot: Codable, Equatable {

    // MARK: - Identity

    /// Human-readable name, e.g. "Creative Work" or "Precision Linework".
    var name: String
    /// Device model string, e.g. "Wacom Intuos Pro M".  Informational only —
    /// profiles can be applied to any connected tablet.
    var deviceModel: String

    // MARK: - Tablet area mapping

    /// Active area origin X as a fraction of the full digitizer surface (0.0–1.0).
    var tabletAreaX: Double
    /// Active area origin Y as a fraction of the full digitizer surface (0.0–1.0).
    var tabletAreaY: Double
    /// Active area width as a fraction of the full digitizer surface (0.0–1.0).
    var tabletAreaWidth: Double
    /// Active area height as a fraction of the full digitizer surface (0.0–1.0).
    var tabletAreaHeight: Double
    /// When true, the active area is letterboxed to match the target display's
    /// aspect ratio so the pen maps without distortion.
    var proportionalMapping: Bool
    /// Target display index: 0 = primary, 1–N = specific display.
    var targetDisplayIndex: Int

    // MARK: - Pressure and smoothing

    /// Cubic Bézier pressure response curve.
    var pressureCurve: BezierCurve
    /// EMA smoothing coefficient, 0.0 (none) to 1.0 (maximum).
    var smoothingStrength: Double

    // MARK: - Button bindings

    /// Side button 1 (lower barrel button on most Wacom pens).
    var penButton1: ButtonBinding
    /// Side button 2 (upper barrel button on most Wacom pens).
    var penButton2: ButtonBinding
    /// Pen tip action.
    var tipBinding: ButtonBinding
    /// Eraser tip action.
    var eraserBinding: ButtonBinding

    // MARK: - Touch ring

    /// Touch ring operating mode ("scroll" or "off").
    var touchRingMode: String
    /// Touch ring center button binding.
    var touchRingButtonBinding: ButtonBinding

    // MARK: - Future (Phase 2)

    /// Per-pen-serial tool settings overrides.  Nil until per-serial support ships.
    var toolSettingsPerSerial: [String: ToolSnapshot]? = nil
}

// MARK: - ToolSnapshot

/// Per-pen-serial settings snapshot.  Planned for Phase 2 (per-serial tool support).
/// The `serial` field is the hex string representation of the 32-bit Wacom serial number.
struct ToolSnapshot: Codable, Equatable {
    var serial: String
    var pressureCurve: BezierCurve
    var smoothingStrength: Double
    var penButton1: ButtonBinding
    var penButton2: ButtonBinding
}
