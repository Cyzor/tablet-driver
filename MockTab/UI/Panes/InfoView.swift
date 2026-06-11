// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ServiceManagement
import SwiftUI
import TabletKit

/// Status dashboard tab — shows live device state, system permissions,
/// and a collapsible diagnostic dump for technical analysis.
struct InfoView: View {
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var settings: TabletSettings
    var productID: Int?

    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var launchAtLogin = false
    @State private var diagnosticsExpanded = false
    @State private var conflicts: [String] = []
    @State private var showCaptureGuide = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if fallbackDevice != nil {
                        unknownDeviceBanner
                    }
                    statusTable
                    Divider()
                    LiveInputView(
                        livePoint: tabletManager.contexts[productID ?? 0]?.livePoint,
                        liveButtons: tabletManager.contexts[productID ?? 0]?.liveButtons
                            ?? LiveButtonState(),
                        activeToolID: tabletManager.contexts[productID ?? 0]?.activeToolID,
                        registry: DeviceRegistry.shared,
                        hasDualRings: WacomDeviceRegistry.spec(for: productID ?? 0)?.hasDualRings
                            == true
                    )
                    Divider()
                    captureSection
                    Divider()
                    diagnosticSection
                }
                .padding()
            }
            .onAppear { refresh() }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)
            ) { _ in refresh() }
            DeviceStatusBar(
                settings: settings, tabletManager: tabletManager, registry: DeviceRegistry.shared,
                productID: productID ?? 0
            )
            .sheet(isPresented: $showCaptureGuide) {
                CaptureGuideView(
                    engine: CaptureEngine.shared,
                    tabletManager: tabletManager,
                    productID: productID ?? 0,
                    onDismiss: { showCaptureGuide = false }
                )
            }
        }
    }

    // MARK: - Status table

    private var deviceContext: DeviceContext? {
        tabletManager.contexts[productID ?? 0]
    }

    private var fallbackDevice: WacomFallbackDevice? {
        deviceContext?.tabletDevice as? WacomFallbackDevice
    }

    private var unknownDeviceBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.orange)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Unrecognised tablet", comment: "Banner title shown when active device is on the generic fallback driver"))
                    .appFont(.headline)
                Text(String(localized: "MockTab is using its generic driver for this device. Basic pen input may work, but full support requires a short data-collection session.", comment: "Body of the unknown-device banner"))
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
                value: deviceContext?.isConnected ?? false
                    ? TabletManager.deviceName(forProductID: productID ?? 0)
                    : String(localized: "Not connected", comment: "Device connection status value"),
                ok: deviceContext?.isConnected ?? false)

            row(
                String(localized: "Connection", comment: "Row label in Info tab status table"),
                value: deviceContext?.transport ?? "—",
                ok: deviceContext?.isConnected ?? false ? true : nil)

            if let pct = deviceContext?.batteryPercent {
                row(
                    String(localized: "Battery", comment: "Row label in Info tab status table"),
                    value: (deviceContext?.batteryCharging ?? false)
                        ? "\(pct)%  \(String(localized: "(Charging)", comment: "Suffix when device is charging, e.g. '85%  (Charging)'"))"
                        : "\(pct)%",
                    ok: pct < 20 ? false : nil,
                    leadingSymbol: batterySymbolName(
                        pct: pct,
                        charging: deviceContext?.batteryCharging ?? false),
                    symbolColor: batteryColor(
                        pct: pct,
                        charging: deviceContext?.batteryCharging ?? false))
            }

            row(
                String(localized: "Speed", comment: "Row label in Info tab status table — USB speed"),
                value: deviceContext?.usbSpeed ?? "—",
                ok: deviceContext?.isConnected ?? false ? true : nil)

            row(
                String(localized: "Status", comment: "Row label in Info tab status table — driver status"),
                value: (deviceContext?.isConnected ?? false)
                    ? String(localized: "Active", comment: "Driver status value — device is active")
                    : String(localized: "Idle", comment: "Driver status value — device is idle"),
                ok: (deviceContext?.isConnected ?? false) ? true : nil)

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
                fixHelp: String(localized: "Enable MockTab to start automatically when you log in.", comment: "Tooltip on Fix button for Launch at Login"))

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
        fixHelp: String? = nil
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 150, alignment: .trailing)
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
                    Button(LocalizedStringKey("Fix"), action: fix)
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
                .accessibilityLabel(LocalizedStringKey("OK"))
        } else if ok == false {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.primary)
                .accessibilityLabel(LocalizedStringKey("Failed"))
        } else {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.tertiary)
                .accessibilityLabel(LocalizedStringKey("Unknown"))
        }
    }

    // MARK: - Battery icon helpers

    private func batterySymbolName(pct: Int, charging: Bool) -> String {
        guard !charging else { return "battery.100percent.bolt" }
        switch pct {
        case 0..<13: return "battery.0percent"
        case 13..<38: return "battery.25percent"
        case 38..<63: return "battery.50percent"
        case 63..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func batteryColor(pct: Int, charging: Bool) -> Color {
        if charging { return .green }
        if pct < 20 { return .red }
        if pct < 50 { return .orange }
        return .green
    }

    // MARK: - HID capture section

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Diagnostics", comment: "Section header: device diagnostics and data collection"))
                .appFont(.headline)

            HStack(spacing: 12) {
                Button(String(localized: "Collect Device Data…", comment: "Button label: start device data collection")) {
                    showCaptureGuide = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(String(localized: "Guides you through a short set of actions to capture how your device communicates. Produces a small JSON file you can share to add or fix device support.", comment: "Help text for the Collect Device Data button"))
                Spacer()
            }

            Text(String(localized: "Use this if your device is unrecognised or a feature isn't working as expected. The collection takes about one minute.", comment: "Description below the Collect Device Data button"))
                .appFont(.settingsLabel)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Diagnostic section

    private var diagnosticSection: some View {
        DisclosureRow(label: String(localized: "Diagnostic Detail", comment: "Collapsible section header for detailed diagnostic information"), isExpanded: $diagnosticsExpanded) {
            Text(diagnosticText)
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

    private var diagnosticText: String {
        var lines: [String] = []

        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .medium
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
            lines += [String(localized: "Transport : \(tabletManager.connectedTransport)", comment: "Diagnostic: USB/Bluetooth transport type")]
            lines += [String(localized: "Speed     : \(tabletManager.connectedUSBSpeed)", comment: "Diagnostic: USB speed or Bluetooth version")]
            if let pct = tabletManager.batteryPercent {
                let chgStr = tabletManager.batteryCharging ? String(localized: " (charging)", comment: "Battery status indicator") : ""
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
                lines += ["  ⚠ \(conflict)"]
            }
        }

        if let ctx = tabletManager.activeContext {
            let jitter = String(format: "%.2f", ctx.injector.jitterLevel)
            let highLabel = ctx.injector.isJittery ? String(localized: " (HIGH)", comment: "Jitter level warning") : ""
            lines += [String(localized: "Jitter level   : \(jitter) pt/sample\(highLabel)", comment: "Diagnostic: input jitter measurement")]
        }

        let probe = LatencyProbe.shared
        if probe.reportCount > 0 {
            let avg = String(format: "%.2f", probe.averageMs)
            let worst = String(format: "%.1f", probe.worstMs)
            lines += [String(localized: "HID latency    : \(avg) ms avg, \(worst) ms worst, \(probe.stallCount) stalls >\(Int(LatencyProbe.stallThresholdMs)) ms", comment: "Diagnostic: HID report delivery latency from kernel receipt to driver callback")]
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
    }

    private func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
    }

    // MARK: - Conflict detection

    private static let competingProcesses: [(name: String, label: String)] = [
        ("WacomTabletDriver", "Wacom Tablet Driver"),
        ("TabletDriver", "Wacom TabletDriver"),
        ("Wacom_IOManager", "Wacom I/O Manager"),
        ("WacomTabletSpringboard", "Wacom Springboard"),
        ("DataStoreMgr", "Wacom DataStore Manager"),
        ("OpenTabletDriver.Daemon", "OpenTabletDriver Daemon"),
        ("OpenTabletDriver.UX", "OpenTabletDriver UX"),
        ("OpenTabletDriver", "OpenTabletDriver (GUI)"),
    ]

    private func detectConflicts() -> [String] {
        var found: [String] = []

        let running = NSWorkspace.shared.runningApplications
        var liveNames = Set(running.compactMap { $0.localizedName })
        liveNames.formUnion(running.compactMap { $0.bundleIdentifier })

        var claimedNames = Set<String>()
        for (name, label) in Self.competingProcesses {
            let matchingLive = liveNames.filter {
                ($0 == name || name.hasPrefix($0) || $0.hasPrefix(name))
                    && !claimedNames.contains($0)
            }
            if !matchingLive.isEmpty {
                claimedNames.formUnion(matchingLive)
                found.append(String(localized: "Conflicting driver: \(label)", comment: "Conflict detection: named process is running"))
            }
        }

        if let ctx = tabletManager.activeContext, ctx.injector.isJittery {
            let level = String(format: "%.1f", ctx.injector.jitterLevel)
            found.append(String(localized: "RF interference: \(level) pt/sample", comment: "Conflict detection: RF interference jitter"))
        }

        return found
    }

    private func showConflictAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Potential Conflicts Detected", comment: "Alert title when user taps Fix on the Conflicts row")

        let intro = String(localized: "MockTab found the following issues that may interfere with tablet operation:", comment: "First sentence of conflict alert body")
        var body = "\(intro)\n\n"
        for (i, conflict) in conflicts.enumerated() {
            body += "  \(i + 1). \(conflict)\n"
        }
        let recommendation = String(localized: "Recommendation: Quit or disable the listed processes, then restart MockTab. For Wacom drivers, check System Settings → General → Login Items to prevent them from launching at startup. For RF jitter, try moving wireless receivers (mice, keyboards, Wi-Fi dongles) away from the tablet.", comment: "Recommendation paragraph at the end of the conflict alert body")
        body += "\n\(recommendation)"

        alert.informativeText = body
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
            Text(String(localized: "Live Input", comment: "Section header: live input state and pen position"))
                .appFont(.headline)

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
                    .gridCellColumns(3)
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
                            Text(LocalizedStringKey("None")).foregroundStyle(.tertiary).appFont(.settingsBadge)
                        }
                    }
                }

                liveRow(label: String(localized: "Pressure", comment: "Live Input table row label")) {
                    HStack {
                        Text(point != nil ? "\(point!.pressure)" : "0")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)

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

                liveRow(label: String(localized: "Coordinate", comment: "Live Input table row label — raw X/Y position")) {
                    Text(
                        point != nil
                            ? "X: \(point!.x)   Y: \(point!.y)"
                            : String(localized: "X: 0   Y: 0", comment: "Default coordinate display when no pen is detected")
                    )
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                liveRow(label: String(localized: "Tilt", comment: "Live Input table row label — pen tilt X/Y")) {
                    Text(
                        point != nil
                            ? "X: \(String(format: "%+.2f", point!.tiltX))   Y: \(String(format: "%+.2f", point!.tiltY))"
                            : String(localized: "X: +0.00   Y: +0.00", comment: "Default tilt display when no pen is detected")
                    )
                    .monospacedDigit()
                }

                liveRow(label: String(localized: "Hover", comment: "Live Input table row label — hover distance")) {
                    if let p = point {
                        Text("\(p.hoverDistance)   \(p.inProximity ? String(localized: "(In Range)", comment: "Hover proximity state") : String(localized: "(Out)", comment: "Hover proximity state — out of range"))")
                            .monospacedDigit()
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
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minWidth: 380)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func stylusRow(label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 90, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            Text(value)
                .monospacedDigit()
                .gridCellColumns(2)
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
                .frame(minWidth: 90, alignment: .trailing)
                .gridColumnAlignment(.trailing)
            value()
                .monospacedDigit()
                .gridCellColumns(2)
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
