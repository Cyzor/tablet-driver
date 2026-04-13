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
    @State private var editingPreset: TabletSettings.Preset? = nil
    @State private var editingName = ""

    // Summary + export state
    @State private var summaryExpanded = false
    /// TabletSettings instances for tablets that aren't currently connected.
    /// Populated lazily in onAppear so we don't rebuild on every render.
    @State private var offlineSettings: [Int: TabletSettings] = [:]

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
            Image(systemName: settings.activePreset == nil ? "star" : "star.fill")
                .foregroundStyle(settings.activePreset == nil ? Color.secondary : Color.yellow)
            VStack(alignment: .leading, spacing: 2) {
                if let preset = settings.activePreset {
                    Text("Active: \(preset.name)").fontWeight(.medium)
                } else {
                    Text("Device defaults — no preset active").foregroundStyle(.secondary)
                }
                if case .app(_, let appName) = settings.activationSource {
                    Text("Auto-switched by \(appName)")
                        .font(.settingsLabel)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if settings.activePreset != nil {
                Button("Deactivate") {
                    // Capture snapshot before deactivating so we can undo
                    let snap = settings.snapshot()
                    settings.activate(nil)
                    settings.restoreSnapshot(snap, actionName: "Deactivate Preset")
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
        if settings.presets.isEmpty {
            Text(
                "No presets yet.\nUse the button below to save the current settings as a named snapshot."
            )
            .foregroundStyle(.secondary)
            .font(.callout)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            VStack(spacing: 0) {
                ForEach(settings.presets) { preset in
                    presetRow(preset)
                    if preset.id != settings.presets.last?.id {
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
    private func presetRow(_ preset: TabletSettings.Preset) -> some View {
        let isActive = settings.activePreset?.id == preset.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Activation toggle
                Button {
                    // Capture snapshot before activating so we can undo
                    let snap = settings.snapshot()
                    settings.activate(isActive ? nil : preset)
                    settings.restoreSnapshot(snap, actionName: "Activate Preset")
                } label: {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .imageScale(.large)
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)

                // Name — inline edit while renaming
                if editingPreset?.id == preset.id {
                    TextField("Preset name", text: $editingName)
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
                        settings.restoreSnapshot(snap, actionName: "Delete Preset")
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
    private func appBindingsForPreset(_ preset: TabletSettings.Preset) -> some View {
        let bound = settings.appBindings.filter { $0.presetID == preset.id }
        VStack(alignment: .leading, spacing: 4) {
            if bound.isEmpty {
                Text("No apps bound to this preset")
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
            .help("Assigns the currently frontmost app to this preset")
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
                TextField("New preset name", text: $newName)
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
                Label("Save current settings as preset…", systemImage: "plus.circle")
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
                    Text("Auto-switch preset by app")
                        .fontWeight(.medium)
                    Text(
                        "When enabled, switching to a bound app automatically activates its preset."
                    )
                    .font(.settingsLabel)
                    .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if settings.autoSwitchEnabled && !settings.appBindings.isEmpty {
                Text("App bindings appear under each preset above.")
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
                ExportDragWell(generateJSON: buildExportData)
                    .frame(width: 80, height: 80)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Drag to the Finder to save a backup, or use the button below.")
                        .font(.settingsLabel)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Export as JSON…") { saveExportToFile() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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

        let presets = ts.presets.map { exportPreset($0, activeID: ts.activePreset?.id, devicePrefix: devicePrefix) }
        if !presets.isEmpty { d["presets"] = presets }

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
        _ preset: TabletSettings.Preset,
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

    // MARK: - Actions

    private func commitCreate() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Capture snapshot before creating preset so we can undo
        let snap = settings.snapshot()
        settings.saveAsPreset(name: trimmed)
        // Register undo that deletes the new preset
        if let newPreset = settings.presets.last(where: { $0.name == trimmed }) {
            let presetToDelete = newPreset
            let snapshotForUndo = snap
            settings.record("Save Preset") {
                settings.deletePreset(presetToDelete)
                settings.restoreSnapshot(snapshotForUndo, actionName: "Undo Save Preset")
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
            settings.record("Rename Preset") {
                settings.renamePreset(presetForUndo, to: nameForUndo)
            }
        }
        editingPreset = nil
    }
}

// MARK: - ExportDragWell

/// An 80×80 pt drag well.  The user can drag the document icon out to Finder
/// to save a JSON backup, or click nowhere — the Export button below the well
/// handles the save-panel path.
private struct ExportDragWell: NSViewRepresentable {
    var generateJSON: () -> Data?

    func makeNSView(context: Context) -> ExportWellNSView {
        let v = ExportWellNSView()
        v.generateJSON = generateJSON
        return v
    }

    func updateNSView(_ nsView: ExportWellNSView, context: Context) {
        nsView.generateJSON = generateJSON
    }
}

@MainActor
final class ExportWellNSView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var generateJSON: (() -> Data?)?

    private let iconLayer = CALayer()
    private let borderLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setupLayers()
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
        let cfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .light)
        if let img = NSImage(systemSymbolName: "doc.badge.arrow.up", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            iconLayer.contents = img
            iconLayer.contentsGravity = .resizeAspect
        }
        layer?.addSublayer(iconLayer)
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
        borderLayer.strokeColor = NSColor.separatorColor.cgColor
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
