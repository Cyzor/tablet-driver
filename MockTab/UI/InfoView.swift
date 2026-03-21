import SwiftUI
import AppKit
import ServiceManagement

/// Status dashboard tab — shows live device state, system permissions,
/// and a collapsible diagnostic dump for technical analysis.
struct InfoView: View {
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var settings: TabletSettings

    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var launchAtLogin       = false
    @State private var diagnosticsExpanded = false
    @State private var conflicts: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusTable
                    Divider()
                    diagnosticSection
                }
                .padding()
            }
            .contentShape(Rectangle())
            .onTapGesture { refresh() }
            // Refresh immediately on appear and whenever the user switches back to
            // MockTab (e.g. after granting accessibility in System Settings).
            .onAppear { refresh() }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
            PresetStatusBar(settings: settings)
        }
    }

    // MARK: - Status table

    private var statusTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            row("Device",
                value: tabletManager.isConnected
                    ? tabletManager.connectedDeviceName
                    : "Not connected",
                ok: tabletManager.isConnected)

            row("Connection",
                value: tabletManager.isConnected ? tabletManager.connectedTransport : "—",
                ok: tabletManager.isConnected ? true : nil)

            row("Speed",
                value: tabletManager.isConnected ? tabletManager.connectedUSBSpeed : "—",
                ok: tabletManager.isConnected ? true : nil)

            row("Status",
                value: tabletManager.isConnected ? "Active" : "Idle",
                ok: tabletManager.isConnected ? true : nil)

            row("Permission",
                value: accessibilityGranted ? "Granted" : "Not granted",
                ok: accessibilityGranted,
                fix: accessibilityGranted ? nil : requestAccessibility)

            row("HID Manager",
                value: tabletManager.hidManagerOpen ? "Running" : "Failed to open",
                ok: tabletManager.hidManagerOpen ? true : false)

            row("Preset",
                value: presetLabel,
                ok: nil)

            row("Launch at Login",
                value: launchAtLogin ? "Enabled" : "Disabled",
                ok: launchAtLogin ? true : nil,
                fix: launchAtLogin ? nil : enableLaunchAtLogin)

            row("Conflicts",
                value: conflicts.isEmpty ? "None detected" : "\(conflicts.count) issue\(conflicts.count == 1 ? "" : "s")",
                ok: conflicts.isEmpty ? true : false,
                fix: conflicts.isEmpty ? nil : showConflictAlert)
        }
    }

    /// One row of the status grid.
    /// - `ok: true`  → green ✓    device / condition is fine
    /// - `ok: false` → black ✗    problem; shows Fix button when `fix` is supplied
    /// - `ok: nil`   → gray  –    informational, no pass/fail judgement
    @ViewBuilder
    private func row(_ label: String, value: String,
                     ok: Bool?, fix: (() -> Void)? = nil) -> some View {
        GridRow {
            // Right-aligned label column.
            Text(label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 150, alignment: .trailing)
                .gridColumnAlignment(.trailing)

            // Icon + value + optional Fix button — all in one HStack so the
            // Fix button sits immediately beside the value text, not at the
            // far edge of the window.
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

        let ver   = Bundle.main.object(forInfoDictionaryKey:
                        "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey:
                        "CFBundleVersion") as? String ?? "?"
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
            lines += ["Jitter level   : \(jitter) pt/sample\(ctx.injector.isJittery ? " (HIGH)" : "")"]
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Actions

    private func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        conflicts = detectConflicts()
    }

    /// Prompts the system accessibility dialog.  If it doesn't appear
    /// (macOS sometimes suppresses repeat prompts), the user can reach
    /// the pane directly via System Settings > Privacy & Security > Accessibility.
    private func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
    }

    // MARK: - Conflict detection

    /// Known executable names that indicate a competing tablet driver is running.
    /// Matched against both the executable name from the process list and
    /// NSWorkspace's localizedName / bundleIdentifier for GUI apps.
    private static let competingProcesses: [(name: String, label: String)] = [
        ("WacomTabletDriver",        "Wacom Tablet Driver"),
        ("TabletDriver",             "Wacom TabletDriver"),
        ("Wacom_IOManager",          "Wacom I/O Manager"),
        ("WacomTabletSpringboard",   "Wacom Springboard"),
        ("DataStoreMgr",             "Wacom DataStore Manager"),
        ("OpenTabletDriver.Daemon",  "OpenTabletDriver Daemon"),
        ("OpenTabletDriver.UX",      "OpenTabletDriver UX"),
        ("OpenTabletDriver",         "OpenTabletDriver (GUI)"),
    ]

    /// Scans running processes and injector state for potential conflicts.
    /// Uses both NSWorkspace (for GUI apps) and a POSIX-level process scan
    /// (for daemons like OpenTabletDriver.Daemon that have no UI presence).
    private func detectConflicts() -> [String] {
        var found: [String] = []

        // Collect names from NSWorkspace (GUI apps).
        let running = NSWorkspace.shared.runningApplications
        var liveNames = Set(running.compactMap { $0.localizedName })
        liveNames.formUnion(running.compactMap { $0.bundleIdentifier })

        // Collect executable names via POSIX (catches daemons / CLI tools).
        // sysctl KERN_PROC_ALL gives us every process; we extract the
        // comm field (up to 16 chars of the executable name).
        let posixNames = Self.runningProcessNames()
        liveNames.formUnion(posixNames)

        // Track which live names have already been claimed by a more-specific
        // entry so "OpenTabletDriver" doesn't duplicate "OpenTabletDriver.Daemon".
        var claimedNames = Set<String>()
        for (name, label) in Self.competingProcesses {
            // Exact match from NSWorkspace (full names) or from sysctl.
            // sysctl's p_comm is truncated to 16 chars, so also check whether
            // any running process name starts with our target (or vice-versa)
            // to catch e.g. "OpenTabletDriver." matching "OpenTabletDriver.Daemon".
            let matchingLive = liveNames.filter {
                ($0 == name || name.hasPrefix($0) || $0.hasPrefix(name))
                && !claimedNames.contains($0)
            }
            if !matchingLive.isEmpty {
                claimedNames.formUnion(matchingLive)
                found.append("\(label) is running — may conflict with MockTab's HID access")
            }
        }

        // Check jitter from the active context's injector.
        if let ctx = tabletManager.activeContext, ctx.injector.isJittery {
            let level = String(format: "%.1f", ctx.injector.jitterLevel)
            found.append("High hover jitter (\(level) pt/sample) — possible RF interference")
        }

        return found
    }

    /// Returns a set of executable names for all running processes using sysctl.
    private static func runningProcessNames() -> Set<String> {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > 0 else { return [] }

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

    /// Shows an alert listing all detected conflicts with recommendations.
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

    /// Registers MockTab as a login item via SMAppService (macOS 13+).
    /// Falls back to opening System Settings > General > Login Items & Extensions
    /// if registration fails (e.g. the app isn't in /Applications yet).
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
