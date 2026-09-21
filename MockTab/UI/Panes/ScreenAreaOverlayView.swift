// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// ScreenAreaOverlayView.swift — SwiftUI content for the full-screen screen-area picker

import SwiftUI

/// Full-screen crop picker: drags the same `NormalizedAreaEditor` chrome used
/// in the Displays pane's embedded thumbnail, but at true display scale with
/// a heavier exterior dim (there's real desktop content behind it, not a
/// static wallpaper thumbnail) and a live dimension/position HUD tracking the
/// rect while it's dragged.
struct ScreenAreaOverlayView: View {
    let aspectRatio: Double
    let initialRect: NormalizedRect
    var onDone: (NormalizedRect) -> Void
    var onCancel: () -> Void

    @State private var rect: NormalizedRect

    init(
        aspectRatio: Double, initialRect: NormalizedRect,
        onDone: @escaping (NormalizedRect) -> Void, onCancel: @escaping () -> Void
    ) {
        self.aspectRatio = aspectRatio
        self.initialRect = initialRect
        self.onDone = onDone
        self.onCancel = onCancel
        self._rect = State(initialValue: initialRect)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                NormalizedAreaEditor(
                    aspectRatio: aspectRatio,
                    rect: $rect,
                    style: .fullScreen,
                    dimOpacity: 0.55,
                    onCommit: { _ in },
                    overlay: { areaRect, _ in
                        dimensionHUD(areaRect: areaRect)
                    }
                )
                .frame(width: geo.size.width, height: geo.size.height)

                // Anchored near the top rather than the bottom — the Dock
                // (and this window's own crop chrome, which can extend close
                // to the bottom edge) both live down there, and this
                // borderless overlay isn't a real Space-owning fullscreen
                // window, so it has no reliable way to query live Dock
                // height/position/auto-hide state to dodge around it.
                confirmBar
                    .position(x: geo.size.width / 2, y: 60)
            }
        }
        .onExitCommand { onCancel() }
    }

    /// Pixel dimensions and top-left offset of the rect, read straight from
    /// `areaRect` — already in canvas points, which equal real screen pixels
    /// 1:1 since the overlay window is sized to the display's own bounds
    /// with no letterboxing. Centered in the rect, sized up 4x from the
    /// original caption-scale HUD to match the convention other crop tools
    /// use for an encapsulated caption.
    private func dimensionHUD(areaRect: CGRect) -> some View {
        let widthPx = Int(areaRect.width.rounded())
        let heightPx = Int(areaRect.height.rounded())
        let xPx = Int(areaRect.minX.rounded())
        let yPx = Int(areaRect.minY.rounded())

        return Text(verbatim: "\(widthPx)\u{00D7}\(heightPx) at \(xPx), \(yPx)")
            .font(.system(size: 28, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            .position(x: areaRect.midX, y: areaRect.midY)
            .allowsHitTesting(false)
    }

    private var confirmBar: some View {
        HStack(spacing: 40) {
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Done") { onDone(rect) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
