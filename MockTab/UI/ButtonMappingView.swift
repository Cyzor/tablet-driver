// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026  This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab.  If not, see <https://www.gnu.org/licenses/>.

import AppKit
import SwiftUI

// MARK: - Label-width coordination

/// Collects the natural (unconstrained) width of every label text across the
/// entire view tree and reduces to the widest value.  The result is fed back
/// into each row so all control fields start at the same horizontal position
/// regardless of which Section they live in.
private struct LabelWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - ButtonMappingView

struct ButtonMappingView: View {
    @ObservedObject var settings: TabletSettings
    @ObservedObject var tool: ToolSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    var productID: Int?

    /// Shared label-column width, computed from the widest label in any row.
    /// Zero until the first layout pass completes; nil-guarded in labelText(_:)
    /// so the first render uses the natural text width rather than collapsing.
    @State private var labelColumnWidth: CGFloat = 0

    private var spec: WacomDeviceSpec? {
        productID.flatMap { WacomDeviceRegistry.spec(for: $0) }
    }

    private var hasTouchRing:   Bool { spec?.hasTouchRing   == true }
    private var hasDualRings:   Bool { spec?.hasDualRings   == true }
    private var hasTouchStrips: Bool { spec?.hasTouchStrips == true }

    // MARK: - Recording Binding Helper

    /// Creates a binding that automatically registers undo for any change.
    /// The `owner` should be the object that has the undoManager (tool or settings).
    private func recordingBinding<T>(
        _ name: String,
        owner: AnyObject,
        get: @escaping () -> T,
        set: @escaping (T) -> Void
    ) -> Binding<T> {
        Binding(
            get: get,
            set: { newValue in
                let oldValue = get()
                set(newValue)
                if let settingsOwner = owner as? TabletSettings {
                    settingsOwner.record(name) { set(oldValue) }
                } else if let toolOwner = owner as? ToolSettings {
                    toolOwner.record(name) { set(oldValue) }
                }
            }
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            AppOverrideBar(settings: settings, domainKeys: AppOverrideBar.buttonKeys)
            Form {
                let lb = tabletManager.liveButtons
                penButtonsSection(lb: lb)
                if hasDualRings {
                    dualSidedSection(lb: lb)
                } else {
                    singleSidedSection(lb: lb)
                }
            }
            .formStyle(.grouped)
//            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            // Collect the widest natural label width from every row across all
            // sections and store it so the next render locks every label column.
            .onPreferenceChange(LabelWidthKey.self) { labelColumnWidth = $0 }
            DeviceStatusBar(settings: settings, tabletManager: tabletManager, registry: registry, productID: productID ?? 0)
        }
    }

    // MARK: - Pen buttons section

    @ViewBuilder
    private func penButtonsSection(lb: LiveButtonState) -> some View {
        Section {
            buttonRow(
                "Tip", isActive: lb.tipDown,
                binding: recordingBinding(
                    "Tip Button", owner: tool,
                    get: { tool.tipBinding },
                    set: { tool.tipBinding = $0 }))
            buttonRow(
                "Eraser", isActive: lb.eraserDown,
                binding: recordingBinding(
                    "Eraser Button", owner: tool,
                    get: { tool.eraserBinding },
                    set: { tool.eraserBinding = $0 }))
            buttonRow(
                "Side button 1", isActive: lb.button1Down,
                binding: recordingBinding(
                    "Pen Button 1", owner: tool,
                    get: { tool.penButton1Binding },
                    set: { tool.penButton1Binding = $0 }))
            buttonRow(
                "Side button 2", isActive: lb.button2Down,
                binding: recordingBinding(
                    "Pen Button 2", owner: tool,
                    get: { tool.penButton2Binding },
                    set: { tool.penButton2Binding = $0 }))

            // Diagram row: no label column; transparent so the section
            // background shows through unchanged.
            PenDiagramView(liveButtons: lb)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 64)
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                .listRowBackground(Color.clear)
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pen Buttons")
                ToolNameLabel(tabletManager: tabletManager, registry: registry)
            }
        }
    }

    // MARK: - Single-sided layout (most tablets)

    @ViewBuilder
    private func singleSidedSection(lb: LiveButtonState) -> some View {
        // DeviceNameLabel heads this section so it sits between the pen section
        // and the hardware button rows, matching the original visual intent.
        Section {
            ForEach(0..<8, id: \.self) { i in
                expressKeyRow(index: i, label: "Key \(i + 1)", lb: lb)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                DeviceNameLabel(tabletManager: tabletManager, registry: registry)
                Text("Express Keys")
            }
        }

        if hasTouchRing {
            Section("Touch Ring") {
                buttonRow(
                    "Center", isActive: lb.touchRingButtonDown,
                    binding: recordingBinding(
                        "Touch Ring Button", owner: settings,
                        get: { settings.touchRingButtonBinding },
                        set: { settings.touchRingButtonBinding = $0 }))
                touchRingRow(
                    "Touch Ring", isActive: lb.touchRingActive,
                    mode: recordingBinding(
                        "Touch Ring Mode", owner: settings,
                        get: { settings.touchRingMode },
                        set: { settings.touchRingMode = $0 }))
            }
        }

        if hasTouchStrips {
            Section("Touch Strips") {
                touchRingRow(
                    "Left", isActive: lb.touchStrip1Active,
                    mode: recordingBinding(
                        "Touch Strip 1 Mode", owner: settings,
                        get: { settings.touchStrip1Mode },
                        set: { settings.touchStrip1Mode = $0 }))
                touchRingRow(
                    "Right", isActive: lb.touchStrip2Active,
                    mode: recordingBinding(
                        "Touch Strip 2 Mode", owner: settings,
                        get: { settings.touchStrip2Mode },
                        set: { settings.touchStrip2Mode = $0 }))
            }
        }
    }

    // MARK: - Dual-sided layout (Cintiq 24HD and similar)
    // Indices  0– 2 = left toggle buttons (near ring)
    // Indices  3– 7 = left express keys
    // Indices  8–10 = right toggle buttons (near ring, mirror)
    // Indices 11–15 = right express keys (mirror)
    // Both rings share the same mode setting (mirrored behavior).

    @ViewBuilder
    private func dualSidedSection(lb: LiveButtonState) -> some View {
        Section {
            ForEach(0..<3, id: \.self) { i in
                expressKeyRow(index: i, label: "Button \(i + 1)", lb: lb)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                DeviceNameLabel(tabletManager: tabletManager, registry: registry)
                Text("Toggle Buttons — Left")
            }
        }

        Section("Express Keys — Left") {
            ForEach(3..<8, id: \.self) { i in
                expressKeyRow(index: i, label: "Key \(i - 2)", lb: lb)
            }
        }

        Section("Touch Ring — Left") {
            touchRingRow(
                "Touch Ring", isActive: lb.touchRingActive,
                mode: recordingBinding(
                    "Touch Ring Mode", owner: settings,
                    get: { settings.touchRingMode },
                    set: { settings.touchRingMode = $0 }))
        }

        Section("Toggle Buttons — Right") {
            ForEach(8..<11, id: \.self) { i in
                expressKeyRow(index: i, label: "Button \(i - 7)", lb: lb)
            }
        }

        Section("Express Keys — Right") {
            ForEach(11..<16, id: \.self) { i in
                expressKeyRow(index: i, label: "Key \(i - 10)", lb: lb)
            }
        }

        Section("Touch Ring — Right") {
            touchRingRow(
                "Touch Ring", isActive: lb.touchRing2Active,
                mode: recordingBinding(
                    "Touch Ring Mode", owner: settings,
                    get: { settings.touchRingMode },
                    set: { settings.touchRingMode = $0 }))
        }
    }

    // MARK: - Express key row helper

    @ViewBuilder
    private func expressKeyRow(index: Int, label: String, lb: LiveButtonState) -> some View {
        buttonRow(
            label,
            isActive: lb.expressKeys[index],
            binding: recordingBinding(
                "Express Key \(index + 1)", owner: settings,
                get: { settings.expressKeyBindings[index] },
                set: { newValue in
                    var updated = settings.expressKeyBindings
                    updated[index] = newValue
                    settings.expressKeyBindings = updated
                }
            )
        )
    }

    // MARK: - Touch ring / strip row

    @ViewBuilder
    private func touchRingRow(
        _ label: String, isActive: Bool,
        mode: Binding<TouchRingMode>
    ) -> some View {
        HStack(spacing: 10) {
            activeIndicator(isActive)
            labelText(label, isActive: isActive)   // ← pass isActive

            // Force a pop-up menu to look like a fucking menu
            Picker("", selection: mode) {
                ForEach(TouchRingMode.allCases, id: \.self) { m in
                    Text(m.displayLabel).tag(m)
                }
            }
         // .pickerStyle(.menu)
            .labelsHidden()
            .padding(1)
            
            .controlSize(.regular)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(NSColor.controlColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
                    )
                    .shadow(radius:0.25)
            )
            
        }
    }

    // MARK: - Button binding row

    @ViewBuilder
    private func buttonRow(
        _ label: String, isActive: Bool,
        binding: Binding<ButtonBinding>
    ) -> some View {
        HStack(spacing: 0) {
            activeIndicator(isActive)
            labelText(label, isActive: isActive)   // ← pass isActive
            ButtonBindingControl(binding: binding)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        // Row-level background removed — highlight lives on the label now.
    }


    // MARK: - Shared row subviews

    /// Green checkmark when a hardware button is currently held; invisible
    /// when idle so the label column stays stable without a ghost shape.
    @ViewBuilder
    private func activeIndicator(_ isActive: Bool) -> some View {
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Color.green)
            .imageScale(.small)
            .opacity(isActive ? 1 : 0)
    }

    /// Renders label text right-aligned in a column whose width equals the
    /// widest natural label across the whole form.
    ///
    /// **Two-pass layout:**
    /// A GeometryReader in the Text background measures the natural (pre-frame)
    /// width and reports it via LabelWidthKey.  onPreferenceChange reduces all
    /// values to the maximum and stores it in labelColumnWidth.  The next pass
    /// locks every label to that shared width with trailing alignment.
    /// The > 0 guard avoids a zero-width collapse on the first render.
    @ViewBuilder
    private func labelText(_ label: String, isActive: Bool = false) -> some View {
        Text(label)
//            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .foregroundStyle(Color.primary)   // always maximum contrast; never changes
            .fontWeight(isActive ? .semibold : .regular)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(isActive ? 0.12 : 0))
            )
            .animation(.easeOut(duration: 0.07), value: isActive)
            // GeometryReader still measures the full padded width —
            // uniform across all labels so column alignment stays consistent.
            .background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: LabelWidthKey.self,
                        value: geo.size.width
                    )
                }
            }
            .frame(
                width: labelColumnWidth > 0 ? labelColumnWidth : nil,
                alignment: .trailing
            )
    }
}

// MARK: - ButtonBindingControl

/// A Bloom-style shortcut recorder control.
/// • Click the field to start recording — press any key combo to bind it.
/// • ESC cancels; Delete alone clears the binding.
/// • Use the ▾ menu to assign click actions instead of a key combo.
/// • The ✕ button clears any existing assignment.
struct ButtonBindingControl: View {
    @Binding var binding: ButtonBinding
    @State private var isRecording = false
    @State private var monitor: Any?
    /// Modifier keys accumulated while recording (before any base key is pressed).
    @State private var pendingModifiers: NSEvent.ModifierFlags = []

    var body: some View {
        HStack(spacing: 4) {
            // Recording field
            Button(action: toggleRecording) {
                HStack {
                    Text(fieldText)
                        .foregroundStyle(fieldTextColor)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(minWidth: 140, maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .background(fieldBackground)

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
            }

            // Click-action picker
            Menu {
                Button("Left Click")   { set(.leftClick)   }
                Button("Right Click")  { set(.rightClick)  }
                Button("Middle Click") { set(.middleClick) }
                Divider()
                Button("⌘ Command") { binding = ButtonBinding(modifierOnly: .command) }
                Button("⌥ Option")  { binding = ButtonBinding(modifierOnly: .option)  }
                Button("⇧ Shift")   { binding = ButtonBinding(modifierOnly: .shift)   }
                Button("⌃ Control") { binding = ButtonBinding(modifierOnly: .control) }
                Divider()
                Button("None") { set(.none) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.settingsBadge)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
        }
        .onDisappear { stopRecording() }
    }

    // MARK: - Visual state

    private var fieldText: String {
        if isRecording {
            return pendingModifiers.isEmpty
                ? "Type shortcut…"
                : modifierGlyphs(pendingModifiers) + "…"
        }
        if binding.kind == .none { return "Record Shortcut" }
        return binding.displayLabel
    }

    /// Modifier key symbols in standard macOS display order (⌃⌥⇧⌘).
    private func modifierGlyphs(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    private var fieldTextColor: Color {
        if isRecording           { return .accentColor }
        if binding.kind == .none { return .secondary   }
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
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        pendingModifiers = []
        // Monitor both keyDown (regular keys) and flagsChanged (modifier-only presses).
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            switch event.type {
            case .flagsChanged: self.handleFlagsChanged(event)
            default:            self.handleKey(event)
            }
            return nil  // consume — prevents the key from reaching any other responder
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
