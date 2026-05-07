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

import CoreGraphics
import Foundation

/// Immutable, value-typed projection of every TabletSettings/ToolSettings field that
/// `InputInjector.inject()` (and its callees) reads on the per-report hot path.
///
/// Built on the main actor via `TabletSettings.makeInjectionSnapshot()`, then handed
/// to HIDThread so injection can run inline without the Task { @MainActor } hop.
/// HIDThread is a serial run-loop thread, so a single mutable copy of the snapshot
/// can be replaced atomically from main without locks.
struct InjectionSnapshot: Sendable, Equatable {

    // MARK: - Active area / orientation

    var tabletOrientation: TabletOrientation
    var activeAreaX: Double
    var activeAreaY: Double
    var activeAreaWidth: Double
    var activeAreaHeight: Double
    var proportionalMapping: Bool

    // MARK: - Display targeting

    var targetDisplayIndex: Int
    var toggleDisplayIDs: Set<CGDirectDisplayID>
    var calibrationEntries: [CalibrationEntry]
    var parallaxOffsetX: Double
    var parallaxOffsetY: Double

    // MARK: - Behavior

    var invertRotation: Bool
    var relativeCursorMovement: Bool
    var tipUpAssist: Bool
    var doubleClickDistance: Double

    // MARK: - Active tool (value-copied)

    var activeTool: Tool

    // MARK: - Express keys & touch ring

    var expressKeyBindings: [ButtonBinding]
    var touchRingButtonBinding: ButtonBinding
    var touchRingSlots: [ControlSlot]
    var touchRingActiveSlotIndex: Int

    /// Value-typed copy of the @MainActor `ToolSettings` instance.
    /// Includes the precomputed pressure LUT so HIDThread doesn't reach back into
    /// the live `ToolSettings` reference (which is owned by the main actor).
    struct Tool: Sendable, Equatable {
        var pressureLUT: [Double]
        var smoothingStrength: Double
        var tipBinding: ButtonBinding
        var eraserBinding: ButtonBinding
        var penButton1Binding: ButtonBinding
        var penButton2Binding: ButtonBinding
        var penButton3Binding: ButtonBinding
        var penButton4Binding: ButtonBinding
        var penButton5Binding: ButtonBinding
        var useRotationAsTilt: Bool
        var rotationTiltOffsetDegrees: Double
        var rotationTiltMagnitude: Double
    }

    /// Look up the calibration entry for a specific orientation and display.
    /// Mirrors `TabletSettings.calibration(for:displayID:)` so off-thread mapping
    /// can resolve calibration without touching the live settings object.
    func calibration(for orientation: TabletOrientation,
                     displayID: UInt32) -> CalibrationEntry? {
        calibrationEntries.first {
            $0.key.orientation == orientation.rawValue && $0.key.displayID == displayID
        }
    }
}

// MARK: - Snapshot construction

@MainActor
extension TabletSettings {

    /// Captures every field required by the input-injection hot path into an
    /// immutable value type that's safe to read from HIDThread.
    ///
    /// Cheap to call: ~30 scalars + small array copies. No I/O, no JSON parsing
    /// (calibration entries are read from the already-decoded property cache).
    func makeInjectionSnapshot() -> InjectionSnapshot {
        InjectionSnapshot(
            tabletOrientation: tabletOrientation,
            activeAreaX: activeAreaX,
            activeAreaY: activeAreaY,
            activeAreaWidth: activeAreaWidth,
            activeAreaHeight: activeAreaHeight,
            proportionalMapping: proportionalMapping,
            targetDisplayIndex: targetDisplayIndex,
            toggleDisplayIDs: toggleDisplayIDSet,
            calibrationEntries: calibrationEntries,
            parallaxOffsetX: parallaxOffsetX,
            parallaxOffsetY: parallaxOffsetY,
            invertRotation: invertRotation,
            relativeCursorMovement: relativeCursorMovement,
            tipUpAssist: tipUpAssist,
            doubleClickDistance: doubleClickDistance,
            activeTool: activeTool.injectionSnapshot(),
            expressKeyBindings: expressKeyBindings,
            touchRingButtonBinding: touchRingButtonBinding,
            touchRingSlots: touchRingSlots,
            touchRingActiveSlotIndex: touchRingActiveSlotIndex)
    }
}

@MainActor
extension ToolSettings {

    /// Value copy of the per-tool fields read by InputInjector.
    func injectionSnapshot() -> InjectionSnapshot.Tool {
        InjectionSnapshot.Tool(
            pressureLUT: pressureLUT,
            smoothingStrength: smoothingStrength,
            tipBinding: tipBinding,
            eraserBinding: eraserBinding,
            penButton1Binding: penButton1Binding,
            penButton2Binding: penButton2Binding,
            penButton3Binding: penButton3Binding,
            penButton4Binding: penButton4Binding,
            penButton5Binding: penButton5Binding,
            useRotationAsTilt: useRotationAsTilt,
            rotationTiltOffsetDegrees: rotationTiltOffsetDegrees,
            rotationTiltMagnitude: rotationTiltMagnitude)
    }
}
