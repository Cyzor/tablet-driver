// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ProfilesView

/// Full profile management view: preset list, create/rename, auto-switch, summary, and backup/restore.
struct ProfilesView: View {
    @ObservedObject var settings: TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    let instanceKey: DeviceInstanceKey?
    /// Model axis of the bound unit — spec/catalog lookups key on this.
    private var productID: Int? { instanceKey?.productID }

    // Create/rename state
    @State private var isCreating = false
    @State private var newName = ""
    @State private var editingPreset: TabletSettings.Profile?
    @State private var editingName = ""
    @FocusState private var createFieldFocused: Bool

    // Summary + export state
    @State private var summaryExpanded = false

    /// TabletSettings for tablets that aren't currently connected.
    /// Populated lazily in onAppear so we don't rebuild on every render.
    @State private var offlineSettings: [String: TabletSettings] = [:]

    // Import state
    @State private var pendingImport: ImportPlan?
    @State private var importError: String?

    var body: some View {
        SettingsPane(
            settings: settings, tabletManager: tabletManager, registry: registry,
            instanceKey: instanceKey
        ) {
            Section {
                activeBanner
                PresetListView(
                    profiles: settings.profiles,
                    activeProfile: settings.activeProfile,
                    appOverrides: settings.appOverrides,
                    editingPreset: $editingPreset,
                    editingName: $editingName,
                    onActivate: { settings.activate($0) },
                    onDelete: { settings.deletePresetRecordingUndo($0) },
                    onRenameBegin: { editingPreset = $0; editingName = $0.name },
                    onRenameCommit: commitRename,
                    onRenameCancel: { editingPreset = nil; editingName = "" }
                )
            } header: {
                Text("Profiles").appFont(.headline)
            }
            Section {
                createRow
            } header: {
                Text("New Profile").appFont(.headline)
            }
            Section {
                autoSwitchSection
            } header: {
                Text("Auto-Switch").appFont(.headline)
            }
            Section {
                ConfigurationSummaryView(
                    tablets: registry.knownTablets,
                    tabletManager: tabletManager,
                    offlineSettings: offlineSettings,
                    toolsForDevice: { registry.tools(for: $0.instanceKey) },
                    isExpanded: $summaryExpanded
                )
            }
            Section {
                exportSection
            } header: {
                Text("Backup & Restore").appFont(.headline)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Finder-style: a single click outside the field confirms any
            // rename in progress (an empty name reverts to the old one).
            if editingPreset != nil { commitRename() }
        }
        .onAppear { populateOfflineSettings() }
        .onChange(of: registry.knownTablets.count) { _ in populateOfflineSettings() }
        .onReceive(NotificationCenter.default.publisher(for: .mockTabImportData)) { note in
            guard let data = note.userInfo?["data"] as? Data else { return }
            handleImportData(data)
        }
    }

    // MARK: - Offline Settings

    private func populateOfflineSettings() {
        var result: [String: TabletSettings] = [:]
        for tablet in registry.knownTablets {
            if tabletManager.context(for: tablet) == nil {
                result[tablet.id] = TabletSettings(instanceKey: tablet.instanceKey)
            }
        }
        offlineSettings = result
    }

    // MARK: - Active Banner

    @ViewBuilder
    private var activeBanner: some View {
        if let active = settings.activeProfile {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Active profile:")
                    .appFont(.headline)
                Text(active.name)
                    .appFont(.settingsLabel)
                    .fontWeight(.medium)
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Create Row

    private var createRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isCreating {
                HStack(spacing: 8) {
                    TextField("Profile name", text: $newName)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 200)
                        .focused($createFieldFocused)
                        .onSubmit { commitCreate() }
                        .onAppear { createFieldFocused = true }

                    Button("Create") { commitCreate() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Save this new profile with the current settings")

                    Button("Cancel") {
                        isCreating = false
                        newName = ""
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
                    .help("Cancel creating a new profile")
                }
            } else {
                Button {
                    isCreating = true
                    newName = ""
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .accessibilityHidden(true)
                        Text(
                            String(
                                localized: "Create Profile",
                                comment: "Button to create a new profile"))
                    }
                }
                .buttonStyle(.bordered)
                .help("Save the current settings as a new profile")
            }
        }
    }

    // MARK: - Auto-Switch Section

    @ViewBuilder
    private var autoSwitchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                String(
                    localized:
                        "Automatically switch to the matching profile when this tablet connects",
                    comment: "Toggle: auto-activate profile when tablet connects"),
                isOn: settings.recordingBinding(
                    "Auto-Switch",
                    get: { settings.autoSwitchEnabled },
                    set: { settings.autoSwitchEnabled = $0 }
                )
            )
            .appFont(.settingsLabel)
            .help("Restore the active profile automatically when this tablet is connected")
        }
    }

    // MARK: - Export Section

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                String(
                    localized:
                        "Export your current configuration as a JSON file. You can restore it later if settings get reset or corrupted.",
                    comment: "Description of the backup/export functionality")
            )
            .appFont(.settingsLabel)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                BackupRestoreWell(
                    generateJSON: {
                        PresetExporter(registry: registry, tabletManager: tabletManager).export()
                    },
                    onExport: saveExportToFile,
                    onImportData: handleImportData,
                    onImportPicker: openImportPanel
                )
                .frame(width: 80, height: 80)

                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        String(
                            localized: "Drag out to save a backup. Drag a .json file in to import.",
                            comment: "Description of export/import drag-and-drop functionality")
                    )
                    .appFont(.settingsLabel)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Export as JSON…") { saveExportToFile() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Save all profiles and settings to a JSON backup file")

                        Button("Import from File…") { openImportPanel() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Restore settings from a previously saved JSON backup")
                    }

                    if let err = importError {
                        Text(err)
                            .appFont(.settingsBadge)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .sheet(item: $pendingImport) { plan in
            ImportPreviewSheet(
                plan: plan,
                registry: registry,
                tabletManager: tabletManager,
                currentPaneSettings: settings,
                currentPaneProductID: productID,
                offlineSettings: offlineSettings
            ) {
                pendingImport = nil
            }
        }
    }

    private struct BackupRestoreWell: View {
        let generateJSON: () -> Data?
        let onExport: () -> Void
        let onImportData: (Data) -> Void
        let onImportPicker: () -> Void

        @State private var isDropTargeted = false
        @State private var isHovering = false

        var body: some View {
            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor))

                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isDropTargeted
                                ? Color.accentColor
                                : Color(NSColor.separatorColor),
                            lineWidth: isDropTargeted ? 2 : 1
                        )

                    VStack(spacing: 6) {
                        Image(systemName: "document.badge.gearshape.fill")
                            .appFont(size: 26, weight: .semibold)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(isDropTargeted ? Color.accentColor : Color.primary)
                            .offset(x: 4)
                            .accessibilityHidden(true)

                        Text(
                            String(
                                localized: "JSON",
                                comment: "Short label inside backup/restore tile")
                        )
                        .appFont(.settingsBadge)
                        .foregroundStyle(.secondary)
                    }
                    .padding(10)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("JSON backup tile — drag out to export, drop a JSON file in to import")
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onHover { hovering in
                    isHovering = hovering
                }
                .onDrop(of: [.json], isTargeted: $isDropTargeted) { providers in
                    guard let provider = providers.first else { return false }
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.json.identifier) { data, _ in
                        guard let data else { return }
                        DispatchQueue.main.async { onImportData(data) }
                    }
                    return true
                }
                .onDrag {
                    guard let data = generateJSON() else { return NSItemProvider() }
                    let provider = NSItemProvider()
                    provider.registerDataRepresentation(
                        forTypeIdentifier: UTType.json.identifier,
                        visibility: .all
                    ) { completion in
                        completion(data, nil)
                        return nil
                    }
                    provider.suggestedName = defaultFilename
                    return provider
                }
                .contextMenu {
                    Button {
                        onExport()
                    } label: {
                        Label(
                            String(
                                localized: "Export as JSON…",
                                comment: "Context menu action for exporting backup"),
                            systemImage: "square.and.arrow.up")
                    }
                    Button {
                        onImportPicker()
                    } label: {
                        Label(
                            String(
                                localized: "Import from File…",
                                comment: "Context menu action for importing backup"),
                            systemImage: "square.and.arrow.down")
                    }
                }
                .help(
                    String(
                        localized: "Drag out to export a backup, drag in a JSON file to import, or Control-click for actions.",
                        comment: "Help text for backup/restore tile")
                )
            }
        }

        private var defaultFilename: String {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            return "MockTab-\(fmt.string(from: Date())).json"
        }
    }

    private func saveExportToFile() {
        let exporter = PresetExporter(registry: registry, tabletManager: tabletManager)
        guard let data = exporter.export() else { return }
        let panel = NSSavePanel()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "MockTab-\(fmt.string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    // MARK: - Import

    private func handleImportData(_ data: Data) {
        importError = nil
        do {
            let plan = try PresetImporter.parse(data, registry: registry)
            pendingImport = plan
        } catch let e as PresetImporter.ParseError {
            importError = e.localizedDescription
        } catch {
            importError = String(
                localized: "Could not read file.",
                comment: "Error message when import file cannot be read")
        }
    }

    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = String(
            localized: "Choose a MockTab backup file to import",
            comment: "File picker message for importing backup")
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

        let snap = settings.snapshot()
        settings.saveAsPreset(name: trimmed)

        if let newPreset = settings.profiles.last(where: { $0.name == trimmed }) {
            recordSaveProfile(created: newPreset, previousSnapshot: snap, name: trimmed)
        }

        isCreating = false
        newName = ""
    }

    /// Self-recursive so "Save Profile" also redoes: undoing deletes the
    /// preset just created and restores the prior settings snapshot; that
    /// closure then re-creates an equivalent preset (same name, new UUID —
    /// exact identity isn't preserved, but the visible result is) and
    /// re-registers itself with the roles swapped, same shape as
    /// `TabletSettings.restoreSnapshot`.
    private func recordSaveProfile(created preset: TabletSettings.Profile, previousSnapshot snap: TabletSettings.FullSnapshot, name: String) {
        settings.record("Save Profile") {
            let currentSnap = self.settings.snapshot()
            self.settings.deletePreset(preset)
            self.settings.applySnapshot(snap)
            self.settings.saveAsPreset(name: name)
            if let recreated = self.settings.profiles.last(where: { $0.name == name }) {
                self.recordSaveProfile(created: recreated, previousSnapshot: currentSnap, name: name)
            }
        }
    }

    private func commitRename() {
        guard let preset = editingPreset else { return }
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let oldName = preset.name
            let presetID = preset.id
            settings.renamePreset(preset, to: trimmed)
            // `Profile`'s Equatable compares every field (including `name`),
            // and `renamePreset` looks its target up by value equality — so
            // a stale captured `preset` (old name) would stop matching after
            // the first rename. Re-fetch the live profile by id each time
            // this fires, so repeated undo/redo cycles keep working.
            settings.recordToggle("Rename Profile", from: oldName, to: trimmed) { name in
                guard let current = settings.profiles.first(where: { $0.id == presetID }) else { return }
                settings.renamePreset(current, to: name)
            }
        }
        editingPreset = nil
    }
}

// MARK: - PresetListView

/// Isolated preset list: only re-evaluates body when profiles, activeProfile, or appOverrides
/// change — insulated from 133 Hz driver updates and unrelated ProfilesView state changes.
private struct PresetListView: View {
    let profiles: [TabletSettings.Profile]
    let activeProfile: TabletSettings.Profile?
    let appOverrides: [TabletSettings.AppOverride]
    @Binding var editingPreset: TabletSettings.Profile?
    @Binding var editingName: String
    let onActivate: (TabletSettings.Profile) -> Void
    let onDelete: (TabletSettings.Profile) -> Void
    let onRenameBegin: (TabletSettings.Profile) -> Void
    let onRenameCommit: () -> Void
    let onRenameCancel: () -> Void

    @FocusState private var editFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if profiles.isEmpty {
                Text(
                    String(
                        localized: "No profiles yet. Create one below.",
                        comment: "Empty state message when no profiles exist")
                )
                .appFont(.settingsLabel)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 4)
            } else {
                ForEach(profiles, id: \.id) { preset in
                    presetRow(preset)
                }
            }
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: TabletSettings.Profile) -> some View {
        let isActive = activeProfile?.id == preset.id
        let isEditing = editingPreset?.id == preset.id

        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.green : Color.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            // Renaming swaps only the name Text for a plain-style TextField
            // with the same metrics (Finder-style): no border chrome, no
            // inline buttons, so nothing in the row moves. Return commits,
            // Esc cancels, click-away commits.
            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TextField("Profile name", text: $editingName)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.leading)
                        .focused($editFieldFocused)
                        .renameFieldRing()
                        .onSubmit { onRenameCommit() }
                        .onExitCommand { onRenameCancel() }
                        .onAppear { focusAndSelectAll() }
                } else {
                    Text(preset.name)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                }

                if !preset.overriddenKeys.isEmpty {
                    Text(String(localized: "\(preset.overriddenKeys.count) setting", comment: "Count of overridden settings in a profile"))
                    .appFont(.settingsBadge)
                    .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isActive {
                Button("Activate") { onActivate(preset) }
                    .controlSize(.small)
                    .help("Switch to this profile immediately")
            } else {
                Text(String(localized: "Active", comment: "Badge label when profile is active"))
                    .appFont(.settingsBadge)
                    .foregroundStyle(.green)
            }

            if !preset.overriddenKeys.isEmpty {
                appBindingsForPreset(preset)
            }

            Menu {
                menuEntries(preset)
            } label: {
                Image(systemName: "ellipsis")
                    .appFont(.settingsBadge)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .accessibilityHidden(true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .accessibilityLabel("Profile actions")
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .contextMenu { menuEntries(preset) }
    }

    /// Shared entries for the row's "…" flyout and right-click context menu.
    @ViewBuilder
    private func menuEntries(_ preset: TabletSettings.Profile) -> some View {
        Button { onRenameBegin(preset) } label: {
            Label("Rename", systemImage: "pencil")
        }
        .help("Edit the profile name")
        Divider()
        Button(role: .destructive) { onDelete(preset) } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(preset.name == "Default")
        .help("Permanently delete this profile (cannot be undone)")
    }

    /// Focuses the rename text field and selects its full contents so the user
    /// can immediately type a replacement. Called from the field's `.onAppear`.
    private func focusAndSelectAll() {
        editFieldFocused = true
        DispatchQueue.main.async {
            NSApp.keyWindow?.firstResponder?
                .tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
        }
    }

    @ViewBuilder
    private func appBindingsForPreset(_ preset: TabletSettings.Profile) -> some View {
        let overrideApps = appOverrides.filter {
            $0.overriddenKeys.intersection(preset.overriddenKeys).isEmpty == false
        }
        if !overrideApps.isEmpty {
            HStack(spacing: 4) {
                ForEach(overrideApps, id: \.bundleID) { override in
                    appIcon(bundleID: override.bundleID)
                        .help(override.appName)
                }
            }
        }
    }

    @ViewBuilder
    private func appIcon(bundleID: String) -> some View {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }),
            let icon = app.icon
        {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: "app")
                .appFont(.settingsBadge)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - ConfigurationSummaryView

/// Isolated device summary: re-evaluates only when the tablet list or offline settings change,
/// not on every ProfilesView state change.
private struct ConfigurationSummaryView: View {
    let tablets: [DeviceRegistry.KnownTablet]
    let tabletManager: TabletManager
    let offlineSettings: [String: TabletSettings]
    let toolsForDevice: (DeviceRegistry.KnownTablet) -> [DeviceRegistry.KnownTool]
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureRow(
            label: String(
                localized: "Device Summary", comment: "Disclosure row label in Profiles tab"),
            isExpanded: $isExpanded
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(tablets, id: \.id) { tablet in
                    tabletSummaryCard(tablet)
                }
            }
        }
    }

    @ViewBuilder
    private func tabletSummaryCard(_ tablet: DeviceRegistry.KnownTablet) -> some View {
        let ts: TabletSettings =
            tabletManager.context(for: tablet)?.settings
            ?? offlineSettings[tablet.id]
            ?? TabletSettings(instanceKey: tablet.instanceKey)
        let nonDefault = deviceNonDefaultLines(ts)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(tablet.nickname)
                    .appFont(.settingsLabel)
                    .fontWeight(.medium)
                Text(tablet.modelName)
                    .appFont(.settingsBadge)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(
                    ts.profiles.count == 0
                        ? String(localized: "No profiles", comment: "Badge text when tablet has no profiles")
                        : String(localized: "\(ts.profiles.count) profile", comment: "Count of profiles for a tablet")
                )
                .appFont(.settingsBadge)
                .foregroundStyle(.tertiary)
            }

            if !nonDefault.isEmpty {
                ForEach(nonDefault, id: \.self) { line in
                    Text(line)
                        .appFont(.settingsBadge)
                        .foregroundStyle(.secondary)
                }
            }

            let tools = toolsForDevice(tablet)
            if !tools.isEmpty {
                ForEach(tools, id: \.id) { tool in
                    toolSummaryRow(tool, deviceSettings: ts, isLast: tool.id == tools.last?.id)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func toolSummaryRow(
        _ tool: DeviceRegistry.KnownTool, deviceSettings: TabletSettings, isLast: Bool
    ) -> some View {
        let t = deviceSettings.toolSettings(forID: tool.id)
        let nonDefault = toolNonDefaultLines(t)
        let toolKind =
            tool.kind.lowercased() == "pen"
            ? String(localized: "Pen", comment: "Tool type: pen")
            : (tool.kind.lowercased() == "eraser"
                ? String(localized: "Eraser", comment: "Tool type: eraser")
                : String(localized: "Tool", comment: "Tool type: generic"))

        HStack(alignment: .top, spacing: 8) {
            Text(toolKind)
                .appFont(.settingsBadge)
                .foregroundStyle(.secondary)
                .scaledFrame(width: 50, alignment: .leading)
            Text(tool.nickname.isEmpty ? tool.displayID : tool.nickname)
                .appFont(.settingsBadge)
                .foregroundStyle(.secondary)
            if !nonDefault.isEmpty {
                Text(
                    "(\(nonDefault.joined(separator: String(localized: ", ", comment: "List separator"))))"
                )
                .appFont(.settingsBadge)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 8)
        .padding(.bottom, isLast ? 0 : 4)
    }

    private func deviceNonDefaultLines(_ s: TabletSettings) -> [String] {
        var lines: [String] = []
        if s.activeAreaX != 0 || s.activeAreaY != 0 {
            lines.append(String(localized: "area offset", comment: "Device summary: area offset"))
        }
        if s.activeAreaWidth != 1.0 || s.activeAreaHeight != 1.0 {
            lines.append(String(localized: "area scaled", comment: "Device summary: area scaled"))
        }
        if s.targetDisplayIndex != 0 {
            lines.append(
                String(
                    localized: "display != primary", comment: "Device summary: non-primary display")
            )
        }
        if s.pressureCurve.p1 != CGPoint(x: 0, y: 0) || s.pressureCurve.p2 != CGPoint(x: 1, y: 1) {
            lines.append(
                String(localized: "pressure curve", comment: "Device summary: pressure curve"))
        }
        if s.proportionalMapping {
            lines.append(
                String(localized: "proportional", comment: "Device summary: proportional mapping"))
        }
        if s.invertRotation {
            lines.append(
                String(localized: "rotation inverted", comment: "Device summary: rotation inverted")
            )
        }
        return lines
    }

    private func toolNonDefaultLines(_ t: ToolSettings) -> [String] {
        var lines: [String] = []
        if t.pressureCurve.p1 != CGPoint(x: 0, y: 0) || t.pressureCurve.p2 != CGPoint(x: 1, y: 1) {
            lines.append(String(localized: "curve", comment: "Tool summary: pressure curve"))
        }
        if t.tipBinding != .leftClick {
            lines.append(
                String(localized: "tip ≠ default", comment: "Tool summary: non-default tip binding")
            )
        }
        if t.eraserBinding != .eraser {
            lines.append(
                String(
                    localized: "eraser ≠ default",
                    comment: "Tool summary: non-default eraser binding"))
        }
        return lines
    }
}
