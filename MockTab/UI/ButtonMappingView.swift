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
    @ObservedObject var tool: ToolSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    var productID: Int?
    
    private var spec: WacomDeviceSpec? {
        productID.flatMap { WacomDeviceRegistry.spec(for: $0) }
    }

    private var activeToolSpec: WacomToolSpec? {
        guard let productID, let ctx = tabletManager.contexts[productID] else { return nil }
        return WacomToolCatalog.spec(forToolCode: ctx.activeToolCode)
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
            AppOverrideBar(settings: settings, domainKeys: AppOverrideBar.buttonKeys, productID: productID)
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
            .scrollContentBackground(.hidden)
            DeviceStatusBar(settings: settings, tabletManager: tabletManager, registry: registry, productID: productID ?? 0)
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
                    "Tip", isActive: lb.tipDown,
                    binding: recordingBinding(
                        "Tip Button", owner: tool,
                        get: { tool.tipBinding },
                        set: { tool.tipBinding = $0 }))
            }

            // Eraser — only for non-mouse tools
            if !isMouse {
                buttonRow(
                    "Eraser", isActive: lb.eraserDown,
                    binding: recordingBinding(
                        "Eraser Button", owner: tool,
                        get: { tool.eraserBinding },
                        set: { tool.eraserBinding = $0 }))
            }

            // Barrel/side button rows — count driven by spec
            // For airbrush (1 button): "Side button"
            // For mice: "Button 1", "Button 2", etc.
            let buttonLabel: (Int) -> String = { i in
                if isMouse {
                    return "Button \(i + 1)"
                } else {
                    return btnCount == 1 ? "Side button" : "Side button \(i + 1)"
                }
            }

            // Button 1
            if btnCount >= 1 {
                buttonRow(
                    buttonLabel(0), isActive: lb.button1Down,
                    binding: recordingBinding(
                        "Button 1", owner: tool,
                        get: { tool.penButton1Binding },
                        set: { tool.penButton1Binding = $0 }))
            }

            // Button 2
            if btnCount >= 2 {
                buttonRow(
                    buttonLabel(1), isActive: lb.button2Down,
                    binding: recordingBinding(
                        "Button 2", owner: tool,
                        get: { tool.penButton2Binding },
                        set: { tool.penButton2Binding = $0 }))
            }

            // Button 3
            if btnCount >= 3 {
                buttonRow(
                    buttonLabel(2), isActive: lb.button3Down,
                    binding: recordingBinding(
                        "Button 3", owner: tool,
                        get: { tool.penButton3Binding },
                        set: { tool.penButton3Binding = $0 }))
            }

            // Button 4
            if btnCount >= 4 {
                buttonRow(
                    buttonLabel(3), isActive: lb.button4Down,
                    binding: recordingBinding(
                        "Button 4", owner: tool,
                        get: { tool.penButton4Binding },
                        set: { tool.penButton4Binding = $0 }))
            }

            // Button 5
            if btnCount >= 5 {
                buttonRow(
                    buttonLabel(4), isActive: lb.button5Down,
                    binding: recordingBinding(
                        "Button 5", owner: tool,
                        get: { tool.penButton5Binding },
                        set: { tool.penButton5Binding = $0 }))
            }

            // Wheel row — airbrush fingerwheel or scroll wheel
            if hasWheel {
                let wheelLabel = toolSpec?.toolType == .airbrush ? "Fingerwheel" : "Scroll Wheel"
                buttonRow(
                    wheelLabel, isActive: false,
                    binding: recordingBinding(
                        "Wheel", owner: tool,
                        get: { tool.wheelBinding },
                        set: { tool.wheelBinding = $0 }))
            }

            // Diagram row: no label column; transparent so the section
            // background shows through unchanged.
            PenDiagramView(liveButtons: lb)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 64)
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                .listRowBackground(Color.clear)
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(isMouse ? "Mouse Buttons" : "Pen Buttons")
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
                Text("Express Keys")
                DeviceNameLabel(tabletManager: tabletManager, registry: registry)
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
                Text("Toggle Buttons — Left")
                DeviceNameLabel(tabletManager: tabletManager, registry: registry)
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
            .help("Action performed when sliding a finger around the touch ring.")
            
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
    
    /// Renders label text right-aligned in a fixed-width column so all control
    /// fields start at the same horizontal position regardless of which Section
    /// they live in.  100 pt comfortably fits the longest label ("Side button 1",
    /// "Fingerwheel", "Scroll Wheel") plus horizontal padding at the default font size.
    @ViewBuilder
    private func labelText(_ label: String, isActive: Bool = false) -> some View {
        Text(label)
            .foregroundStyle(Color.primary)
            .fontWeight(isActive ? .semibold : .regular)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(isActive ? 0.12 : 0))
            )
            .animation(.easeOut(duration: 0.07), value: isActive)
            .frame(width: 100, alignment: .trailing)
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
            .help("Click to record a keyboard shortcut. Press Escape to cancel or Delete to clear. Use the ▾ menu to assign a click action.")

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
            Menu {
                Button("Left Click")   { set(.leftClick)   }
                Button("Right Click")  { set(.rightClick)  }
                Button("Middle Click") { set(.middleClick) }
                Button("Eraser")       { set(.eraser)      }
                Divider()
                Button("Toggle Display") { set(.displayToggle) }
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
            .help("Assign a click action: left-click, right-click, middle-click, modifier keys, or display toggle.")

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
