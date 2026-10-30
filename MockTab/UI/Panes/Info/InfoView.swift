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
    var productID: Int? { instanceKey?.productID }

    // Permissions start false; `refresh()` in `onAppear` sets them before the
    // first frame. Calling the checks here repeated them on every rebuild.
    @State var accessibilityGranted = false
    /// Gates *reading* the tablet at all; denial also surfaces as "HID
    /// Manager: failed to open" elsewhere, but this row names the actual
    /// cause and carries the fix.
    @State var inputMonitoringGranted = false
    @State var launchAtLogin = InfoView.knownLaunchAtLogin
    /// Follows the status menu's Show in Dock toggle too.
    @AppStorage(DockIcon.defaultsKey) var showsDockIcon = true
    @State var diagnosticsExpanded = false
    @State var diagnosticSnapshot = ""
    @State private var diagnosticSnapshotAt = Date()
    @State var conflicts: [ConflictFinding] = []
    @State var showCaptureGuide = false
    @State var rawCaptureRunning = false
    /// True when a *different* window's session holds the process-wide raw
    /// capture. Shown as a disabled button rather than a silent no-op: the
    /// singleton can only serve one session, and a button that appears to do
    /// nothing is worse than one that says why.
    @State var rawCaptureHeldElsewhere = false
    @State var rawCaptureReportCount = 0
    @State var rawCaptureSavedURL: URL?
    /// Polls `HIDCapture.shared.reportCount` while running — no publisher on
    /// the capture buffer, and a per-report UI update would be wasteful.
    @State var rawCaptureCountTimer: Timer?
    /// Refreshes the diagnostic snapshot on mouse-up; active only while the
    /// panel is expanded — see `.onChange(of: diagnosticsExpanded)` below.
    @State var mouseUpMonitor: Any?
    /// True between a mouse/pen-down that started inside the diagnostics
    /// text and its matching mouse-up. Guards refreshes during the drag.
    @State var selectionGestureActive = false
    /// Where `selectionGestureActive` began, for telling a real
    /// drag-selection from a bare click on mouse-up.
    @State var selectionGestureStart: CGPoint = .zero
    /// True once a real drag-selection has completed, and stays true after
    /// the gesture ends (unlike `selectionGestureActive`) so a later
    /// automatic refresh trigger doesn't wipe out a selection the user is
    /// still looking at. Cleared only by an actual refresh.
    @State var textHasSelection = false
    /// Per-window, not a shared singleton — two tablet windows collecting
    /// data must not see each other's state.
    @StateObject private var captureEngine = CaptureEngine()
    /// Owns this window's claim on the process-wide raw-capture buffer, so
    /// both collectors start and stop as one run. Per-window for the same
    /// reason `captureEngine` is.
    @State var diagnosticSession = DiagnosticSession()
    @ObservedObject var collectionRequest = DeviceDataCollectionRequest.shared

    var body: some View {
        let _ = BodyCounter.note("Info")
        SettingsPane(
            settings: settings, tabletManager: tabletManager, registry: DeviceRegistry.shared,
            instanceKey: instanceKey
        ) {
            if let unrecognizedDriver {
                Section {
                    Group {
                        if unrecognizedDriver.isWacomAndroidMode {
                            androidModeBanner
                        } else {
                            unknownDeviceBanner
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            Section {
                statusTable
                    .keepsWindowWideEnough()
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
            // A capture only runs while the guide sheet is up, but this view
            // can still disappear under it (tab switch), stopping the poll
            // timer. Resume it, or catch up on the auto-stop if
            // that fired while we weren't watching.
            if rawCaptureRunning {
                if !HIDCapture.shared.isCapturing {
                    finishRawCaptureTeardown()
                } else if rawCaptureCountTimer == nil {
                    startRawCapturePollTimer()
                }
            }
            rawCaptureHeldElsewhere = DiagnosticSession.rawCaptureHeldByOther(than: diagnosticSession)
            handleCollectionRequest()
        }
        .onReceive(collectionRequest.$target) { _ in DispatchQueue.main.async { handleCollectionRequest() } }
        .onDisappear {
            rawCaptureCountTimer?.invalidate()
            rawCaptureCountTimer = nil
        }
        // No Escape handler here: the capture sheet owns Escape while it's up.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in refresh() }
        .sheet(isPresented: $showCaptureGuide) {
            CaptureGuideView(
                engine: captureEngine,
                tabletManager: tabletManager,
                productID: productID ?? 0,
                onDismiss: {
                    showCaptureGuide = false
                    // Still running here means `onFinalizeRawCapture` never
                    // ran — the user cancelled. Discard rather than finalize:
                    // no package is built around it, so saving would leave a
                    // partial recording behind that looks like a real one.
                    if rawCaptureRunning { discardRawCapture() }
                    rawCaptureHeldElsewhere = DiagnosticSession.rawCaptureHeldByOther(
                        than: diagnosticSession)
                },
                onFinalizeRawCapture: {
                    // The raw log starts first, so it reaches the shared
                    // time limit a moment before the session does. It's
                    // saved by then; package that file.
                    if rawCaptureRunning { finishRawCaptureTeardown() }
                    return rawCaptureSavedURL
                }
            )
            // Backstop, not the primary path: the raw capture starts before
            // the sheet is presented, so a dismissal route that skips
            // `onDismiss` — a startup error, Escape, or a future third exit
            // — would otherwise leave it recording with no UI to stop it.
            // Tied to the sheet's own disappearance, which every route
            // reaches. Idempotent via `ownsRawCapture`.
            .onDisappear {
                // Same reasoning as `onDismiss`: reaching here still running
                // means no package was built, so the recording is incomplete.
                if rawCaptureRunning { discardRawCapture() }
                rawCaptureHeldElsewhere = DiagnosticSession.rawCaptureHeldByOther(
                    than: diagnosticSession)
            }
        }
    }

    // MARK: - Actions

    private func refresh() {
        refreshPermissions()
        launchAtLogin = Self.knownLaunchAtLogin
        if let names = Self.knownRunningAppNames { conflicts = detectConflicts(liveNames: names) }
        refreshDiagnosticSnapshot()
        // Both queries are round trips to system services, about 60 ms
        // together, so they run off the main thread.
        Task {
            async let login = Self.readLaunchAtLogin()
            async let names = Task.detached { Self.runningAppNames() }.value
            let (enabled, liveNames) = await (login, names)
            Self.knownRunningAppNames = liveNames
            launchAtLogin = enabled
            conflicts = detectConflicts(liveNames: liveNames)
            refreshDiagnosticSnapshot()
        }
    }

    /// Last login-item state read, so a new window shows it without waiting.
    static var knownLaunchAtLogin = false

    static func readLaunchAtLogin() async -> Bool {
        let enabled = await Task.detached { SMAppService.mainApp.status == .enabled }.value
        knownLaunchAtLogin = enabled
        return enabled
    }

    /// Running apps at the last check, so a new window lists conflicts at once.
    static var knownRunningAppNames: Set<String>?

    /// Reads the login-item state and running apps at launch, before any
    /// window asks for them.
    static func prewarmSystemQueries() {
        Task { _ = await readLaunchAtLogin() }
        Task { knownRunningAppNames = await Task.detached { runningAppNames() }.value }
    }

    nonisolated private static func runningAppNames() -> Set<String> {
        let running = NSWorkspace.shared.runningApplications
        var names = Set(running.compactMap { $0.localizedName })
        names.formUnion(running.compactMap { $0.bundleIdentifier })
        return names
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
    func refreshDiagnosticSnapshot() {
        diagnosticSnapshot = buildDiagnosticText()
        diagnosticSnapshotAt = Date()
        textHasSelection = false
    }

    /// Ask for Accessibility: the system alert when it can still appear,
    /// System Settings when it can't (the alert only shows on an app's
    /// first ask, silent forever after — its own button already covers the
    /// Settings route, so calling both would stack redundant windows).
    func requestAccessibility() {
        if tabletManager.promptForAccessibilityIfNeeded() { return }
        openSettingsPane(Self.accessibilityAnchor)
    }

    /// Ask for Input Monitoring — unlike Accessibility this genuinely
    /// prompts in place, so Settings is a fallback for a denied request
    /// (covers both a fresh refusal and a prior denial, where the prompt no
    /// longer appears). `IOHIDRequestAccess` blocks until answered, so its
    /// return value is authoritative.
    func requestInputMonitoring() {
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
    static let inputMonitoringAnchor = "Privacy_ListenEvent"
    static let accessibilityAnchor = "Privacy_Accessibility"

    func openSettingsPane(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Conflict detection

    struct ConflictFinding {
        let description: String
        let remedy: String
    }

    private func detectConflicts(liveNames: Set<String>) -> [ConflictFinding] {
        var found: [ConflictFinding] = []

        let driverRemedy = String(localized: "Quit or disable it, then restart MockTab. Check System Settings → General → Login Items to stop it launching at startup.", comment: "Remedy line for a conflicting-driver finding in the conflict alert")
        for label in ConflictProcessMatcher.matchedLabels(liveNames: liveNames) {
            found.append(ConflictFinding(
                description: String(localized: "Conflicting driver: \(label)", comment: "Conflict detection: named process is running"),
                remedy: driverRemedy))
        }

        let jitter = HIDThread.shared.performAndWait {
            [injector = tabletManager.activeContext?.injector] in
            injector.map { (isJittery: $0.isJittery, level: $0.jitterLevel) }
        }
        if let jitter, jitter.isJittery {
            let level = Double(jitter.level).formatted(.number.precision(.fractionLength(1)))
            found.append(ConflictFinding(
                description: String(localized: "RF interference: \(level) pt/sample", comment: "Conflict detection: RF interference jitter"),
                remedy: String(localized: "Move wireless receivers (mice, keyboards, Wi-Fi dongles) away from the tablet.", comment: "Remedy line for an RF-interference finding in the conflict alert")))
        }

        return found
    }

    func showConflictAlert() {
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

    func enableLaunchAtLogin() {
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
    func disableLaunchAtLogin() {
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

/// Pen-thread values the diagnostics text shows, copied on the pen thread so
/// none is read halfway through an update.
struct PenThreadReadings {
    struct Probe {
        let reportCount: UInt64
        let averageMs: Double
        let worstMs: Double
        let stallCount: UInt64
        let totalAverageMs: Double
        let totalWorstMs: Double
        let connectStallCount: UInt64
        let connectWorstMs: Double
        let gapHistogramMs: [UInt64]
    }

    /// Nil with no active tablet.
    let jitterHistogram: [UInt64]?
    let staleModifierCacheDrops: UInt64
    let probe: Probe

    init(injector: InputInjector?, probe p: LatencyProbe) {
        jitterHistogram = injector?.jitterHistogram
        staleModifierCacheDrops = injector?.staleModifierCacheDrops ?? 0
        probe = Probe(
            reportCount: p.reportCount, averageMs: p.averageMs, worstMs: p.worstMs,
            stallCount: p.stallCount, totalAverageMs: p.totalAverageMs,
            totalWorstMs: p.totalWorstMs, connectStallCount: p.connectStallCount,
            connectWorstMs: p.connectWorstMs, gapHistogramMs: p.gapHistogramMs)
    }
}
