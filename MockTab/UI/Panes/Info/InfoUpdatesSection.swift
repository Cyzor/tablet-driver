// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

extension InfoView {
    var updatesHeader: some View {
        Text(String(localized: "Updates", comment: "Section header in the Info tab: app version and updates"))
            .appFont(.headline)
    }
}

/// The Info pane's Updates section: the only place an update shows.
/// Its own view so update progress redraws these rows, not the whole pane.
struct InfoUpdatesSection: View {
    @ObservedObject private var updates = UpdateController.shared
    /// Relaunching would end a capture, so it waits while one runs.
    @ObservedObject private var captures = CaptureActivity.shared
    /// Option turns Check Now into Check for Pre-release.
    @State private var updateOptionDown = false

    var body: some View { updatesSection }

    /// One leading column for every row, as wide as a Status icon, so the
    /// icon, the notes, the buttons, and the checkbox share two edges.
    private func updateRow<Leading: View, Content: View>(
        alignment: VerticalAlignment = .center,
        @ViewBuilder leading: () -> Leading, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: alignment, spacing: 8) {
            Image(systemName: "minus.circle.fill").hidden().overlay { leading().fixedSize() }
            content()
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        let status = updateStatus
        updateRow {
            Group {
                if status.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: status.symbol)
                        .foregroundStyle(status.tint)
                }
            }
            .accessibilityHidden(true)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                if let progress = status.progress {
                    ProgressView(value: progress).frame(maxWidth: 220)
                } else if status.showsCapture {
                    captureNotice
                } else if let subtitle = status.subtitle {
                    Text(subtitle)
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 12)

            // The website still works when only the helper is blocked.
            if let link = status.link {
                Button(link.label, action: link.run)
                    .fixedSize()
            }
            if let action = status.action {
                Button(action.label, action: action.run)
                    .keyboardShortcut(action.isCancel ? .cancelAction : nil)
                    .disabled(action.isDisabled)
                    .help(action.help ?? "")
                    .fixedSize()
            }
        }
        .padding(.vertical, 2)
        .tracksOptionKey($updateOptionDown)

        switch updates.phase {
        case .available(let offer):
            // Full width, like the diagnostics box.
            Group {
                VStack(alignment: .leading, spacing: 10) {
                    updateNotes(offer.notes)
                    // Default button trails, as in macOS dialogs.
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button(String(localized: "Skip for Now", comment: "Update button: hide the update until the next check")) {
                            updates.skip()
                        }
                        if updates.canInstallInPlace && offer.installable {
                            Button(String(localized: "Install on Quit", comment: "Update button: get the update ready and install it when MockTab quits")) {
                                updates.install(relaunch: false)
                            }
                            .help(String(localized: "Downloads and checks the update now, and installs it the next time MockTab quits.", comment: "Tooltip on Install on Quit"))
                            Button(String(localized: "Install and Relaunch", comment: "Update button: install now; MockTab quits and reopens")) {
                                updates.install(relaunch: true)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(captures.isActive)
                            .help(captures.isActive ? String(localized: "Available once MockTab finishes collecting device data.", comment: "Tooltip on Install and Relaunch or Relaunch Now while they are unavailable because a device data collection is running") : String(localized: "Downloads and checks the update, then quits MockTab, installs it, and opens it again. The pen pauses for about a second.", comment: "Tooltip on Install and Relaunch"))
                        } else {
                            Button(String(localized: "Open Download Page", comment: "Update button: get the update in the browser instead")) {
                                updates.openDownload(offer)
                            }
                            .help(offer.installable
                                ? String(localized: "MockTab can't replace itself in this folder.", comment: "Tooltip on Open Download Page when MockTab's folder isn't writable")
                                : String(localized: "Install this one by hand. Later updates install here.", comment: "Tooltip on Open Download Page when the update needs a newer updater"))
                        }
                    }
                    if captures.isActive && updates.canInstallInPlace && offer.installable { captureNotice }
                }
            }
        case .updated(_, let notes) where !notes.isEmpty:
            updateNotes(notes)
        default:
            EmptyView()
        }

        if updates.hasHelper {
            let autoLabel = String(localized: "Check automatically", comment: "Checkbox in the Info tab's Updates section")
            // The box sits in the icon column; the label stays clickable.
            updateRow(alignment: .firstTextBaseline) {
                Toggle(autoLabel, isOn: $updates.checksAutomatically)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            } content: {
                VStack(alignment: .leading, spacing: 2) {
                    // The box already carries this label for VoiceOver.
                    Text(autoLabel)
                        .onTapGesture { updates.checksAutomatically.toggle() }
                        .accessibilityHidden(true)
                    Text(String(localized: "Once a week while MockTab runs.", comment: "Caption under the automatic update checkbox"))
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .help(String(localized: "A newer version only changes this section. Nothing opens or interrupts you.", comment: "Tooltip on the automatic update checkbox"))
        }
    }

    /// Why relaunching is unavailable, visible without hovering. Show also
    /// proves the capture is real.
    private var captureText: String {
        String(localized: "Collecting device data in another window.", comment: "Updates section: why Install and Relaunch or Relaunch Now is unavailable; Show brings that window forward")
    }

    private var showCapture: UpdateAction {
        UpdateAction(label: String(localized: "Show", comment: "Updates section: bring the window that is collecting device data forward"),
                     run: { CaptureActivity.shared.show() })
    }

    private var captureNotice: some View {
        HStack(spacing: 4) {
            Text(captureText)
                .appFont(.callout)
                .foregroundStyle(.secondary)
            // An in-place arrow, not a button or a link: it only goes there.
            Button(action: showCapture.run) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(showCapture.label)
            .accessibilityLabel(showCapture.label)
        }
    }

    /// One selectable text, so a copy comes out as a plain bulleted list.
    private func updateNotes(_ notes: [String]) -> some View {
        Text(verbatim: notes.map { "• \($0)" }.joined(separator: "\n"))
            .appFont(.body)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .textBox()
    }

    private struct UpdateAction {
        let label: String
        var help: String?
        /// Escape presses it, in the window that has focus.
        var isCancel = false
        var isDisabled = false
        let run: () -> Void
    }

    private struct UpdateStatus {
        var symbol = "arrow.down.circle"
        var tint: Color = .secondary
        var busy = false
        var title: String
        var subtitle: String?
        var progress: Double?
        var action: UpdateAction?
        var link: UpdateAction?
        /// The capture line, with its arrow, in place of the subtitle.
        var showsCapture = false
    }

    private var lastCheckedText: String {
        guard let date = updates.lastChecked else {
            return String(localized: "MockTab hasn't checked yet", comment: "Updates section subtitle before any check")
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        f.locale = UpdateController.textLocale
        return String(localized: "Last checked \(f.string(from: date))", comment: "Updates section subtitle, e.g. 'Last checked Today at 14:00'")
    }

    private var updateStatus: UpdateStatus {
        let version = updates.runningDisplay
        // Holding Option asks for a snapshot; there's no channel setting.
        let wantsSnapshot = updateOptionDown && updates.hasHelper
        let check = wantsSnapshot
            ? UpdateAction(
                label: String(localized: "Check for Pre-release", comment: "Button in the Updates section while Option is held: check for a newer test build"),
                help: String(localized: "Ask mocktab.org whether a pre-release version newer than the latest release is out.", comment: "Tooltip on Check for Pre-release"),
                run: { updates.check(manual: true, snapshot: true) })
            : UpdateAction(
                label: String(localized: "Check Now", comment: "Button in the Updates section: check for a newer version"),
                help: String(localized: "Ask mocktab.org whether a newer MockTab is out.", comment: "Tooltip on Check Now"),
                run: { updates.hasHelper ? updates.check(manual: true) : updates.openUpdatePage() })

        switch updates.phase {
        case .idle:
            return UpdateStatus(title: "MockTab \(version)", subtitle: lastCheckedText, action: check)
        case .checking:
            return UpdateStatus(busy: true,
                                title: String(localized: "Checking for updates…", comment: "Updates section title while a check runs"),
                                subtitle: "MockTab \(version)")
        case .upToDate(let snapshotAvailable):
            return UpdateStatus(symbol: "checkmark.circle.fill", tint: .green,
                                title: String(localized: "MockTab \(version) is up to date", comment: "Updates section title when nothing newer exists"),
                                subtitle: snapshotAvailable
                                    ? String(localized: "A pre-release version is also available. Hold Option to check for it.", comment: "Updates section subtitle when the release is current and a newer test build exists; Option turns Check Now into Check for Pre-release")
                                    : lastCheckedText,
                                action: check)
        case .available(let offer):
            return UpdateStatus(symbol: "arrow.down.circle.fill", tint: .accentColor,
                                title: String(localized: "MockTab \(offer.display) is available", comment: "Updates section title when an update exists"),
                                subtitle: offer.isSnapshot
                                    ? String(localized: "A pre-release version. You have \(version).", comment: "Updates section subtitle under an available pre-release")
                                    : String(localized: "You have \(version).", comment: "Updates section subtitle under an available update"))
        case .downloading(let offer, let percent):
            return UpdateStatus(symbol: "arrow.down.circle", tint: .accentColor,
                                title: String(localized: "Downloading MockTab \(offer.display)…", comment: "Updates section title while an update downloads"),
                                progress: Double(percent) / 100,
                                action: UpdateAction(label: String(localized: "Cancel", comment: "Button in the Updates section: stop the download"),
                                                     isCancel: true,
                                                     run: { updates.cancel() }))
        case .verifying(let offer):
            return UpdateStatus(busy: true,
                                title: String(localized: "Verifying MockTab \(offer.display)…", comment: "Updates section title while a download is verified"))
        case .ready(let offer):
            return UpdateStatus(symbol: "arrow.down.circle.fill", tint: .accentColor,
                                title: String(localized: "MockTab \(offer.display) is ready", comment: "Updates section title when an update waits for quit"),
                                subtitle: String(localized: "It installs when MockTab quits.", comment: "Updates section subtitle when an update waits for quit"),
                                action: UpdateAction(
                                    label: String(localized: "Relaunch Now", comment: "Button in the Updates section: install the waiting update now"),
                                    help: captures.isActive ? String(localized: "Available once MockTab finishes collecting device data.", comment: "Tooltip on Install and Relaunch or Relaunch Now while they are unavailable because a device data collection is running")
                                        : String(localized: "Quits MockTab, installs the update, and opens it again. The pen pauses for about a second.", comment: "Tooltip on Relaunch Now"),
                                    isDisabled: captures.isActive,
                                    run: { updates.relaunchNow() }),
                                showsCapture: captures.isActive)
        case .unreachable:
            return UpdateStatus(symbol: "exclamationmark.circle.fill", tint: .orange,
                                title: String(localized: "Couldn't reach mocktab.org", comment: "Updates section title when the check or download failed to connect"),
                                subtitle: lastCheckedText,
                                action: UpdateAction(label: String(localized: "Try Again", comment: "Button in the Updates section: repeat the check"),
                                                     run: { updates.check(manual: true) }),
                                link: UpdateAction(label: String(localized: "Open Update Page", comment: "Button in the Updates section: check on the website instead"),
                                                   run: { updates.openUpdatePage() }))
        case .downloadFailed(let offer, let host, _):
            return UpdateStatus(symbol: "exclamationmark.circle.fill", tint: .orange,
                                title: String(localized: "Couldn't download MockTab \(offer.display)", comment: "Updates section title when the check worked but the download failed to connect"),
                                subtitle: String(localized: "Couldn't reach \(host).", comment: "Updates section subtitle naming the host a failed download was to come from, e.g. github.com"),
                                action: UpdateAction(label: String(localized: "Try Again", comment: "Button in the Updates section: repeat the check"),
                                                     run: { updates.retryDownload() }),
                                link: UpdateAction(label: String(localized: "Open Download Page", comment: "Update button: get the update in the browser instead"),
                                                   run: { updates.openDownload(offer) }))
        case .unreadable:
            return UpdateStatus(symbol: "exclamationmark.circle.fill", tint: .orange,
                                title: String(localized: "Couldn't read the update information", comment: "Updates section title when the feed is damaged"),
                                subtitle: lastCheckedText,
                                action: UpdateAction(label: String(localized: "Open Update Page", comment: "Button in the Updates section: check on the website instead"),
                                                     run: { updates.openUpdatePage() }))
        case .rejected(let offer):
            return UpdateStatus(symbol: "xmark.circle.fill", tint: .red,
                                title: String(localized: "MockTab refused the update", comment: "Updates section title when a download fails verification"),
                                subtitle: String(localized: "It didn't pass MockTab's checks, so nothing changed.", comment: "Updates section subtitle after a rejected update"),
                                action: UpdateAction(label: String(localized: "Open Download Page", comment: "Update button: get the update in the browser instead"),
                                                     run: { updates.openDownload(offer) }))
        case .needsSystem(let display, let minimum):
            return UpdateStatus(title: String(localized: "MockTab \(display) needs macOS \(minimum) or later", comment: "Updates section title when the newer version can't run on this Mac's macOS"),
                                subtitle: String(localized: "MockTab \(version) is the newest for this Mac.", comment: "Updates section subtitle when the newer version needs a newer macOS"),
                                action: check)
        case .installFailed(let offer):
            return UpdateStatus(symbol: "exclamationmark.circle.fill", tint: .orange,
                                title: String(localized: "Couldn't install MockTab \(offer.display)", comment: "Updates section title when the installer couldn't start or the install failed"),
                                subtitle: String(localized: "You still have \(version).", comment: "Updates section subtitle when an install failed and the running version stays"),
                                action: UpdateAction(label: String(localized: "Open Download Page", comment: "Update button: get the update in the browser instead"),
                                                     run: { updates.openDownload(offer) }))
        case .updated(let display, _):
            return UpdateStatus(symbol: "checkmark.circle.fill", tint: .green,
                                title: String(localized: "Now running MockTab \(display)", comment: "Updates section title on the first launch after an update"),
                                subtitle: String(localized: "What's new:", comment: "Updates section subtitle above the notes after an update"),
                                action: check)
        }
    }
}
