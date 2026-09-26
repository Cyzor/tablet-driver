// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The tablet area and the screen area side by side, so one can be matched to
/// the other by eye. Each pane shows only its half of the mapping; this shows
/// both, live. Opened from either pane's canvas context menu.
///
/// Shows only the target display, large: a screen area applies to a single
/// display, so the arrangement around it adds nothing here. The tablet is an
/// abstract rectangle in its real, rotated shape — no product artwork.
struct MappingSheet: View {
    @ObservedObject var settings: TabletSettings
    /// Full tablet surface, width ÷ height, after rotation.
    let tabletAspect: Double
    let tabletCaption: DeviceRegistry.Caption
    let display: DisplayInfo
    /// Ends the sheet; it's presented from AppKit, which owns the window.
    var onClose: () -> Void = {}

    @State private var tabletRect: NormalizedRect
    @State private var screenRect: NormalizedRect

    init(
        settings: TabletSettings, tabletAspect: Double,
        tabletCaption: DeviceRegistry.Caption, display: DisplayInfo,
        onClose: @escaping () -> Void
    ) {
        self.settings = settings
        self.tabletAspect = tabletAspect
        self.tabletCaption = tabletCaption
        self.display = display
        self.onClose = onClose
        _tabletRect = State(initialValue: NormalizedRect(
            x: settings.activeAreaX, y: settings.activeAreaY,
            w: settings.activeAreaWidth, h: settings.activeAreaHeight))
        _screenRect = State(initialValue: NormalizedRect(
            x: settings.displayRegionX, y: settings.displayRegionY,
            w: settings.displayRegionWidth, h: settings.displayRegionHeight))
    }

    private var displayAspect: Double {
        Double(display.bounds.width) / Double(max(display.bounds.height, 1))
    }
    private var screenShape: Double { displayAspect * screenRect.w / max(screenRect.h, 0.001) }
    private var tabletShape: Double { tabletAspect * tabletRect.w / max(tabletRect.h, 0.001) }

    // Layout: the two canvases share whatever height the controls leave.
    private static let padding: CGFloat = 24
    private static let spacing: CGFloat = 20
    /// Two control wells, the button row, and the gaps between five rows.
    private static let chromeHeight: CGFloat = 36 * 2 + 30 + spacing * 4
    private static let displayShare: CGFloat = 0.64
    static let defaultWidth: CGFloat = 640
    static let maxWidth: CGFloat = 1100

    /// Content size at `width` where the display canvas exactly fills its
    /// row, so no size of the sheet leaves it stranded in empty margin.
    static func contentSize(width: CGFloat, displayAspect: Double) -> CGSize {
        let canvasHeight = (width - padding * 2) / CGFloat(displayAspect)
        return CGSize(
            width: width,
            height: canvasHeight / displayShare + chromeHeight + padding * 2)
    }

    /// Inverse of `contentSize`: the width whose content is `height` tall.
    static func width(forContentHeight height: CGFloat, displayAspect: Double) -> CGFloat {
        (height - chromeHeight - padding * 2) * displayShare * CGFloat(displayAspect) + padding * 2
    }

    var body: some View {
        GeometryReader { geo in
            let flexible = max(geo.size.height - Self.chromeHeight, 160)
            VStack(spacing: Self.spacing) {
                NormalizedAreaEditor(
                    aspectRatio: displayAspect,
                    rect: $screenRect,
                    background: {
                        if let wallpaper = display.wallpaper {
                            GeometryReader { geo in
                                Image(nsImage: wallpaper)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .clipped()
                            }
                        }
                    },
                    overlay: { areaRect, _ in
                        DisplayMappingView.DisplayNameBadge(
                            name: display.name, resolution: display.resolution, areaRect: areaRect)
                    }
                )
                .snapping(to: tabletShape, label: String(localized: "Matches tablet area"))
                .frame(height: flexible * Self.displayShare)

                fitButtons(
                    fit: { screenRect = fitted(shape: tabletShape, in: displayAspect, around: screenRect) },
                    full: { screenRect = Self.full },
                    fitLabel: "Fit to Tablet",
                    fitHelp: "Make the screen area the tablet's shape, as large as the display allows, so none of the tablet goes unused.",
                    fullLabel: "Use Whole Screen",
                    fullHelp: "Map the tablet to the entire selected display (undoable).")

                NormalizedAreaEditor(aspectRatio: tabletAspect, rect: $tabletRect) { areaRect, cs in
                    ZStack {
                        Canvas { ctx, _ in
                            letterbox(ctx: ctx, areaRect: areaRect, canvas: cs)
                        }
                        DisplayMappingView.DisplayNameBadge(
                            name: tabletCaption.primary, resolution: tabletCaption.secondary ?? "",
                            areaRect: areaRect)
                    }
                    .frame(width: cs.width, height: cs.height)
                }
                .snapping(to: screenShape, label: String(localized: "Matches screen area"))
                .frame(height: flexible * (1 - Self.displayShare))

                fitButtons(
                    fit: { tabletRect = fitted(shape: screenShape, in: tabletAspect, around: tabletRect) },
                    full: { tabletRect = Self.full },
                    fitLabel: "Fit to Screen Area",
                    fitHelp: "Make the active area the screen area's shape, as large as the tablet allows, so the cursor isn't stretched.",
                    fullLabel: "Reset to Full Area",
                    fullHelp: "Reset the active area to the full tablet surface (undoable).")

                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { onClose() }
                        .keyboardShortcut(.cancelAction)
                    Button("Done") {
                        settings.applyMapping(
                            tablet: TabletSettings.AreaSnapshot(
                                x: tabletRect.x, y: tabletRect.y, w: tabletRect.w, h: tabletRect.h),
                            screen: TabletSettings.AreaSnapshot(
                                x: screenRect.x, y: screenRect.y, w: screenRect.w, h: screenRect.h))
                        onClose()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Self.padding)
        .background(SheetMaterial())
    }

    private static let full = NormalizedRect(x: 0, y: 0, w: 1, h: 1)

    private func fitted(shape: Double, in container: Double, around r: NormalizedRect) -> NormalizedRect {
        let f = TabletSettings.fittedRegion(
            tabletAspect: shape, displayAspect: container,
            centerX: r.x + r.w / 2, centerY: r.y + r.h / 2)
        return NormalizedRect(x: f.x, y: f.y, w: f.w, h: f.h)
    }

    /// Glyph-only fit and full-coverage buttons; the pane buttons' labels and
    /// tooltips carry over as the accessibility label and help.
    private func fitButtons(
        fit: @escaping () -> Void, full: @escaping () -> Void,
        fitLabel: LocalizedStringKey, fitHelp: LocalizedStringKey,
        fullLabel: LocalizedStringKey, fullHelp: LocalizedStringKey
    ) -> some View {
        HStack(spacing: 14) {
            Button(action: fit) { Image(systemName: "aspectratio") }
                .accessibilityLabel(fitLabel)
                .help(fitHelp)
            Button(action: full) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .accessibilityLabel(fullLabel)
                .help(fullHelp)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 15))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.recessedWell))
    }

    /// Dims the part of the tablet area proportions leave unused, tracking the
    /// tablet drag live and the screen area as it's committed.
    private func letterbox(ctx: GraphicsContext, areaRect: CGRect, canvas cs: CGSize) {
        guard settings.proportionalMapping, cs.width > 0, cs.height > 0 else { return }
        let (x, y, w, h) = DisplayMapper.proportionalCrop(
            areaX: areaRect.minX / cs.width, areaY: areaRect.minY / cs.height,
            areaW: areaRect.width / cs.width, areaH: areaRect.height / cs.height,
            effMaxX: 1, effMaxY: 1,
            surfaceAspect: tabletAspect, displayAspect: screenShape)
        let live = CGRect(x: x * cs.width, y: y * cs.height, width: w * cs.width, height: h * cs.height)
        guard live != areaRect else { return }
        var region = Path(areaRect)
        region.addRect(live)
        ctx.fill(region, with: .color(.black.opacity(0.25)), style: FillStyle(eoFill: true))
    }
}

extension DeviceRegistry {
    /// Name and optional model caption for a tablet's area canvas.
    struct Caption {
        let primary: String
        let secondary: String?
    }

    /// Prefers the model name captured when the tablet was last seen: it
    /// carries the right vendor. Re-deriving from the PID alone defaults to
    /// Wacom once the device is gone, printing e.g. "Wacom 0x520D" for a
    /// disconnected Xencelabs.
    @MainActor
    func caption(forProductID pid: Int?, tabletManager: TabletManager) -> Caption {
        guard let pid else {
            if let activePID = tabletManager.activeContext?.productID {
                return Caption(primary: TabletManager.deviceName(forProductID: activePID), secondary: nil)
            }
            return Caption(
                primary: String(localized: "No device", comment: "Fallback label when no tablet is connected"),
                secondary: nil)
        }
        if let tablet = knownTablets.first(where: { $0.productID == pid }) {
            if tablet.nickname != tablet.modelName {
                return Caption(primary: tablet.nickname, secondary: tablet.modelName)
            }
            return Caption(primary: tablet.modelName, secondary: nil)
        }
        return Caption(primary: TabletManager.deviceName(forProductID: pid), secondary: nil)
    }
}

extension DisplayInfo {
    /// The display a single-display target index selects; nil for All,
    /// Toggle and Span, which have no single screen area.
    static func targeted(by index: Int, in displays: [DisplayInfo]) -> DisplayInfo? {
        guard index != TabletSettings.displayModeAll, index != TabletSettings.displayModeToggle,
            index != TabletSettings.displayModeSpan
        else { return nil }
        let resolved = index > 0 ? index : 1  // 0 = primary, first in the list
        return displays.first { $0.listIndex == resolved } ?? displays.first
    }
}

/// Presents `MappingSheet` from AppKit. SwiftUI's `.sheet` resets the sheet
/// window's size limits on every layout pass, so it could neither hold a
/// minimum nor grow from the top. An AppKit sheet stays attached under the
/// toolbar and grows down from it.
@MainActor
enum MappingSheetPresenter {
    /// `parent` is the pane's own window, not the key window: right-clicking an
    /// inactive window doesn't make it key.
    static func present(
        from parent: NSWindow?, settings: TabletSettings, tabletAspect: Double,
        tabletCaption: DeviceRegistry.Caption, display: DisplayInfo
    ) {
        guard let parent, parent.attachedSheet == nil else { return }
        parent.makeKeyAndOrderFront(nil)
        let aspect = Double(display.bounds.width) / Double(max(display.bounds.height, 1))

        // Opens at its default size, fitted inside the window it hangs from;
        // that is also its minimum — resizing only ever makes it larger.
        var minWidth = MappingSheet.defaultWidth
        let room = parent.contentLayoutRect.height - 24
        if MappingSheet.contentSize(width: minWidth, displayAspect: aspect).height > room {
            minWidth = max(MappingSheet.width(forContentHeight: room, displayAspect: aspect), 320)
        }
        let size = MappingSheet.contentSize(width: minWidth, displayAspect: aspect)

        let sheet = MappingSheetWindow(
            displayAspect: aspect, minWidth: minWidth,
            maxWidth: max(MappingSheet.maxWidth, minWidth), contentSize: size)
        let host = NSHostingController(rootView: MappingSheet(
            settings: settings, tabletAspect: tabletAspect,
            tabletCaption: tabletCaption, display: display,
            onClose: { [weak parent, weak sheet] in
                if let sheet { parent?.endSheet(sheet) }
            }))
        host.sizingOptions = []
        sheet.contentViewController = host
        sheet.setContentSize(size)
        parent.beginSheet(sheet)
    }
}

/// The sheet's own window, which decides every resize: the canvases fill
/// their rows at any size, and it never goes below its opening size or past
/// the maximum. Answering `windowWillResize` beats setting min, max and aspect
/// separately, which let it shrink from the center once the limits disagreed.
private final class MappingSheetWindow: NSWindow, NSWindowDelegate {
    let displayAspect: Double
    let minWidth: CGFloat
    let maxWidth: CGFloat
    /// Which dimension leads the current drag; latched once per resize so a
    /// corner drag can't alternate between two sizes frame to frame.
    private var heightLeads: Bool?

    init(displayAspect: Double, minWidth: CGFloat, maxWidth: CGFloat, contentSize: CGSize) {
        self.displayAspect = displayAspect
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        delegate = self
        isOpaque = false
        backgroundColor = .clear
    }

    func windowWillStartLiveResize(_ notification: Notification) { heightLeads = nil }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let proposed = contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let current = contentRect(forFrameRect: frame).size
        let dw = abs(proposed.width - current.width)
        let dh = abs(proposed.height - current.height)
        if heightLeads == nil, dw + dh > 0.5 { heightLeads = dh > dw }
        let width = heightLeads == true
            ? MappingSheet.width(forContentHeight: proposed.height, displayAspect: displayAspect)
            : proposed.width
        let clamped = min(max(width, minWidth), maxWidth)
        let content = MappingSheet.contentSize(width: clamped, displayAspect: displayAspect)
        return frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
    }
}

/// The system's sheet material behind the content.
private struct SheetMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sheet
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Weak handle to the window a view lives in, filled in by `WindowReader`.
final class WindowRef {
    weak var window: NSWindow?
}

/// Records the hosting window into `ref`, so an action can target the window
/// it came from rather than whichever one is key.
struct WindowReader: NSViewRepresentable {
    let ref: WindowRef

    func makeNSView(context: Context) -> NSView { Probe(ref: ref) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        let ref: WindowRef
        init(ref: WindowRef) {
            self.ref = ref
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            ref.window = window
        }
    }
}
