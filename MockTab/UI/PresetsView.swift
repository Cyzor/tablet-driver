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

import SwiftUI

/// Profiles tab — lets the user create, activate, rename, and delete named
/// configuration snapshots for the current device, and bind specific apps
/// to profiles so they switch automatically on focus.
///
/// Each profile stores only the keys that were explicitly changed while it was
/// active; everything else falls through to the device defaults at read time.
struct ProfilesView: View {
    @ObservedObject var settings: TabletSettings

    @State private var isCreating = false
    @State private var newName = ""
    @State private var editingPreset: TabletSettings.Preset? = nil
    @State private var editingName = ""

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
                }
                .padding()
            }
            PresetStatusBar(settings: settings)
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
