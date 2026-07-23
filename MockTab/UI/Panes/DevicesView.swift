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

    /// Screenshot aid: when on, every device/tool identifier renders as a
    /// deterministic, format-preserving decoy so serials can be captured
    /// without hand-redaction. Toggled by Option+Shift-clicking a tablet
    /// row; view-local, so it resets whenever the pane is reopened.
    @State private var decoyingIDs = false

    private var effectiveTabletID: String? {
        // Explicit selection always wins. When auto-following, prefer a
        // pen-bearing device over an aux-only companion (the Quick Keys puck)
        // so the default Tools view shows the pen rather than an empty
        // section — the puck owns no tools of its own.
        if let selectedTabletID { return selectedTabletID }
        // Filter by the full connected set, not the single `connectedProductID`
        // scalar — that scalar transiently points at whichever device
        // (re)enumerated last, which can be the puck during a USB blip. Using it
        // let the puck hijack the auto-selection and blank the Tools section
        // even while the pen display was connected.
        let connected = registry.knownTablets.filter {
            tabletManager.connectedProductIDs.contains($0.productID)
        }
        if let penBearing = connected.first(where: { !isPuckKind(forProductID: $0.productID) }) {
            return penBearing.id
        }
        // No connected pen-bearing device: fall back to any known pen-bearing
        // device (so its tools stay visible even while only the puck's transport
        // is up), then to whatever's connected — a genuinely standalone puck —
        // then to anything at all.
        return registry.knownTablets.first(where: { !isPuckKind(forProductID: $0.productID) })?.id
            ?? connected.first?.id
            ?? registry.knownTablets.first?.id
    }

    /// True when the tablet currently driving the Tools section is aux-only
    /// (the Quick Keys puck) — it has no digitizer, so it can never own a pen
    /// tool. The load-bearing guard: a pen never renders under a puck header.
    private var effectiveTabletIsAuxOnly: Bool {
        guard let id = effectiveTabletID,
            let tablet = registry.knownTablets.first(where: { $0.id == id })
        else { return false }
        return isPuckKind(forProductID: tablet.productID)
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
        .onChange(of: tabletManager.connectedProductIDs) { _ in
            // Watch the whole connected set, not just the `connectedProductID`
            // scalar — a USB blip that changes which devices are present must
            // reload the tool list even when the scalar happens not to change.
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
                    registerToolRemovalUndo(snapshots)
                }
                pendingForgetTool = nil
                editingToolID = nil
            }
            .keyboardShortcut(.delete, modifiers: .command)
            Button("Cancel", role: .cancel) { pendingForgetTool = nil }
                .keyboardShortcut(.cancelAction)
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
                    registerTabletRemovalUndo(snapshot)
                }
                pendingRemoveTablet = nil
            }
            .keyboardShortcut(.delete, modifiers: .command)
            Button("Cancel", role: .cancel) { pendingRemoveTablet = nil }
                .keyboardShortcut(.cancelAction)
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

            // Two-line row: nickname on top, catalog name and identifier
            // in a small gray subtitle. Nothing competes for width, so
            // long names and identifiers stop truncating each other.
            // Renaming swaps only the nickname Text for a plain-style
            // TextField with the same metrics (Finder-style): no border
            // chrome, no inline buttons, so nothing in the row moves.
            // Return commits, Esc cancels, click-away commits.
            VStack(alignment: .leading, spacing: 1) {
                if editingTabletID == tablet.id {
                    TextField(String(localized: "Device name", comment: "Placeholder text in rename tablet field"), text: $editingName)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.leading)
                        .focused($editFieldFocused)
                        .renameFieldRing()
                        .onSubmit { commitTabletRename() }
                        .onExitCommand { editingTabletID = nil }
                        .onAppear { focusAndSelectAll() }
                } else {
                    Text(tablet.nickname)
                        .fontWeight(isActive ? .semibold : .regular)
                        .lineLimit(1)
                }
                let subtitle = Self.subtitle(
                    kind: tablet.modelName, id: shownID(tablet.displayID),
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
            .help("\(tablet.modelName) · \(shownID(tablet.displayID))")

            // Always present so the row's trailing edge never moves; while
            // editing it commits instead of re-entering edit mode.
            Button {
                if editingTabletID == tablet.id {
                    commitTabletRename()
                } else {
                    beginTabletEdit(tablet)
                }
            } label: {
                Image(systemName: "pencil")
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Rename")
            .accessibilityLabel("Rename")
        }
        .padding(.vertical, 2)
        // Quiet hint for which row's tools show below. `.listRowBackground`
        // is a List-only modifier and does nothing inside the grouped Form
        // this pane lives in, so paint the highlight behind the row directly.
        // The negative padding lets it bleed to the cell edges for a full-row
        // wash rather than a tight box around the content.
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
                .padding(.horizontal, -8)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginTabletEdit(tablet) }
        // Selection runs as a simultaneous gesture, not a plain single
        // `.onTapGesture`. Alongside the count:2 rename tap, a plain single
        // tap makes SwiftUI stall the action by the double-click interval to
        // rule out a second click — a visible "why did that take a beat" lag
        // on every row switch. A simultaneous tap fires on release without
        // waiting, so activation feels instant; double-click still renames
        // (first tap selects, second enters edit — the Finder behavior).
        .simultaneousGesture(
            TapGesture().onEnded {
                // A modified click drives the decoy toggle (the gesture
                // below); swallow it here so it doesn't also reselect the row.
                if NSEvent.modifierFlags.contains([.option, .shift]) { return }
                commitTabletRename()
                commitToolRename()
                selectedTabletID = tablet.id
                registry.loadTools(forDevice: tablet.id)
            }
        )
        // Hidden screenshot aid: Option+Shift-click any row to swap all
        // identifiers for decoys (and back). A modifier-qualified tap fires
        // on release, so it isn't held back by the row's double-tap (rename)
        // disambiguation the way a plain single tap is.
        .simultaneousGesture(
            TapGesture().modifiers([.option, .shift]).onEnded { decoyingIDs.toggle() }
        )
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
            if effectiveTabletIsAuxOnly {
                // Aux-only devices (the Quick Keys puck) have no digitizer, so
                // no pen ever belongs to them. Its pens live under the paired
                // Pen Display and in Tools (All Tablets).
                emptyState(String(localized: "This device has no pen tools.\nIts buttons are configured in the Buttons tab.", comment: "Empty state shown in the tools list for an aux-only device like the Quick Keys puck"))
            } else if registry.knownTools.isEmpty {
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

            // Two-line row — see tabletRow. Renaming swaps only the nickname
            // Text for a metrically identical plain TextField (Finder-style);
            // Return commits, Esc cancels, click-away commits. Forget stays
            // available in the context menu.
            VStack(alignment: .leading, spacing: 1) {
                if isEditing {
                    TextField(String(localized: "Tool name", comment: "Placeholder text in rename tool field"), text: $editingName)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.leading)
                        .focused($editFieldFocused)
                        .renameFieldRing()
                        .onSubmit { commitToolRename() }
                        .onExitCommand { editingToolID = nil }
                        .onAppear { focusAndSelectAll() }
                } else {
                    Text(tool.nickname)
                        .lineLimit(1)
                }
                let subtitle = Self.subtitle(
                    kind: tool.kind, id: shownID(tool.displayID),
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
            .help("\(tool.kind) · \(shownID(tool.displayID))")

            Button {
                if isEditing {
                    commitToolRename()
                } else {
                    beginToolEdit(tool, inAllSection: inAllSection)
                }
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Rename")
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

    /// The identifier as shown: the real value normally, or a stable decoy
    /// while the screenshot aid is on.
    private func shownID(_ id: String) -> String {
        decoyingIDs ? Self.decoyID(for: id) : id
    }

    /// A format-preserving decoy for a hardware identifier. Every digit and
    /// letter is swapped for a deterministic stand-in — same input always
    /// yields the same output, so one device wears one stable fake serial
    /// across the session — while the "0x" prefix and separators are kept so
    /// the result still reads as a plausible serial. Case and the hex-vs-
    /// non-hex split are preserved per character: hex digits stay hex (so an
    /// "0x…" id still looks like valid hex) and a distinctive serial letter
    /// like the "G" in "1GQ…" maps to another such letter rather than
    /// surviving verbatim. Display-only; the registry is untouched.
    static func decoyID(for id: String) -> String {
        // FNV-1a over the whole id seeds the stream, so the decoy depends on
        // the entire value, not just each character in isolation.
        var seed: UInt64 = 1469598103934665603
        for byte in id.utf8 { seed = (seed ^ UInt64(byte)) &* 1099511628211 }
        let hexLower = Array("0123456789abcdef")
        let hexUpper = Array("0123456789ABCDEF")
        let nonHexLower = Array("ghijklmnopqrstuvwxyz")
        let nonHexUpper = Array("GHIJKLMNOPQRSTUVWXYZ")
        let chars = Array(id)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            // Preserve the literal "0x" hex marker so it doesn't get mangled.
            if c == "0", i + 1 < chars.count, chars[i + 1] == "x" || chars[i + 1] == "X" {
                out.append(c)
                out.append(chars[i + 1])
                i += 2
                continue
            }
            seed = (seed ^ UInt64(c.asciiValue ?? 0)) &* 1099511628211
            let pick = Int(seed & 0x1F)
            if c.isNumber {
                out.append(hexLower[pick % 10])
            } else if ("a"..."f").contains(c) {
                out.append(hexLower[pick % 16])
            } else if ("A"..."F").contains(c) {
                out.append(hexUpper[pick % 16])
            } else if ("g"..."z").contains(c) {
                out.append(nonHexLower[pick % 20])
            } else if ("G"..."Z").contains(c) {
                out.append(nonHexUpper[pick % 20])
            } else {
                // Separators and anything else pass through unchanged.
                out.append(c)
            }
            i += 1
        }
        return out
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
        registerRenameUndo(
            String(localized: "Rename Tablet", comment: "Undo action name when renaming a tablet"),
            apply: { registry.renameTablet(id: id, to: $0) },
            from: oldName, to: trimmed)
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
            let renameToolAction = String(localized: "Rename Tool", comment: "Undo action name when renaming a tool")
            registry.renameToolEverywhere(id: toolID, to: trimmed)
            registerRenameUndo(
                renameToolAction,
                apply: { registry.renameToolEverywhere(id: toolID, to: $0) },
                from: oldName, to: trimmed)
            // Carry the new name to the folded-in eraser entry so places
            // that surface the active tool by id (status bar, Info pane)
            // stay consistent with the merged row. Both undos land in the
            // same runloop group, so one Undo reverts the pair.
            if let eraserID = Self.eraserSiblingID(of: toolID),
                let eraser = registry.allKnownTools.first(where: { $0.id == eraserID })
            {
                let oldEraserName = eraser.nickname
                let newEraserName = "\(trimmed) (Eraser)"
                registry.renameToolEverywhere(id: eraserID, to: newEraserName)
                registerRenameUndo(
                    renameToolAction,
                    apply: { registry.renameToolEverywhere(id: eraserID, to: $0) },
                    from: oldEraserName, to: newEraserName)
            }
            return
        }

        guard let deviceID = effectiveTabletID,
            let tool = registry.knownTools.first(where: { $0.id == toolID })
        else { return }
        // Empty or unchanged names end the edit and keep the old name.
        guard !trimmed.isEmpty, trimmed != tool.nickname else { return }
        let oldName = tool.nickname
        let renameToolAction = String(localized: "Rename Tool", comment: "Undo action name when renaming a tool")
        registry.renameTool(id: toolID, to: trimmed, forDevice: deviceID)
        registerRenameUndo(
            renameToolAction,
            apply: { registry.renameTool(id: toolID, to: $0, forDevice: deviceID) },
            from: oldName, to: trimmed)
        // Carry the new name to the folded-in eraser entry — see the
        // all-tablets branch above.
        if let eraserID = Self.eraserSiblingID(of: toolID),
            let eraser = registry.knownTools.first(where: { $0.id == eraserID })
        {
            let oldEraserName = eraser.nickname
            let newEraserName = "\(trimmed) (Eraser)"
            registry.renameTool(id: eraserID, to: newEraserName, forDevice: deviceID)
            registerRenameUndo(
                renameToolAction,
                apply: { registry.renameTool(id: eraserID, to: $0, forDevice: deviceID) },
                from: oldEraserName, to: newEraserName)
        }
    }

    // MARK: - Undo/Redo helpers

    /// Registers an undoable rename, self-recursively so it also redoes —
    /// same idiom as `TabletSettings.recordToggle`, needed here because
    /// `DeviceRegistry` renames bypass `TabletSettings.record` entirely.
    private func registerRenameUndo(_ name: String, apply: @escaping (String) -> Void, from oldValue: String, to newValue: String) {
        undoManager?.registerUndo(withTarget: registry) { _ in
            apply(oldValue)
            self.registerRenameUndo(name, apply: apply, from: newValue, to: oldValue)
        }
        undoManager?.setActionName(name)
    }

    /// Self-recursive so "Remove Tool" also redoes: undo restores every
    /// snapshot, then re-removes the same tool ids the same way (per-device
    /// vs. everywhere, per snapshot) and re-registers.
    private func registerToolRemovalUndo(_ snapshots: [DeviceRegistry.ToolRemovalSnapshot]) {
        undoManager?.registerUndo(withTarget: registry) { target in
            for snapshot in snapshots { target.restoreTool(snapshot) }
            self.registerToolRemovalRedo(snapshots)
        }
        undoManager?.setActionName(String(localized: "Remove Tool", comment: "Undo action name when removing a tool"))
    }

    /// Registers the re-removal as its own undoable step, so it only runs
    /// when Redo actually fires — not synchronously inside the undo closure
    /// above (which would restore the tool and instantly re-delete it).
    private func registerToolRemovalRedo(_ oldSnapshots: [DeviceRegistry.ToolRemovalSnapshot]) {
        undoManager?.registerUndo(withTarget: registry) { target in
            var newSnapshots: [DeviceRegistry.ToolRemovalSnapshot] = []
            for old in oldSnapshots {
                let snapshot: DeviceRegistry.ToolRemovalSnapshot?
                if old.originDeviceID.isEmpty {
                    snapshot = target.forgetToolEverywhere(id: old.tool.id)
                } else {
                    snapshot = target.forgetTool(id: old.tool.id, forDevice: old.originDeviceID)
                }
                if let snapshot { newSnapshots.append(snapshot) }
            }
            guard !newSnapshots.isEmpty else { return }
            self.registerToolRemovalUndo(newSnapshots)
        }
        undoManager?.setActionName(String(localized: "Remove Tool", comment: "Undo action name when removing a tool"))
    }

    /// Self-recursive so "Remove Tablet" also redoes.
    private func registerTabletRemovalUndo(_ snapshot: DeviceRegistry.TabletRemovalSnapshot) {
        undoManager?.registerUndo(withTarget: registry) { target in
            target.restoreTablet(snapshot)
            self.registerTabletRemovalRedo(snapshot)
        }
        undoManager?.setActionName(String(localized: "Remove Tablet", comment: "Undo action name when removing a tablet"))
    }

    /// Registers the re-removal as its own undoable step — see
    /// `registerToolRemovalRedo` above for why this can't run inline.
    private func registerTabletRemovalRedo(_ old: DeviceRegistry.TabletRemovalSnapshot) {
        undoManager?.registerUndo(withTarget: registry) { target in
            guard let newSnapshot = target.removeTablet(id: old.tablet.id) else { return }
            self.registerTabletRemovalUndo(newSnapshot)
        }
        undoManager?.setActionName(String(localized: "Remove Tablet", comment: "Undo action name when removing a tablet"))
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
