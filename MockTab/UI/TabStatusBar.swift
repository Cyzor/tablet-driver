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

import SwiftUI

// MARK: - DeviceNameLabel

/// A compact caption line showing the active device's user-assigned nickname
/// plus a green/grey presence dot.  Used as a subtitle under section headings
/// in tabs whose settings are per-device (Pressure, Buttons, Display).
struct DeviceNameLabel: View {
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry:      DeviceRegistry

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tabletManager.isConnected ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(displayName)
                .font(.settingsLabel)
                .foregroundStyle(.secondary)
        }
    }

    private var displayName: String {
        guard tabletManager.isConnected else { return "No device connected" }
        let id = tabletManager.connectedProductID
        if let t = registry.knownTablets.first(where: { $0.id == id }) { return t.nickname }
        return TabletManager.deviceName(forProductID: id)
    }
}

// MARK: - ToolNameLabel

/// A compact caption line showing the active tool's user-assigned nickname
/// plus a green/grey proximity dot.  Used as a subtitle under the Pen Buttons
/// section heading, where settings are per-tool (not per-device).
struct ToolNameLabel: View {
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry:      DeviceRegistry

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tabletManager.activeToolID != nil ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(displayName)
                .font(.settingsLabel)
                .foregroundStyle(.secondary)
        }
    }

    private var displayName: String {
        guard let toolID = tabletManager.activeToolID else {
            // Fall back to last-seen tool if registry has one
            return registry.knownTools.first?.nickname ?? "No tool in proximity"
        }
        if let t = registry.knownTools.first(where: { $0.id == toolID }) { return t.nickname }
        return toolID
    }
}

// MARK: - DeviceStatusBar

/// Slim sticky footer showing live device context: tablet name, connection
/// type, battery (BT only), last-seen tool, and active app override.
/// All data is sourced from the device context bound to this window's productID.
struct DeviceStatusBar: View {
    @ObservedObject var settings:      TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry:      DeviceRegistry
    let productID: Int

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                statusItem(symbol: "rectangle",              text: tabletName)
                Divider().frame(height: 12)
                statusItem(symbol: connectionSymbol,         text: connectionLabel)
                if let (sym, label) = batteryItem {
                    Divider().frame(height: 12)
                    statusItem(symbol: sym, text: label, tint: batteryTint)
                }
                Divider().frame(height: 12)
                statusItem(symbol: "pencil.tip.crop.circle", text: toolName)
                if let appName = activeAppName {
                    Divider().frame(height: 12)
                    statusItem(symbol: "app.badge.checkmark", text: appName)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func statusItem(symbol: String, text: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.settingsBadge)
                .foregroundStyle(tint)
            Text(text)
                .font(.settingsLabel)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Computed values

    private var context: DeviceContext? {
        tabletManager.contexts[productID]
    }

    private var tabletName: String {
        guard let context = context, context.isConnected else { return "No device" }
        if let t = registry.knownTablets.first(where: { $0.id == productID }) { return t.nickname }
        return TabletManager.deviceName(forProductID: productID)
    }

    private var connectionSymbol: String {
        guard let context = context else { return "cable.connector.horizontal" }
        let t = context.transport.lowercased()
        if t.contains("bluetooth") { return "wave.3.right" }
        return "cable.connector.horizontal"
    }

    private var connectionLabel: String {
        guard let context = context, context.isConnected else { return "Off" }
        return context.transport
    }

    private var batteryItem: (String, String)? {
        guard let context = context, let pct = context.batteryPercent else { return nil }
        let sym = batterySymbol(pct: pct, charging: context.batteryCharging)
        let label = context.batteryCharging ? "\(pct)% ⚡" : "\(pct)%"
        return (sym, label)
    }

    private var batteryTint: Color {
        guard let context = context, let pct = context.batteryPercent else { return .secondary }
        if context.batteryCharging { return .green }
        if pct < 20 { return .red }
        if pct < 50 { return .orange }
        return .secondary
    }

    private func batterySymbol(pct: Int, charging: Bool) -> String {
        guard !charging else { return "battery.100percent.bolt" }
        switch pct {
        case 0 ..< 13:  return "battery.0percent"
        case 13 ..< 38: return "battery.25percent"
        case 38 ..< 63: return "battery.50percent"
        case 63 ..< 88: return "battery.75percent"
        default:        return "battery.100percent"
        }
    }

    private var toolName: String {
        if let context = context, let toolID = context.activeToolID {
            if let t = registry.knownTools.first(where: { $0.id == toolID }) { return t.nickname }
            return toolID
        }
        return registry.knownTools.first?.nickname ?? "No tool"
    }

    private var activeAppName: String? {
        settings.activeAppOverride?.appName
    }
}
