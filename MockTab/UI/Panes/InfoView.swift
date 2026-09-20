// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import IOKit.hid
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
    /// Gates *reading* the tablet at all; denial also surfaces as "HID
    /// Manager: failed to open" elsewhere, but this row names the actual
    /// cause and carries the fix.
    @State private var inputMonitoringGranted =
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    @State private var launchAtLogin = false
    @State private var diagnosticsExpanded = false
    @State private var diagnosticSnapshot = ""
    @State private var diagnosticSnapshotAt = Date()
    @State private var conflicts: [ConflictFinding] = []
    @State private var showCaptureGuide = false
    @State private var rawCaptureRunning = false
    @State private var rawCaptureReportCount = 0
    @State private var rawCaptureSavedURL: URL?
    /// Polls `HIDCapture.shared.reportCount` while running — no publisher on
    /// the capture buffer, and a per-report UI update would be wasteful.
    @State private var rawCaptureCountTimer: Timer?
    /// Reveals the raw+decoded capture tool in place of "Collect Device
    /// Data…" while Option is held — same convention as `AppOverrideBar`'s
    /// Reset/Remove All swap. Live-tracked for the label; the action itself
    /// re-reads `NSEvent.modifierFlags` at click time in case Option was
    /// released since the last render.
    @State private var optionKeyDown = false
    @State private var optionKeyMonitor: Any?
    /// Refreshes the diagnostic snapshot on mouse-up; active only while the
    /// panel is expanded — see `.onChange(of: diagnosticsExpanded)` below.
    @State private var mouseUpMonitor: Any?
    /// True between a mouse/pen-down that started inside the diagnostics
    /// text and its matching mouse-up. Guards refreshes during the drag.
    @State private var selectionGestureActive = false
    /// Where `selectionGestureActive` began, for telling a real
    /// drag-selection from a bare click on mouse-up.
    @State private var selectionGestureStart: CGPoint = .zero
    /// True once a real drag-selection has completed, and stays true after
    /// the gesture ends (unlike `selectionGestureActive`) so a later
    /// automatic refresh trigger doesn't wipe out a selection the user is
    /// still looking at. Cleared only by an actual refresh.
    @State private var textHasSelection = false
    /// Per-window, not a shared singleton — two tablet windows collecting
    /// data must not see each other's state.
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
        .onAppear {
            refresh()
            // HIDCapture.shared keeps recording/flushing across tab
            // switches; only this view's poll timer stops on disappear —
            // resume it here, or catch up on an auto-stop that happened
            // while this view wasn't around to notice.
            if rawCaptureRunning {
                if !HIDCapture.shared.isCapturing {
                    finishRawCaptureTeardown()
                } else if rawCaptureCountTimer == nil {
                    startRawCapturePollTimer()
                }
            }
            optionKeyDown = NSEvent.modifierFlags.contains(.option)
            if optionKeyMonitor == nil {
                optionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    optionKeyDown = event.modifierFlags.contains(.option)
                    return event
                }
            }
        }
        .onDisappear {
            rawCaptureCountTimer?.invalidate()
            rawCaptureCountTimer = nil
            if let optionKeyMonitor { NSEvent.removeMonitor(optionKeyMonitor) }
            optionKeyMonitor = nil
            optionKeyDown = false
        }
        // Escape/Cmd-. end a raw capture session, same as clicking Stop.
        // `.onExitCommand` alone doesn't reliably fire here — SettingsPane's
        // List/Form claims the key view loop for row navigation — so these
        // route through AppKit's command dispatch instead via
        // `.keyboardShortcut`, which works regardless of first responder.
        // Only present in the hierarchy while a capture is running, so
        // neither shortcut is claimed the rest of the time.
        .background {
            if rawCaptureRunning {
                Button("", action: stopRawCapture)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                Button("", action: stopRawCapture)
                    .keyboardShortcut(".", modifiers: .command)
                    .buttonStyle(.plain)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
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

            // Labeled with System Settings' own names. Granted rows keep a
            // button rather than going bare: revoking is the user's to do,
            // so the one thing we can offer is the trip there —
            // "Open System Settings" is Apple's own wording (SystemPolicy.framework).
            row(
                String(localized: "Input Monitoring", comment: "Row label in Info tab status table — Input Monitoring permission"),
                value: inputMonitoringGranted
                    ? String(localized: "Granted", comment: "Permission status value")
                    : String(localized: "Not granted", comment: "Permission status value"),
                ok: inputMonitoringGranted,
                action: inputMonitoringGranted
                    ? { openSettingsPane(Self.inputMonitoringAnchor) }
                    : requestInputMonitoring,
                actionLabel: inputMonitoringGranted
                    ? String(localized: "Open System Settings", comment: "Button on a granted permission row, opens the matching Privacy & Security pane")
                    : String(localized: "Grant…", comment: "Button that requests a system permission from the Info tab"),
                actionHelp: inputMonitoringGranted
                    ? String(localized: "Review or turn off MockTab's permission to read your tablet.", comment: "Tooltip on Open System Settings button for a granted permission")
                    : String(localized: "Allow MockTab to read your tablet. Without this, the tablet is detected but sends nothing.", comment: "Tooltip on Grant button for Input Monitoring permission")
            )

            row(
                String(localized: "Accessibility", comment: "Row label in Info tab status table — Accessibility permission"),
                value: accessibilityGranted
                    ? String(localized: "Granted", comment: "Permission status value")
                    : String(localized: "Not granted", comment: "Permission status value"),
                ok: accessibilityGranted,
                action: accessibilityGranted
                    ? { openSettingsPane(Self.accessibilityAnchor) }
                    : requestAccessibility,
                actionLabel: accessibilityGranted
                    ? String(localized: "Open System Settings", comment: "Button on a granted permission row, opens the matching Privacy & Security pane")
                    : String(localized: "Grant…", comment: "Button that requests a system permission from the Info tab"),
                actionHelp: accessibilityGranted
                    ? String(localized: "Review or turn off MockTab's permission to move the pointer and press keys.", comment: "Tooltip on Open System Settings button for a granted permission")
                    : String(localized: "Allow MockTab to move the pointer and press keys. Without this, the pen is read but moves nothing.", comment: "Tooltip on Grant button for Accessibility permission")
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
                // Not a fault — label the action for what it does, not "Fix".
                action: launchAtLogin ? disableLaunchAtLogin : enableLaunchAtLogin,
                actionLabel: launchAtLogin
                    ? String(localized: "Disable", comment: "Button that turns off Launch at Login from the Info tab")
                    : String(localized: "Enable", comment: "Button that turns on Launch at Login from the Info tab"),
                actionHelp: launchAtLogin
                    ? String(localized: "Stop MockTab from starting automatically when you log in.", comment: "Tooltip on Disable button for Launch at Login")
                    : String(localized: "Enable MockTab to start automatically when you log in.", comment: "Tooltip on Enable button for Launch at Login"))

            row(
                String(localized: "Conflicts", comment: "Row label in Info tab status table"),
                value: conflicts.isEmpty
                    ? String(localized: "None detected", comment: "Conflicts status value — no conflicts")
                    : String(localized: "\(conflicts.count) detected", comment: "Conflicts status value when conflicts are found, showing count"),
                ok: conflicts.isEmpty ? true : false,
                action: conflicts.isEmpty ? nil : showConflictAlert,
                // Ellipsis: opens an alert rather than fixing anything directly.
                actionLabel: String(localized: "Fix…", comment: "Button on the Conflicts row that opens an alert describing the detected conflicts"),
                actionHelp: String(localized: "Show details about detected conflicts with other tablet drivers and how to resolve them.", comment: "Tooltip on Fix button for Conflicts row")
            )
        }
    }

    /// One status row, optionally carrying a trailing action button.
    ///
    /// "Actionable" isn't the same as "faulty" — a granted permission still
    /// gets a route to System Settings. Rows with nothing to do pass no
    /// action, which is what makes the button's presence meaningful.
    ///
    /// Trailing ellipsis only when the action needs more from the user
    /// before completing (a prompt, alert, sheet). "Enable"/"Disable" act at
    /// once; "Grant…"/"Fix…" don't.
    @ViewBuilder
    private func row(
        _ label: String, value: String,
        ok: Bool?,
        leadingSymbol: String? = nil,
        symbolColor: Color? = nil,
        action: (() -> Void)? = nil,
        actionLabel: String? = nil,
        actionHelp: String? = nil
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .scaledFrame(minWidth: 150, alignment: .trailing)
                .gridColumnAlignment(.trailing)

            // Sized to content — flexible space sits after the button
            // column so values and buttons stay together.
            HStack(spacing: 8) {
                if let sym = leadingSymbol {
                    Image(systemName: sym)
                        .foregroundStyle(symbolColor ?? .primary)
                        .accessibilityHidden(true)
                } else {
                    statusIcon(ok)
                }
                Text(value)
            }
            .gridColumnAlignment(.leading)

            // Own grid column so buttons share one left edge down the table;
            // rows without an action still occupy the cell to keep the
            // column from collapsing (mirrors DevicesView's rename button).
            HStack(spacing: 0) {
                // actionLabel required alongside action — no generic fallback,
                // since that could silently pick the wrong ellipsis convention.
                if let action, let actionLabel {
                    Button(actionLabel, action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(actionHelp ?? "")
                        // Sized to its own label — equal widths would stretch
                        // "Enable" to "Open System Settings"'s width.
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .gridColumnAlignment(.leading)
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

    /// One button, two tools — hold Option for the advanced one. Default is
    /// "Collect Device Data…" (`CaptureGuideView`/`DiscoveryAccumulator`), a
    /// statistical summary for first-contact triage. Option swaps in
    /// `HIDCapture`'s raw+decoded recorder for checking a known decoder
    /// against real hardware.
    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if rawCaptureRunning {
                    // Controls stay put regardless of Option once running —
                    // only *starting* a capture is Option-gated.
                    Button(String(localized: "Stop Capture", comment: "Button label: stop raw HID capture")) {
                        stopRawCapture()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                        Text(String(localized: "\(rawCaptureReportCount) reports", comment: "Live report count while raw capture is running"))
                            .appFont(.settingsLabel)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else if optionKeyDown {
                    Button(String(localized: "Record Raw Data…", comment: "Button label: start raw HID capture with decoded annotations (Option-revealed)")) {
                        startRawCapture()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(String(localized: "Every report, raw bytes plus decoded values, categorized by report ID and condensed to steady-state ranges. For checking a known decoder against real hardware.", comment: "Help text for the Record Raw Data button"))
                } else {
                    Button(String(localized: "Collect Device Data…", comment: "Button label: start device data collection")) {
                        showCaptureGuide = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(String(localized: "Records what your tablet sends to the Mac and saves it as a small JSON file you can share.", comment: "Help text for the Collect Device Data button"))
                }
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
                optionKeyDown || rawCaptureRunning
                    ? String(localized: "Record everything the tablet sends. Creates large files for detailed analysis.", comment: "Description below the Record Raw Data button")
                    : String(localized: "Collect tablet details for support. May take a few minutes. Hold ⌥ for raw capture.", comment: "Description below the Collect Device Data button")
            )
            .appFont(.settingsLabel)
            .foregroundStyle(.tertiary)
        }
    }

    private func startRawCapture() {
        // Re-read at click time — Option may have been released since the
        // last render (see AppOverrideBar for the same guard).
        guard NSEvent.modifierFlags.contains(.option) else { return }
        HIDCapture.shared.start()
        rawCaptureReportCount = 0
        rawCaptureSavedURL = nil
        rawCaptureRunning = true
        startRawCapturePollTimer()
    }

    private func startRawCapturePollTimer() {
        rawCaptureCountTimer?.invalidate()
        rawCaptureCountTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            rawCaptureReportCount = HIDCapture.shared.reportCount
            // Flushing/auto-stop are owned by HIDCapture's own background
            // timer, not this poll — this only needs to notice when
            // isCapturing flips false on its own (the ceiling fired) and
            // finish the UI-side teardown.
            if rawCaptureRunning, !HIDCapture.shared.isCapturing {
                finishRawCaptureTeardown()
            }
        }
    }

    private func stopRawCapture() {
        HIDCapture.shared.stop()
        finishRawCaptureTeardown()
    }

    /// Shared by manual Stop, Escape/Cmd-., and a detected auto-stop —
    /// flushes what's left, updates the UI, stops polling.
    private func finishRawCaptureTeardown() {
        rawCaptureCountTimer?.invalidate()
        rawCaptureCountTimer = nil
        rawCaptureReportCount = HIDCapture.shared.reportCount
        rawCaptureRunning = false
        rawCaptureSavedURL = HIDCapture.shared.finish()
    }

    // MARK: - Diagnostic section

    private var diagnosticSection: some View {
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
    private static func isInsideDiagnosticText(_ event: NSEvent) -> Bool {
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
    /// Deliberately not a live-reading computed property — an earlier
    /// version re-rendered on any incidental InfoView redraw, discarding an
    /// in-progress text selection. Called explicitly and cached.
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
        lines += [String(localized: "Input Monitor  : \(inputMonitoringGranted ? String(localized: "granted", comment: "Permission status") : String(localized: "not granted", comment: "Permission status"))", comment: "Diagnostic: Input Monitoring permission")]
        lines += [String(localized: "Accessibility  : \(accessibilityGranted ? String(localized: "granted", comment: "Permission status") : String(localized: "not granted", comment: "Permission status"))", comment: "Diagnostic: Accessibility permission")]
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

        // Memory counterpart to the latency lines above.
        if let footprint = FootprintProbe.read() {
            let current = FootprintProbe.megabytes(footprint.current)
            let peak = FootprintProbe.megabytes(footprint.peak)
            lines += [String(localized: "Memory         : \(current) MB now, \(peak) MB peak", comment: "Diagnostic: process memory footprint, current and lifetime peak, in megabytes")]
        }

        if let fallback = fallbackDevice {
            lines += [""]
            lines += ["─── HID Report Descriptor (fallback driver) ───"]
            lines += [LiveHIDDescriptorInspector.summarize(fallback.parsedDescriptor)]
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
        refreshPermissions()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        conflicts = detectConflicts()
        refreshDiagnosticSnapshot()
    }

    /// Split out so a grant made in System Settings is picked up on app
    /// reactivation without rebuilding the whole snapshot.
    ///
    /// Re-opens the HID manager when Input Monitoring is now granted — a
    /// grant that arrives after launch leaves the manager closed from its
    /// failed open, so without this the row would read Granted while the
    /// tablet stayed dead.
    private func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted =
            IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if inputMonitoringGranted {
            tabletManager.reopenIfClosed()
        }
    }

    /// Single choke point for updating `diagnosticSnapshot`, so every
    /// trigger also stamps `diagnosticSnapshotAt`.
    private func refreshDiagnosticSnapshot() {
        diagnosticSnapshot = buildDiagnosticText()
        diagnosticSnapshotAt = Date()
        textHasSelection = false
    }

    /// Ask for Accessibility: the system alert when it can still appear,
    /// System Settings when it can't (the alert only shows on an app's
    /// first ask, silent forever after — its own button already covers the
    /// Settings route, so calling both would stack redundant windows).
    private func requestAccessibility() {
        if tabletManager.promptForAccessibilityIfNeeded() { return }
        openSettingsPane(Self.accessibilityAnchor)
    }

    /// Ask for Input Monitoring — unlike Accessibility this genuinely
    /// prompts in place, so Settings is a fallback for a denied request
    /// (covers both a fresh refusal and a prior denial, where the prompt no
    /// longer appears). `IOHIDRequestAccess` blocks until answered, so its
    /// return value is authoritative.
    private func requestInputMonitoring() {
        let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        refreshPermissions()
        if !granted {
            openSettingsPane(Self.inputMonitoringAnchor)
        }
    }

    // Privacy & Security pane anchors, verified against the strings in
    // macOS 27's SecurityPrivacyExtension. Note macOS 27 retitles the
    // Accessibility pane to "Device Control and Data Access" — the anchor
    // name is unchanged, so the link still lands correctly.
    private static let inputMonitoringAnchor = "Privacy_ListenEvent"
    private static let accessibilityAnchor = "Privacy_Accessibility"

    private func openSettingsPane(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        else { return }
        NSWorkspace.shared.open(url)
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
            openLoginItemsPane()
        }
    }

    /// Turn off launch-at-login, falling back to Login Items if the system
    /// refuses. Worth a real action, not just a link — we register this
    /// from one click in the same table, so it's the one item here a user
    /// can enable by accident and needs an easy way back from.
    private func disableLaunchAtLogin() {
        do {
            try SMAppService.mainApp.unregister()
            refresh()
        } catch {
            openLoginItemsPane()
        }
    }

    private func openLoginItemsPane() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        )
    }
}

// MARK: - LiveInputSectionContent
//
// Owns the livePointTick polling dependency itself rather than InfoView
// hosting it. `livePoint` publishes on every HID report; scoping the tick
// to just this subtree keeps the rest of InfoView (including the
// diagnostics text, whose in-progress selection a stylus report would
// otherwise blow away on every redraw) stable while the pen moves.
private struct LiveInputSectionContent: View {
    let deviceContext: DeviceContext?
    let productID: Int?

    /// For a wireless-dongle-bound window, the dongle's own PID carries no
    /// capability data — the paired tablet's does.
    private var effectiveProductID: Int? {
        if let paired = deviceContext?.pairedProductID, paired != 0 { return paired }
        return productID
    }

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
            hasDualRings: WacomDeviceRegistry.spec(for: effectiveProductID ?? 0)?.hasDualRings == true,
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

    /// Total signed rotation since the gauge last reset, not clamped to
    /// 0-360 — each new raw angle adds the shortest signed delta from the
    /// previous one, so a wrap (358° -> 2°) contributes +4° instead of
    /// snapping the hand back ~356° (confirmed against a ~9-revolution
    /// capture, ptk-870-usb-funky-art-pen-rotation.txt).
    @State private var accumAngle: Double = 0
    @State private var lastRawAngle: Double?

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
            guard let d = newDeg else {
                accumAngle = 0
                lastRawAngle = nil
                return
            }
            guard let prev = lastRawAngle else {
                accumAngle = d
                lastRawAngle = d
                return
            }
            var delta = (d - prev).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            accumAngle += delta
            lastRawAngle = d
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
