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

// MARK: - ButtonMappingView

struct ButtonMappingView: View {
    @ObservedObject var settings: TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    var productID: Int?

    private var tool: ToolSettings { settings.activeTool }

    // Pre-allocated Binding<ToolSettings> — created once, not per body call.
    // Used to derive Binding<ButtonBinding> for each key path so SwiftUI
    // view identity is stable across ~16 Hz liveButtons invalidations.
    private var activeToolBinding: Binding<ToolSettings> {
        $settings.activeTool
    }

    private var pen1Binding: Binding<ButtonBinding> {
        Binding(
            get: { tool.penButton1Binding },
            set: { newValue in
                let tool = self.tool
                let t = self.activeToolBinding
                settings.record("Button 1") { t.wrappedValue.penButton1Binding = newValue }
            }
        )
    }
    private var pen2Binding: Binding<ButtonBinding> {
        Binding(
            get: { tool.penButton2Binding },
            set: { newValue in
                let tool = self.tool
                let t = self.activeToolBinding
                settings.record("Button 2") { t.wrappedValue.penButton2Binding = newValue }
            }
        )
    }
    private var pen3Binding: Binding<ButtonBinding> {
        Binding(
            get: { tool.penButton3Binding },
            set: { newValue in
                let tool = self.tool
                let t = self.activeToolBinding
                settings.record("Button 3") { t.wrappedValue.penButton3Binding = newValue }
            }
        )
    }
    private var pen4Binding: Binding<ButtonBinding> {
        Binding(
            get: { tool.penButton4Binding },
            set: { newValue in
                let tool = self.tool
                let t = self.activeToolBinding
                settings.record("Button 4") { t.wrappedValue.penButton4Binding = newValue }
            }
        )
    }
    private var pen5Binding: Binding<ButtonBinding> {
        Binding(
            get: { tool.penButton5Binding },
            set: { newValue in
                let tool = self.tool
                let t = self.activeToolBinding
                settings.record("Button 5") { t.wrappedValue.penButton5Binding = newValue }
            }
        )
    }
    private var tipBinding: Binding<ButtonBinding> {
        Binding(
            get: { tool.tipBinding },
            set: { newValue in
                let tool = self.tool
                let t = self.activeToolBinding
                settings.record("Tip Button") { t.wrappedValue.tipBinding = newValue }
            }
        )
    }
    private var eraserBinding: Binding<ButtonBinding> {
        Binding(
            get: { tool.eraserBinding },
            set: { newValue in
                let tool = self.tool
                let t = self.activeToolBinding
                settings.record("Eraser Button") { t.wrappedValue.eraserBinding = newValue }
            }
        )
    }
    private var wheelBinding: Binding<ButtonBinding> {
        Binding(
            get: { tool.wheelBinding },
            set: { newValue in
                let tool = self.tool
                let t = self.activeToolBinding
                settings.record("Wheel") { t.wrappedValue.wheelBinding = newValue }
            }
        )
    }

    private var spec: WacomDeviceSpec? {
        productID.flatMap { WacomDeviceRegistry.spec(for: $0) }
    }

    private var activeToolSpec: WacomToolSpec? {
        guard let productID, let ctx = tabletManager.contexts[productID] else { return nil }
        return WacomToolCatalog.spec(forToolCode: ctx.activeToolCode)
    }

    private var hasTouchRing: Bool { spec?.hasTouchRing == true }
    private var hasDualRings: Bool { spec?.hasDualRings == true }
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
            AppOverrideBar(
                settings: settings, domainKeys: AppOverrideBar.buttonKeys, productID: productID)
            Form {
                penButtonsSection(lb: tabletManager.liveButtons)
                if hasDualRings {
                    dualSidedSection(lb: tabletManager.liveButtons)
                } else {
                    singleSidedSection(lb: tabletManager.liveButtons)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            DeviceStatusBar(
                settings: settings, tabletManager: tabletManager, registry: registry,
                productID: productID ?? 0)
        }
    }

    // MARK: - Pen buttons section

    @ViewBuilder
    private func penButtonsSection(lb: LiveButtonState) -> some View {
        let toolSpec = activeToolSpec
        let isMouse = toolSpec?.toolType == .mouse
        // For mice, show all 5 HID-path button slots regardless of spec.buttonCount
        // (spec.buttonCount describes only the digitizer path, not the full HID mouse report)
        let btnCount = isMouse ? 5 : (toolSpec?.buttonCount ?? 2)
        let hasWheel = toolSpec?.hasWheel == true

        Section {
            // Tip — only for non-mouse tools
            if !isMouse {
                buttonRow(
                    String(localized: "Tip", comment: "Pen tip button row label in Buttons tab"),
                    isActive: lb.tipDown,
                    binding: tipBinding)
            }

            // Eraser — only for non-mouse tools
            if !isMouse {
                buttonRow(
                    String(localized: "Eraser", comment: "Eraser button row label in Buttons tab"),
                    isActive: lb.eraserDown,
                    binding: eraserBinding)
            }

            // Button 1
            if btnCount >= 1 {
                buttonRow(
                    isMouse ? "Button 1" : (btnCount == 1 ? "Side button" : "Side button 1"),
                    isActive: lb.button1Down,
                    binding: recordingBinding(
                        "Button 1", owner: tool,
                        get: { tool.penButton1Binding },
                        set: { tool.penButton1Binding = $0 }))
            }
            // Button 2
            if btnCount >= 2 {
                buttonRow(
                    isMouse ? "Button 2" : "Side button 2",
                    isActive: lb.button2Down,
                    binding: recordingBinding(
                        "Button 2", owner: tool,
                        get: { tool.penButton2Binding },
                        set: { tool.penButton2Binding = $0 }))
            }
            // Button 3
            if btnCount >= 3 {
                buttonRow(
                    isMouse ? "Button 3" : "Side button 3",
                    isActive: lb.button3Down,
                    binding: recordingBinding(
                        "Button 3", owner: tool,
                        get: { tool.penButton3Binding },
                        set: { tool.penButton3Binding = $0 }))
            }
            // Button 4
            if btnCount >= 4 {
                buttonRow(
                    isMouse ? "Button 4" : "Side button 4",
                    isActive: lb.button4Down,
                    binding: recordingBinding(
                        "Button 4", owner: tool,
                        get: { tool.penButton4Binding },
                        set: { tool.penButton4Binding = $0 }))
            }
            // Button 5
            if btnCount >= 5 {
                buttonRow(
                    isMouse ? "Button 5" : "Side button 5",
                    isActive: lb.button5Down,
                    binding: recordingBinding(
                        "Button 5", owner: tool,
                        get: { tool.penButton5Binding },
                        set: { tool.penButton5Binding = $0 }))
            }

            // Wheel row — airbrush fingerwheel or scroll wheel
            if hasWheel {
                let wheelLabel =
                    toolSpec?.toolType == .airbrush
                    ? String(localized: "Fingerwheel", comment: "Airbrush fingerwheel row label")
                    : String(localized: "Scroll Wheel", comment: "Mouse scroll wheel row label")
                buttonRow(wheelLabel, isActive: false, binding: wheelBinding)
            }

            // Diagram row: no label column; transparent so the section
            // background shows through unchanged.
            PenDiagramView(liveButtons: lb)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 64)
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                .listRowBackground(Color.clear)
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(isMouse ? "Mouse Buttons" : "Pen Buttons"))
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
                expressKeyRow(
                    index: i,
                    label: String(
                        localized: "Key \(i + 1)", comment: "Express key N label, e.g. 'Key 1'"),
                    lb: lb)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("Express Keys"))
                DeviceNameLabel(tabletManager: tabletManager, registry: registry)
            }
        }

        if hasTouchRing {
            Section(LocalizedStringKey("Touch Ring")) {
                buttonRow(
                    String(localized: "Center", comment: "Touch ring center button row label"),
                    isActive: lb.touchRingButtonDown,
                    binding: recordingBinding(
                        "Touch Ring Button", owner: settings,
                        get: { settings.touchRingButtonBinding },
                        set: { settings.touchRingButtonBinding = $0 }))
                touchRingRow(
                    String(
                        localized: "Touch Ring",
                        comment: "Section header / row label for touch ring"),
                    isActive: lb.touchRingActive,
                    mode: recordingBinding(
                        "Touch Ring Mode", owner: settings,
                        get: { settings.touchRingMode },
                        set: { settings.touchRingMode = $0 }))
            }
        }

        if hasTouchStrips {
            Section(LocalizedStringKey("Touch Strips")) {
                touchRingRow(
                    String(localized: "Left", comment: "Left touch strip row label"),
                    isActive: lb.touchStrip1Active,
                    mode: recordingBinding(
                        "Touch Strip 1 Mode", owner: settings,
                        get: { settings.touchStrip1Mode },
                        set: { settings.touchStrip1Mode = $0 }))
                touchRingRow(
                    String(localized: "Right", comment: "Right touch strip row label"),
                    isActive: lb.touchStrip2Active,
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
                expressKeyRow(
                    index: i,
                    label: String(
                        localized: "Button \(i + 1)",
                        comment: "Toggle button N label, e.g. 'Button 1'"), lb: lb)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey("Toggle Buttons — Left"))
                DeviceNameLabel(tabletManager: tabletManager, registry: registry)
            }
        }

        Section(LocalizedStringKey("Express Keys — Left")) {
            ForEach(3..<8, id: \.self) { i in
                expressKeyRow(
                    index: i,
                    label: String(
                        localized: "Key \(i - 2)", comment: "Express key N label, e.g. 'Key 1'"),
                    lb: lb)
            }
        }

        Section(LocalizedStringKey("Touch Ring — Left")) {
            touchRingRow(
                String(
                    localized: "Touch Ring", comment: "Section header / row label for touch ring"),
                isActive: lb.touchRingActive,
                mode: recordingBinding(
                    "Touch Ring Mode", owner: settings,
                    get: { settings.touchRingMode },
                    set: { settings.touchRingMode = $0 }))
        }

        Section(LocalizedStringKey("Toggle Buttons — Right")) {
            ForEach(8..<11, id: \.self) { i in
                expressKeyRow(
                    index: i,
                    label: String(
                        localized: "Button \(i - 7)",
                        comment: "Toggle button N label, e.g. 'Button 1'"), lb: lb)
            }
        }

        Section(LocalizedStringKey("Express Keys — Right")) {
            ForEach(11..<16, id: \.self) { i in
                expressKeyRow(
                    index: i,
                    label: String(
                        localized: "Key \(i - 10)", comment: "Express key N label, e.g. 'Key 1'"),
                    lb: lb)
            }
        }

        Section(LocalizedStringKey("Touch Ring — Right")) {
            touchRingRow(
                String(
                    localized: "Touch Ring", comment: "Section header / row label for touch ring"),
                isActive: lb.touchRing2Active,
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
            labelText(label, isActive: isActive)  // ← pass isActive

            // Force a pop-up menu to look like a fucking menu
            Picker("", selection: mode) {
                ForEach(TouchRingMode.allCases, id: \.self) { m in
                    Text(m.displayLabel).tag(m)
                }
            }
            // .pickerStyle(.menu)
            .labelsHidden()
            .padding(1)
            .help(
                LocalizedStringKey("Action performed when sliding a finger around the touch ring.")
            )

            .controlSize(.regular)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(NSColor.controlColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
                    )
                    .shadow(radius: 0.25)
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
            labelText(label, isActive: isActive)
            ButtonBindingControl(binding: binding)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Shared row subviews

    /// Green checkmark when a hardware button is currently held; invisible
    /// when idle so the label column stays stable without a ghost shape.
    private func activeIndicator(_ isActive: Bool) -> some View {
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Color.green)
            .imageScale(.small)
            .opacity(isActive ? 1 : 0)
    }

    private func labelText(_ label: String, isActive: Bool) -> some View {
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
        // Cached once per body call — prevents String(localized:) + CGEventFlags
        // set ops in displayLabel from firing on every SwiftUI invalidation.
        let displayText = binding.displayLabel
        HStack(spacing: 4) {
            // Recording field
            Button(action: toggleRecording) {
                HStack {
                    Text(displayText)
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
            .help(
                LocalizedStringKey(
                    "Click to record a keyboard shortcut. Press Escape to cancel or Delete to clear. Use the ▾ menu to assign a click action."
                ))

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
            Button("Right Click") { binding = ButtonBinding(kind: .rightClick) }
            Button("Middle Click") { binding = ButtonBinding(kind: .middleClick) }
            Button("Double Click") { binding = ButtonBinding(kind: .doubleClick) }
            Button("Eraser") { binding = ButtonBinding(kind: .eraser) }
            Divider()
            Button("Spacebar") { binding = ButtonBinding(kind: .spacebar) }
            Button("Toggle Display") { binding = ButtonBinding(kind: .displayToggle) }
            Divider()
            Button("⌘ Command") { binding = ButtonBinding(modifierOnly: .command) }
            Button("⌥ Option") { binding = ButtonBinding(modifierOnly: .option) }
            Button("⇧ Shift") { binding = ButtonBinding(modifierOnly: .shift) }
            Button("⌃ Control") { binding = ButtonBinding(modifierOnly: .control) }
            Divider()
            Button("None") { binding = .none }
        } label: {
            Image(systemName: "ellipsis")
                .font(.settingsBadge)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
        .help(
            "Assign a click action: left-click, right-click, middle-click, modifier keys, or display toggle."
        )
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
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        pendingModifiers = []
        // Monitor both keyDown (regular keys) and flagsChanged (modifier-only presses).
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            switch event.type {
            case .flagsChanged: self.handleFlagsChanged(event)
            default: self.handleKey(event)
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
