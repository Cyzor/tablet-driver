import AppKit
import ServiceManagement
import SwiftUI

/// Status dashboard tab — shows live device state, system permissions,
/// and a collapsible diagnostic dump for technical analysis.
struct InfoView: View {
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var settings: TabletSettings

    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var launchAtLogin = false
    @State private var diagnosticsExpanded = false
    @State private var conflicts: [String] = []

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
                        livePoint:    tabletManager.livePoint,
                        liveButtons:  tabletManager.liveButtons,
                        activeToolID: tabletManager.activeToolID,
                        registry:     DeviceRegistry.shared
                    )
                    Divider()
                    diagnosticSection
                }
                .padding()
            }
            .contentShape(Rectangle())
            .onTapGesture { refresh() }
            .onAppear { refresh() }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)
            ) { _ in refresh() }
            PresetStatusBar(settings: settings)
        }
    }

    // MARK: - Status table
    // Re-renders only on device connect/disconnect and permission changes,
    // NOT on every pen report — livePoint/liveButtons are isolated in LiveInputView.

    private var statusTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            row(
                "Device",
                value: tabletManager.isConnected
                    ? tabletManager.connectedDeviceName
                    : "Not connected",
                ok: tabletManager.isConnected)

            row(
                "Connection",
                value: tabletManager.isConnected ? tabletManager.connectedTransport : "—",
                ok: tabletManager.isConnected ? true : nil)

            row(
                "Speed",
                value: tabletManager.isConnected ? tabletManager.connectedUSBSpeed : "—",
                ok: tabletManager.isConnected ? true : nil)

            row(
                "Status",
                value: tabletManager.isConnected ? "Active" : "Idle",
                ok: tabletManager.isConnected ? true : nil)

            row(
                "Permission",
                value: accessibilityGranted ? "Granted" : "Not granted",
                ok: accessibilityGranted,
                fix: accessibilityGranted ? nil : requestAccessibility)

            row(
                "HID Manager",
                value: tabletManager.hidManagerOpen ? "Running" : "Failed to open",
                ok: tabletManager.hidManagerOpen ? true : false)

            row(
                "Preset",
                value: presetLabel,
                ok: nil)

            row(
                "Launch at Login",
                value: launchAtLogin ? "Enabled" : "Disabled",
                ok: launchAtLogin ? true : nil,
                fix: launchAtLogin ? nil : enableLaunchAtLogin)

            row(
                "Conflicts",
                value: conflicts.isEmpty
                    ? "None detected"
                    : "\(conflicts.count) issue\(conflicts.count == 1 ? "" : "s")",
                ok: conflicts.isEmpty ? true : false,
                fix: conflicts.isEmpty ? nil : showConflictAlert)
        }
    }

    @ViewBuilder
    private func row(
        _ label: String, value: String,
        ok: Bool?, fix: (() -> Void)? = nil
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 150, alignment: .trailing)
                .gridColumnAlignment(.trailing)

            HStack(spacing: 8) {
                statusIcon(ok)
                Text(value)
                if let fix {
                    Button("Fix", action: fix)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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

    // MARK: - Diagnostic section

    private var diagnosticSection: some View {
        DisclosureGroup("Diagnostic Detail", isExpanded: $diagnosticsExpanded) {
            if diagnosticsExpanded {
                // Only compute diagnosticText when the panel is actually open.
                Text(diagnosticText)
                    .font(.system(.caption2, design: .monospaced))
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
        guard let preset = settings.activePreset else { return "None (device defaults)" }
        switch settings.activationSource {
        case .manual:
            return "\(preset.name)"
        case .app(_, let appName):
            return "\(preset.name)  (Auto: \(appName))"
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
        }

        lines += [""]
        lines += ["HID Manager    : \(tabletManager.hidManagerOpen ? "open" : "failed to open")"]
        lines += ["Accessibility  : \(accessibilityGranted ? "granted" : "not granted")"]
        lines += ["Launch at login: \(launchAtLogin ? "enabled" : "disabled")"]
        lines += ["Preset         : \(presetLabel)"]

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
                    HStack(spacing: 4) {
                        if lb.tipDown    { tag("Tip") }
                        if lb.eraserDown { tag("Eraser") }
                        if lb.button1Down { tag("B1") }
                        if lb.button2Down { tag("B2") }
                        if !lb.tipDown && !lb.eraserDown && !lb.button1Down && !lb.button2Down {
                            Text("None").foregroundStyle(.tertiary).font(.caption2)
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

                liveRow(label: "Touch Ring") {
                    HStack(spacing: 6) {
                        Image(systemName: lb.touchRingActive
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(lb.touchRingActive ? Color.green : Color.secondary)
                            .imageScale(.small)
                        Text(lb.touchRingActive ? "Active" : "Idle")
                            .foregroundStyle(lb.touchRingActive ? .primary : .tertiary)
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
            .font(.caption2)
            .padding(.horizontal, 4)
            .background(Color.accentColor.opacity(0.2))
            .cornerRadius(3)
    }
}
