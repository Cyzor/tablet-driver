// CalibrationSession.swift — State machine for multi-point parallax calibration
// MockTab

import Foundation
import CoreGraphics

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
        case done(maxResidual: Double, transformType: String)
        case cancelled
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentTargetPosition: CGPoint = .zero

    /// Normalized target positions (0–1) for this session.
    let targets: [(Double, Double)]
    let displayID: CGDirectDisplayID
    let displayBounds: CGRect
    let orientation: TabletOrientation
    private let settings: TabletSettings
    private let tabletManager: TabletManager

    /// Accumulated samples for the current target point.
    private var currentSamples: [(Double, Double)] = []
    /// Completed samples — one median per target.
    private var completedSamples: [CalibrationSample] = []
    /// Number of raw reports to collect per target before computing median.
    private let samplesPerTarget = 16

    // MARK: - Init

    init(settings: TabletSettings,
         tabletManager: TabletManager,
         displayID: CGDirectDisplayID,
         displayBounds: CGRect,
         orientation: TabletOrientation,
         advancedMode: Bool = false) {
        self.settings = settings
        self.tabletManager = tabletManager
        self.displayID = displayID
        self.displayBounds = displayBounds
        self.orientation = orientation
        self.targets = advancedMode ? CalibrationEntry.ninePointTargets : CalibrationEntry.fourPointTargets
    }

    // MARK: - Lifecycle

    func start() {
        completedSamples = []
        tabletManager.calibrationPointHandler = { [weak self] point in
            self?.handleRawPoint(point)
        }
        advanceToTarget(0)
    }

    func cancel() {
        tabletManager.calibrationPointHandler = nil
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
            let tabletAspect = areaW / areaH
            let displayAspect = Double(displayBounds.width) / Double(displayBounds.height)
            if tabletAspect > displayAspect {
                let effectiveW = areaH * displayAspect
                areaX += (areaW - effectiveW) / 2
                areaW = effectiveW
            } else if tabletAspect < displayAspect {
                let effectiveH = areaW / displayAspect
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
        tabletManager.calibrationPointHandler = nil
        state = .computing

        let transform = CalibrationEntry.fitBest(samples: completedSamples)
        let maxRes = CalibrationEntry.maxResidual(transform: transform, samples: completedSamples)

        let entry = CalibrationEntry(
            key: CalibrationKey(orientation: orientation.rawValue, displayID: displayID),
            samples: completedSamples,
            transform: transform,
            calibratedAt: Date(),
            maxResidual: maxRes)

        // Store the result, replacing any existing entry for this key.
        let oldJSON = settings.calibrationJSON
        var entries = settings.calibrationEntries
        entries.removeAll { $0.key == entry.key }
        entries.append(entry)
        settings.calibrationEntries = entries

        // Register undo.
        settings.record("Calibrate Pen Display") {
            self.settings.calibrationJSON = oldJSON
        }

        // Invalidate injector's calibration cache.
        tabletManager.activeContext?.injector.invalidateCalibrationCache()

        let typeName: String
        switch transform {
        case .none: typeName = "none"
        case .affine: typeName = "affine"
        case .homography: typeName = "homography"
        }
        state = .done(maxResidual: maxRes, transformType: typeName)
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
