// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// A Bloom-style shortcut recorder control.
/// • Click the field to start recording — press any key combo to bind it.
/// • ESC cancels; Delete alone clears the binding.
/// • Use the ▾ menu to assign click actions instead of a key combo.
/// • The ✕ button clears any existing assignment.
struct ButtonBindingControl: View, Equatable {
    @Binding var binding: ButtonBinding
    var compact: Bool = false
    var ringSlotCount: Int = 4
    @State private var isRecording = false
    @State private var monitor: Any?
    /// Modifier keys accumulated while recording (before any base key is pressed).
    @State private var pendingModifiers: NSEvent.ModifierFlags = []
    /// Set by the left-mouse-down monitor so toggleRecording() knows the
    /// click that fired the button action was the same one that already
    /// stopped recording — and should not restart it.
    @State private var stoppedByMouseDown = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.binding == rhs.binding
            && lhs.compact == rhs.compact
            && lhs.ringSlotCount == rhs.ringSlotCount
    }

    var body: some View {
        // Cached once per body call — prevents String(localized:) + CGEventFlags
        // set ops in displayLabel from firing on every SwiftUI invalidation.
        // fieldText adds recording-state placeholder text on top of displayLabel.
        let displayText = fieldText
        HStack(spacing: 4) {
            // Recording field
            Button(action: toggleRecording) {
                HStack {
                    Text(displayText)
                        .foregroundStyle(fieldTextColor)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .frame(minWidth: compact ? 60 : 140, maxWidth: compact ? 120 : .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .background(fieldBackground)
            .help(
                "Click to record a keyboard shortcut. Press Escape to cancel or Delete to clear. Use the ▾ menu to assign a click action.")

            // Clear button
            if binding.kind != .none && !isRecording {
                Button {
                    binding = .none
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .help("Clear this button assignment.")
                .accessibilityLabel("Clear button assignment")
            }

            // Click-action picker
            clickMenu
        }
        .onDisappear { if isRecording { stopRecording() } }
    }

    // MARK: - Menu

    /// Lazy menu — allocated once per ButtonBindingControl instance, not per body call.
    /// Uses direct binding assignments instead of set() to avoid retain cycles.
    private var clickMenu: some View {
        Menu {
            Button("Left Click") { binding = ButtonBinding(kind: .leftClick) }
                .help("Primary mouse button (used for drawing and selecting)")
            Button("Right Click") { binding = ButtonBinding(kind: .rightClick) }
                .help("Secondary mouse button (context menus)")
            Button("Middle Click") { binding = ButtonBinding(kind: .middleClick) }
                .help("Middle mouse button (panning in many apps)")
            Button("Middle Click + Tip") { binding = ButtonBinding(kind: .middleClickWithTip) }
                .help("Middle click only when pen tip is in contact")
            Button("Double Click") { binding = ButtonBinding(kind: .doubleClick) }
                .help("Two rapid clicks in succession")
            Button("Eraser") { binding = ButtonBinding(kind: .eraser) }
                .help("Eraser tool (pressure-sensitive in drawing apps)")
            Divider()
            Button("Spacebar") { binding = ButtonBinding(kind: .spacebar) }
                .help("Spacebar key (hand-tool in many design apps)")
            Button("Escape") {
                binding = ButtonBinding(kind: .keyCombo, keyCode: 53, modifierFlags: 0, keyLabel: "⎋")
            }
            .help("Escape key")
            Button("Toggle Display") { binding = ButtonBinding(kind: .displayToggle) }
                .help("Switch tablet mapping between displays")
            Menu("Touch Ring Mode") {
                Button("Cycle") { binding = ButtonBinding(kind: .ringCycle) }
                    .help("Cycle through ring modes")
                Divider()
                ForEach(0..<ringSlotCount, id: \.self) { i in
                    Button("Jump to Mode \(i + 1)") {
                        binding = ButtonBinding(kind: .ringSelectSlot, keyCode: UInt16(i))
                    }
                    .help("Switch ring directly to mode \(i + 1)")
                }
            }
            Divider()
            Button("⌘ Command") { binding = ButtonBinding(modifierOnly: .command) }
                .help("Hold Command modifier (⌘)")
            Button("⌥ Option") { binding = ButtonBinding(modifierOnly: .option) }
                .help("Hold Option modifier (⌥)")
            Button("⇧ Shift") { binding = ButtonBinding(modifierOnly: .shift) }
                .help("Hold Shift modifier (⇧)")
            Button("⌃ Control") { binding = ButtonBinding(modifierOnly: .control) }
                .help("Hold Control modifier (⌃)")
            Divider()
            Button("None") { binding = .none }
                .help("Disable this button")
        } label: {
            Image(systemName: "ellipsis")
                .appFont(.settingsBadge)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .accessibilityHidden(true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
        .help(
            "Assign a click action: left-click, right-click, middle-click, modifier keys, or display toggle."
        )
        .accessibilityLabel("Click action menu")
    }

    // MARK: - Visual state

    private var fieldText: String {
        if isRecording {
            return pendingModifiers.isEmpty
                ? String(
                    localized: "Type shortcut\u{2026}",
                    comment: "Placeholder in shortcut recorder field while recording")
                : modifierGlyphs(pendingModifiers) + "…"
        }
        if binding.kind == .none {
            return String(
                localized: "Record Shortcut",
                comment: "Placeholder in shortcut recorder field when empty")
        }
        return binding.displayLabel
    }

    /// Modifier key symbols in standard macOS display order (⌃⌥⇧⌘).
    private func modifierGlyphs(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    private var fieldTextColor: Color {
        if isRecording { return .accentColor }
        if binding.kind == .none { return .secondary }
        return .primary
    }

    @ViewBuilder private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(
                isRecording
                    ? Color.accentColor.opacity(0.07)
                    : Color(NSColor.controlBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isRecording ? Color.accentColor : Color(NSColor.separatorColor),
                        lineWidth: 1
                    )
            )
    }

    // MARK: - Actions

    private func set(_ kind: ButtonBinding.Kind) {
        stopRecording()
        binding = ButtonBinding(kind: kind)
    }

    private func toggleRecording() {
        // The left-mouse-down monitor already stopped recording on the mouse-down
        // event that caused this button action to fire. Don't restart — the user
        // clicked this field to dismiss, not to begin a new recording.
        if stoppedByMouseDown {
            stoppedByMouseDown = false
            return
        }
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        stoppedByMouseDown = false
        isRecording = true
        pendingModifiers = []
        // Monitor keyDown and flagsChanged (keyboard input) plus leftMouseDown.
        // leftMouseDown is passed through (return event) so the click reaches its
        // target — which may be another field that then starts its own recording,
        // naturally enforcing single-field mutual exclusion without coordination.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown]
        ) { event in
            switch event.type {
            case .flagsChanged:
                self.handleFlagsChanged(event)
                return nil
            case .leftMouseDown:
                self.stoppedByMouseDown = true
                self.stopRecording()
                return event  // pass through — click reaches its target
            default:
                self.handleKey(event)
                return nil
            }
        }
    }

    private func stopRecording() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        isRecording = false
        pendingModifiers = []
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let current = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function, .help])
        if current.isEmpty {
            // Every modifier key has been released.
            guard !pendingModifiers.isEmpty else { return }
            binding = ButtonBinding(modifierOnly: pendingModifiers)
            stopRecording()
        } else {
            // Accumulate — releasing one modifier of a combo (e.g. ⌘ before ⇧)
            // must not lose the earlier modifier from the committed set.
            pendingModifiers.formUnion(current)
        }
    }

    private func handleKey(_ event: NSEvent) {
        let bare = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 && bare.isEmpty {
            // ESC alone → cancel without changing the binding
        } else if event.keyCode == 51 && bare.isEmpty {
            // Delete alone → clear
            binding = .none
        } else {
            binding = ButtonBinding(fromKey: event)
        }
        stopRecording()
    }
}
