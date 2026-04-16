
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
            Text(LocalizedStringKey("Import Configuration")).font(.headline)
            if !plan.sourceDate.isEmpty {
                Text(String(localized: "Exported \(formattedDate(plan.sourceDate))", comment: "Label showing when the backup was created"))
                    .font(.settingsLabel).foregroundStyle(.secondary)
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
                            if excluded.contains(entry.productID) {
                                excluded.remove(entry.productID)
                            } else {
                                excluded.insert(entry.productID)
                            }
                        }
                }
            }
            .padding(16)
        }
        .frame(minHeight: 80, maxHeight: 300)
    }

    private var note: some View {
        Text(
            "Each tablet's settings will be added as a new profile. " +
            "Your current settings are not changed until you activate a profile."
        )
        .font(.settingsLabel).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button(LocalizedStringKey("Cancel")) { onDismiss() }
                .keyboardShortcut(.cancelAction)
            Button(includedCount == 0 ? String(localized: "Import") : "Import \(includedCount)") {
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

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.nickname).fontWeight(.medium)
                        .foregroundStyle(isExcluded ? Color.secondary : Color.primary)
                    Text(entry.modelName).font(.settingsBadge)
                        .foregroundStyle(.secondary)
                }

                if !isExcluded {
                    HStack(spacing: 4) {
                        Text("→ New profile:").font(.settingsLabel).foregroundStyle(.secondary)
                        Text("\"\(finalName)\"").font(.settingsLabel)
                            .foregroundStyle(renamed ? Color.orange : Color.secondary)
                        if renamed {
                            Text("(renamed to avoid conflict)").font(.settingsBadge).foregroundStyle(.orange)
                        }
                    }
                    if !entry.isKnown {
                        Text("Not in your registry — profile will be available when this tablet connects.")
                            .font(.settingsBadge).foregroundStyle(.orange)
                    }
                    Text("\(entry.profileValues.count) setting\(entry.profileValues.count == 1 ? "" : "s")")
                        .font(.settingsBadge).foregroundStyle(.tertiary)
                } else {
                    Text("Skipped").font(.settingsLabel).foregroundStyle(.secondary)
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
