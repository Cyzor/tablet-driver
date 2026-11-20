// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import TabletKit

// MARK: - SwiftUI wrapper

struct ScratchpadView: View {
    @ObservedObject var settings: TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    let instanceKey: DeviceInstanceKey?
    var undoManager: UndoManager?

    init(settings: TabletSettings,
         tabletManager: TabletManager,
         registry: DeviceRegistry,
         instanceKey: DeviceInstanceKey? = nil,
         undoManager: UndoManager? = nil) {
        self.settings = settings
        self.tabletManager = tabletManager
        self.registry = registry
        self.instanceKey = instanceKey
        self.undoManager = undoManager
    }

    @State private var clearID = 0
    @State private var resetViewID = 0
    @State private var isViewMoved = false

    var body: some View {
        let _ = BodyCounter.note("Scratchpad")
        VStack(spacing: 0) {
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()

            DeviceStatusBar(
                settings: settings,
                tabletManager: tabletManager,
                registry: registry,
                instanceKey: instanceKey
            )
            .layoutPriority(1)
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Test Area")
                .appFont(.headline)

            Text(
                String(
                    localized: "Draw on the canvas to verify pressure and click behavior.",
                    comment: "Description of the scratchpad drawing area"
                )
            )
            .appFont(.settingsLabel)
            .foregroundStyle(.secondary)

            ScratchpadCanvas(
                clearID: clearID,
                resetViewID: resetViewID,
                isViewMoved: $isViewMoved,
                tabletManager: tabletManager,
                undoManager: undoManager
            )
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.85), lineWidth: 1)
                }

            buttonRow
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var buttonRow: some View {
        HStack(spacing: 10) {
            Spacer()

            Button("Reset View") {
                resetViewID += 1
            }
            .help("Undo scrolling, zooming, and rotation of the test canvas")
            .appControlSize(.small)
            .disabled(!isViewMoved)

            Button("Clear") {
                clearID += 1
            }
            .help("Erase all strokes from the test canvas")
            .appControlSize(.small)
        }
    }
}
