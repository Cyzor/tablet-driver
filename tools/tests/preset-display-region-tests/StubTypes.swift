// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// StubTypes.swift — stand-ins so the real PresetImporter.swift typechecks
// standalone, kept minimal on purpose.
//
// This harness only exercises PresetImporter.decodeDeviceSettings and
// .decodeStoredSettings (plain `static func`s operating on [String: Any]),
// never .parse(_:registry:) — but Swift compiles a struct's body as one
// unit, so `parse`'s signature must still typecheck even though these tests
// never call it. `parse` references `DeviceRegistry` (793 lines, itself
// pulling in TabletManager/DeviceInstanceClaims/etc. — the same snowballing
// dependency graph tools/tests/display-region-tests/TabletSettingsStub.swift
// hit and stubbed around for InjectionSnapshot) and returns `ImportPlan`
// (small, dependency-free — compiled here from the real ImportPlan.swift,
// no stub needed). `decodeDisplay` also reads TabletSettings' three sentinel
// constants.
//
// A normal `xcodebuild` of the app target compiles the real DeviceRegistry
// and TabletSettings, so drift here can only make this harness stale, never
// mask a real regression — same guarantee TabletSettingsStub.swift relies on.

enum TabletSettings {
    static let displayModeAll = -1
    static let displayModeToggle = -2
    static let displayModeSpan = -3
}

/// Stand-in — `parse`'s signature needs the type to exist, and its body reads
/// `registry.knownTablets` (never actually called by these tests, but must
/// still typecheck as part of the struct).
struct DeviceRegistry {
    struct KnownTablet { let productID: Int }
    let knownTablets: [KnownTablet] = []
}
