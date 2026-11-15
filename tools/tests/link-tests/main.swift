// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

func link(_ string: String) -> MockTabLink? {
    URL(string: string).flatMap(MockTabLink.init)
}

// Names: fixed kebab case, one per section.
expect(MockTabLink.slug(for: .tabletArea) == "tablet-area", "tablet-area slug")
expect(MockTabLink.slug(for: .penFeel) == "pen-feel", "pen-feel slug")
expect(MockTabLink.slug(for: .buttons) == "buttons", "buttons slug")
let slugs = HelpSection.allCases.map(MockTabLink.slug(for:))
expect(Set(slugs).count == slugs.count, "slugs are distinct")

// Every section round-trips through its link.
for section in HelpSection.allCases {
    expect(MockTabLink(MockTabLink.help(section).url) == .help(section), "help/\(section) round-trips")
    if MockTabLink.isSettingsPane(section) {
        expect(MockTabLink(MockTabLink.settings(section).url) == .settings(section), "settings/\(section) round-trips")
    }
}

// Accepted forms.
expect(link("mocktab://settings") == .settings(nil), "settings alone")
expect(link("mocktab://settings/") == .settings(nil), "settings with trailing slash")
expect(link("mocktab://help") == .help(nil), "help alone")
expect(link("mocktab://settings/pen-feel") == .settings(.penFeel), "settings pane")
expect(link("mocktab://help/website") == .help(.website), "help website section")
expect(link("MockTab://Settings/Pen-Feel") == .settings(.penFeel), "case-insensitive")
expect(link("mocktab://settings/buttons?x=1") == .settings(.buttons), "query ignored")

// Refused forms.
expect(link("mocktab://settings/about") == nil, "about has no pane")
expect(link("mocktab://settings/website") == nil, "website has no pane")
expect(link("mocktab://settings/penFeel") == nil, "raw value isn't a slug")
expect(link("mocktab://settings/nothing") == nil, "unknown pane")
expect(link("mocktab://settings/buttons/extra") == nil, "extra path")
expect(link("mocktab://preferences/buttons") == nil, "unknown host")
expect(link("mocktab:settings/buttons") == nil, "no host")
expect(link("https://settings/buttons") == nil, "other scheme")
expect(link("file:///settings/buttons") == nil, "file URL")
finish()