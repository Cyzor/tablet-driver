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

    /// Watches the session's own state publisher for completion, not a
    /// SwiftUI `.onChange`, which can miss the `.computing` → `.done` edge.
    /// `@Published` fires on every assignment.
    private var stateObserver: AnyCancellable?
    /// Pending auto-dismiss, cancelled if the user dismisses first.
    private var autoDismissWork: DispatchWorkItem?
    /// Ends the session when its display moves, resizes, or goes away:
    /// targets and the fit both assume the bounds it started with.
    private var screenObserver: NSObjectProtocol?
    /// The whole display's bounds at start; the session's own are cropped.
    private var startingDisplayBounds: CGRect?

    /// How long the completion panel stays up before dismissing itself.
    private static let autoDismissDelay: TimeInterval = 2.0

    init(session: CalibrationSession) {
        self.session = session
        super.init(
            contentRect: session.displayBounds.quartzToAppKit,
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
        startingDisplayBounds = currentDisplayBounds()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentDisplayBounds() != self.startingDisplayBounds else { return }
                calibrationLogger.debug("calibration display changed — cancelling")
                self.dismiss()
            }
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

    /// The session's display's current bounds, nil once it's gone.
    private func currentDisplayBounds() -> CGRect? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.first { CalibrationKey.uuidString(for: $0) == session.displayUUID }
            .map { CGDisplayBounds($0) }
    }

    /// Close the overlay and clean up.
    func dismiss() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
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
