// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// TabletSettingsStub.swift — stand-ins for types DisplayMapper.swift reads
// off TabletSettings/InjectionSnapshot, kept minimal on purpose.
//
// DisplayMapper.swift itself only reads three static sentinel constants off
// TabletSettings (displayModeAll/displayModeToggle/displayModeSpan) — stubbed
// directly below.
//
// InjectionSnapshot is trickier: the real InjectionSnapshot.swift pairs the
// plain struct definition with a `@MainActor extension TabletSettings {
// func makeInjectionSnapshot() }` that reads ~30 stored properties off the
// real (large, UI-coupled) TabletSettings and ToolSettings classes.
// DisplayMapper's functions never call makeInjectionSnapshot() — they only
// read fields off an already-built InjectionSnapshot — so this harness
// doesn't need that extension at all. Pulling in the real InjectionSnapshot.swift
// would force pulling in TabletSettings.swift + ToolSettings.swift + their
// transitive dependencies just to satisfy a method body these tests never
// call, in contradiction of every other harness's "compile one isolated
// concern" scope (see tools/tests/prefs-resilience-tests/run.sh, which
// compiles model leaf types but stops short of TabletSettings itself).
//
// So this file hand-copies just the field list DisplayMapper.swift's mapping
// functions actually read (via `InjectionSnapshot`) as of 2026-09-18. Keep
// this in sync with MockTab/Driver/Injection/InjectionSnapshot.swift if its
// fields change — a normal `xcodebuild` of the app target (already part of
// this project's workflow) still compiles the real struct, so a drift here
// can only ever make this harness stale, never mask a real regression.

import CoreGraphics

enum TabletSettings {
    static let displayModeAll = -1
    static let displayModeToggle = -2
    static let displayModeSpan = -3
}

struct InjectionSnapshot {
    var tabletOrientation: TabletOrientation
    var activeAreaX: Double
    var activeAreaY: Double
    var activeAreaWidth: Double
    var activeAreaHeight: Double
    var proportionalMapping: Bool

    var targetDisplayIndex: Int
    var toggleDisplayIDs: Set<CGDirectDisplayID>
    var displayRegionX: Double
    var displayRegionY: Double
    var displayRegionWidth: Double
    var displayRegionHeight: Double
    var calibrationEntries: [CalibrationEntry]
    var parallaxOffsetX: Double
    var parallaxOffsetY: Double

    func calibration(for orientation: TabletOrientation,
                     displayUUID: String) -> CalibrationEntry? {
        guard !displayUUID.isEmpty else { return nil }
        return calibrationEntries.first {
            $0.key.orientation == orientation.rawValue && $0.key.displayUUID == displayUUID
        }
    }
}

extension InjectionSnapshot {
    /// Convenience factory for tests: every field defaults to whatever makes
    /// `DisplayMapper` behave as if the feature under test were untouched
    /// (full active area, no crop, primary display, no region narrowing).
    static func fixture(
        tabletOrientation: TabletOrientation = .landscape,
        activeAreaX: Double = 0, activeAreaY: Double = 0,
        activeAreaWidth: Double = 1, activeAreaHeight: Double = 1,
        proportionalMapping: Bool = false,
        targetDisplayIndex: Int = 0,
        toggleDisplayIDs: Set<CGDirectDisplayID> = [],
        displayRegionX: Double = 0, displayRegionY: Double = 0,
        displayRegionWidth: Double = 1, displayRegionHeight: Double = 1,
        calibrationEntries: [CalibrationEntry] = [],
        parallaxOffsetX: Double = 0, parallaxOffsetY: Double = 0
    ) -> InjectionSnapshot {
        InjectionSnapshot(
            tabletOrientation: tabletOrientation,
            activeAreaX: activeAreaX, activeAreaY: activeAreaY,
            activeAreaWidth: activeAreaWidth, activeAreaHeight: activeAreaHeight,
            proportionalMapping: proportionalMapping,
            targetDisplayIndex: targetDisplayIndex,
            toggleDisplayIDs: toggleDisplayIDs,
            displayRegionX: displayRegionX, displayRegionY: displayRegionY,
            displayRegionWidth: displayRegionWidth, displayRegionHeight: displayRegionHeight,
            calibrationEntries: calibrationEntries,
            parallaxOffsetX: parallaxOffsetX, parallaxOffsetY: parallaxOffsetY)
    }
}
