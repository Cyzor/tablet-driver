import SwiftUI
import AppKit

struct ButtonMappingView: View {
    @ObservedObject var settings: TabletSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // ── Pen buttons ──────────────────────────────────────────────
                Text("Pen Buttons").font(.headline)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Side button 1").frame(width: 110, alignment: .leading)
                        ButtonBindingControl(binding: Binding(
                            get: { settings.penButton1Binding },
                            set: { settings.penButton1Binding = $0 }
                        ))
                    }
                    GridRow {
                        Text("Side button 2").frame(width: 110, alignment: .leading)
                        ButtonBindingControl(binding: Binding(
                            get: { settings.penButton2Binding },
                            set: { settings.penButton2Binding = $0 }
                        ))
                    }
                }

                Divider()

                // ── Express keys ─────────────────────────────────────────────
                Text("Express Keys").font(.headline)

                Text("Up to 8 express keys on the PTH-860 (PTH-851 has none).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(0..<8, id: \.self) { i in
                        GridRow {
                            Text("Key \(i + 1)").frame(width: 110, alignment: .leading)
                            ButtonBindingControl(binding: Binding(
                                get: { settings.expressKeyBindings[i] },
                                set: {
                                    var updated = settings.expressKeyBindings
                                    updated[i] = $0
                                    settings.expressKeyBindings = updated
                                }
                            ))
                        }
                    }
                }
            }
            .padding()
        }
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
        if isRecording        { return "Type shortcut…" }
        if binding.kind == .none { return "Record Shortcut" }
        return binding.displayLabel
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
        // addLocalMonitorForEvents runs handler on the main thread.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            self.handleKey(event)
            return nil  // consume — prevents the key from reaching any other responder
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        isRecording = false
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
