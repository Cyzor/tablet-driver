// CalibrationOverlayView.swift — SwiftUI view for calibration crosshairs and progress
// MockTab

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
        .onExitCommand { onDismiss() }
        .onChange(of: session.state) { newState in
            if case .done = newState {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    onDismiss()
                }
            }
        }
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

    private var instructionPanel: some View {
        VStack(spacing: 8) {
            switch session.state {
            case .idle:
                Text("Preparing calibration…")
                    .font(.title3)
            case .awaitingTap(let idx):
                Text("Point \(idx + 1) of \(session.targets.count)")
                    .font(.title3.bold())
                Text("Tap and hold the crosshair with your pen tip")
                    .font(.body)
            case .collecting(let idx, let count):
                Text("Point \(idx + 1) of \(session.targets.count)")
                    .font(.title3.bold())
                Text("Hold steady… (\(count)/16)")
                    .font(.body)
            case .computing:
                Text("Computing calibration…")
                    .font(.title3)
                ProgressView()
            case .done(let maxRes, let transformType):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Calibration complete")
                    .font(.title3.bold())
                let pixelError = maxRes * Swift.max(session.displayBounds.width, session.displayBounds.height)
                Text("\(transformType) transform, \(pixelError, specifier: "%.1f") px max error")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .cancelled:
                EmptyView()
            }

            if session.state != .cancelled {
                Button("Cancel") { onDismiss() }
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
