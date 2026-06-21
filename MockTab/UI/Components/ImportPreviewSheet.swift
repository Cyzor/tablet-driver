// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Pre-import confirmation sheet showing all tablets in a backup file
/// with checkboxes to include/exclude each one before applying.
struct ImportPreviewSheet: View {
    let plan: ImportPlan
    @ObservedObject var registry: DeviceRegistry
    @ObservedObject var tabletManager: TabletManager
    let offlineSettings: [Int: TabletSettings]
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
            String(localized: "Each tablet's settings will be added as a new profile. Your current settings are not changed until you activate a profile.",
                   comment: "Import sheet: footer explaining that import creates new profiles and doesn't overwrite current settings")
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
        let ts: TabletSettings? =
            tabletManager.contexts[entry.productID]?.settings ??
            offlineSettings[entry.productID]
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
                    Text(String(format:
                        NSLocalizedString(
                            entry.profileValues.count == 1 ? "%d setting" : "%d settings",
                            comment: "Count of settings in imported profile"),
                        entry.profileValues.count))
                        .appFont(.settingsBadge).foregroundStyle(.tertiary)
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

    // MARK: - Actions

    private func applyImport() {
        for entry in plan.entries where !excluded.contains(entry.productID) {
            let ts: TabletSettings
            if let live = tabletManager.contexts[entry.productID]?.settings {
                ts = live
            } else if let offline = offlineSettings[entry.productID] {
                ts = offline
            } else {
                ts = TabletSettings(productID: entry.productID)
            }
            let name = ts.uniqueProfileName(entry.resolvedProfileName)
            ts.importProfile(name: name, from: entry.profileValues)
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
