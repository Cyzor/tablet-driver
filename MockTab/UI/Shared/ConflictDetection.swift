// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pure name-matching used by the Conflicts row in the Info tab to spot
/// known competing tablet-driver processes among currently running apps.
///
/// Deliberately process-based (the call site sources `liveNames` from
/// `NSWorkspace.shared.runningApplications`), never filesystem/launchd-based:
/// a stale, unloaded launchd plist left behind by an uninstalled driver
/// points at a binary that no longer exists and would falsely flag a
/// conflict that isn't actually running.
enum ConflictProcessMatcher {
    static let competingProcesses: [(name: String, label: String)] = [
        ("WacomTabletDriver", "Wacom Tablet Driver"),
        ("TabletDriver", "Wacom TabletDriver"),
        ("Wacom_IOManager", "Wacom I/O Manager"),
        ("WacomTabletSpringboard", "Wacom Springboard"),
        ("DataStoreMgr", "Wacom DataStore Manager"),
        ("OpenTabletDriver.Daemon", "OpenTabletDriver Daemon"),
        ("OpenTabletDriver.UX", "OpenTabletDriver UX"),
        ("OpenTabletDriver", "OpenTabletDriver (GUI)"),
        ("XencelabsDriver", "Xencelabs Driver"),
    ]

    /// Labels of competing processes found among `liveNames` (process
    /// display names and bundle identifiers of currently running apps).
    ///
    /// Exact matching only — no prefix/substring matching. Two failure
    /// modes ruled that out: some system processes report an empty
    /// `localizedName` (not `nil`, so it survives `compactMap`), which used
    /// to satisfy `x.hasPrefix("")` for every `x`; and a real harmless
    /// helper process can be a literal prefix of a real competing process's
    /// name (e.g. "Xencelabs" is a prefix of "XencelabsDriver"), which used
    /// to falsely flag the helper as the driver.
    static func matchedLabels(liveNames: Set<String>) -> [String] {
        competingProcesses.filter { liveNames.contains($0.name) }.map { $0.label }
    }
}
