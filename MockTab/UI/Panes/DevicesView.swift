// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
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
    @ObservedObject var settings: TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    var productID: Int?
    var undoManager: UndoManager?

    @State private var editingTabletID: Int? = nil
    @State private var editingToolID: String? = nil
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
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    tabletsSection
                    Divider()
                    toolsSection
                    Divider()
                    allToolsSection
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
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            editingTabletID = nil
            editingToolID = nil
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
            // No .destructive role so "Remove" is the default (blue) button — Enter confirms.
            Button(LocalizedStringKey("Remove")) {
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
            Button(LocalizedStringKey("Cancel"), role: .cancel) { pendingForgetTool = nil }
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
            Button(LocalizedStringKey("Remove")) {
                guard let tablet = pendingRemoveTablet else { return }
                if let snapshot = registry.removeTablet(id: tablet.id) {
                    undoManager?.registerUndo(withTarget: registry) { target in
                        target.restoreTablet(snapshot)
                    }
                    undoManager?.setActionName(String(localized: "Remove Tablet", comment: "Undo action name when removing a tablet"))
                }
                pendingRemoveTablet = nil
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) { pendingRemoveTablet = nil }
        } message: {
            Text(String(localized: "This will discard all settings, profiles, button mappings, and the saved tool list for this tablet. The tablet will be re-added with defaults the next time it connects.", comment: "Message explaining what gets wiped when removing a tablet"))
        }
    }

    // MARK: - Tablets

    private var tabletsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey("Tablets")).appFont(.headline)
            columnHeader("Name", "Kind", "Identifier")
            if registry.knownTablets.isEmpty {
                emptyState(String(localized: "No tablets have been connected yet.", comment: "Empty state message when no tablets have been detected"))
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

            // Editable name
            if editingTabletID == tablet.id {
                TextField(String(localized: "Device name", comment: "Placeholder text in rename tablet field"), text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .focused($editFieldFocused)
                    .onSubmit { commitTabletRename() }
                    .onAppear { focusAndSelectAll() }
            } else {
                Text(tablet.nickname)
                    .fontWeight(isActive ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Kind column
            Text(tablet.modelName)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)

            // Serial / ID column
            Text(tablet.displayID)
                .foregroundStyle(.secondary)
                .appFont(.monospaced)
                .frame(width: 110, alignment: .leading)

            // Actions
            if editingTabletID == tablet.id {
                Button(LocalizedStringKey("Save")) { commitTabletRename() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button(LocalizedStringKey("Cancel")) { editingTabletID = nil }
                    .buttonStyle(.bordered).controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            } else {
                Button {
                    editingTabletID = tablet.id
                    editingName = tablet.nickname
                } label: {
                    Image(systemName: "pencil")
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(LocalizedStringKey("Rename"))
                .accessibilityLabel(LocalizedStringKey("Rename"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginTabletEdit(tablet) }
        .onTapGesture {
            guard editingTabletID == nil else { return }
            selectedTabletID = tablet.id
            registry.loadTools(forDevice: tablet.id)
        }
        .contextMenu {
            Button(LocalizedStringKey("Rename…")) { beginTabletEdit(tablet) }
            Divider()
            Button(LocalizedStringKey("Remove from List…")) {
                pendingRemoveTablet = tablet
            }
            .disabled(isActive)
        }
    }

    private func beginTabletEdit(_ tablet: DeviceRegistry.KnownTablet) {
        editingToolID = nil
        editingTabletID = tablet.id
        editingName = tablet.nickname
    }

    private func beginToolEdit(_ tool: DeviceRegistry.KnownTool) {
        editingTabletID = nil
        editingToolID = tool.id
        editingName = tool.nickname
    }

    // MARK: - Tools

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header shows which tablet's tools are listed
            HStack(spacing: 0) {
                Text(LocalizedStringKey("Tools")).appFont(.headline)
                if let id = effectiveTabletID,
                    let tablet = registry.knownTablets.first(where: { $0.id == id })
                {
                    Text(" — \(tablet.nickname)")
                        .appFont(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            columnHeader("Name", "Kind", "Identifier")
            if registry.knownTools.isEmpty {
                emptyState(String(localized: "No tools detected yet.\nMove the pen over the tablet to register it.", comment: "Empty state message in tools list — singular tablet"))
            } else {
                card {
                    ForEach(registry.knownTools) { tool in
                        toolRow(tool, forDevice: effectiveTabletID)
                        if tool.id != registry.knownTools.last?.id {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func toolRow(_ tool: DeviceRegistry.KnownTool, forDevice deviceID: Int?) -> some View {
        let isInProximity = tool.id == tabletManager.activeToolID
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

            if editingToolID == tool.id {
                TextField(String(localized: "Tool name", comment: "Placeholder text in rename tool field"), text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .focused($editFieldFocused)
                    .onSubmit { commitToolRename() }
                    .onAppear { focusAndSelectAll() }
            } else {
                Text(tool.nickname)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(tool.kind)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)

            Text(tool.displayID)
                .foregroundStyle(.secondary)
                .appFont(.monospaced)
                .frame(width: 110, alignment: .leading)

            if editingToolID == tool.id {
                Button(LocalizedStringKey("Rename")) { commitToolRename() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button(LocalizedStringKey("Forget…")) {
                    pendingForgetTool = tool
                    pendingForgetDeviceID = deviceID
                }
                .buttonStyle(.bordered).controlSize(.small)
                .foregroundStyle(.red)
                .help(LocalizedStringKey("Remove this tool from the registry. It will reappear with its default name next time it is detected."))
                Button(LocalizedStringKey("Cancel")) { editingToolID = nil }
                    .buttonStyle(.bordered).controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            } else {
                Button {
                    editingToolID = tool.id
                    editingName = tool.nickname
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(LocalizedStringKey("Rename"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isInProximity ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginToolEdit(tool) }
        .contextMenu {
            Button(LocalizedStringKey("Rename…")) { beginToolEdit(tool) }
            Divider()
            Button(LocalizedStringKey("Remove from List…")) {
                pendingForgetTool = tool
                pendingForgetDeviceID = deviceID
            }
        }
    }

    // MARK: - All Tools

    private var allToolsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey("Tools (All Tablets)")).appFont(.headline)
            columnHeader("Name", "Kind", "Identifier")
            if registry.allKnownTools.isEmpty {
                emptyState(String(localized: "No tools detected yet.\nMove the pen over a tablet to register it.", comment: "Empty state message in tools list — multiple tablets"))
            } else {
                card {
                    ForEach(registry.allKnownTools) { tool in
                        toolRow(tool, forDevice: nil)
                        if tool.id != registry.allKnownTools.last?.id {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            }
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
            Text(kindCol)
                .frame(width: 100, alignment: .leading)
            Text(idCol)
                .frame(width: 110, alignment: .leading)
            Spacer(minLength: 60)  // room for the action buttons
        }
        .appFont(.settingsLabel)
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
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1))
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
        guard let id = editingTabletID,
            let tablet = registry.knownTablets.first(where: { $0.id == id })
        else { return }
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let oldName = tablet.nickname
        registry.renameTablet(id: id, to: trimmed)
        // Register undo for tablet rename
        undoManager?.registerUndo(withTarget: registry) { target in
            target.renameTablet(id: id, to: oldName)
        }
        undoManager?.setActionName(String(localized: "Rename Tablet", comment: "Undo action name when renaming a tablet"))
        editingTabletID = nil
    }

    private func commitToolRename() {
        guard let toolID = editingToolID,
            let deviceID = effectiveTabletID,
            let tool = registry.knownTools.first(where: { $0.id == toolID })
        else { return }
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let oldName = tool.nickname
        registry.renameTool(id: toolID, to: trimmed, forDevice: deviceID)
        // Register undo for tool rename
        undoManager?.registerUndo(withTarget: registry) { target in
            target.renameTool(id: toolID, to: oldName, forDevice: deviceID)
        }
        undoManager?.setActionName(String(localized: "Rename Tool", comment: "Undo action name when renaming a tool"))
        editingToolID = nil
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
