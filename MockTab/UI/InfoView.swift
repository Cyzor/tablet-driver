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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusTable
                Divider()
                diagnosticSection
            }
            .padding()
        }
        // Refresh immediately on appear and whenever the user switches back to
        // MockTab (e.g. after granting accessibility in System Settings).
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
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

        return lines.joined(separator: "\n")
    }

    // MARK: - Actions

    private func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Prompts the system accessibility dialog.  If it doesn't appear
    /// (macOS sometimes suppresses repeat prompts), the user can reach
    /// the pane directly via System Settings > Privacy & Security > Accessibility.
    private func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
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
