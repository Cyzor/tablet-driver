// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
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
    var tipUpAssistDelay: Double
    var dragThreshold: Double
    var doubleClickDistance: Double
    /// System double-click time window (NSEvent.doubleClickInterval), captured
    /// on main so resolveClick never calls AppKit from HIDThread.
    var doubleClickInterval: Double

    // MARK: - Active tool (value-copied)

    var activeTool: Tool

    // MARK: - Express keys & touch ring

    var expressKeyBindings: [ButtonBinding]
    var bezelButtonBindings: [ButtonBinding]
    var touchRingButtonBinding: ButtonBinding
    var touchRingSlots: [ControlSlot]
    var touchRingActiveSlotIndex: Int

    // MARK: - Capacitive finger touch

    var touchEnabled: Bool
    var touchSensitivity: Double
    var tapToClick: Bool
    var twoFingerScroll: Bool
    var reverseScrollDirection: Bool
    var twoFingerScrollMomentum: Bool
    var pinchZoomEnabled: Bool
    var touchAreaX: Double
    var touchAreaY: Double
    var touchAreaWidth: Double
    var touchAreaHeight: Double

    /// Value-typed copy of the @MainActor `ToolSettings` instance.
    /// Includes the precomputed pressure LUT so HIDThread doesn't reach back into
    /// the live `ToolSettings` reference (which is owned by the main actor).
    struct Tool: Sendable, Equatable {
        var pressureLUT: [Double]
        var smoothingStrength: Double
        var pressureSmoothingStrength: Double
        var panScrollSpeed: Double
        var panScrollMomentum: Bool
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

    /// Look up the calibration entry for a specific orientation and display UUID.
    /// Mirrors `TabletSettings.calibration(for:displayUUID:)` so off-thread mapping
    /// can resolve calibration without touching the live settings object.
    func calibration(for orientation: TabletOrientation,
                     displayUUID: String) -> CalibrationEntry? {
        guard !displayUUID.isEmpty else { return nil }
        return calibrationEntries.first {
            $0.key.orientation == orientation.rawValue && $0.key.displayUUID == displayUUID
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
            tipUpAssistDelay: tipUpAssistDelay,
            dragThreshold: dragThreshold,
            doubleClickDistance: doubleClickDistance,
            doubleClickInterval: NSEvent.doubleClickInterval,
            activeTool: activeTool.injectionSnapshot(),
            expressKeyBindings: expressKeyBindings,
            bezelButtonBindings: bezelButtonBindings,
            touchRingButtonBinding: touchRingButtonBinding,
            touchRingSlots: touchRingSlots,
            touchRingActiveSlotIndex: touchRingActiveSlotIndex,
            touchEnabled: touchEnabled,
            touchSensitivity: touchSensitivity,
            tapToClick: tapToClick,
            twoFingerScroll: twoFingerScroll,
            reverseScrollDirection: reverseScrollDirection,
            twoFingerScrollMomentum: twoFingerScrollMomentum,
            pinchZoomEnabled: pinchZoomEnabled,
            touchAreaX: touchAreaX,
            touchAreaY: touchAreaY,
            touchAreaWidth: touchAreaWidth,
            touchAreaHeight: touchAreaHeight)
    }
}

@MainActor
extension ToolSettings {

    /// Value copy of the per-tool fields read by InputInjector.
    func injectionSnapshot() -> InjectionSnapshot.Tool {
        InjectionSnapshot.Tool(
            pressureLUT: pressureLUT,
            smoothingStrength: smoothingStrength,
            pressureSmoothingStrength: pressureSmoothingStrength,
            panScrollSpeed: panScrollSpeed,
            panScrollMomentum: panScrollMomentum,
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
