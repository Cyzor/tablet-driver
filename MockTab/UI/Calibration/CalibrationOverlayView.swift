// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// CalibrationOverlayView.swift — SwiftUI view for calibration crosshairs and progress

import SwiftUI

/// Full-screen overlay view showing calibration targets, progress, and instructions.
struct CalibrationOverlayView: View {
    @ObservedObject var session: CalibrationSession
    var onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Crosshair at current target position
                crosshairLayer(in: geo.size)

                // Instructions and progress at bottom center
                VStack(spacing: 12) {
                    Spacer()
                    instructionPanel
                        .padding(.bottom, 60)
                }
            }
        }
        // Auto-dismiss on completion lives in CalibrationOverlayWindow, driven by
        // the session's state publisher rather than a SwiftUI change edge.
        .onExitCommand { onDismiss() }
    }

    // MARK: - Crosshair

    @ViewBuilder
    private func crosshairLayer(in size: CGSize) -> some View {
        switch session.state {
        case .awaitingTap, .collecting:
            let pos = session.currentTargetPosition
            let x = pos.x * size.width
            let y = pos.y * size.height
            CrosshairShape()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: 40, height: 40)
                .shadow(color: .black, radius: 2)
                .position(x: x, y: y)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: pos)

            // Collection ring
            if case .collecting(_, let count) = session.state {
                let progress = Double(count) / Double(16)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.green, lineWidth: 3)
                    .frame(width: 50, height: 50)
                    .rotationEffect(.degrees(-90))
                    .position(x: x, y: y)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Instruction panel

    private var isDone: Bool {
        if case .done = session.state { return true }
        return false
    }

    private var instructionPanel: some View {
        VStack(spacing: 8) {
            switch session.state {
            case .idle:
                Text("Preparing calibration…")
                    .appFont(.title3)
            case .awaitingTap(let idx):
                Text("Point \(idx + 1) of \(session.targets.count)")
                    .appFont(.title3).bold()
                Text("Tap and hold the crosshair with your pen tip")
                    .appFont(.body)
            case .collecting(let idx, let count):
                Text("Point \(idx + 1) of \(session.targets.count)")
                    .appFont(.title3).bold()
                Text("Hold steady… (\(count)/16)")
                    .appFont(.body)
            case .computing:
                Text("Computing calibration…")
                    .appFont(.title3)
                ProgressView()
            case .done(let maxRes, let transformType, let stored):
                Image(systemName: stored ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .appFont(size: 36)
                    .foregroundStyle(stored ? .green : .yellow)
                    .accessibilityHidden(true)
                // Explicit LocalizedStringKey — a bare ternary of literals infers
                // String and would bypass localization.
                let heading: LocalizedStringKey = stored
                    ? "Calibration complete" : "Calibration looks wrong"
                Text(heading)
                    .appFont(.title3).bold()
                let pixelError = maxRes * Swift.max(session.displayBounds.width, session.displayBounds.height)
                Text("\(transformType) transform, \(pixelError, specifier: "%.1f") px max error")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                if !stored {
                    Text("The taps don't line up with the targets. Applying this would map the cursor further from the pen tip than no calibration at all.")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .scaledFrame(maxWidth: 320)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .cancelled:
                EmptyView()
            }

            // A withheld result needs an explicit decision — the calibration is
            // not stored unless "Apply Anyway" is chosen.
            if case .done(_, _, false) = session.state {
                HStack(spacing: 12) {
                    Button("Discard") {
                        session.discardPendingResult()
                        onDismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
                    Button("Apply Anyway") {
                        session.applyPendingResult()
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
                .padding(.top, 4)
            } else if session.state != .cancelled {
                // After a successful fit the overlay is just showing a result, so
                // the button confirms rather than cancels. Both keys are already
                // localized in every shipped language. The explicit
                // LocalizedStringKey keeps both branches string *literals* — a
                // plain ternary would degrade to String and skip localization.
                let label: LocalizedStringKey = isDone ? "Done" : "Cancel"
                Button(label) { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
    }
}

// MARK: - Crosshair shape

/// A simple crosshair with center dot.
struct CrosshairShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cx = rect.midX, cy = rect.midY
        let armLength = rect.width / 2

        // Horizontal line
        p.move(to: CGPoint(x: cx - armLength, y: cy))
        p.addLine(to: CGPoint(x: cx + armLength, y: cy))

        // Vertical line
        p.move(to: CGPoint(x: cx, y: cy - armLength))
        p.addLine(to: CGPoint(x: cx, y: cy + armLength))

        // Center dot
        p.addEllipse(in: CGRect(x: cx - 3, y: cy - 3, width: 6, height: 6))

        return p
    }
}
