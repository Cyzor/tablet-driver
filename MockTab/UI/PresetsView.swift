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
import SwiftUI

/// Profiles tab — lets the user create, activate, rename, and delete named
/// configuration snapshots for the current device, and bind specific apps
/// to profiles so they switch automatically on focus.
///
/// Each profile stores only the keys that were explicitly changed while it was
/// active; everything else falls through to the device defaults at read time.
struct ProfilesView: View {
    @ObservedObject var settings:      TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry:      DeviceRegistry
    var productID: Int?

    @State private var isCreating = false
    @State private var newName = ""
    @State private var editingPreset: TabletSettings.Profile? = nil
    @State private var editingName = ""

    // Summary + export state
    @State private var summaryExpanded = false
    /// TabletSettings instances for tablets that aren't currently connected.
    /// Populated lazily in onAppear so we don't rebuild on every render.
    @State private var offlineSettings: [Int: TabletSettings] = [:]

    // Import state
    @State private var pendingImport: ImportPlan? = nil
    @State private var showImportSheet = false
    @State private var importError: String? = nil

    // MARK: - Recording Binding Helper

    /// Creates a binding that automatically registers undo when the value changes.
    private func recordingBinding<T: Equatable>(
        _ name: String,
        get: @escaping () -> T,
        set: @escaping (T) -> Void
    ) -> Binding<T> {
        Binding(
            get: get,
            set: { newValue in
                let oldValue = get()
                guard newValue != oldValue else { return }
                set(newValue)
                settings.record(name) { set(oldValue) }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    activeBanner
                    Divider()
                    presetList
                    Divider()
                    createRow
                    Divider()
                    autoSwitchSection
                    Divider()
                    summarySection
                    Divider()
                    exportSection
                }
                .padding()
            }
            DeviceStatusBar(settings: settings, tabletManager: tabletManager, registry: registry, productID: productID ?? 0)
        }
        .onAppear { populateOfflineSettings() }
        .onChange(of: registry.knownTablets.count) { _ in populateOfflineSettings() }
    }

    private func populateOfflineSettings() {
        for tablet in registry.knownTablets {
            guard tabletManager.contexts[tablet.id] == nil,
                  offlineSettings[tablet.id] == nil
            else { continue }
            offlineSettings[tablet.id] = TabletSettings(productID: tablet.id)
        }
    }

    // MARK: - Active banner

    private var activeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: settings.activeProfile == nil ? "star" : "star.fill")
                .foregroundStyle(settings.activeProfile == nil ? Color.secondary : Color.yellow)
            VStack(alignment: .leading, spacing: 2) {
                if let preset = settings.activeProfile {
                    Text("Active: \(preset.name)").fontWeight(.medium)
                } else {
                    Text("Device defaults — no profile active").foregroundStyle(.secondary)
                }
                if case .app(_, let appName) = settings.activationSource {
                    Text("Auto-switched by \(appName)")
                        .font(.settingsLabel)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if settings.activeProfile != nil {
                Button("Deactivate") {
                    // Capture snapshot before deactivating so we can undo
                    let snap = settings.snapshot()
                    settings.activate(nil)
                    settings.restoreSnapshot(snap, actionName: "Deactivate Profile")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1))
    }

    // MARK: - Preset list

    @ViewBuilder
    private var presetList: some View {
        if settings.profiles.isEmpty {
            Text(
                "No profiles yet.\nUse the button below to save the current settings as a named profile."
            )
            .foregroundStyle(.secondary)
            .font(.callout)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            VStack(spacing: 0) {
                ForEach(settings.profiles) { preset in
                    presetRow(preset)
                    if preset.id != settings.profiles.last?.id {
                        Divider().padding(.leading, 40)
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1))
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: TabletSettings.Profile) -> some View {
        let isActive = settings.activeProfile?.id == preset.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Activation toggle
                Button {
                    // Capture snapshot before activating so we can undo
                    let snap = settings.snapshot()
                    settings.activate(isActive ? nil : preset)
                    settings.restoreSnapshot(snap, actionName: "Activate Profile")
                } label: {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .imageScale(.large)
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)

                // Name — inline edit while renaming
                if editingPreset?.id == preset.id {
                    TextField("Profile name", text: $editingName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        .onSubmit { commitRename() }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(preset.name)
                        Text(
                            "\(preset.overriddenKeys.count) override\(preset.overriddenKeys.count == 1 ? "" : "s")"
                        )
                        .font(.settingsBadge)
                        .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Row action buttons
                if editingPreset?.id == preset.id {
                    Button("Save") { commitRename() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Cancel") { editingPreset = nil }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button {
                        editingPreset = preset
                        editingName = preset.name
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Rename")

                    Button(role: .destructive) {
                        // Capture snapshot before deleting so we can undo
                        let snap = settings.snapshot()
                        settings.deletePreset(preset)
                        // Register undo that restores the deleted preset
                        settings.restoreSnapshot(snap, actionName: "Delete Profile")
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Delete")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // App bindings for this preset (only shown when auto-switch is on)
            if settings.autoSwitchEnabled {
                appBindingsForPreset(preset)
                    .padding(.leading, 40)
                    .padding(.trailing, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - App bindings sub-section

    @ViewBuilder
    private func appBindingsForPreset(_ preset: TabletSettings.Profile) -> some View {
        let bound = settings.appBindings.filter { $0.profileID == preset.id }
        VStack(alignment: .leading, spacing: 4) {
            if bound.isEmpty {
                Text("No apps bound to this profile")
                    .font(.settingsLabel)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(bound) { binding in
                    HStack(spacing: 6) {
                        appIcon(bundleID: binding.bundleID)
                        Text(binding.appName)
                            .font(.settingsLabel)
                        Spacer()
                        Button {
                            // Capture current bindings before unbinding
                            let oldBindings = settings.appBindings
                            settings.unbindApp(bundleID: binding.bundleID)
                            // Register undo for unbind
                            settings.record("Unbind App") {
                                self.settings.appBindings = oldBindings
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.settingsBadge)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove binding")
                    }
                }
            }
            Button {
                // Capture current bindings before binding
                let oldBindings = settings.appBindings
                settings.bindFrontmostApp(to: preset)
                // Register undo for bind
                settings.record("Bind App") {
                    self.settings.appBindings = oldBindings
                }
            } label: {
                Label("Bind current app", systemImage: "plus")
                    .font(.settingsLabel)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Assigns the currently frontmost app to this profile")
        }
    }

    @ViewBuilder
    private func appIcon(bundleID: String) -> some View {
        if let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path,
            let icon = NSWorkspace.shared.icon(forFile: path) as NSImage?
        {
            Image(nsImage: icon)
                .resizable().scaledToFit()
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "app")
                .font(.settingsBadge)
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        }
    }

    // MARK: - Create row

    @ViewBuilder
    private var createRow: some View {
        if isCreating {
            HStack(spacing: 8) {
                TextField("New profile name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitCreate() }
                Button("Save") { commitCreate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") {
                    isCreating = false
                    newName = ""
                }
                .buttonStyle(.bordered)
            }
        } else {
            Button {
                newName = ""
                isCreating = true
            } label: {
                Label("Save current settings as profile…", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: - Auto-switch section

    private var autoSwitchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                isOn: recordingBinding(
                    "Auto-Switch",
                    get: { settings.autoSwitchEnabled },
                    set: { settings.autoSwitchEnabled = $0 }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-switch profile by app")
                        .fontWeight(.medium)
                    Text(
                        "When enabled, switching to a bound app automatically activates its profile."
                    )
                    .font(.settingsLabel)
                    .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if settings.autoSwitchEnabled && !settings.appBindings.isEmpty {
                Text("App bindings appear under each profile above.")
                    .font(.settingsLabel)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Configuration Summary

    private var summarySection: some View {
        DisclosureGroup(isExpanded: $summaryExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if registry.knownTablets.isEmpty {
                    Text("No tablets have been connected yet.")
                        .font(.settingsLabel)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    ForEach(registry.knownTablets) { tablet in
                        tabletSummaryCard(tablet)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Configuration Summary", systemImage: "list.bullet.rectangle")
                .fontWeight(.medium)
        }
    }

    @ViewBuilder
    private func tabletSummaryCard(_ tablet: DeviceRegistry.KnownTablet) -> some View {
        let isConnected = tabletManager.contexts[tablet.id] != nil
        let ts: TabletSettings? = tabletManager.contexts[tablet.id]?.settings ?? offlineSettings[tablet.id]
        let tools = registry.tools(forDevice: tablet.id)

        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "rectangle.connected.to.line.below")
                    .foregroundStyle(isConnected ? Color.accentColor : Color.secondary)
                Text(tablet.nickname).fontWeight(.medium)
                Spacer()
                Text(isConnected ? "Connected" : "Not connected")
                    .font(.settingsBadge)
                    .foregroundStyle(isConnected ? Color.green : Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if let ts {
                let deviceLines = deviceNonDefaultLines(ts)
                let overrides = ts.appOverrides

                if !deviceLines.isEmpty || !overrides.isEmpty {
                    Divider().padding(.leading, 10)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(deviceLines, id: \.self) { line in
                            Text(line)
                                .font(.settingsLabel)
                                .foregroundStyle(.secondary)
                        }
                        if !overrides.isEmpty {
                            let names = overrides.map(\.appName).joined(separator: ", ")
                            Text("\(overrides.count) app override\(overrides.count == 1 ? "" : "s"): \(names)")
                                .font(.settingsLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }

                // Tools
                if !tools.isEmpty {
                    Divider().padding(.leading, 10)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(tools.enumerated()), id: \.element.id) { idx, tool in
                            toolSummaryRow(tool, deviceSettings: ts, isLast: idx == tools.count - 1)
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1))
    }

    @ViewBuilder
    private func toolSummaryRow(_ tool: DeviceRegistry.KnownTool, deviceSettings: TabletSettings, isLast: Bool) -> some View {
        let toolSettings = deviceSettings.toolSettings(forID: tool.id)
        let toolLines = toolNonDefaultLines(toolSettings)

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "pencil")
                    .font(.settingsBadge)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.nickname).font(.settingsLabel).fontWeight(.medium)
                    if tool.nickname != tool.kind {
                        Text(tool.kind)
                            .font(.settingsBadge)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Text(tool.displayID)
                    .font(.settingsBadge)
                    .foregroundStyle(.tertiary)
                    .fontDesign(.monospaced)
            }
            ForEach(toolLines, id: \.self) { line in
                Text(line)
                    .font(.settingsBadge)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)

        if !isLast { Divider().padding(.leading, 30) }
    }

    // MARK: - Non-default helpers

    private func deviceNonDefaultLines(_ s: TabletSettings) -> [String] {
        var lines: [String] = []
        if s.activeAreaX != 0 || s.activeAreaY != 0 || s.activeAreaWidth != 1 || s.activeAreaHeight != 1 {
            let x = Int(s.activeAreaX * 100); let y = Int(s.activeAreaY * 100)
            let w = Int(s.activeAreaWidth * 100); let h = Int(s.activeAreaHeight * 100)
            lines.append("Area: \(w)% × \(h)% at (\(x)%, \(y)%)")
        }
        if !s.proportionalMapping { lines.append("Proportional mapping: off") }
        switch s.targetDisplayIndex {
        case 0: break
        case TabletSettings.displayModeAll:    lines.append("Display: all displays")
        case TabletSettings.displayModeToggle: lines.append("Display: toggle mode")
        default: lines.append("Display: screen \(s.targetDisplayIndex)")
        }
        if s.smoothingStrength != 0 { lines.append("Smoothing: \(Int(s.smoothingStrength * 100))%") }
        if s.doubleClickDistance != 10 { lines.append("Double-click distance: \(Int(s.doubleClickDistance)) pt") }
        if s.invertRotation { lines.append("Art Pen rotation: inverted") }
        if s.relativeCursorMovement { lines.append("Cursor: relative mode") }
        if s.tabletOrientation != .landscape { lines.append("Orientation: \(s.tabletOrientation.label)") }
        if s.touchRingMode != .scroll { lines.append("Touch ring: \(s.touchRingMode.displayLabel)") }
        if s.touchStrip1Mode != .scroll { lines.append("Touch strip 1: \(s.touchStrip1Mode.displayLabel)") }
        if s.touchStrip2Mode != .scroll { lines.append("Touch strip 2: \(s.touchStrip2Mode.displayLabel)") }
        if s.penButton1Binding != .rightClick  { lines.append("Pen button 1: \(s.penButton1Binding.displayLabel)") }
        if s.penButton2Binding != .middleClick { lines.append("Pen button 2: \(s.penButton2Binding.displayLabel)") }
        let mapped = s.expressKeyBindings.filter { $0 != .none }
        if !mapped.isEmpty { lines.append("Express keys: \(mapped.count) mapped") }
        if s.pressureCurve != .linear { lines.append("Pressure curve: custom") }
        return lines
    }

    private func toolNonDefaultLines(_ t: ToolSettings) -> [String] {
        var lines: [String] = []
        if t.pressureCurve != .linear { lines.append("Pressure: custom curve") }
        if t.smoothingStrength != 0 { lines.append("Smoothing: \(Int(t.smoothingStrength * 100))%") }
        if t.tipBinding != .leftClick { lines.append("Tip: \(t.tipBinding.displayLabel)") }
        if t.eraserBinding != .rightClick { lines.append("Eraser: \(t.eraserBinding.displayLabel)") }
        if t.penButton1Binding != .rightClick  { lines.append("Pen button 1: \(t.penButton1Binding.displayLabel)") }
        if t.penButton2Binding != .middleClick { lines.append("Pen button 2: \(t.penButton2Binding.displayLabel)") }
        return lines
    }

    // MARK: - Export

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Backup & Restore")
                .fontWeight(.medium)
            Text("Export your current configuration as a JSON file. You can restore it later if settings get reset or corrupted.")
                .font(.settingsLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                ExportDragWell(generateJSON: buildExportData, onImport: handleImportData)
                    .frame(width: 80, height: 80)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Drag out to save a backup. Drag a .json file in to import.")
                        .font(.settingsLabel)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Export as JSON…") { saveExportToFile() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("Import from File…") { openImportPanel() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    if let err = importError {
                        Text(err)
                            .font(.settingsBadge)
                            .foregroundStyle(.red)
                    }
                }
            }
            .sheet(isPresented: $showImportSheet) {
                if let plan = pendingImport {
                    ImportPreviewSheet(plan: plan, registry: registry, tabletManager: tabletManager,
                                       offlineSettings: offlineSettings) {
                        showImportSheet = false
                        pendingImport = nil
                    }
                }
            }
        }
    }

    // MARK: - Structured JSON export

    private func buildExportData() -> Data? {
        let tablets = registry.knownTablets.map { exportTablet($0) }
        let iso = ISO8601DateFormatter()
        let envelope: [String: Any] = [
            "version": 2,
            "exportedAt": iso.string(from: Date()),
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "tablets": tablets
        ]
        guard JSONSerialization.isValidJSONObject(envelope) else { return nil }
        return try? JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
    }

    private func exportTablet(_ tablet: DeviceRegistry.KnownTablet) -> [String: Any] {
        let pid = tablet.id
        let hexPID = "0x\(String(pid, radix: 16, uppercase: true))"
        let devicePrefix = "device-\(hexPID)."
        let ts: TabletSettings = tabletManager.contexts[pid]?.settings
            ?? offlineSettings[pid]
            ?? TabletSettings(productID: pid)

        var d: [String: Any] = [
            "productID": hexPID,
            "modelName": tablet.modelName,
            "nickname": tablet.nickname,
            "settings": exportDeviceSettings(ts)
        ]
        if let serial = tablet.usbSerial, !serial.isEmpty { d["usbSerial"] = serial }

        let overrides = ts.appOverrides.map { exportAppOverride($0, devicePrefix: devicePrefix) }
        if !overrides.isEmpty { d["appOverrides"] = overrides }

        let presets = ts.profiles.map { exportPreset($0, activeID: ts.activeProfile?.id, devicePrefix: devicePrefix) }
        if !presets.isEmpty { d["profiles"] = presets }

        let tools = registry.tools(forDevice: pid).map { exportTool($0, ts: ts, devicePrefix: devicePrefix) }
        if !tools.isEmpty { d["tools"] = tools }

        return d
    }

    private func exportDeviceSettings(_ s: TabletSettings) -> [String: Any] {
        var d: [String: Any] = [:]
        d["tabletArea"] = [
            "x":                  roundFrac(s.activeAreaX),
            "y":                  roundFrac(s.activeAreaY),
            "width":              roundFrac(s.activeAreaWidth),
            "height":             roundFrac(s.activeAreaHeight),
            "proportionalMapping": s.proportionalMapping,
            "orientation":        s.tabletOrientation.label
        ] as [String: Any]
        d["display"]            = exportDisplay(s.targetDisplayIndex, toggleIDs: s.toggleDisplayIDSet)
        d["pressureCurve"]      = exportCurve(s.pressureCurve)
        d["smoothing"]          = s.smoothingStrength
        d["doubleClickDistance"] = s.doubleClickDistance
        d["invertRotation"]     = s.invertRotation
        d["relativeCursorMovement"] = s.relativeCursorMovement
        d["penButton1"]         = s.penButton1Binding.displayLabel
        d["penButton2"]         = s.penButton2Binding.displayLabel
        d["touchRing"]          = s.touchRingMode.displayLabel
        d["touchRingButton"]    = s.touchRingButtonBinding.displayLabel
        d["touchStrip1"]        = s.touchStrip1Mode.displayLabel
        d["touchStrip2"]        = s.touchStrip2Mode.displayLabel
        let expressKeys = s.expressKeyBindings.map(\.displayLabel)
        if expressKeys.contains(where: { $0 != "None" }) {
            d["expressKeys"] = expressKeys
        }
        return d
    }

    private func exportTool(
        _ tool: DeviceRegistry.KnownTool,
        ts: TabletSettings,
        devicePrefix: String
    ) -> [String: Any] {
        let t = ts.toolSettings(forID: tool.id)
        var d: [String: Any] = [
            "id":       tool.displayID,
            "kind":     tool.kind,
            "nickname": tool.nickname,
            "settings": [
                "pressureCurve": exportCurve(t.pressureCurve),
                "smoothing":     t.smoothingStrength,
                "tip":           t.tipBinding.displayLabel,
                "eraser":        t.eraserBinding.displayLabel,
                "penButton1":    t.penButton1Binding.displayLabel,
                "penButton2":    t.penButton2Binding.displayLabel
            ] as [String: Any]
        ]
        // Tool-level app overrides live in the same AppOverride entries as device overrides.
        // Filter to those that touch tool-specific keys.
        let toolKeys: Set<String> = ["pressureCurve", "smoothingStrength", "tipBinding",
                                     "eraserBinding", "penButton1Binding", "penButton2Binding"]
        let toolOverrides = ts.appOverrides
            .filter { !$0.overriddenKeys.intersection(toolKeys).isEmpty }
            .map { exportAppOverride($0, devicePrefix: devicePrefix, includeOnly: toolKeys) }
        if !toolOverrides.isEmpty { d["appOverrides"] = toolOverrides }
        return d
    }

    private func exportPreset(
        _ preset: TabletSettings.Profile,
        activeID: UUID?,
        devicePrefix: String
    ) -> [String: Any] {
        let presetPrefix = "\(devicePrefix)preset-\(preset.id.uuidString)."
        var settings: [String: Any] = [:]
        for key in preset.overriddenKeys.sorted() {
            if let v = readUDValue(key: key, prefix: presetPrefix) { settings[key] = v }
        }
        var d: [String: Any] = ["name": preset.name, "active": preset.id == activeID]
        if !settings.isEmpty { d["settings"] = settings }
        return d
    }

    private func exportAppOverride(
        _ override: TabletSettings.AppOverride,
        devicePrefix: String,
        includeOnly filter: Set<String>? = nil
    ) -> [String: Any] {
        let prefix = "\(devicePrefix)appOverride-\(override.bundleID)."
        let keys = filter.map { override.overriddenKeys.intersection($0) } ?? override.overriddenKeys
        var settings: [String: Any] = [:]
        for key in keys.sorted() {
            if let v = readUDValue(key: key, prefix: prefix) { settings[key] = v }
        }
        var d: [String: Any] = ["app": override.appName, "bundleID": override.bundleID]
        if !settings.isEmpty { d["settings"] = settings }
        return d
    }

    /// Reads one UserDefaults value and returns it in a JSON-friendly, human-readable form.
    private func readUDValue(key: String, prefix: String) -> Any? {
        let ud = UserDefaults.standard
        switch key {
        case "activeAreaX", "activeAreaY", "activeAreaWidth", "activeAreaHeight",
             "smoothingStrength", "doubleClickDistance":
            guard ud.object(forKey: prefix + key) != nil else { return nil }
            return roundFrac(ud.double(forKey: prefix + key))
        case "proportionalMapping", "invertRotation", "relativeCursorMovement":
            guard ud.object(forKey: prefix + key) != nil else { return nil }
            return ud.bool(forKey: prefix + key)
        case "targetDisplayIndex":
            guard ud.object(forKey: prefix + key) != nil else { return nil }
            return exportDisplayIndex(ud.integer(forKey: prefix + key))
        case "toggleDisplayIDs":
            guard let raw = ud.string(forKey: prefix + key), !raw.isEmpty else { return nil }
            return raw.split(separator: ",")
                .compactMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }
                .map { String($0) }
        case "tabletOrientation":
            guard ud.object(forKey: prefix + key) != nil else { return nil }
            return TabletOrientation(rawValue: ud.integer(forKey: prefix + key))?.label
        case "penButton1Binding", "penButton2Binding", "touchRingButtonBinding",
             "tipBinding", "eraserBinding":
            guard let raw = ud.string(forKey: prefix + key) else { return nil }
            return ButtonBinding.decode(raw)?.displayLabel ?? raw
        case "expressKeyBindings":
            guard let raw = ud.string(forKey: prefix + key),
                  let data = raw.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([ButtonBinding].self, from: data)
            else { return nil }
            return arr.map(\.displayLabel)
        case "touchRingMode", "touchStrip1Mode", "touchStrip2Mode":
            guard let raw = ud.string(forKey: prefix + key) else { return nil }
            return TouchRingMode(rawValue: raw)?.displayLabel ?? raw
        case "pressureCurve":
            guard let data = ud.data(forKey: prefix + key),
                  let curve = try? JSONDecoder().decode(BezierCurve.self, from: data)
            else { return nil }
            return exportCurve(curve)
        default:
            return nil
        }
    }

    // MARK: - Export helpers

    private func exportCurve(_ c: BezierCurve) -> [String: Any] {
        ["p1": [roundFrac(c.p1.x), roundFrac(c.p1.y)],
         "p2": [roundFrac(c.p2.x), roundFrac(c.p2.y)]]
    }

    private func exportDisplay(_ idx: Int, toggleIDs: Set<CGDirectDisplayID>) -> Any {
        switch idx {
        case 0:                              return "primary"
        case TabletSettings.displayModeAll:  return "all"
        case TabletSettings.displayModeToggle:
            guard !toggleIDs.isEmpty else { return "toggle" }
            return ["mode": "toggle",
                    "displays": toggleIDs.sorted().map { String($0) }] as [String: Any]
        default: return "display-\(idx)"
        }
    }

    private func exportDisplayIndex(_ idx: Int) -> Any {
        switch idx {
        case 0:                              return "primary"
        case TabletSettings.displayModeAll:  return "all"
        case TabletSettings.displayModeToggle: return "toggle"
        default: return "display-\(idx)"
        }
    }

    /// Round to 4 decimal places to suppress floating-point noise in the output.
    private func roundFrac(_ v: Double) -> Double {
        (v * 10000).rounded() / 10000
    }

    private func saveExportToFile() {
        guard let data = buildExportData() else { return }
        let panel = NSSavePanel()
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "MockTab-\(fmt.string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    // MARK: - Import

    /// Called by the drag well or file picker with raw JSON data.
    private func handleImportData(_ data: Data) {
        importError = nil
        do {
            let plan = try ImportPlan.parse(data, registry: registry)
            pendingImport = plan
            showImportSheet = true
        } catch let e as ImportPlan.ParseError {
            importError = e.localizedDescription
        } catch {
            importError = "Could not read file."
        }
    }

    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a MockTab backup file to import"
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url)
            else { return }
            self.handleImportData(data)
        }
    }

    // MARK: - Actions

    private func commitCreate() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Capture snapshot before creating preset so we can undo
        let snap = settings.snapshot()
        settings.saveAsPreset(name: trimmed)
        // Register undo that deletes the new preset
        if let newPreset = settings.profiles.last(where: { $0.name == trimmed }) {
            let presetToDelete = newPreset
            let snapshotForUndo = snap
            settings.record("Save Profile") {
                settings.deletePreset(presetToDelete)
                settings.restoreSnapshot(snapshotForUndo, actionName: "Undo Save Profile")
            }
        }
        isCreating = false
        newName = ""
    }

    private func commitRename() {
        guard let preset = editingPreset else { return }
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let oldName = preset.name
            settings.renamePreset(preset, to: trimmed)
            // Register undo for rename
            let presetForUndo = preset
            let nameForUndo = oldName
            settings.record("Rename Profile") {
                settings.renamePreset(presetForUndo, to: nameForUndo)
            }
        }
        editingPreset = nil
    }
}

// MARK: - ImportPlan

/// The result of parsing a v2 JSON backup: one entry per tablet found in the file.
struct ImportPlan {
    struct TabletEntry {
        let productID: Int          // hex string parsed to Int
        let modelName: String
        let nickname: String
        /// The preset name that will be created (may have suffix if name already taken).
        let resolvedProfileName: String
        /// All keys/values ready to write to UserDefaults for the preset.
        let profileValues: [String: Any]
        /// True if this productID is already in the registry.
        let isKnown: Bool
    }

    let sourceDate: String          // "exportedAt" from file, for display
    let entries: [TabletEntry]

    enum ParseError: LocalizedError {
        case notJSON, wrongVersion(Int?), noTablets

        var errorDescription: String? {
            switch self {
            case .notJSON:        return "Not a valid JSON file."
            case .wrongVersion(let v):
                if let v { return "Unsupported profile version (\(v)). Expected version 2." }
                return "File is missing a version field."
            case .noTablets:      return "No tablet data found in this file."
            }
        }
    }

    // MARK: Parsing

    @MainActor
    static func parse(_ data: Data, registry: DeviceRegistry) throws -> ImportPlan {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ParseError.notJSON }

        let version = root["version"] as? Int
        guard version == 2 else { throw ParseError.wrongVersion(version) }

        let sourceDate = root["exportedAt"] as? String ?? ""
        guard let tabletsRaw = root["tablets"] as? [[String: Any]], !tabletsRaw.isEmpty
        else { throw ParseError.noTablets }

        var entries: [TabletEntry] = []
        for tabletDict in tabletsRaw {
            guard let pidStr = tabletDict["productID"] as? String,
                  let pid = Int(pidStr.dropFirst(2), radix: 16)  // "0x0357" → 855
            else { continue }

            let modelName = tabletDict["modelName"] as? String ?? pidStr
            let nickname  = tabletDict["nickname"]  as? String ?? modelName
            let isKnown   = registry.knownTablets.contains { $0.id == pid }

            // Decode device-level settings into UserDefaults-ready values.
            var values: [String: Any] = [:]
            if let s = tabletDict["settings"] as? [String: Any] {
                decodeDeviceSettings(s, into: &values)
            }

            // Build a non-colliding preset name using existing presets for this device.
            // We'll finalize dedup at apply-time; here use the nickname as a base.
            let baseName = nickname

            entries.append(TabletEntry(
                productID: pid,
                modelName: modelName,
                nickname: nickname,
                resolvedProfileName: baseName,
                profileValues: values,
                isKnown: isKnown
            ))
        }

        if entries.isEmpty { throw ParseError.noTablets }
        return ImportPlan(sourceDate: sourceDate, entries: entries)
    }

    // MARK: Decoder helpers

    private static func decodeDeviceSettings(
        _ s: [String: Any],
        into values: inout [String: Any]
    ) {
        if let area = s["tabletArea"] as? [String: Any] {
            if let v = area["x"]      as? Double { values["activeAreaX"]      = v }
            if let v = area["y"]      as? Double { values["activeAreaY"]      = v }
            if let v = area["width"]  as? Double { values["activeAreaWidth"]  = v }
            if let v = area["height"] as? Double { values["activeAreaHeight"] = v }
            if let v = area["proportionalMapping"] as? Bool { values["proportionalMapping"] = v }
            if let v = area["orientation"] as? String {
                values["tabletOrientation"] = decodeOrientation(v)
            }
        }
        if let v = s["display"] { values["targetDisplayIndex"] = decodeDisplay(v) }
        if let v = s["smoothing"]          as? Double { values["smoothingStrength"]  = v }
        if let v = s["doubleClickDistance"] as? Double { values["doubleClickDistance"] = v }
        if let v = s["invertRotation"]     as? Bool   { values["invertRotation"]     = v }
        if let v = s["relativeCursorMovement"] as? Bool { values["relativeCursorMovement"] = v }
        if let v = s["penButton1"]        as? String  { values["penButton1Binding"]  = ButtonBinding.fromDisplayLabel(v).encoded }
        if let v = s["penButton2"]        as? String  { values["penButton2Binding"]  = ButtonBinding.fromDisplayLabel(v).encoded }
        if let v = s["touchRingButton"]   as? String  { values["touchRingButtonBinding"] = ButtonBinding.fromDisplayLabel(v).encoded }
        if let v = s["touchRing"]         as? String  { values["touchRingMode"]      = decodeTouchRingMode(v) }
        if let v = s["touchStrip1"]       as? String  { values["touchStrip1Mode"]    = decodeTouchRingMode(v) }
        if let v = s["touchStrip2"]       as? String  { values["touchStrip2Mode"]    = decodeTouchRingMode(v) }
        if let v = s["expressKeys"]       as? [String] { values["expressKeyBindings"] = decodeExpressKeys(v) }
        if let v = s["pressureCurve"]     as? [String: Any] {
            if let data = decodeCurveData(v) { values["pressureCurve"] = data }
        }
    }

    private static func decodeOrientation(_ label: String) -> Int {
        switch label {
        case "Portrait":          return 1
        case "Landscape Flipped": return 2
        case "Portrait Flipped":  return 3
        default:                  return 0  // "Landscape"
        }
    }

    private static func decodeDisplay(_ value: Any) -> Int {
        if let s = value as? String {
            switch s {
            case "primary": return 0
            case "all":     return TabletSettings.displayModeAll
            case "toggle":  return TabletSettings.displayModeToggle
            default:
                // "display-2" → 2
                if s.hasPrefix("display-"), let n = Int(s.dropFirst(8)) { return n }
                return 0
            }
        }
        if let d = value as? [String: Any], (d["mode"] as? String) == "toggle" {
            return TabletSettings.displayModeToggle
        }
        return 0
    }

    private static func decodeTouchRingMode(_ label: String) -> String {
        switch label {
        case "Scroll": return TouchRingMode.scroll.rawValue
        default:       return TouchRingMode.off.rawValue
        }
    }

    private static func decodeExpressKeys(_ labels: [String]) -> String {
        var bindings = labels.map { ButtonBinding.fromDisplayLabel($0) }
        while bindings.count < 16 { bindings.append(.none) }
        let arr = Array(bindings.prefix(16))
        guard let data = try? JSONEncoder().encode(arr),
              let s = String(data: data, encoding: .utf8)
        else { return "" }
        return s
    }

    private static func decodeCurveData(_ d: [String: Any]) -> Data? {
        guard let p1arr = d["p1"] as? [Double], p1arr.count == 2,
              let p2arr = d["p2"] as? [Double], p2arr.count == 2
        else { return nil }
        let curve = BezierCurve(
            p1: CGPoint(x: p1arr[0], y: p1arr[1]),
            p2: CGPoint(x: p2arr[0], y: p2arr[1]))
        return try? JSONEncoder().encode(curve)
    }
}

// MARK: - ImportPreviewSheet

private struct ImportPreviewSheet: View {
    let plan: ImportPlan
    @ObservedObject var registry: DeviceRegistry
    @ObservedObject var tabletManager: TabletManager
    let offlineSettings: [Int: TabletSettings]
    let onDismiss: () -> Void

    /// Product IDs the user has unchecked — these are skipped on import.
    @State private var excluded: Set<Int> = []

    private var includedCount: Int { plan.entries.filter { !excluded.contains($0.productID) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Configuration")
                    .font(.headline)
                if !plan.sourceDate.isEmpty {
                    Text("Exported \(formattedDate(plan.sourceDate))")
                        .font(.settingsLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            Divider()

            // Entry list
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.entries, id: \.productID) { entry in
                        entryRow(entry)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if excluded.contains(entry.productID) {
                                    excluded.remove(entry.productID)
                                } else {
                                    excluded.insert(entry.productID)
                                }
                            }
                    }
                }
                .padding(16)
            }
            .frame(minHeight: 80, maxHeight: 300)

            Divider()

            // Note
            Text("Each tablet's settings will be added as a new profile. Your current settings are not changed until you activate a profile.")
                .font(.settingsLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

            Divider()

            // Buttons
            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(includedCount == 0 ? "Import" : "Import \(includedCount)") {
                    applyImport()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(includedCount == 0)
            }
            .padding(16)
        }
        .frame(width: 420)
    }

    @ViewBuilder
    private func entryRow(_ entry: ImportPlan.TabletEntry) -> some View {
        let isExcluded = excluded.contains(entry.productID)
        let ts: TabletSettings? = tabletManager.contexts[entry.productID]?.settings
            ?? offlineSettings[entry.productID]
        let finalName = ts?.uniqueProfileName(entry.resolvedProfileName)
            ?? entry.resolvedProfileName
        let renamed = finalName != entry.resolvedProfileName

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isExcluded ? "circle" : (entry.isKnown ? "checkmark.circle.fill" : "questionmark.circle"))
                .foregroundStyle(isExcluded ? Color.secondary : (entry.isKnown ? Color.green : Color.orange))
                .frame(width: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.nickname)
                        .fontWeight(.medium)
                        .foregroundStyle(isExcluded ? Color.secondary : Color.primary)
                    Text(entry.modelName)
                        .font(.settingsBadge)
                        .foregroundStyle(.secondary)
                }
                if !isExcluded {
                    HStack(spacing: 4) {
                        Text("→ New profile:")
                            .font(.settingsLabel)
                            .foregroundStyle(.secondary)
                        Text("\"\(finalName)\"")
                            .font(.settingsLabel)
                            .foregroundStyle(renamed ? Color.orange : Color.secondary)
                        if renamed {
                            Text("(renamed to avoid conflict)")
                                .font(.settingsBadge)
                                .foregroundStyle(.orange)
                        }
                    }
                    if !entry.isKnown {
                        Text("Not in your registry — profile will be available when this tablet connects.")
                            .font(.settingsBadge)
                            .foregroundStyle(.orange)
                    }
                    Text("\(entry.profileValues.count) setting\(entry.profileValues.count == 1 ? "" : "s")")
                        .font(.settingsBadge)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Skipped")
                        .font(.settingsLabel)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(isExcluded ? Color(NSColor.separatorColor).opacity(0.5) : Color(NSColor.separatorColor), lineWidth: 1))
        .opacity(isExcluded ? 0.5 : 1.0)
    }

    private func applyImport() {
        for entry in plan.entries where !excluded.contains(entry.productID) {
            let ts: TabletSettings
            if let live = tabletManager.contexts[entry.productID]?.settings {
                ts = live
            } else if let offline = offlineSettings[entry.productID] {
                ts = offline
            } else {
                ts = TabletSettings(productID: entry.productID)
            }
            let name = ts.uniqueProfileName(entry.resolvedProfileName)
            ts.importProfile(name: name, from: entry.profileValues)
        }
        onDismiss()
    }

    private func formattedDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}

// MARK: - ExportDragWell

/// An 80×80 pt well that supports both drag-out (export) and drag-in (import).
/// Drag the document icon out to Finder to save a backup.
/// Drag a .json file onto it to trigger an import.
private struct ExportDragWell: NSViewRepresentable {
    var generateJSON: () -> Data?
    /// Called on the main actor when a JSON file is dropped onto the well.
    var onImport: (Data) -> Void

    func makeNSView(context: Context) -> ExportWellNSView {
        let v = ExportWellNSView()
        v.generateJSON = generateJSON
        v.onImport = onImport
        return v
    }

    func updateNSView(_ nsView: ExportWellNSView, context: Context) {
        nsView.generateJSON = generateJSON
        nsView.onImport = onImport
    }
}

@MainActor
final class ExportWellNSView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var generateJSON: (() -> Data?)?
    var onImport: ((Data) -> Void)?

    private let iconLayer = CALayer()
    private let borderLayer = CAShapeLayer()
    private var isDropTarget = false {
        didSet { updateDropAppearance() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupLayers()
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("public.file-url")])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupLayers() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        // Dashed border
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.separatorColor.cgColor
        borderLayer.lineWidth = 1.5
        borderLayer.lineDashPattern = [6, 4]
        layer?.addSublayer(borderLayer)

        // Document icon
        updateIconSymbol(receiving: false)
        layer?.addSublayer(iconLayer)
    }

    private func updateIconSymbol(receiving: Bool) {
        let name = receiving ? "doc.badge.arrow.down" : "doc.badge.arrow.up"
        let cfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .light)
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) {
            iconLayer.contents = img
            iconLayer.contentsGravity = .resizeAspect
        }
    }

    private func updateDropAppearance() {
        let accent = NSColor.controlAccentColor.cgColor
        let separator = NSColor.separatorColor.cgColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        borderLayer.strokeColor = isDropTarget ? accent : separator
        borderLayer.lineWidth = isDropTarget ? 2.0 : 1.5
        CATransaction.commit()
        updateIconSymbol(receiving: isDropTarget)
    }

    override func layout() {
        super.layout()
        let r = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        borderLayer.path = path.cgPath
        borderLayer.frame = bounds

        let size: CGFloat = 36
        iconLayer.frame = CGRect(
            x: (bounds.width - size) / 2,
            y: (bounds.height - size) / 2,
            width: size, height: size)
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        if !isDropTarget { borderLayer.strokeColor = NSColor.separatorColor.cgColor }
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard jsonURL(from: sender) != nil else { return [] }
        isDropTarget = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard jsonURL(from: sender) != nil else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        guard let url = jsonURL(from: sender),
              let data = try? Data(contentsOf: url)
        else { return false }
        onImport?(data)
        return true
    }

    private func jsonURL(from info: NSDraggingInfo) -> URL? {
        guard let urls = info.draggingPasteboard
                .readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let url = urls.first,
              url.pathExtension.lowercased() == "json"
        else { return nil }
        return url
    }

    // MARK: Drag source

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .copy }

    override func mouseDown(with event: NSEvent) {
        let provider = NSFilePromiseProvider(fileType: "public.json", delegate: self)
        let item = NSDraggingItem(pasteboardWriter: provider)

        // Render the symbol onto a square canvas at its natural size so the
        // dragging item doesn't stretch it to fill an arbitrary frame rect.
        let canvasSize: CGFloat = 44
        let canvas = NSSize(width: canvasSize, height: canvasSize)
        let ghost = NSImage(size: canvas, flipped: false) { rect in
            let cfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .light)
            guard let sym = NSImage(systemSymbolName: "doc.badge.arrow.up", accessibilityDescription: nil)?
                    .withSymbolConfiguration(cfg) else { return true }
            let s = sym.size
            sym.draw(in: CGRect(x: (rect.width - s.width) / 2,
                                y: (rect.height - s.height) / 2,
                                width: s.width, height: s.height))
            return true
        }

        // Frame is in the view's own coordinate space — center over the well.
        item.setDraggingFrame(
            CGRect(x: bounds.midX - canvasSize / 2, y: bounds.midY - canvasSize / 2,
                   width: canvasSize, height: canvasSize),
            contents: ghost)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    // MARK: NSFilePromiseProviderDelegate

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return "MockTab-\(fmt.string(from: Date())).json"
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task { @MainActor in
            guard let data = self.generateJSON?() else { completionHandler(nil); return }
            do {
                try data.write(to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}

// NSBezierPath → CGPath helper (used in ExportWellNSView)
private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &points) {
            case .moveTo:  path.move(to: points[0])
            case .lineTo:  path.addLine(to: points[0])
            case .curveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath: path.closeSubpath()
            default: break
            }
        }
        return path
    }
}
