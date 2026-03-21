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

            Button("Preferences…") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    PreferencesWindowController.shared.show()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(width: 200)
    }
}
