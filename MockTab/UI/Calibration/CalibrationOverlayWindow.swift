// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// CalibrationOverlayWindow.swift — Full-screen transparent window for calibration crosshairs

import AppKit
import Combine
import SwiftUI

/// A borderless, transparent window that covers the target display for calibration.
/// Hosts a `CalibrationOverlayView` showing crosshair targets and collection feedback.
@MainActor
final class CalibrationOverlayWindow: NSWindow {

    private let session: CalibrationSession

    /// Watches the session's own state publisher for completion. The auto-dismiss
    /// used to hang off a SwiftUI `.onChange` in the overlay view, which sometimes
    /// missed the `.computing` → `.done` edge and left the success panel up until
    /// the user hit Cancel. `@Published` fires on every assignment regardless of
    /// how SwiftUI coalesces the resulting view update.
    private var stateObserver: AnyCancellable?
    /// Pending auto-dismiss, cancelled if the user dismisses first.
    private var autoDismissWork: DispatchWorkItem?

    /// How long the completion panel stays up before dismissing itself.
    private static let autoDismissDelay: TimeInterval = 2.0

    init(session: CalibrationSession) {
        self.session = session
        super.init(
            contentRect: session.displayBounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false)

        backgroundColor = NSColor.black.withAlphaComponent(0.4)
        isOpaque = false
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = false
        isReleasedWhenClosed = false

        let overlayView = CalibrationOverlayView(session: session) { [weak self] in
            self?.dismiss()
        }
        let hostingView = NSHostingView(rootView: overlayView)
        // The window always has a dark semi-transparent background, so force dark
        // appearance on the hosting view so SwiftUI materials and text render correctly
        // regardless of the system light/dark mode setting.
        hostingView.appearance = NSAppearance(named: .darkAqua)
        contentView = hostingView
    }

    /// Show the overlay and start the calibration session.
    func beginCalibration() {
        stateObserver = session.$state.sink { [weak self] newState in
            // A withheld (high-residual) result stays up until the user chooses
            // to apply or discard it — auto-dismissing would hide the warning.
            guard case .done(_, _, let stored) = newState, stored else { return }
            self?.scheduleAutoDismiss()
        }
        makeKeyAndOrderFront(nil)
        session.start()
    }

    /// Leave the completion panel up briefly so the residual is readable, then close.
    private func scheduleAutoDismiss() {
        guard autoDismissWork == nil else { return }  // `.done` published once per session
        calibrationLogger.debug("calibration finished — auto-dismiss scheduled")
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        autoDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoDismissDelay, execute: work)
    }

    /// Close the overlay and clean up.
    func dismiss() {
        autoDismissWork?.cancel()
        autoDismissWork = nil
        stateObserver = nil
        session.cancel()
        orderOut(nil)
        close()
    }

    // Allow Escape to cancel.
    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    // Keep the window key so it receives keyboard events.
    override var canBecomeKey: Bool { true }
}
