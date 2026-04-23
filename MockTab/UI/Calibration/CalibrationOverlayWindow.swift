// CalibrationOverlayWindow.swift — Full-screen transparent window for calibration crosshairs
// MockTab

import AppKit
import SwiftUI

/// A borderless, transparent window that covers the target display for calibration.
/// Hosts a `CalibrationOverlayView` showing crosshair targets and collection feedback.
@MainActor
final class CalibrationOverlayWindow: NSWindow {

    private let session: CalibrationSession

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
        contentView = NSHostingView(rootView: overlayView)
    }

    /// Show the overlay and start the calibration session.
    func beginCalibration() {
        makeKeyAndOrderFront(nil)
        session.start()
    }

    /// Close the overlay and clean up.
    func dismiss() {
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
