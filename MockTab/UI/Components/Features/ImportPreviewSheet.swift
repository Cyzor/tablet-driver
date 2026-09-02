// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import TabletKit

/// Pre-import confirmation sheet showing all tablets in a backup file
/// with checkboxes to include/exclude each one before applying.
struct ImportPreviewSheet: View {
    let plan: ImportPlan
    @ObservedObject var registry: DeviceRegistry
    @ObservedObject var tabletManager: TabletManager
    /// The currently-open Profiles pane's own settings object. Only this
    /// instance is guaranteed to have `undoManager` wired (set once, per
    /// window, in `SettingsWindowController.init`) — `tabletManager.contexts`
    /// is a PID-keyed derived view that can diverge from it, and offline/
    /// fresh `TabletSettings` instances never get an undo manager at all.
    /// Used so importing into the tablet you're actually viewing is
    /// reliably undoable; other tablets in the same backup fall back to the
    /// lookup chain below and may not be (no window open for them yet).
    let currentPaneSettings: TabletSettings?
    /// The product ID `currentPaneSettings` belongs to — `TabletSettings`
    /// doesn't expose its own productID (identity lives in `devicePrefix`),
    /// so the caller supplies the one it already has.
    let currentPaneProductID: Int?
    /// Keyed by registry row id; import archives are model-keyed, so
    /// lookups go through the model's legacy row id (see `offline(_:)`).
    let offlineSettings: [String: TabletSettings]

    private func offline(_ productID: Int) -> TabletSettings? {
        offlineSettings[DeviceInstanceKey(productID: productID, instance: "").stringValue]
    }
    let onDismiss: () -> Void

    @State private var excluded: Set<Int> = []
    private var includedCount: Int {
        plan.entries.filter { !excluded.contains($0.productID) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            entryList
            Divider()
            note
            Divider()
            buttons
        }
        .frame(width: 420)
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import Configuration").appFont(.headline)
            if !plan.sourceDate.isEmpty {
                Text(String(localized: "Exported \(formattedDate(plan.sourceDate))", comment: "Label showing when the backup was created"))
                    .appFont(.settingsLabel).foregroundStyle(.secondary)
            }
        }
        .padding([.horizontal, .top], 20)
        .padding(.bottom, 12)
    }

    private var entryList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(plan.entries, id: \.productID) { entry in
                    entryRow(entry)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            toggleExclusion(entry.productID)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(rowAccessibilityLabel(for: entry))
                        .accessibilityHint("Double tap to toggle whether this profile is imported")
                        .accessibilityAction {
                            toggleExclusion(entry.productID)
                        }
                }
            }
            .padding(16)
        }
        .frame(minHeight: 80, maxHeight: 300)
    }

    private func toggleExclusion(_ productID: Int) {
        if excluded.contains(productID) {
            excluded.remove(productID)
        } else {
            excluded.insert(productID)
        }
    }

    private func rowAccessibilityLabel(for entry: ImportPlan.TabletEntry) -> String {
        let state: String
        if excluded.contains(entry.productID) {
            state = String(localized: "Excluded", comment: "Accessibility state for an import entry the user has chosen to skip")
        } else if entry.isKnown {
            state = String(localized: "Known tablet", comment: "Accessibility state for a registered tablet entry in the import sheet")
        } else {
            state = String(localized: "Unknown tablet", comment: "Accessibility state for an unregistered tablet entry in the import sheet")
        }
        return "\(entry.nickname), \(entry.modelName), \(state)"
    }

    private var note: some View {
        Text(
            String(localized: "Each tablet's base settings and named presets are added as new profiles — your current settings aren't changed until you activate one. App overrides and per-tool settings apply immediately.",
                   comment: "Import sheet: footer explaining that profiles are inert until activated, but app overrides and tool settings take effect right away")
        )
        .appFont(.settingsLabel).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel", comment: "Import sheet: dismiss button")) { onDismiss() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Import", comment: "Import sheet: import button")) {
                applyImport()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(includedCount == 0)
        }
        .padding(16)
    }

    // MARK: - Entry Row

    @ViewBuilder
    private func entryRow(_ entry: ImportPlan.TabletEntry) -> some View {
        let isExcluded = excluded.contains(entry.productID)
        let ts: TabletSettings? = resolveSettings(for: entry.productID)
        let finalName = ts?.uniqueProfileName(entry.resolvedProfileName) ?? entry.resolvedProfileName
        let renamed = finalName != entry.resolvedProfileName

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isExcluded ? "circle" : (entry.isKnown ? "checkmark.circle.fill" : "questionmark.circle"))
                .foregroundStyle(isExcluded ? Color.secondary : (entry.isKnown ? Color.green : Color.orange))
                .frame(width: 16)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.nickname).fontWeight(.medium)
                        .foregroundStyle(isExcluded ? Color.secondary : Color.primary)
                    Text(entry.modelName).appFont(.settingsBadge)
                        .foregroundStyle(.secondary)
                }

                if !isExcluded {
                    HStack(spacing: 4) {
                        Text(String(localized: "→ New profile:", comment: "Import sheet: label before the profile name that will be created")).appFont(.settingsLabel).foregroundStyle(.secondary)
                        Text("\"\(finalName)\"").appFont(.settingsLabel)
                            .foregroundStyle(renamed ? Color.orange : Color.secondary)
                        if renamed {
                            Text(String(localized: "(renamed to avoid conflict)", comment: "Label when a profile name was changed to avoid a duplicate"))
                                .appFont(.settingsBadge).foregroundStyle(.orange)
                        }
                    }
                    if !entry.isKnown {
                        Text(String(localized: "Not in your registry — profile will be available when this tablet connects.", comment: "Message when importing a profile for a tablet that hasn't been connected yet"))
                            .appFont(.settingsBadge).foregroundStyle(.orange)
                    }
                    Text(String(localized: "\(entry.profileValues.count) setting", comment: "Count of settings in imported profile"))
                        .appFont(.settingsBadge).foregroundStyle(.tertiary)
                    extraContentSummary(for: entry, ts: ts)
                } else {
                    Text(String(localized: "Skipped", comment: "Label when a tablet profile is excluded from import"))
                        .appFont(.settingsLabel).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(
                isExcluded ? Color(NSColor.separatorColor).opacity(0.5) : Color(NSColor.separatorColor),
                lineWidth: 1))
        .opacity(isExcluded ? 0.5 : 1.0)
    }

    /// Counts of presets/overrides/tool-settings found in the backup for this
    /// tablet. Conflicting overrides/tool settings (an existing local
    /// customization for the same app/tool) are always skipped — kept local,
    /// never silently clobbered. There's no overwrite option yet; the
    /// control for that was disconnected until it's wired up for real (see
    /// `importAppOverride`/`importToolSettings`'s `overwrite` parameter).
    @ViewBuilder
    private func extraContentSummary(for entry: ImportPlan.TabletEntry, ts: TabletSettings?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !entry.presets.isEmpty {
                Text(String(localized: "\(entry.presets.count) named preset", comment: "Count of named presets found in the backup for this tablet"))
                    .appFont(.settingsBadge).foregroundStyle(.tertiary)
            }
            if !entry.overrides.isEmpty {
                Text(String(localized: "\(entry.overrides.count) app override", comment: "Count of per-app overrides found in the backup for this tablet"))
                    .appFont(.settingsBadge).foregroundStyle(.tertiary)
            }
            if !entry.toolSettings.isEmpty {
                Text(String(localized: "\(entry.toolSettings.count) tool setting", comment: "Count of per-tool settings found in the backup for this tablet"))
                    .appFont(.settingsBadge).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Actions

    /// Resolves the `TabletSettings` to import into for a given tablet.
    /// Prefers `currentPaneSettings` when it's the same device as `productID`
    /// — the only instance guaranteed to have `undoManager` wired, since
    /// that's set once per window in `SettingsWindowController.init`, not on
    /// `tabletManager.contexts`' derived PID lookup or on offline/fresh
    /// instances. Other tablets in the same backup fall back to that lookup
    /// chain and may end up not undoable — no window is open for them.
    private func resolveSettings(for productID: Int) -> TabletSettings {
        if let currentPaneSettings, currentPaneProductID == productID {
            return currentPaneSettings
        }
        return tabletManager.contexts[productID]?.settings
            ?? offline(productID)
            ?? TabletSettings(productID: productID)
    }

    private func applyImport() {
        for entry in plan.entries where !excluded.contains(entry.productID) {
            let ts = resolveSettings(for: entry.productID)
            let name = ts.uniqueProfileName(entry.resolvedProfileName)
            ts.importProfile(name: name, from: entry.profileValues)

            for preset in entry.presets {
                let presetName = ts.uniqueProfileName(preset.name)
                ts.importProfile(name: presetName, from: preset.values)
            }

            // No overwrite option yet — conflicting overrides/tool settings
            // are always skipped, keeping the local customization untouched.
            for override in entry.overrides {
                ts.importAppOverride(
                    bundleID: override.bundleID, appName: override.appName,
                    from: override.values)
            }
            for tool in entry.toolSettings {
                ts.importToolSettings(toolID: tool.toolID, from: tool.values)
            }
        }
        onDismiss()
    }

    private func formattedDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}
