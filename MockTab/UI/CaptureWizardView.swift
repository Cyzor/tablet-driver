// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026 This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab. If not, see <https://www.gnu.org/licenses/>.

import AppKit
import SwiftUI

/// Reference-type gate shared between the SwiftUI view (struct) and the
/// `onSampleCaptured` closure. Closures capture class instances by reference,
/// so they always see the current `isArmed` value even after the view struct
/// has been recreated by SwiftUI.
@MainActor
private final class CaptureGate: ObservableObject {
    @Published var isArmed = false
}

/// Unified device data collection wizard.
///
/// Guides the user through 5 grouped activities. Each activity shows a "Ready"
/// button: while waiting, the baseline is continuously refreshed so hover movement
/// doesn't trigger a false capture. Once the user clicks Ready, the next HID
/// report that differs from the current baseline is captured as the action sample.
///
/// Activities with no matching hardware (eraser-less pens, no express keys) are
/// skipped automatically via the Skip button.
///
/// Express keys auto-rearm the gate after each capture so the user only clicks
/// Ready once for the whole group, then presses keys in sequence.
struct CaptureWizardView: View {

    @ObservedObject var engine: CaptureEngine
    @ObservedObject var tabletManager: TabletManager
    let productID: Int
    let onDismiss: () -> Void

    // MARK: - Activity groups

    enum Activity: Int, CaseIterable, Identifiable {
        case tip
        case penButtons
        case eraser
        case expressKeys
        case touchControls

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .tip:           return "Touch the pen tip to the surface, then lift"
            case .penButtons:    return "Press and hold each side button on the pen"
            case .eraser:        return "Press the eraser end to the surface (if present)"
            case .expressKeys:   return "Press each button on the tablet body (if any)"
            case .touchControls: return "Slide or touch any rings or strips on the tablet (if any)"
            }
        }

        var readyPrompt: String {
            switch self {
            case .tip:
                return "Hold the pen still above the surface, then click Ready."
            case .penButtons:
                return "Rest your finger near a side button, then click Ready."
            case .eraser:
                return "Hold the eraser end near the surface, then click Ready."
            case .expressKeys:
                // The gate stays armed between key presses — one Ready for the whole group.
                return "Rest a finger near the first button, then click Ready. Press each key in sequence; click Skip when finished."
            case .touchControls:
                return "Rest a finger near the ring or strip, then click Ready."
            }
        }

        var icon: String {
            switch self {
            case .tip:           return "hand.point.down.left"
            case .penButtons:    return "button.horizontal"
            case .eraser:        return "arrow.up.and.down.circle"
            case .expressKeys:   return "rectangle.grid.2x2"
            case .touchControls: return "circle.dashed"
            }
        }

        /// When true, the gate re-arms automatically after each captured key step
        /// within this group. The user clicks Ready once, then performs each action
        /// in sequence without clicking Ready again.
        var autoRearmAfterCapture: Bool {
            self == .expressKeys
        }

        static func activity(for step: CalibrationStep) -> Activity? {
            switch step {
            case .idle, .tipDown, .tipUp, .hover5mm, .tilt15, .tilt45:
                return .tip
            case .penButton1, .penButton2:
                return .penButtons
            case .eraserDown, .eraserUp:
                return .eraser
            case .expressKey1, .expressKey2, .expressKey3, .expressKey4,
                 .expressKey5, .expressKey6, .expressKey7, .expressKey8:
                return .expressKeys
            case .touchRing, .touchRingPos0, .touchRingPos36, .touchRingPos71:
                return .touchControls
            case .rotationCW, .rotationCCW:
                return nil
            }
        }

        /// Background steps capture ambient device state and should advance
        /// automatically without user interaction. Key steps require the user
        /// to perform a deliberate action (tip contact, button press, etc.).
        static func isKeyStep(_ step: CalibrationStep) -> Bool {
            switch step {
            case .tipDown, .tipUp,
                 .penButton1, .penButton2,
                 .eraserDown, .eraserUp,
                 .expressKey1, .expressKey2, .expressKey3, .expressKey4,
                 .expressKey5, .expressKey6, .expressKey7, .expressKey8,
                 .touchRing, .touchRingPos0, .touchRingPos36, .touchRingPos71:
                return true
            case .idle, .hover5mm, .tilt15, .tilt45, .rotationCW, .rotationCCW:
                return false
            }
        }
    }

    // MARK: - State

    /// Which activity groups have been fully exited (engine moved on to the next group).
    /// Updated exclusively in `onChange(of: engine.armedStep)` when the active group
    /// changes, so the checkmark never appears while sub-steps are still in progress.
    @State private var detectedActivities: Set<Int> = []
    /// The activity group currently being collected.
    @State private var armedActivity: Activity? = nil
    /// Reference-type gate so the onSampleCaptured closure always reads the current value.
    @StateObject private var gate = CaptureGate()
    /// Timer that continuously resets the baseline while the user is preparing.
    @State private var rebaselineTimer: Timer? = nil
    @State private var savedURL: URL? = nil
    @State private var showCancelConfirm = false
    /// Running count of express key steps captured in the current session of the
    /// expressKeys group. Shown in the caption so the user knows presses are landing.
    @State private var capturedKeyCount: Int = 0

    private var activeActivity: Activity? {
        guard let step = engine.armedStep else { return nil }
        return Activity.activity(for: step)
    }

    private var isComplete: Bool { engine.armedStep == nil && savedURL != nil }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isComplete, let url = savedURL {
                completionView(url: url)
            } else {
                activityList
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 440)
        .alert("Cancel Data Collection?", isPresented: $showCancelConfirm) {
            Button("Continue Collecting", role: .cancel) {}
            Button("Cancel", role: .destructive) {
                stopRebaseline()
                engine.cancel()
                onDismiss()
            }
        } message: {
            Text("Any data collected so far will be discarded.")
        }
        .onAppear { startCollection() }
        .onDisappear { stopRebaseline() }
        // React to the engine advancing to a new step.
        //
        // Three bugs fixed here vs. the original implementation:
        //
        //  1. INTRA-GROUP DEADLOCK: The original code only restarted the rebaseline
        //     timer and reset the gate on activity-group transitions. Within a group,
        //     consecutive key sub-steps (e.g. .tipDown → .tipUp) left the timer
        //     stopped and the gate permanently closed. The engine then waited forever
        //     for a sub-step it could never receive.
        //     Fix: gate reset + rebaseline (or auto-rearm) now run on EVERY step change.
        //
        //  2. PREMATURE CHECKMARK: detectedActivities.insert was called in
        //     onSampleCaptured after the first key sub-step of a group, hiding the
        //     UI controls before remaining sub-steps completed.
        //     Fix: insert only when the engine exits the group (newActivity != armedActivity).
        //
        //  3. EXPRESS KEY FRICTION: each of up to 8 key steps required a separate
        //     Ready click, giving no confirmation that any press was received.
        //     Fix: autoRearmAfterCapture activities re-arm the gate automatically
        //     after each capture; the user clicks Ready once, then presses keys in
        //     sequence. capturedKeyCount provides running feedback.
        .onChange(of: engine.armedStep) { newStep in
            let newActivity = newStep.flatMap { Activity.activity(for: $0) }
            let crossedBoundary = newActivity != armedActivity

            if crossedBoundary {
                // Leaving an activity group — mark it complete now that all
                // its sub-steps are behind us.
                if let completed = armedActivity {
                    detectedActivities.insert(completed.rawValue)
                }
                if armedActivity == .expressKeys {
                    capturedKeyCount = 0
                }
                armedActivity = newActivity
            }

            // Reset the gate on every step change, then decide how to proceed.
            gate.isArmed = false

            if newStep == nil {
                // Engine exhausted all steps.
                stopRebaseline()
            } else if !crossedBoundary, let activity = newActivity, activity.autoRearmAfterCapture {
                // Intra-group transition for an auto-rearm activity (express keys).
                // Re-arm after a brief drain — no manual Ready required between keys.
                stopRebaseline()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms drain
                    engine.rebaseline()
                    gate.isArmed = true
                }
            } else {
                // Normal activities: restart the rebaseline timer and wait for Ready.
                startRebaseline()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Collect Device Data")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        WacomDeviceRegistry.spec(for: productID) != nil
            ? "Captures diagnostic data to help investigate a problem with your device."
            : "Helps add support for your device by capturing its HID report layout."
    }

    // MARK: - Activity list

    private var activityList: some View {
        VStack(spacing: 0) {
            ForEach(Activity.allCases) { activity in
                activityRow(activity)
                if activity.rawValue < Activity.allCases.count - 1 {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func activityRow(_ activity: Activity) -> some View {
        let isActive = activeActivity == activity && engine.isRunning
        let isDone = detectedActivities.contains(activity.rawValue)
        let isReadyPhase = isActive && gate.isArmed

        HStack(spacing: 14) {
            // Status icon
            ZStack {
                Circle()
                    .fill(
                        isDone
                            ? Color.green.opacity(0.15)
                            : isActive
                                ? Color.blue.opacity(0.12)
                                : Color.clear
                    )
                    .frame(width: 32, height: 32)

                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                } else if isReadyPhase {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                } else if isActive {
                    Image(systemName: "hand.raised")
                        .font(.system(size: 13))
                        .foregroundStyle(.blue)
                } else {
                    Image(systemName: activity.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(activity.label)
                    .font(.body)
                    .foregroundStyle(isDone ? .secondary : isActive ? .primary : .secondary)

                if isActive {
                    if isReadyPhase {
                        if activity == .expressKeys && capturedKeyCount > 0 {
                            // Running confirmation: the user can see each press is landing.
                            Text("\(capturedKeyCount) key\(capturedKeyCount == 1 ? "" : "s") captured — press the next, or Skip when finished")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        } else {
                            Text("Perform the action now…")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    } else {
                        Text(activity.readyPrompt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Buttons are shown whenever the row is active, regardless of isDone.
            // Skip is always available so the user is never trapped waiting for
            // hardware they don't have or a step they can't perform.
            if isActive {
                HStack(spacing: 8) {
                    if isReadyPhase {
                        // Gate is open — waiting for a valid pen/key action.
                        Button("Next") {
                            stopRebaseline()
                            engine.confirmAndContinue()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        // Gate is closed — user must click Ready to arm capture.
                        // "Ready" means "I am now in position — capture what I do next."
                        Button("Ready") {
                            stopRebaseline()
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 400_000_000)
                                engine.rebaseline()
                                gate.isArmed = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    Button("Skip") {
                        gate.isArmed = false
                        stopRebaseline()
                        engine.confirmAndContinue()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(isActive ? Color.blue.opacity(0.04) : Color.clear)
        .animation(.easeInOut(duration: 0.2), value: isActive)
        .animation(.easeInOut(duration: 0.2), value: isDone)
        .animation(.easeInOut(duration: 0.15), value: isReadyPhase)
    }

    // MARK: - Completion

    private func completionView(url: URL) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)

            Text("Collection Complete")
                .font(.title3)
                .fontWeight(.semibold)

            let detected = Activity.allCases.filter { detectedActivities.contains($0.rawValue) }
            if !detected.isEmpty {
                Text("Captured: \(detected.map { summarise($0) }.joined(separator: ", "))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Show File in Finder", systemImage: "doc.badge.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("Share this file with MockTab developers for potential feature support.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summarise(_ activity: Activity) -> String {
        switch activity {
        case .tip:           return "pen tip"
        case .penButtons:    return "pen buttons"
        case .eraser:        return "eraser"
        case .expressKeys:   return "express keys"
        case .touchControls: return "touch controls"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if !isComplete {
                Button("Cancel") {
                    if engine.isRunning { showCancelConfirm = true } else { onDismiss() }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isComplete {
                Button("Done") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Collection logic

    private func startCollection() {
        guard let devInfo = deviceInfo() else { return }

        let spec = WacomDeviceRegistry.spec(for: productID)
        var steps = CalibrationStep.basicPenSteps
        if spec?.hasTilt == true {
            steps += [.hover5mm, .tilt15, .tilt45, .rotationCW, .rotationCCW]
        }

        if let ek = spec?.buttonCount, ek > 0 {
            let keyMap: [Int: CalibrationStep] = [
                1: .expressKey1, 2: .expressKey2, 3: .expressKey3, 4: .expressKey4,
                5: .expressKey5, 6: .expressKey6, 7: .expressKey7, 8: .expressKey8,
            ]
            for i in 1...min(ek, 8) {
                if let k = keyMap[i] { steps.append(k) }
            }
        }

        if spec?.hasTouchRing == true {
            steps += [.touchRing, .touchRingPos0]
        }

        let gate = gate // local let so the closure captures the object, not self
        engine.onSampleCaptured = { [gate] _, sample in
            if !Activity.isKeyStep(sample.step) {
                // Background step (idle baseline, hover, tilt, rotation) — advance silently.
                engine.confirmAndContinue()
                return
            }

            guard gate.isArmed else {
                // Key step but the gate isn't open — ignore it.
                // The rebaseline timer (if running) keeps the baseline fresh until Ready.
                return
            }

            gate.isArmed = false // close gate before advancing

            // Track express key captures for the running UI counter.
            if Activity.activity(for: sample.step) == .expressKeys {
                Task { @MainActor in capturedKeyCount += 1 }
            }

            // For express keys, a shorter post-capture pause is sufficient because the
            // gate will auto-rearm via onChange and the user is already in button-press
            // mode. Other steps use the longer pause so the user can register the state
            // change before the next instruction appears.
            let pauseNS: UInt64 = Activity.activity(for: sample.step) == .expressKeys
                ? 600_000_000   // 0.6 s
                : 1_200_000_000 // 1.2 s

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: pauseNS)
                engine.confirmAndContinue()
            }
        }

        // Wrap in Task { @MainActor in } because the engine may invoke this callback
        // from a background HID-event thread. Mutating @State from any non-main-actor
        // context is undefined behaviour and can silently drop the UI update.
        engine.onCalibrationComplete = { result in
            Task { @MainActor in
                stopRebaseline()
                if let url = engine.exportJSON(result: result) {
                    savedURL = url
                }
            }
        }

        engine.startCalibration(deviceInfo: devInfo, steps: steps)

        // Initialise the first activity and begin rebaselining immediately.
        armedActivity = activeActivity
        gate.isArmed = false
        startRebaseline()
    }

    private func deviceInfo() -> CaptureDeviceInfo? {
        let name =
            WacomDeviceRegistry.spec(for: productID)?.name
            ?? TabletManager.deviceName(forProductID: productID)
        return CaptureDeviceInfo(
            vendorID: 0x056A,
            productID: productID,
            name: name,
            locationID: nil,
            serialNumber: nil
        )
    }

    // MARK: - Baseline timer

    /// Fires every 0.25 s, resetting the engine's baseline so that pen hover
    /// movement doesn't constitute "input" until the user clicks Ready.
    private func startRebaseline() {
        stopRebaseline()
        rebaselineTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in
                guard !gate.isArmed else { return }
                engine.rebaseline()
            }
        }
    }

    private func stopRebaseline() {
        rebaselineTimer?.invalidate()
        rebaselineTimer = nil
    }
}
