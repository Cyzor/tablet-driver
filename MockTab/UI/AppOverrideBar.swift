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

import AppKit
import SwiftUI

/// Per-tab application override selector.
///
/// Displays a horizontal row of app chips — "Global" plus one chip per app that
/// has a registered override for this tab's domain keys.  Clicking a chip
/// selects that app's override for viewing and editing; the active chip matches
/// the currently frontmost application.
///
/// Domain keys identify which settings belong to the enclosing tab:
///   - Tablet Area:  areaKeys
///   - Pressure:     pressureKeys
///   - Buttons:      buttonKeys
struct AppOverrideBar: View {

    // MARK: - Domain key sets

    static let areaKeys: Set<String> = [
        "activeAreaX", "activeAreaY", "activeAreaWidth", "activeAreaHeight",
        "proportionalMapping", "targetDisplayIndex", "toggleDisplayIDs",
    ]

    static let pressureKeys: Set<String> = [
        "pressureCurve", "smoothingStrength", "doubleClickDistance",
    ]

    static let buttonKeys: Set<String> = [
        "penButton1Binding", "penButton2Binding",
        "tipBinding", "eraserBinding",
        "expressKeyBindings",
        "touchRingButtonBinding", "touchRingMode",
        "touchStrip1Mode", "touchStrip2Mode",
    ]

    // MARK: - Properties

    @ObservedObject var settings: TabletSettings
    let domainKeys: Set<String>

    /// All registered overrides (visible in the chip row regardless of domain keys,
    /// so the user can select any app and start building overrides for it).
    private var allOverrides: [TabletSettings.AppOverride] {
        settings.appOverrides
    }

    /// The bundle ID selected for editing (nil = Global).
    private var selectedBundleID: String? {
        settings.activeAppOverride?.bundleID
    }

    /// True when the frontmost app has a registered override.
    private var frontmostHasOverride: Bool {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return settings.appOverrides.contains { $0.bundleID == bid }
    }

    /// Display name + bundle ID of the frontmost app (for the Add button label).
    private var frontmostApp: (name: String, bundleID: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bid = app.bundleIdentifier
        else { return nil }
        return (app.localizedName ?? bid, bid)
    }

    private var canAddFrontmostApp: Bool {
        guard let (_, bid) = frontmostApp else { return false }
        return !settings.appOverrides.contains { $0.bundleID == bid }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                overrideChipRow
                Spacer(minLength: 8)
                if canAddFrontmostApp {
                    addButton
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(NSColor.controlBackgroundColor))

            if let override = settings.activeAppOverride {
                overrideBanner(override)
            }

            Divider()
        }
    }

    // MARK: - Chip row

    private var overrideChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                chip(
                    label: "Global",
                    icon: nil,
                    bundleID: nil,
                    isSelected: selectedBundleID == nil
                )
                ForEach(allOverrides) { override in
                    chip(
                        label: override.appName,
                        icon: appIcon(bundleID: override.bundleID),
                        bundleID: override.bundleID,
                        isSelected: selectedBundleID == override.bundleID,
                        domainKeyCount: override.overriddenKeys.intersection(domainKeys).count,
                        onRemove: {
                            settings.removeAppOverride(
                                bundleID: override.bundleID,
                                keyScope: domainKeys)
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func chip(
        label: String,
        icon: NSImage?,
        bundleID: String?,
        isSelected: Bool,
        domainKeyCount: Int = 0,
        onRemove: (() -> Void)? = nil
    ) -> some View {
        Button {
            settings.selectAppOverride(bundleID: bundleID)
        } label: {
            HStack(spacing: 4) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable().scaledToFit()
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? .white : Color.secondary)
                }
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                if domainKeyCount > 0 && !isSelected {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                }
                if let onRemove, !isSelected {
                    Button {
                        onRemove()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected
                    ? Color.accentColor
                    : Color(NSColor.controlColor)
            )
            .foregroundStyle(isSelected ? .white : Color.primary)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? Color.clear : Color(NSColor.separatorColor),
                        lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Add button

    private var addButton: some View {
        Button {
            settings.addAppOverrideForFrontmostApp()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                if let (name, _) = frontmostApp {
                    Text("Add \(name)")
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help("Add per-app override for the frontmost application")
    }

    // MARK: - Override banner

    private func overrideBanner(_ override: TabletSettings.AppOverride) -> some View {
        HStack(spacing: 6) {
            if let icon = appIcon(bundleID: override.bundleID) {
                Image(nsImage: icon)
                    .resizable().scaledToFit()
                    .frame(width: 14, height: 14)
            }
            Text("Editing **\(override.appName)** settings")
                .font(.caption)
            Text("· changes apply only when \(override.appName) is active")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reset") {
                settings.removeAppOverride(bundleID: override.bundleID, keyScope: domainKeys)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove all \(override.appName) overrides for this tab")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: - App icon helper

    private func appIcon(bundleID: String) -> NSImage? {
        guard let path = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleID)?.path
        else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }
}
