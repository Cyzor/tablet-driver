import SwiftUI

/// Presets tab — lets the user create, activate, rename, and delete named
/// configuration snapshots for the current device, and bind specific apps
/// to presets so they switch automatically on focus.
///
/// Each preset stores only the keys that were explicitly changed while it was
/// active; everything else falls through to the device defaults at read time.
struct PresetsView: View {
    @ObservedObject var settings: TabletSettings

    @State private var isCreating    = false
    @State private var newName       = ""
    @State private var editingPreset: TabletSettings.Preset? = nil
    @State private var editingName   = ""

    var body: some View {
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if settings.activePreset != nil {
                Button("Deactivate") { settings.activate(nil) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1))
    }

    // MARK: - Preset list

    @ViewBuilder
    private var presetList: some View {
        if settings.presets.isEmpty {
            Text("No presets yet.\nUse the button below to save the current settings as a named snapshot.")
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
            .overlay(RoundedRectangle(cornerRadius: 6)
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
                    settings.activate(isActive ? nil : preset)
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
                        Text("\(preset.overriddenKeys.count) override\(preset.overriddenKeys.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Row action buttons
                if editingPreset?.id == preset.id {
                    Button("Save")   { commitRename() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Cancel") { editingPreset = nil }
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button {
                        editingPreset = preset
                        editingName   = preset.name
                    } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Rename")

                    Button(role: .destructive) { settings.deletePreset(preset) }
                        label: { Image(systemName: "trash") }
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
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(bound) { binding in
                    HStack(spacing: 6) {
                        appIcon(bundleID: binding.bundleID)
                        Text(binding.appName)
                            .font(.caption)
                        Spacer()
                        Button {
                            settings.unbindApp(bundleID: binding.bundleID)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove binding")
                    }
                }
            }
            Button {
                settings.bindFrontmostApp(to: preset)
            } label: {
                Label("Bind current app", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Assigns the currently frontmost app to this preset")
        }
    }

    @ViewBuilder
    private func appIcon(bundleID: String) -> some View {
        if let path  = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path,
           let icon  = NSWorkspace.shared.icon(forFile: path) as NSImage? {
            Image(nsImage: icon)
                .resizable().scaledToFit()
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "app")
                .font(.caption2)
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
                Button("Cancel") { isCreating = false; newName = "" }
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
            Toggle(isOn: $settings.autoSwitchEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-switch preset by app")
                        .fontWeight(.medium)
                    Text("When enabled, switching to a bound app automatically activates its preset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if settings.autoSwitchEnabled && !settings.appBindings.isEmpty {
                Text("App bindings appear under each preset above.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Actions

    private func commitCreate() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.saveAsPreset(name: trimmed)
        isCreating = false
        newName    = ""
    }

    private func commitRename() {
        guard let preset = editingPreset else { return }
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { settings.renamePreset(preset, to: trimmed) }
        editingPreset = nil
    }
}
