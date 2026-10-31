// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later


import AppKit
import Combine
import IOKit.hid
import ServiceManagement
import SwiftUI
import TabletKit

// The Info pane's device-data capture and Diagnostic Detail sections, and
// the diagnostic text they copy and send.
extension InfoView {
    /// One button: "Collect Device Data…", which opens `CaptureGuideView`
    /// and records both the statistical summary and the full raw log for the
    /// same session, packaged into one zip.
    ///
    /// There's deliberately no running/stopped state here: the capture lasts
    /// exactly as long as the sheet.
    var captureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(String(localized: "Collect Device Data…", comment: "Button label: start device data collection")) {
                        // Always records both the summary and the full log.
                        beginCollection()
                    }
                    .buttonStyle(.bordered)
                    .appControlSize(.small)
                    .disabled(rawCaptureHeldElsewhere)
                    .help(
                        rawCaptureHeldElsewhere
                            ? String(localized: "Another tablet's window is collecting data right now. Finish that one first.", comment: "Help text when data collection is unavailable because another window owns the recording")
                            : String(localized: "Records what your tablet sends to the Mac and saves it as a zip file you can share.", comment: "Help text for the Collect Device Data button"))
                Spacer()
                if let url = rawCaptureSavedURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label(String(localized: "Show in Finder", comment: "Button: reveal the saved raw capture file"), systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                    .appFont(.settingsLabel)
                    .foregroundStyle(.secondary)
                }
            }

            Text(
                rawCaptureHeldElsewhere
                    ? String(localized: "Another tablet's window is collecting data right now. Finish that one first.", comment: "Description below the Collect Device Data button when another window owns the recording")
                    : String(localized: "Collect tablet details for support.", comment: "Description below the Collect Device Data button")
            )
            .appFont(.settingsLabel)
            .foregroundStyle(.tertiary)
        }
    }


    /// Starts `HIDCapture` and arms the UI-side polling for the live ticker
    /// and report count. Paired with every guided collection — see the
    /// Collect Device Data button.
    func beginCollection() {
        // Cleared even if the raw capture is refused, so an earlier log
        // can't be packaged with this session.
        rawCaptureSavedURL = nil
        startRawCapture()
        showCaptureGuide = true
    }

    /// Help > Collect Device Data, addressed to this window.
    func handleCollectionRequest() {
        guard collectionRequest.consume(for: instanceKey),
              !showCaptureGuide, !rawCaptureHeldElsewhere
        else { return }
        beginCollection()
    }

    func startRawCapture() {
        // Refused when another window's session already holds the raw-capture
        // singleton — starting anyway would reset its buffer mid-recording.
        guard diagnosticSession.startRawCapture() else { return }
        rawCaptureReportCount = 0
        rawCaptureSavedURL = nil
        rawCaptureRunning = true
        startRawCapturePollTimer()
    }

    func startRawCapturePollTimer() {
        rawCaptureCountTimer?.invalidate()
        rawCaptureCountTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { pollRawCapture() }
        }
    }

    func pollRawCapture() {
        rawCaptureReportCount = HIDCapture.shared.reportCount
        // Flushing/auto-stop are owned by HIDCapture's own background
        // timer, not this poll — this only needs to notice when
        // isCapturing flips false on its own (the ceiling fired) and
        // finish the UI-side teardown.
        if rawCaptureRunning, !HIDCapture.shared.isCapturing {
            finishRawCaptureTeardown()
        }
    }

    /// Cancel counterpart to `finishRawCaptureTeardown`: same UI teardown, but
    /// the recording and its partial file are thrown away instead of kept.
    func discardRawCapture() {
        rawCaptureCountTimer?.invalidate()
        rawCaptureCountTimer = nil
        rawCaptureReportCount = 0
        rawCaptureRunning = false
        rawCaptureSavedURL = nil
        diagnosticSession.cancelRawCapture()
    }

    /// Shared by manual Stop, Escape/Cmd-., and a detected auto-stop —
    /// flushes what's left, updates the UI, stops polling.
    func finishRawCaptureTeardown() {
        rawCaptureCountTimer?.invalidate()
        rawCaptureCountTimer = nil
        rawCaptureReportCount = HIDCapture.shared.reportCount
        rawCaptureRunning = false
        rawCaptureSavedURL = diagnosticSession.finishRawCapture()
    }

    // MARK: - Diagnostic section

    var diagnosticSection: some View {
        DisclosureRow(label: String(localized: "Diagnostic Detail", comment: "Collapsible section header for detailed diagnostic information"), isExpanded: $diagnosticsExpanded) {
            VStack(alignment: .trailing, spacing: 6) {
                // No separate "Updated HH:mm:ss" label — duplicates the
                // "Generated :" line already inside the snapshot text.
                Button {
                    refreshDiagnosticSnapshot()
                } label: {
                    Label(String(localized: "Refresh", comment: "Button: regenerate the diagnostic text snapshot — a last resort now that most cases refresh on their own"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .appFont(.settingsLabel)
                .foregroundStyle(.secondary)

                Text(diagnosticSnapshot)
                    .appFont(.monospaced)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
                    )
            }
        }
        .onChange(of: diagnosticsExpanded) { expanded in
            if expanded {
                refreshDiagnosticSnapshot()
                startMouseUpMonitor()
            } else {
                stopMouseUpMonitor()
            }
        }
        .onDisappear { stopMouseUpMonitor() }
        .onReceive(
            deviceContext?.livePointPublisher.eraseToAnyPublisher()
                ?? Empty().eraseToAnyPublisher()
        ) { point in
            // Proximity exit only (point going nil) — fires once per pen
            // lift, not per report. Guarded against an in-progress
            // selection drag and an already-completed one the user is
            // still looking at, since a pen lift can arrive at any point
            // after either.
            guard diagnosticsExpanded, point == nil, !selectionGestureActive, !textHasSelection else { return }
            refreshDiagnosticSnapshot()
        }
    }

    /// Refreshes the diagnostic snapshot on left-mouse-up anywhere in the
    /// app — a natural pause point that doesn't fight an in-progress
    /// selection on every redraw. Must exclude the mouse-up that *finishes*
    /// a selection inside the diagnostics text, or the refresh would wipe
    /// it back out immediately.
    ///
    /// Excluded by tracking where the gesture *started*, not where it ends
    /// — hit-testing only the mouse-up location missed drags that begin
    /// inside the text but end just outside its bounds (a very ordinary way
    /// to finish a selection).
    /// A drag shorter than this, in points, is a bare click (selects
    /// nothing) rather than a real selection.
    static let selectionDragThreshold: CGFloat = 3

    func startMouseUpMonitor() {
        guard mouseUpMonitor == nil else { return }
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            switch event.type {
            case .leftMouseDown:
                selectionGestureActive = Self.isInsideDiagnosticText(event)
                selectionGestureStart = event.locationInWindow
            case .leftMouseUp:
                let dx = event.locationInWindow.x - selectionGestureStart.x
                let dy = event.locationInWindow.y - selectionGestureStart.y
                let wasRealDrag = hypot(dx, dy) >= Self.selectionDragThreshold

                if selectionGestureActive && wasRealDrag {
                    // A real drag inside the text: new selection made.
                    textHasSelection = true
                } else if !wasRealDrag {
                    // A bare click anywhere is a deselection signal —
                    // without this, once set, textHasSelection would never
                    // clear and auto-refresh would stay blocked forever.
                    textHasSelection = false
                }
                // Remaining case — a real drag that didn't start in the
                // text — leaves textHasSelection untouched.

                if selectionGestureActive {
                    selectionGestureActive = false
                } else if !textHasSelection {
                    refreshDiagnosticSnapshot()
                }
            default:
                break
            }
            return event
        }
    }

    /// `hitTest(_:)` wants the point in the coordinate system of the
    /// *superview* of the view it's called on, not the view's own — calling
    /// it directly on `contentView` with window coordinates is off by the
    /// title bar's height.
    static func isInsideDiagnosticText(_ event: NSEvent) -> Bool {
        let hit =
            event.window?.contentView?.superview?.hitTest(event.locationInWindow)
            ?? event.window?.contentView?.hitTest(event.locationInWindow)
        guard let hit else { return false }
        return isInsideTextView(hit)
    }

    /// Walks up from the hit-tested view for a text-view ancestor. Checks
    /// both formal `NSText` conformance and class name — SwiftUI's
    /// `.textSelection(.enabled)` is backed by a private view that behaves
    /// like a text view but isn't guaranteed to declare `NSText`.
    static func isInsideTextView(_ view: NSView) -> Bool {
        var v: NSView? = view
        while let current = v {
            if current is NSText { return true }
            if NSStringFromClass(type(of: current)).localizedCaseInsensitiveContains("text") {
                return true
            }
            v = current.superview
        }
        return false
    }

    func stopMouseUpMonitor() {
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
    }

    var profileLabel: String {
        guard let profile = settings.activeProfile else {
            return String(localized: "None (device defaults)", comment: "Profile row value when no profile is active")
        }
        return profile.name
    }

    /// Builds a snapshot of diagnostic text as of the moment it's called.
    /// Deliberately not a live-reading computed property — an earlier
    /// version re-rendered on any incidental InfoView redraw, discarding an
    /// in-progress text selection. Called explicitly and cached.
    func buildDiagnosticText() -> String {
        var lines: [String] = []

        lines += [String(localized: "Generated : \(DateStamp.full())", comment: "Diagnostic: timestamp when info was generated")]

        let ver = Bundle.main.versionLabel
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        lines += [String(localized: "App       : MockTab \(ver) (build \(build))", comment: "Diagnostic: app version and build number")]

        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines += [String(localized: "macOS     : \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", comment: "Diagnostic: macOS version")]

        #if arch(arm64)
            lines += [String(localized: "CPU       : Apple Silicon (arm64)", comment: "Diagnostic: CPU architecture")]
        #else
            lines += [String(localized: "CPU       : Intel (x86_64)", comment: "Diagnostic: CPU architecture")]
        #endif

        lines += [""]

        if tabletManager.connectedProductIDs.isEmpty {
            lines += [String(localized: "Tablets   : none", comment: "Diagnostic: no tablets connected")]
        } else {
            lines += [String(localized: "Tablets   : \(tabletManager.connectedProductIDs.count)", comment: "Diagnostic: number of connected tablets")]
            for pid in tabletManager.connectedProductIDs {
                let name = TabletManager.deviceName(forProductID: pid)
                lines += ["  • \(name)  (ProductID 0x\(String(pid, radix: 16, uppercase: true)))"]
            }
            let active = tabletManager.activeContext
            lines += [String(localized: "Transport : \(active?.transport ?? "—")", comment: "Diagnostic: USB/Bluetooth transport type")]
            lines += [String(localized: "Speed     : \(active?.usbSpeed ?? "—")", comment: "Diagnostic: USB speed or Bluetooth version")]
            if let pct = active?.batteryPercent {
                let chgStr = (active?.batteryCharging ?? false) ? String(localized: " (charging)", comment: "Battery status indicator") : ""
                lines += [String(localized: "Battery   : \(pct)%\(chgStr)", comment: "Diagnostic: battery percentage and charging status")]
            } else if active?.batteryCharging == true {
                lines += [String(localized: "Battery   : charging", comment: "Diagnostic: charging, level not reported")]
            }
        }

        lines += [""]
        lines += [String(localized: "HID Manager    : \(tabletManager.hidManagerOpen ? String(localized: "open", comment: "HID Manager status") : String(localized: "failed to open", comment: "HID Manager status"))", comment: "Diagnostic: HID Manager status")]
        lines += [String(localized: "Input Monitor  : \(inputMonitoringGranted ? String(localized: "granted", comment: "Permission status") : String(localized: "not granted", comment: "Permission status"))", comment: "Diagnostic: Input Monitoring permission")]
        lines += [String(localized: "Accessibility  : \(accessibilityGranted ? String(localized: "granted", comment: "Permission status") : String(localized: "not granted", comment: "Permission status"))", comment: "Diagnostic: Accessibility permission")]
        lines += [String(localized: "Launch at login: \(launchAtLogin ? String(localized: "enabled", comment: "Launch at login status") : String(localized: "disabled", comment: "Launch at login status"))", comment: "Diagnostic: Launch at login setting")]
        lines += [String(localized: "Profile        : \(profileLabel)", comment: "Diagnostic: active profile name")]

        lines += [""]
        if conflicts.isEmpty {
            lines += [String(localized: "Conflicts      : none", comment: "Diagnostic: no conflicting drivers")]
        } else {
            lines += [String(localized: "Conflicts      : \(conflicts.count)", comment: "Diagnostic: number of conflicting drivers")]
            for conflict in conflicts {
                switch conflict {
                case .driver(_, let names):
                    lines += names.map { "  ⚠ \($0)" }
                case .interference(let level):
                    let value = level.formatted(.number.precision(.fractionLength(1)))
                    lines += ["  ⚠ " + String(localized: "RF interference: \(value) pt/sample", comment: "Conflict detection: RF interference jitter")]
                }
            }
        }
        // Listed for reports, not counted: they leave the tablet alone.
        let helpers = ConflictProcessMatcher.matches(liveNames: Self.knownRunningAppNames ?? []).wacomHelpers
        if !helpers.isEmpty {
            lines += [String(localized: "Wacom helpers  : \(helpers.joined(separator: ", "))", comment: "Diagnostic: harmless Wacom apps running, such as its updater; the argument lists bundle IDs")]
        }

        // Copied on the pen thread, which updates these with every report.
        let pen = HIDThread.shared.performAndWait {
            [injector = tabletManager.activeContext?.injector] in
            PenThreadReadings(injector: injector, probe: .shared)
        }

        if let jitterHist = pen.jitterHistogram {
            let jitterTotal = jitterHist.reduce(0, +)
            if jitterTotal > 0 {
                // Cumulative since this tool came into proximity, unlike
                // the instantaneous jitter level — so a snapshot between
                // hover sessions still shows recent jitter, not zero.
                var bounds = CursorSmoother.jitterHistogramBucketsPtPerSample.map { "<\($0)" }
                bounds.append(">\(CursorSmoother.jitterHistogramBucketsPtPerSample.last!)")
                let parts = zip(bounds, jitterHist).map { "\($0):\($1)" }
                lines += [String(localized: "Jitter (pt/sample): \(parts.joined(separator: "  "))", comment: "Diagnostic: histogram of hover-jitter sample magnitudes, cumulative for this tool's proximity session")]
            } else {
                lines += [String(localized: "Jitter (pt/sample): no hover samples yet", comment: "Diagnostic: jitter histogram is empty")]
            }

            // Non-zero means this machine hits the stale-cache window; zero on a
            // machine still losing modifiers rules that mechanism out.
            let drops = pen.staleModifierCacheDrops
            if drops > 0 {
                lines += [String(localized: "Modifier resync: \(drops) move events deferred to the keyboard", comment: "Diagnostic: count of move events that omitted physical modifier bits because the cached keyboard state was older than the report being stamped")]
            }
        }

        let probe = pen.probe
        if probe.reportCount > 0 {
            let avg = probe.averageMs.formatted(.number.precision(.fractionLength(2)))
            let worst = probe.worstMs.formatted(.number.precision(.fractionLength(1)))
            lines += [String(localized: "HID latency    : \(avg) ms avg, \(worst) ms worst, \(probe.stallCount) stalls >\(Int(LatencyProbe.stallThresholdMs)) ms", comment: "Diagnostic: HID report delivery latency from kernel receipt to driver callback, steady-state usage only")]
            if probe.totalAverageMs > 0 {
                let totalAvg = probe.totalAverageMs.formatted(.number.precision(.fractionLength(2)))
                let totalWorst = probe.totalWorstMs.formatted(.number.precision(.fractionLength(1)))
                lines += [String(localized: "Pipeline total : \(totalAvg) ms avg, \(totalWorst) ms worst (kernel receipt → events posted)", comment: "Diagnostic: total in-app latency from kernel receipt of a HID report to the synthesized events being posted")]
            }
        }
        if probe.connectStallCount > 0 {
            let connectWorst = probe.connectWorstMs.formatted(.number.precision(.fractionLength(1)))
            lines += [String(localized: "  (device connect: \(connectWorst) ms worst, \(probe.connectStallCount) stalls — excluded above)", comment: "Diagnostic: latency spikes during device connection, excluded from the steady-state HID latency line")]
        }

        let histTotal = probe.gapHistogramMs.reduce(0, +)
        if histTotal > 0 {
            var bounds = LatencyProbe.gapHistogramBucketsMs.map { "<\(Int($0))" }
            bounds.append(">\(Int(LatencyProbe.gapHistogramBucketsMs.last!))")
            let parts = zip(bounds, probe.gapHistogramMs).map { "\($0)ms:\($1)" }
            lines += [String(localized: "Report gaps    : \(parts.joined(separator: "  "))", comment: "Diagnostic: histogram of inter-report arrival gaps, in milliseconds, for spotting bursty/coalesced delivery")]
        }

        // Memory counterpart to the latency lines above.
        if let footprint = FootprintProbe.read() {
            let current = FootprintProbe.megabytes(footprint.current)
            let peak = FootprintProbe.megabytes(footprint.peak)
            lines += [String(localized: "Memory         : \(current) MB now, \(peak) MB peak", comment: "Diagnostic: process memory footprint, current and lifetime peak, in megabytes")]
        }

        if let parsed = unrecognizedDriver?.parsedDescriptor {
            lines += [""]
            lines += ["─── HID Report Descriptor (unrecognized tablet) ───"]
            lines += [LiveHIDDescriptorInspector.summarize(parsed)]
            if let hex = parsed.rawHex {
                lines += [""]
                lines += ["Raw bytes:"]
                lines += [hex]
            }
        }

        return lines.joined(separator: "\n")
    }
}
