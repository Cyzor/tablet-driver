// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import SwiftUI
import TabletKit

struct DisplayMappingView: View {
    @ObservedObject var settings: TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    let instanceKey: DeviceInstanceKey?
    /// Model axis of the bound unit — spec/catalog lookups key on this.
    private var productID: Int? { instanceKey?.productID }
    @State private var displays: [DisplayInfo] = []
    @State private var rangeStart: Int = -1
    /// True while this tab is on-screen. Gates the live refresh below so a
    /// display change doesn't redo the wallpaper-thumbnail decode while
    /// another tab is showing (other tabs stay alive off-screen, same as `InfoView`).
    @State private var isShowing = false
    @State private var screenAreaWindow: ScreenAreaOverlayWindow?

    @AppStorage(AppearancePrefs.storageKey) private var textSizeIndex: Int = AppearancePrefs.defaultIndex
    private var textScale: CGFloat { AppearancePrefs.scale(forIndex: textSizeIndex) }

    private let modeAll = TabletSettings.displayModeAll  // -1
    private let modeToggle = TabletSettings.displayModeToggle  // -2
    private let modeSpan = TabletSettings.displayModeSpan  // -3

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

    // MARK: - Built-in display brightness

    /// True when the selected tablet is a pen display whose panel brightness
    /// the driver can set (Xencelabs). Decided from the device spec, not the
    /// live connection, so the section stays visible — disabled — while the
    /// display is unplugged or asleep.
    private var hasBrightnessControl: Bool {
        guard let pid = productID, let spec = TabletManager.staticSpec(forProductID: pid)
        else { return false }
        return spec.parser == .xencelabs && spec.isPenDisplay
    }

    private var brightnessDeviceConnected: Bool {
        guard let ctx = tabletManager.context(forKey: instanceKey) else { return false }
        return ctx.isConnected
    }

    /// True only once the user has explicitly picked Custom/User Mode —
    /// contrast/gamma stay hidden under the parked default (a named preset)
    /// since writing them there corrupts the preset's own color transform.
    private var isCustomColorModeSelected: Bool {
        settings.displayColorMode == TabletSettings.displayColorModeCustomIndex
    }

    /// Gamma choices offered in the dropdown, stored as gamma × 10.
    private let gammaChoices: [Int] = [18, 20, 22, 24]

    /// Color-space presets, in the panel's on-screen order (row index = wire
    /// value for `colorModePayload`). Descriptions condensed from the vendor
    /// driver's own tooltips.
    private let colorModeChoices: [(name: String, description: String)] = [
        ("Adobe RGB", "A wide color space covering most colors achievable on CMYK printers. Common for print-bound artwork."),
        ("sRGB", "The standard color space for the web and most consumer displays. Common for web-bound artwork."),
        ("REC 709", "A video color space for broadcast and web media; the HDTV standard, with a gamut matching sRGB."),
        ("DCI-P3", "A wide-gamut video color space used mainly for professional cinema projection."),
        ("REC 2020", "A broadcast video color space for ultra-high-resolution 4K/8K displays."),
        ("Pantone®", "A proprietary color space used in the creative industry from design through production."),
        ("Custom", "The panel's user-adjustable color mode."),
    ]

    private var brightnessSection: some View {
        Section {
            // Dimmed on the content only, never the whole Section:
            // `.disabled()` by itself leaves labels and readouts at full
            // strength (AppKit only drops the controls' accent tint), so
            // without this the section reads as available. Putting the
            // opacity on the Section instead would fade the footer too —
            // and that footer is what explains *why* this is unavailable,
            // so it has to stay the most legible thing here.
            Group {
                HStack {
                    Image(systemName: "sun.max")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Brightness")
                    Slider(
                        value: settings.recordingBinding(
                            String(localized: "Display Brightness", comment: "Undo action name: display calibration/mapping control in the Displays pane"),
                            // Before the user ever touches the slider (-1), park
                            // the knob at the vendor default without sending.
                            get: { Double(settings.displayBrightness >= 0 ? settings.displayBrightness : 75) },
                            set: { settings.displayBrightness = Int($0.rounded()) }),
                        in: 0...100)
                    Text(settings.displayBrightness >= 0 ? "\(settings.displayBrightness)%" : "—")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .scaledFrame(width: 48, alignment: .trailing)
                }
                .help("Backlight brightness of the tablet's built-in display. The hardware keeps its own value until you move the slider.")

                HStack {
                    Image(systemName: "paintpalette")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Color Space")
                    Spacer()
                    Picker("Color Space", selection: settings.recordingBinding(
                        String(localized: "Display Color Space", comment: "Undo action name: display calibration/mapping control in the Displays pane"),
                        get: { settings.displayColorMode >= 0 ? settings.displayColorMode : 0 },
                        set: { settings.displayColorMode = $0 })) {
                        ForEach(colorModeChoices.indices, id: \.self) { i in
                            Text(colorModeChoices[i].name).tag(i)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .help(colorModeChoices[
                    settings.displayColorMode >= 0 && settings.displayColorMode < colorModeChoices.count
                        ? settings.displayColorMode : 0
                ].description)

                // Contrast/gamma are only meaningful in Custom mode — named
                // presets (Adobe RGB, sRGB, etc.) own these internally, and the
                // vendor driver doesn't expose them outside Custom either.
                if isCustomColorModeSelected {
                    HStack {
                        Image(systemName: "circle.lefthalf.filled")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Contrast")
                        Slider(
                            value: settings.recordingBinding(
                                String(localized: "Display Contrast", comment: "Undo action name: display calibration/mapping control in the Displays pane"),
                                get: { Double(settings.displayContrast >= 0 ? settings.displayContrast : 50) },
                                set: { settings.displayContrast = Int($0.rounded()) }),
                            in: 0...100)
                        Text(settings.displayContrast >= 0 ? "\(settings.displayContrast)%" : "—")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .scaledFrame(width: 48, alignment: .trailing)
                    }
                    .help("Contrast of the tablet's built-in display. The hardware keeps its own value until you change it.")

                    HStack {
                        Image(systemName: "circle.dotted")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Gamma")
                        Spacer()
                        Picker("Gamma", selection: settings.recordingBinding(
                            String(localized: "Display Gamma", comment: "Undo action name: display calibration/mapping control in the Displays pane"),
                            get: { settings.displayGamma >= 0 ? settings.displayGamma : 22 },
                            set: { settings.displayGamma = $0 })) {
                            ForEach(gammaChoices, id: \.self) { value in
                                Text(gammaLabel(value)).tag(value)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .help("Display gamma. The hardware keeps its own value until you change it.")
                }
            }
            .opacity(brightnessDeviceConnected ? 1 : 0.5)
        } header: {
            Text("Built-in Display").appFont(.headline)
        } footer: {
            Text(brightnessDeviceConnected
                ? "Changes the panel's own image controls, like the buttons on the display bezel."
                : "Available when the display is connected.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .disabled(!brightnessDeviceConnected)
    }

    /// Format a gamma-×10 value as its decimal label (22 → "2.2").
    private func gammaLabel(_ timesTen: Int) -> String {
        String(format: "%.1f", Double(timesTen) / 10.0)
    }

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
                        Text(String(localized: "Your display is rotated. Combined with a rotated tablet, this may require adjustment. Test your pen input to verify the mapping is correct.", comment: "Warning message for rotated display"))
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
    private var targetedDisplay: DisplayInfo? {
        let idx = settings.targetDisplayIndex
        guard idx != modeAll, idx != modeToggle, idx != modeSpan else { return nil }
        let resolvedIndex = idx > 0 ? idx : 1  // idx == 0 → "Primary display" → first in `displays`
        return displays.first { $0.listIndex == resolvedIndex } ?? displays.first
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
                .frame(height: 130)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))

                HStack {
                    Spacer()
                    Button("Select on Screen…") {
                        beginScreenAreaPicker(for: display)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Drag the region directly over your desktop, like the macOS screenshot tool.")

                    Button("Fit to Tablet") { fitScreenAreaToTablet(display) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
                    .controlSize(.small)
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
    /// hold the badge, same threshold as `tabletBadge`.
    private struct DisplayNameBadge: View {
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
                    if fullName {
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
            let old = settings.targetDisplayIndex
            guard old != tag else { return }
            settings.targetDisplayIndex = tag
            settings.recordToggle(String(localized: "Display Mapping"), from: old, to: tag) { self.settings.targetDisplayIndex = $0 }
        } label: {
            HStack(spacing: 8) {
                NativeRadioIndicator(isSelected: settings.targetDisplayIndex == tag)
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
    }

    // MARK: - Toggle section

    private var toggleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Active Displays")
                .appFont(.settingsLabel)
                .foregroundStyle(.secondary)
                .help("Click a thumbnail to toggle that display in or out of the rotation. ⌘-click to add individual displays; ⇧-click to select a range.")

            HStack(spacing: 8) {
                ForEach(Array(displays.enumerated()), id: \.element.id) { index, info in
                    toggleThumbnail(at: index, info: info)
                }
                Spacer(minLength: 0)
            }
        }
        .disabled(displays.count <= 1)
    }

    /// Returns the names of buttons currently bound to displayToggle, or nil if none.
    private var displayToggleAssignedLabel: String? {
        var names: [String] = []
        if settings.activeTool.penButton1Binding.kind == .displayToggle { names.append("Pen Button 1") }
        if settings.activeTool.penButton2Binding.kind == .displayToggle { names.append("Pen Button 2") }
        let ekNames = settings.expressKeyBindings.enumerated()
            .filter { $0.element.kind == .displayToggle }
            .map { "Key \($0.offset + 1)" }
        names += ekNames
        if settings.touchRingButtonBinding.kind == .displayToggle { names.append("Ring Button") }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private var displayToggleHintRow: some View {
        let assignedLabel = displayToggleAssignedLabel
        return HStack(spacing: 8) {
            if assignedLabel != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
            }
            Text(assignedLabel.map { String(localized: "Triggered by \($0)", comment: "Label showing which button triggers the display toggle") } ?? String(localized: "No button assigned to toggle", comment: "Label when no button is assigned to display toggle"))
                .foregroundStyle(assignedLabel != nil ? .secondary : .primary)
            Spacer()
            if assignedLabel == nil {
                Button("Set Up") {
                    if let wc = NSApp.keyWindow?.windowController as? SettingsWindowController {
                        wc.showTab(.buttons)
                    } else {
                        SettingsWindowManager.shared.showTab(.buttons)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Go to the Buttons tab to assign a button that triggers the display toggle.")
            }
        }
        .padding(.vertical, 2)
    }

    private func toggleThumbnail(at index: Int, info: DisplayInfo) -> some View {
        let included = isIncluded(info)
        let badgeFont = NSFont.systemFont(ofSize: AppFontRole.badgeTitle.baseSize * textScale, weight: .bold)
        // 76pt chip minus horizontal padding/insets around the badge text.
        let tier = info.labelTier(fitting: 76 - 12, font: badgeFont)
        let chipLabel: String = {
            switch tier {
            case .full: return info.name
            case .firstWord: return info.firstWord
            case .index: return "\(index + 1)"
            }
        }()

        return ZStack {
            // Wallpaper or flat fill
            if let wp = info.wallpaper {
                Image(nsImage: wp)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 76, height: 48)
                    .clipped()
                    .opacity(included ? 0.65 : 0.20)
            } else {
                Rectangle()
                    .fill(
                        included
                            ? Color.accentColor.opacity(0.15)
                            : Color.secondary.opacity(0.07))
            }

            // Include / exclude icon
            Image(systemName: included ? "checkmark.circle.fill" : "xmark.circle.fill")
                .appFont(size: 18)
                .foregroundStyle(included ? Color.green : Color.secondary)
                .shadow(color: .black.opacity(0.4), radius: 1)
                .accessibilityHidden(true)

            // Display name badge
            VStack(spacing: 0) {
                Spacer()
                Text(chipLabel)
                    .appFont(.badgeTitle)
                    .bold()
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    .padding(.bottom, 3)
            }
        }
        .frame(minWidth: 76, minHeight: 48)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(
                    included ? Color.accentColor : Color.secondary.opacity(0.35),
                    lineWidth: included ? 1.5 : 1
                )
        )
        .help(tier == .full ? "" : info.name)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(included ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(Text(String(
            localized: "Display \(info.name), \(included ? "included" : "excluded")",
            comment: "Accessibility label for a display thumbnail in the toggle-display picker"
        )))
        .accessibilityHint("Double tap to toggle inclusion in the display rotation")
        .onTapGesture {
            let flags = NSApplication.shared.currentEvent?.modifierFlags ?? []

            if flags.contains(.shift) {
                // Shift+click: range selection from rangeStart to current index
                if rangeStart < 0 {
                    rangeStart = index
                } else {
                    let start = min(rangeStart, index)
                    let end = max(rangeStart, index)
                    var ids = settings.toggleDisplayIDSet
                    if ids.isEmpty { ids = Set(displays.map(\.id)) }
                    // Include all displays in the range
                    for i in start...end {
                        ids.insert(displays[i].id)
                    }
                    // Simplify back to empty (= all) when every display is included
                    let oldIDs = settings.toggleDisplayIDSet
                    let newIDs = (ids == Set(displays.map(\.id))) ? [] : ids
                    settings.toggleDisplayIDSet = newIDs
                    settings.recordToggle(String(localized: "Toggle Display Set", comment: "Undo action name: display calibration/mapping control in the Displays pane"), from: oldIDs, to: newIDs) { settings.toggleDisplayIDSet = $0 }
                    rangeStart = -1
                }
            } else if flags.contains(.command) {
                // Cmd+click: toggle individual display
                toggleIncluded(info)
            } else {
                // Regular click: toggle individual display
                toggleIncluded(info)
                rangeStart = -1
            }
        }
    }

    // MARK: - Toggle helpers

    private func isIncluded(_ info: DisplayInfo) -> Bool {
        let ids = settings.toggleDisplayIDSet
        return ids.isEmpty || ids.contains(info.id)
    }

    private func toggleIncluded(_ info: DisplayInfo) {
        let oldIDs = settings.toggleDisplayIDSet
        var ids = oldIDs
        if ids.isEmpty {
            // All included implicitly → make explicit so we can exclude one
            ids = Set(displays.map(\.id))
        }
        if ids.contains(info.id) {
            ids.remove(info.id)
            if ids.isEmpty { return }  // never exclude the last display
        } else {
            ids.insert(info.id)
        }
        // Simplify back to empty (= all) when every display is included
        let newIDs = (ids == Set(displays.map(\.id))) ? [] : ids
        settings.toggleDisplayIDSet = newIDs
        // Register undo (and, via recordToggle, redo) for the toggle set change
        settings.recordToggle(String(localized: "Toggle Display Set", comment: "Undo action name: display calibration/mapping control in the Displays pane"), from: oldIDs, to: newIDs) {
            settings.toggleDisplayIDSet = $0
        }
    }

    /// The set to build a new selection from when the click starts outside
    /// Toggle/Span mode: just the single display currently targeted (Primary
    /// resolves to the first display), not every display. Falls back to "all"
    /// only when already in Toggle/Span (where an empty `toggleDisplayIDSet`
    /// already means "all" and should keep meaning that).
    private func seedIDsForNewSelection() -> Set<CGDirectDisplayID> {
        let idx = settings.targetDisplayIndex
        if idx == modeToggle || idx == modeSpan {
            let ids = settings.toggleDisplayIDSet
            return ids.isEmpty ? Set(displays.map(\.id)) : ids
        }
        if let display = targetedDisplay {
            return [display.id]
        }
        // modeAll or no resolvable target: start from everything.
        return Set(displays.map(\.id))
    }

    /// Cmd+click on a canvas rectangle: builds the toggle/span selection
    /// additively. Starting from whatever's currently targeted (a single
    /// display, or the existing Toggle/Span set), the click adds or removes
    /// just the clicked display. Stays in the current mode when it's already
    /// Toggle or Span; otherwise defaults to Toggle.
    private func canvasCmdClick(at index: Int) {
        guard displays.indices.contains(index) else { return }
        let info = displays[index]
        let oldIDs = settings.toggleDisplayIDSet
        let oldDisplayIndex = settings.targetDisplayIndex
        let targetMode = (oldDisplayIndex == modeToggle || oldDisplayIndex == modeSpan) ? oldDisplayIndex : modeToggle
        var ids = seedIDsForNewSelection()
        if ids.contains(info.id) {
            ids.remove(info.id)
            if ids.isEmpty { return }  // never exclude the last display
        } else {
            ids.insert(info.id)
        }
        let newIDs = (ids == Set(displays.map(\.id))) ? [] : ids
        applyToggleDisplaySet(ids: newIDs, index: targetMode, undoIDs: oldIDs, undoIndex: oldDisplayIndex)
    }

    /// Shift+click range-select on a canvas rectangle, mirroring the
    /// thumbnails' range behavior: selects every display between
    /// `rangeStart` and `index`. Stays in the current mode when it's already
    /// Toggle or Span; otherwise defaults to Toggle. The range is added to
    /// whatever's currently targeted (a single display, or the existing
    /// Toggle/Span set) rather than starting from every display. Outside
    /// Toggle/Span, the very first Shift+click needs no priming click first —
    /// it anchors the range at the currently-targeted display (e.g. Primary),
    /// matching Finder's "Shift+click extends from the current selection".
    private func canvasRangeClick(at index: Int) {
        guard displays.indices.contains(index) else { return }
        let oldDisplayIndex = settings.targetDisplayIndex
        if rangeStart < 0 {
            if oldDisplayIndex != modeToggle, oldDisplayIndex != modeSpan, let anchor = targetedDisplay,
                let anchorIndex = displays.firstIndex(where: { $0.id == anchor.id })
            {
                rangeStart = anchorIndex
            } else {
                rangeStart = index
                return
            }
        }
        let targetMode = (oldDisplayIndex == modeToggle || oldDisplayIndex == modeSpan) ? oldDisplayIndex : modeToggle
        let start = min(rangeStart, index)
        let end = max(rangeStart, index)
        let oldIDs = settings.toggleDisplayIDSet
        var ids = seedIDsForNewSelection()
        for i in start...end {
            ids.insert(displays[i].id)
        }
        let newIDs = (ids == Set(displays.map(\.id))) ? [] : ids
        applyToggleDisplaySet(ids: newIDs, index: targetMode, undoIDs: oldIDs, undoIndex: oldDisplayIndex)
        rangeStart = -1
    }

    /// Self-recursive so this also redoes — see `applyDisplayReset`.
    private func applyToggleDisplaySet(ids: Set<CGDirectDisplayID>, index: Int, undoIDs: Set<CGDirectDisplayID>, undoIndex: Int) {
        settings.toggleDisplayIDSet = ids
        settings.targetDisplayIndex = index
        settings.record(String(localized: "Toggle Display Set", comment: "Undo action name: display calibration/mapping control in the Displays pane")) {
            self.applyToggleDisplaySet(ids: undoIDs, index: undoIndex, undoIDs: ids, undoIndex: index)
        }
    }

    // MARK: - Canvas layout

    private var displayCanvas: some View {
        GeometryReader { geo in
            let scale = layoutScale(in: geo.size)
            let offset = layoutOffset(in: geo.size, scale: scale)
            let rects: [CGRect] = displays.map {
                swiftUIRect(for: $0, scale: scale, offset: offset)
            }
            // Pre-compute per-display selection state for use in Canvas closure.
            let idx = settings.targetDisplayIndex
            let toggleIDSet = settings.toggleDisplayIDSet
            let selectedStates: [Bool] = displays.map { info in
                if idx == modeAll { return true }
                if idx == modeToggle || idx == modeSpan { return toggleIDSet.isEmpty || toggleIDSet.contains(info.id) }
                return idx == info.listIndex
            }

            Canvas { ctx, _ in
                for (index, info) in displays.enumerated() {
                    let rect = rects[index]
                    let selected = selectedStates[index]
                    let path = Path(roundedRect: rect, cornerRadius: 3, style: .continuous)

                    if let wallpaper = info.wallpaper {
                        let iSize = wallpaper.size
                        if iSize.width > 0, iSize.height > 0 {
                            let iAspect = iSize.width / iSize.height
                            let rAspect = rect.width / rect.height
                            let drawRect: CGRect
                            if iAspect > rAspect {
                                let w = rect.height * iAspect
                                drawRect = CGRect(
                                    x: rect.midX - w / 2, y: rect.minY,
                                    width: w, height: rect.height)
                            } else {
                                let h = rect.width / iAspect
                                drawRect = CGRect(
                                    x: rect.minX, y: rect.midY - h / 2,
                                    width: rect.width, height: h)
                            }
                            ctx.drawLayer { layer in
                                layer.clip(to: path)
                                layer.draw(Image(nsImage: wallpaper), in: drawRect)
                            }
                        }
                        let scrim: Color =
                            selected
                            ? Color.accentColor.opacity(0.30)
                            : Color.black.opacity(0.15)
                        ctx.fill(path, with: .color(scrim))
                    } else {
                        ctx.fill(
                            path,
                            with: .color(
                                selected
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.secondary.opacity(0.1)
                            ))
                    }

                    ctx.stroke(
                        path,
                        with: .color(
                            selected ? Color.accentColor : Color.secondary.opacity(0.45)
                        ), style: StrokeStyle(lineWidth: selected ? 2 : 1))

                    let hPad: CGFloat = 6
                    let vPad: CGFloat = 4
                    let maxTextW = rect.width - 8
                    let badgeFont = NSFont.systemFont(
                        ofSize: AppFontRole.badgeTitle.baseSize * textScale, weight: .bold)
                    let tier = info.labelTier(fitting: maxTextW - hPad * 2, font: badgeFont)
                    let titleString = tier == .index ? "\(info.listIndex)" : (tier == .firstWord ? info.firstWord : info.name)

                    let nameResolved = ctx.resolve(
                        Text(titleString).font(Font.appFont(.badgeTitle, scale: textScale)).bold().foregroundColor(.white))
                    let measure = CGSize(width: maxTextW, height: 40)
                    let nameSize = nameResolved.measure(in: measure)

                    if tier == .full {
                        let resResolved = ctx.resolve(
                            Text(info.resolution).font(Font.appFont(.badgeSubtitle, scale: textScale)).foregroundColor(.white))
                        let resSize = resResolved.measure(in: measure)

                        let nameY = rect.midY - 8
                        let resY = rect.midY + 8
                        let badgeW = min(
                            max(nameSize.width, resSize.width) + hPad * 2,
                            rect.width - 4)
                        let badge = CGRect(
                            x: rect.midX - badgeW / 2,
                            y: nameY - nameSize.height / 2 - vPad,
                            width: badgeW,
                            height: (resY + resSize.height / 2 + vPad)
                                - (nameY - nameSize.height / 2 - vPad))

                        ctx.drawLayer { layer in
                            layer.clip(to: Path(rect.insetBy(dx: 2, dy: 2)))
                            layer.fill(
                                Path(
                                    roundedRect: badge, cornerRadius: 3,
                                    style: .continuous),
                                with: .color(.black.opacity(0.42)))
                            layer.draw(
                                nameResolved,
                                at: CGPoint(x: rect.midX, y: nameY), anchor: .center)
                            layer.draw(
                                resResolved,
                                at: CGPoint(x: rect.midX, y: resY), anchor: .center)
                        }
                    } else {
                        // Too narrow for both lines — show one centered
                        // line (first word, or a bare index as a last resort).
                        let badgeW = min(nameSize.width + hPad * 2, rect.width - 4)
                        let badge = CGRect(
                            x: rect.midX - badgeW / 2,
                            y: rect.midY - nameSize.height / 2 - vPad,
                            width: badgeW,
                            height: nameSize.height + vPad * 2)

                        ctx.drawLayer { layer in
                            layer.clip(to: Path(rect.insetBy(dx: 2, dy: 2)))
                            layer.fill(
                                Path(
                                    roundedRect: badge, cornerRadius: 3,
                                    style: .continuous),
                                with: .color(.black.opacity(0.42)))
                            layer.draw(
                                nameResolved,
                                at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                        }
                    }
                }
            }
            .onTapGesture { location in
                let flags = NSApplication.shared.currentEvent?.modifierFlags ?? []

                if flags.contains(.shift), displays.count > 1 {
                    // Shift+click extends the current selection (Primary/a
                    // single display, or the existing Toggle/Span set) by a
                    // range — same as Finder, regardless of starting mode.
                    if let i = rects.firstIndex(where: { $0.contains(location) }) {
                        canvasRangeClick(at: i)
                    }

                } else if flags.contains(.command), displays.count > 1 {
                    // Cmd+click → build toggle rotation and activate Toggle mode
                    if let i = rects.firstIndex(where: { $0.contains(location) }) {
                        canvasCmdClick(at: i)
                    }

                } else {
                    // Plain click → select that specific display
                    for (index, rect) in rects.enumerated() where rect.contains(location) {
                        let old = settings.targetDisplayIndex
                        let newVal = displays[index].listIndex
                        guard old != newVal else { break }
                        settings.targetDisplayIndex = newVal
                        settings.recordToggle(String(localized: "Display Mapping"), from: old, to: newVal) { self.settings.targetDisplayIndex = $0 }
                        break
                    }
                }
            }
        }
        .frame(height: 180)
        .help(canvasHelpText)
    }

    private var canvasHelpText: String {
        if settings.targetDisplayIndex == modeToggle || settings.targetDisplayIndex == modeSpan {
            return String(localized: "⌘+click to add or remove a display from the selection. ⇧+click to select a range.", comment: "Help text for the display canvas while in Toggle or Span mode")
        }
        return String(localized: "Click a display to map the tablet to it. ⌘+click to add it to the toggle rotation. ⇧+click to span all displays.", comment: "Help text for the display canvas in single-display modes")
    }

    // MARK: - Coordinate helpers

    private func swiftUIRect(
        for info: DisplayInfo,
        scale: CGFloat,
        offset: CGPoint
    ) -> CGRect {
        // CGDisplayBounds is already top-down (Y increases downward), same as
        // SwiftUI — no flip needed. Flipping it here inverted the vertical
        // stacking order of displays relative to each other.
        return CGRect(
            x: info.bounds.minX * scale + offset.x,
            y: info.bounds.minY * scale + offset.y,
            width: info.bounds.width * scale,
            height: info.bounds.height * scale
        )
    }

    private func layoutScale(in size: CGSize) -> CGFloat {
        guard !displays.isEmpty else { return 1 }
        let unionW = (displays.map(\.bounds.maxX).max()! - displays.map(\.bounds.minX).min()!)
        let unionH = (displays.map(\.bounds.maxY).max()! - displays.map(\.bounds.minY).min()!)
        guard unionW > 0, unionH > 0 else { return 1 }
        return min((size.width - 16) / unionW, (size.height - 16) / unionH)
    }

    private func layoutOffset(in size: CGSize, scale: CGFloat) -> CGPoint {
        guard !displays.isEmpty else { return .zero }
        let minX = displays.map(\.bounds.minX).min()!
        let minY = displays.map(\.bounds.minY).min()!
        let maxY = displays.map(\.bounds.maxY).max()!
        let scaledW = (displays.map(\.bounds.maxX).max()! - minX) * scale
        let scaledH = (maxY - minY) * scale
        return CGPoint(
            x: (size.width - scaledW) / 2 - minX * scale,
            y: (size.height - scaledH) / 2 - minY * scale
        )
    }
}

// MARK: - DisplayInfo

struct DisplayInfo {
    var id: CGDirectDisplayID
    /// 1-based index into CGGetActiveDisplayList — the value stored in targetDisplayIndex.
    var listIndex: Int
    var bounds: CGRect  // in CGDisplayBounds / Quartz coordinates
    var name: String  // localised device name if available
    var resolution: String  // e.g. "2560×1440"
    /// Desktop image thumbnail, or nil when none could be loaded.
    ///
    /// Known inaccuracy: since the Wallpaper settings pane replaced Desktop &
    /// Screen Saver, `NSWorkspace.desktopImageURL(for:)` only reports still
    /// images set the old way. Solid colors, aerials, dynamic wallpapers and
    /// per-Space choices all live in the private `com.apple.wallpaper` store,
    /// and the API returns `/System/Library/CoreServices/DefaultDesktop.heic`
    /// instead — so those setups show a stock image here rather than what is
    /// actually on screen. Reading the private store or screenshotting the
    /// desktop (Screen Recording permission) are the only alternatives, and
    /// neither is worth it for a decorative thumbnail. Revisit only if Apple
    /// ships a supported query.
    var wallpaper: NSImage?

    var pickerLabel: String { "\(name) (\(resolution))" }

    /// Fallback label when `name` doesn't fit a crowded thumbnail (e.g. "Pen" from "Pen Display24").
    var firstWord: String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    /// Widest label — full name, first word, or bare index — that fits `maxWidth`.
    enum LabelTier { case full, firstWord, index }

    func labelTier(fitting maxWidth: CGFloat, font: NSFont) -> LabelTier {
        func width(_ s: String) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font]).width
        }
        if width(name) <= maxWidth { return .full }
        if width(firstWord) <= maxWidth { return .firstWord }
        return .index
    }

    /// Returns all active displays sorted by screen position (left→right, top→bottom),
    /// matching the arrangement shown in System Settings > Displays.
    static func all() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        var screenMap: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID
            {
                screenMap[num] = screen
            }
        }

        let unsorted = ids.enumerated().map { index, id -> DisplayInfo in
            let name = screenMap[id]?.localizedName ?? "Display \(index + 1)"
            let w = Int(CGDisplayPixelsWide(id))
            let h = Int(CGDisplayPixelsHigh(id))
            let wallpaper: NSImage? = screenMap[id].flatMap { screen in
                NSWorkspace.shared.desktopImageURL(for: screen)
                    .flatMap { Self.cachedThumbnail(from: $0, maxEdge: 640) }
            }
            return DisplayInfo(
                id: id, listIndex: index + 1,
                bounds: CGDisplayBounds(id),
                name: name, resolution: "\(w)×\(h)",
                wallpaper: wallpaper)
        }

        // Sort left-to-right, then top-to-bottom — matches System Settings Displays arrangement.
        return unsorted.sorted {
            if abs($0.bounds.minX - $1.bounds.minX) > 1 { return $0.bounds.minX < $1.bounds.minX }
            return $0.bounds.minY < $1.bounds.minY
        }
    }

    private static let ciContext = CIContext()

    /// Keyed by desktop-image URL so re-running `all()` skips decoding
    /// thumbnails for displays whose wallpaper hasn't changed.
    private static var thumbnailCache: [URL: NSImage] = [:]

    private static func cachedThumbnail(from url: URL, maxEdge: CGFloat) -> NSImage? {
        if let cached = thumbnailCache[url] { return cached }
        guard let thumbnail = loadThumbnail(from: url, maxEdge: maxEdge) else { return nil }
        thumbnailCache[url] = thumbnail
        return thumbnail
    }

    private static func loadThumbnail(from url: URL, maxEdge: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
        else { return nil }
        let toned = tonedDown(cg) ?? cg
        return NSImage(cgImage: toned, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Desaturates and flattens contrast so the thumbnail reads as a muted
    /// backdrop rather than competing with the crop chrome drawn over it —
    /// most setups resolve to Apple's default wallpaper here (see
    /// `wallpaper`'s doc comment), which is busy and heavily saturated at
    /// full strength. `nil` on any filter failure; caller falls back to the
    /// untouched thumbnail.
    private static func tonedDown(_ cg: CGImage) -> CGImage? {
        guard let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
        filter.setValue(0.35, forKey: kCIInputSaturationKey)
        filter.setValue(0.85, forKey: kCIInputContrastKey)
        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: output.extent)
    }
}
