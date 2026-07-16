// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import TabletKit

/// The ring/strip/dial mode block: every mode stays visible as a one-line
/// readable summary ("Scroll · 1.5×", "Keys ⌘= / ⌘－", …), and selecting a
/// mode — by clicking its row or its wedge in the ring diagram — expands a
/// labeled editor for just that mode beneath it. Replaces the old
/// all-controls-inline rows (`TouchRingSlotRowView`), whose mixed picker/
/// slider/recorder rows never aligned with each other.
///
/// One instance renders as a single Form row containing the whole block.
/// Bindings come in as per-index factories so the caller keeps owning its
/// settings plumbing; `ledEditor` is non-nil only where the hardware has a
/// per-mode light (Xencelabs Quick Keys dial).
struct TouchRingModeListView: View {
    let slots: [ControlSlot]
    /// How many of `slots` this device exposes (model always stores 4).
    let shownSlotCount: Int
    let ringSlotCount: Int
    /// Whether the control is live and `activeSlotIndex` is meaningful.
    let isRingActive: Bool
    let activeSlotIndex: Int
    let centerDown: Bool
    /// Rings show the schematic diagram; strips have no round diagram.
    let showsDiagram: Bool
    let actionBinding: (Int) -> Binding<ControlSlot.Action>
    let speedBinding: (Int) -> Binding<Double>
    let cwBinding: (Int) -> Binding<ButtonBinding>
    let ccwBinding: (Int) -> Binding<ButtonBinding>
    /// Inline light editor per mode slot; nil (all Wacom devices) omits the
    /// summary dot and the Light row entirely.
    var ledEditor: ((Int) -> LEDColorControl)? = nil
    /// Called when the diagram's center button is clicked — callers use it
    /// to start recording in the center-click binding field, so the diagram
    /// is direct-manipulation for every part of the physical control.
    var onCenterTap: (() -> Void)? = nil

    /// Mode currently expanded for editing; nil = all collapsed (pure
    /// overview). Session-scoped view state, deliberately not persisted.
    @State private var selected: Int? = nil

    var body: some View {
        Group {
            if showsDiagram {
                // Diagram to the right of the mode list, top-anchored in a
                // fixed-width column: rows expanding and collapsing on the
                // left no longer shove it around, so it stays a stable click
                // target. The list column absorbs the width cost — long
                // localized summaries truncate before the diagram moves.
                HStack(alignment: .top, spacing: 12) {
                    modeList
                    diagram
                }
            } else {
                modeList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.15), value: selected)
    }

    private var modeList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<min(shownSlotCount, slots.count), id: \.self) { idx in
                summaryRow(idx)
                if selected == idx {
                    detailEditor(idx)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Summary rows

    private func summaryRow(_ idx: Int) -> some View {
        Button {
            selected = selected == idx ? nil : idx
        } label: {
            HStack(spacing: 0) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                    .imageScale(.small)
                    .opacity(isRingActive && activeSlotIndex == idx ? 1 : 0)
                    .accessibilityHidden(true)
                HStack(spacing: 5) {
                    // Leading chevron per DisclosureRow's house convention —
                    // the row must read as a disclosure control, not as a
                    // static label that happens to be clickable.
                    Image(systemName: "chevron.down")
                        .appFont(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(selected == idx ? -180 : 0))
                        .accessibilityHidden(true)
                    Text("Mode \(idx + 1)")
                        .foregroundStyle(.secondary)
                }
                .scaledFrame(minWidth: 100, alignment: .trailing)
                .padding(.horizontal, 5)
                Text(summaryText(idx))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .accessibilityLabel("Mode \(idx + 1): \(summaryText(idx))")
        .accessibilityHint("Opens the settings for this mode.")
    }

    /// One readable line per mode: the action, then only what qualifies it —
    /// key bindings for key modes, the speed for anything that turns.
    private func summaryText(_ idx: Int) -> String {
        let slot = slots[idx]
        switch slot.action {
        case .off, .skip:
            return slot.action.displayLabel
        case .scroll:
            return "\(slot.action.displayLabel) · \(speedLabel(slot.speed))"
        case .keyPress:
            let cw = slot.cwBinding.displayLabel
            let ccw = slot.ccwBinding.displayLabel
            return String(
                localized: "Keys \(cw) / \(ccw) · \(speedLabel(slot.speed))",
                comment: "Ring mode summary: clockwise / counter-clockwise key bindings, then speed")
        }
    }

    private func speedLabel(_ speed: Double) -> String {
        speed < 0.01
            ? String(
                localized: "Off",
                comment: "Ring speed at minimum — rotation disabled")
            : String(format: "%.2g×", speed)
    }

    // MARK: - Detail editor

    /// The labeled editor for the selected mode, boxed in a subtle inset
    /// group so its controls read as belonging to the summary row above —
    /// without the containment they floated among the neighboring rows.
    private func detailEditor(_ idx: Int) -> some View {
        let slot = slots[idx]
        return VStack(alignment: .leading, spacing: 10) {
            labeledRow(String(localized: "Action", comment: "Ring mode editor row label")) {
                Picker("", selection: actionBinding(idx)) {
                    ForEach(ControlSlot.Action.allCases, id: \.self) { action in
                        Text(action.displayLabel).tag(action)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            // Greyed (not hidden) while the mode is off/skip — the value is
            // kept and comes back when the mode does.
            labeledRow(String(localized: "Speed", comment: "Ring mode editor row label")) {
                // Snaps in the binding rather than via `step:` so it renders
                // without tick marks — one slider style everywhere.
                Slider(value: snappedSpeedBinding(idx), in: 0...3.0) { EmptyView() }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    .help("Adjust how fast the ring scrolls or repeats key presses.")
                Text(speedLabel(slot.speed))
                    .foregroundStyle(.secondary)
                    .scaledFrame(width: 40, alignment: .leading)
                    .monospacedDigit()
            }
            .disabled(slot.action == .off || slot.action == .skip)

            if slot.action == .keyPress {
                labeledRow(
                    String(localized: "Clockwise", comment: "Ring mode editor row label"),
                    symbol: "arrow.clockwise"
                ) {
                    ButtonBindingControl(
                        binding: cwBinding(idx), ringSlotCount: ringSlotCount)
                }
                labeledRow(
                    String(
                        localized: "Counterclockwise", comment: "Ring mode editor row label"),
                    symbol: "arrow.counterclockwise"
                ) {
                    ButtonBindingControl(
                        binding: ccwBinding(idx), ringSlotCount: ringSlotCount)
                }
            }

            if let ledEditor {
                labeledRow(
                    String(localized: "Light", comment: "Ring mode editor row label"),
                    symbol: "lightbulb"
                ) {
                    ledEditor(idx)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
        )
        // Indent past the summary rows' label column so the box visually
        // hangs under its summary row.
        .padding(.leading, 26)
        .padding(.vertical, 2)
        .transition(.opacity)
    }

    private var snappedSpeedBinding: (Int) -> Binding<Double> {
        { idx in
            let raw = speedBinding(idx)
            return Binding(
                get: { raw.wrappedValue },
                set: { raw.wrappedValue = ($0 * 4).rounded() / 4 })
        }
    }

    /// One editor row: a trailing-aligned label column wide enough for the
    /// longest localized text label (so every input field starts on the same
    /// vertical line), then the control. Rows whose function a familiar
    /// SF Symbol conveys pass `symbol` and show it in the label column
    /// instead; the text stays as tooltip and accessibility label.
    private func labeledRow(
        _ label: String, symbol: String? = nil, @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(spacing: 0) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                        .help(label)
                        .accessibilityLabel(label)
                } else {
                    Text(label)
                        .foregroundStyle(.secondary)
                }
            }
            .scaledFrame(minWidth: 110, alignment: .trailing)
            .padding(.trailing, 8)
            HStack(spacing: 8) { content() }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Diagram

    /// The schematic ring, captioned and clickable: a wedge selects that
    /// mode for editing (outline), while the hardware-active mode stays
    /// filled — the two states are independent. Fixed-width column so the
    /// diagram holds still while the mode list beside it grows; the caption
    /// wraps within the column (German/French run long).
    private var diagram: some View {
        VStack(spacing: 2) {
            TouchRingDiagramView(
                activeSlotIndex: activeSlotIndex,
                centerDown: centerDown,
                slotCount: ringSlotCount,
                selectedIndex: selected
            )
            .equatable()
            .frame(width: 104, height: 104)
            .overlay {
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { value in
                            if let idx = wedgeIndex(at: value.location, in: geo.size) {
                                selected = selected == idx ? nil : idx
                            } else if isCenter(value.location, in: geo.size) {
                                onCenterTap?()
                            }
                        })
                }
            }
            Text(activeCaption)
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 120)
        .padding(.top, 2)
    }

    private var activeCaption: String {
        guard isRingActive, slots.indices.contains(activeSlotIndex) else {
            return String(
                localized: "Current mode",
                comment: "Ring diagram caption while the control is inactive")
        }
        return String(
            localized: "Mode \(activeSlotIndex + 1): \(slots[activeSlotIndex].action.displayLabel)",
            comment: "Ring diagram caption naming the hardware-active mode")
    }

    /// Maps a tap inside the diagram's frame to a wedge index, mirroring the
    /// SVG layouts in TouchRingDiagramView: quarters are TL/TR/BR/BL
    /// clockwise from top-left; thirds are left/right/bottom. Taps on the
    /// center button or outside the ring select nothing.
    private func wedgeIndex(at point: CGPoint, in size: CGSize) -> Int? {
        let side = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let r = (dx * dx + dy * dy).squareRoot()
        // Ring body spans ~0.22–0.5 of the drawn diameter (center button
        // inside, empty canvas outside).
        guard r > side * 0.22, r < side * 0.5 else { return nil }
        if ringSlotCount == 3 {
            // 0° = right, 90° = down (view coordinates).
            var deg = atan2(dy, dx) * 180 / .pi
            if deg < -90 { deg += 360 }
            if deg < 30 { return 1 }        // right
            if deg < 150 { return 2 }       // bottom
            return 0                        // left
        }
        if dy < 0 { return dx < 0 ? 0 : 1 }
        return dx < 0 ? 3 : 2
    }

    /// Whether a tap landed on the diagram's center button (the disc inside
    /// the ring — same radius bound wedgeIndex excludes).
    private func isCenter(_ point: CGPoint, in size: CGSize) -> Bool {
        let side = min(size.width, size.height)
        let dx = point.x - size.width / 2
        let dy = point.y - size.height / 2
        return (dx * dx + dy * dy).squareRoot() <= side * 0.22
    }
}
