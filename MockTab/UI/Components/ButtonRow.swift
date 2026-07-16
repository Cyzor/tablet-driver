// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Shared row layout for a single button binding — a proximity/press
/// indicator, a label, and the shortcut-recorder control. Used by every
/// pane section that lists assignable buttons (pen buttons, express keys,
/// bezel buttons, Quick Keys) so they stay visually identical.
@ViewBuilder
func buttonRow(
    _ label: String, isActive: Bool,
    binding: Binding<ButtonBinding>,
    ringSlotCount: Int = 4,
    recordRequestToken: Int = 0
) -> some View {
    HStack(spacing: 0) {
        activeIndicator(isActive)
        // Fixed minimum width with trailing alignment so the binding control
        // starts at a consistent x position regardless of label length.
        labelText(label, isActive: isActive)
            .scaledFrame(minWidth: 100, alignment: .trailing)
        ButtonBindingControl(
            binding: binding, ringSlotCount: ringSlotCount,
            recordRequestToken: recordRequestToken)
            .equatable()
        Spacer(minLength: 0)
    }
}

/// Green checkmark when a hardware button is currently held; invisible
/// when idle so the label column stays stable without a ghost shape.
func activeIndicator(_ isActive: Bool) -> some View {
    Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(Color.green)
        .imageScale(.small)
        .opacity(isActive ? 1 : 0)
        .accessibilityHidden(true)
}

func labelText(_ label: String, isActive: Bool) -> some View {
    Text(label)
        .foregroundStyle(Color.primary)
        .fontWeight(isActive ? .semibold : .regular)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.accentColor.opacity(isActive ? 0.12 : 0))
        )
}
