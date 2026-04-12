// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026 This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab. If not, see <https://www.gnu.org/licenses/>.

// Requires macOS 13+ for .draggable / .dropDestination.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Scroll-tracking preference keys

private struct ChipScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ChipContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - AppOverrideBar

/// Per-tab application override selector.
///
/// Displays a horizontal, scrollable row of app chips — "Global" plus one chip per
/// app that has a registered override for this tab.
///
/// **Layout:**
/// The ScrollView spans the full bar width so the scrollbar track runs edge to edge.
/// Chip content is inset by `chipHorizontalPadding` on the leading side and by
/// `addMenuSlotWidth` on the trailing side, reserving clearance for the addMenu panel.
///
/// The addMenu panel is a `.topTrailing` overlay on the ScrollView, constrained to
/// `chipAreaHeight` — the height of the chip row only, derived from `chipIconSize` and
/// the bar's padding constants. This ensures the panel sits flush with the chips and
/// never overlaps the scrollbar track that may appear below in legacy-scrollbar mode.
/// Within the panel the button fills its full height (minus a 2 pt inset each side) so
/// it reads as a sibling of the chips, anchored permanently at the trailing edge.
///
/// **Tap vs Drag (tablet-optimized):**
/// - Quick tap → instantly selects the override (primary action).
/// - Long-press (~0.45 s) then drag → shows ghost preview and allows reordering.
///   `maximumDistance` is widened from the 10 pt default to absorb stylus jitter.
///
/// **Overflow indication:**
/// Gradient-fade overlays signal clipped content when overlay scrollbars are active.
/// Suppressed when "Always show scrollbars" is set — the track is the indicator there.
///
/// **Drag-over feedback:**
/// The hovered drop-target chip springs open a gap to its left before the drop lands.
///
/// **Chip appearance:**
/// Unselected chips use a dynamic fill with explicit light/dark values so they read
/// clearly against the bar background in both appearances.
///
/// **Icon-size plumbing:**
/// All chip icon geometry derives from `chipIconSize`. Bumping it scales chip height
/// and `chipAreaHeight` together, keeping the addMenu panel correctly sized.
///
/// Right-click provides Rename / Reveal in Finder / Remove.
struct AppOverrideBar: View {

    // MARK: - Domain key sets

    static let areaKeys: Set<String> = [
        "activeAreaX", "activeAreaY", "activeAreaWidth", "activeAreaHeight",
        "proportionalMapping", "tabletOrientation",
        "targetDisplayIndex", "toggleDisplayIDs",
    ]

    static let orientationKeys: Set<String> = [
        "tabletOrientation",
    ]

    static let pressureKeys: Set<String> = [
        "pressureCurve", "smoothingStrength", "doubleClickDistance", "invertRotation",
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

    @State private var isDropTargeted     = false
    @State private var dragEnabledID:     String? = nil
    @State private var dragHoverTargetID: String? = nil

    @State private var chipScrollOffset:  CGFloat = 0
    @State private var chipContentWidth:  CGFloat = 0
    @State private var chipViewportWidth: CGFloat = 0

    private var canScrollLeading: Bool { chipScrollOffset < -2 }
    private var canScrollTrailing: Bool {
        guard chipContentWidth > chipViewportWidth else { return false }
        return chipScrollOffset > -(chipContentWidth - chipViewportWidth) + 2
    }

    @State private var alwaysShowScrollbars = (NSScroller.preferredScrollerStyle == .legacy)

    @State private var renamingBundleID: String?   = nil
    @State private var renameText                  = ""
    @State private var pendingDropURLs:    [URL]   = []
    @State private var showMultiDropAlert          = false
    @State private var cachedRunningApps: [NSRunningApplication] = []

    private var selectedBundleID: String? { settings.activeAppOverride?.bundleID }

    // MARK: - Constants

    private let longPressDuration:      TimeInterval = 0.2  // ← Tune (try 0.4–0.55)
    private let longPressMaxDrift:      CGFloat      = 16    // ← Tune (try 16–30); default 10 too tight for tablet
    private let dragHoverGap:           CGFloat      = 20

    private let chipVerticalPadding:    CGFloat      = 7
    private let chipHorizontalPadding:  CGFloat      = 14

    // Chip's own internal vertical padding (the .padding(.vertical, 4) in chipContent).
    // Stored here so chipAreaHeight can reference it without inspecting the view body.
    private let chipInternalVPadding:   CGFloat      = 4

    // Trailing content inset: keeps the last chip clear of the addMenu panel's solid area.
    // Solid area = addMenuButtonWidth (28) + chipHorizontalPadding (14) = 42 pt.
    // The 20 pt leading fade is semi-transparent, so chips there remain partially visible.
    private let addMenuSlotWidth:       CGFloat      = 42
    private let addMenuButtonWidth:     CGFloat      = 28
    private let addMenuPanelFadeWidth:  CGFloat      = 20

    // Single knob for chip icon geometry. When going beyond ~18, also consider:
    //   • chipInternalVPadding (currently 4 pt each side)
    //   • chipContent label font (currently 11 pt)
    //   • longPressMaxDrift
    // chipAreaHeight is derived from this, so the panel stays correctly sized automatically.
    private let chipIconSize:           CGFloat      = 20    // ← Tune (e.g. 16, 18, 20)

    // The height of the chip row content area, excluding any scrollbar track.
    //
    // Assumes chipIconSize >= rendered label height (~13 pt at 11 pt font), so the icon
    // drives the chip height. Correct for all values of chipIconSize >= 13.
    // Legacy-mode scrollbar track height (~15 pt) sits below this; the addMenu panel
    // is constrained to this height so it never overlaps the track.
    private var chipAreaHeight: CGFloat {
        chipVerticalPadding * 2 + chipIconSize + chipInternalVPadding * 2
    }

    private static let unselectedChipFill = Color(NSColor(name: nil, dynamicProvider: { appearance in
        let isDark = [NSAppearance.Name.darkAqua,
                      .vibrantDark,
                      .accessibilityHighContrastDarkAqua,
                      .accessibilityHighContrastVibrantDark].contains(appearance.name)
        return isDark
            ? NSColor(white: 0.30, alpha: 1.0)  // #4D4D4D — lighter than the dark bar
            : NSColor(white: 0.90, alpha: 1.0)  // #DBDBDB — clearly grey on the light bar
    }))

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            chipBarRow
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
                Divider()
            }
        }
        .alert(
            "Rename App",
            isPresented: Binding(
                get: { renamingBundleID != nil },
                set: { if !$0 { renamingBundleID = nil } }
            ),
            presenting: renamingBundleID
        ) { bundleID in
            TextField("App name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingBundleID = nil }
            Button("Rename") { commitRename(bundleID: bundleID) }
        }
        .alert("Add Multiple Apps?", isPresented: $showMultiDropAlert, presenting: pendingDropURLs) { urls in
            Button("Add All (\(urls.count))") { addMultipleApps(urls) }
            Button("Add First 3 Only") { addMultipleApps(Array(urls.prefix(3))) }
            Button("Cancel", role: .cancel) {}
        } message: { urls in
            Text("You dropped \(urls.count) apps. Add all of them as overrides?")
        }
        .onAppear { refreshRunningApps() }
        .onChange(of: settings.appOverrides.map(\.bundleID)) { _ in refreshRunningApps() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification))    { _ in refreshRunningApps() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshRunningApps() }
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            alwaysShowScrollbars = (NSScroller.preferredScrollerStyle == .legacy)
        }
    }

    // MARK: - Chip bar row

    /// The addMenu panel is a `.topTrailing` overlay constrained to `chipAreaHeight`.
    ///
    /// `.topTrailing` anchors it to the top of the ScrollView, so in legacy-scrollbar
    /// mode it ends exactly where the chip row ends and the scrollbar track begins.
    /// In overlay-scrollbar mode (default) the ScrollView has no track height, so the
    /// panel fills the whole ScrollView — identical to the chip area. Either way the
    /// scrollbar track is never obscured.
    private var chipBarRow: some View {
        scrollingChipRow
            .overlay(alignment: .topTrailing) {
                addMenuPanel
                    .frame(height: chipAreaHeight)
            }
    }

    // MARK: - addMenu panel

    private var addMenuPanel: some View {
        let barBG = Color(NSColor.controlBackgroundColor)

        return HStack(spacing: 0) {
            // Soft fade: chips slide behind this gradient rather than hard-cutting
            // at the button edge, giving a clean leading-edge transition.
            LinearGradient(
                colors: [barBG.opacity(0), barBG],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: addMenuPanelFadeWidth)
            .allowsHitTesting(false)

            // Button fills the panel height with a small vertical inset so it reads
            // like a chip sibling anchored at the trailing edge of the row.
            addMenu
                .frame(width: addMenuButtonWidth)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 2)
                .padding(.trailing, chipHorizontalPadding)
                .background(barBG)
        }
    }

    // MARK: - Scrolling chip row

    private var scrollingChipRow: some View {
        let barBG    = Color(NSColor.controlBackgroundColor)
        let fadeWidth: CGFloat = 24

        return ScrollView(.horizontal, showsIndicators: true) {
            chipRow
                .padding(.leading,  chipHorizontalPadding)
                .padding(.trailing, addMenuSlotWidth)
                .padding(.vertical, chipVerticalPadding)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: ChipContentWidthKey.self,  value: geo.size.width)
                            .preference(key: ChipScrollOffsetKey.self,
                                        value: geo.frame(in: .named("chipScroll")).minX)
                    }
                )
        }
        .coordinateSpace(name: "chipScroll")
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { chipViewportWidth = geo.size.width }
                    .onChange(of: geo.size.width) { chipViewportWidth = $0 }
            }
        )
        .onPreferenceChange(ChipContentWidthKey.self) { chipContentWidth = $0 }
        .onPreferenceChange(ChipScrollOffsetKey.self) { chipScrollOffset = $0 }
        .overlay(alignment: .leading) {
            if canScrollLeading && !alwaysShowScrollbars {
                LinearGradient(colors: [barBG, barBG.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: fadeWidth)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.15), value: canScrollLeading)
            }
        }
        .overlay(alignment: .trailing) {
            if canScrollTrailing && !alwaysShowScrollbars {
                LinearGradient(colors: [barBG.opacity(0), barBG],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: fadeWidth)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.15), value: canScrollTrailing)
            }
        }
    }

    // MARK: - Chip row

    private var chipRow: some View {
        HStack(spacing: 5) {
            appChip(label: "Global", icon: nil, bundleID: nil, isSelected: selectedBundleID == nil)

            ForEach(settings.appOverrides) { override in
                appChip(
                    label: override.appName,
                    icon: appIcon(bundleID: override.bundleID),
                    bundleID: override.bundleID,
                    isSelected: selectedBundleID == override.bundleID,
                    domainKeyCount: override.overriddenKeys.intersection(domainKeys).count
                )
                .padding(.leading, dragHoverTargetID == override.bundleID ? dragHoverGap : 0)
                .dropDestination(for: String.self) { droppedIDs, _ in
                    guard let sourceID = droppedIDs.first, sourceID != override.bundleID else { return false }
                    reorderChip(from: sourceID, to: override.bundleID)
                    return true
                } isTargeted: { targeted in
                    dragHoverTargetID = targeted ? override.bundleID : nil
                }
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: dragHoverTargetID)
        .animation(.spring(response: 0.3,  dampingFraction: 0.8),  value: settings.appOverrides.map(\.bundleID))
    }

    private func reorderChip(from sourceID: String, to targetID: String) {
        guard let sourceIdx = settings.appOverrides.firstIndex(where: { $0.bundleID == sourceID }),
              let targetIdx = settings.appOverrides.firstIndex(where: { $0.bundleID == targetID })
        else { return }
        settings.reorderAppOverrides(from: sourceIdx, to: targetIdx)
    }

    // MARK: - App chip

    @ViewBuilder
    private func appChip(
        label: String,
        icon: NSImage?,
        bundleID: String?,
        isSelected: Bool,
        domainKeyCount: Int = 0
    ) -> some View {
        // isDragLifted: long press has fired — used for visual feedback only.
        // .draggable is always armed (not gated on this) so the drag recognizer is
        // present from the first touch. Gating it caused a race: the recognizer was
        // added after mouseDown, so it sometimes missed the in-progress press.
        let isDragLifted = bundleID != nil && dragEnabledID == bundleID

        Button {
            settings.selectAppOverride(bundleID: bundleID)
        } label: {
            if let id = bundleID {
                chipContent(label: label, icon: icon, isSelected: isSelected, domainKeyCount: domainKeyCount)
                    .draggable(id) {
                        chipContent(label: label, icon: icon, isSelected: true, domainKeyCount: 0)
                            .shadow(radius: 0, y: 0)
                    }
            } else {
                chipContent(label: label, icon: icon, isSelected: isSelected, domainKeyCount: domainKeyCount)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isDragLifted ? 1.06 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.65), value: isDragLifted)
        .contextMenu {
            if let bundleID {
                Button("Rename…") { renamingBundleID = bundleID; renameText = label }
                Button("Reveal in Finder") { revealInFinder(bundleID: bundleID) }
                Divider()
                Button("Remove", role: .destructive) { settings.removeAppOverride(bundleID: bundleID) }
            }
        }
        .onLongPressGesture(
            minimumDuration: longPressDuration,
            maximumDistance: longPressMaxDrift,
            perform: { dragEnabledID = bundleID },
            onPressingChanged: { pressing in
                if !pressing { dragEnabledID = nil; dragHoverTargetID = nil }
            }
        )
    }

    // MARK: - Chip visual

    @ViewBuilder
    private func chipContent(
        label: String,
        icon: NSImage?,
        isSelected: Bool,
        domainKeyCount: Int
    ) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(nsImage: icon)
                    .resizable().scaledToFit()
                    .frame(width: chipIconSize, height: chipIconSize)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: chipIconSize * 0.77))
                    .frame(width: chipIconSize, height: chipIconSize)
                    .foregroundStyle(isSelected ? .white : Color.secondary)
            }
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
            if domainKeyCount > 0 && !isSelected {
                Circle().fill(Color.accentColor).frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, chipInternalVPadding)
        .background(isSelected ? Color.accentColor : Self.unselectedChipFill)
        .foregroundStyle(isSelected ? .white : Color.primary)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Color(NSColor.separatorColor), lineWidth: 0.5))
    }

    // MARK: - Helpers

    private func commitRename(bundleID: String) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.renameAppOverride(bundleID: bundleID, to: trimmed)
        renamingBundleID = nil
    }

    private func revealInFinder(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSSound.beep(); return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Add menu

    private var addMenu: some View {
        Menu {
            if cachedRunningApps.isEmpty {
                Text("No other apps running").foregroundStyle(.secondary)
            } else {
                ForEach(cachedRunningApps, id: \.bundleIdentifier) { app in
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
            Image(systemName: "plus.app.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Add per-app override — or drag an app here from Finder or the Dock")
    }

    // MARK: - Drop handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let validApps = urls.compactMap { self.bundleInfo(fromAppURL: $0) }
            guard !validApps.isEmpty else { return }
            if validApps.count <= 3 {
                for (bid, name) in validApps { addApp(bundleID: bid, name: name) }
            } else {
                pendingDropURLs = urls
                showMultiDropAlert = true
            }
        }
        return true
    }

    private func addMultipleApps(_ urls: [URL]) {
        for url in urls {
            if let (bid, name) = bundleInfo(fromAppURL: url) { addApp(bundleID: bid, name: name) }
        }
    }

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
        if let (bid, name) = bundleInfo(fromAppURL: url) { addApp(bundleID: bid, name: name) }
    }

    private func addApp(bundleID: String, name: String) {
        guard bundleID != Bundle.main.bundleIdentifier else { return }
        settings.addAppOverride(bundleID: bundleID, appName: name)
    }

    private func bundleInfo(fromAppURL url: URL) -> (bundleID: String, name: String)? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return (bundleID, name)
    }

    private func appIcon(bundleID: String) -> NSImage? {
        guard let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }

    private func refreshRunningApps() {
        let myBundleID = Bundle.main.bundleIdentifier ?? ""
        let registered = Set(settings.appOverrides.map(\.bundleID))
        cachedRunningApps = NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular
                    && ($0.bundleIdentifier ?? "") != myBundleID
                    && !registered.contains($0.bundleIdentifier ?? "")
                    && $0.bundleIdentifier != nil
                    && $0.localizedName != nil
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    // MARK: - Override banner

    private func overrideBanner(_ override: TabletSettings.AppOverride) -> some View {
        HStack(spacing: 6) {
            if let icon = appIcon(bundleID: override.bundleID) {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 14, height: 14)
            }
            Text("Editing **\(override.appName)** settings").font(.settingsLabel)
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
