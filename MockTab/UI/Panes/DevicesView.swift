// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import TabletKit

/// Devices tab — lists every tablet and pen the user has ever connected.
///
/// Upper section: one row per known tablet.  The active tablet is drawn in
/// semi-bold with a green checkmark.  Clicking any row loads that device's
/// tool list below.  Every row's name is user-editable inline.
///
/// Lower section: tools and peripherals seen on the selected tablet
/// (stylus, eraser, etc.).  Names are also user-editable.
struct DevicesView: View {
    @ObservedObject var settings: TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    var productID: Int?
    var undoManager: UndoManager?

    @State private var editingTabletID: Int? = nil
    @State private var editingToolID: String? = nil
    /// Which section the tool edit lives in. The same tool appears in both
    /// the per-tablet Tools list and Tools (All Tablets); without this,
    /// starting a rename in one section put both rows into edit mode.
    @State private var editingToolInAllSection = false
    @State private var editingName = ""
    @FocusState private var editFieldFocused: Bool

    @State private var pendingForgetTool: DeviceRegistry.KnownTool? = nil
    @State private var pendingForgetDeviceID: Int? = nil
    @State private var pendingRemoveTablet: DeviceRegistry.KnownTablet? = nil

    /// Tablet explicitly selected by the user to view its tools.
    /// Nil = auto-follow the currently active device.
    @State private var selectedTabletID: Int? = nil

    private var effectiveTabletID: Int? {
        selectedTabletID
            ?? (tabletManager.connectedProductID != 0 ? tabletManager.connectedProductID : nil)
            ?? registry.knownTablets.first?.id
    }

    var body: some View {
        SettingsPane(
            settings: settings, tabletManager: tabletManager, registry: registry,
            productID: productID
        ) {
            tabletsSection
            toolsSection
            allToolsSection
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Finder-style: a single click outside the field confirms any
            // rename in progress (an empty name reverts to the old one).
            commitTabletRename()
            commitToolRename()
        }
        .onAppear { syncTools() }
        .onChange(of: tabletManager.connectedProductID) { _ in
            if selectedTabletID == nil { syncTools() }
        }
        .alert(
            String(localized: "Remove \"\(pendingForgetTool?.nickname ?? "")\"?", comment: "Confirmation alert when removing a tool"),
            isPresented: Binding(
                get: { pendingForgetTool != nil },
                set: { if !$0 { pendingForgetTool = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                guard let tool = pendingForgetTool else { return }
                let snapshot: DeviceRegistry.ToolRemovalSnapshot?
                if let did = pendingForgetDeviceID {
                    snapshot = registry.forgetTool(id: tool.id, forDevice: did)
                } else {
                    snapshot = registry.forgetToolEverywhere(id: tool.id)
                }
                if let snapshot {
                    undoManager?.registerUndo(withTarget: registry) { target in
                        target.restoreTool(snapshot)
                    }
                    undoManager?.setActionName(String(localized: "Remove Tool", comment: "Undo action name when removing a tool"))
                }
                pendingForgetTool = nil
                editingToolID = nil
            }
            Button("Cancel", role: .cancel) { pendingForgetTool = nil }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(String(localized: "This tool will reappear with its default name next time the tablet detects it.", comment: "Message explaining that removed tool nicknames are temporary"))
        }
        .alert(
            String(localized: "Remove \"\(pendingRemoveTablet?.nickname ?? "")\"?", comment: "Confirmation alert when removing a tablet"),
            isPresented: Binding(
                get: { pendingRemoveTablet != nil },
                set: { if !$0 { pendingRemoveTablet = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                guard let tablet = pendingRemoveTablet else { return }
                if let snapshot = registry.removeTablet(id: tablet.id) {
                    undoManager?.registerUndo(withTarget: registry) { target in
                        target.restoreTablet(snapshot)
                    }
                    undoManager?.setActionName(String(localized: "Remove Tablet", comment: "Undo action name when removing a tablet"))
                }
                pendingRemoveTablet = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoveTablet = nil }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(String(localized: "This will discard all settings, profiles, button mappings, and the saved tool list for this tablet. The tablet will be re-added with defaults the next time it connects.", comment: "Message explaining what gets wiped when removing a tablet"))
        }
    }

    // MARK: - Tablets

    private var tabletsSection: some View {
        Section {
            columnHeader("Name", "Kind", "Identifier")
            if registry.knownTablets.isEmpty {
                emptyState(String(localized: "No tablets have been connected yet.", comment: "Empty state message when no tablets have been detected"))
            } else {
                ForEach(registry.knownTablets) { tablet in
                    tabletRow(tablet)
                }
            }
        } header: {
            Text("Tablets").appFont(.headline)
        }
    }

    @ViewBuilder
    private func tabletRow(_ tablet: DeviceRegistry.KnownTablet) -> some View {
        let isActive = tabletManager.connectedProductIDs.contains(tablet.id)
        let isSelected = effectiveTabletID == tablet.id

        HStack(spacing: 8) {
            // Active indicator
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.green : Color.clear)
                .frame(width: 20, alignment: .center)
                .accessibilityHidden(true)

            // Kind icon
            Image(systemName: "rectangle")
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
                .accessibilityHidden(true)

            if editingTabletID == tablet.id {
                // Inline rename, Finder-style: the field takes over the row
                // (Kind/Identifier hide so nothing wraps or shifts) and the
                // buttons keep their natural width in every locale.
                TextField(String(localized: "Device name", comment: "Placeholder text in rename tablet field"), text: $editingName)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
                    .focused($editFieldFocused)
                    .onSubmit { commitTabletRename() }
                    .onAppear { focusAndSelectAll() }
                Button("Rename") { commitTabletRename() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .fixedSize()
                Button("Cancel") { editingTabletID = nil }
                    .buttonStyle(.bordered).controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
            } else {
                // Name column: flexible but capped (~32 characters) so long
                // identifiers get the leftover width instead of truncating.
                Text(tablet.nickname)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxWidth: 280, alignment: .leading)

                // Kind column
                Text(tablet.modelName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
                    .help(tablet.modelName)

                // Serial / ID column
                Text(tablet.displayID)
                    .foregroundStyle(.secondary)
                    .appFont(.monospaced)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 135, maxWidth: .infinity, alignment: .leading)
                    .help(tablet.displayID)

                Button {
                    editingTabletID = tablet.id
                    editingName = tablet.nickname
                } label: {
                    Image(systemName: "pencil")
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Rename")
                .accessibilityLabel("Rename")
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.08) : nil)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginTabletEdit(tablet) }
        .onTapGesture {
            commitTabletRename()
            commitToolRename()
            selectedTabletID = tablet.id
            registry.loadTools(forDevice: tablet.id)
        }
        .contextMenu {
            Button("Rename…") { beginTabletEdit(tablet) }
            Divider()
            Button("Remove from List…", role: .destructive) {
                pendingRemoveTablet = tablet
            }
            .disabled(isActive)
        }
    }

    private func beginTabletEdit(_ tablet: DeviceRegistry.KnownTablet) {
        commitToolRename()
        commitTabletRename()
        editingToolID = nil
        editingTabletID = tablet.id
        editingName = tablet.nickname
    }

    private func beginToolEdit(_ tool: DeviceRegistry.KnownTool, inAllSection: Bool) {
        commitTabletRename()
        commitToolRename()
        editingTabletID = nil
        editingToolID = tool.id
        editingToolInAllSection = inAllSection
        editingName = tool.nickname
    }

    // MARK: - Tools

    private var toolsSection: some View {
        Section {
            columnHeader("Name", "Kind", "Identifier")
            if registry.knownTools.isEmpty {
                emptyState(String(localized: "No tools detected yet.\nMove the pen over the tablet to register it.", comment: "Empty state message in tools list — singular tablet"))
            } else {
                ForEach(registry.knownTools) { tool in
                    toolRow(tool, forDevice: effectiveTabletID)
                }
            }
        } header: {
            // Header shows which tablet's tools are listed
            HStack(spacing: 0) {
                Text("Tools").appFont(.headline)
                if let id = effectiveTabletID,
                    let tablet = registry.knownTablets.first(where: { $0.id == id })
                {
                    Text(" — \(tablet.nickname)")
                        .appFont(.headline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func toolRow(_ tool: DeviceRegistry.KnownTool, forDevice deviceID: Int?) -> some View {
        let isInProximity = tool.id == tabletManager.activeContext?.activeToolID
        let inAllSection = deviceID == nil
        let isEditing = editingToolID == tool.id && editingToolInAllSection == inAllSection
        HStack(spacing: 8) {
            // Proximity indicator
            Image(systemName: isInProximity ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isInProximity ? Color.green : Color.clear)
                .frame(width: 20, alignment: .center)
                .accessibilityHidden(true)

            // Kind icon
            Image(systemName: toolIcon(for: tool))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
                .accessibilityHidden(true)

            if isEditing {
                // Inline rename, Finder-style — see tabletRow.
                TextField(String(localized: "Tool name", comment: "Placeholder text in rename tool field"), text: $editingName)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
                    .focused($editFieldFocused)
                    .onSubmit { commitToolRename() }
                    .onAppear { focusAndSelectAll() }
                Button("Rename") { commitToolRename() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .fixedSize()
                Button("Forget…", role: .destructive) {
                    pendingForgetTool = tool
                    pendingForgetDeviceID = deviceID
                }
                .buttonStyle(.bordered).controlSize(.small)
                .fixedSize()
                .help("Remove this tool from the registry. It will reappear with its default name next time it is detected.")
                Button("Cancel") { editingToolID = nil }
                    .buttonStyle(.bordered).controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
            } else {
                // Name column: flexible but capped (~32 characters) so long
                // identifiers get the leftover width instead of truncating.
                Text(tool.nickname)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxWidth: 280, alignment: .leading)

                Text(tool.kind)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
                    .help(tool.kind)

                Text(tool.displayID)
                    .foregroundStyle(.secondary)
                    .appFont(.monospaced)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 135, maxWidth: .infinity, alignment: .leading)
                    .help(tool.displayID)

                Button {
                    beginToolEdit(tool, inAllSection: inAllSection)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Rename")
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isInProximity ? Color.accentColor.opacity(0.08) : nil)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginToolEdit(tool, inAllSection: inAllSection) }
        .contextMenu {
            Button("Rename…") { beginToolEdit(tool, inAllSection: inAllSection) }
            Divider()
            Button("Remove from List…", role: .destructive) {
                pendingForgetTool = tool
                pendingForgetDeviceID = deviceID
            }
        }
    }

    // MARK: - All Tools

    private var allToolsSection: some View {
        Section {
            columnHeader("Name", "Kind", "Identifier")
            if registry.allKnownTools.isEmpty {
                emptyState(String(localized: "No tools detected yet.\nMove the pen over a tablet to register it.", comment: "Empty state message in tools list — multiple tablets"))
            } else {
                ForEach(registry.allKnownTools) { tool in
                    toolRow(tool, forDevice: nil)
                }
            }
        } header: {
            Text("Tools (All Tablets)").appFont(.headline)
        }
    }

    // MARK: - Shared layout helpers

    private func toolIcon(for tool: DeviceRegistry.KnownTool) -> String {
        let toolCode = tool.toolCode ?? 0
        let type = WacomToolCatalog.toolType(forToolCode: toolCode)
        switch type {
        case .stylus, .eraser, .airbrush, .artPen, .inkingPen:
            return "pencil.tip.crop.circle"
        case .mouse:
            return "computermouse.fill"
        default:
            return "camera.metering.unknown"
        }
    }

    private func columnHeader(_ nameCol: LocalizedStringKey, _ kindCol: LocalizedStringKey, _ idCol: LocalizedStringKey) -> some View {
        HStack {
            Text(nameCol)
                .padding(.leading, 56)  // Room for kind icon + active indicator
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxWidth: 280 + 56, alignment: .leading)  // mirrors the rows' name cap
            Text(kindCol)
                .frame(width: 130, alignment: .leading)
            Text(idCol)
                .frame(minWidth: 135, maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 28)  // room for the rename pencil
        }
        .appFont(.settingsLabel)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .appFont(.callout)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func commitTabletRename() {
        guard let id = editingTabletID else { return }
        // End the edit before the lookup so a vanished tablet can't leave
        // the row stuck in edit mode (same hardening as commitToolRename).
        editingTabletID = nil
        guard let tablet = registry.knownTablets.first(where: { $0.id == id })
        else { return }
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        // Empty or unchanged names end the edit and keep the old name.
        guard !trimmed.isEmpty, trimmed != tablet.nickname else { return }
        let oldName = tablet.nickname
        registry.renameTablet(id: id, to: trimmed)
        // Register undo for tablet rename
        undoManager?.registerUndo(withTarget: registry) { target in
            target.renameTablet(id: id, to: oldName)
        }
        undoManager?.setActionName(String(localized: "Rename Tablet", comment: "Undo action name when renaming a tablet"))
    }

    private func commitToolRename() {
        guard let toolID = editingToolID else { return }
        // End the edit unconditionally — a failed lookup below must not
        // leave the row stuck in edit mode (click-away used to do exactly
        // that for all-tablets tools, which aren't in `knownTools`).
        editingToolID = nil
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)

        if editingToolInAllSection {
            // The all-tablets list can hold tools belonging to any tablet,
            // so rename across every tablet's persisted list.
            guard let tool = registry.allKnownTools.first(where: { $0.id == toolID }),
                !trimmed.isEmpty, trimmed != tool.nickname
            else { return }
            let oldName = tool.nickname
            registry.renameToolEverywhere(id: toolID, to: trimmed)
            undoManager?.registerUndo(withTarget: registry) { target in
                target.renameToolEverywhere(id: toolID, to: oldName)
            }
            undoManager?.setActionName(String(localized: "Rename Tool", comment: "Undo action name when renaming a tool"))
            return
        }

        guard let deviceID = effectiveTabletID,
            let tool = registry.knownTools.first(where: { $0.id == toolID })
        else { return }
        // Empty or unchanged names end the edit and keep the old name.
        guard !trimmed.isEmpty, trimmed != tool.nickname else { return }
        let oldName = tool.nickname
        registry.renameTool(id: toolID, to: trimmed, forDevice: deviceID)
        // Register undo for tool rename
        undoManager?.registerUndo(withTarget: registry) { target in
            target.renameTool(id: toolID, to: oldName, forDevice: deviceID)
        }
        undoManager?.setActionName(String(localized: "Rename Tool", comment: "Undo action name when renaming a tool"))
    }

    private func syncTools() {
        guard let id = effectiveTabletID else { return }
        registry.loadTools(forDevice: id)
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
}
