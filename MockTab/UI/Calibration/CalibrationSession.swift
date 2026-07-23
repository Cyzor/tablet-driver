// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// CalibrationSession.swift — State machine for multi-point parallax calibration

import Foundation
import CoreGraphics
import OSLog
import TabletKit

let calibrationLogger = Logger(subsystem: "com.cyzor.mocktab", category: "calibration")

/// Drives the calibration flow: presents targets, collects raw pen samples,
/// fits a transform, and stores the result.
@MainActor
final class CalibrationSession: ObservableObject {

    // MARK: - State

    enum State: Equatable {
        case idle
        case awaitingTap(pointIndex: Int)
        case collecting(pointIndex: Int, sampleCount: Int)
        case computing
        /// `stored` is false when the fit's residual exceeded
        /// `residualWarningThreshold` — the entry is held in `pendingEntry` and
        /// only written if the user explicitly applies it.
        case done(maxResidual: Double, transformType: String, stored: Bool)
        case cancelled
    }

    /// Max residual (normalized display units) still considered a usable fit.
    /// 0.01 is 1% of the display's longer edge — about 26 px on a 2560-px-wide
    /// screen, comfortably above a careful tap's noise and well below the error
    /// produced by tapping targets out of order or missing them.
    static let residualWarningThreshold = 0.01

    @Published private(set) var state: State = .idle
    @Published private(set) var currentTargetPosition: CGPoint = .zero

    /// Normalized target positions (0–1) for this session.
    let targets: [(Double, Double)]
    let displayUUID: String
    let displayBounds: CGRect
    let orientation: TabletOrientation
    private let settings: TabletSettings
    private let tabletManager: TabletManager
    /// Advanced (9-point) sessions permit higher-order affine/homography fits for
    /// non-coincident setups; the default simple session stays scale + translation.
    private let advancedMode: Bool

    /// Accumulated samples for the current target point.
    private var currentSamples: [(Double, Double)] = []
    /// Completed samples — one median per target.
    private var completedSamples: [CalibrationSample] = []
    /// Number of raw reports to collect per target before computing median.
    private let samplesPerTarget = 16

    // MARK: - Init

    init(settings: TabletSettings,
         tabletManager: TabletManager,
         displayUUID: String,
         displayBounds: CGRect,
         orientation: TabletOrientation,
         advancedMode: Bool = false) {
        self.settings = settings
        self.tabletManager = tabletManager
        self.displayUUID = displayUUID
        self.displayBounds = displayBounds
        self.orientation = orientation
        self.advancedMode = advancedMode
        self.targets = advancedMode ? CalibrationEntry.ninePointTargets : CalibrationEntry.fourPointTargets
    }

    // MARK: - Lifecycle

    func start() {
        completedSamples = []
        tabletManager.setCalibrationPointHandler { [weak self] point in
            self?.handleRawPoint(point)
        }
        advanceToTarget(0)
    }

    func cancel() {
        tabletManager.setCalibrationPointHandler(nil)
        state = .cancelled
    }

    // MARK: - Target advancement

    /// True while we're waiting for the pen to lift before accepting the next tap.
    /// Prevents a held tap from bleeding straight into the next target's collection.
    private var waitingForLift = false

    private func advanceToTarget(_ index: Int) {
        guard index < targets.count else {
            finishCalibration()
            return
        }
        currentSamples = []
        let (tx, ty) = targets[index]
        currentTargetPosition = CGPoint(x: tx, y: ty)
        waitingForLift = true   // require pen lift before next collection starts
        state = .awaitingTap(pointIndex: index)
    }

    // MARK: - Raw point handling

    private func handleRawPoint(_ point: TabletPoint) {
        guard point.inProximity else { return }

        // Gate: if we just finished a point, block collection until pen lifts.
        if waitingForLift {
            if point.pressure == 0 { waitingForLift = false }
            return
        }

        let pointIndex: Int
        switch state {
        case .awaitingTap(let idx):
            // Wait for tip-down to start collecting.
            guard point.pressure > 0 else { return }
            pointIndex = idx
            state = .collecting(pointIndex: idx, sampleCount: 0)
        case .collecting(let idx, _):
            pointIndex = idx
        default:
            return
        }

        // Convert raw hardware coords to oriented normalized [0,1] using
        // the same transform as InputInjector.mapToScreen().
        guard let (relX, relY) = normalizeRawPoint(point) else { return }

        currentSamples.append((relX, relY))
        state = .collecting(pointIndex: pointIndex, sampleCount: currentSamples.count)

        if currentSamples.count >= samplesPerTarget {
            // Compute median of collected samples.
            let medX = median(currentSamples.map(\.0))
            let medY = median(currentSamples.map(\.1))
            let (tx, ty) = targets[pointIndex]
            completedSamples.append(CalibrationSample(
                targetX: tx, targetY: ty,
                observedX: medX, observedY: medY))
            advanceToTarget(pointIndex + 1)
        }
    }

    /// Convert a raw TabletPoint to oriented normalized [0,1] coordinates,
    /// applying the same orientation transform and active-area crop as mapToScreen.
    private func normalizeRawPoint(_ point: TabletPoint) -> (Double, Double)? {
        let rawX = Double(point.x)
        let rawY = Double(point.y)
        let rawMaxX = Double(point.maxX)
        let rawMaxY = Double(point.maxY)

        let ox: Double, oy: Double
        let effMaxX: Double, effMaxY: Double

        switch orientation {
        case .landscape:
            ox = rawX; oy = rawY
            effMaxX = rawMaxX; effMaxY = rawMaxY
        case .portrait:
            ox = rawY; oy = rawMaxX - rawX
            effMaxX = rawMaxY; effMaxY = rawMaxX
        case .landscapeFlipped:
            ox = rawMaxX - rawX; oy = rawMaxY - rawY
            effMaxX = rawMaxX; effMaxY = rawMaxY
        case .portraitFlipped:
            ox = rawMaxY - rawY; oy = rawX
            effMaxX = rawMaxY; effMaxY = rawMaxX
        }

        var areaX = settings.activeAreaX * effMaxX
        var areaY = settings.activeAreaY * effMaxY
        var areaW = Swift.max(settings.activeAreaWidth, 0.001) * effMaxX
        var areaH = Swift.max(settings.activeAreaHeight, 0.001) * effMaxY

        if settings.proportionalMapping {
            // Mirror of InputInjector.mapToScreen's proportional crop — keep
            // the two in sync. Nothing guarantees both axes share a raw
            // units-per-mm scale, so both the aspect *comparison* and the
            // crop *amounts* are computed unit-free: use the vendor
            // profile's physical mm dimensions when available, and scale
            // crops by aspect ratios rather than cross-multiplying one
            // axis's raw units against the other's. Reduces exactly to the
            // old isotropic math for Wacom hardware (no mm data).
            var surfaceAspect = effMaxX / effMaxY
            if let productID = tabletManager.activeContext?.injector.deviceProductID,
                let profile = VendorDeviceRegistry.profile(forProductID: productID),
                let w = profile.activeWidthMM, w > 0, let h = profile.activeHeightMM, h > 0
            {
                surfaceAspect = orientation.swapsAxes ? h / w : w / h
            }
            let tabletAspect = surfaceAspect * (areaW / effMaxX) / (areaH / effMaxY)
            let displayAspect = Double(displayBounds.width) / Double(displayBounds.height)
            if tabletAspect > displayAspect {
                let effectiveW = areaW * (displayAspect / tabletAspect)
                areaX += (areaW - effectiveW) / 2
                areaW = effectiveW
            } else if tabletAspect < displayAspect {
                let effectiveH = areaH * (tabletAspect / displayAspect)
                areaY += (areaH - effectiveH) / 2
                areaH = effectiveH
            }
        }

        let relX = (ox - areaX) / areaW
        let relY = (oy - areaY) / areaH
        guard relX >= 0, relX <= 1, relY >= 0, relY <= 1 else { return nil }
        return (relX, relY)
    }

    // MARK: - Finish

    private func finishCalibration() {
        tabletManager.setCalibrationPointHandler(nil)
        state = .computing

        let transform = CalibrationEntry.fitBest(samples: completedSamples, allowHigherOrder: advancedMode)
        let maxRes = CalibrationEntry.maxResidual(transform: transform, samples: completedSamples)

        let entry = CalibrationEntry(
            key: CalibrationKey(orientation: orientation.rawValue, displayUUID: displayUUID),
            samples: completedSamples,
            transform: transform,
            calibratedAt: Date(),
            maxResidual: maxRes)

        let typeName: String
        switch transform {
        case .none: typeName = "none"
        case .affine: typeName = "affine"
        case .homography: typeName = "homography"
        }
        let pointCount = completedSamples.count

        // A fit this loose means the targets weren't tapped where they were drawn —
        // wrong order, missed crosshairs, pen lifted early. Applying it would move
        // the cursor further from the pen tip than no calibration at all, so hold
        // the entry back and make the user opt in rather than silently storing it.
        let usable = maxRes <= Self.residualWarningThreshold
        calibrationLogger.debug(
            "calibration complete: \(typeName, privacy: .public) fit, \(pointCount) points, max residual \(maxRes, privacy: .public), usable \(usable, privacy: .public)")

        if usable {
            store(entry)
        } else {
            pendingEntry = entry
        }
        state = .done(maxResidual: maxRes, transformType: typeName, stored: usable)
    }

    /// Entry computed but withheld because its residual failed the quality check.
    /// Written only if the user chooses to apply it anyway.
    private var pendingEntry: CalibrationEntry?

    /// Apply a result that was withheld for a high residual. No-op otherwise.
    func applyPendingResult() {
        guard let entry = pendingEntry else { return }
        pendingEntry = nil
        calibrationLogger.debug("user applied high-residual calibration")
        store(entry)
        if case .done(let res, let type, _) = state {
            state = .done(maxResidual: res, transformType: type, stored: true)
        }
    }

    /// Discard a withheld result. Nothing was written, so this only clears the
    /// pending entry — previous calibration for this key is untouched.
    func discardPendingResult() {
        guard pendingEntry != nil else { return }
        pendingEntry = nil
        calibrationLogger.debug("user discarded high-residual calibration")
    }

    /// Write an entry into settings, replacing any existing one for its key.
    private func store(_ entry: CalibrationEntry) {
        let oldJSON = settings.calibrationJSON
        var entries = settings.calibrationEntries
        entries.removeAll { $0.key == entry.key }
        entries.append(entry)
        settings.calibrationEntries = entries
        let newJSON = settings.calibrationJSON

        // Register undo (and, via recordToggle, redo).
        settings.recordToggle(String(localized: "Calibrate Pen Display", comment: "Undo action name: applying a pen-display calibration result"), from: oldJSON, to: newJSON) {
            self.settings.calibrationJSON = $0
        }

        // Invalidate injector's calibration cache.
        tabletManager.activeContext?.injector.invalidateCalibrationCache()
    }

    // MARK: - Helpers

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        if n == 0 { return 0 }
        if n % 2 == 0 { return (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0 }
        return sorted[n / 2]
    }
}
