// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// How the Buttons pane names a turned tablet's rings, dials, and modes: by
/// where you see them. Saved bindings still name the physical ring or dial
/// and slot, so this only translates between the two.
struct RotaryPlacement: Equatable {
    /// The two rings or dials have traded places as you see them.
    var tradesRotaries = false
    /// Places a four-lamp ring's lamps have moved around it: the mode you see
    /// in place m is saved slot m + `lampShift`, wrapping at four.
    var lampShift = 0

    static let upright = RotaryPlacement()

    /// `binding` as you see it, naming the ring or dial and mode in their places.
    func shown(_ binding: ButtonBinding) -> ButtonBinding { moved(binding, slotBy: -lampShift) }

    /// What to save for `binding`, chosen as you see it.
    func saved(_ binding: ButtonBinding) -> ButtonBinding { moved(binding, slotBy: lampShift) }

    /// Mode names by place, from names by saved ring or dial and slot.
    func shown(modeNames: [[String]]) -> [[String]] {
        let rows = tradesRotaries && modeNames.count == 2 ? modeNames.reversed() : modeNames
        return rows.map { row in
            row.count == 4 ? row.indices.map { row[($0 + lampShift) % 4] } : row
        }
    }

    private func moved(_ binding: ButtonBinding, slotBy shift: Int) -> ButtonBinding {
        var moved = binding
        switch binding.kind {
        case .ringCycle: moved.kind = tradesRotaries ? .ringCycle2 : .ringCycle
        case .ringCycle2: moved.kind = tradesRotaries ? .ringCycle : .ringCycle2
        case .ringSelectSlot: moved.kind = tradesRotaries ? .ringSelectSlot2 : .ringSelectSlot
        case .ringSelectSlot2: moved.kind = tradesRotaries ? .ringSelectSlot : .ringSelectSlot2
        default: return binding
        }
        if lampShift != 0, binding.kind == .ringSelectSlot || binding.kind == .ringSelectSlot2, binding.keyCode < 4 {
            moved.keyCode = UInt16(((Int(binding.keyCode) + shift) % 4 + 4) % 4)
        }
        return moved
    }
}

/// A Bloom-style shortcut recorder control.
/// • Click the field to start recording — press any key combo to bind it.
/// • ESC cancels; Delete alone clears the binding.
/// • Use the menu beside the field to assign click actions instead of a key combo.
/// • The ✕ button clears any existing assignment.
struct ButtonBindingControl: View, Equatable {
    @Binding var binding: ButtonBinding
    var compact: Bool = false
    var ringSlotCount: Int = 4
    /// Offer the second dial or ring's actions in the mode submenu. Only for
    /// ExpressKeys on two-rotary hardware, not pen or bezel buttons.
    var offersSecondDial: Bool = false
    /// Offer Eraser. Only the eraser end and side buttons can act as the
    /// eraser; anywhere else it would click.
    var offersEraser: Bool = false
    /// What each rotary's modes do, so a jump-to-mode binding can name the
    /// function ("Right Ring: Zoom") instead of the slot.
    var modeNames: [[String]] = []
    /// The hardware has a mechanical dial, not a touch ring. Picks "Dial"
    /// or "Ring" wording. See `ButtonMappingView.hasMechanicalDial`.
    var isMechanicalDialHardware: Bool = false
    /// Set on a PTK dial's own toggle key. The mode submenu then collapses to
    /// one flat Cycle item aimed at this dial.
    var dialToggleControl: RotaryIndex? = nil
    /// Names rings, dials, and modes by where they sit on a turned tablet.
    var placement: RotaryPlacement = .upright
    /// Offer the ring or dial mode actions: only on a device's own keys, and
    /// only when it has a ring, dial, or strip whose modes MockTab keeps.
    var offersRingModes: Bool = false
    /// Offer jumping straight to a mode, for hardware whose own mode keys
    /// pick a mode (Cintiq 24HD, MobileStudio Pro) instead of cycling.
    var offersModeJumps: Bool = false
    /// Incremented by an external control (the ring diagram's center button)
    /// to begin recording in this field, exactly as if it had been clicked.
    var recordRequestToken: Int = 0
    @State private var isRecording = false
    @State private var monitor: Any?
    /// Modifier keys accumulated while recording (before any base key is pressed).
    @State private var pendingModifiers: NSEvent.ModifierFlags = []
    /// Event number of the click that stopped recording. Its mouse-up shares
    /// the number, so toggleRecording() ignores only that click, not a later one.
    @State private var stoppingClick: Int?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // SwiftUI compares views on the main actor.
        MainActor.assumeIsolated {
            lhs.binding == rhs.binding
                && lhs.compact == rhs.compact
                && lhs.ringSlotCount == rhs.ringSlotCount
                && lhs.offersSecondDial == rhs.offersSecondDial
                && lhs.offersEraser == rhs.offersEraser
                && lhs.modeNames == rhs.modeNames
                && lhs.isMechanicalDialHardware == rhs.isMechanicalDialHardware
                && lhs.dialToggleControl == rhs.dialToggleControl
                && lhs.placement == rhs.placement
                && lhs.offersRingModes == rhs.offersRingModes
                && lhs.offersModeJumps == rhs.offersModeJumps
                && lhs.recordRequestToken == rhs.recordRequestToken
        }
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
                "Click to record a keyboard shortcut. Press Escape to cancel or Delete to clear. Use the menu next to it to assign a click action.")

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
        .onChange(of: recordRequestToken) { _ in
            if !isRecording { startRecording() }
        }
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
            Button("Pan View") { binding = ButtonBinding(kind: .scrollDrag) }
                .help("Hold to pan or scroll by moving the pen, like a hand tool")
            Button("Double Click") { binding = ButtonBinding(kind: .doubleClick) }
                .help("Two rapid clicks in succession")
            Button("Click Lock") { binding = ButtonBinding(kind: .clickLock) }
                .help("Press once to hold the left button, press again or lift the pen away to release")
            if offersEraser {
                Button("Eraser") { binding = ButtonBinding(kind: .eraser) }
                    .help("Eraser tool (pressure-sensitive in drawing apps)")
            }
            Divider()
            Button("Spacebar") { binding = ButtonBinding(kind: .spacebar) }
                .help("Spacebar key (hand-tool in many design apps)")
            Button("Escape") {
                binding = ButtonBinding(kind: .keyCombo, keyCode: 53, modifierFlags: 0, keyLabel: "⎋")
            }
            .help("Escape key")
            Button("Toggle Display") { binding = ButtonBinding(kind: .displayToggle) }
                .help("Switch tablet mapping between displays")
            Button("Span Displays") { binding = ButtonBinding(kind: .spanDisplaysToggle) }
                .help("Spread the tablet across the displays selected in the Display pane. Press again to return to the previous display setting.")
            Button("Toggle Relative Mode") { binding = ButtonBinding(kind: .relativeModeToggle) }
                .help("Switch between absolute (stylus) and relative (mouse) cursor movement")
            if let control = dialToggleControl {
                Button("Cycle Dial Mode") {
                    binding = ButtonBinding(kind: control == .second ? .ringCycle2 : .ringCycle)
                }
                .help("Cycle through dial modes")
            } else if offersRingModes && !offersModeJumps && !offersSecondDial {
                // Cycle alone needs no submenu.
                Button(isMechanicalDialHardware ? "Cycle Dial Mode" : "Cycle Touch Ring Mode") {
                    binding = placement.saved(ButtonBinding(kind: .ringCycle))
                }
                .help(isMechanicalDialHardware ? "Cycle through dial modes" : "Cycle through ring modes")
            } else if offersRingModes {
                // Items name rings, dials, and modes where you see them;
                // `placement` turns each into what to save.
                Menu(isMechanicalDialHardware ? "Dial Mode" : "Touch Ring Mode") {
                    if hasTwoRings {
                        Button("Cycle (Left Ring)") { binding = placement.saved(ButtonBinding(kind: .ringCycle)) }
                            .help("Cycle through the left ring's modes")
                    } else {
                        Button("Cycle") { binding = placement.saved(ButtonBinding(kind: .ringCycle)) }
                            .help(isMechanicalDialHardware ? "Cycle through dial modes" : "Cycle through ring modes")
                    }
                    if offersModeJumps {
                        Divider()
                        ForEach(0..<ringSlotCount, id: \.self) { i in
                            Button(hasTwoRings ? "Jump Left Ring to Mode \(i + 1)" : "Jump to Mode \(i + 1)") {
                                binding = placement.saved(ButtonBinding(kind: .ringSelectSlot, keyCode: UInt16(i)))
                            }
                            .help(isMechanicalDialHardware
                                ? "Switch the dial directly to mode \(i + 1)"
                                : hasTwoRings
                                    ? "Switch the left ring directly to mode \(i + 1)"
                                    : "Switch ring directly to mode \(i + 1)")
                        }
                    }
                    if offersSecondDial {
                        Divider()
                        if hasTwoRings {
                            Button("Cycle (Right Ring)") { binding = placement.saved(ButtonBinding(kind: .ringCycle2)) }
                                .help("Cycle through the right ring's modes")
                        } else {
                            Button("Cycle (Second Dial)") { binding = placement.saved(ButtonBinding(kind: .ringCycle2)) }
                                .help("Cycle through the second dial's modes")
                        }
                        if offersModeJumps {
                            Divider()
                            ForEach(0..<ringSlotCount, id: \.self) { i in
                                Button(hasTwoRings ? "Jump Right Ring to Mode \(i + 1)" : "Jump Second Dial to Mode \(i + 1)") {
                                    binding = placement.saved(ButtonBinding(kind: .ringSelectSlot2, keyCode: UInt16(i)))
                                }
                                .help(hasTwoRings
                                    ? "Switch the right ring directly to mode \(i + 1)"
                                    : "Switch the second dial directly to mode \(i + 1)")
                            }
                        }
                    }
                }
            }
            Divider()
            Button("⌘ Command") { binding = ButtonBinding(modifierOnly: .command) }
                .help("Hold Command while the button is down")
            Button("⌥ Option") { binding = ButtonBinding(modifierOnly: .option) }
                .help("Hold Option while the button is down")
            Button("⇧ Shift") { binding = ButtonBinding(modifierOnly: .shift) }
                .help("Hold Shift while the button is down")
            Button("⌃ Control") { binding = ButtonBinding(modifierOnly: .control) }
                .help("Hold Control while the button is down")
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
            "Assign a click, modifier key, display switch, or other action instead of a shortcut."
        )
        .accessibilityLabel("Click action menu")
    }

    /// Two touch rings, as on the Cintiq 24HD: menus and labels say left and
    /// right instead of first and second.
    private var hasTwoRings: Bool { offersSecondDial && !isMechanicalDialHardware }

    private var modeFunctionText: String? {
        placement.shown(binding).modeFunctionLabel(
            modeNames: placement.shown(modeNames: modeNames), isMechanicalDial: isMechanicalDialHardware)
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
        if let text = modeFunctionText { return text }
        // Say "Dial" on dial hardware. Display-only: `displayLabel` stays
        // device-unaware because presets and undo text share it. A toggle
        // key cycling its own dial reads the same wherever the dial sits.
        if let control = dialToggleControl, binding.kind == (control == .second ? .ringCycle2 : .ringCycle) {
            return String(localized: "Dial: Cycle", comment: "Button action: cycle a mechanical dial's mode")
        }
        let shown = placement.shown(binding)
        if hasTwoRings {
            switch shown.kind {
            case .ringCycle:
                return String(localized: "Left Ring: Cycle", comment: "Button action: cycle the left touch ring's mode")
            case .ringSelectSlot:
                return String(
                    localized: "Left Ring: Mode \(shown.keyCode + 1)",
                    comment: "Button action: jump the left touch ring to a mode slot")
            case .ringCycle2:
                return String(localized: "Right Ring: Cycle", comment: "Button action: cycle the right touch ring's mode")
            case .ringSelectSlot2:
                return String(
                    localized: "Right Ring: Mode \(shown.keyCode + 1)",
                    comment: "Button action: jump the right touch ring to a mode slot")
            default: break
            }
        }
        if isMechanicalDialHardware {
            switch shown.kind {
            case .ringCycle where dialToggleControl != .second:
                return String(localized: "Dial: Cycle", comment: "Button action: cycle a mechanical dial's mode")
            case .ringSelectSlot:
                return String(
                    localized: "Dial: Mode \(shown.keyCode + 1)",
                    comment: "Button action: jump to a mechanical dial's mode slot")
            default: break
            }
        }
        return shown.displayLabel
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
        // The click that fired this action already stopped recording on its
        // mouse-down; the user clicked this field to dismiss, not to restart.
        let stopping = stoppingClick
        stoppingClick = nil
        if let stopping, NSApp.currentEvent?.eventNumber == stopping { return }
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        stoppingClick = nil
        isRecording = true
        pendingModifiers = []
        // leftMouseDown passes through, so clicking another field starts its
        // recording and ends this one without extra coordination.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown]
        ) { event in
            switch event.type {
            case .flagsChanged:
                self.handleFlagsChanged(event)
                return nil
            case .leftMouseDown:
                self.stoppingClick = event.eventNumber
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
