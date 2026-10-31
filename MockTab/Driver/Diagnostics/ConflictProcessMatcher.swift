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
    /// Declaration order is display order.
    enum Vendor: Int, Comparable {
        case wacom, openTabletDriver, xencelabs

        static func < (a: Vendor, b: Vendor) -> Bool { a.rawValue < b.rawValue }
    }

    /// A running driver process, by process name or bundle ID.
    struct Match: Equatable {
        let vendor: Vendor
        let name: String
    }

    struct Matches: Equatable {
        /// Sorted by vendor, then name.
        var drivers: [Match] = []
        /// Bundle IDs of running Wacom apps that never read the tablet.
        var wacomHelpers: [String] = []
    }

    static let competingProcesses: [(name: String, vendor: Vendor)] = [
        ("OpenTabletDriver.Daemon", .openTabletDriver),
        ("OpenTabletDriver.UX", .openTabletDriver),
        ("OpenTabletDriver", .openTabletDriver),
        ("XencelabsDriver", .xencelabs),
    ]

    /// Wacom ships many apps, not all named for Wacom, and any of them
    /// running means its install is live, so they match by bundle ID.
    static let wacomBundlePrefix = "com.wacom."

    /// Wacom apps that leave the tablet alone. Anything else under the
    /// prefix counts as a driver, so a new or renamed one still gets flagged.
    static let wacomHelperBundleIDs: Set<String> = [
        "com.wacom.UpgradeHelper",
        "com.wacom.WacomCenter",
    ]

    /// Competing processes found among `liveNames` (process display names
    /// and bundle identifiers of currently running apps).
    ///
    /// Names match exactly — no prefix/substring matching. Two failure
    /// modes ruled that out: some system processes report an empty
    /// `localizedName` (not `nil`, so it survives `compactMap`), which used
    /// to satisfy `x.hasPrefix("")` for every `x`; and a real harmless
    /// helper process can be a literal prefix of a real competing process's
    /// name (e.g. "Xencelabs" is a prefix of "XencelabsDriver"), which used
    /// to falsely flag the helper as the driver.
    static func matches(liveNames: Set<String>) -> Matches {
        var result = Matches()
        let wacom = liveNames
            .filter { $0.hasPrefix(wacomBundlePrefix) && $0.count > wacomBundlePrefix.count }
            .sorted()
        for id in wacom {
            if wacomHelperBundleIDs.contains(id) {
                result.wacomHelpers.append(id)
            } else {
                result.drivers.append(Match(vendor: .wacom, name: id))
            }
        }
        result.drivers += competingProcesses
            .filter { liveNames.contains($0.name) }
            .map { Match(vendor: $0.vendor, name: $0.name) }
            .sorted { ($0.vendor, $0.name) < ($1.vendor, $1.name) }
        return result
    }
}
