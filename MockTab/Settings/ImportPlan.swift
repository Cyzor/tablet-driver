// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The result of parsing a v2 JSON backup: one entry per tablet found in the file.
struct ImportPlan: Identifiable {
    let id = UUID()

    /// A named preset found in the backup. Presets always import as a fresh
    /// profile (new UUID), so — unlike overrides/tool settings — there is no
    /// identity collision to resolve; only the display name can collide, and
    /// that's already handled by `TabletSettings.uniqueProfileName`.
    struct PresetEntry {
        let name: String
        let values: [String: Any]
    }

    /// A per-app override found in the backup. Identified by `bundleID` —
    /// importing one for an app that already has a local override is a real
    /// identity collision (not a naming one), surfaced in the preview UI.
    struct OverrideEntry {
        let bundleID: String
        let appName: String
        let values: [String: Any]
    }

    /// A per-tool settings block found in the backup. Identified by `toolID` —
    /// same collision class as `OverrideEntry`.
    struct ToolEntry {
        let toolID: String
        let kind: String
        let values: [String: Any]
    }

    struct TabletEntry {
        let productID: Int
        let modelName: String
        let nickname: String
        /// The preset name that will be created (may have suffix if name already taken).
        let resolvedProfileName: String
        /// All keys/values ready to write to UserDefaults for the preset.
        let profileValues: [String: Any]
        /// True if this productID is already in the registry.
        let isKnown: Bool
        /// Named presets found in the backup for this tablet.
        let presets: [PresetEntry]
        /// Per-app overrides found in the backup for this tablet.
        let overrides: [OverrideEntry]
        /// Per-tool settings found in the backup for this tablet.
        let toolSettings: [ToolEntry]
    }

    let sourceDate: String
    let entries: [TabletEntry]
}
