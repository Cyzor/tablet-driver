// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import Foundation
import TabletKit

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
    var displayRegionX: Double
    var displayRegionY: Double
    var displayRegionWidth: Double
    var displayRegionHeight: Double
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
    /// Second dial's own toggle-key binding (PTK-670/870's right cluster
    /// center key). Unused on every other device.
    var touchRingButtonBinding2: ButtonBinding
    var touchRingSlots: [ControlSlot]
    var touchRingActiveSlotIndex: Int
    /// Active mode slot for the second, independent dial (PTK-670/870's right
    /// dial). Unused on every other device.
    var touchRingActiveSlotIndex2: Int
    var reverseRingDirection: Bool

    // MARK: - Capacitive finger touch

    /// For a wireless-dongle-bound device, the paired tablet's PID (0 if
    /// unpaired or not a dongle) — the dongle's own PID has no touch-area
    /// data in the registry, so touch coordinate scaling must key off this
    /// instead of `InputInjector.deviceProductID` once it's nonzero. See
    /// `DeviceContext.pairedProductID`.
    var pairedProductID: Int
    var touchEnabled: Bool
    var touchSensitivity: Double
    /// Seconds a touch sequence emits nothing after landing (from
    /// `TabletSettings.touchOnsetDelayMs`, converted from ms). Passed to
    /// `TouchStateTracker.process` as its `onsetDelay:` argument.
    var touchOnsetDelay: Double
    /// Screen points a single-finger touch may drift before it starts moving
    /// the cursor (from `TabletSettings.touchTapStabilizationPt`). Passed to
    /// `TouchStateTracker.process` as its `tapStabilizationPt:` argument. 0
    /// disables.
    var touchTapStabilizationPt: Double
    /// From `TabletSettings.touchAbsoluteMode`. Passed to
    /// `TouchStateTracker.process` as its `absoluteTouch:` argument.
    var touchAbsoluteMode: Bool
    var tapToClick: Bool
    var twoFingerScroll: Bool
    var reverseScrollDirection: Bool
    var twoFingerScrollMomentum: Bool
    var pinchZoomEnabled: Bool
    var smartZoomEnabled: Bool
    var rotateEnabled: Bool
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
    ///
    /// `pairedProductID` comes from the owning `DeviceContext`, not
    /// `TabletSettings` itself — see `InjectionSnapshot.pairedProductID`.
    func makeInjectionSnapshot(pairedProductID: Int = 0) -> InjectionSnapshot {
        InjectionSnapshot(
            tabletOrientation: tabletOrientation,
            activeAreaX: activeAreaX,
            activeAreaY: activeAreaY,
            activeAreaWidth: activeAreaWidth,
            activeAreaHeight: activeAreaHeight,
            proportionalMapping: proportionalMapping,
            targetDisplayIndex: targetDisplayIndex,
            toggleDisplayIDs: toggleDisplayIDSet,
            displayRegionX: displayRegionX,
            displayRegionY: displayRegionY,
            displayRegionWidth: displayRegionWidth,
            displayRegionHeight: displayRegionHeight,
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
            touchRingButtonBinding2: touchRingButtonBinding2,
            touchRingSlots: touchRingSlots,
            touchRingActiveSlotIndex: touchRingActiveSlotIndex,
            touchRingActiveSlotIndex2: touchRingActiveSlotIndex2,
            reverseRingDirection: reverseRingDirection,
            pairedProductID: pairedProductID,
            touchEnabled: touchEnabled,
            touchSensitivity: touchSensitivity,
            touchOnsetDelay: touchOnsetDelayMs / 1000.0,
            touchTapStabilizationPt: touchTapStabilizationPt,
            touchAbsoluteMode: Self.touchAbsoluteMode,
            tapToClick: tapToClick,
            twoFingerScroll: twoFingerScroll,
            reverseScrollDirection: reverseScrollDirection,
            twoFingerScrollMomentum: twoFingerScrollMomentum,
            pinchZoomEnabled: pinchZoomEnabled,
            smartZoomEnabled: smartZoomEnabled,
            rotateEnabled: rotateEnabled,
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
