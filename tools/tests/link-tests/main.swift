// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL: \(label)")
    }
}

func link(_ string: String) -> MockTabLink? {
    URL(string: string).flatMap(MockTabLink.init)
}

// Names: fixed kebab case, one per section.
check(MockTabLink.slug(for: .tabletArea) == "tablet-area", "tablet-area slug")
check(MockTabLink.slug(for: .penFeel) == "pen-feel", "pen-feel slug")
check(MockTabLink.slug(for: .buttons) == "buttons", "buttons slug")
let slugs = HelpSection.allCases.map(MockTabLink.slug(for:))
check(Set(slugs).count == slugs.count, "slugs are distinct")

// Every section round-trips through its link.
for section in HelpSection.allCases {
    check(MockTabLink(MockTabLink.help(section).url) == .help(section), "help/\(section) round-trips")
    if MockTabLink.isSettingsPane(section) {
        check(MockTabLink(MockTabLink.settings(section).url) == .settings(section), "settings/\(section) round-trips")
    }
}

// Accepted forms.
check(link("mocktab://settings") == .settings(nil), "settings alone")
check(link("mocktab://settings/") == .settings(nil), "settings with trailing slash")
check(link("mocktab://help") == .help(nil), "help alone")
check(link("mocktab://settings/pen-feel") == .settings(.penFeel), "settings pane")
check(link("mocktab://help/website") == .help(.website), "help website section")
check(link("MockTab://Settings/Pen-Feel") == .settings(.penFeel), "case-insensitive")
check(link("mocktab://settings/buttons?x=1") == .settings(.buttons), "query ignored")

// Refused forms.
check(link("mocktab://settings/about") == nil, "about has no pane")
check(link("mocktab://settings/website") == nil, "website has no pane")
check(link("mocktab://settings/penFeel") == nil, "raw value isn't a slug")
check(link("mocktab://settings/nothing") == nil, "unknown pane")
check(link("mocktab://settings/buttons/extra") == nil, "extra path")
check(link("mocktab://preferences/buttons") == nil, "unknown host")
check(link("mocktab:settings/buttons") == nil, "no host")
check(link("https://settings/buttons") == nil, "other scheme")
check(link("file:///settings/buttons") == nil, "file URL")

print(failures == 0 ? "PASS: \(checks) link checks" : "\(failures) of \(checks) link checks failed")
exit(failures == 0 ? 0 : 1)
