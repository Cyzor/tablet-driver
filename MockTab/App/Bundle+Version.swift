// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension Bundle {
    /// Only release.sh marks a build as a release, so dev and snapshot builds
    /// never pass as the release they followed.
    var isReleaseBuild: Bool {
        object(forInfoDictionaryKey: "MockTabRelease") as? Bool == true
    }

    /// UTC build time, e.g. "20260928T1538Z".
    var buildStamp: String? {
        object(forInfoDictionaryKey: "MockTabBuildStamp") as? String
    }

    /// "0.4.2" for releases, "0.4.2-snapshot-20260928T1538Z" otherwise. Used by
    /// the update page, diagnostics, and captures.
    var versionLabel: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        guard !isReleaseBuild, let buildStamp else { return version }
        return version + "-snapshot-" + buildStamp
    }
}
