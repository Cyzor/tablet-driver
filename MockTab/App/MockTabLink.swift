// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where a `mocktab:` link leads, for launchers like LaunchBar and for links
/// in Help. Links only open windows: none changes a setting or carries data,
/// so one fired from a web page can do no harm.
///
///     mocktab://settings               the frontmost settings window
///     mocktab://settings/pen-feel      that pane
///     mocktab://help                   Help
///     mocktab://help/buttons           that Help section
///
/// Panes and Help sections share names: each section's in kebab case. The
/// names are fixed English, so a link works whatever the app's language.
enum MockTabLink: Equatable {
    /// A settings pane, named for its Help section; nil for the window alone.
    case settings(HelpSection?)
    case help(HelpSection?)

    static let scheme = "mocktab"

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count <= 1 else { return nil }
        var section: HelpSection?
        if let slug = parts.first {
            guard let named = HelpSection.allCases.first(where: { Self.slug(for: $0) == slug.lowercased() })
            else { return nil }
            section = named
        }
        switch host {
        case "settings":
            if let section, !Self.isSettingsPane(section) { return nil }
            self = .settings(section)
        case "help":
            self = .help(section)
        default:
            return nil
        }
    }

    /// The link for this destination.
    var url: URL {
        switch self {
        case .settings(let section): Self.url(host: "settings", section: section)
        case .help(let section): Self.url(host: "help", section: section)
        }
    }

    /// Help sections with no settings pane of their own.
    static func isSettingsPane(_ section: HelpSection) -> Bool {
        section != .about && section != .website
    }

    /// A section's name in links: its raw value in kebab case.
    static func slug(for section: HelpSection) -> String {
        section.rawValue.reduce(into: "") { slug, character in
            if character.isUppercase { slug += "-" }
            slug += character.lowercased()
        }
    }

    private static func url(host: String, section: HelpSection?) -> URL {
        let path = section.map { "/" + slug(for: $0) } ?? ""
        return URL(string: "\(scheme)://\(host)\(path)")!
    }
}
