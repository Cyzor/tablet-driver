// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Root view of the help window.
///
/// `HelpWindowController` owns this view and passes itself as the controller
/// so the sidebar selection is preserved across show/hide cycles.
struct HelpPanelView: View {

    @ObservedObject var controller: HelpWindowController

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(HelpSection.allCases, selection: $controller.selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            HelpDetailView(section: controller.selectedSection,
                           fontSizeStep: controller.fontSizeStep)
        }
        .navigationSplitViewStyle(.prominentDetail)
        .frame(minWidth: 520, minHeight: 380)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                ControlGroup {
                    Button {
                        controller.fontSizeStep = max(
                            HelpWindowController.fontSizeStepRange.lowerBound,
                            controller.fontSizeStep - 1)
                    } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .disabled(controller.fontSizeStep <= HelpWindowController.fontSizeStepRange.lowerBound)
                    .accessibilityLabel(LocalizedStringKey("Decrease text size"))

                    Button {
                        controller.fontSizeStep = min(
                            HelpWindowController.fontSizeStepRange.upperBound,
                            controller.fontSizeStep + 1)
                    } label: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .disabled(controller.fontSizeStep >= HelpWindowController.fontSizeStepRange.upperBound)
                    .accessibilityLabel(LocalizedStringKey("Increase text size"))
                }
                .help(String(localized: "Decrease or increase text size",
                             comment: "Help window toolbar: font size control tooltip"))
            }
        }
    }
}

// MARK: - Detail

private struct HelpDetailView: View {

    let section: HelpSection
    let fontSizeStep: Int

    var body: some View {
        ScrollView {
            MarkdownBodyView(source: section.markdownSource, fontSizeStep: fontSizeStep)
                .textSelection(.enabled)
                .frame(maxWidth: 580, alignment: .leading)
                .padding(EdgeInsets(top: 24, leading: 28, bottom: 32, trailing: 28))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
