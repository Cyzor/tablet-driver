// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later


import AppKit
import Combine
import SwiftUI
import TabletKit

// The capture guide's completion screen, shown once a recording is saved.
extension CaptureGuideView {
    func completionView(url: URL) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .appFont(size: 44)
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text(String(localized: "Collection Complete", comment: "Data collection completion status"))
                .appFont(.title3)
                .fontWeight(.semibold)

            HStack(spacing: 8) {
                Button {
                    openGitHubIssue(url: url)
                } label: {
                    Label(String(localized: "Open GitHub Issue…", comment: "Button label: open a pre-filled GitHub issue for device support"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .appControlSize(.small)

                emailButton(url: url)
                    .buttonStyle(.bordered)
                    .appControlSize(.small)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label(String(localized: "Show in Finder", comment: "Button label: open data collection file in Finder"), systemImage: "doc.badge.arrow.up")
                }
                .buttonStyle(.bordered)
                .appControlSize(.small)
            }

            Text(String(localized: "On GitHub, drag the file into the form.", comment: "Caption on the data-collection completion screen"))
                .appFont(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            // Share extensions take only the file, so the address has to be
            // somewhere the user can see and copy.
            if !Self.defaultMailIsAppleMail {
                Text(String(
                    localized: "Email goes to \(Self.reportAddress)",
                    comment: "Caption naming the address for emailed diagnostics"))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Open a pre-filled GitHub issue containing the capture JSON.
    /// Falls back to a short body asking the user to drag-attach the file when
    /// the inline JSON would exceed GitHub's URL form length limit.
    func openGitHubIssue(url: URL) {
        // Identify the device the way the capture file does, not the way the
        // app guessed. `productID` here is the contexts key, and the old title
        // said "Wacom" regardless of who actually made the tablet.
        let pidHex = resolvedInfo.map { String(format: "0x%04X", $0.productID) }
            ?? String(format: "0x%04X", productID)
        let vidHex = resolvedInfo.map { $0.vendorIDHex } ?? "unknown"
        let deviceLabel = resolvedInfo?.name ?? pidHex
        let title = "Device support: \(deviceLabel) (\(vidHex)/\(pidHex))"
        let baseURL = "https://github.com/cyzor/tablet-driver/issues/new"
        let json = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        // These fill the form's **Capture data** field, so they lead with the
        // JSON block rather than restating the device — model, connection, and
        // macOS version have their own fields.
        let inlineBody = """
        <!-- Captured by MockTab — please leave the JSON block intact -->
        <!-- Device: \(deviceLabel) — \(vidHex)/\(pidHex) — \(url.lastPathComponent) -->

        ```json
        \(json)
        ```
        """

        let fallbackBody = """
        <!-- Captured by MockTab -->
        <!-- Device: \(deviceLabel) — \(vidHex)/\(pidHex) -->

        **Attach `\(url.lastPathComponent)`:** drag it here from the Finder window MockTab opened.
        """

        // Name the issue form explicitly. Without `template`, GitHub shows the
        // template chooser and discards everything prefilled here the moment the
        // user picks one — which is the only path Contributing.md documents.
        // With it, prefill is keyed by the form's field `id`s, not `body`.
        var comps = URLComponents(string: baseURL)!
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var items = [
            URLQueryItem(name: "template", value: "device-support.yml"),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "labels", value: "device-support"),
            URLQueryItem(name: "model", value: deviceLabel),
            URLQueryItem(
                name: "macos", value: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            URLQueryItem(name: "capture", value: inlineBody),
        ]
        // The dropdown only accepts one of its declared options; anything else
        // makes GitHub drop the whole prefill, so leave it unset when unsure.
        if let transport = resolvedInfo?.transport,
            Self.connectionOptions.contains(transport)
        {
            items.append(URLQueryItem(name: "connection", value: transport))
        }
        comps.queryItems = items

        // A zip can't be inlined, and /issues/new is served server-side, so the
        // URL must stay under typical limits; 7000 leaves headroom under 8 KB.
        if json.isEmpty || (comps.url?.absoluteString.count ?? 0) > 7000 {
            comps.queryItems = items.map {
                $0.name == "capture" ? URLQueryItem(name: "capture", value: fallbackBody) : $0
            }
        }

        if let u = comps.url {
            NSWorkspace.shared.open(u)
        }
        // The form can't take the file itself; put it where the user can grab it.
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Sends the capture privately: no account, nothing posted. Apple Mail
    /// takes recipient, subject, and attachment directly. Other mail apps
    /// (MailMate, Outlook) take attachments only through their share
    /// extensions, which carry no recipient, so there the button is the
    /// system share menu and the address rides in the message.
    @ViewBuilder
    func emailButton(url: URL) -> some View {
        let label = Label(
            String(localized: "Email…", comment: "Button label: send the data collection file by email"),
            systemImage: "envelope")
        if Self.defaultMailIsAppleMail {
            Button { composeInAppleMail(url: url) } label: { label }
        } else {
            ShareLink(
                item: url,
                subject: Text(emailSubject),
                message: Text(String(
                    localized: "Send to \(Self.reportAddress)",
                    comment: "Line in the diagnostics email body naming the address to send it to")
                    + "\n\n" + emailBody)
            ) { label }
        }
    }

    /// The compose service claims it can mail for any default client, then
    /// hands other clients only address, subject, and text; the file is lost.
    /// So choose by the default client itself.
    static var defaultMailIsAppleMail: Bool {
        guard let mailto = URL(string: "mailto:"),
            let app = NSWorkspace.shared.urlForApplication(toOpen: mailto)
        else { return false }
        return Bundle(url: app)?.bundleIdentifier == "com.apple.mail"
    }

    var emailSubject: String {
        let pidHex = resolvedInfo.map { String(format: "0x%04X", $0.productID) }
            ?? String(format: "0x%04X", productID)
        return "MockTab data: \(resolvedInfo?.name ?? pidHex) (\(pidHex))"
    }

    /// Prompt, room to answer, then the facts a reply would otherwise ask for.
    var emailBody: String {
        let prompt = String(
            localized: "How well is MockTab working for you? Please describe your experience and what needs to improve.\n\n",
            comment: "Prompt placed in the body of the diagnostics email")
        let device = resolvedInfo.map {
            "\($0.name) (\($0.vendorIDHex)/" + String(format: "0x%04X", $0.productID) + ")"
                + ($0.transport.map { ", \($0)" } ?? "")
        } ?? String(format: "0x%04X", productID)
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return prompt + "\n\n—\n"
            + "Tablet: \(device)\n"
            + "MockTab \(version) (\(build)), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)\n"
    }

    func composeInAppleMail(url: URL) {
        guard let service = NSSharingService(named: .composeEmail) else { return }
        service.recipients = [Self.reportAddress]
        service.subject = emailSubject
        service.perform(withItems: [emailBody, url])
    }

    /// Assembled at runtime so address scrapers reading the source find nothing.
    static let reportAddress = ["info", "mocktab.org"].joined(separator: "@")
}
