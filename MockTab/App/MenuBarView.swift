import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var tabletManager: TabletManager

    var body: some View {
        // Status indicator — disabled so it's informational only.
        Button {} label: {
            Label(
                tabletManager.isConnected ? "Tablet connected" : "No tablet detected",
                systemImage: tabletManager.isConnected ? "circle.fill" : "circle"
            )
        }
        .disabled(true)

        Divider()

        Button("Preferences…") {
            PreferencesWindowController.shared.show()
        }

        Divider()

        Button("Quit MockTab") {
            NSApp.terminate(nil)
        }
    }
}
