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
    /// `ButtonsView` use for their own companion sections.
    var companionContext: DeviceContext? {
        guard let productID else { return nil }
        let companionPID = DeviceCompanions.connectedCompanion(
            forProductID: productID, connectedProductIDs: tabletManager.connectedProductIDs)
        return companionPID.flatMap { tabletManager.contexts[$0] }
    }

    /// The driver for a tablet the registry doesn't know, or nil.
    var unrecognizedDriver: SessionDriver? {
        (deviceContext?.tabletDevice as? SessionDriver).flatMap { $0.guessedAs != nil || $0.isSelfDescribed ? $0 : nil }
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
                if unrecognizedDriver?.isSelfDescribed == true {
                    Text(String(localized: "Experimental support", comment: "Banner title shown when another maker's tablet is read from its own description"))
                        .appFont(.headline)
                    Text(String(localized: "Some features may not work yet.", comment: "Banner line shown when another maker's tablet is read from its own description"))
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(String(localized: "Unrecognized tablet", comment: "Banner title shown when the active tablet isn't in the registry"))
                        .appFont(.headline)
                }
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
                value: deviceContext?.connectionName ?? "—",
                ok: isConnected ? true : nil)

            // One row in every state, so a report arriving changes its value
            // instead of swapping in a new row. A model that has reported
            // before keeps the row while it connects, so rows below don't shift.
            let batteryPercent = deviceContext?.batteryPercent
            let charging = deviceContext?.batteryCharging ?? false
            let checking = deviceContext?.awaitingBatteryReading == true
            if batteryPercent != nil || charging || checking
                || (instanceKey ?? deviceContext?.instanceKey).map(DeviceContext.expectsBatteryReport(for:)) == true
            {
                row(
                    String(localized: "Battery", comment: "Row label in Info tab status table"),
                    value: batteryPercent.map { pct in
                        charging
                            ? "\(pct)%  \(String(localized: "(Charging)", comment: "Suffix when device is charging, e.g. '85%  (Charging)'"))"
                            : "\(pct)%"
                    } ?? (charging
                        ? String(
                            localized: "Charging",
                            comment: "Status bar and Info battery value while a tablet charges and doesn't report its level")
                        : checking
                            ? String(localized: "Checking…", comment: "Battery value while a wireless tablet's level settles after it links")
                            : "—"),
                    ok: batteryPercent.map { $0 < 20 ? false : nil } ?? nil,
                    leadingSymbol: BatteryIndicator.symbolName(pct: batteryPercent ?? 100, charging: charging),
                    // Affirmative green when healthy — this table is the
                    // place users come to check on the device.
                    // Grey while the tablet sleeps: the reading is from before.
                    symbolColor: deviceContext?.isAsleepOnWirelessKit == true ? .secondary : batteryPercent.map {
                        BatteryIndicator.tint(pct: $0, charging: charging, healthy: .green)
                    } ?? (charging ? .green : .secondary),
                    accessory: offersWirelessSleep ? AnyView(wirelessSleepPicker) : nil)
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

            let asleep = deviceContext?.isAsleepOnWirelessKit == true
            row(
                String(localized: "Status", comment: "Row label in Info tab status table — driver status"),
                value: asleep
                    ? String(localized: "Asleep", comment: "Driver status value — a wireless tablet is asleep")
                    : isConnected
                    ? String(localized: "Active", comment: "Driver status value — device is active")
                    : String(localized: "Idle", comment: "Driver status value — device is idle"),
                ok: isConnected && !asleep ? true : nil)

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
                value: profileLabel,
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
                actionHelp: String(localized: "Show details about detected conflicts with other tablet drivers and how to resolve them.", comment: "Tooltip on Fix button for Conflicts row"),
                reservesActionSpace: true
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
        actionDisabled: Bool = false,
        reservesActionSpace: Bool = false,
        accessory: AnyView? = nil
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
                    // Centered in a status icon's width, so the value lines
                    // up with the rows above and below however wide it is.
                    statusIcon(nil)
                        .hidden()
                        .overlay {
                            Image(systemName: sym)
                                .foregroundStyle(symbolColor ?? .primary)
                                .fixedSize()
                        }
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
                if let accessory {
                    accessory
                } else if let action, let actionLabel {
                    Button(actionLabel, action: action)
                        .buttonStyle(.bordered)
                        .appControlSize(.small)
                        .disabled(actionDisabled)
                        .help(actionHelp ?? "")
                        // Sized to its own label — equal widths would stretch
                        // "Enable" to "Open System Settings"'s width.
                        .fixedSize()
                } else if reservesActionSpace, let actionLabel {
                    // Keeps the row's height when an action may appear later.
                    Button(actionLabel) {}
                        .buttonStyle(.bordered)
                        .appControlSize(.small)
                        .fixedSize()
                        .hidden()
                }
                Spacer(minLength: 0)
            }
            .gridColumnAlignment(.leading)
        }
    }

    /// A model that runs on the Wacom wireless kit, which holds a sleep timer.
    var offersWirelessSleep: Bool {
        let pid = deviceContext?.productID ?? productID ?? 0
        return WacomDeviceRegistry.spec(for: pid)?.offeredControls.contains(.wirelessKit) == true
    }

    /// The kit's sleep timer, live only while the tablet runs on its receiver.
    var wirelessSleepPicker: some View {
        let live = deviceContext?.tabletDevice?.controls.wirelessKit != nil
        return HStack(spacing: 6) {
            Text("Sleep After", comment: "Label before the sleep timer menu in the Info pane's Battery row")
                .foregroundStyle(.secondary)
            Picker(
                String(localized: "Sleep Timer", comment: "Quick Keys auto-sleep timer row label"),
                selection: settings.recordingBinding(
                    String(localized: "Sleep Timer", comment: "Quick Keys auto-sleep timer row label"),
                    get: { max(settings.wirelessSleepMinutes, 0) },
                    set: { settings.wirelessSleepMinutes = $0 })
            ) {
                // Tags are minutes; the receiver counts 5-minute steps.
                Text("5 minutes", comment: "Wireless kit sleep timer choice").tag(5)
                Text("10 minutes", comment: "Wireless kit sleep timer choice").tag(10)
                Text("15 minutes", comment: "Wireless kit sleep timer choice").tag(15)
                Text("30 minutes", comment: "Quick Keys sleep timer choice").tag(30)
                Text("60 minutes", comment: "Quick Keys sleep timer choice").tag(60)
                Divider()
                Text("Default", comment: "Wireless kit sleep timer choice: the tablet's own timer").tag(0)
            }
            .labelsHidden()
            .appControlSize(.small)
            .fixedSize()
        }
        .disabled(!live)
        .help(live
            ? String(localized: "Puts the tablet to sleep when it sits unused this long.", comment: "Tooltip on the wireless kit sleep timer in the Info pane")
            : String(localized: "Works only through the wireless receiver.", comment: "Tooltip on the wireless kit sleep timer while the tablet is on USB"))
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
