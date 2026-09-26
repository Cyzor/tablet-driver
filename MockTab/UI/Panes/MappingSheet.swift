// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The tablet area and the screen area side by side, so one can be matched to
/// the other by eye. Each pane shows only its half of the mapping; this shows
/// both, live. Opened from either pane's canvas context menu.
///
/// With one target display it shows that display large, with its editable
/// screen area. All, Span and Toggle have no screen area, so they show the
/// arrangement read-only, the mapped displays highlighted, and the tablet
/// matches the destination's shape. The tablet is an abstract rectangle in its
/// real, rotated shape — no product artwork.
struct MappingSheet: View {
    @ObservedObject var settings: TabletSettings
    /// Full tablet surface, width ÷ height, after rotation.
    let tabletAspect: Double
    let tabletCaption: DeviceRegistry.Caption
    let destination: MappingDestination
    /// Ends the sheet; it's presented from AppKit, which owns the window.
    var onClose: () -> Void = {}

    @State private var tabletRect: NormalizedRect
    /// The sheet window's own undo manager — the key window while the sheet
    /// is up, so Edit ▸ Undo and ⌘Z step through the sheet's edits. The pane's
    /// history only sees Done, as one step.
    @Environment(\.undoManager) private var undoManager
    @State private var screenRect: NormalizedRect

    init(
        settings: TabletSettings, tabletAspect: Double,
        tabletCaption: DeviceRegistry.Caption, destination: MappingDestination,
        onClose: @escaping () -> Void
    ) {
        self.settings = settings
        self.tabletAspect = tabletAspect
        self.tabletCaption = tabletCaption
        self.destination = destination
        self.onClose = onClose
        _tabletRect = State(initialValue: NormalizedRect(
            x: settings.activeAreaX, y: settings.activeAreaY,
            w: settings.activeAreaWidth, h: settings.activeAreaHeight))
        _screenRect = State(initialValue: NormalizedRect(
            x: settings.displayRegionX, y: settings.displayRegionY,
            w: settings.displayRegionWidth, h: settings.displayRegionHeight))
    }

    /// Shape of the top canvas: the target display, or the whole arrangement.
    private var displayAspect: Double { Self.canvasAspect(for: destination) }
    /// The destination's shape, live while the screen area is edited.
    private var screenShape: Double {
        destination.single == nil
            ? destination.shape ?? displayAspect
            : displayAspect * screenRect.w / max(screenRect.h, 0.001)
    }

    static func canvasAspect(for destination: MappingDestination) -> Double {
        let r = destination.single.map { $0.bounds }
            ?? destination.displays.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        return r.height > 0 ? Double(r.width / r.height) : 16.0 / 10.0
    }
    private var tabletShape: Double { tabletAspect * tabletRect.w / max(tabletRect.h, 0.001) }

    // Layout: the two canvases share whatever height the controls leave.
    // Every edge sits `padding + canvasInset` in: the canvases draw that far
    // inside their frames, and the button row is inset to match.
    private static let padding: CGFloat = 16
    private static let canvasInset: CGFloat = 8
    private static let spacing: CGFloat = 20
    /// Two control wells, the button row with its inset, and the gaps
    /// between six rows (the spacer above the buttons counts as one).
    private static let chromeHeight: CGFloat = 36 * 2 + 30 + canvasInset + spacing * 5
    private static let displayShare: CGFloat = 0.64
    static let defaultWidth: CGFloat = 640
    static let maxWidth: CGFloat = 1100

    /// Content size at `width` where the display canvas exactly fills its
    /// row, so no size of the sheet leaves it stranded in empty margin.
    static func contentSize(width: CGFloat, displayAspect: Double) -> CGSize {
        let drawn = width - padding * 2 - canvasInset * 2
        let row = drawn / CGFloat(displayAspect) + canvasInset * 2
        return CGSize(width: width, height: row / displayShare + chromeHeight + padding * 2)
    }

    /// Inverse of `contentSize`: the width whose content is `height` tall.
    static func width(forContentHeight height: CGFloat, displayAspect: Double) -> CGFloat {
        let row = (height - chromeHeight - padding * 2) * displayShare
        return (row - canvasInset * 2) * CGFloat(displayAspect) + canvasInset * 2 + padding * 2
    }

    var body: some View {
        GeometryReader { geo in
            let flexible = max(geo.size.height - Self.chromeHeight, 160)
            VStack(spacing: Self.spacing) {
                Group {
                    if let display = destination.single {
                        NormalizedAreaEditor(
                            aspectRatio: displayAspect,
                            rect: $screenRect,
                            onCommit: { before in recordEdit(tablet: tabletRect, screen: before) },
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
                    } else {
                        DisplayArrangementView(
                            displays: destination.displays,
                            isSelected: { info in destination.included.contains { $0.id == info.id } })
                    }
                }
                .frame(height: flexible * Self.displayShare)

                fitButtons(
                    fit: { edit(screen: fitted(shape: tabletShape, in: displayAspect, around: screenRect)) },
                    full: { edit(screen: Self.full) },
                    fitLabel: "Fit to Tablet",
                    fitHelp: "Make the screen area the tablet's shape, as large as the display allows, so none of the tablet goes unused.",
                    fullLabel: "Use Whole Screen",
                    fullHelp: "Map the tablet to the entire selected display (undoable).")
                    .disabled(destination.single == nil)

                NormalizedAreaEditor(
                    aspectRatio: tabletAspect, rect: $tabletRect,
                    onCommit: { before in recordEdit(tablet: before, screen: screenRect) }
                ) { areaRect, cs in
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
                    fit: { edit(tablet: fitted(shape: screenShape, in: tabletAspect, around: tabletRect)) },
                    full: { edit(tablet: Self.full) },
                    fitLabel: "Fit to Screen Area",
                    fitHelp: "Make the active area the screen area's shape, as large as the tablet allows, so the cursor isn't stretched.",
                    fullLabel: "Reset to Full Area",
                    fullHelp: "Reset the active area to the full tablet surface (undoable).")

                // Pins the buttons to the bottom margin; `chromeHeight` is an
                // estimate, and any slack belongs above the buttons, not below.
                Spacer(minLength: 0)

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
                .padding([.horizontal, .bottom], Self.canvasInset)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(Self.padding)
        .background(SheetMaterial())
    }

    private static let full = NormalizedRect(x: 0, y: 0, w: 1, h: 1)
    private static let undoTarget = NSObject()

    /// Applies new rects as one undoable step.
    private func edit(tablet: NormalizedRect? = nil, screen: NormalizedRect? = nil) {
        let before = (tabletRect, screenRect)
        if let tablet { tabletRect = tablet }
        if let screen { screenRect = screen }
        recordEdit(tablet: before.0, screen: before.1)
    }

    /// Registers undo back to the given rects — for a change already made,
    /// such as a finished drag. Undoing registers the redo the same way.
    private func recordEdit(tablet: NormalizedRect, screen: NormalizedRect) {
        guard tablet != tabletRect || screen != screenRect else { return }
        undoManager?.registerUndo(withTarget: Self.undoTarget) { _ in
            edit(tablet: tablet, screen: screen)
        }
        undoManager?.setActionName(String(localized: "Edit Mapping"))
    }

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

extension View {
    /// Right-click menu offering Edit Mapping…, served from AppKit: SwiftUI's
    /// `.contextMenu` sometimes misses the first right-click on views with
    /// their own tap and drag gestures, which every mapping canvas has.
    func editMappingMenu(enabled: Bool = true, action: @escaping () -> Void) -> some View {
        overlay(RightClickMenuHost { _ in
            let menu = NSMenu()
            menu.autoenablesItems = false
            let item = NSMenuItem(
                title: String(localized: "Edit Mapping…"),
                action: #selector(RingMenuTarget.selectAction(_:)), keyEquivalent: "")
            item.target = RingMenuTarget.shared
            item.representedObject = RingMenuAction(action)
            item.isEnabled = enabled
            menu.addItem(item)
            return menu
        })
    }
}

/// Where the tablet maps in the current display mode, and the shape it maps
/// to. One display: that display, cropped to the screen area. All and Span:
/// the bounding rectangle of the included displays. Toggle: one display at a
/// time — measured against the first in the rotation.
struct MappingDestination {
    let displays: [DisplayInfo]
    /// The displays the mapping covers or rotates through.
    let included: [DisplayInfo]
    /// Set only in single-display mode, the one mode with a screen area.
    let single: DisplayInfo?
    /// Real width ÷ height the tablet maps to.
    let shape: Double?

    @MainActor
    static func current(for settings: TabletSettings, displays: [DisplayInfo] = DisplayInfo.all()) -> Self {
        let idx = settings.targetDisplayIndex
        let ids = settings.toggleDisplayIDSet
        let chosen = ids.isEmpty ? displays : displays.filter { ids.contains($0.id) }
        func aspect(_ r: CGRect) -> Double? { r.height > 0 ? Double(r.width / r.height) : nil }
        switch idx {
        case TabletSettings.displayModeAll, TabletSettings.displayModeSpan:
            let set = idx == TabletSettings.displayModeAll ? displays : chosen
            let union = set.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
            return Self(displays: displays, included: set, single: nil, shape: set.isEmpty ? nil : aspect(union))
        case TabletSettings.displayModeToggle:
            // Rotation follows the system's display list, not screen position.
            let first = chosen.min { $0.listIndex < $1.listIndex }
            return Self(displays: displays, included: chosen, single: nil, shape: first.flatMap { aspect($0.bounds) })
        default:
            let d = DisplayInfo.targeted(by: idx, in: displays)
            let shape = d.flatMap { aspect($0.bounds) }.map {
                $0 * settings.displayRegionWidth / max(settings.displayRegionHeight, 0.001)
            }
            return Self(displays: displays, included: d.map { [$0] } ?? [], single: d, shape: shape)
        }
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
        tabletCaption: DeviceRegistry.Caption, destination: MappingDestination
    ) {
        guard let parent, parent.attachedSheet == nil else { return }
        parent.makeKeyAndOrderFront(nil)
        let aspect = MappingSheet.canvasAspect(for: destination)

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
            tabletCaption: tabletCaption, destination: destination,
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
            // Record, never clear: several readers can share one ref, and a
            // reader leaving the pane (the Screen Area section on switching to
            // Toggle) must not blank the window for the ones that stay. The
            // ref is weak, so a closed window still clears itself.
            if let window { ref.window = window }
        }
    }
}
