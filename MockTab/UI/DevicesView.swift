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
    @ObservedObject var registry: DeviceRegistry
    var undoManager: UndoManager?

    @State private var editingTabletID: Int? = nil
    @State private var editingToolID: String? = nil
    @State private var editingName = ""

    @State private var pendingForgetTool: DeviceRegistry.KnownTool? = nil
    @State private var pendingForgetDeviceID: Int? = nil

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
                Divider()
                allToolsSection
            }
            .padding()
        }
        .onAppear { syncTools() }
        .onChange(of: tabletManager.connectedProductID) { _ in
            if selectedTabletID == nil { syncTools() }
        }
        .alert(
            "Remove \"\(pendingForgetTool?.nickname ?? "")\"?",
            isPresented: Binding(
                get: { pendingForgetTool != nil },
                set: { if !$0 { pendingForgetTool = nil } }
            )
        ) {
            // No .destructive role so "Remove" is the default (blue) button — Enter confirms.
            Button("Remove") {
                guard let tool = pendingForgetTool else { return }
                if let did = pendingForgetDeviceID {
                    registry.forgetTool(id: tool.id, forDevice: did)
                } else {
                    registry.forgetToolEverywhere(id: tool.id)
                }
                pendingForgetTool = nil
                editingToolID = nil
            }
            Button("Cancel", role: .cancel) { pendingForgetTool = nil }
        } message: {
            Text("This tool will reappear with its default name next time the tablet detects it..")
        }
    }

    // MARK: - Tablets

    private var tabletsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tablets").font(.headline)
            columnHeader("Name", "Kind", "Serial / ID")
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
        let isActive = tabletManager.connectedProductIDs.contains(tablet.id)
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

            // Serial / ID column
            Text(tablet.displayID)
                .foregroundStyle(.secondary)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 110, alignment: .leading)

            // Actions
            if editingTabletID == tablet.id {
                Button("Save") { commitTabletRename() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Cancel") { editingTabletID = nil }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                Button {
                    editingTabletID = tablet.id
                    editingName = tablet.nickname
                } label: {
                    Image(systemName: "pencil")
                }
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
                    let tablet = registry.knownTablets.first(where: { $0.id == id })
                {
                    Text(" — \(tablet.nickname)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            columnHeader("Name", "Kind", "Serial / ID")
            if registry.knownTools.isEmpty {
                emptyState("No tools detected yet.\nMove the pen over the tablet to register it.")
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
            Image(systemName: isInProximity ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isInProximity ? Color.green : Color.clear)

            if editingToolID == tool.id {
                TextField("Tool name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .onSubmit { commitToolRename() }
            } else {
                HStack(spacing: 4) {
                    Text(tool.nickname)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !tool.isSupported {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Tool not fully supported on this device")
                    }
                }
            }

            Text(tool.kind)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)

            Text(tool.displayID)
                .foregroundStyle(.secondary)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 110, alignment: .leading)

            if editingToolID == tool.id {
                Button("Rename") { commitToolRename() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Forget…") {
                    pendingForgetTool = tool
                    pendingForgetDeviceID = deviceID
                }
                .buttonStyle(.bordered).controlSize(.small)
                .foregroundStyle(.red)
                Button("Cancel") { editingToolID = nil }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                Button {
                    editingToolID = tool.id
                    editingName = tool.nickname
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Rename")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isInProximity ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    // MARK: - All Tools

    private var allToolsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tools (All Tablets)").font(.headline)
            columnHeader("Name", "Kind", "Serial / ID")
            if registry.allKnownTools.isEmpty {
                emptyState("No tools detected yet.\nMove the pen over a tablet to register it.")
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

    private func columnHeader(_ nameCol: String, _ kindCol: String, _ idCol: String) -> some View {
        HStack {
            Text(nameCol)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(kindCol)
                .frame(width: 100, alignment: .leading)
            Text(idCol)
                .frame(width: 110, alignment: .leading)
            Spacer(minLength: 60)  // room for the action buttons
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
        .overlay(
            RoundedRectangle(cornerRadius: 6)
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
        undoManager?.setActionName("Rename Tablet")
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
        undoManager?.setActionName("Rename Tool")
        editingToolID = nil
    }

    private func syncTools() {
        guard let id = effectiveTabletID else { return }
        registry.loadTools(forDevice: id)
    }
}
