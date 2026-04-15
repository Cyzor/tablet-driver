// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026  This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab.  If not, see <https://www.gnu.org/licenses/>.

import AppKit
import ServiceManagement
import SwiftUI

/// Status dashboard tab — shows live device state, system permissions,
/// and a collapsible diagnostic dump for technical analysis.
struct InfoView: View {
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var settings: TabletSettings
    var productID: Int?
    @StateObject private var captureEngine = CaptureEngine.shared

    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var launchAtLogin = false
    @State private var diagnosticsExpanded = false
    @State private var conflicts: [String] = []

    // HID capture
    @State private var captureActive = false
    @State private var captureCount = 0
    @State private var captureLastSaved: String? = nil
    @State private var showCaptureWizard = false
    @State private var discoverySaved: String? = nil
    @State private var discoveryInstructions: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusTable
                    Divider()
                    // LiveInputView is a separate struct so SwiftUI only
                    // re-renders the live section on livePoint/liveButtons
                    // changes — the static status table above is unaffected.
                    LiveInputView(
                        livePoint:    tabletManager.contexts[productID ?? 0]?.livePoint,
                        liveButtons:  tabletManager.contexts[productID ?? 0]?.liveButtons ?? LiveButtonState(),
                        activeToolID: tabletManager.contexts[productID ?? 0]?.activeToolID,
                        registry:     DeviceRegistry.shared,
                        hasDualRings: WacomDeviceRegistry.spec(for: productID ?? 0)?.hasDualRings == true
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
            DeviceStatusBar(settings: settings, tabletManager: tabletManager, registry: DeviceRegistry.shared, productID: productID ?? 0)
 .sheet(isPresented: $showCaptureWizard) {
 CaptureWizardView(
 engine: CaptureEngine.shared,
 tabletManager: tabletManager,
 productID: productID ?? 0,
 onDismiss: { showCaptureWizard = false }
 )
 }
        }
    }

    // MARK: - Status table
    // Re-renders only on device connect/disconnect and permission changes,
    // NOT on every pen report — livePoint/liveButtons are isolated in LiveInputView.

    private var deviceContext: DeviceContext? {
        tabletManager.contexts[productID ?? 0]
    }

    private var statusTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            row(
                "Device",
                value: deviceContext?.isConnected ?? false
                    ? TabletManager.deviceName(forProductID: productID ?? 0)
                    : "Not connected",
                ok: deviceContext?.isConnected ?? false)

            row(
                "Connection",
                value: deviceContext?.transport ?? "—",
                ok: deviceContext?.isConnected ?? false ? true : nil)

            if let pct = deviceContext?.batteryPercent {
                row(
                    "Battery",
                    value: (deviceContext?.batteryCharging ?? false)
                        ? "\(pct)%  (Charging)"
                        : "\(pct)%",
                    ok: pct < 20 ? false : nil,
                    leadingSymbol: batterySymbolName(pct: pct,
                                                    charging: deviceContext?.batteryCharging ?? false),
                    symbolColor:   batteryColor(pct: pct,
                                                charging: deviceContext?.batteryCharging ?? false))
            }

            row(
                "Speed",
                value: deviceContext?.usbSpeed ?? "—",
                ok: deviceContext?.isConnected ?? false ? true : nil)

            row(
                "Status",
                value: (deviceContext?.isConnected ?? false) ? "Active" : "Idle",
                ok: (deviceContext?.isConnected ?? false) ? true : nil)

            row(
                "Permission",
                value: accessibilityGranted ? "Granted" : "Not granted",
                ok: accessibilityGranted,
                fix: accessibilityGranted ? nil : requestAccessibility,
                fixHelp: "Open System Settings to grant MockTab permission to inject keyboard and mouse events into other apps.")

            row(
                "HID Manager",
                value: tabletManager.hidManagerOpen ? "Running" : "Failed to open",
                ok: tabletManager.hidManagerOpen ? true : false)

            row(
                "Profile",
                value: presetLabel,
                ok: nil)

            row(
                "Launch at Login",
                value: launchAtLogin ? "Enabled" : "Disabled",
                ok: launchAtLogin ? true : nil,
                fix: launchAtLogin ? nil : enableLaunchAtLogin,
                fixHelp: "Enable MockTab to start automatically when you log in.")

            row(
                "Conflicts",
                value: conflicts.isEmpty
                    ? "None detected"
                    : "\(conflicts.count) issue\(conflicts.count == 1 ? "" : "s")",
                ok: conflicts.isEmpty ? true : false,
                fix: conflicts.isEmpty ? nil : showConflictAlert,
                fixHelp: "Show details about detected conflicts with other tablet drivers and how to resolve them.")
        }
    }

    @ViewBuilder
    private func row(
        _ label: String, value: String,
        ok: Bool?,
        leadingSymbol: String? = nil,
        symbolColor:   Color?  = nil,
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
                } else {
                    statusIcon(ok)
                }
                Text(value)
                if let fix {
                    Button("Fix", action: fix)
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
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if ok == false {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.primary)
        } else {
            Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary)
        }
    }

    // MARK: - Battery icon helpers

    /// Maps a battery percentage (and charging state) to the closest SF Symbol
    /// in the battery family (battery.0percent … battery.100percent.bolt).
    private func batterySymbolName(pct: Int, charging: Bool) -> String {
        guard !charging else { return "battery.100percent.bolt" }
        switch pct {
        case 0 ..< 13:  return "battery.0percent"
        case 13 ..< 38: return "battery.25percent"
        case 38 ..< 63: return "battery.50percent"
        case 63 ..< 88: return "battery.75percent"
        default:        return "battery.100percent"
        }
    }

    /// Returns a colour that reflects battery health:
    /// red < 20 %, orange 20–49 %, green ≥ 50 % (and charging).
    private func batteryColor(pct: Int, charging: Bool) -> Color {
        if charging  { return .green }
        if pct < 20  { return .red   }
        if pct < 50  { return .orange }
        return .green
    }

    // MARK: - HID capture section

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HID Capture")
                .font(.headline)

            HStack(spacing: 12) {
                Button(captureActive ? "Stop Capture" : "Start Capture") {
                    if captureActive {
                        HIDCapture.shared.stop()
                        captureCount = HIDCapture.shared.reportCount
                        captureActive = false
                    } else {
                        HIDCapture.shared.start()
                        captureCount = 0
                        captureLastSaved = nil
                        captureActive = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(captureActive ? .red : .accentColor)
                .controlSize(.small)
                .help("Record every raw HID report from the tablet before decoding. Use to diagnose unknown byte positions or decoder issues.")

                if captureActive {
                    Text("\(captureCount) reports")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer()

                Button("Save to Desktop") {
                    if captureActive {
                        HIDCapture.shared.stop()
                        captureActive = false
                    }
                    captureCount = HIDCapture.shared.reportCount
                    if let url = HIDCapture.shared.save() {
                        captureLastSaved = url.lastPathComponent
                        HIDCapture.shared.clear()
                        captureCount = 0
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(captureCount == 0 && !captureActive)
                .help("Stop capture (if running) and save all recorded HID reports to a JSON file on the Desktop.")
            }

 HStack(spacing: 12) {
 Button("Calibrate Unknown Device") {
 showCaptureWizard = true
 }
 .buttonStyle(.bordered)
 .tint(.blue)
 .controlSize(.small)
 .help("Guided calibration for unknown tablets. Produces a small JSON file for device support.")
 Button("Quick Discovery (10s)") {
            startDiscovery()
        }
        .buttonStyle(.bordered)
        .tint(.purple)
        .controlSize(.small)
        .help("Capture HID reports for 10 seconds while you move the stylus and press buttons.")
 Spacer()
 }

            if let saved = captureLastSaved {
                Text("Saved: \(saved)")
                    .font(.settingsLabel)
                    .foregroundStyle(.secondary)
            }


        if captureEngine.isDiscoveryMode {
            Text("Move stylus, press buttons, tilt, rotate...")
                .font(.settingsLabel)
                .foregroundStyle(.blue)
        }

        if let saved = discoverySaved {
            Text("Discovery saved: \(saved)")
                .font(.settingsLabel)
                .foregroundStyle(.secondary)
        }
            Text("Records every raw HID report before the decoder. Use to identify unknown byte positions (DTK-2400 barrel bits, KC-100 buttons, BT container layout).")
                .font(.settingsLabel)
                .foregroundStyle(.tertiary)
        }
        .onReceive(
            Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
        ) { _ in
            if captureActive {
                captureCount = HIDCapture.shared.reportCount
            }
        }
    }


    // MARK: - Discovery Mode

    private func startDiscovery() {
        guard let spec = WacomDeviceRegistry.spec(for: productID ?? 0) else { return }
        let vendorID = 0x056A
        let deviceInfo = CaptureDeviceInfo(
            vendorID: vendorID,
            productID: spec.productID,
            name: spec.name,
            locationID: nil,
            serialNumber: nil
        )

        // Clear previous state
        discoverySaved = nil
        discoveryInstructions = nil

        // Clear calibration callback and set discovery completion handler
        captureEngine.onCalibrationComplete = nil
        captureEngine.onDiscoveryComplete = { result in
            if let url = CaptureEngine.shared.exportDiscoveryJSON(result: result) {
                discoverySaved = url.lastPathComponent
            }
            discoveryInstructions = nil
        }

        // Start discovery (10 seconds)
        captureEngine.startDiscovery(deviceInfo: deviceInfo, duration: 10)
    }

    // MARK: - Diagnostic section

    private var diagnosticSection: some View {
        DisclosureGroup("Diagnostic Detail", isExpanded: $diagnosticsExpanded) {
            if diagnosticsExpanded {
                // Only compute diagnosticText when the panel is actually open.
                Text(diagnosticText)
                    .font(.monospaced)
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
    }

    private var presetLabel: String {
        guard let profile = settings.activeProfile else { return "None (device defaults)" }
        switch settings.activationSource {
        case .manual:
            return "\(profile.name)"
        case .app(_, let appName):
            return "\(profile.name)  (Auto: \(appName))"
        }
    }

    private var diagnosticText: String {
        var lines: [String] = []

        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .medium
        lines += ["Generated : \(fmt.string(from: Date()))"]

        let ver   = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        lines += ["App       : MockTab \(ver) (build \(build))"]

        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines += ["macOS     : \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"]

        #if arch(arm64)
            lines += ["CPU       : Apple Silicon (arm64)"]
        #else
            lines += ["CPU       : Intel (x86_64)"]
        #endif

        lines += [""]

        if tabletManager.connectedProductIDs.isEmpty {
            lines += ["Tablets   : none"]
        } else {
            lines += ["Tablets   : \(tabletManager.connectedProductIDs.count)"]
            for pid in tabletManager.connectedProductIDs {
                let name = TabletManager.deviceName(forProductID: pid)
                lines += ["  • \(name)  (ProductID 0x\(String(pid, radix: 16, uppercase: true)))"]
            }
            lines += ["Transport : \(tabletManager.connectedTransport)"]
            lines += ["Speed     : \(tabletManager.connectedUSBSpeed)"]
            if let pct = tabletManager.batteryPercent {
                let chgStr = tabletManager.batteryCharging ? " (charging)" : ""
                lines += ["Battery   : \(pct)%\(chgStr)"]
            }
        }

        lines += [""]
        lines += ["HID Manager    : \(tabletManager.hidManagerOpen ? "open" : "failed to open")"]
        lines += ["Accessibility  : \(accessibilityGranted ? "granted" : "not granted")"]
        lines += ["Launch at login: \(launchAtLogin ? "enabled" : "disabled")"]
        lines += ["Profile        : \(presetLabel)"]

        lines += [""]
        if conflicts.isEmpty {
            lines += ["Conflicts      : none"]
        } else {
            lines += ["Conflicts      : \(conflicts.count)"]
            for conflict in conflicts {
                lines += ["  ⚠ \(conflict)"]
            }
        }

        if let ctx = tabletManager.activeContext {
            let jitter = String(format: "%.2f", ctx.injector.jitterLevel)
            lines += [
                "Jitter level   : \(jitter) pt/sample\(ctx.injector.isJittery ? " (HIGH)" : "")"
            ]
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
        ("WacomTabletDriver",       "Wacom Tablet Driver"),
        ("TabletDriver",            "Wacom TabletDriver"),
        ("Wacom_IOManager",         "Wacom I/O Manager"),
        ("WacomTabletSpringboard",  "Wacom Springboard"),
        ("DataStoreMgr",            "Wacom DataStore Manager"),
        ("OpenTabletDriver.Daemon", "OpenTabletDriver Daemon"),
        ("OpenTabletDriver.UX",     "OpenTabletDriver UX"),
        ("OpenTabletDriver",        "OpenTabletDriver (GUI)"),
    ]

    private func detectConflicts() -> [String] {
        var found: [String] = []

        let running = NSWorkspace.shared.runningApplications
        var liveNames = Set(running.compactMap { $0.localizedName })
        liveNames.formUnion(running.compactMap { $0.bundleIdentifier })
        liveNames.formUnion(Self.runningProcessNames())

        var claimedNames = Set<String>()
        for (name, label) in Self.competingProcesses {
            let matchingLive = liveNames.filter {
                ($0 == name || name.hasPrefix($0) || $0.hasPrefix(name))
                    && !claimedNames.contains($0)
            }
            if !matchingLive.isEmpty {
                claimedNames.formUnion(matchingLive)
                found.append("\(label) is running — may conflict with MockTab's HID access")
            }
        }

        if let ctx = tabletManager.activeContext, ctx.injector.isJittery {
            let level = String(format: "%.1f", ctx.injector.jitterLevel)
            found.append("High hover jitter (\(level) pt/sample) — possible RF interference")
        }

        return found
    }

    private static func runningProcessNames() -> Set<String> {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        var names = Set<String>()
        for i in 0..<actualCount {
            let comm = procs[i].kp_proc.p_comm
            let name = withUnsafeBytes(of: comm) { buf in
                guard let base = buf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
                return String(cString: base)
            }
            if !name.isEmpty { names.insert(name) }
        }
        return names
    }

    private func showConflictAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Potential Conflicts Detected"

        var body = "MockTab found the following issues that may interfere with tablet operation:\n\n"
        for (i, conflict) in conflicts.enumerated() {
            body += "  \(i + 1). \(conflict)\n"
        }
        body += "\nRecommendation: Quit or disable the listed processes, then restart MockTab. "
        body += "For Wacom drivers, check System Settings → General → Login Items to prevent them from launching at startup. "
        body += "For RF jitter, try moving wireless receivers (mice, keyboards, Wi-Fi dongles) away from the tablet."

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
// when livePoint / liveButtons / activeToolID change.  The status table,
// diagnostic panel, and action buttons in InfoView are completely unaffected
// by pen-report updates.

private struct LiveInputView: View {
    let livePoint:    TabletPoint?
    let liveButtons:  LiveButtonState
    let activeToolID: String?
    let registry:     DeviceRegistry
    var hasDualRings: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live Input")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                // ── Stylus info ───────────────────────────────────────────────
                let tool: DeviceRegistry.KnownTool? = {
                    guard let id = activeToolID else { return nil }
                    return registry.knownTools.first(where: { $0.id == id })
                }()

                stylusRow(label: "Stylus Name", value: tool?.nickname ?? "—")
                stylusRow(label: "Stylus Type", value: tool?.kind     ?? "—")
                stylusRow(
                    label: "Tool Code",
                    value: tool?.toolCode.map { "0x\(String(format: "%04X", $0))" } ?? "—")
                stylusRow(label: "Serial", value: tool?.displayID ?? "—")

                Divider()
                    .gridCellColumns(3)
                    .padding(.vertical, 4)

                // ── Live data ─────────────────────────────────────────────────
                let point = livePoint
                let lb    = liveButtons

                liveRow(label: "Buttons") {
                    let anyExpress = lb.expressKeys.contains(true)
                    HStack(spacing: 4) {
                        if lb.tipDown     { tag("Tip") }
                        if lb.eraserDown  { tag("Eraser") }
                        if lb.button1Down { tag("B1") }
                        if lb.button2Down { tag("B2") }
                        ForEach(0..<lb.expressKeys.count, id: \.self) { i in
                            if lb.expressKeys[i] { tag("K\(i + 1)") }
                        }
                        if !lb.tipDown && !lb.eraserDown && !lb.button1Down
                            && !lb.button2Down && !anyExpress {
                            Text("None").foregroundStyle(.tertiary).font(.settingsBadge)
                        }
                    }
                }

                liveRow(label: "Pressure") {
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

                liveRow(label: "Rotation") {
                    Text(point != nil ? String(format: "%.1f°", point!.rotation) : "—")
                        .monospacedDigit()
                }

                liveRow(label: "Coordinate") {
                    Text(point != nil
                         ? "X: \(point!.x)   Y: \(point!.y)"
                         : "X: 0   Y: 0")
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                liveRow(label: "Tilt") {
                    Text(point != nil
                         ? "X: \(String(format: "%+.2f", point!.tiltX))   Y: \(String(format: "%+.2f", point!.tiltY))"
                         : "X: +0.00   Y: +0.00")
                        .monospacedDigit()
                }

                liveRow(label: "Hover") {
                    if let p = point {
                        Text("\(p.hoverDistance)   \(p.inProximity ? "(In Range)" : "(Out)")")
                            .monospacedDigit()
                    } else {
                        Text("—").monospacedDigit()
                    }
                }

                liveRow(label: hasDualRings ? "Ring — Left" : "Touch Ring") {
                    HStack(spacing: 6) {
                        Image(systemName: lb.touchRingActive
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(lb.touchRingActive ? Color.green : Color.secondary)
                            .imageScale(.small)
                        Text(lb.touchRingActive ? "Active" : "Idle")
                            .foregroundStyle(lb.touchRingActive ? .primary : .tertiary)
                    }
                }

                if hasDualRings {
                    liveRow(label: "Ring — Right") {
                        HStack(spacing: 6) {
                            Image(systemName: lb.touchRing2Active
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(lb.touchRing2Active ? Color.green : Color.secondary)
                                .imageScale(.small)
                            Text(lb.touchRing2Active ? "Active" : "Idle")
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
    private func liveRow(label: String,
                         @ViewBuilder value: () -> some View) -> some View {
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
            .font(.settingsBadge)
            .padding(.horizontal, 4)
            .background(Color.accentColor.opacity(0.2))
            .cornerRadius(3)
    }
}
