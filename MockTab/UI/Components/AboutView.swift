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

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?.?"
    }

    private var copyrightYears: String {
        let startYear = 2026
        let currentYear = Calendar.current.component(.year, from: Date())
        return startYear == currentYear ? "\(startYear)" : "\(startYear)–\(currentYear)"
    }

    var body: some View {
        VStack(spacing: 10) {
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
//                Image("AboutMockTabIcon")
                    .resizable()
                    .frame(width: 128, height: 128)
                    .accessibilityHidden(true)

                Text(String(localized: "MockTab", comment: "Application name"))
                    .appFont(.largeTitle).fontWeight(.semibold)
            }

            // Version
            HStack(spacing: 1) {
                Text(String(localized: "Version \(version)", comment: "App version label in about view"))
                Text(String(localized: "(\(build))", comment: "Build number in parentheses"))
                    .foregroundColor(.secondary)
            }
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

                Link(destination: URL(string: "https://github.com/cyzor/tablet-driver/releases")!) {
                    Label(String(localized: "Releases", comment: "Link label: view releases on GitHub"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.link)
            }
            .appFont(.settingsBadge)

            // Acknowledgments — device data and protocol research MockTab draws on.
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
        .frame(width: 480, height: 720)
    }

    private var licenseBox: some View {
        VStack(spacing: 0) {
            Text(String(localized: "Open Source License", comment: "Section header: open source license information"))
                .appFont(.settingsBadge).fontWeight(.medium)
                .foregroundColor(.primary)

            Text(String(localized: "MockTab is free software released under the GNU General Public License v3.0.", comment: "License description in about view"))
                .appFont(.badgeSubtitle)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(nil)

            Link(
                String(localized: "View License", comment: "Link label: view full GPL v3.0 license text"),
                destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
            )
            .appFont(.badgeSubtitle)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

#Preview {
    AboutView()
}

