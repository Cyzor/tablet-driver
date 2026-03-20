import SwiftUI

struct PreferencesView: View {
    @StateObject private var settings = TabletSettings()

    var body: some View {
        TabView {
            TabletAreaView(settings: settings)
                .tabItem { Label("Tablet Area", systemImage: "rectangle.dashed") }

            PressureCurveView(settings: settings)
                .tabItem { Label("Pressure", systemImage: "waveform.path") }

            ButtonMappingView(settings: settings)
                .tabItem { Label("Buttons", systemImage: "hand.point.up.left") }

            DisplayMappingView(settings: settings)
                .tabItem { Label("Display", systemImage: "display") }

            ScratchpadView()
                .tabItem { Label("Scratchpad", systemImage: "scribble") }
        }
        .frame(width: 500, height: 440)
        .onAppear {
            // Wire updated settings into the running TabletManager.
            Task { @MainActor in
                TabletManager.shared.settings = settings
            }
        }
    }
}
