// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026  This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab.  If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

struct AboutView: View {
    @State private var isHovering = false

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
                .overlay(alignment: .bottom) {
                    if isHovering {
                        Link(
                            destination: URL(
                                string: "https://en.wikipedia.org/wiki/Mock_Turtle")!
                        ) {
                            VStack(spacing: 4) {
                                Text("Alice's Adventures in Wonderland, Lewis Carroll")
                                    .font(.system(size: 12, weight: .bold).italic())
                                Text("Illustrator: John Tenniel, 1865")
                                    .font(.system(size: 11, weight: .bold))
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
                        .transition(.opacity)  // ← fades in/out
                    }
                }
                .animation(.easeIn(duration: 0.1), value: isHovering)  // ← drives the transition
                .onHover { hovering in
                    isHovering = hovering
                }

            Text(
                "“Once,” said the Mock Turtle at last, with a deep sigh, “I was a real Turtle.”"
            )
            .font(.system(size: 16).italic().bold())
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

                Text(String(localized: "MockTab", comment: "Application name"))
                    .font(.system(size: 32, weight: .semibold))
            }

            // Version
            HStack(spacing: 1) {
                Text(String(localized: "Version \(version)", comment: "App version label in about view"))
                Text(String(localized: "(\(build))", comment: "Build number in parentheses"))
                    .foregroundColor(.secondary)
            }
            .font(.system(size: 13))
            .foregroundColor(.secondary)

            Divider()
                .frame(maxWidth: 220)

            // Description
            Text(String(localized: "Native macOS driver for a few legacy drawing tablets", comment: "App tagline in about view"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(nil)

            // License Info
            licenseBox

            // Links
            HStack(spacing: 24) {
                Link(destination: URL(string: "https://github.com/mocktab/mocktab")!) {
                    Label(String(localized: "Source Code", comment: "Link label: view source code on GitHub"), systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.link)

                Link(destination: URL(string: "https://github.com/mocktab/mocktab/releases")!) {
                    Label(String(localized: "Releases", comment: "Link label: view releases on GitHub"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.link)
            }
            .font(.system(size: 11))

            // Copyright
            Text(String(localized: "Copyright © \(copyrightYears) MockTab Contributors", comment: "Copyright notice with year range"))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(28)
        .frame(width: 480, height: 720)
    }

    private var licenseBox: some View {
        VStack(spacing: 0) {
            Text(String(localized: "Open Source License", comment: "Section header: open source license information"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)

            Text(String(localized: "MockTab is free software released under the GNU General Public License v3.0.", comment: "License description in about view"))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(nil)

            Link(
                String(localized: "View License", comment: "Link label: view full GPL v3.0 license text"),
                destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
            )
            .font(.system(size: 10))
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

