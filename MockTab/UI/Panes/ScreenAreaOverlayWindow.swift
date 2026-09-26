// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// ScreenAreaOverlayWindow.swift — Full-screen crop picker for the tablet's screen region

import AppKit
import SwiftUI

/// A borderless, transparent window covering one display, letting the user
/// drag out the tablet's active screen region directly over their desktop —
/// the same "select a portion of the screen" interaction as macOS's own
/// screenshot tool, rather than eyeballing a small thumbnail. Mirrors
/// `CalibrationOverlayWindow`'s window setup.
@MainActor
final class ScreenAreaOverlayWindow: NSWindow {

    private var onFinish: ((NormalizedRect?) -> Void)?
    private var resignActiveObserver: NSObjectProtocol?

    init(
        displayBounds: CGRect, initialRect: NormalizedRect,
        snapAspect: Double?, snapLabel: String,
        onFinish: @escaping (NormalizedRect?) -> Void
    ) {
        self.onFinish = onFinish
        super.init(
            contentRect: displayBounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false)

        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        isReleasedWhenClosed = false

        let overlayView = ScreenAreaOverlayView(
            aspectRatio: displayBounds.width / max(displayBounds.height, 1),
            initialRect: Self.withEdgeMargin(initialRect, displayBounds: displayBounds),
            snapAspect: snapAspect, snapLabel: snapLabel,
            onDone: { [weak self] rect in self?.finish(with: rect) },
            onCancel: { [weak self] in self?.finish(with: nil) })
        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        contentView = hostingView
    }

    func begin() {
        makeKeyAndOrderFront(nil)
        // Matches the macOS screenshot tool: switching away (Cmd-Tab,
        // clicking another app) cancels the picker instead of leaving a
        // borderless, always-on-top overlay stranded above whatever the
        // user switched to.
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.finish(with: nil)
        }
    }

    /// Any edge sitting flush against the display's true bounds gets pulled
    /// in by a fixed screen-point margin, so the corner/edge handles don't
    /// spawn glued to the physical screen edge (where they're nearly
    /// unreachable — half the hit target sits outside the window). A rect
    /// that's already inset on some edges is left alone on those edges.
    private static let edgeMargin: CGFloat = 60

    private static func withEdgeMargin(_ rect: NormalizedRect, displayBounds: CGRect) -> NormalizedRect {
        guard displayBounds.width > 0, displayBounds.height > 0 else { return rect }
        let marginX = edgeMargin / displayBounds.width
        let marginY = edgeMargin / displayBounds.height
        var r = rect

        let flushLeft = r.x <= 0.001
        let flushTop = r.y <= 0.001
        let flushRight = r.x + r.w >= 0.999
        let flushBottom = r.y + r.h >= 0.999

        if flushLeft { r.x += marginX; r.w -= marginX }
        if flushTop { r.y += marginY; r.h -= marginY }
        if flushRight { r.w -= marginX }
        if flushBottom { r.h -= marginY }

        return r
    }

    private func finish(with rect: NormalizedRect?) {
        guard let callback = onFinish else { return }
        onFinish = nil
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
        orderOut(nil)
        close()
        callback(rect)
    }

    override func cancelOperation(_ sender: Any?) {
        finish(with: nil)
    }

    override var canBecomeKey: Bool { true }
}
