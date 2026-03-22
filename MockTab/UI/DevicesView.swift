import SwiftUI

/// Devices tab — lists every tablet and pen the user has ever connected.
///
/// Upper section: one row per known tablet.  The active tablet is drawn in
/// semi-bold with a green checkmark.  Clicking any row loads that device's
/// tool list below.  Every row's name is user-editable inline.
///
/// Lower section: tools and peripherals seen on the selected tablet
/// (stylus, eraser, etc.).  Names are also user-editable.
struct DevicesView: View {
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry:      DeviceRegistry

    @State private var editingTabletID: Int?    = nil
    @State private var editingToolID:   String? = nil
    @State private var editingName = ""

    /// Tablet explicitly selected by the user to view its tools.
    /// Nil = auto-follow the currently active device.
    @State private var selectedTabletID: Int? = nil

    private var effectiveTabletID: Int? {
        selectedTabletID
            ?? (tabletManager.connectedProductID != 0 ? tabletManager.connectedProductID : nil)
            ?? registry.knownTablets.first?.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                tabletsSection
                Divider()
                toolsSection
            }
            .padding()
        }
        .onAppear { syncTools() }
        .onChange(of: tabletManager.connectedProductID) { _ in
            if selectedTabletID == nil { syncTools() }
        }
    }

    // MARK: - Tablets

    private var tabletsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tablets").font(.headline)
            columnHeader("Name", "Kind")
            if registry.knownTablets.isEmpty {
                emptyState("No tablets have been connected yet.")
            } else {
                card {
                    ForEach(registry.knownTablets) { tablet in
                        tabletRow(tablet)
                        if tablet.id != registry.knownTablets.last?.id {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tabletRow(_ tablet: DeviceRegistry.KnownTablet) -> some View {
        let isActive   = tabletManager.connectedProductIDs.contains(tablet.id)
        let isSelected = effectiveTabletID == tablet.id

        HStack(spacing: 8) {
            // Active indicator
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.green : Color.clear)

            // Editable name
            if editingTabletID == tablet.id {
                TextField("Device name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .onSubmit { commitTabletRename() }
            } else {
                Text(tablet.nickname)
                    .fontWeight(isActive ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Kind column
            Text(tablet.modelName)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)

            // Actions
            if editingTabletID == tablet.id {
                Button("Save")   { commitTabletRename() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Cancel") { editingTabletID = nil }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                Button {
                    editingTabletID = tablet.id
                    editingName     = tablet.nickname
                } label: { Image(systemName: "pencil") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Rename")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            guard editingTabletID == nil else { return }
            selectedTabletID = tablet.id
            registry.loadTools(forDevice: tablet.id)
        }
    }

    // MARK: - Tools

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header shows which tablet's tools are listed
            HStack(spacing: 0) {
                Text("Tools").font(.headline)
                if let id = effectiveTabletID,
                   let tablet = registry.knownTablets.first(where: { $0.id == id }) {
                    Text(" — \(tablet.nickname)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            columnHeader("Name", "Kind")
            if registry.knownTools.isEmpty {
                emptyState("No tools detected yet.\nMove the pen over the tablet to register it.")
            } else {
                card {
                    ForEach(registry.knownTools) { tool in
                        toolRow(tool)
                        if tool.id != registry.knownTools.last?.id {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func toolRow(_ tool: DeviceRegistry.KnownTool) -> some View {
        let isInProximity = tool.id == tabletManager.activeToolID
        HStack(spacing: 8) {
            Image(systemName: isInProximity ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isInProximity ? Color.green : Color.clear)

            if editingToolID == tool.id {
                TextField("Tool name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .onSubmit { commitToolRename() }
            } else {
                Text(tool.nickname)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(tool.kind)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)

            if editingToolID == tool.id {
                Button("Save")   { commitToolRename() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Cancel") { editingToolID = nil }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                Button {
                    editingToolID = tool.id
                    editingName   = tool.nickname
                } label: { Image(systemName: "pencil") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Rename")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Shared layout helpers

    private func columnHeader(_ nameCol: String, _ kindCol: String) -> some View {
        HStack {
            Text(nameCol)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(kindCol)
                .frame(width: 100, alignment: .leading)
            Spacer(minLength: 60) // room for the action buttons
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1))
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .font(.callout)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func commitTabletRename() {
        guard let id = editingTabletID else { return }
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { registry.renameTablet(id: id, to: trimmed) }
        editingTabletID = nil
    }

    private func commitToolRename() {
        guard let toolID = editingToolID, let deviceID = effectiveTabletID else { return }
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { registry.renameTool(id: toolID, to: trimmed, forDevice: deviceID) }
        editingToolID = nil
    }

    private func syncTools() {
        guard let id = effectiveTabletID else { return }
        registry.loadTools(forDevice: id)
    }
}
