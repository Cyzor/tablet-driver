// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import TabletKit

/// One row in the touch-ring slot list. Extracted so `.equatable()` can short-circuit
/// body evaluation on resize frames when neither slot data nor active state has changed.
struct TouchRingSlotRowView: View, Equatable {
    let slot: ControlSlot
    let idx: Int
    let isActiveSlot: Bool
    let ringSlotCount: Int
    let actionBinding: Binding<ControlSlot.Action>
    let speedBinding: Binding<Double>
    let cwBinding: Binding<ButtonBinding>
    let ccwBinding: Binding<ButtonBinding>
    /// Dial-LED control for this mode slot; nil (all Wacom call sites) hides
    /// the color well entirely. Xencelabs Quick Keys only.
    var ledWell: LEDColorControl? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.slot == rhs.slot
            && lhs.idx == rhs.idx
            && lhs.isActiveSlot == rhs.isActiveSlot
            && lhs.ringSlotCount == rhs.ringSlotCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                    .imageScale(.small)
                    .opacity(isActiveSlot ? 1 : 0)
                    .accessibilityHidden(true)
                Text("Mode \(idx + 1)")
                    .foregroundStyle(.secondary)
                    .scaledFrame(minWidth: 100, alignment: .trailing)
                    .padding(.horizontal, 5)
                Picker("", selection: actionBinding) {
                    ForEach(ControlSlot.Action.allCases, id: \.self) { action in
                        Text(action.displayLabel).tag(action)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()

                if slot.action != .off && slot.action != .skip {
                    let speedLabel = slot.speed < 0.01
                        ? String(
                            localized: "Off",
                            comment: "Ring speed slider at minimum — rotation disabled")
                        : String(format: "%.2g×", slot.speed)
                    Text(speedLabel)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .scaledFrame(width: 36, alignment: .trailing)
                        .monospacedDigit()
                        .padding(.leading, 8)
                    Slider(value: speedBinding, in: 0...3.0, step: 0.25)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                        .help("Adjust how fast the ring scrolls or repeats key presses.")
                        .padding(.trailing, ledWell == nil ? 40 : 12)
                } else {
                    Spacer(minLength: 10)
                }

                if let ledWell {
                    // Compact light dot → the shared swatch/brightness
                    // editor in a popover (LEDColorControl). Sets the dial's
                    // LED for this mode. Trailing-edge placement after the
                    // flexible slider/spacer keeps every row's well on one
                    // vertical line — inline placement next to the action
                    // picker made them wander with the picker's width.
                    ledWell
                        .fixedSize()
                        .padding(.trailing, 40)
                        .help("Dial LED color and brightness while this mode is active.")
                        .accessibilityLabel("Dial LED color")
                }
            }

            if slot.action == .keyPress {
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .appFont(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Clockwise")
                        ButtonBindingControl(
                            binding: cwBinding, compact: true,
                            ringSlotCount: ringSlotCount)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .appFont(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Counter-clockwise")
                        ButtonBindingControl(
                            binding: ccwBinding, compact: true,
                            ringSlotCount: ringSlotCount)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}
