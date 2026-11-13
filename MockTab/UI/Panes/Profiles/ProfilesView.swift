// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import TabletKit
import UniformTypeIdentifiers

// MARK: - ProfilesView

/// Full profile management view: profile list, create/rename, auto-switch, summary, and backup/restore.
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
    @State private var editingProfile: TabletSettings.Profile?
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
        let _ = BodyCounter.note("Profiles")
        SettingsPane(
            settings: settings, tabletManager: tabletManager, registry: registry,
            instanceKey: instanceKey
        ) {
            Section {
                activeBanner
                ProfileListView(
                    profiles: settings.profiles,
                    activeProfile: settings.activeProfile,
                    appOverrides: settings.appOverrides,
                    editingProfile: $editingProfile,
                    editingName: $editingName,
                    onActivate: { settings.activate($0) },
                    onDelete: { settings.deleteProfileRecordingUndo($0) },
                    onDeleteAll: { settings.deleteAllProfilesRecordingUndo() },
                    // Deferred a turn, as in the Devices pane: landing the field
                    // in the same turn as the gesture's own state changes loses
                    // the focus/select-all trigger in `.onAppear`.
                    onRenameBegin: { preset in
                        // Finder-style: starting one rename confirms another.
                        if editingProfile != nil { commitRename() }
                        DispatchQueue.main.async {
                            editingProfile = preset
                            editingName = preset.name
                        }
                    },
                    onRenameCommit: commitRename,
                    onRenameCancel: { editingProfile = nil; editingName = "" }
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
            if editingProfile != nil { commitRename() }
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
                        // Deferred a turn: requesting focus in the same turn
                        // the field is inserted has been landing before the
                        // field can take it, leaving it visible but unfocused.
                        .onAppear { DispatchQueue.main.async { createFieldFocused = true } }

                    Button("Create") { commitCreate() }
                        .buttonStyle(.borderedProminent)
                        .appControlSize(.small)
                        .fixedSize()
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Save this new profile with the current settings")

                    Button("Cancel") {
                        isCreating = false
                        newName = ""
                    }
                    .appControlSize(.small)
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

    // MARK: - Export Section

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                String(
                    localized:
                        "Export current configuration as a JSON file.",
                    comment: "Description of the backup/export functionality")
            )
            .appFont(.settingsLabel)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                BackupRestoreWell(
                    generateJSON: {
                        ConfigurationExporter(registry: registry, tabletManager: tabletManager).export()
                    },
                    onExport: saveExportToFile,
                    onImportData: handleImportData,
                    onImportPicker: openImportPanel
                )
                .frame(width: 80, height: 80)

                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        String(
                            localized: "Drag out to save. Drag in to restore.",
                            comment: "Description of export/import drag-and-drop functionality")
                    )
                    .appFont(.settingsLabel)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Export as JSON…") { saveExportToFile() }
                            .buttonStyle(.bordered)
                            .appControlSize(.small)
                            .help("Save all profiles and settings to a JSON backup file")

                        Button("Import from File…") { openImportPanel() }
                            .buttonStyle(.bordered)
                            .appControlSize(.small)
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
                        Image(systemName: "doc.badge.gearshape.fill")
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
                .accessibilityLabel("Backup file")
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
                // A file promise, since Finder on macOS 13 makes nothing from
                // a data-only SwiftUI drag.
                .overlay(BackupFileDragSource(
                    fileName: ConfigurationExporter.suggestedFileBaseName + ".json",
                    makeData: generateJSON))
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
    }

    private func saveExportToFile() {
        let exporter = ConfigurationExporter(registry: registry, tabletManager: tabletManager)
        guard let data = exporter.export() else { return }
        BackupFilePanel.save(data)
    }

    // MARK: - Import

    private func handleImportData(_ data: Data) {
        importError = nil
        do {
            let plan = try ConfigurationImporter.parse(data, registry: registry)
            pendingImport = plan
        } catch let e as ConfigurationImporter.ParseError {
            importError = e.localizedDescription
        } catch {
            importError = String(
                localized: "Could not read file.",
                comment: "Error message when import file cannot be read")
        }
    }

    private func openImportPanel() {
        BackupFilePanel.open { handleImportData($0) }
    }

    // MARK: - Actions

    private func commitCreate() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let snap = settings.snapshot()
        settings.saveAsProfile(name: trimmed)

        if let newPreset = settings.profiles.last(where: { $0.name == trimmed }) {
            recordSaveProfile(created: newPreset, previousSnapshot: snap, name: trimmed)
        }

        isCreating = false
        newName = ""
    }

    /// Self-recursive so "Save Profile" also redoes: undoing deletes the
    /// profile just created and restores the prior settings snapshot; that
    /// closure then re-creates an equivalent profile (same name, new UUID —
    /// exact identity isn't preserved, but the visible result is) and
    /// re-registers itself with the roles swapped, same shape as
    /// `TabletSettings.restoreSnapshot`.
    private func recordSaveProfile(created preset: TabletSettings.Profile, previousSnapshot snap: TabletSettings.FullSnapshot, name: String) {
        settings.record(String(localized: "Save Profile", comment: "Undo action name: creating a new named preset in the Profiles pane")) {
            let currentSnap = self.settings.snapshot()
            self.settings.deleteProfile(preset)
            self.settings.applySnapshot(snap)
            self.settings.saveAsProfile(name: name)
            if let recreated = self.settings.profiles.last(where: { $0.name == name }) {
                self.recordSaveProfile(created: recreated, previousSnapshot: currentSnap, name: name)
            }
        }
    }

    private func commitRename() {
        guard let preset = editingProfile else { return }
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let oldName = preset.name
            let presetID = preset.id
            settings.renameProfile(preset, to: trimmed)
            // `Profile`'s Equatable compares every field (including `name`),
            // and `renameProfile` looks its target up by value equality — so
            // a stale captured `preset` (old name) would stop matching after
            // the first rename. Re-fetch the live profile by id each time
            // this fires, so repeated undo/redo cycles keep working.
            settings.recordToggle(String(localized: "Rename Profile", comment: "Undo action name: renaming a preset in the Profiles pane"), from: oldName, to: trimmed) { name in
                guard let current = settings.profiles.first(where: { $0.id == presetID }) else { return }
                settings.renameProfile(current, to: name)
            }
        }
        editingProfile = nil
    }
}

// MARK: - ProfileListView

/// Isolated profile list: only re-evaluates body when profiles, activeProfile, or appOverrides
/// change — insulated from 133 Hz driver updates and unrelated ProfilesView state changes.
private struct ProfileListView: View {
    let profiles: [TabletSettings.Profile]
    let activeProfile: TabletSettings.Profile?
    let appOverrides: [TabletSettings.AppOverride]
    @Binding var editingProfile: TabletSettings.Profile?
    @Binding var editingName: String
    let onActivate: (TabletSettings.Profile) -> Void
    let onDelete: (TabletSettings.Profile) -> Void
    let onDeleteAll: () -> Void
    let onRenameBegin: (TabletSettings.Profile) -> Void
    let onRenameCommit: () -> Void
    let onRenameCancel: () -> Void

    @FocusState private var editFieldFocused: Bool
    /// Before macOS 15: Option held when a row menu opens turns Delete into
    /// Delete All. The menu doesn't change while open, so the item does what
    /// it shows.
    @State private var optionKeyDown = false

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
                    profileRow(preset)
                }
            }
        }
        .tracksOptionKey($optionKeyDown, watchKeys: {
            if #available(macOS 15, *) { return false }
            return true
        }())
    }

    @ViewBuilder
    private func profileRow(_ preset: TabletSettings.Profile) -> some View {
        let isActive = activeProfile?.id == preset.id
        let isEditing = editingProfile?.id == preset.id

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
                    .appControlSize(.small)
                    .help("Switch to this profile immediately")
            } else {
                Text(String(localized: "Active", comment: "Badge label when profile is active"))
                    .appFont(.settingsBadge)
                    .foregroundStyle(.green)
            }

            if !preset.overriddenKeys.isEmpty {
                overrideAppsForProfile(preset)
            }

            RowActionsMenu(accessibilityLabel: "Profile actions", subject: preset.name) {
                menuEntries(preset)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
        )
        // Double-click renames, matching the Devices pane rows. Masked off
        // while editing so the row gesture can't take the field's clicks —
        // see `rowTapHandling`.
        .rowTapHandling(active: !isEditing) { row, mask in
            row.gesture(TapGesture(count: 2).onEnded { onRenameBegin(preset) }, including: mask)
        }
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
        // macOS 15 swaps the item live while the menu is open. Earlier
        // systems decide when the menu opens, from `optionKeyDown`.
        if #available(macOS 15, *) {
            deleteButton(preset).modifierKeyAlternate(.option) { deleteAllButton }
        } else if optionKeyDown {
            deleteAllButton
        } else {
            deleteButton(preset)
        }
    }

    // `onDelete` is `deleteProfileRecordingUndo`, which snapshots the
    // profile's stored values and its list position, so deleting really is
    // undoable.
    private func deleteButton(_ preset: TabletSettings.Profile) -> some View {
        Button(role: .destructive) { onDelete(preset) } label: {
            Label("Delete", systemImage: "trash")
        }
        .help("Delete this profile (undoable).")
    }

    private var deleteAllButton: some View {
        Button(role: .destructive) { onDeleteAll() } label: {
            Label(String(localized: "Delete All", comment: "Profile row menu item while Option is held: deletes every profile for this tablet"), systemImage: "trash")
        }
        .help(String(localized: "Delete every profile for this tablet (undoable).", comment: "Help: Option-click Delete All in the profile row menu"))
    }

    /// Focuses the rename text field and selects its full contents so the user
    /// can immediately type a replacement. Called from the field's `.onAppear`.
    private func focusAndSelectAll() {
        editFieldFocused = true
        selectAllInFocusedRenameField()
    }

    @ViewBuilder
    private func overrideAppsForProfile(_ preset: TabletSettings.Profile) -> some View {
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
    /// Screenshot aid, as in the Devices pane: Option-Shift-click a card.
    @State private var decoyingIDs = false

    var body: some View {
        DisclosureRow(
            label: String(
                localized: "Device Summary", comment: "Disclosure row label in Profiles tab"),
            isExpanded: $isExpanded
        ) {
            VStack(alignment: .leading, spacing: 10) {
                // A companion such as the Quick Keys puck has no pens, so
                // it would get an empty card.
                ForEach(tablets.filter { TabletManager.staticSpec(forProductID: $0.productID)?.isAuxOnly != true }, id: \.id) { tablet in
                    tabletSummaryCard(tablet)
                        .gesture(TapGesture().modifiers([.option, .shift]).onEnded { decoyingIDs.toggle() })
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
                    .appFont(.headline)
                    .lineLimit(1)
                Text(tablet.modelName)
                    .appFont(.settingsLabel)
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
                        .appFont(.settingsLabel)
                        .foregroundStyle(.secondary)
                }
            }

            let tools = Self.summaryTools(toolsForDevice(tablet))
            let apps = ts.appOverrides.compactMap { o -> (name: String, lines: [String])? in
                let lines = overrideLines(o, in: ts)
                return lines.isEmpty ? nil : (o.appName, lines)
            }
            if !tools.isEmpty {
                let repeated = Self.repeatedNicknames(tools)
                ForEach(tools, id: \.id) { tool in
                    toolSummaryRow(
                        tool, deviceSettings: ts, showsID: repeated.contains(tool.nickname),
                        isLast: apps.isEmpty && tool.id == tools.last?.id)
                }
            }
            ForEach(Array(apps.enumerated()), id: \.offset) { i, app in
                summaryRow(
                    kind: String(localized: "App", comment: "Profiles summary: row kind for an app's override"),
                    name: app.name, shownID: nil, details: app.lines, isLast: i == apps.count - 1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// An eraser end uses its pen's settings, so it gets no row of its own
    /// unless its pen hasn't been seen.
    static func summaryTools(_ tools: [DeviceRegistry.KnownTool]) -> [DeviceRegistry.KnownTool] {
        let ids = Set(tools.map(\.id))
        return tools.filter { tool in
            DeviceRegistry.tipSiblingID(of: tool.id).map { !ids.contains($0) } ?? true
        }
    }

    /// Nicknames shared by more than one row, which then show their identifier.
    static func repeatedNicknames(_ tools: [DeviceRegistry.KnownTool]) -> Set<String> {
        var seen = Set<String>()
        var repeated = Set<String>()
        for tool in tools where !seen.insert(tool.nickname).inserted { repeated.insert(tool.nickname) }
        return repeated
    }

    @ViewBuilder
    private func toolSummaryRow(
        _ tool: DeviceRegistry.KnownTool, deviceSettings: TabletSettings, showsID: Bool, isLast: Bool
    ) -> some View {
        // The cache keeps the first instance made, so a mouse must be made
        // as one or the driver inherits pen button defaults.
        let t = deviceSettings.toolSettings(
            forID: DeviceRegistry.tipSiblingID(of: tool.id) ?? tool.id, isMouse: tool.isMouse)
        let nonDefault = toolNonDefaultLines(t, tool: tool, deviceSettings: deviceSettings)
        let toolKind =
            tool.kind.lowercased() == "pen"
            ? String(localized: "Pen", comment: "Tool type: pen")
            : (tool.kind.lowercased() == "eraser"
                ? String(localized: "Eraser", comment: "Tool type: eraser")
                : (tool.isMouse
                    ? String(localized: "Mouse", comment: "Tool type: mouse")
                    : String(localized: "Pen", comment: "Tool type: pen")))

        summaryRow(
            kind: toolKind, name: tool.nickname.isEmpty ? tool.displayID : tool.nickname,
            shownID: showsID && !tool.nickname.isEmpty
                ? (decoyingIDs ? DevicesView.decoyID(for: tool.displayID) : tool.displayID) : nil,
            details: nonDefault, isLast: isLast)
    }

    /// A pen or app row: its kind, its name, then what it changes.
    private func summaryRow(kind: String, name: String, shownID: String?, details: [String], isLast: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(kind)
                .appFont(.settingsLabel)
                .foregroundStyle(.secondary)
                .scaledFrame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(name)
                        .appFont(.settingsLabel)
                        .lineLimit(1)
                    if let shownID {
                        Text(shownID)
                            .appFont(.settingsLabel)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                if !details.isEmpty {
                    Text(details.joined(separator: Self.separator))
                        .appFont(.settingsLabel)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.bottom, isLast ? 0 : 4)
    }

    private static var separator: String { String(localized: ", ", comment: "List separator") }

    /// One summary item: a setting's name, as its pane labels it, and its value.
    private static func item(_ name: String, _ value: String) -> String {
        String(localized: "\(name): \(value)", comment: "Profiles summary item: a setting's name and its value")
    }

    private static func curveName(_ curve: BezierCurve) -> String {
        switch curve {
        case .soft: return String(localized: "Soft", comment: "Pressure curve preset button — soft response")
        case .firm: return String(localized: "Firm", comment: "Pressure curve preset button — firm response")
        case .linear: return String(localized: "Linear", comment: "Pressure curve preset button — linear response")
        default: return customName
        }
    }

    private static var customName: String {
        String(localized: "Custom", comment: "Profiles summary: a setting changed by hand, matching no preset")
    }

    /// Tablet-wide settings that differ from the defaults.
    private func deviceNonDefaultLines(_ s: TabletSettings) -> [String] {
        var lines: [String] = []
        if s.activeAreaX != 0 || s.activeAreaY != 0 || s.activeAreaWidth != 1.0 || s.activeAreaHeight != 1.0 {
            lines.append(Self.item(Label.tabletArea, Self.customName))
        }
        if s.targetDisplayIndex != 0 { lines.append(Self.item(Label.display, Self.displayName(s.targetDisplayIndex))) }
        if s.pressureCurve != .linear { lines.append(Self.item(Label.pressureCurve, Self.curveName(s.pressureCurve))) }
        if !s.proportionalMapping { lines.append(Self.item(Label.proportional, Self.onOff(false))) }
        if s.invertRotation { lines.append(Self.item(Label.invertRotation, Self.onOff(true))) }
        if s.relativeCursorMovement { lines.append(Self.item(Label.relative, Self.onOff(true))) }
        if s.doubleClickDistance != 10 {
            lines.append(Self.item(Label.doubleClick, PenFeelView.doubleClickLabel(s.doubleClickDistance)))
        }
        if s.tipUpAssistDelay != 0 {
            lines.append(Self.item(Label.tipUpAssist, PenFeelView.tipUpAssistLabel(s.tipUpAssistDelay)))
        }
        if s.dragThreshold != TouchdownGuard.defaultRadius {
            lines.append(Self.item(Label.dragThreshold, PenFeelView.dragThresholdLabel(s.dragThreshold)))
        }
        if !s.requireContact.isEmpty {
            lines.append(Self.item(Label.requireContact, Self.requireContactName(s.requireContact)))
        }
        return lines
    }

    /// What an app's override sets, read straight from its stored keys: every
    /// key it holds counts, even one set back to a default. Like the rest of
    /// this summary, it skips express keys, rings, and touch.
    private func overrideLines(_ o: TabletSettings.AppOverride, in s: TabletSettings) -> [String] {
        let ud = UserDefaults.standard
        let prefix = s.appOverrideKeyPrefix(o)
        func value(_ key: String) -> Any? { ud.object(forKey: prefix + key) }
        func double(_ key: String) -> Double? { (value(key) as? NSNumber)?.doubleValue }
        func bool(_ key: String) -> Bool? { (value(key) as? NSNumber)?.boolValue }
        var lines: [String] = []
        func binding(_ key: String, _ name: String, _ slot: ToolSettings.ButtonSlot) {
            guard let raw = value(key) as? String else { return }
            let b = ButtonBinding.decode(raw, orDefault: ToolSettings.builtInBinding(slot, isMouse: false))
            lines.append(Self.item(name, b.displayLabel))
        }
        binding("tipBinding", Label.tip, .tip)
        binding("eraserBinding", Label.eraser, .eraser)
        for n in 1...5 {
            binding("penButton\(n)Binding", ButtonsView.penButtonLabel(n, count: 5, isMouse: false), .button(n))
        }
        binding("wheelBinding", ButtonsView.wheelLabel(tool: nil), .wheel)
        if ["activeAreaX", "activeAreaY", "activeAreaWidth", "activeAreaHeight"].contains(where: { value($0) != nil }) {
            lines.append(Self.item(Label.tabletArea, Self.customName))
        }
        if let index = (value("targetDisplayIndex") as? NSNumber)?.intValue {
            lines.append(Self.item(Label.display, Self.displayName(index)))
        }
        if let on = bool("proportionalMapping") { lines.append(Self.item(Label.proportional, Self.onOff(on))) }
        if let data = value("pressureCurve") as? Data, let curve = try? JSONDecoder().decode(BezierCurve.self, from: data) {
            lines.append(Self.item(Label.pressureCurve, Self.curveName(curve)))
        }
        if let v = double("pressureThreshold") {
            lines.append(Self.item(Label.clickThreshold, PenFeelView.pressureThresholdLabel(v)))
        }
        if let v = double("smoothingStrength") { lines.append(Self.item(Label.steadiness, PenFeelView.steadinessLabel(v))) }
        if let v = double("pressureSmoothingStrength") {
            lines.append(Self.item(Label.pressureSmoothing, PenFeelView.pressureSmoothingLabel(v)))
        }
        if let v = double("panScrollSpeed") { lines.append(Self.item(Label.panView, Self.speed(v))) }
        if let on = bool("panScrollReverse") { lines.append(Self.item(Label.reverse, Self.onOff(on))) }
        if let on = bool("panScrollMomentum") { lines.append(Self.item(Label.momentum, Self.onOff(on))) }
        if let on = bool("invertRotation") { lines.append(Self.item(Label.invertRotation, Self.onOff(on))) }
        if let on = bool("relativeCursorMovement") { lines.append(Self.item(Label.relative, Self.onOff(on))) }
        if let v = double("doubleClickDistance") { lines.append(Self.item(Label.doubleClick, PenFeelView.doubleClickLabel(v))) }
        if let v = double("tipUpAssistDelay") { lines.append(Self.item(Label.tipUpAssist, PenFeelView.tipUpAssistLabel(v))) }
        if let v = double("dragThreshold") { lines.append(Self.item(Label.dragThreshold, PenFeelView.dragThresholdLabel(v))) }
        if let raw = (value("requireContact") as? NSNumber)?.intValue {
            lines.append(Self.item(Label.requireContact, Self.requireContactName(RequireContactActions(rawValue: raw))))
        }
        return lines
    }

    private static func onOff(_ on: Bool) -> String {
        on
            ? String(localized: "On", comment: "Profiles summary: a setting turned on")
            : String(localized: "Off", comment: "Feature disabled — drag threshold slider at minimum value")
    }

    private static func speed(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(2))) + "×"
    }

    private static func requireContactName(_ actions: RequireContactActions) -> String {
        let names = RequireContactActions.choices.filter { actions.contains($0.action) }
            .map { ButtonBinding(kind: $0.kind).displayLabel }
        return names.isEmpty ? ButtonBinding.none.displayLabel : names.joined(separator: separator)
    }

    /// Setting names, as the Buttons, Pen Feel, and Tablet Area panes label them.
    private enum Label {
        static var tip: String { String(localized: "Tip", comment: "Pen tip button row label in Buttons tab") }
        static var eraser: String { String(localized: "Eraser", comment: "Eraser button row label in Buttons tab") }
        static var tabletArea: String { String(localized: "Tablet Area", comment: "Tab name: tablet active area configuration") }
        static var display: String { String(localized: "Display", comment: "Tab name: display mapping and preview") }
        static var proportional: String { String(localized: "Proportional mapping", comment: "Checkbox label in Tablet Area tab") }
        static var pressureCurve: String { String(localized: "Pressure Curve", comment: "Undo action name: pressure curve change") }
        static var clickThreshold: String { String(localized: "Click Threshold") }
        static var steadiness: String { String(localized: "Steadiness") }
        static var pressureSmoothing: String { String(localized: "Pressure Smoothing") }
        static var panView: String { String(localized: "Pan View", comment: "Button action: hold to pan/scroll with pen motion") }
        static var reverse: String { String(localized: "Reverse Direction") }
        static var momentum: String { String(localized: "Momentum Scrolling") }
        static var invertRotation: String { String(localized: "Invert Rotation Direction", comment: "Toggle label in Pen Feel tab") }
        static var relative: String { String(localized: "Relative Cursor Movement", comment: "Toggle label in Pen Feel tab") }
        static var doubleClick: String { String(localized: "Double-Click Distance", comment: "Section header in Pen Feel tab") }
        static var tipUpAssist: String { String(localized: "Tip-up Assist") }
        static var dragThreshold: String { String(localized: "Drag Threshold") }
        static var requireContact: String {
            String(
                localized: "Require Contact",
                comment: "Setting label and undo action name: which side-button actions engage only while the pen touches the surface, in the Pen Feel pane")
        }
    }

    /// The Display pane's wording for a mapping target.
    private static func displayName(_ index: Int) -> String {
        switch index {
        case TabletSettings.displayModeAll: return String(localized: "All — span across all displays")
        case TabletSettings.displayModeToggle: return String(localized: "Toggle between displays")
        case TabletSettings.displayModeSpan: return String(localized: "Span selected displays")
        default:
            // A 1-based position in the active display list, as DisplayInfo stores it.
            var count: UInt32 = 0
            var ids = [CGDirectDisplayID](repeating: 0, count: 16)
            if index > 0, CGGetActiveDisplayList(16, &ids, &count) == .success, index <= count,
                let screen = NSScreen.screens.first(where: {
                    $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                        == ids[index - 1]
                })
            {
                return screen.localizedName
            }
            return String(localized: "Not connected", comment: "Connection status when this window's tablet is disconnected")
        }
    }

    /// A pen's settings that differ from the built-in values, named as the
    /// Buttons and Pen Feel panes name them.
    private func toolNonDefaultLines(
        _ t: ToolSettings, tool: DeviceRegistry.KnownTool, deviceSettings: TabletSettings
    ) -> [String] {
        let spec = tool.toolCode.flatMap { ToolCatalog.spec(forToolCode: $0) }
        let isMouse = tool.isMouse
        var lines: [String] = []
        func binding(_ name: String, _ value: ButtonBinding, _ slot: ToolSettings.ButtonSlot) {
            if value != ToolSettings.builtInBinding(slot, isMouse: isMouse) {
                lines.append(Self.item(name, value.displayLabel))
            }
        }
        binding(Label.tip, t.tipBinding, .tip)
        if !isMouse {
            binding(Label.eraser, t.eraserBinding, .eraser)
        }
        let count = ButtonsView.penButtonCount(tool: spec, device: nil)
        let buttons = [t.penButton1Binding, t.penButton2Binding, t.penButton3Binding, t.penButton4Binding, t.penButton5Binding]
        for n in 1...min(count, buttons.count) {
            binding(ButtonsView.penButtonLabel(n, count: count, isMouse: isMouse), buttons[n - 1], .button(n))
        }
        if spec?.hasWheel == true {
            binding(ButtonsView.wheelLabel(tool: spec), t.wheelBinding, .wheel)
        }
        if t.pressureCurve != .linear {
            lines.append(Self.item(Label.pressureCurve, Self.curveName(t.pressureCurve)))
        }
        let thresholdDefault = ToolSettings.deviceDefaultPressureThreshold(prefix: deviceSettings.devicePrefix)
        if abs(t.pressureThreshold - thresholdDefault) >= 0.005 {
            lines.append(Self.item(Label.clickThreshold, PenFeelView.pressureThresholdLabel(t.pressureThreshold)))
        }
        if t.smoothingStrength > 0 {
            lines.append(Self.item(Label.steadiness, PenFeelView.steadinessLabel(t.smoothingStrength)))
        }
        if t.pressureSmoothingStrength > 0 {
            lines.append(Self.item(Label.pressureSmoothing, PenFeelView.pressureSmoothingLabel(t.pressureSmoothingStrength)))
        }
        var pan: [String] = []
        if abs(t.panScrollSpeed - 1) >= 0.005 {
            pan.append(Self.speed(t.panScrollSpeed))
        }
        if t.panScrollReverse { pan.append(Label.reverse) }
        if t.panScrollMomentum { pan.append(Label.momentum) }
        if !pan.isEmpty {
            lines.append(Self.item(Label.panView, pan.joined(separator: Self.separator)))
        }
        return lines
    }
}

// MARK: - BackupFileDragSource

/// Drags the backup out as a file promise: Finder names the folder, then
/// this view writes the file there. The pasteboard carries the JSON too, so a drop
/// on another MockTab window imports it directly. It claims only left-button
/// events, leaving hover and Control-click to the tile underneath.
private struct BackupFileDragSource: NSViewRepresentable {
    let fileName: String
    let makeData: () -> Data?

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.fileName = fileName
        view.makeData = makeData
    }

    final class DragView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
        var fileName = ""
        var makeData: () -> Data? = { nil }
        private var mouseDownEvent: NSEvent?

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .leftMouseDown, .leftMouseDragged, .leftMouseUp: return super.hitTest(point)
            default: return nil
            }
        }

        override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownEvent else { return }
            let a = start.locationInWindow, b = event.locationInWindow
            guard hypot(b.x - a.x, b.y - a.y) >= 3, let data = makeData() else { return }
            mouseDownEvent = nil

            let provider = BackupPromiseProvider(fileType: UTType.json.identifier, delegate: self)
            provider.data = data
            let item = NSDraggingItem(pasteboardWriter: provider)
            item.setDraggingFrame(bounds, contents: snapshot())
            beginDraggingSession(with: [item], event: start, source: self)
        }

        override func mouseUp(with event: NSEvent) { mouseDownEvent = nil }

        /// The tile as drawn, as SwiftUI's drag showed it.
        private func snapshot() -> NSImage {
            guard let content = window?.contentView,
                  let rep = content.bitmapImageRepForCachingDisplay(in: convert(bounds, to: content))
            else { return NSWorkspace.shared.icon(for: .json) }
            content.cacheDisplay(in: convert(bounds, to: content), to: rep)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(rep)
            return image
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            fileName
        }

        func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            do {
                try ((provider as? BackupPromiseProvider)?.data ?? Data()).write(to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    /// Adds the JSON itself beside the promise.
    final class BackupPromiseProvider: NSFilePromiseProvider {
        var data = Data()
        private static let json = NSPasteboard.PasteboardType(UTType.json.identifier)

        override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
            super.writableTypes(for: pasteboard) + [Self.json]
        }

        override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
            type == Self.json ? data : super.pasteboardPropertyList(forType: type)
        }
    }
}
