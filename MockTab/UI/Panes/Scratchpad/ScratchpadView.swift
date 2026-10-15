// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import Combine
import TabletKit

// MARK: - SwiftUI wrapper

struct ScratchpadView: View {
    @ObservedObject var settings: TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    /// Deliberately NOT @ObservedObject: the ~30 Hz touch-frame stream must
    /// invalidate only the small `TouchVisualizer` child (which observes the
    /// publisher itself), not this whole pane — re-evaluating the full body
    /// per frame was a measurable main-thread CPU cost while touch was live.
    /// This view only writes gating state (`isPublishingEnabled`, clearing
    /// `contacts`); it never reads `contacts` in `body`.
    private let liveTouch: LiveTouchPublisher
    let instanceKey: DeviceInstanceKey?
    /// Model axis of the bound unit — spec/catalog lookups key on this.
    private var productID: Int? { instanceKey?.productID }
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
        // Derive the touch publisher from the bound manager so the view isn't
        // tied to the singleton — the only `TabletManager` in practice today,
        // but the parameter is what the rest of the view uses.
        self.liveTouch = tabletManager.liveTouch
    }

    @State private var currentPressure: Double = 0
    @State private var clearID = 0
    @State private var resetViewID = 0
    @State private var isViewMoved = false

    /// Tracks whether this view is on-screen AND the app is frontmost.
    /// Used to gate the live-touch publish — when either is false, the
    /// HID-thread closure skips dispatch entirely, so a palm resting on
    /// the tablet costs nothing while the user is in another tab or app.
    @State private var isVisible = false
    @State private var isAppActive = NSApp.isActive

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .onAppear {
            isVisible = true
            updateLiveTouchGate()
        }
        .onDisappear {
            isVisible = false
            updateLiveTouchGate()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isAppActive = true
            updateLiveTouchGate()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            isAppActive = false
            updateLiveTouchGate()
        }
        .onChange(of: settings.touchEnabled) { enabled in
            // The HID closure stops publishing immediately when touch is
            // disabled, but the previously displayed contacts would otherwise
            // linger on the canvas with no fresh frame to overwrite them.
            if !enabled { liveTouch.contacts = [] }
        }
    }

    private func updateLiveTouchGate() {
        let newValue = isVisible && isAppActive
        // Clear any lingering contacts on the way out so the canvas doesn't
        // paint a stale snapshot when the view becomes visible again.
        if !newValue && liveTouch.isPublishingEnabled {
            liveTouch.contacts = []
        }
        liveTouch.isPublishingEnabled = newValue
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
                currentPressure: $currentPressure,
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

            pressureRow

            visualizerRow
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// For a wireless-dongle-bound window, the dongle's own PID carries no
    /// touch data — the paired tablet's does. Falls back to `productID` for
    /// every direct (non-dongle) connection, and before pairing resolves.
    private var effectiveProductID: Int? {
        let context = tabletManager.context(forKey: instanceKey)
        if let paired = context?.pairedProductID, paired != 0 { return paired }
        return productID
    }

    private var spec: TabletSpec? {
        effectiveProductID.flatMap { WacomDeviceRegistry.spec(for: $0) }
    }

    private var pressureRow: some View {
        HStack(spacing: 10) {
            Text("Pressure")
                .appFont(.settingsLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityHidden(true)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.quaternary)

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(pressureColor)
                        .frame(width: geo.size.width * currentPressure)
                        .animation(reduceMotion ? nil : .linear(duration: 0.05), value: currentPressure)
                }
            }
            .scaledFrame(height: 8)
            .accessibilityHidden(true)

            Text(String(format: "%.0f%%", currentPressure * 100))
                .appFont(.monospaced)
                .foregroundStyle(.secondary)
                .scaledFrame(width: 44, alignment: .trailing)
                // The label, bar, and figure read as one element.
                .accessibilityLabel(Text("Pressure"))
                .accessibilityValue(currentPressure.formatted(.percent.precision(.fractionLength(0))))

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

    /// Tilt and touch visualizers share one row; both canvases are 100 pt
    /// tall, so their vertical centers align without any further bookkeeping.
    private var visualizerRow: some View {
        HStack(spacing: 24) {
            HStack(spacing: 10) {
                Text("Tilt")
                    .appFont(.settingsLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)

                TiltVisualizerCanvas(tabletManager: tabletManager)
                    .scaledFrame(width: 100, height: 100)
                    .help("Live tilt direction and magnitude from the active pen.")
            }

            if spec?.hasFingerTouch == true {
                HStack(spacing: 10) {
                    Text("Touch")
                        .appFont(.settingsLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityHidden(true)

                    TouchVisualizer(
                        liveTouch: liveTouch,
                        maxContacts: spec?.maxTouchContacts ?? 10
                    )
                    .scaledFrame(width: 100, height: 100)
                    .help("Live finger-touch contacts from the active device's touch surface.")
                }
            }
        }
    }

    private var pressureColor: Color {
        currentPressure < 0.5
            ? .accentColor
            : Color(hue: 0.05, saturation: 0.8, brightness: 0.85)
    }
}
