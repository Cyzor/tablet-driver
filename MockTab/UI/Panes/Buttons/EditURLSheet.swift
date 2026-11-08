// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 MockTab contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Types, pastes, or fixes the URL a button opens. Reached from a button
/// row's right-click menu; takes what a dragged link would, but no files.
struct EditURLSheet: View {
    @Binding var binding: ButtonBinding
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(binding: Binding<ButtonBinding>) {
        _binding = binding
        let current = binding.wrappedValue
        let isLink = current.openURL.map { !$0.isFileURL } ?? false
        _text = State(initialValue: isLink ? current.target : "")
    }

    private var url: URL? { ButtonOpenAction.typedLink(text) }

    /// Why OK is grayed out, once there's something to judge.
    private var problem: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, url == nil else { return nil }
        // A Finder item dropped here arrives as its path.
        if ButtonOpenAction.looksLikeFile(trimmed) {
            return String(
                localized: "To open a file, drag it onto the button's row.",
                comment: "Edit URL sheet: the typed text is a file path, which this sheet doesn't take")
        }
        let fits = ButtonOpenAction.link(from: trimmed)
            .map { $0.absoluteString.utf8.count <= ButtonOpenAction.maxLinkLength } ?? false
        guard fits else {
            return String(localized: "This isn't a URL.", comment: "Edit URL sheet: the typed text isn't a usable URL")
        }
        return String(
            localized: "No app on this Mac opens this URL.",
            comment: "Edit URL sheet: no installed app handles the typed URL's scheme")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit URL", comment: "Edit URL sheet title")
                .font(.headline)
            CappedURLField(text: $text, onSubmit: save)
            Text(problem ?? " ")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(problem == nil)
            HStack {
                Spacer()
                Button(String(localized: "Cancel", comment: "Edit URL sheet: cancel button"), role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "OK", comment: "Edit URL sheet: confirm button"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(url == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        guard let url else { return }
        // An unchanged URL keeps the name it came with, like a macro's.
        if binding.kind != .open || binding.target != url.absoluteString {
            binding = ButtonBinding(opening: url)
        }
        dismiss()
    }
}

/// A one-line field that refuses any edit past the URL length cap before
/// taking it, so a stray paste of a huge document can't stall the window.
/// SwiftUI's `TextField` checks only after the text is in.
private struct CappedURLField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.formatter = LengthCap()
        // A reserved example domain reads as a stand-in, not a value.
        field.placeholderString = "https://example.com"
        field.isAutomaticTextCompletionEnabled = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel(String(localized: "URL", comment: "Edit URL sheet: text field label"))
        field.delegate = context.coordinator
        DispatchQueue.main.async {
            if field.currentEditor() == nil { field.window?.makeFirstResponder(field) }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CappedURLField
        init(_ parent: CappedURLField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        // Return only: the field's action also fires whenever editing ends,
        // as when the sheet settles focus while opening.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }

    /// Takes text as is, but no edit that would pass the cap; AppKit beeps.
    private final class LengthCap: Formatter {
        override func string(for obj: Any?) -> String? { obj as? String }

        override func getObjectValue(
            _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
            errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
        ) -> Bool {
            obj?.pointee = string as NSString
            return true
        }

        override func isPartialStringValid(
            _ partialString: String, newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?,
            errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
        ) -> Bool {
            partialString.utf8.count <= ButtonOpenAction.maxLinkLength
        }
    }
}
