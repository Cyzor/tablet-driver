// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Requires macOS 13+ for .draggable / .dropDestination.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Scroll-tracking preference key

private struct ChipContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Keyboard proxy (arrow-key navigation, no focus ring)

private struct ChipKeyboardProxy: NSViewRepresentable {
    var focusGeneration: Int
    var onLeft: () -> Void
    var onRight: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> KeyView { KeyView() }

    func updateNSView(_ v: KeyView, context: Context) {
        v.onLeft = onLeft
        v.onRight = onRight
        if context.coordinator.lastGeneration != focusGeneration {
            context.coordinator.lastGeneration = focusGeneration
            DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        }
    }

    class Coordinator { var lastGeneration = -1 }

    class KeyView: NSView {
        var onLeft: (() -> Void)?
        var onRight: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func drawFocusRingMask() {}
        override var focusRingMaskBounds: NSRect { .zero }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123: onLeft?()
            case 124: onRight?()
            default: super.keyDown(with: event)
            }
        }
    }
}

// MARK: - AppOverrideBar

/// Per-tab application override selector.
///
/// Displays a horizontal, scrollable row of app chips — "Global" plus one chip per
/// app that has a registered override for this tab.
///
/// Layout:
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
/// Tap vs Drag (tablet-optimized):
/// - Quick tap → instantly selects the override (primary action).
/// - Long-press (~0.45 s) then drag → shows ghost preview and allows reordering.
/// `maximumDistance` is widened from the 10 pt default to absorb stylus jitter.
///
/// Overflow indication:
/// Gradient-fade overlays signal clipped content when overlay scrollbars are active.
/// Suppressed when "Always show scrollbars" is set — the track is the indicator there.
///
/// Drag-over feedback:
/// The hovered drop-target chip springs open a gap to its left before the drop lands.
///
/// Chip appearance:
/// Unselected chips use the system `.quaternary` hierarchical fill, which tracks
/// light/dark, vibrancy, and Increase Contrast automatically. Selected chips use a
/// tinted-accent treatment (translucent accent fill, accent-colored label) rather
/// than a full opaque accent fill — a Global chip is visible almost continuously,
/// so it should read as "current" without demanding attention. Selected chips also
/// respect whether the containing control is in the key window, so inactive windows
/// get a further-softened selection treatment.
///
/// Icon-size plumbing:
/// All chip icon geometry derives from `chipIconSize`. Bumping it scales chip height
/// and `chipAreaHeight` together, keeping the addMenu panel correctly sized.
///
/// Right-click provides Rename / Reveal in Finder / Remove.
struct AppOverrideBar: View {

    // MARK: - Domain key sets

    static let areaKeys: Set<String> = [
        "activeAreaX", "activeAreaY", "activeAreaWidth", "activeAreaHeight",
        "proportionalMapping", "parallaxOffsetX", "parallaxOffsetY",
        "tabletOrientation",
        "targetDisplayIndex", "toggleDisplayIDs",
    ]

    static let orientationKeys: Set<String> = [
        "tabletOrientation"
    ]

    static let pressureKeys: Set<String> = [
        "pressureCurve", "smoothingStrength", "pressureSmoothingStrength", "pressureThreshold",
        "doubleClickDistance",
        "invertRotation", "relativeCursorMovement", "tipUpAssistDelay", "dragThreshold",
        "useRotationAsTilt", "rotationTiltOffsetDegrees", "rotationTiltMagnitude",
        "panScrollSpeed", "panScrollMomentum",
    ]

    static let buttonKeys: Set<String> = [
        "penButton1Binding", "penButton2Binding",
        "tipBinding", "eraserBinding",
        "expressKeyBindings",
        "touchRingButtonBinding",
        "touchRingSlotsJSON", "touchRingActiveSlotIndex",
    ]

    static let touchKeys: Set<String> = [
        "touchEnabled", "tapToClick", "touchSensitivity",
        "twoFingerScroll", "naturalScrolling", "twoFingerScrollMomentum",
        "pinchZoomEnabled",
        "touchAreaX", "touchAreaY", "touchAreaWidth", "touchAreaHeight",
    ]

    // MARK: - Properties

    @ObservedObject var settings: TabletSettings
    let domainKeys: Set<String>
    let productID: Int?
    /// Restores this pane's fields to shipped defaults on the Global layer.
    /// Shown in the Global chip's context menu only while Global is selected —
    /// applying it to a chip that isn't the active layer would silently write
    /// to whichever layer *is* active instead, since panes read/write through
    /// `settings`/`tool`'s current override, not through the clicked chip.
    var onResetToDefaults: (() -> Void)? = nil

    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isDropTargeted = false
    @State private var dragEnabledID: String? = nil
    @State private var dragHoverTargetID: String? = nil

    @State private var chipContentWidth: CGFloat = 0
    @State private var chipViewportWidth: CGFloat = 0

    // canScrollTrailing is intentionally imprecise: it stays true even when scrolled
    // all the way right, because the alternative (tracking exact offset via a named
    // coordinate space) causes floating-point noise that fires onPreferenceChange on
    // every layout pass, creating a display-rate render loop.
    private var canScrollTrailing: Bool { chipContentWidth > chipViewportWidth }

    @State private var alwaysShowScrollbars = (NSScroller.preferredScrollerStyle == .legacy)

    @State private var chipFocusGeneration: Int = 0

    @State private var iconCache: [String: NSImage] = [:]

    @State private var renamingBundleID: String? = nil
    @State private var renameText = ""
    @State private var lastChipTapTime: [String: TimeInterval] = [:]
    @State private var pendingDropURLs: [URL] = []
    @State private var showMultiDropAlert = false
    @State private var cachedRunningApps: [NSRunningApplication] = []
    /// True while the Option key is held — the banner's Reset button becomes
    /// Remove All. Tracked via a local flagsChanged monitor that lives only
    /// while the banner is on screen.
    @State private var optionKeyDown = false
    @State private var optionKeyMonitor: Any? = nil
    /// True after the first refresh fires. Prevents refreshRunningApps() from
    /// re-running on every pane switch (i.e., every time this bar re-appears
    /// because its tab became the selected one). Without this guard the @State
    /// write from refreshRunningApps() triggers a SwiftUI body re-evaluation on
    /// every tab switch, which causes the GPU compositor to allocate ~400 MB of
    /// IOSurface backing stores on multi-display retina setups.
    @State private var hasRefreshedRunningApps = false

    private var selectedBundleID: String? { settings.activeAppOverride?.bundleID }

    private var isControlActive: Bool {
        controlActiveState == .key
    }

    // MARK: - Constants

    private let longPressDuration: TimeInterval = 0.45
    private let longPressMaxDrift: CGFloat = 18
    private let dragHoverGap: CGFloat = 20

    private let chipVerticalPadding: CGFloat = 7
    private let chipHorizontalPadding: CGFloat = 14

    private let chipInternalVPadding: CGFloat = 4

    private let addMenuSlotWidth: CGFloat = 42
    private let addMenuButtonWidth: CGFloat = 28
    private let addMenuPanelFadeWidth: CGFloat = 20

    private let chipIconSize: CGFloat = 20

    private var chipAreaHeight: CGFloat {
        chipVerticalPadding * 2 + chipIconSize + chipInternalVPadding * 2
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            chipBarRow
                .background(TabletColorTheme.barBackgroundColor(for: productID))
                .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
                .overlay(
                    isDropTargeted
                    ? RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(.vertical, 2)
                    : nil
                )

            Divider()

            if let override = settings.activeAppOverride {
                overrideBanner(override)
                Divider()
            }
        }
        .alert(
            String(localized: "Rename App", comment: "Alert title when renaming an app override"),
            isPresented: Binding(
                get: { renamingBundleID != nil },
                set: { if !$0 { renamingBundleID = nil } }
            ),
            presenting: renamingBundleID
        ) { bundleID in
            TextField(
                String(localized: "App name", comment: "Placeholder text in app rename field"),
                text: $renameText
            )
            Button("Cancel", role: .cancel) {
                renamingBundleID = nil
            }
            Button("Rename") {
                commitRename(bundleID: bundleID)
            }
        }
        .alert(
            String(
                localized: "Add Multiple Apps?",
                comment: "Alert title when user drops multiple apps"
            ),
            isPresented: $showMultiDropAlert,
            presenting: pendingDropURLs
        ) { urls in
            Button(
                String(
                    localized: "Add All (\(urls.count))",
                    comment: "Button label: add all apps from drag drop"
                )
            ) {
                addMultipleApps(urls)
            }

            Button("Add First 3 Only") {
                addMultipleApps(Array(urls.prefix(3)))
            }

            Button("Cancel", role: .cancel) {}
        } message: { urls in
            Text(
                String(
                    localized: "You dropped \(urls.count) apps. Add all of them as overrides?",
                    comment: "Alert when user drag-drops multiple apps into the override bar"
                )
            )
        }
        .onAppear {
            guard !hasRefreshedRunningApps else { return }
            hasRefreshedRunningApps = true
            refreshRunningApps()
        }
        .onChange(of: settings.appOverrides.map(\.bundleID)) { _ in
            refreshRunningApps()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didLaunchApplicationNotification
            )
        ) { _ in
            refreshRunningApps()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didTerminateApplicationNotification
            )
        ) { _ in
            refreshRunningApps()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSScroller.preferredScrollerStyleDidChangeNotification
            )
        ) { _ in
            alwaysShowScrollbars = (NSScroller.preferredScrollerStyle == .legacy)
        }
    }

    // MARK: - Chip bar row

    private var chipBarRow: some View {
        scrollingChipRow
            .overlay(alignment: .topTrailing) {
                addMenuPanel
                    .frame(height: chipAreaHeight)
            }
            .background(
                ChipKeyboardProxy(
                    focusGeneration: chipFocusGeneration,
                    onLeft: { selectAdjacentChip(offset: -1) },
                    onRight: { selectAdjacentChip(offset: 1) }
                )
            )
    }

    // MARK: - addMenu panel

    private var addMenuPanel: some View {
        let barBG = TabletColorTheme.barBackgroundColor(for: productID)

        return HStack(spacing: 0) {
            LinearGradient(
                colors: [barBG.opacity(0), barBG],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: addMenuPanelFadeWidth)
            .allowsHitTesting(false)

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
        let barBG = TabletColorTheme.barBackgroundColor(for: productID)
        let fadeWidth: CGFloat = 24

        // Suppress the scroller knob in overlay mode: its flash animation drives a
        // display-link that fires enqueueHoverUpdateIfNeeded at refresh rate, spiking CPU.
        // Gradient fades already serve as the overflow indicator in overlay mode.
        return ScrollView(.horizontal, showsIndicators: alwaysShowScrollbars) {
            chipRow
                .padding(.leading, chipHorizontalPadding)
                .padding(.trailing, addMenuSlotWidth)
                .padding(.vertical, chipVerticalPadding)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: ChipContentWidthKey.self, value: geo.size.width)
                    }
                )
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { chipViewportWidth = geo.size.width }
                    .onChange(of: geo.size.width) { chipViewportWidth = $0 }
            }
        )
        .onPreferenceChange(ChipContentWidthKey.self) { chipContentWidth = $0 }
        .overlay(alignment: .trailing) {
            if canScrollTrailing && !alwaysShowScrollbars {
                LinearGradient(
                    colors: [barBG.opacity(0), barBG],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: fadeWidth)
                .allowsHitTesting(false)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: canScrollTrailing)
            }
        }
    }

    // MARK: - Chip row

    private var chipRow: some View {
        HStack(spacing: 5) {
            appChip(
                label: String(
                    localized: "Global",
                    comment: "App override bar chip — settings apply to all apps not specifically overridden"
                ),
                icon: nil,
                bundleID: nil,
                isSelected: selectedBundleID == nil
            )

            ForEach(settings.appOverrides) { override in
                appChip(
                    label: override.appName,
                    icon: appIconCached(bundleID: override.bundleID),
                    bundleID: override.bundleID,
                    isSelected: selectedBundleID == override.bundleID,
                    domainKeyCount: override.overriddenKeys.intersection(domainKeys).count
                )
                .padding(.leading, dragHoverTargetID == override.bundleID ? dragHoverGap : 0)
                .dropDestination(for: String.self) { droppedIDs, _ in
                    guard let sourceID = droppedIDs.first, sourceID != override.bundleID else {
                        return false
                    }
                    reorderChip(from: sourceID, to: override.bundleID)
                    return true
                } isTargeted: { targeted in
                    dragHoverTargetID = targeted ? override.bundleID : nil
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.75), value: dragHoverTargetID)
        .animation(
            reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8),
            value: settings.appOverrides.map(\.bundleID)
        )
    }

    private func reorderChip(from sourceID: String, to targetID: String) {
        guard
            let sourceIdx = settings.appOverrides.firstIndex(where: { $0.bundleID == sourceID }),
            let targetIdx = settings.appOverrides.firstIndex(where: { $0.bundleID == targetID })
        else { return }

        settings.reorderAppOverrides(from: sourceIdx, to: targetIdx)
    }

    private func selectAdjacentChip(offset: Int) {
        let ids: [String?] = [nil] + settings.appOverrides.map { Optional($0.bundleID) }
        guard !ids.isEmpty,
              let current = ids.firstIndex(where: { $0 == selectedBundleID })
        else { return }
        let next = (current + offset + ids.count) % ids.count
        settings.selectAppOverride(bundleID: ids[next])
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
        Button {
            let now = Date.timeIntervalSinceReferenceDate
            let key = bundleID ?? "__global__"
            if let prev = lastChipTapTime[key], now - prev < NSEvent.doubleClickInterval {
                lastChipTapTime[key] = nil
                if let bundleID {
                    renamingBundleID = bundleID
                    renameText = label
                }
            } else {
                lastChipTapTime[key] = now
                settings.selectAppOverride(bundleID: bundleID)
                chipFocusGeneration += 1
            }
        } label: {
            if let id = bundleID, dragEnabledID == id {
                chipContent(
                    label: label,
                    icon: icon,
                    isSelected: isSelected,
                    isWindowActive: isControlActive,
                    domainKeyCount: domainKeyCount
                )
                .draggable(id) {
                    chipContent(
                        label: label,
                        icon: icon,
                        isSelected: true,
                        isWindowActive: true,
                        domainKeyCount: 0
                    )
                }
            } else {
                chipContent(
                    label: label,
                    icon: icon,
                    isSelected: isSelected,
                    isWindowActive: isControlActive,
                    domainKeyCount: domainKeyCount
                )
            }
        }
        .buttonStyle(.plain)
        .onLongPressGesture(
            minimumDuration: longPressDuration,
            maximumDistance: longPressMaxDrift,
            perform: { dragEnabledID = bundleID },
            onPressingChanged: { pressing in
                if !pressing {
                    dragEnabledID = nil
                    dragHoverTargetID = nil
                }
            }
        )
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            if let bundleID {
                Button {
                    renamingBundleID = bundleID
                    renameText = label
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }

                Button {
                    revealInFinder(bundleID: bundleID)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }

                if isSelected {
                    Divider()
                    Button {
                        settings.removeAppOverride(bundleID: bundleID, keyScope: domainKeys)
                    } label: {
                        Label("Reset Pane to Defaults", systemImage: "arrow.counterclockwise")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    settings.removeAppOverride(bundleID: bundleID)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } else if isSelected, let onResetToDefaults {
                Button {
                    onResetToDefaults()
                } label: {
                    Label("Reset Pane to Defaults", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    // MARK: - Chip visual

    @ViewBuilder
    private func chipContent(
        label: String,
        icon: NSImage?,
        isSelected: Bool,
        isWindowActive: Bool,
        domainKeyCount: Int
    ) -> some View {
        let showsActiveSelection = isSelected && isWindowActive
        let showsInactiveSelection = isSelected && !isWindowActive

        // Active selection uses a translucent accent tint rather than a full
        // accent fill — the Global chip is visible almost continuously, and a
        // solid accent pill reads as louder than a near-permanent element
        // should. Unselected chips use the system hierarchical fill so light/
        // dark, vibrancy, and Increase Contrast are handled for free.
        let background: AnyShapeStyle = {
            if showsActiveSelection { return AnyShapeStyle(Color(nsColor: .controlAccentColor).opacity(0.22)) }
            if showsInactiveSelection { return AnyShapeStyle(Color(nsColor: .unemphasizedSelectedContentBackgroundColor)) }
            return AnyShapeStyle(.quaternary)
        }()

        let foreground: Color = {
            if showsActiveSelection { return Color(nsColor: .controlAccentColor) }
            if showsInactiveSelection { return Color(nsColor: .unemphasizedSelectedTextColor) }
            return .primary
        }()

        HStack(spacing: 4) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: chipIconSize, height: chipIconSize)
            } else {
                Image(systemName: "globe")
                    .appFont(size: chipIconSize * 0.77)
                    .frame(width: chipIconSize, height: chipIconSize)
                    .foregroundStyle(
                        showsActiveSelection
                            ? Color(nsColor: .controlAccentColor)
                            : Color.secondary
                    )
                    .accessibilityHidden(true)
            }

            Text(label)
                .appFont(size: 11, weight: isSelected ? .medium : .regular)
                .lineLimit(1)

            if domainKeyCount > 0 && !isSelected {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, chipInternalVPadding)
        .background(background)
        .foregroundStyle(foreground)
        .clipShape(Capsule())
        .overlay(
            Capsule().strokeBorder(
                showsActiveSelection ? Color(nsColor: .controlAccentColor).opacity(0.5) : Color(NSColor.separatorColor),
                lineWidth: 0.5
            )
        )
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
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Add menu

    private var addMenu: some View {
        Menu {
            if cachedRunningApps.isEmpty {
                Text("No other apps running")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(cachedRunningApps, id: \.bundleIdentifier) { app in
                    Button {
                        addApp(bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "")
                    } label: {
                        if let bundleID = app.bundleIdentifier,
                            let icon = appIconCached(bundleID: bundleID)
                        {
                            Label {
                                Text(app.localizedName ?? "")
                            } icon: {
                                Image(nsImage: icon)
                            }
                        } else {
                            Text(app.localizedName ?? "")
                        }
                    }
                }
            }

            Divider()

            Button {
                browseForApp()
            } label: {
                Label("Other…", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus.app.fill")
                .appFont(size: 36, weight: .semibold)
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Add per-app override — or drag an app here from Finder or the Dock")
        .accessibilityLabel("Add app override")
    }

    // MARK: - Drop handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    urls.append(url)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let validApps = urls.compactMap { self.bundleInfo(fromAppURL: $0) }
            guard !validApps.isEmpty else { return }

            if validApps.count <= 3 {
                for (bid, name) in validApps {
                    addApp(bundleID: bid, name: name)
                }
            } else {
                pendingDropURLs = urls
                showMultiDropAlert = true
            }
        }

        return true
    }

    private func addMultipleApps(_ urls: [URL]) {
        for url in urls {
            if let (bid, name) = bundleInfo(fromAppURL: url) {
                addApp(bundleID: bid, name: name)
            }
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

        if let (bid, name) = bundleInfo(fromAppURL: url) {
            addApp(bundleID: bid, name: name)
        }
    }

    private func addApp(bundleID: String, name: String) {
        guard bundleID != Bundle.main.bundleIdentifier else { return }
        settings.addAppOverride(bundleID: bundleID, appName: name)
    }

    private func bundleInfo(fromAppURL url: URL) -> (bundleID: String, name: String)? {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
            return nil
        }

        let name =
            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? url.deletingPathExtension().lastPathComponent

        return (bundleID, name)
    }

    private func appIcon(bundleID: String) -> NSImage? {
        guard let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
        else { return nil }

        return Self.downsampledIcon(NSWorkspace.shared.icon(forFile: path), pointSize: chipIconSize)
    }

    private func appIconCached(bundleID: String) -> NSImage? {
        if let hit = iconCache[bundleID] { return hit }
        Task { @MainActor in
            if let img = appIcon(bundleID: bundleID) {
                iconCache[bundleID] = img
            }
        }
        return nil
    }

    /// `NSWorkspace` icons carry every representation up to the app's largest
    /// `.icns` size (often 1024pt+ at retina). Rendered at chip size that's a
    /// lot of wasted GPU-backed surface — rasterizing once to a small bitmap
    /// here, the same way `DisplayMappingView.loadThumbnail` caps wallpaper
    /// thumbnails, keeps the cached icon's backing store proportional to what's
    /// actually drawn on screen.
    private static func downsampledIcon(_ image: NSImage, pointSize: CGFloat, scale: CGFloat = 2) -> NSImage {
        let pixelSize = Int(pointSize * scale)
        guard pixelSize > 0,
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let context = CGContext(
                data: nil, width: pixelSize, height: pixelSize,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            true
        else { return image }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        guard let resized = context.makeImage() else { return image }
        return NSImage(cgImage: resized, size: NSSize(width: pointSize, height: pointSize))
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
            if let icon = appIconCached(bundleID: override.bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            }

            Text(
                String(
                    localized: "Editing \(override.appName) settings",
                    comment: "Label showing which app's settings are being edited"
                )
            )
            .appFont(.settingsLabel)

            Text(
                String(
                    localized: "· changes apply only when \(override.appName) is active",
                    comment: "Note that per-app overrides only apply to the specific app"
                )
            )
            .appFont(.settingsLabel)
            .foregroundStyle(.secondary)

            Spacer()

            Button(
                optionKeyDown
                    ? String(
                        localized: "Remove All",
                        comment: "Override banner button while Option is held — removes every app's overrides for this tablet"
                    )
                    : String(
                        localized: "Reset",
                        comment: "Override banner button — removes this app's overrides for this tab"
                    )
            ) {
                // Read the modifier at click time rather than trusting the
                // displayed state, so a release between render and click
                // can't remove more than the label promised.
                if NSEvent.modifierFlags.contains(.option) {
                    settings.removeAllAppOverrides()
                } else {
                    settings.removeAppOverride(bundleID: override.bundleID, keyScope: domainKeys)
                }
            }
            .appFont(.settingsLabel)
            .controlSize(.small)
            .help(
                optionKeyDown
                    ? String(
                        localized: "Remove every app's overrides for this tablet",
                        comment: "Help: Option-click removes all per-app overrides for this tablet"
                    )
                    : String(
                        localized: "Remove all \(override.appName) overrides for this tab",
                        comment: "Help: remove all per-app overrides for current tab"
                    )
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.08))
        .onAppear {
            optionKeyDown = NSEvent.modifierFlags.contains(.option)
            guard optionKeyMonitor == nil else { return }
            optionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                optionKeyDown = event.modifierFlags.contains(.option)
                return event
            }
        }
        .onDisappear {
            if let optionKeyMonitor { NSEvent.removeMonitor(optionKeyMonitor) }
            optionKeyMonitor = nil
            optionKeyDown = false
        }
    }
}
