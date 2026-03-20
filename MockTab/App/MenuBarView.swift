import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var tabletManager: TabletManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Circle()
                    .fill(tabletManager.isConnected ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(tabletManager.isConnected ? "Tablet connected" : "No tablet detected")
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if #available(macOS 14.0, *) {
                OpenSettingsButtonModern()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else {
                Button("Preferences…") {
                    // Dispatch after a brief delay so the popover can dismiss first.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            Divider()

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(width: 200)
    }
}

/// Uses the official openSettings environment action (macOS 14+).
@available(macOS 14.0, *)
private struct OpenSettingsButtonModern: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Preferences…") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        .buttonStyle(.plain)
    }
}
