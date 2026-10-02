// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct AboutView: View {
    @State private var isHovering = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?.?"
    }

    /// Stamped by the "Stamp Build Date" build phase on every build (Debug,
    /// Release, or Archive) — not a version-bump script's business, so it
    /// stays accurate for a local Cmd-R build even between releases.
    private var buildDate: String? {
        Bundle.main.object(forInfoDictionaryKey: "MockTabBuildDate") as? String
    }

    private var versionLabel: String {
        Bundle.main.isReleaseBuild
            ? String(localized: "Version \(version)", comment: "App version label in about view")
            : String(localized: "Version \(version) snapshot", comment: "App version label in about view, for builds between releases")
    }

    private var copyrightYears: String {
        let startYear = 2026
        let currentYear = Calendar.current.component(.year, from: Date())
        return startYear == currentYear ? "\(startYear)" : "\(startYear)–\(currentYear)"
    }

    var body: some View {
        VStack(spacing: 8) {
            // Mock Turtle Image with border
            Image("Mock-Turtle-Tenniel-1865")
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 800)
                .border(Color.secondary, width: 1.5)
                .accessibilityLabel(Text(String(
                    localized: "Mock Turtle, illustration by John Tenniel, 1865",
                    comment: "Accessibility label for the Mock Turtle illustration in the About view"
                )))
                .overlay(alignment: .bottom) {
                    if isHovering {
                        Link(
                            destination: URL(
                                string: "https://en.wikipedia.org/wiki/Mock_Turtle")!
                        ) {
                            VStack(spacing: 4) {
                                Text("Alice's Adventures in Wonderland, Lewis Carroll")
                                    .appFont(.settingsCaption).fontWeight(.bold).italic()
                                Text("Illustrator: John Tenniel, 1865")
                                    .appFont(.settingsBadge).fontWeight(.bold)
                            }
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.black.opacity(0.7))
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeIn(duration: 0.1), value: isHovering)
                .onHover { hovering in
                    isHovering = hovering
                }

            Text(
                "“Once,” said the Mock Turtle at last, with a deep sigh, “I was a real Turtle.”"
            )
            .appFont(.title3).italic().bold()
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .padding(1)
            Divider()

            // App Name + Icon
            HStack(spacing: 12) {
                 Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)

                Text(String(localized: "MockTab", comment: "Application name"))
                    .appFont(.largeTitle).fontWeight(.semibold)
            }

            // Version and build date on one line
            Text([versionLabel, buildDate].compactMap { $0 }.joined(separator: " · "))
                .appFont(.settingsLabel)
                .foregroundColor(.secondary)

            Divider()
                .frame(maxWidth: 220)

            // Description
            Text(String(localized: "Native macOS driver for a few legacy drawing tablets", comment: "App tagline in about view"))
                .appFont(.settingsCaption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(nil)

            // License Info
            licenseBox

            // Links
            HStack(spacing: 24) {
                Link(destination: URL(string: "https://mocktab.org")!) {
                    Label(String(localized: "mocktab.org", comment: "Link label: MockTab's website"), systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.link)

                Button {
                    AppMenuController.shared.checkForUpdates()
                } label: {
                    Label(String(localized: "Check for Updates", comment: "Link label in about view: open the update page in the browser"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.link)
            }
            .appFont(.settingsBadge)

            // Acknowledgments — MockTab's own decoder library, then outside device data.
            HStack(spacing: 4) {
                Text(String(localized: "Built on", comment: "Acknowledgment line prefix, followed by the linked name TabletKit"))
                    .foregroundColor(.secondary)
                Link("TabletKit", destination: URL(string: "https://github.com/Cyzor/TabletKit")!)
            }
            .appFont(.badgeSubtitle)
            .buttonStyle(.link)

            HStack(spacing: 4) {
                Text(String(localized: "Device data from", comment: "Acknowledgment line prefix, followed by linked project names"))
                    .foregroundColor(.secondary)
                Link("OpenTabletDriver", destination: URL(string: "https://opentabletdriver.net/")!)
                Text(String(localized: "and", comment: "Conjunction between two linked project names in the acknowledgment line"))
                    .foregroundColor(.secondary)
                Link(String(localized: "the Linux Wacom Project", comment: "Link label: the Linux Wacom Project (libwacom's parent project)"), destination: URL(string: "https://linuxwacom.github.io/")!)
            }
            .appFont(.badgeSubtitle)
            .buttonStyle(.link)

            // Copyright
            Text(String(localized: "Copyright © \(copyrightYears) MockTab Contributors", comment: "Copyright notice with year range"))
                .appFont(.badgeSubtitle)
                .foregroundColor(.secondary)
        }
        .padding(28)
        .frame(width: 480, height: 690)
    }

    private var licenseBox: some View {
        HStack(spacing: 4) {
            Text(String(localized: "Free software under the GPL v3", comment: "License line in about view, followed by a View License link"))
                .foregroundColor(.secondary)
            Text(verbatim: "·")
                .foregroundColor(.secondary)
            Link(
                String(localized: "View License", comment: "Link label: view full GPL v3.0 license text"),
                destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
            )
        }
        .appFont(.badgeSubtitle)
        .buttonStyle(.link)
    }
}

#Preview {
    AboutView()
}

