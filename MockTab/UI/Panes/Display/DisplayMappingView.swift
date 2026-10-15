// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import TabletKit

struct DisplayMappingView: View {
    @Environment(\.controlActiveState) private var controlActiveState
    var accent: Color { .windowAccent(controlActiveState) }

    @ObservedObject var settings: TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    let instanceKey: DeviceInstanceKey?
    /// Model axis of the bound unit — spec/catalog lookups key on this.
    var productID: Int? { instanceKey?.productID }
    @State var displays: [DisplayInfo] = []
    @State var rangeStart: Int = -1
    /// True while this tab is on-screen. Gates the live refresh below so a
    /// display change doesn't redo the wallpaper-thumbnail decode while
    /// another tab is showing (other tabs stay alive off-screen, same as `InfoView`).
    @State private var isShowing = false
    @State private var screenAreaWindow: ScreenAreaOverlayWindow?
    @State private var windowRef = WindowRef()

    @AppStorage(AppearancePrefs.storageKey) private var textSizeIndex: Int = AppearancePrefs.defaultIndex
    var textScale: CGFloat { AppearancePrefs.scale(forIndex: textSizeIndex) }

    private let modeAll = TabletSettings.displayModeAll  // -1
    let modeToggle = TabletSettings.displayModeToggle  // -2
    let modeSpan = TabletSettings.displayModeSpan  // -3

    /// Whether any connected display is rotated via macOS rotation feature.
    private var hasRotatedDisplay: Bool {
        NSScreen.screens.contains { screen in
            guard let numObj = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            // CGDisplayRotation returns 0, 90, 180, 270. Non-zero means rotated.
            let rotation = CGDisplayRotation(numObj)
            return rotation != 0
        }
    }

    var body: some View {
        let _ = BodyCounter.note("Display")
        SettingsPane(
            settings: settings, tabletManager: tabletManager, registry: registry,
            instanceKey: instanceKey, overrideKeys: AppOverrideBar.areaKeys,
            onResetToDefaults: resetToDefaults
        ) {
            canvasSection
            displayMappingSection
            if hasBrightnessControl {
                brightnessSection
            }
            if let name = cintiqPanelModelName {
                CintiqPanelSection(modelName: name)
            }
            displayRegionSection
        }
        .onAppear {
            displays = DisplayInfo.all()
            isShowing = true
        }
        .onDisappear { isShowing = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            // Same notification InputInjector.swift uses for monitor add/remove/
            // resolution/rearrangement. No reliable notification for wallpaper-only changes.
            if isShowing { displays = DisplayInfo.all() }
        }
    }

    // MARK: - Reset to Defaults

    /// Restores the `AppOverrideBar.areaKeys` fields this pane owns —
    /// `targetDisplayIndex`, `toggleDisplayIDSet`, and the four
    /// `displayRegion*` fields — to their shipped defaults (primary display,
    /// no toggle set, full-display region). The other `areaKeys` fields
    /// (active area, parallax, orientation) belong to `TabletAreaView` and
    /// aren't touched here.
    private func resetToDefaults() {
        applyDisplayReset(index: 0, ids: [], undoIndex: settings.targetDisplayIndex, undoIDs: settings.toggleDisplayIDSet)
        let snap = TabletSettings.AreaSnapshot(
            x: settings.displayRegionX, y: settings.displayRegionY,
            w: settings.displayRegionWidth, h: settings.displayRegionHeight)
        settings.displayRegionX = 0; settings.displayRegionY = 0
        settings.displayRegionWidth = 1; settings.displayRegionHeight = 1
        settings.recordDisplayRegionDrag(before: snap)
    }

    /// Self-recursive so "Reset to Defaults" also redoes: each invocation
    /// applies its `index`/`ids` pair and registers the swap as the next
    /// undo (which, from the redo stack, replays as the next redo).
    private func applyDisplayReset(index: Int, ids: Set<CGDirectDisplayID>, undoIndex: Int, undoIDs: Set<CGDirectDisplayID>) {
        settings.targetDisplayIndex = index
        settings.toggleDisplayIDSet = ids
        settings.record(String(localized: "Reset to Defaults", comment: "Undo action name: restoring a pane's controls to their defaults")) {
            self.applyDisplayReset(index: undoIndex, ids: undoIDs, undoIndex: index, undoIDs: ids)
        }
    }

    /// Gamma choices offered in the dropdown, stored as gamma × 10.
    let gammaChoices: [Int] = [18, 20, 22, 24]

    /// Color-space presets, in the panel's on-screen order (row index = wire
    /// value for `colorModePayload`). Descriptions condensed from the vendor
    /// driver's own tooltips.
    let colorModeChoices: [(name: String, description: String)] = [
        ("Adobe RGB", "A wide color space covering most colors achievable on CMYK printers. Common for print-bound artwork."),
        ("sRGB", "The standard color space for the web and most consumer displays. Common for web-bound artwork."),
        ("REC 709", "A video color space for broadcast and web media; the HDTV standard, with a gamut matching sRGB."),
        ("DCI-P3", "A wide-gamut video color space used mainly for professional cinema projection."),
        ("REC 2020", "A broadcast video color space for ultra-high-resolution 4K/8K displays."),
        ("Pantone®", "A proprietary color space used in the creative industry from design through production."),
        ("Custom", "The panel's user-adjustable color mode."),
    ]

    private var displayMappingSection: some View {
        Section {
            // Warning for rotated displays + rotated tablet
            if hasRotatedDisplay && settings.tabletOrientation != .landscape && settings.tabletOrientation != .landscapeFlipped {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .imageScale(.small)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Display Rotation Detected", comment: "Warning title for rotated display"))
                            .appFont(.subheadline)
                            .fontWeight(.semibold)
                        Text(String(localized: "Rotated display. Check where the pen lands.", comment: "Warning message for rotated display"))
                            .appFont(.settingsLabel)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(6)
            }

            radioRow("Primary display", tag: 0)
                .help("Map the tablet to your main display.")
            ForEach(displays, id: \.listIndex) { info in
                radioRowContent(Text(verbatim: info.pickerLabel), tag: info.listIndex, disabled: false)
                    .help(String(localized: "Map the tablet to \(info.name) only.", comment: "Help: specific display mapping"))
            }
            radioRow("Toggle between displays", tag: modeToggle, disabled: displays.count <= 1)
                .help("Use a button press to cycle the tablet's active mapping between selected displays.")
            radioRow("Span selected displays", tag: modeSpan, disabled: displays.count <= 1)
                .help("Map the tablet across only the selected displays as one continuous surface.")
            radioRow("All — span across all displays", tag: modeAll, disabled: displays.count <= 1)
                .help("Map the tablet across all displays as one continuous surface.")

            if settings.targetDisplayIndex == modeToggle || settings.targetDisplayIndex == modeSpan {
                toggleSection
                if settings.targetDisplayIndex == modeToggle {
                    displayToggleHintRow
                } else if settings.spanRestoreIndex != nil {
                    spanRestoreHintRow
                }
            }
        } header: {
            Text("Display Mapping")
        } footer: {
            Text("The active tablet area maps to the selected display.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Display region (map the tablet onto part of the display)

    /// The single display the mapping currently targets, or nil when the
    /// target is "All Displays", "Toggle", or "Span" — in which case the
    /// whole section is hidden rather than shown disabled, since there's no
    /// one display thumbnail to draw the picker over.
    var targetedDisplay: DisplayInfo? {
        DisplayInfo.targeted(by: settings.displayIndex, in: displays)
    }

    /// Single rect binding over the four `displayRegion*` settings, the form
    /// the shared crop editor consumes — same pattern as `TabletAreaView`'s
    /// `activeAreaBinding`.
    private var displayRegionBinding: Binding<NormalizedRect> {
        Binding(
            get: {
                NormalizedRect(
                    x: settings.displayRegionX, y: settings.displayRegionY,
                    w: settings.displayRegionWidth, h: settings.displayRegionHeight)
            },
            set: { r in
                settings.displayRegionX = r.x
                settings.displayRegionY = r.y
                settings.displayRegionWidth = r.w
                settings.displayRegionHeight = r.h
            }
        )
    }

    /// Real shape of the tablet's active area, which the screen area snaps
    /// to so the whole tablet can be used without calculating proportions.
    private var tabletAreaAspect: Double {
        let surface = settings.tabletOrientation.applying(
            toAspectRatio: tabletManager.surfaceAspectRatio(for: instanceKey))
        return surface * settings.activeAreaWidth / max(settings.activeAreaHeight, 0.001)
    }

    /// Largest tablet-shaped region, kept around the current region's center.
    private func fitScreenAreaToTablet(_ display: DisplayInfo) {
        let before = TabletSettings.AreaSnapshot(
            x: settings.displayRegionX, y: settings.displayRegionY,
            w: settings.displayRegionWidth, h: settings.displayRegionHeight)
        let r = TabletSettings.fittedRegion(
            tabletAspect: tabletAreaAspect,
            displayAspect: Double(display.bounds.width) / Double(max(display.bounds.height, 1)),
            centerX: before.x + before.w / 2, centerY: before.y + before.h / 2)
        settings.displayRegionX = r.x; settings.displayRegionY = r.y
        settings.displayRegionWidth = r.w; settings.displayRegionHeight = r.h
        settings.recordDisplayRegionDrag(before: before)
    }

    private static var matchesTabletLabel: String {
        String(localized: "Matches tablet area", comment: "Badge on the screen-area crop while its shape snaps to the tablet's active area")
    }

    @ViewBuilder
    private var displayRegionSection: some View {
        if let display = targetedDisplay {
            Section {
                NormalizedAreaEditor(
                    aspectRatio: display.bounds.width / max(display.bounds.height, 1),
                    rect: displayRegionBinding,
                    onCommit: { oldRect in
                        settings.recordDisplayRegionDrag(before: TabletSettings.AreaSnapshot(
                            x: oldRect.x, y: oldRect.y, w: oldRect.w, h: oldRect.h))
                    },
                    background: {
                        if let wallpaper = display.wallpaper {
                            GeometryReader { bgGeo in
                                // .aspectRatio(contentMode: .fill) alone
                                // leaves clipped() with no explicit target
                                // rect to clip to — a wallpaper whose aspect
                                // ratio doesn't exactly match the display's
                                // could leave a hairline sliver unfilled at
                                // one edge (visible as a faint stray outline
                                // around the thumbnail). Framing to the
                                // container's own measured size first gives
                                // clipped() a concrete rect, so the image
                                // always fills it exactly.
                                Image(nsImage: wallpaper)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: bgGeo.size.width, height: bgGeo.size.height)
                                    .clipped()
                            }
                        }
                    },
                    overlay: { areaRect, _ in
                        DisplayNameBadge(name: display.name, resolution: display.resolution, areaRect: areaRect)
                    }
                )
                .snapping(to: tabletAreaAspect, label: Self.matchesTabletLabel)
                .speaking(as: String(localized: "Screen Area"), size: .points(display.bounds.size))
                .editMappingMenu { presentMappingSheet() }
                .background(WindowReader(ref: windowRef))
                .frame(height: 130)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))

                HStack {
                    Spacer()
                    Button("Select on Screen…") {
                        beginScreenAreaPicker(for: display)
                    }
                    .buttonStyle(.bordered)
                    .appControlSize(.small)
                    .help("Drag the region directly over your desktop, like the macOS screenshot tool.")

                    Button("Fit to Tablet") { fitScreenAreaToTablet(display) }
                        .buttonStyle(.bordered)
                        .appControlSize(.small)
                        .help("Make the screen area the tablet's shape, as large as the display allows, so none of the tablet goes unused.")

                    Button("Use Whole Screen") {
                        let snap = TabletSettings.AreaSnapshot(
                            x: settings.displayRegionX, y: settings.displayRegionY,
                            w: settings.displayRegionWidth, h: settings.displayRegionHeight)
                        settings.displayRegionX = 0; settings.displayRegionY = 0
                        settings.displayRegionWidth = 1; settings.displayRegionHeight = 1
                        settings.recordDisplayRegionDrag(before: snap)
                    }
                    .buttonStyle(.bordered)
                    .appControlSize(.small)
                    .help("Map the tablet to the entire selected display (undoable).")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            } header: {
                Text("Screen Area")
            } footer: {
                Text("Confines the tablet to part of the screen. The rest becomes unreachable.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// Launch the full-screen crop picker over `display`'s own bounds,
    /// seeded with the current region — always the display's full bounds,
    /// not narrowed by any existing sub-region, so a previously shrunk
    /// region can be expanded back out.
    private func beginScreenAreaPicker(for display: DisplayInfo) {
        let before = TabletSettings.AreaSnapshot(
            x: settings.displayRegionX, y: settings.displayRegionY,
            w: settings.displayRegionWidth, h: settings.displayRegionHeight)
        let window = ScreenAreaOverlayWindow(
            displayBounds: display.bounds,
            initialRect: displayRegionBinding.wrappedValue,
            snapAspect: tabletAreaAspect, snapLabel: Self.matchesTabletLabel,
            onFinish: { result in
                screenAreaWindow = nil
                guard let result else { return }
                settings.displayRegionX = result.x
                settings.displayRegionY = result.y
                settings.displayRegionWidth = result.w
                settings.displayRegionHeight = result.h
                settings.recordDisplayRegionDrag(before: before)
            })
        screenAreaWindow = window
        window.begin()
    }

    private var canvasSection: some View {
        Section {
            displayCanvas
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        } header: {
            PaneSectionHeader("Preview") {
                DeviceNameLabel(tabletManager: tabletManager, registry: registry, instanceKey: instanceKey)
            }
        }
    }

    /// A display's name/resolution badge, styled to match the one `displayCanvas`
    /// draws (name bold, resolution beneath, dark rounded backing) — used
    /// wherever a display thumbnail needs the same identifying label outside
    /// the `Canvas`-based multi-display layout (e.g. the single-display
    /// screen-area editor).
    ///
    /// Centers on the live crop rect, not the full canvas — matching
    /// `TabletAreaView.tabletBadge`, whose badge tracks the crop box as it's
    /// dragged. Clips to `areaRect` and hides once the box is too narrow to
    /// hold the badge, same threshold as `tabletBadge`. Shared with `MappingSheet`.
    struct DisplayNameBadge: View {
        let name: String
        let resolution: String
        let areaRect: CGRect
        @AppStorage(AppearancePrefs.storageKey) private var textSizeIndex: Int = AppearancePrefs.defaultIndex
        private var textScale: CGFloat { AppearancePrefs.scale(forIndex: textSizeIndex) }

        /// Only one display here (no index available), so the fallback tier
        /// is the first word, never an index digit.
        private var showsFullName: Bool {
            let font = NSFont.systemFont(ofSize: AppFontRole.badgeTitle.baseSize * textScale, weight: .bold)
            let info = DisplayInfo(id: 0, listIndex: 0, bounds: .zero, name: name, resolution: resolution, wallpaper: nil)
            return info.labelTier(fitting: areaRect.width - 16, font: font) == .full
        }

        var body: some View {
            if areaRect.width >= 140 {
                let fullName = showsFullName
                VStack(spacing: 2) {
                    Text(fullName ? name : (name.split(separator: " ").first.map(String.init) ?? name))
                        .appFont(.badgeTitle)
                        .bold()
                        .lineLimit(1)
                    if fullName, !resolution.isEmpty {
                        Text(resolution)
                            .appFont(.badgeSubtitle)
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.black.opacity(0.42))
                )
                .frame(maxWidth: areaRect.width - 4)
                .position(x: areaRect.midX, y: areaRect.midY)
                .help(fullName ? "" : name)
            }
        }
    }

    // MARK: - Radio row helper

    @ViewBuilder
    private func radioRow(_ label: LocalizedStringKey, tag: Int, disabled: Bool = false) -> some View {
        radioRowContent(Text(label), tag: tag, disabled: disabled)
    }

    @ViewBuilder
    private func radioRowContent(_ labelView: Text, tag: Int, disabled: Bool) -> some View {
        Button {
            let old = settings.displayTarget
            guard settings.displayIndex != tag else { return }
            settings.selectDisplay(index: tag)
            settings.recordToggle(String(localized: "Display Mapping"), from: old, to: settings.displayTarget) { self.settings.displayTarget = $0 }
        } label: {
            HStack(spacing: 8) {
                NativeRadioIndicator(isSelected: settings.displayIndex == tag)
                    .frame(width: 18, height: 18)
                    .allowsHitTesting(false)
                labelView
                    .foregroundStyle(disabled ? Color.secondary : Color.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        // The drawn radio indicator says which is chosen; VoiceOver needs it too.
        .accessibilityAddTraits(settings.displayIndex == tag ? .isSelected : [])
    }

    // MARK: - Canvas layout

    private var displayCanvas: some View {
        let idx = settings.displayIndex
        let toggleIDSet = settings.toggleDisplayIDSet
        return DisplayArrangementView(
            displays: displays,
            isSelected: { info in
                if idx == modeAll { return true }
                if idx == modeToggle || idx == modeSpan { return toggleIDSet.isEmpty || toggleIDSet.contains(info.id) }
                return idx == info.listIndex
            },
            onTap: { i in
                let flags = NSApplication.shared.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift), displays.count > 1 {
                    // Shift+click extends the current selection (Primary/a
                    // single display, or the existing Toggle/Span set) by a
                    // range — same as Finder, regardless of starting mode.
                    canvasRangeClick(at: i)
                } else if flags.contains(.command), displays.count > 1 {
                    // Cmd+click → build toggle rotation and activate Toggle mode
                    canvasCmdClick(at: i)
                } else {
                    // Plain click → select that specific display
                    let old = settings.displayTarget
                    let newVal = displays[i].listIndex
                    guard settings.displayIndex != newVal else { return }
                    settings.selectDisplay(index: newVal)
                    settings.recordToggle(String(localized: "Display Mapping"), from: old, to: settings.displayTarget) { self.settings.displayTarget = $0 }
                }
            })
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(Text("Mapped displays", comment: "VoiceOver label for the display arrangement canvas"))
        .accessibilityValue(mappedDisplaysSummary)
        .editMappingMenu { presentMappingSheet() }
        .background(WindowReader(ref: windowRef))
        .frame(height: 180)
        .help(canvasHelpText)
        .accessibilityHint(canvasSpokenHint)
    }

    /// The canvas for VoiceOver: which displays the tablet maps to. The
    /// display list above does the choosing.
    private var mappedDisplaysSummary: String {
        let idx = settings.displayIndex
        let ids = settings.toggleDisplayIDSet
        let names: [String]
        if idx == modeAll || ((idx == modeToggle || idx == modeSpan) && ids.isEmpty) {
            names = displays.map(\.name)
        } else if idx == modeToggle || idx == modeSpan {
            names = displays.filter { ids.contains($0.id) }.map(\.name)
        } else {
            names = displays.filter { $0.listIndex == idx }.map(\.name)
        }
        return names.formatted(.list(type: .and))
    }

    private func presentMappingSheet() {
        MappingSheetPresenter.present(
            from: windowRef.window, settings: settings,
            tabletAspect: settings.tabletOrientation.applying(
                toAspectRatio: tabletManager.surfaceAspectRatio(for: instanceKey)),
            tabletCaption: registry.caption(forProductID: productID, tabletManager: tabletManager),
            tabletSizeMM: tabletManager.surfaceSizeMM(for: instanceKey),
            destination: MappingDestination.current(for: settings, displays: displays))
    }

    private var canvasHelpText: String {
        if settings.targetDisplayIndex == modeToggle || settings.targetDisplayIndex == modeSpan {
            return String(localized: "⌘+click to add or remove a display from the selection. ⇧+click to select a range.", comment: "Help text for the display canvas while in Toggle or Span mode")
        }
        return String(localized: "Click a display to map the tablet to it. ⌘+click to add it to the toggle rotation. ⇧+click to span all displays.", comment: "Help text for the display canvas in single-display modes")
    }

    /// `canvasHelpText` with key names in place of symbols, for VoiceOver.
    private var canvasSpokenHint: String {
        if settings.targetDisplayIndex == modeToggle || settings.targetDisplayIndex == modeSpan {
            return String(localized: "Command-click to add or remove a display from the selection. Shift-click to select a range.", comment: "VoiceOver hint for the display canvas while in Toggle or Span mode")
        }
        return String(localized: "Click a display to map the tablet to it. Command-click to add it to the toggle rotation. Shift-click to span all displays.", comment: "VoiceOver hint for the display canvas in single-display modes")
    }
}
