// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab Authors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Requires macOS 13+ for .draggable / .dropDestination.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Drag, drop, click and keyboard plumbing for the app override bar's chips.

// MARK: - Scroll-tracking preference key

struct ChipContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Chip drag pasteboard type

/// Pasteboard type for chip-reorder drags. Only the app override bar writes
/// and reads it, and the row's drop zone additionally requires the drag
/// source to be one of its own chips.
let chipDragType = NSPasteboard.PasteboardType("com.mocktab.app-override-chip")

// MARK: - Chip frame preference key (live drop-target hit-testing)

/// Reports each app chip's frame in the chip row's coordinate space, updated
/// on every layout pass. The row's drop zone hit-tests the drag pointer
/// against these current frames; never a snapshot frozen at drag-start,
/// which goes stale as soon as the gap indicator shifts chips.
struct ChipFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Named coordinate space shared by the chip frame reporters and the row's
/// drop-zone overlay, so both speak the same geometry.
enum ChipRowCoordinateSpace {
    static let name = "AppOverrideBar.chipRow"
}

/// Reports the drop-zone overlay's origin within the row's coordinate space,
/// so it can convert chip frames (row space) into its own local space. The
/// overlay spans the full scroll-view width while the frames are relative to
/// the chip HStack, so the two origins differ.
struct ChipDropZoneOffsetKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

/// The drop hover state as a single `Equatable` value, so `.animation(value:)`
/// fires when either component changes (tuples can't conform to `Equatable`).
struct ChipDragHoverState: Equatable {
    var targetID: String?
    var atEnd: Bool
}

/// Renders a SwiftUI chip view to an `NSImage` for the drag ghost.
@MainActor
func renderChipGhost<V: View>(_ view: V, scale: CGFloat) -> NSImage? {
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
struct ChipInteractionProxy: NSViewRepresentable {
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

// MARK: - Dragged chip collapse

/// Shrinks the dragged chip, and one row spacing, to nothing while a drop gap
/// is open. Width is explicit on both ends so the change animates in step
/// with the gap. One view structure throughout: a branch would rebuild the
/// chip's NSView, which hosts the drag session, mid-press.
struct ChipCollapsedDragSource: ViewModifier {
    let width: CGFloat?
    let collapsed: Bool
    let spacing: CGFloat

    func body(content: Content) -> some View {
        let active = width != nil && collapsed
        content
            .frame(width: width.map { collapsed ? 0 : $0 }, alignment: .leading)
            .opacity(active ? 0 : 1)
            .padding(.trailing, active ? -spacing : 0)
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
struct ChipRowDropZone: NSViewRepresentable {
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

struct ChipKeyboardProxy: NSViewRepresentable {
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
