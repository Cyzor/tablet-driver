// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import os
import TabletKit

private let displayMapperLog = Logger(subsystem: "com.cyzor.mocktab", category: "inject")

/// Maps tablet points and raw touch reports to screen coordinates: display
/// selection, orientation and active-area crop, multi-point calibration, and
/// relative (mouse-like) mode. Extracted out of `InputInjector` per the
/// 2026-05-18 review (`Notes/Scratch/InputInjector-review-2026-05-18.md`,
/// Phase 1) — this is the class's most well-isolated concern.
///
/// `InputInjector` holds this as a `var` field and calls its mutating methods
/// inline on the hot path, exactly as it called its own private methods
/// before the extraction. The caching/threading contract is unchanged: all
/// reads/writes happen on HIDThread except `recomputeVirtualScreenBounds()`,
/// which the caller must invoke on main (NSScreen is AppKit-only) — same
/// requirement `InputInjector` had before this was a separate type.
struct DisplayMapper {

    // MARK: - Display bounds cache

    private var cachedDisplayBounds: CGRect = .zero
    private var cachedDisplayIndex: Int = Int.min
    private var cachedDisplayUUID: String = ""
    private var cachedCalibration: CalibrationEntry?
    private var cachedCalibrationOrientation: Int = -1
    private var currentToggleIndex: Int = 0

    /// Cached physical active-area aspect ratio (width/height in mm),
    /// invalidated when the device's productID changes. nil when the registry
    /// doesn't have mm dimensions for this device, or the raw digitizer
    /// coordinate space happens to be isotropic (physical aspect and raw
    /// maxX/maxY ratio agree, as on Wacom hardware) — either way proportional
    /// mapping falls back to the raw-unit ratio. Needed because raw
    /// coordinate density isn't always the same on both axes (confirmed on
    /// Xencelabs' Pen Display: X and Y have very different units-per-mm), so
    /// `areaW / areaH` in raw units is not a reliable proxy for the tablet's
    /// visual aspect ratio — using it directly let proportional mapping
    /// letterbox against a fictitious ~2.7x-too-tall "aspect ratio" and
    /// badly distort the mapped area.
    private var cachedPhysicalAspect: Double?
    private var cachedAspectSpecPID: Int = -1

    /// Union of all NSScreen frames in CG (top-left origin) coordinates, used by
    /// relative-mode mapping. NSScreen is AppKit and main-thread-only; reading it
    /// inside `resolveRelativePoint` would block moving inject() off the main actor.
    /// Recomputed on main when displays change (didChangeScreenParametersNotification).
    private var cachedVirtualScreenBounds: CGRect = .zero

    /// Last normalized tablet position while in relative-cursor-movement mode.
    /// Cleared at proximity exit so the first report after hover-entry doesn't
    /// produce a large jump.
    private var lastRelativeNorm: CGPoint? = nil

    // MARK: - Cache invalidation

    /// Forces a display-bounds and calibration cache miss on the next lookup.
    /// Called when the target display changes (settings edit, screen
    /// reconfiguration) or the toggle rotation advances.
    mutating func invalidateDisplayCache() {
        cachedDisplayIndex = Int.min
        cachedCalibrationOrientation = -1
    }

    /// Force re-read of calibration data on next inject.
    /// Call after calibration data is stored or cleared.
    mutating func invalidateCalibrationCache() {
        cachedCalibrationOrientation = -1
    }

    /// Clears the relative-mode anchor. Call at proximity exit and on
    /// deadzone rejection so the pen doesn't re-anchor from stale state.
    mutating func clearRelativeAnchor() {
        lastRelativeNorm = nil
    }

    /// Recomputes `cachedVirtualScreenBounds` from `NSScreen.screens`.
    /// Must be called on main.
    mutating func recomputeVirtualScreenBounds() {
        let primaryH = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        let union: CGRect = NSScreen.screens.reduce(CGRect.null) { acc, screen in
            // Convert AppKit frame (bottom-left origin) → CG frame (top-left origin).
            let f = screen.frame
            let cgRect = CGRect(
                x: f.minX, y: primaryH - f.maxY,
                width: f.width, height: f.height)
            return acc.union(cgRect)
        }
        cachedVirtualScreenBounds = union
    }

    // MARK: - Point mapping

    /// In relative mode: computes a delta from the previous normalized tablet position
    /// and applies it to the current cursor location.
    ///
    /// Display mapping is intentionally ignored — it makes no sense for mouse-like input.
    /// Deltas are scaled by the total virtual screen space (union of all displays), so a
    /// full active-area sweep traverses the entire available screen real estate.  The
    /// cursor is clamped to the same total bounds so it can reach any display.
    ///
    /// Active-area crop is still respected: a smaller crop = higher sensitivity.
    mutating func resolveRelativePoint(
        _ point: TabletPoint, snapshot: InjectionSnapshot, currentCursorPosition: CGPoint
    ) -> CGPoint {
        let virtualBounds = cachedVirtualScreenBounds
        let screen =
            virtualBounds.isEmpty
            ? CGRect(
                x: 0, y: 0,
                width: CGFloat(CGDisplayPixelsWide(CGMainDisplayID())),
                height: CGFloat(CGDisplayPixelsHigh(CGMainDisplayID())))
            : virtualBounds

        // Compute normalized position within the active area (same orientation math
        // as mapToScreen; active-area crop controls sensitivity).
        let rawX = Double(point.x)
        let rawY = Double(point.y)
        let rawMaxX = Double(point.maxX)
        let rawMaxY = Double(point.maxY)
        let ox: Double
        let oy: Double
        let effMaxX: Double
        let effMaxY: Double
        let orientation = snapshot.tabletOrientation
        switch orientation {
        case .landscape:
            ox = rawX
            oy = rawY
            effMaxX = rawMaxX
            effMaxY = rawMaxY
        case .portrait:
            ox = rawY
            oy = rawMaxX - rawX
            effMaxX = rawMaxY
            effMaxY = rawMaxX
        case .landscapeFlipped:
            ox = rawMaxX - rawX
            oy = rawMaxY - rawY
            effMaxX = rawMaxX
            effMaxY = rawMaxY
        case .portraitFlipped:
            ox = rawMaxY - rawY
            oy = rawX
            effMaxX = rawMaxY
            effMaxY = rawMaxX
        }
        let areaW = Swift.max(snapshot.activeAreaWidth, 0.001) * effMaxX
        let areaH = Swift.max(snapshot.activeAreaHeight, 0.001) * effMaxY
        let norm = CGPoint(
            x: (ox - snapshot.activeAreaX * effMaxX) / areaW,
            y: (oy - snapshot.activeAreaY * effMaxY) / areaH)

        // First report after proximity entry: anchor without moving.
        guard let prev = lastRelativeNorm else {
            lastRelativeNorm = norm
            return currentCursorPosition
        }
        lastRelativeNorm = norm

        let dx = (norm.x - prev.x) * screen.width
        let dy = (norm.y - prev.y) * screen.height
        let cur = currentCursorPosition
        return CGPoint(
            x: Swift.min(Swift.max(cur.x + dx, screen.minX), screen.maxX),
            y: Swift.min(Swift.max(cur.y + dy, screen.minY), screen.maxY))
    }

    /// Maps a tablet point to screen coordinates, accounting for orientation and active area cropping.
    /// Returns nil if the pen is outside the active area (deadzone).
    mutating func mapToScreen(
        _ point: TabletPoint, snapshot: InjectionSnapshot, deviceProductID: Int
    ) -> CGPoint? {
        let displayBounds = displayBounds(for: snapshot)

        // Apply orientation transform before the active-area crop.
        // The active-area fractions are defined in oriented (post-rotation) space,
        // so we transform raw hardware coordinates first, then apply the crop.
        let rawX = Double(point.x)
        let rawY = Double(point.y)
        let rawMaxX = Double(point.maxX)
        let rawMaxY = Double(point.maxY)

        let ox: Double  // oriented x
        let oy: Double  // oriented y
        let effMaxX: Double  // range of oriented x axis
        let effMaxY: Double  // range of oriented y axis

        let orientation = snapshot.tabletOrientation
        switch orientation {
        case .landscape:
            ox = rawX
            oy = rawY
            effMaxX = rawMaxX
            effMaxY = rawMaxY
        case .portrait:  // 90° CW — USB port moves to left
            ox = rawY
            oy = rawMaxX - rawX
            effMaxX = rawMaxY
            effMaxY = rawMaxX
        case .landscapeFlipped:  // 180° — USB port at top
            ox = rawMaxX - rawX
            oy = rawMaxY - rawY
            effMaxX = rawMaxX
            effMaxY = rawMaxY
        case .portraitFlipped:  // 90° CCW — USB port moves to right
            ox = rawMaxY - rawY
            oy = rawX
            effMaxX = rawMaxY
            effMaxY = rawMaxX
        }

        var areaX = snapshot.activeAreaX * effMaxX
        var areaY = snapshot.activeAreaY * effMaxY
        var areaW = Swift.max(snapshot.activeAreaWidth, 0.001) * effMaxX
        var areaH = Swift.max(snapshot.activeAreaHeight, 0.001) * effMaxY

        if snapshot.proportionalMapping {
            if cachedAspectSpecPID != deviceProductID {
                // Wacom hardware's raw units are isotropic, so WacomDeviceRegistry
                // doesn't need this — only vendor (Xencelabs/XP-Pen/etc.) profiles
                // carry activeWidthMM/Height for this purpose. Look up by
                // productID alone (not vendorID+productID): deviceVendorID
                // is correct at DeviceContext construction time, but proved
                // unreliable to depend on here in practice (this cache
                // observably flipped to the raw-ratio fallback partway
                // through a session, right when the pen tool was first
                // detected) — simplest fix is to not need it.
                if let profile = VendorDeviceRegistry.profile(forProductID: deviceProductID),
                    let w = profile.activeWidthMM, w > 0, let h = profile.activeHeightMM, h > 0
                {
                    cachedPhysicalAspect = w / h
                } else {
                    cachedPhysicalAspect = nil
                }
                cachedAspectSpecPID = deviceProductID
            }
            // Visual aspect of the (possibly cropped) active area. With mm
            // data: physical surface aspect, orientation-swapped, scaled by
            // the crop fractions of each axis. Without: raw-unit ratio
            // (correct for isotropic Wacom hardware).
            let surfaceAspect: Double
            if let phys = cachedPhysicalAspect {
                surfaceAspect = orientation.swapsAxes ? 1.0 / phys : phys
            } else {
                surfaceAspect = effMaxX / effMaxY
            }
            let tabletAspect = surfaceAspect * (areaW / effMaxX) / (areaH / effMaxY)
            let displayAspect = Double(displayBounds.width) / Double(displayBounds.height)
            // Crop as a *ratio of aspects*, never by cross-multiplying one
            // axis's raw units against the other's: nothing guarantees the
            // two axes share a units-per-mm scale, and if they don't,
            // `areaH * displayAspect` is not an X-axis length. For
            // isotropic hardware these expressions reduce exactly to the
            // old areaH*displayAspect / areaW/displayAspect forms.
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

        // Outside active area — deadzone
        guard relX >= 0, relX <= 1, relY >= 0, relY <= 1 else { return nil }

        // Apply multi-point calibration transform in normalized space (if available).
        var calX = relX, calY = relY
        let orientRaw = orientation.rawValue
        if cachedCalibrationOrientation != orientRaw {
            cachedCalibration = snapshot.calibration(for: orientation,
                                                     displayUUID: cachedDisplayUUID)
            cachedCalibrationOrientation = orientRaw
        }
        if let cal = cachedCalibration {
            (calX, calY) = cal.apply(to: (relX, relY))
        }

        var sx = displayBounds.minX + calX * displayBounds.width
        var sy = displayBounds.minY + calY * displayBounds.height

        // Additive fine-tune offset (points, user-configured) — stacks on top of calibration.
        sx += snapshot.parallaxOffsetX
        sy += snapshot.parallaxOffsetY

        sx = Swift.min(Swift.max(sx, displayBounds.minX), displayBounds.maxX)
        sy = Swift.min(Swift.max(sy, displayBounds.minY), displayBounds.maxY)
        return CGPoint(x: sx, y: sy)
    }

    // MARK: - Display bounds resolution

    /// Returns bounds for `snapshot.targetDisplayIndex`, using the cache when the
    /// index hasn't changed. Also used by the touch path, which shares the pen's
    /// target display.
    mutating func displayBounds(for snapshot: InjectionSnapshot) -> CGRect {
        let idx = snapshot.targetDisplayIndex
        if cachedDisplayIndex != idx {
            let (bounds, displayID) = resolveDisplayBoundsAndID(snapshot: snapshot)
            cachedDisplayBounds = bounds
            cachedDisplayUUID = CalibrationKey.uuidString(for: displayID)
            cachedDisplayIndex = idx
            // Invalidate calibration cache when display changes.
            cachedCalibrationOrientation = -1
        }
        return cachedDisplayBounds
    }

    /// Queries the OS display list and returns the target display's bounds and ID.
    /// Only called on cache miss; results stored in cachedDisplayBounds/cachedDisplayUUID.
    private func resolveDisplayBoundsAndID(snapshot: InjectionSnapshot) -> (CGRect, CGDirectDisplayID) {
        let mainID = CGMainDisplayID()
        let fallback = CGRect(
            x: 0, y: 0,
            width: CGFloat(CGDisplayPixelsWide(mainID)),
            height: CGFloat(CGDisplayPixelsHigh(mainID))
        )
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            displayMapperLog.error("displayUnion: CGGetActiveDisplayList(count) failed or zero displays — falling back to main display")
            return (fallback, mainID)
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            displayMapperLog.error("displayUnion: CGGetActiveDisplayList(ids) failed — falling back to main display")
            return (fallback, mainID)
        }
        let idx = snapshot.targetDisplayIndex
        if idx == TabletSettings.displayModeAll {
            // Union bounding rect spanning every active display — no single display ID.
            return (ids.map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }, 0)
        }
        if idx == TabletSettings.displayModeToggle {
            let rotation = toggleRotation(snapshot: snapshot, allIDs: ids)
            guard !rotation.isEmpty else { return (CGDisplayBounds(mainID), mainID) }
            let toggleID = rotation[currentToggleIndex % rotation.count]
            return (CGDisplayBounds(toggleID), toggleID)
        }
        if idx > 0, idx <= ids.count {
            let targetID = ids[idx - 1]
            return (CGDisplayBounds(targetID), targetID)
        }
        return (CGDisplayBounds(mainID), mainID)
    }

    /// Returns the ordered list of display IDs in the toggle rotation,
    /// filtered by the IDs stored in settings (empty = all included).
    private func toggleRotation(
        snapshot: InjectionSnapshot,
        allIDs: [CGDirectDisplayID]
    ) -> [CGDirectDisplayID] {
        let stored = snapshot.toggleDisplayIDs
        if stored.isEmpty { return allIDs }
        return allIDs.filter { stored.contains($0) }
    }

    /// Advances the toggle rotation to the next display in the sequence.
    /// No-op when fewer than two displays are in the rotation.
    /// Called from fireButtonAction (HIDThread) when a `.displayToggle` binding fires.
    mutating func cycleToggleDisplay(snapshot: InjectionSnapshot) {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return }
        let rotation = toggleRotation(snapshot: snapshot, allIDs: ids)
        guard rotation.count > 1 else { return }
        currentToggleIndex = (currentToggleIndex + 1) % rotation.count
        cachedDisplayIndex = Int.min  // force cache miss on next inject
        cachedCalibrationOrientation = -1
    }
}
