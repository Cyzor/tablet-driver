import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var tabletManager: TabletManager
    @EnvironmentObject var settings: TabletSettings

    var body: some View {
        // Status indicator — disabled so it's informational only.
        Button {} label: {
            Label(
                tabletManager.isConnected
                    ? "\(tabletManager.connectedDeviceName) connected"
                    : "No tablet detected",
                systemImage: tabletManager.isConnected ? "circle.fill" : "circle"
            )
        }
        .disabled(true)

        Divider()

        // Preset submenu — shown only when at least one preset exists.
        if !settings.presets.isEmpty {
            Menu {
                Button {
                    settings.activate(nil)
                } label: {
                    if settings.activePreset == nil {
                        Label("Device Defaults", systemImage: "checkmark")
                    } else {
                        Text("Device Defaults")
                    }
                }

                Divider()

                ForEach(settings.presets) { preset in
                    Button {
                        settings.activate(preset)
                    } label: {
                        if settings.activePreset?.id == preset.id {
                            Label(preset.name, systemImage: "checkmark")
                        } else {
                            Text(preset.name)
                        }
                    }
                }
            } label: {
                switch settings.activationSource {
                case .manual:
                    Text("Preset: \(settings.activePreset?.name ?? "Device Defaults")")
                case .app(_, let appName):
                    Text("Preset: \(settings.activePreset?.name ?? "Device Defaults")  (\(appName))")
                }
            }

            Divider()
        }

        Button("Preferences…") {
            PreferencesWindowController.shared.show()
        }

        Divider()

        Button("Quit MockTab") {
            NSApp.terminate(nil)
        }
    }
}
