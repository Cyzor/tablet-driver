// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A number shown as plain text that turns into a field when clicked, like
/// the rename fields: Return or clicking anywhere else commits, Esc cancels.
struct InlineNumberField: View {
    /// The number as shown, and as the field starts out.
    let shown: String
    /// Spoken name and value, such as "Width" and "224 millimeters".
    let label: String
    let spokenValue: String
    let help: String
    /// Accessibility identifier, the same in both states.
    let identifier: String
    let onCommit: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @State private var isHovered = false
    @State private var clickMonitor: Any?
    @FocusState private var isFocused: Bool

    var body: some View {
        // Both states take the shown number's size, so nothing around them
        // moves when the field opens.
        Text(shown)
            .monospacedDigit()
            .padding(.horizontal, 3)
            .hidden()
            .overlay(alignment: .trailing) {
                if isEditing { field } else { number }
            }
            .onDisappear(perform: stopWatchingClicks)
    }

    private var number: some View {
        Text(shown)
            .monospacedDigit()
            .padding(.horizontal, 3)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture(perform: begin)
            .help(help)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(spokenValue)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { begin() }
            .accessibilityIdentifier(identifier)
    }

    private var field: some View {
        TextField(label, text: $draft)
            .labelsHidden()
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($isFocused)
            .renameFieldRing()
            .onSubmit(commit)
            .onExitCommand(perform: end)
            // Deferred a turn: focus asked for as the field is inserted
            // lands before it can take it.
            .onAppear {
                hideAutoFillPanelDuringRename()
                watchClicks()
                DispatchQueue.main.async {
                    isFocused = true
                    selectAllInFocusedRenameField()
                }
            }
            .onChange(of: isFocused) { focused in
                if !focused { commit() }
            }
            .accessibilityIdentifier(identifier)
    }

    private func begin() {
        draft = shown
        isEditing = true
    }

    private func commit() {
        guard isEditing else { return }
        end()
        onCommit(draft)
    }

    private func end() {
        isEditing = false
        stopWatchingClicks()
    }

    /// Commits on a click anywhere but the field. A click on empty space or
    /// a label takes no focus, so the field would otherwise stay open.
    private func watchClicks() {
        stopWatchingClicks()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                let editedField = (event.window?.firstResponder as? NSTextView)?.delegate as? NSView
                let hit = event.window?.contentView?.superview?.hitTest(event.locationInWindow)
                if let hit, let editedField, hit.isDescendant(of: editedField) { return }
                commit()
            }
            return event
        }
    }

    private func stopWatchingClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}
