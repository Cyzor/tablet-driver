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

// MARK: - ChipFrameKey

/// Collects each app chip's frame (in the "chipRow" coordinate space) so
/// the reorder drag can compute insertion position from measured positions
/// rather than estimated widths.
private struct ChipFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - AppOverrideBar

/// Per-tab application override selector.
///
/// Displays a horizontal row of app chips — "Global" plus one chip per app that
/// has a registered override for this tab.  A "+" menu lets the user pick from
/// currently-running apps or browse with an Open panel.  The chip row also acts
/// as a drop well: dragging any .app from Finder, Spotlight, or the Dock adds it
/// as an override target.
///
/// App chips can be reordered by dragging horizontally.  Dragging a chip far
/// enough vertically (≥50 pt) triggers a Dock-style removal hint — the chip
/// turns red and shows an × — and releasing at that point removes the override.
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

    // App-file drop state
    @State private var isDropTargeted = false

    // Rename alert state
    @State private var renamingBundleID: String? = nil
    @State private var renameText = ""

    // Drag-to-reorder / drag-to-remove state
    @State private var draggingBundleID: String? = nil
    @State private var dragTranslation: CGSize = .zero
    @State private var chipFrames: [String: CGRect] = [:]

    private let removalThreshold: CGFloat = 50

    private var selectedBundleID: String? { settings.activeAppOverride?.bundleID }

    private var isRemovalHinted: Bool {
        draggingBundleID != nil && abs(dragTranslation.height) > removalThreshold
    }

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
                Spacer(minLength: 8)
                addMenu
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(NSColor.controlBackgroundColor))
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
            .overlay(
                isDropTargeted
                    ? RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(.vertical, 2)
                    : nil
            )

            if let override = settings.activeAppOverride {
                overrideBanner(override)
            }

            Divider()
        }
    }

    // MARK: - Chip row

    private var chipRow: some View {
        HStack(spacing: 5) {
            // Global chip — not draggable
            appChip(label: "Global", icon: nil, bundleID: nil, isSelected: selectedBundleID == nil)

            ForEach(settings.appOverrides) { override in
                let isDragging   = draggingBundleID == override.bundleID
                let hinted       = isDragging && isRemovalHinted

                appChip(
                    label: override.appName,
                    icon: appIcon(bundleID: override.bundleID),
                    bundleID: override.bundleID,
                    isSelected: selectedBundleID == override.bundleID,
                    domainKeyCount: override.overriddenKeys.intersection(domainKeys).count,
                    removalHinted: hinted
                )
                // Measure position for insertion-index computation.
                // Skip measurement during drag to avoid preference feedback loop.
                .background(
                    draggingBundleID == nil ? (
                        AnyView(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ChipFrameKey.self,
                                    value: [override.bundleID: geo.frame(in: .named("chipRow"))])
                            }
                        )
                    ) : AnyView(Color.clear)
                )
                // Dragged chip follows the finger; others shift to show insertion gap.
                .offset(
                    x: isDragging ? dragTranslation.width  : chipShiftX(for: override.bundleID),
                    y: isDragging ? dragTranslation.height : 0
                )
                // Lift dragged chip; spring-animate neighbors.
                .scaleEffect(isDragging ? (hinted ? 0.88 : 1.06) : 1.0)
                .opacity(hinted ? 0.45 : 1.0)
                .animation(
                    draggingBundleID == nil ? .spring(response: 0.3, dampingFraction: 0.8) : nil,
                    value: dragTranslation
                )
                .zIndex(isDragging ? 1 : 0)
                .highPriorityGesture(reorderGesture(for: override.bundleID))
            }
        }
        .coordinateSpace(name: "chipRow")
        .onPreferenceChange(ChipFrameKey.self) { chipFrames = $0 }
    }

    // MARK: - Drag gesture

    private func reorderGesture(for bundleID: String) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("chipRow"))
            .onChanged { value in
                if draggingBundleID == nil { draggingBundleID = bundleID }
                guard draggingBundleID == bundleID else { return }
                dragTranslation = value.translation
            }
            .onEnded { value in
                defer {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        draggingBundleID = nil
                        dragTranslation  = .zero
                    }
                }
                guard draggingBundleID == bundleID else { return }

                if abs(value.translation.height) > removalThreshold {
                    settings.removeAppOverride(bundleID: bundleID)
                } else {
                    let targetIdx = insertionIndex(for: bundleID)
                    if let sourceIdx = settings.appOverrides.firstIndex(where: { $0.bundleID == bundleID }),
                       targetIdx != sourceIdx {
                        settings.reorderAppOverrides(from: sourceIdx, to: targetIdx)
                    }
                }
            }
    }

    // MARK: - Insertion-index helpers

    /// Returns the index in `appOverrides` where the dragged chip would be inserted,
    /// based on which chip center is closest to the current drag position.
    private func insertionIndex(for bundleID: String) -> Int {
        guard let sourceFrame = chipFrames[bundleID],
              let sourceIdx   = settings.appOverrides.firstIndex(where: { $0.bundleID == bundleID })
        else { return 0 }

        let draggedCenterX = sourceFrame.midX + dragTranslation.width
        var bestIdx  = sourceIdx
        var bestDist = CGFloat.infinity

        for (idx, override) in settings.appOverrides.enumerated() {
            if let frame = chipFrames[override.bundleID] {
                let dist = abs(frame.midX - draggedCenterX)
                if dist < bestDist { bestDist = dist; bestIdx = idx }
            }
        }
        return bestIdx
    }

    /// Horizontal shift applied to non-dragged chips to open or close the insertion gap.
    private func chipShiftX(for bundleID: String) -> CGFloat {
        guard let dragID    = draggingBundleID,
              dragID != bundleID,
              !isRemovalHinted,
              let sourceIdx = settings.appOverrides.firstIndex(where: { $0.bundleID == dragID }),
              let thisIdx   = settings.appOverrides.firstIndex(where: { $0.bundleID == bundleID }),
              let dragFrame = chipFrames[dragID]
        else { return 0 }

        let targetIdx    = insertionIndex(for: dragID)
        let draggedWidth = dragFrame.width + 5  // chip width + gap

        if targetIdx > sourceIdx && thisIdx > sourceIdx && thisIdx <= targetIdx {
            return -draggedWidth   // shift left to make room on the right
        } else if targetIdx < sourceIdx && thisIdx < sourceIdx && thisIdx >= targetIdx {
            return  draggedWidth   // shift right to make room on the left
        }
        return 0
    }

    // MARK: - App chip

    @ViewBuilder
    private func appChip(
        label: String,
        icon: NSImage?,
        bundleID: String?,
        isSelected: Bool,
        domainKeyCount: Int = 0,
        removalHinted: Bool = false
    ) -> some View {
        Button { settings.selectAppOverride(bundleID: bundleID) } label: {
            ZStack {
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
                }
                .opacity(removalHinted ? 0.25 : 1.0)

                // Removal hint × badge
                if removalHinted {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                removalHinted ? Color.red.opacity(0.85)
                    : (isSelected ? Color.accentColor : Color(NSColor.controlColor))
            )
            .foregroundStyle(isSelected || removalHinted ? .white : Color.primary)
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(
                    (isSelected || removalHinted) ? Color.clear : Color(NSColor.separatorColor),
                    lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let bundleID {
                Button("Rename…") {
                    renamingBundleID = bundleID
                    renameText = label
                }
                Divider()
                Button("Remove", role: .destructive) {
                    settings.removeAppOverride(bundleID: bundleID)
                }
            }
        }
        .alert(
            "Rename App",
            isPresented: .constant(renamingBundleID != nil),
            presenting: renamingBundleID
        ) { bid in
            TextField("App name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingBundleID = nil }
            Button("Rename") { commitRename(bundleID: bid) }
        }
    }

    private func commitRename(bundleID: String) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.renameAppOverride(bundleID: bundleID, to: trimmed)
        renamingBundleID = nil
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
                            Label { Text(app.localizedName!) } icon: { Image(nsImage: icon) }
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

    // MARK: - External .app drop

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
            return false
        }
        provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, let (bid, name) = bundleInfo(fromAppURL: url) else { return }
            Task { @MainActor in addApp(bundleID: bid, name: name) }
        }
        return true
    }

    // MARK: - Open panel

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
        // Prefer CFBundleName (concise) over CFBundleDisplayName (marketing bloat)
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
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
                .font(.settingsLabel)
            Text("· changes apply only when \(override.appName) is active")
                .font(.settingsLabel)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reset") {
                settings.removeAppOverride(bundleID: override.bundleID, keyScope: domainKeys)
            }
            .font(.settingsLabel)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove all \(override.appName) overrides for this tab")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.08))
    }
}
