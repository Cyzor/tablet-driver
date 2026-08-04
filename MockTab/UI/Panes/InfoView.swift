// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import ServiceManagement
import SwiftUI
import TabletKit

/// Status dashboard tab — shows live device state, system permissions,
/// and a collapsible diagnostic dump for technical analysis.
struct InfoView: View {
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var settings: TabletSettings
    let instanceKey: DeviceInstanceKey?
    /// Model axis of the bound unit — spec/catalog lookups key on this.
    private var productID: Int? { instanceKey?.productID }

    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var launchAtLogin = false
    @State private var diagnosticsExpanded = false
    @State private var diagnosticSnapshot = ""
    @State private var diagnosticSnapshotAt = Date()
    @State private var conflicts: [ConflictFinding] = []
    @State private var showCaptureGuide = false
    /// Local event monitor refreshing the diagnostic snapshot on mouse-up,
    /// active only while the panel is expanded and torn down otherwise —
    /// see the `.onChange(of: diagnosticsExpanded)` below.
    @State private var mouseUpMonitor: Any?
    /// True between a mouse/pen-down that started inside the diagnostics
    /// text and its matching mouse-up — i.e. a selection drag is (or was
    /// just) in progress. Guards refreshes *during* the drag itself.
    @State private var selectionGestureActive = false
    /// Where `selectionGestureActive` became true, in window coordinates —
    /// compared against the mouse-up location to tell a real drag-selection
    /// from a bare click (which places a cursor but selects nothing worth
    /// protecting).
    @State private var selectionGestureStart: CGPoint = .zero
    /// True once a real drag-selection inside the diagnostics text has
    /// completed, and stays true *after* the gesture ends — unlike
    /// `selectionGestureActive`, which only covers the drag itself. Without
    /// this, a proximity exit (or any other automatic trigger) arriving
    /// after the user has let go of the mouse but is still looking at their
    /// selection would refresh right out from under it. Cleared only by an
    /// actual refresh (`refreshDiagnosticSnapshot()`), since that's the one
    /// thing that genuinely invalidates whatever was selected.
    @State private var textHasSelection = false
    /// Owned per-window rather than a shared singleton: two tablet windows
    /// each collecting data must not see each other's Cancel/Done, event
    /// counts, or recorded reports.
    @StateObject private var captureEngine = CaptureEngine()

    var body: some View {
        SettingsPane(
            settings: settings, tabletManager: tabletManager, registry: DeviceRegistry.shared,
            instanceKey: instanceKey
        ) {
            if fallbackDevice != nil || genericDigitizer != nil {
                Section {
                    unknownDeviceBanner
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                statusTable
            } header: {
                Text("Status").appFont(.headline)
            }
            Section {
                LiveInputSectionContent(
                    deviceContext: deviceContext,
                    productID: productID
                )
            } header: {
                Text(String(localized: "Live Input", comment: "Section header: live input state and pen position"))
                    .appFont(.headline)
            }
            Section {
                captureSection
                diagnosticSection
            } header: {
                Text(String(localized: "Diagnostics", comment: "Section header: device diagnostics and data collection"))
                    .appFont(.headline)
            }
        }
        .onAppear { refresh() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in refresh() }
        .sheet(isPresented: $showCaptureGuide) {
            CaptureGuideView(
                engine: captureEngine,
                tabletManager: tabletManager,
                productID: productID ?? 0,
                onDismiss: { showCaptureGuide = false }
            )
        }
    }

    // MARK: - Status table

    private var deviceContext: DeviceContext? {
        tabletManager.context(forKey: instanceKey)
    }

    private var isConnected: Bool {
        deviceContext?.isConnected ?? false
    }

    /// Connected aux-only companion peripheral (currently only the Xencelabs
    /// Quick Keys puck/dongle) — same resolution `DeviceStatusBar` and
    /// `ButtonMappingView` use for their own companion sections.
    private var companionContext: DeviceContext? {
        guard let productID else { return nil }
        let companionPID = VendorDeviceRegistry.connectedCompanion(
            forProductID: productID, connectedProductIDs: tabletManager.connectedProductIDs)
        return companionPID.flatMap { tabletManager.contexts[$0] }
    }

    private var fallbackDevice: WacomFallbackDevice? {
        deviceContext?.tabletDevice as? WacomFallbackDevice
    }

    private var genericDigitizer: GenericHIDDigitizer? {
        deviceContext?.tabletDevice as? GenericHIDDigitizer
    }

    /// Brand/category guessed from USB strings for an unrecognized device,
    /// when available — `WacomFallbackDevice` already knows it's Wacom, so
    /// only `GenericHIDDigitizer` carries a heuristic guess.
    private var detectedBrand: String? {
        genericDigitizer?.detectedBrand
    }

    private var unknownDeviceBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.orange)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Unrecognized tablet", comment: "Banner title shown when active device is on the generic fallback driver"))
                    .appFont(.headline)
                if let detectedBrand {
                    Text(String(localized: "Looks like \(detectedBrand), but MockTab doesn't know this model yet.", comment: "Brand guess shown above the unknown-device banner body when USB strings hint at a known tablet brand"))
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(String(localized: "MockTab is running its generic driver, so basic pen input may work. Full support needs a short recording of what your tablet sends.", comment: "Body of the unknown-device banner"))
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "Collect Device Data…", comment: "Banner button: start the data-collection session for an unknown device")) {
                    showCaptureGuide = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var statusTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            row(
                String(localized: "Device", comment: "Row label in Info tab status table"),
                value: isConnected
                    ? TabletManager.deviceName(forProductID: productID ?? 0)
                    : String(localized: "Not connected", comment: "Device connection status value"),
                ok: isConnected)

            row(
                String(localized: "Connection", comment: "Row label in Info tab status table"),
                value: deviceContext?.transport ?? "—",
                ok: isConnected ? true : nil)

            if let pct = deviceContext?.batteryPercent {
                row(
                    String(localized: "Battery", comment: "Row label in Info tab status table"),
                    value: (deviceContext?.batteryCharging ?? false)
                        ? "\(pct)%  \(String(localized: "(Charging)", comment: "Suffix when device is charging, e.g. '85%  (Charging)'"))"
                        : "\(pct)%",
                    ok: pct < 20 ? false : nil,
                    leadingSymbol: BatteryIndicator.symbolName(
                        pct: pct,
                        charging: deviceContext?.batteryCharging ?? false),
                    // Affirmative green when healthy — this table is the
                    // place users come to check on the device.
                    symbolColor: BatteryIndicator.tint(
                        pct: pct,
                        charging: deviceContext?.batteryCharging ?? false,
                        healthy: .green))
            }

            if let pct = companionContext?.batteryPercent {
                row(
                    String(localized: "Quick Keys Battery", comment: "Row label in Info tab status table — connected companion peripheral's battery"),
                    value: (companionContext?.batteryCharging ?? false)
                        ? "\(pct)%  \(String(localized: "(Charging)", comment: "Suffix when device is charging, e.g. '85%  (Charging)'"))"
                        : "\(pct)%",
                    ok: pct < 20 ? false : nil,
                    leadingSymbol: BatteryIndicator.symbolName(
                        pct: pct,
                        charging: companionContext?.batteryCharging ?? false),
                    symbolColor: BatteryIndicator.tint(
                        pct: pct,
                        charging: companionContext?.batteryCharging ?? false,
                        healthy: .green))
            }

            row(
                String(localized: "Speed", comment: "Row label in Info tab status table — USB speed"),
                value: deviceContext?.usbSpeed ?? "—",
                ok: isConnected ? true : nil)

            row(
                String(localized: "Status", comment: "Row label in Info tab status table — driver status"),
                value: isConnected
                    ? String(localized: "Active", comment: "Driver status value — device is active")
                    : String(localized: "Idle", comment: "Driver status value — device is idle"),
                ok: isConnected ? true : nil)

            row(
                String(localized: "Permission", comment: "Row label in Info tab status table — Accessibility permission"),
                value: accessibilityGranted
                    ? String(localized: "Granted", comment: "Accessibility permission status value")
                    : String(localized: "Not granted", comment: "Accessibility permission status value"),
                ok: accessibilityGranted,
                fix: accessibilityGranted ? nil : requestAccessibility,
                fixHelp: String(localized: "Open System Settings to grant MockTab permission to inject keyboard and mouse events into other apps.", comment: "Tooltip on Fix button for Accessibility permission")
            )

            row(
                String(localized: "HID Manager", comment: "Row label in Info tab status table"),
                value: tabletManager.hidManagerOpen
                    ? String(localized: "Running", comment: "HID Manager status value")
                    : String(localized: "Failed to open", comment: "HID Manager status value — error state"),
                ok: tabletManager.hidManagerOpen ? true : false)

            row(
                String(localized: "Profile", comment: "Row label in Info tab status table — active profile name"),
                value: presetLabel,
                ok: nil)

            row(
                String(localized: "Launch at Login", comment: "Row label in Info tab status table"),
                value: launchAtLogin
                    ? String(localized: "Enabled", comment: "Launch at Login status value")
                    : String(localized: "Disabled", comment: "Launch at Login status value"),
                ok: launchAtLogin ? true : nil,
                fix: launchAtLogin ? nil : enableLaunchAtLogin,
                // A disabled preference isn't a fault — label the action for
                // what it does instead of the repair-framed "Fix".
                fixLabel: String(localized: "Enable", comment: "Button that turns on Launch at Login from the Info tab"),
                fixHelp: String(localized: "Enable MockTab to start automatically when you log in.", comment: "Tooltip on Enable button for Launch at Login"))

            row(
                String(localized: "Conflicts", comment: "Row label in Info tab status table"),
                value: conflicts.isEmpty
                    ? String(localized: "None detected", comment: "Conflicts status value — no conflicts")
                    : String(localized: "\(conflicts.count) detected", comment: "Conflicts status value when conflicts are found, showing count"),
                ok: conflicts.isEmpty ? true : false,
                fix: conflicts.isEmpty ? nil : showConflictAlert,
                fixHelp: String(localized: "Show details about detected conflicts with other tablet drivers and how to resolve them.", comment: "Tooltip on Fix button for Conflicts row")
            )
        }
    }

    @ViewBuilder
    private func row(
        _ label: String, value: String,
        ok: Bool?,
        leadingSymbol: String? = nil,
        symbolColor: Color? = nil,
        fix: (() -> Void)? = nil,
        fixLabel: String? = nil,
        fixHelp: String? = nil
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .scaledFrame(minWidth: 150, alignment: .trailing)
                .gridColumnAlignment(.trailing)

            HStack(spacing: 8) {
                if let sym = leadingSymbol {
                    Image(systemName: sym)
                        .foregroundStyle(symbolColor ?? .primary)
                        .accessibilityHidden(true)
                } else {
                    statusIcon(ok)
                }
                Text(value)
                if let fix {
                    Button(fixLabel ?? String(localized: "Fix", comment: "Default button label for repairing a failed status row in the Info tab"), action: fix)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(fixHelp ?? "")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func statusIcon(_ ok: Bool?) -> some View {
        if ok == true {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("OK")
        } else if ok == false {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.primary)
                .accessibilityLabel("Failed")
        } else {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Unknown")
        }
    }

    // MARK: - HID capture section

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(String(localized: "Collect Device Data…", comment: "Button label: start device data collection")) {
                    showCaptureGuide = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(String(localized: "Records what your tablet sends to the Mac and saves it as a small JSON file you can share.", comment: "Help text for the Collect Device Data button"))
                Spacer()
            }

            Text(String(localized: "Gather tablet details for support.  May take a few minutes.", comment: "Description below the Collect Device Data button"))
                .appFont(.settingsLabel)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Diagnostic section

    private var diagnosticSection: some View {
        DisclosureRow(label: String(localized: "Diagnostic Detail", comment: "Collapsible section header for detailed diagnostic information"), isExpanded: $diagnosticsExpanded) {
            VStack(alignment: .trailing, spacing: 6) {
                // No separate "Updated HH:mm:ss" label here — it always
                // duplicated the "Generated :" line already inside the
                // snapshot text below, just in a different spot.
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
            // Refresh on proximity exit (point going nil) only — fires once
            // per pen lift, not per report. Guarded against both an
            // in-progress drag (ending a stylus-driven selection *is* a pen
            // lift, and if it also registers as a full proximity exit, this
            // must not refresh out from under it) and an already-completed
            // selection the user is still looking at — a pen lift is
            // unrelated to the tablet's own timing, so it can arrive at any
            // point after the drag finished, not just during it. Safe from
            // the jitter-reset issue regardless, now that jitter is a
            // cumulative histogram rather than the instantaneous value
            // `resetOnProximityExit()` zeroes here.
            guard diagnosticsExpanded, point == nil, !selectionGestureActive, !textHasSelection else { return }
            refreshDiagnosticSnapshot()
        }
    }

    /// Refreshes the diagnostic snapshot on left-mouse-up anywhere in the
    /// app: mouse release is a natural pause point, not a continuous stream,
    /// so unlike the old live-updating property it doesn't fight an
    /// in-progress selection on every redraw. Local monitors run before
    /// normal event dispatch, so this fires even for a mouse-up inside the
    /// diagnostics text itself — which is exactly the case that must be
    /// excluded: that specific mouse-up is what *finishes* a text selection
    /// there, and refreshing under it would wipe the selection right back
    /// out.
    ///
    /// Excluded by tracking where the gesture *started*, not where it ends.
    /// Hit-testing only the mouse-up location (tried first) missed drags
    /// that begin inside the text but end just outside its exact bounds —
    /// in the padding/background/border chrome that visually looks like
    /// part of the box but isn't the `NSTextView` itself — which is a very
    /// ordinary way to finish a selection (dragging past the last line, or
    /// slightly past an edge). Matching mouse-down and mouse-up as a pair
    /// and remembering only the down-location's hit test handles that:
    /// a selection gesture is defined by where it began.
    /// A drag shorter than this, in points, is treated as a bare click
    /// (places a cursor, selects nothing) rather than a real selection —
    /// so it doesn't latch `textHasSelection` and block future auto-refresh
    /// for no reason.
    private static let selectionDragThreshold: CGFloat = 3

    private func startMouseUpMonitor() {
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
                    // A bare click anywhere — inside the text (collapses any
                    // existing selection to a cursor) or elsewhere (the
                    // ordinary "I'm done with that" gesture) — is a
                    // deselection signal. Without this, once a real
                    // selection had ever been made, nothing would resume
                    // auto-refreshing even after the user visibly let go of
                    // it, since textHasSelection only ever got set, never
                    // cleared.
                    textHasSelection = false
                }
                // The remaining case — a real drag that *didn't* start in
                // the text (e.g. resizing something elsewhere) — leaves
                // textHasSelection untouched, so an existing protected
                // selection stays protected regardless of unrelated drags.

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
    /// it directly on `contentView` with window coordinates (an earlier
    /// version of this did) is off by the title bar's height, so the check
    /// silently never matched anything.
    private static func isInsideDiagnosticText(_ event: NSEvent) -> Bool {
        let hit =
            event.window?.contentView?.superview?.hitTest(event.locationInWindow)
            ?? event.window?.contentView?.hitTest(event.locationInWindow)
        guard let hit else { return false }
        return isInsideTextView(hit)
    }

    /// Walks up from the hit-tested view looking for a text-view ancestor —
    /// the hit view itself is often a clip/container view nested a level or
    /// two above the actual text view. Checks both formal `NSText`
    /// conformance and the class name: SwiftUI's `.textSelection(.enabled)`
    /// on a plain `Text` is backed by a private view that behaves like a
    /// text view (click-drag selects, first-responder-adjacent) but isn't
    /// guaranteed to formally declare `NSText` conformance, so relying on
    /// `is NSText` alone already missed once. The class-name check is
    /// deliberately loose to catch that private type without needing its
    /// exact name.
    private static func isInsideTextView(_ view: NSView) -> Bool {
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

    private func stopMouseUpMonitor() {
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
    }

    private var presetLabel: String {
        guard let profile = settings.activeProfile else {
            return String(localized: "None (device defaults)", comment: "Profile row value when no profile is active")
        }
        switch settings.activationSource {
        case .manual:
            return "\(profile.name)"
        case .app(_, let appName):
            return "\(profile.name)  \(String(localized: "(Auto: \(appName))", comment: "Auto-activation suffix in Profile row, e.g. '(Auto: TextEdit)'"))"
        }
    }

    /// Builds a snapshot of diagnostic text as of the moment it's called.
    /// Deliberately *not* a live-reading computed property: earlier it read
    /// `Date()` and app state inline, so any incidental re-render of
    /// `InfoView` (mouse hover elsewhere, window activation, a pen report
    /// arriving) produced different text — which meant the `Text` view's
    /// content changed under an in-progress selection, discarding it before
    /// the user could copy anything. Called explicitly by `refresh()` and
    /// cached in `diagnosticSnapshot`, so the displayed text only changes
    /// when the user asks for it.
    private func buildDiagnosticText() -> String {
        var lines: [String] = []

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        lines += [String(localized: "Generated : \(fmt.string(from: Date()))", comment: "Diagnostic: timestamp when info was generated")]

        let ver =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
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
            }
        }

        lines += [""]
        lines += [String(localized: "HID Manager    : \(tabletManager.hidManagerOpen ? String(localized: "open", comment: "HID Manager status") : String(localized: "failed to open", comment: "HID Manager status"))", comment: "Diagnostic: HID Manager status")]
        lines += [String(localized: "Accessibility  : \(accessibilityGranted ? String(localized: "granted", comment: "Accessibility permission status") : String(localized: "not granted", comment: "Accessibility permission status"))", comment: "Diagnostic: Accessibility permission")]
        lines += [String(localized: "Launch at login: \(launchAtLogin ? String(localized: "enabled", comment: "Launch at login status") : String(localized: "disabled", comment: "Launch at login status"))", comment: "Diagnostic: Launch at login setting")]
        lines += [String(localized: "Profile        : \(presetLabel)", comment: "Diagnostic: active profile name")]

        lines += [""]
        if conflicts.isEmpty {
            lines += [String(localized: "Conflicts      : none", comment: "Diagnostic: no conflicting drivers")]
        } else {
            lines += [String(localized: "Conflicts      : \(conflicts.count)", comment: "Diagnostic: number of conflicting drivers")]
            for conflict in conflicts {
                lines += ["  ⚠ \(conflict.description)"]
            }
        }

        if let ctx = tabletManager.activeContext {
            let jitterHist = ctx.injector.jitterHistogram
            let jitterTotal = jitterHist.reduce(0, +)
            if jitterTotal > 0 {
                // Cumulative since this tool came into proximity — not reset
                // by tip-down/proximity-exit like the instantaneous jitter
                // level, so a snapshot taken between hover sessions still
                // shows whether meaningful jitter has occurred recently
                // instead of always reading zero.
                var bounds = CursorSmoother.jitterHistogramBucketsPtPerSample.map { "<\($0)" }
                bounds.append(">\(CursorSmoother.jitterHistogramBucketsPtPerSample.last!)")
                let parts = zip(bounds, jitterHist).map { "\($0):\($1)" }
                lines += [String(localized: "Jitter (pt/sample): \(parts.joined(separator: "  "))", comment: "Diagnostic: histogram of hover-jitter sample magnitudes, cumulative for this tool's proximity session")]
            } else {
                lines += [String(localized: "Jitter (pt/sample): no hover samples yet", comment: "Diagnostic: jitter histogram is empty")]
            }
        }

        let probe = LatencyProbe.shared
        if probe.reportCount > 0 {
            let avg = String(format: "%.2f", probe.averageMs)
            let worst = String(format: "%.1f", probe.worstMs)
            lines += [String(localized: "HID latency    : \(avg) ms avg, \(worst) ms worst, \(probe.stallCount) stalls >\(Int(LatencyProbe.stallThresholdMs)) ms", comment: "Diagnostic: HID report delivery latency from kernel receipt to driver callback, steady-state usage only")]
            if probe.totalAverageMs > 0 {
                let totalAvg = String(format: "%.2f", probe.totalAverageMs)
                let totalWorst = String(format: "%.1f", probe.totalWorstMs)
                lines += [String(localized: "Pipeline total : \(totalAvg) ms avg, \(totalWorst) ms worst (kernel receipt → events posted)", comment: "Diagnostic: total in-app latency from kernel receipt of a HID report to the synthesized events being posted")]
            }
        }
        if probe.connectStallCount > 0 {
            let connectWorst = String(format: "%.1f", probe.connectWorstMs)
            lines += [String(localized: "  (device connect: \(connectWorst) ms worst, \(probe.connectStallCount) stalls — excluded above)", comment: "Diagnostic: latency spikes during device connection, excluded from the steady-state HID latency line")]
        }

        let histTotal = probe.gapHistogramMs.reduce(0, +)
        if histTotal > 0 {
            var bounds = LatencyProbe.gapHistogramBucketsMs.map { "<\(Int($0))" }
            bounds.append(">\(Int(LatencyProbe.gapHistogramBucketsMs.last!))")
            let parts = zip(bounds, probe.gapHistogramMs).map { "\($0)ms:\($1)" }
            lines += [String(localized: "Report gaps    : \(parts.joined(separator: "  "))", comment: "Diagnostic: histogram of inter-report arrival gaps, in milliseconds, for spotting bursty/coalesced delivery")]
        }

        if let fallback = fallbackDevice {
            lines += [""]
            lines += ["─── HID Report Descriptor (fallback driver) ───"]
            lines += [HIDDescriptorReader.summarize(fallback.parsedDescriptor)]
            if let hex = fallback.parsedDescriptor.rawHex {
                lines += [""]
                lines += ["Raw bytes:"]
                lines += [hex]
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Actions

    private func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        conflicts = detectConflicts()
        refreshDiagnosticSnapshot()
    }

    /// Single choke point for updating `diagnosticSnapshot`, so every
    /// trigger (manual button, expand, mouse-up, proximity exit) also
    /// stamps `diagnosticSnapshotAt` for the "Updated Xs ago" label —
    /// otherwise it's impossible to tell staleness from "nothing changed"
    /// from "the refresh mechanism is broken."
    private func refreshDiagnosticSnapshot() {
        diagnosticSnapshot = buildDiagnosticText()
        diagnosticSnapshotAt = Date()
        textHasSelection = false
    }

    private func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
    }

    // MARK: - Conflict detection

    private struct ConflictFinding {
        let description: String
        let remedy: String
    }

    private func detectConflicts() -> [ConflictFinding] {
        var found: [ConflictFinding] = []

        let running = NSWorkspace.shared.runningApplications
        var liveNames = Set(running.compactMap { $0.localizedName })
        liveNames.formUnion(running.compactMap { $0.bundleIdentifier })

        let driverRemedy = String(localized: "Quit or disable it, then restart MockTab. Check System Settings → General → Login Items to stop it launching at startup.", comment: "Remedy line for a conflicting-driver finding in the conflict alert")
        for label in ConflictProcessMatcher.matchedLabels(liveNames: liveNames) {
            found.append(ConflictFinding(
                description: String(localized: "Conflicting driver: \(label)", comment: "Conflict detection: named process is running"),
                remedy: driverRemedy))
        }

        if let ctx = tabletManager.activeContext, ctx.injector.isJittery {
            let level = String(format: "%.1f", ctx.injector.jitterLevel)
            found.append(ConflictFinding(
                description: String(localized: "RF interference: \(level) pt/sample", comment: "Conflict detection: RF interference jitter"),
                remedy: String(localized: "Move wireless receivers (mice, keyboards, Wi-Fi dongles) away from the tablet.", comment: "Remedy line for an RF-interference finding in the conflict alert")))
        }

        return found
    }

    private func showConflictAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Potential Conflicts Detected", comment: "Alert title when user taps Fix on the Conflicts row")

        let intro = String(localized: "MockTab found the following issues that may interfere with tablet operation:", comment: "First sentence of conflict alert body")
        var sections = [intro]
        for (i, conflict) in conflicts.enumerated() {
            sections.append("\(i + 1). \(conflict.description)\n   \(conflict.remedy)")
        }

        alert.informativeText = sections.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func enableLaunchAtLogin() {
        do {
            try SMAppService.mainApp.register()
            refresh()
        } catch {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
            )
        }
    }
}

// MARK: - LiveInputSectionContent
//
// Owns the livePointTick polling dependency itself, rather than InfoView
// hosting it. `livePoint` publishes on every HID report, so anything that
// reads livePointTick in its body re-renders at report rate — previously
// that was all of InfoView.body, including the diagnostics text below,
// which meant selecting that text with a stylus regenerated the very
// livePoint reports that blew away the in-progress selection on every
// redraw (a mouse-driven selection isn't itself a livePoint source, so it
// didn't hit this). Scoping the tick to just this subtree keeps the
// diagnostics section — and everything else in InfoView — stable while
// the pen moves.
private struct LiveInputSectionContent: View {
    let deviceContext: DeviceContext?
    let productID: Int?

    /// Unused directly — its writes force a body re-evaluation when
    /// livePoint publishes, since that no longer rides tabletManager's
    /// general objectWillChange cascade (see DeviceContext.livePoint).
    @State private var livePointTick = 0

    var body: some View {
        // Establishes livePointTick as a read dependency of this body —
        // without a read, bumping it doesn't reliably trigger a re-render.
        let _ = livePointTick
        LiveInputView(
            livePoint: deviceContext?.livePoint,
            liveButtons: deviceContext?.liveButtons ?? LiveButtonState(),
            activeToolID: deviceContext?.activeToolID,
            registry: DeviceRegistry.shared,
            hasDualRings: WacomDeviceRegistry.spec(for: productID ?? 0)?.hasDualRings == true,
            // Only Wacom's protocol carries a hover height; every other
            // decoder hardcodes 0, so show plain in/out instead of a
            // number that reads as a measured zero.
            reportsHoverDistance: (deviceContext?.vendorID ?? 0x056A) == 0x056A
        )
        .onReceive(
            deviceContext?.livePointPublisher.eraseToAnyPublisher()
                ?? Empty().eraseToAnyPublisher()
        ) { _ in livePointTick &+= 1 }
    }
}

// MARK: - LiveInputView
//
// Isolated from InfoView so SwiftUI only diffs and re-renders this section
// when livePoint / liveButtons / activeToolID change.

private struct LiveInputView: View {
    let livePoint: TabletPoint?
    let liveButtons: LiveButtonState
    let activeToolID: String?
    let registry: DeviceRegistry
    var hasDualRings: Bool = false
    var reportsHoverDistance: Bool = true

    // MARK: - Rotation gauge

    /// Accumulated rotation for monotonic sweep. If new angle is >180 less than
    /// the previous, we've wrapped 0/360 and should add 360 to keep motion forward.
    @State private var accumAngle: Double = 0

    /// Clock-face rotation gauge: thin line pivots from center like a clock hand.
    /// Negates the accumulated angle so clockwise physical twist = clockwise sweep.
    @ViewBuilder
    private func rotationGauge(degrees: Double?) -> some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1.5)
            Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 2, height: 6).offset(y: -14)
            Rectangle().fill(Color.accentColor).frame(width: 2, height: 14).offset(y: -7)
                .rotationEffect(.radians(-accumAngle * .pi / 180), anchor: .center)
        }
        .frame(width: 36, height: 36)
        .onChange(of: degrees) { newDeg in
            if let d = newDeg {
                if accumAngle > 0 && (d - accumAngle) < -180 {
                    accumAngle = d + 360
                } else {
                    accumAngle = d
                }
            } else {
                accumAngle = 0
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                let tool: DeviceRegistry.KnownTool? = {
                    guard let id = activeToolID else { return nil }
                    return registry.knownTools.first(where: { $0.id == id })
                }()

                stylusRow(label: String(localized: "Stylus Name", comment: "Live Input table row label"), value: tool?.nickname ?? "—")
                stylusRow(label: String(localized: "Stylus Type", comment: "Live Input table row label"), value: tool?.kind ?? "—")
                stylusRow(
                    label: String(localized: "Tool Code", comment: "Live Input table row label — hex tool identifier"),
                    value: tool?.toolCode.map { "0x\(String(format: "%04X", $0))" } ?? "—")
                stylusRow(label: String(localized: "Serial", comment: "Live Input table row label — tool serial number"), value: tool?.displayID ?? "—")

                Divider()
                    .gridCellColumns(2)
                    .padding(.vertical, 4)

                let point = livePoint
                let lb = liveButtons

                liveRow(label: String(localized: "Buttons", comment: "Live Input table row label")) {
                    let anyExpress = lb.expressKeys.contains(true)
                    HStack(spacing: 4) {
                        if lb.tipDown { tag(String(localized: "Tip", comment: "Pen tip live input tag")) }
                        if lb.eraserDown { tag(String(localized: "Eraser", comment: "Eraser live input tag")) }
                        if lb.button1Down { tag("B1") }
                        if lb.button2Down { tag("B2") }
                        ForEach(0..<lb.expressKeys.count, id: \.self) { i in
                            if lb.expressKeys[i] { tag("K\(i + 1)") }
                        }
                        if !lb.tipDown && !lb.eraserDown && !lb.button1Down
                            && !lb.button2Down && !anyExpress
                        {
                            Text("None").foregroundStyle(.tertiary).appFont(.settingsBadge)
                        }
                    }
                }

                liveRow(label: String(localized: "Pressure", comment: "Live Input table row label")) {
                    HStack {
                        Text(point != nil ? "\(point!.pressure)" : "0")
                            .monospacedDigit()
                            .scaledFrame(width: 48, alignment: .trailing)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.2))
                                Capsule().fill(Color.accentColor)
                                    .frame(
                                        width: geo.size.width
                                            * CGFloat(point?.normalizedPressure ?? 0))
                            }
                        }
                        .frame(width: 80, height: 6)
                    }
                }

                liveRow(label: String(localized: "Rotation", comment: "Live Input table row label — pen rotation in degrees")) {
                    rotationGauge(degrees: point?.rotation)
                }

                // Coordinate and tilt are heavily quantized: this table is a
                // liveness check, not a precision readout, and raw values
                // flicker on every report even with the pen at rest.
                liveRow(label: String(localized: "Coordinate", comment: "Live Input table row label — raw X/Y position")) {
                    Text(
                        point != nil
                            ? "X: \(quantize(point!.x, to: 100))   Y: \(quantize(point!.y, to: 100))"
                            : String(localized: "X: 0   Y: 0", comment: "Default coordinate display when no pen is detected")
                    )
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                liveRow(label: String(localized: "Tilt", comment: "Live Input table row label — pen tilt X/Y")) {
                    Text(
                        point != nil
                            ? "X: \(String(format: "%+.1f", point!.tiltX))   Y: \(String(format: "%+.1f", point!.tiltY))"
                            : String(localized: "X: +0.0   Y: +0.0", comment: "Default tilt display when no pen is detected")
                    )
                    .monospacedDigit()
                }

                liveRow(label: String(localized: "Hover", comment: "Live Input table row label — hover distance")) {
                    if let p = point, reportsHoverDistance {
                        Text("\(p.hoverDistance)   \(p.inProximity ? String(localized: "(In Range)", comment: "Hover proximity state") : String(localized: "(Out)", comment: "Hover proximity state — out of range"))")
                            .monospacedDigit()
                    } else if let p = point {
                        Text(p.inProximity
                            ? String(localized: "In Range", comment: "Hover state without a height value — device reports only in/out")
                            : String(localized: "Out of Range", comment: "Hover state without a height value — device reports only in/out"))
                    } else {
                        Text("—").monospacedDigit()
                    }
                }

                liveRow(label: hasDualRings ? String(localized: "Ring \u{2014} Left", comment: "Live Input table row label — left touch ring on dual-ring tablets") : String(localized: "Touch Ring", comment: "Section header / row label for touch ring")) {
                    HStack(spacing: 6) {
                        Image(
                            systemName: lb.touchRingActive
                                ? "checkmark.circle.fill" : "circle"
                        )
                        .foregroundStyle(lb.touchRingActive ? Color.green : Color.secondary)
                        .imageScale(.small)
                        Text(verbatim: lb.touchRingActive
                            ? String(localized: "Active", comment: "Touch ring active state in Live Input")
                            : String(localized: "Idle", comment: "Touch ring idle state in Live Input"))
                            .foregroundStyle(lb.touchRingActive ? .primary : .tertiary)
                    }
                }

                if hasDualRings {
                    liveRow(label: String(localized: "Ring \u{2014} Right", comment: "Live Input table row label — right touch ring on dual-ring tablets")) {
                        HStack(spacing: 6) {
                            Image(
                                systemName: lb.touchRing2Active
                                    ? "checkmark.circle.fill" : "circle"
                            )
                            .foregroundStyle(lb.touchRing2Active ? Color.green : Color.secondary)
                            .imageScale(.small)
                            Text(verbatim: lb.touchRing2Active
                                ? String(localized: "Active", comment: "Touch ring active state in Live Input")
                                : String(localized: "Idle", comment: "Touch ring idle state in Live Input"))
                                .foregroundStyle(lb.touchRing2Active ? .primary : .tertiary)
                        }
                    }
                }
            }
            // The enclosing grouped-form section supplies the card chrome.
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minWidth: 380)
        }
    }

    /// Round to the nearest multiple of `step` (coordinates are non-negative).
    private func quantize(_ value: Int, to step: Int) -> Int {
        ((value + step / 2) / step) * step
    }

    @ViewBuilder
    private func stylusRow(label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .scaledFrame(minWidth: 90, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            Text(value)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func liveRow(
        label: String,
        @ViewBuilder value: () -> some View
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .scaledFrame(minWidth: 90, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            value()
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .appFont(.settingsBadge)
            .padding(.horizontal, 4)
            .background(Color.accentColor.opacity(0.2))
            .cornerRadius(3)
    }
}
