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
import UniformTypeIdentifiers

/// Per-tab application override selector.
///
/// Displays a horizontal row of app chips — "Global" plus one chip per app that
/// has a registered override for this tab.  A "+" menu lets the user pick from
/// currently-running apps or browse with an Open panel.  The chip row also acts
/// as a drop well: dragging any .app from Finder, Spotlight, or the Dock adds it
/// as an override target.
///
/// Domain keys identify which settings belong to the enclosing tab:
///   - Tablet Area:   areaKeys
///   - Pressure:      pressureKeys
///   - Buttons:       buttonKeys
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

    @State private var isDropTargeted = false

    private var selectedBundleID: String? { settings.activeAppOverride?.bundleID }

    /// Running GUI apps, excluding MockTab itself and those already registered.
    private var addableRunningApps: [NSRunningApplication] {
        let myBundleID = Bundle.main.bundleIdentifier ?? ""
        let registered = Set(settings.appOverrides.map(\.bundleID))
        return NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular
                && ($0.bundleIdentifier ?? "") != myBundleID
                && !registered.contains($0.bundleIdentifier ?? "")
                && $0.bundleIdentifier != nil
                && $0.localizedName != nil
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                chipRow
                    .onDrop(
                        of: [UTType.applicationBundle, UTType.fileURL],
                        isTargeted: $isDropTargeted,
                        perform: handleDrop)
                    .overlay(
                        isDropTargeted
                            ? RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                                .padding(.vertical, 2)
                            : nil
                    )
                Spacer(minLength: 8)
                addMenu
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

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                appChip(
                    label: "Global",
                    icon: nil,
                    bundleID: nil,
                    isSelected: selectedBundleID == nil)
                ForEach(settings.appOverrides) { override in
                    appChip(
                        label: override.appName,
                        icon: appIcon(bundleID: override.bundleID),
                        bundleID: override.bundleID,
                        isSelected: selectedBundleID == override.bundleID,
                        domainKeyCount: override.overriddenKeys.intersection(domainKeys).count,
                        onRemove: {
                            settings.removeAppOverride(
                                bundleID: override.bundleID,
                                keyScope: domainKeys)
                        })
                }
            }
        }
    }

    @ViewBuilder
    private func appChip(
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
            .background(isSelected ? Color.accentColor : Color(NSColor.controlColor))
            .foregroundStyle(isSelected ? .white : Color.primary)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? Color.clear : Color(NSColor.separatorColor),
                        lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Add menu

    private var addMenu: some View {
        Menu {
            let running = addableRunningApps
            if running.isEmpty {
                Text("No other apps running")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(running, id: \.bundleIdentifier) { app in
                    Button {
                        addApp(bundleID: app.bundleIdentifier!, name: app.localizedName!)
                    } label: {
                        if let icon = app.icon {
                            Label {
                                Text(app.localizedName!)
                            } icon: {
                                Image(nsImage: icon)
                            }
                        } else {
                            Text(app.localizedName!)
                        }
                    }
                }
                Divider()
            }
            Button("Other…") { browseForApp() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
        .help("Add per-app override — or drag an app here from Finder or the Dock")
    }

    // MARK: - Drag-and-drop

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let u = item as? URL {
                        url = u
                    } else {
                        url = nil
                    }
                    if let url, let (bid, name) = bundleInfo(fromAppURL: url) {
                        Task { @MainActor in
                            addApp(bundleID: bid, name: name)
                        }
                    }
                }
                handled = true
            }
        }
        return handled
    }

    // MARK: - Browse with Open panel

    private func browseForApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.message = "Select an app to add a per-app override for"
        panel.prompt = "Add Override"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let (bid, name) = bundleInfo(fromAppURL: url) {
            addApp(bundleID: bid, name: name)
        }
    }

    // MARK: - Helpers

    private func addApp(bundleID: String, name: String) {
        settings.addAppOverride(bundleID: bundleID, appName: name)
    }

    private func bundleInfo(fromAppURL url: URL) -> (bundleID: String, name: String)? {
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier
        else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return (bundleID, name)
    }

    private func appIcon(bundleID: String) -> NSImage? {
        guard let path = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleID)?.path
        else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
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
}
