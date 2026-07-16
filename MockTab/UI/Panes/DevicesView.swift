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
/// Lower section: tools and peripherals seen on the selected tablet.
/// Names are also user-editable.  The registry stores a pen's tip and
/// eraser ends as separate entries (they have distinct tool codes and
/// ids), but the list folds the eraser into its pen's row — one physical
/// object, one row, matching how vendors present it.  Renaming or
/// removing the row applies to both ends.
struct DevicesView: View {
    @ObservedObject var settings: TabletSettings
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry: DeviceRegistry
    let instanceKey: DeviceInstanceKey?
    /// Model axis of the bound unit — spec/catalog lookups key on this.
    private var productID: Int? { instanceKey?.productID }
    var undoManager: UndoManager?

    @State private var editingTabletID: String? = nil
    @State private var editingToolID: String? = nil
    /// Which section the tool edit lives in. The same tool appears in both
    /// the per-tablet Tools list and Tools (All Tablets); without this,
    /// starting a rename in one section put both rows into edit mode.
    @State private var editingToolInAllSection = false
    @State private var editingName = ""
    @FocusState private var editFieldFocused: Bool

    @State private var pendingForgetTool: DeviceRegistry.KnownTool? = nil
    @State private var pendingForgetDeviceID: String? = nil
    @State private var pendingRemoveTablet: DeviceRegistry.KnownTablet? = nil

    /// Tablet explicitly selected by the user to view its tools.
    /// Nil = auto-follow the currently active device.
    @State private var selectedTabletID: String? = nil

    private var effectiveTabletID: String? {
        selectedTabletID
            ?? registry.knownTablets.first(where: {
                $0.productID == tabletManager.connectedProductID
            })?.id
            ?? registry.knownTablets.first?.id
    }

    var body: some View {
        SettingsPane(
            settings: settings, tabletManager: tabletManager, registry: registry,
            instanceKey: instanceKey
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
                // A pen row stands in for both ends — remove the folded-in
                // eraser entry along with the tip, in one undoable action.
                var ids = [tool.id]
                if let eraserID = Self.eraserSiblingID(of: tool.id) { ids.append(eraserID) }
                var snapshots: [DeviceRegistry.ToolRemovalSnapshot] = []
                for id in ids {
                    let snapshot: DeviceRegistry.ToolRemovalSnapshot?
                    if let did = pendingForgetDeviceID {
                        snapshot = registry.forgetTool(id: id, forDevice: did)
                    } else {
                        snapshot = registry.forgetToolEverywhere(id: id)
                    }
                    if let snapshot { snapshots.append(snapshot) }
                }
                if !snapshots.isEmpty {
                    undoManager?.registerUndo(withTarget: registry) { target in
                        for snapshot in snapshots { target.restoreTool(snapshot) }
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
        let isActive = tabletManager.connectedProductIDs.contains(tablet.productID)
        let isSelected = effectiveTabletID == tablet.id

        HStack(spacing: 8) {
            // Active indicator
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.green : Color.clear)
                .frame(width: 20, alignment: .center)
                .accessibilityHidden(true)

            // Kind icon. The puck glyph reads much smaller than the plain
            // rectangle at the same point size (it's a thin outline shape,
            // not a filled block), so it gets a 50% size bump — the
            // surrounding frame stays fixed at 20pt so row spacing/alignment
            // with every other row is unaffected.
            Image(systemName: kindSymbolName(forProductID: tablet.productID))
                .appFont(size: isPuckKind(forProductID: tablet.productID) ? 19.5 : 13)
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
                // Two-line row: nickname on top, catalog name and identifier
                // in a small gray subtitle. Nothing competes for width, so
                // long names and identifiers stop truncating each other.
                VStack(alignment: .leading, spacing: 1) {
                    Text(tablet.nickname)
                        .fontWeight(isActive ? .semibold : .regular)
                        .lineLimit(1)
                    let subtitle = Self.subtitle(
                        kind: tablet.modelName, id: tablet.displayID,
                        nickname: tablet.nickname)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .appFont(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("\(tablet.modelName) · \(tablet.displayID)")

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

    /// SF Symbol for a device's row icon, by product kind. Aux-only
    /// companion peripherals (currently just the Xencelabs Quick Keys puck)
    /// use a symbol that actually resembles their shape; everything else
    /// keeps the generic tablet rectangle.
    private func kindSymbolName(forProductID productID: Int) -> String {
        isPuckKind(forProductID: productID) ? "appletvremote.gen4.fill" : "rectangle"
    }

    private func isPuckKind(forProductID productID: Int) -> Bool {
        guard let profile = VendorDeviceRegistry.profile(forProductID: productID) else { return false }
        return profile.maxX == nil
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

    /// The eraser-end entry paired with a tip entry's id, or nil for ids
    /// that can't have one. Generic serial-less entries with a counter
    /// suffix ("stylus-1") stay unpaired — with no serial there's no way
    /// to know which eraser belongs to which pen body.
    static func eraserSiblingID(of id: String) -> String? {
        if id == "stylus" { return "eraser" }
        if id.hasPrefix("0x") { return "eraser-" + id }
        return nil
    }

    /// Inverse of `eraserSiblingID(of:)`.
    static func tipSiblingID(of id: String) -> String? {
        if id == "eraser" { return "stylus" }
        if id.hasPrefix("eraser-0x") { return String(id.dropFirst("eraser-".count)) }
        return nil
    }

    /// Hides eraser entries whose pen tip is also in the list, so each
    /// physical pen gets one row. An orphaned eraser (tip never seen)
    /// still shows on its own.
    private func displayTools(_ list: [DeviceRegistry.KnownTool]) -> [DeviceRegistry.KnownTool] {
        list.filter { tool in
            guard let tipID = Self.tipSiblingID(of: tool.id) else { return true }
            return !list.contains { $0.id == tipID }
        }
    }

    private var toolsSection: some View {
        Section {
            if registry.knownTools.isEmpty {
                emptyState(String(localized: "No tools detected yet.\nMove the pen over the tablet to register it.", comment: "Empty state message in tools list — singular tablet"))
            } else {
                ForEach(displayTools(registry.knownTools)) { tool in
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
    private func toolRow(_ tool: DeviceRegistry.KnownTool, forDevice deviceID: String?) -> some View {
        // The merged row also lights up when the folded-in eraser end is
        // the one in proximity.
        let activeID = tabletManager.activeContext?.activeToolID
        let isInProximity =
            activeID == tool.id
            || (activeID != nil && activeID == Self.eraserSiblingID(of: tool.id))
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
                // Two-line row — see tabletRow.
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.nickname)
                        .lineLimit(1)
                    let subtitle = Self.subtitle(
                        kind: tool.kind, id: tool.displayID,
                        nickname: tool.nickname)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .appFont(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("\(tool.kind) · \(tool.displayID)")

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
            if registry.allKnownTools.isEmpty {
                emptyState(String(localized: "No tools detected yet.\nMove the pen over a tablet to register it.", comment: "Empty state message in tools list — multiple tablets"))
            } else {
                ForEach(displayTools(registry.allKnownTools)) { tool in
                    toolRow(tool, forDevice: nil)
                }
            }
        } header: {
            Text("Tools (All Tablets)").appFont(.headline)
        }
    }

    // MARK: - Shared layout helpers

    /// Builds the subtitle line under a nickname: catalog name and hardware
    /// identifier, dot-separated. The catalog name is omitted while the
    /// nickname still contains it (the default nickname *is* the catalog
    /// name, so showing it again read as a duplicate); it reappears once the
    /// user assigns a memorable name. Identifiers with no real content —
    /// e.g. a dongle whose serial is all zeros — are dropped entirely.
    /// The full, unfiltered pair stays available in the row's tooltip.
    static func subtitle(kind: String, id: String, nickname: String) -> String {
        var parts: [String] = []
        if !kind.isEmpty, !nickname.localizedCaseInsensitiveContains(kind) {
            parts.append(kind)
        }
        // Meaningful = something left after stripping zeros and the
        // punctuation of hex/MAC/serial formatting.
        if id.contains(where: { !"0x:- ".contains($0) }) {
            parts.append(id)
        }
        return parts.joined(separator: " · ")
    }

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
            // Carry the new name to the folded-in eraser entry so places
            // that surface the active tool by id (status bar, Info pane)
            // stay consistent with the merged row. Both undos land in the
            // same runloop group, so one Undo reverts the pair.
            if let eraserID = Self.eraserSiblingID(of: toolID),
                let eraser = registry.allKnownTools.first(where: { $0.id == eraserID })
            {
                let oldEraserName = eraser.nickname
                registry.renameToolEverywhere(id: eraserID, to: "\(trimmed) (Eraser)")
                undoManager?.registerUndo(withTarget: registry) { target in
                    target.renameToolEverywhere(id: eraserID, to: oldEraserName)
                }
            }
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
        // Carry the new name to the folded-in eraser entry — see the
        // all-tablets branch above.
        if let eraserID = Self.eraserSiblingID(of: toolID),
            let eraser = registry.knownTools.first(where: { $0.id == eraserID })
        {
            let oldEraserName = eraser.nickname
            registry.renameTool(id: eraserID, to: "\(trimmed) (Eraser)", forDevice: deviceID)
            undoManager?.registerUndo(withTarget: registry) { target in
                target.renameTool(id: eraserID, to: oldEraserName, forDevice: deviceID)
            }
        }
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
