import SwiftUI
import AppKit

struct ButtonMappingView: View {
    @ObservedObject var settings:      TabletSettings
    @ObservedObject var tool:          ToolSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry:      DeviceRegistry
    var productID: Int?

    private var hasTouchRing: Bool {
        guard let pid = productID else { return false }
        return WacomDeviceRegistry.spec(for: pid)?.hasTouchRing == true
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // ── Pen buttons ──────────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pen Buttons").font(.headline)
                        ToolNameLabel(tabletManager: tabletManager, registry: registry)
                    }

                    let lb = tabletManager.liveButtons
                    VStack(spacing: 2) {
                        buttonRow("Tip",          isActive: lb.tipDown,     binding: Binding(get: { tool.tipBinding },        set: { tool.tipBinding = $0 }))
                        buttonRow("Eraser",        isActive: lb.eraserDown,  binding: Binding(get: { tool.eraserBinding },     set: { tool.eraserBinding = $0 }))
                        buttonRow("Side button 1", isActive: lb.button1Down, binding: Binding(get: { tool.penButton1Binding }, set: { tool.penButton1Binding = $0 }))
                        buttonRow("Side button 2", isActive: lb.button2Down, binding: Binding(get: { tool.penButton2Binding }, set: { tool.penButton2Binding = $0 }))
                    }

                    Divider()

                    // ── Express keys ─────────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Express Keys").font(.headline)
                        DeviceNameLabel(tabletManager: tabletManager, registry: registry)
                    }

                    Text("Up to 8 configurable express keys.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 2) {
                        ForEach(0..<8, id: \.self) { i in
                            buttonRow("Key \(i + 1)",
                                      isActive: lb.expressKeys[i],
                                      binding: Binding(
                                          get: { settings.expressKeyBindings[i] },
                                          set: {
                                              var updated = settings.expressKeyBindings
                                              updated[i] = $0
                                              settings.expressKeyBindings = updated
                                          }
                                      ))
                        }
                    }

                    // ── Touch ring ───────────────────────────────────────────────
                    if hasTouchRing {
                        Divider()

                        Text("Touch Ring").font(.headline)

                        touchRingRow(isActive: lb.touchRingActive)
                    }
                }
                .padding()
            }
            PresetStatusBar(settings: settings)
        }
    }

    // MARK: - Touch ring row

    @ViewBuilder
    private func touchRingRow(isActive: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.green : Color.clear)
                .imageScale(.small)
            Text("Touch Ring")
                .frame(width: 110, alignment: .leading)
            Picker("", selection: $settings.touchRingMode) {
                ForEach(TouchRingMode.allCases, id: \.self) { mode in
                    Text(mode.displayLabel).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 160, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .animation(.easeOut(duration: 0.07), value: isActive)
    }

    // MARK: - Row helper

    @ViewBuilder
    private func buttonRow(_ label: String, isActive: Bool,
                           binding: Binding<ButtonBinding>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.green : Color.clear)
                .imageScale(.small)
            Text(label)
                .frame(width: 110, alignment: .leading)
            ButtonBindingControl(binding: binding)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .animation(.easeOut(duration: 0.07), value: isActive)
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
                Button("⌘ Command")  { binding = ButtonBinding(modifierOnly: .command) }
                Button("⌥ Option")   { binding = ButtonBinding(modifierOnly: .option)  }
                Button("⇧ Shift")    { binding = ButtonBinding(modifierOnly: .shift)   }
                Button("⌃ Control")  { binding = ButtonBinding(modifierOnly: .control) }
                Divider()
                Button("None")         { set(.none)        }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption2)
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
        if binding.kind == .none { return .secondary }
        return .primary
    }

    @ViewBuilder private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isRecording
                  ? Color.accentColor.opacity(0.07)
                  : Color(NSColor.controlBackgroundColor))
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
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
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
