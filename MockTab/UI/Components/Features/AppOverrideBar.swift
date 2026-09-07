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

// MARK: - Chip drag pasteboard type

/// Pasteboard type for chip-reorder drags. Private to this bar — the type is
/// only ever written and read by views in this file, and the row's drop zone
/// additionally requires the drag source to be one of its own chips.
private let chipDragType = NSPasteboard.PasteboardType("com.mocktab.app-override-chip")

// MARK: - Chip frame preference key (live drop-target hit-testing)

/// Reports each app chip's frame in the chip row's coordinate space, updated
/// on every layout pass. The row's drop zone hit-tests the drag pointer
/// against these current frames; never a snapshot frozen at drag-start,
/// which goes stale as soon as the gap indicator shifts chips.
private struct ChipFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Named coordinate space shared by the chip frame reporters and the row's
/// drop-zone overlay, so both speak the same geometry.
private enum ChipRowCoordinateSpace {
    static let name = "AppOverrideBar.chipRow"
}

/// Reports the drop-zone overlay's origin within the row's coordinate space,
/// so it can convert chip frames (row space) into its own local space. The
/// overlay spans the full scroll-view width while the frames are relative to
/// the chip HStack, so the two origins differ.
private struct ChipDropZoneOffsetKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

/// The drop hover state as a single `Equatable` value, so `.animation(value:)`
/// fires when either component changes (tuples can't conform to `Equatable`).
private struct DragHoverState: Equatable {
    var targetID: String?
    var atEnd: Bool
}

/// Renders a SwiftUI chip view to an `NSImage` for the drag ghost.
@MainActor
private func renderChipGhost<V: View>(_ view: V, scale: CGFloat) -> NSImage? {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let cgImage = renderer.cgImage else { return nil }
    return NSImage(
        cgImage: cgImage,
        size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
    )
}

// MARK: - Chip interaction proxy (tap / double-tap via raw mouse events)

/// Owns tap, double-tap, and hold-to-arm detection for a chip via raw AppKit
/// mouse events, sidestepping SwiftUI's gesture idiosyncratic recognition on this view
/// entirely. Sits as a transparent overlay above the chip's
/// visual content and carries the chip's accessibility element, which
/// previously rode free on `Button`.
///
/// Hold-to-arm: pressing and holding for `armDuration` without drifting more
/// than `armMaxDrift` from the down point fires `onArm` (which enables the
/// chip's drag transport); releasing fires `onDisarm`. Both constants are
/// tuned values for pen input (stylus jitter).
private struct ChipInteractionProxy: NSViewRepresentable {
    var label: String
    var isSelected: Bool
    var armDuration: TimeInterval
    var armMaxDrift: CGFloat
    var onTap: () -> Void
    var onDoubleTap: () -> Void
    var onArm: () -> Void
    var onDisarm: () -> Void
    var dragPayload: String?
    /// Renders the drag ghost on demand. Provided by the SwiftUI side, which
    /// owns the chip's visual; the overlay's own layer tree doesn't contain
    /// that content, so it can't snapshot it directly.
    var ghostImage: () -> NSImage?

    func makeNSView(context: Context) -> InteractionView { InteractionView() }

    func updateNSView(_ v: InteractionView, context: Context) {
        v.armDuration = armDuration
        v.armMaxDrift = armMaxDrift
        v.onTap = onTap
        v.onDoubleTap = onDoubleTap
        v.onArm = onArm
        v.onDisarm = onDisarm
        v.dragPayload = dragPayload
        v.ghostImage = ghostImage
        v.setAccessibilityLabel(label)
        v.setAccessibilitySelected(isSelected)
    }

    class InteractionView: NSView, NSDraggingSource {
        var armDuration: TimeInterval = 0.45
        var armMaxDrift: CGFloat = 18
        var onTap: (() -> Void)?
        var onDoubleTap: (() -> Void)?
        var onArm: (() -> Void)?
        var onDisarm: (() -> Void)?
        /// The chip's bundle ID, written to the drag pasteboard. Nil for the
        /// Global chip, which is fixed and never draggable.
        var dragPayload: String?
        var ghostImage: (() -> NSImage?)?

        private var sawMouseDown = false
        private var downPointInWindow: NSPoint = .zero
        private var armTimer: Timer?
        private var isArmed = false
        private var holdExceededDrift = false
        private var dragSessionActive = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var acceptsFirstResponder: Bool { false }

        override func mouseDown(with event: NSEvent) {
            sawMouseDown = true
            isArmed = false
            holdExceededDrift = false
            downPointInWindow = event.locationInWindow

            // Cmd held at mouse-down arms instantly, bypassing the hold timer
            // — the Dock's own hidden Cmd-drag convention. Immune to the pen
            // jitter failure mode by construction: jitter perturbs position,
            // not modifier-key state.
            if event.modifierFlags.contains(.command), dragPayload != nil {
                isArmed = true
                onArm?()
                return
            }

            // Scheduled in .common modes: during a press-and-drag AppKit runs
            // the event-tracking run-loop mode, where a default-mode timer
            // would never fire.
            let timer = Timer(timeInterval: armDuration, repeats: false) { [weak self] _ in
                guard let self, self.sawMouseDown, !self.holdExceededDrift else { return }
                self.isArmed = true
                self.onArm?()
            }
            RunLoop.main.add(timer, forMode: .common)
            armTimer = timer
        }

        override func mouseDragged(with event: NSEvent) {
            guard sawMouseDown else { return }
            if isArmed {
                guard !dragSessionActive, let payload = dragPayload else { return }
                dragSessionActive = true
                beginChipDragSession(with: event, payload: payload)
                return
            }
            guard !holdExceededDrift else { return }
            let deltaX = event.locationInWindow.x - downPointInWindow.x
            let deltaY = event.locationInWindow.y - downPointInWindow.y
            if hypot(deltaX, deltaY) > armMaxDrift {
                holdExceededDrift = true
                armTimer?.invalidate()
                armTimer = nil
            }
        }

        override func mouseUp(with event: NSEvent) {
            armTimer?.invalidate()
            armTimer = nil
            guard sawMouseDown else { return }
            sawMouseDown = false
            if isArmed {
                isArmed = false
                onDisarm?()
            }
            let location = convert(event.locationInWindow, from: nil)
            guard bounds.contains(location) else { return }
            // AppKit delivers clickCount natively — no hand-rolled timing.
            // First click selects; the second click of a double-click arrives
            // with clickCount == 2 and renames, matching the old behavior.
            if event.clickCount >= 2 {
                onDoubleTap?()
            } else {
                onTap?()
            }
        }

        override func accessibilityPerformPress() -> Bool {
            onTap?()
            return true
        }

        // MARK: - Drag source

        private func beginChipDragSession(with event: NSEvent, payload: String) {
            let writer = NSPasteboardItem()
            writer.setString(payload, forType: chipDragType)
            let item = NSDraggingItem(pasteboardWriter: writer)

            item.setDraggingFrame(bounds, contents: ghostImage?())
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            dragSessionActive = false
            isArmed = false
            onDisarm?()
        }
    }
}

// MARK: - Chip row drop zone (manual NSDraggingDestination)

/// Transparent overlay spanning the chip row that owns drop handling for
/// chip-reorder drags. Hit-tests the pointer against the chips' *current*
/// frames (reported per layout pass via `ChipFramesKey`) to drive the
/// gap-opening indicator, and commits the reorder exactly once on drop.
/// Being an NSView rather than a SwiftUI `.dropDestination` sibling inside
/// the ScrollView's content is also what will let Stage 5 accept drops past
/// the last chip without hitting the ScrollView intrinsic-sizing trap.
private struct ChipRowDropZone: NSViewRepresentable {
    /// Current chip frames in the row's coordinate space, keyed by bundle ID.
    var chipFrames: [String: CGRect]
    /// This overlay's origin within that same coordinate space — chip frames
    /// are translated by subtracting it before hit-testing.
    var originInRowSpace: CGPoint
    /// Chip order, used to derive the insertion index from the hit frame.
    var orderedIDs: [String]
    /// Called with the chip ID to open a gap before, or nil to clear. The
    /// end-of-row target is reported as the last chip's ID with `atEnd` set.
    var onHover: (String?, Bool) -> Void
    /// Called with the source ID and the insertion index (0…count).
    var onDrop: (String, Int) -> Void

    func makeNSView(context: Context) -> DropZoneView {
        let v = DropZoneView()
        v.registerForDraggedTypes([chipDragType])
        return v
    }

    func updateNSView(_ v: DropZoneView, context: Context) {
        v.chipFrames = chipFrames
        v.originInRowSpace = originInRowSpace
        v.orderedIDs = orderedIDs
        v.onHover = onHover
        v.onDrop = onDrop
    }

    class DropZoneView: NSView {
        var chipFrames: [String: CGRect] = [:]
        var originInRowSpace: CGPoint = .zero
        var orderedIDs: [String] = []
        var onHover: ((String?, Bool) -> Void)?
        var onDrop: ((String, Int) -> Void)?

        /// The current insertion target: an index into `orderedIDs` in the
        /// range 0…count, where `count` means "past the last chip."
        private var hoveredIndex: Int?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Never intercept clicks — this overlay exists only for drags.
            nil
        }

        private func sourceID(from info: NSDraggingInfo) -> String? {
            guard let view = info.draggingSource as? ChipInteractionProxy.InteractionView,
                view.dragPayload != nil,
                let id = info.draggingPasteboard.string(forType: chipDragType)
            else { return nil }
            return id
        }

        /// The insertion index for the pointer position: the index of the
        /// first chip (excluding the dragged one) whose current frame
        /// contains the pointer, or `orderedIDs.count` if the pointer is
        /// past the last chip's trailing edge. Frames come straight from the
        /// latest layout pass, so they already reflect any opened gap.
        private func insertionIndex(atWindowPoint windowPoint: NSPoint, excluding sourceID: String) -> Int? {
            let point = convert(windowPoint, from: nil)
            guard bounds.contains(point) else { return nil }
            // Chip frames arrive in the row's coordinate space; translate
            // them into this overlay's local space before hit-testing.
            func localFrame(_ id: String) -> CGRect? {
                chipFrames[id]?.offsetBy(dx: -originInRowSpace.x, dy: -originInRowSpace.y)
            }
            let candidates = orderedIDs.filter { $0 != sourceID }
            for (index, id) in orderedIDs.enumerated() where id != sourceID {
                if localFrame(id)?.contains(point) == true { return index }
            }
            // Past the last chip's trailing edge → append at end.
            if let lastID = candidates.last, let lastFrame = localFrame(lastID),
                point.x > lastFrame.maxX {
                return orderedIDs.count
            }
            return nil
        }

        private func reportHover() {
            guard let index = hoveredIndex else {
                onHover?(nil, false)
                return
            }
            if index == orderedIDs.count {
                onHover?(orderedIDs.last, true)
            } else {
                onHover?(orderedIDs[index], false)
            }
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            draggingUpdated(sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let source = sourceID(from: sender) else { return [] }
            let index = insertionIndex(atWindowPoint: sender.draggingLocation, excluding: source)
            if index != hoveredIndex {
                hoveredIndex = index
                reportHover()
            }
            return index != nil ? .move : []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            hoveredIndex = nil
            onHover?(nil, false)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer {
                hoveredIndex = nil
                onHover?(nil, false)
            }
            guard
                let source = sourceID(from: sender),
                let index = insertionIndex(atWindowPoint: sender.draggingLocation, excluding: source)
            else { return false }
            onDrop?(source, index)
            return true
        }
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
/// - Layout: the ScrollView spans the full bar width so the scrollbar track runs
///   edge to edge. Chip content is inset by `chipHorizontalPadding` on the leading
///   side and `addMenuSlotWidth` on the trailing side, for the addMenu panel. That
///   panel overlays `.topTrailing`, constrained to `chipAreaHeight` (the chip row's
///   own height, derived from `chipIconSize`) so it sits flush with the chips and
///   never overlaps a legacy scrollbar track below; its button fills the panel's
///   height (minus a 2 pt inset) to read as a sibling of the chips.
/// - Tap vs. drag (tablet-optimized): a quick tap selects the override; a
///   long-press (~0.45 s) then drag shows a ghost preview and allows reordering.
///   `maximumDistance` is widened from the 10 pt default to absorb stylus jitter.
/// - Overflow: gradient-fade overlays signal clipped content in overlay-scrollbar
///   mode, suppressed when "Always show scrollbars" is on (the track already
///   signals it there).
/// - Drag-over: the hovered drop-target chip opens a gap to its left before the
///   drop lands.
/// - Chip appearance: unselected chips use the system `.quaternary` hierarchical
///   fill (tracks light/dark, vibrancy, Increase Contrast automatically). Selected
///   chips use a translucent accent tint rather than a full fill.  Global is
///   visible almost continuously and shouldn't demand attention; tone softens
///   further when the window isn't key.
/// - Icon size: all chip geometry derives from `chipIconSize`; changing it scales
///   chip height and `chipAreaHeight` together, keeping the addMenu panel sized.
/// - Right-click provides Rename / Reveal in Finder / Remove.
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
        "touchRingSlotsJSON", "touchRingActiveSlotIndex", "reverseRingDirection",
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
    /// Shown in the Global chip's context menu only while Global is selected;
    /// applying it to a chip that isn't the active layer would silently write
    /// to whichever layer *is* active instead, since panes read/write through
    /// `settings`/`tool`'s current override, not through the clicked chip.
    var onResetToDefaults: (() -> Void)? = nil

    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isDropTargeted = false
    @State private var dragEnabledID: String? = nil
    @State private var dragHoverTargetID: String? = nil
    /// True when the hovered insertion point is past the last chip (append at
    /// end); the gap then opens on the last chippy-chip's trailing side.
    @State private var dragHoverAtEnd = false

    @State private var chipContentWidth: CGFloat = 0
    @State private var chipViewportWidth: CGFloat = 0
    /// Current chip frames in the row's coordinate space, for drop hit-testing.
    @State private var chipFrames: [String: CGRect] = [:]
    /// The drop-zone overlay's origin in the row's coordinate space.
    @State private var chipDropZoneOffset: CGPoint = .zero

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
    /// Horizontal spacing between chips in the row (HStack spacing).
    private let chipRowSpacing: CGFloat = 5
    /// Gap opened ahead of the hovered drop target: wide enough to fit the
    /// chip being dragged, so it reads as "there's room for it here."
    private var dragHoverGap: CGFloat {
        guard let id = dragEnabledID, let width = chipFrames[id]?.width else { return 60 }
        return width + chipRowSpacing
    }

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
        // The drop zone spans the full scroll-view width (not just the chip
        // HStack) so drops past the last chip land in it — that's what makes
        // append-at-end reachable. Chip frames arrive in the row's coordinate
        // space; the drop zone converts using its own offset within that
        // space, reported via ChipDropZoneOffsetKey.
        .overlay(
            ChipRowDropZone(
                chipFrames: chipFrames,
                originInRowSpace: chipDropZoneOffset,
                orderedIDs: settings.appOverrides.map(\.bundleID),
                onHover: { targetID, atEnd in
                    dragHoverTargetID = targetID
                    dragHoverAtEnd = atEnd
                },
                onDrop: { sourceID, index in reorderChip(from: sourceID, toInsertionIndex: index) }
            )
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ChipDropZoneOffsetKey.self,
                        value: geo.frame(in: .named(ChipRowCoordinateSpace.name)).origin
                    )
                }
            )
        )
        .onPreferenceChange(ChipDropZoneOffsetKey.self) { chipDropZoneOffset = $0 }
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
                let isLast = override.bundleID == settings.appOverrides.last?.bundleID
                appChip(
                    label: override.appName,
                    icon: appIconCached(bundleID: override.bundleID),
                    bundleID: override.bundleID,
                    isSelected: selectedBundleID == override.bundleID,
                    domainKeyCount: override.overriddenKeys.intersection(domainKeys).count
                )
                .padding(.leading, dragHoverTargetID == override.bundleID && !dragHoverAtEnd ? dragHoverGap : 0)
                .padding(.trailing, dragHoverAtEnd && isLast ? dragHoverGap : 0)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ChipFramesKey.self,
                            value: [override.bundleID: geo.frame(in: .named(ChipRowCoordinateSpace.name))]
                        )
                    }
                )
            }
        }
        .coordinateSpace(name: ChipRowCoordinateSpace.name)
        .onPreferenceChange(ChipFramesKey.self) { chipFrames = $0 }
        // Animated on the combined hover state: crossing from the last chip
        // to the end-of-row zone keeps the same target ID and only flips
        // `atEnd`, so keying on the ID alone would let that gap teleport.
        .animation(
            reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.75),
            value: DragHoverState(targetID: dragHoverTargetID, atEnd: dragHoverAtEnd)
        )
        .animation(
            reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8),
            value: settings.appOverrides.map(\.bundleID)
        )
    }

    /// Reorders `sourceID` to the given insertion index (0…count, where count
    /// means past the last chip), translating to the remove-then-insert
    /// semantics of `settings.reorderAppOverrides(from:to:)`.
    private func reorderChip(from sourceID: String, toInsertionIndex insertion: Int) {
        guard let sourceIdx = settings.appOverrides.firstIndex(where: { $0.bundleID == sourceID })
        else { return }
        let count = settings.appOverrides.count
        // After removing the source, indices past it shift down by one; the
        // destination is the insertion point adjusted for that shift,
        // clamped into valid array bounds.
        let destination = min(max(insertion - (insertion > sourceIdx ? 1 : 0), 0), count - 1)
        guard destination != sourceIdx else { return }

        settings.reorderAppOverrides(from: sourceIdx, to: destination)
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
        let isArmed = bundleID != nil && dragEnabledID == bundleID
        let content = chipContent(
            label: label,
            icon: icon,
            isSelected: isSelected,
            isWindowActive: isControlActive,
            domainKeyCount: domainKeyCount
        )
        // Armed (held long enough to drag): lift the chip so the hold has
        // visible confirmation before the pointer moves.
        .scaleEffect(isArmed ? 1.06 : 1)
        .shadow(color: .black.opacity(isArmed ? 0.25 : 0), radius: isArmed ? 4 : 0, y: 2)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isArmed)
        // The visual content stays out of the accessibility tree; the
        // interaction proxy's NSView carries the chip's accessibility element.
        .accessibilityHidden(true)
        .overlay(
            ChipInteractionProxy(
                label: label,
                isSelected: isSelected,
                armDuration: longPressDuration,
                armMaxDrift: longPressMaxDrift,
                onTap: {
                    settings.selectAppOverride(bundleID: bundleID)
                    chipFocusGeneration += 1
                },
                onDoubleTap: {
                    if let bundleID {
                        renamingBundleID = bundleID
                        renameText = label
                    }
                },
                onArm: { dragEnabledID = bundleID },
                onDisarm: {
                    dragEnabledID = nil
                    dragHoverTargetID = nil
                    dragHoverAtEnd = false
                },
                dragPayload: bundleID,
                ghostImage: {
                    renderChipGhost(
                        chipContent(
                            label: label,
                            icon: icon,
                            isSelected: true,
                            isWindowActive: true,
                            domainKeyCount: 0
                        ),
                        scale: NSScreen.main?.backingScaleFactor ?? 2
                    )
                }
            )
        )

        content
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
        // accent fill; the Global chip is always visible, and a
        // solid accent pill reads as louder than a near-permanent element
        // should. Unselected chips use the system hierarchical fill so light/
        // dark, vibrancy, and Increase Contrast are hop-ons.  You’re gonna get hop-ons.
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
