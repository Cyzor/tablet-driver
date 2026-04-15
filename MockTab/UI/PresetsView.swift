import AppKit
import SwiftUI

// MARK: - ProfilesView

/// Full profile management view: preset list, create/rename, auto-switch, summary, and backup/restore.
struct ProfilesView: View {
    @ObservedObject var settings: TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    var productID: Int?

    // Create/rename state
    @State private var isCreating = false
    @State private var newName = ""
    @State private var editingPreset: TabletSettings.Profile?
    @State private var editingName = ""

    // Summary + export state
    @State private var summaryExpanded = false

    /// TabletSettings for tablets that aren't currently connected.
    /// Populated lazily in onAppear so we don't rebuild on every render.
    @State private var offlineSettings: [Int: TabletSettings] = [:]

    // Import state
    @State private var pendingImport: ImportPlan?
    @State private var showImportSheet = false
    @State private var importError: String?

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
            DeviceStatusBar(
                settings: settings,
                tabletManager: tabletManager,
                registry: registry,
                productID: productID ?? 0
            )
        }
        .onAppear { populateOfflineSettings() }
        .onChange(of: registry.knownTablets.count) { _ in populateOfflineSettings() }
    }

    // MARK: - Offline Settings

    private func populateOfflineSettings() {
        var result: [Int: TabletSettings] = [:]
        for tablet in registry.knownTablets {
            if tabletManager.contexts[tablet.id] == nil {
                result[tablet.id] = TabletSettings(productID: tablet.id)
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
                Text("Active profile:")
                    .font(.headline)
                Text(active.name)
                    .font(.settingsLabel)
                    .fontWeight(.medium)
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Preset List

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profiles")
                .font(.headline)
                .foregroundStyle(.secondary)

            if settings.profiles.isEmpty {
                Text("No profiles yet. Create one below.")
                    .font(.settingsLabel)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(settings.profiles, id: \.id) { preset in
                    presetRow(preset)
                }
            }
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: TabletSettings.Profile) -> some View {
        let isActive = settings.activeProfile?.id == preset.id
        let isEditing = editingPreset?.id == preset.id

        HStack(spacing: 10) {
            // Active indicator
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.green : Color.secondary)
                .frame(width: 20)

            if isEditing {
                // Inline rename field
                TextField("Profile name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit { commitRename() }

                Button("Save") { commitRename() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button("Cancel") {
                    editingPreset = nil
                    editingName = ""
                }
                .controlSize(.small)
            } else {
                // Preset name + activate button
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .fontWeight(.medium)
                        .foregroundStyle(isActive ? Color.primary : Color.primary)

                    if !preset.overriddenKeys.isEmpty {
                        Text(
                            "\(preset.overriddenKeys.count) setting\(preset.overriddenKeys.count == 1 ? "" : "s")"
                        )
                        .font(.settingsBadge)
                        .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if !isActive {
                    Button("Activate") {
                        settings.activate(preset)
                    }
                    .controlSize(.small)
                } else {
                    Text("Active")
                        .font(.settingsBadge)
                        .foregroundStyle(.green)
                }

                // App overrides summary
                if !preset.overriddenKeys.isEmpty {
                    appBindingsForPreset(preset)
                }

                // Edit / Delete
                Menu {
                    Button("Rename") {
                        editingPreset = preset
                        editingName = preset.name
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        if settings.activeProfile?.id == preset.id {
                            settings.activeProfile = nil
                        }
                        settings.deletePreset(preset)
                    }
                    .disabled(preset.name == "Default")
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.settingsLabel)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
        )
    }

    // MARK: - App Override Chips

    @ViewBuilder
    private func appBindingsForPreset(_ preset: TabletSettings.Profile) -> some View {
        let overrideApps = settings.appOverrides.filter {
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
                .font(.settingsBadge)
                .frame(width: 16, height: 16)
        }
    }

    // MARK: - Create Row

    private var createRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New Profile")
                .font(.headline)
                .foregroundStyle(.secondary)

            if isCreating {
                HStack(spacing: 8) {
                    TextField("Profile name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .onSubmit { commitCreate() }

                    Button("Create") { commitCreate() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button("Cancel") {
                        isCreating = false
                        newName = ""
                    }
                    .controlSize(.small)
                }
            } else {
                Button {
                    isCreating = true
                    newName = ""
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("Create Profile")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Auto-Switch Section

    @ViewBuilder
    private var autoSwitchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Auto-Switch")
                .font(.headline)
                .foregroundStyle(.secondary)

            Toggle(
                "Automatically switch to the matching profile when this tablet connects",
                isOn: recordingBinding(
                    "Auto-Switch",
                    get: { settings.autoSwitchEnabled },
                    set: { settings.autoSwitchEnabled = $0 }
                )
            )
            .font(.settingsLabel)
        }
    }

    // MARK: - Summary Section

    private var summarySection: some View {
        DisclosureRow(label: "Device Summary", isExpanded: $summaryExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(registry.knownTablets, id: \.id) { tablet in
                    tabletSummaryCard(tablet)
                }
            }
        }
    }

    @ViewBuilder
    private func tabletSummaryCard(_ tablet: DeviceRegistry.KnownTablet) -> some View {
        let ts: TabletSettings =
            tabletManager.contexts[tablet.id]?.settings ?? offlineSettings[tablet.id]
            ?? TabletSettings(productID: tablet.id)
        let nonDefault = deviceNonDefaultLines(ts)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(tablet.nickname)
                    .font(.settingsLabel)
                    .fontWeight(.medium)
                Text(tablet.modelName)
                    .font(.settingsBadge)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(
                    ts.profiles.count == 0
                        ? "No profiles"
                        : "\(ts.profiles.count) profile\(ts.profiles.count == 1 ? "" : "s")"
                )
                .font(.settingsBadge)
                .foregroundStyle(.tertiary)
            }

            if !nonDefault.isEmpty {
                ForEach(nonDefault, id: \.self) { line in
                    Text(line)
                        .font(.settingsBadge)
                        .foregroundStyle(.secondary)
                }
            }

            // Tools
            let tools = registry.tools(forDevice: tablet.id)
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
        let toolKind = tool.kind.lowercased() == "pen" ? "Pen" : (tool.kind.lowercased() == "eraser" ? "Eraser" : "Tool")

        HStack(alignment: .top, spacing: 8) {
            Text(toolKind)
                .font(.settingsBadge)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            Text(tool.nickname.isEmpty ? tool.displayID : tool.nickname)
                .font(.settingsBadge)
                .foregroundStyle(.secondary)
            if !nonDefault.isEmpty {
                Text("(\(nonDefault.joined(separator: ", ")))")
                    .font(.settingsBadge)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 8)
        .padding(.bottom, isLast ? 0 : 4)
    }

    private func deviceNonDefaultLines(_ s: TabletSettings) -> [String] {
        var lines: [String] = []
        if s.activeAreaX != 0 || s.activeAreaY != 0 { lines.append("area offset") }
        if s.activeAreaWidth != 1.0 || s.activeAreaHeight != 1.0 { lines.append("area scaled") }
        if s.targetDisplayIndex != 0 { lines.append("display != primary") }
        if s.pressureCurve.p1 != CGPoint(x: 0, y: 0) || s.pressureCurve.p2 != CGPoint(x: 1, y: 1) {
            lines.append("pressure curve")
        }
        if s.proportionalMapping { lines.append("proportional") }
        if s.invertRotation { lines.append("rotation inverted") }
        return lines
    }

    private func toolNonDefaultLines(_ t: ToolSettings) -> [String] {
        var lines: [String] = []
        if t.pressureCurve.p1 != CGPoint(x: 0, y: 0) || t.pressureCurve.p2 != CGPoint(x: 1, y: 1) {
            lines.append("curve")
        }
        if t.tipBinding != .leftClick { lines.append("tip ≠ default") }
        if t.eraserBinding != .eraser { lines.append("eraser ≠ default") }
        return lines
    }

    // MARK: - Export Section

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Backup & Restore")
                .fontWeight(.medium)
            Text(
                "Export your current configuration as a JSON file. You can restore it later if settings get reset or corrupted."
            )
            .font(.settingsLabel)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                ExportDragWell(
                    generateJSON: {
                        PresetExporter(registry: registry, tabletManager: tabletManager).export()
                    },
                    onImport: handleImportData
                )
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
        }
        .sheet(isPresented: $showImportSheet) {
            if let plan = pendingImport {
                ImportPreviewSheet(
                    plan: plan,
                    registry: registry,
                    tabletManager: tabletManager,
                    offlineSettings: offlineSettings
                ) {
                    showImportSheet = false
                    pendingImport = nil
                }
            }
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

    /// Called by the drag well or file picker with raw JSON data.
    private func handleImportData(_ data: Data) {
        importError = nil
        do {
            let plan = try PresetImporter.parse(data, registry: registry)
            pendingImport = plan
            showImportSheet = true
        } catch let e as PresetImporter.ParseError {
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
