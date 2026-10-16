// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later


import AppKit
import Combine
import IOKit.hid
import ServiceManagement
import SwiftUI
import TabletKit

// The Info pane's status table and the Android-mode and unknown-device
// banners above it.
extension InfoView {
    var deviceContext: DeviceContext? {
        tabletManager.context(forKey: instanceKey)
    }

    var isConnected: Bool {
        deviceContext?.isConnected ?? false
    }

    /// Connected aux-only companion peripheral (currently only the Xencelabs
    /// Quick Keys puck/dongle) — same resolution `DeviceStatusBar` and
    /// `ButtonMappingView` use for their own companion sections.
    var companionContext: DeviceContext? {
        guard let productID else { return nil }
        let companionPID = DeviceCompanions.connectedCompanion(
            forProductID: productID, connectedProductIDs: tabletManager.connectedProductIDs)
        return companionPID.flatMap { tabletManager.contexts[$0] }
    }

    /// The driver for a tablet the registry doesn't know, or nil.
    var unrecognizedDriver: SessionDriver? {
        (deviceContext?.tabletDevice as? SessionDriver).flatMap { $0.guessedAs != nil ? $0 : nil }
    }

    /// Brand guessed from USB strings for another maker's unknown tablet.
    var detectedBrand: String? {
        unrecognizedDriver?.detectedBrand
    }

    var androidModeBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Tablet is in Android mode", comment: "Banner title shown when a Wacom Intuos reports its Android-mode vendor ID"))
                    .appFont(.headline)
                Text(String(localized: "Hold the outer ExpressKeys for 5 seconds, then reconnect.", comment: "Body of the Android-mode banner: how to switch the tablet back to PC mode"))
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    var unknownDeviceBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.orange)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Unrecognized tablet", comment: "Banner title shown when the active tablet isn't in the registry"))
                    .appFont(.headline)
                if let detectedBrand {
                    Text(String(localized: "Looks like \(detectedBrand), but MockTab doesn't know this model yet.", comment: "Brand guess shown above the unknown-device banner body when USB strings hint at a known tablet brand"))
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(String(localized: "Full support needs a recording.", comment: "Body of the unknown-device banner"))
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "Collect Device Data…", comment: "Banner button: start the data-collection session for an unknown device")) {
                    showCaptureGuide = true
                }
                .buttonStyle(.borderedProminent)
                .appControlSize(.small)
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

    var statusTable: some View {
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
            } else if deviceContext?.batteryCharging == true {
                row(
                    String(localized: "Battery", comment: "Row label in Info tab status table"),
                    value: String(
                        localized: "Charging",
                        comment: "Status bar and Info battery value while a tablet charges and doesn't report its level"),
                    ok: nil,
                    leadingSymbol: BatteryIndicator.symbolName(pct: 100, charging: true),
                    symbolColor: .green)
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
                    : { requestInputMonitoring() },
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
                    : { requestAccessibility() },
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
                action: launchAtLogin ? { disableLaunchAtLogin() } : { enableLaunchAtLogin() },
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
                action: conflicts.isEmpty ? nil : { showConflictAlert() },
                // Ellipsis: opens an alert rather than fixing anything directly.
                actionLabel: String(localized: "Fix…", comment: "Button on the Conflicts row that opens an alert describing the detected conflicts"),
                actionHelp: String(localized: "Show details about detected conflicts with other tablet drivers and how to resolve them.", comment: "Tooltip on Fix button for Conflicts row")
            )

            row(
                String(localized: "Tablets", comment: "Row label in Info tab status table — tablets the app remembers"),
                value: String(localized: "\(DeviceRegistry.shared.knownTablets.count) known", comment: "Tablets status value: how many tablets the app remembers"),
                ok: tabletManager.connectedProductIDs.isEmpty ? nil : true,
                action: { SettingsWindowManager.shared.showAllConnectedTablets() },
                actionLabel: String(localized: "Show All Connected Tablets", comment: "Button on the Tablets row: open a settings window for every connected tablet"),
                actionHelp: String(localized: "Brings every connected tablet's window to the front, opening any that are closed.", comment: "Tooltip on Show All Connected Tablets button"),
                actionDisabled: !SettingsWindowManager.hasConnectedTablet)
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
    func row(
        _ label: String, value: String,
        ok: Bool?,
        leadingSymbol: String? = nil,
        symbolColor: Color? = nil,
        action: (() -> Void)? = nil,
        actionLabel: String? = nil,
        actionHelp: String? = nil,
        actionDisabled: Bool = false
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
                // One line: the form sized the grid for a wrapped value but
                // drew it truncated, leaving a blank line under the table.
                Text(value)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            // A checkmark symbol reads as selected; here it only means OK.
            .accessibilityRemoveTraits(.isSelected)
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
                        .appControlSize(.small)
                        .disabled(actionDisabled)
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
    func statusIcon(_ ok: Bool?) -> some View {
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
}
