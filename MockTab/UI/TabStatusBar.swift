import SwiftUI

// MARK: - DeviceNameLabel

/// A compact caption line showing the active device's user-assigned nickname
/// plus a green/grey presence dot.  Used as a subtitle under section headings
/// in tabs whose settings are per-device (Pressure, Buttons, Display).
struct DeviceNameLabel: View {
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry:      DeviceRegistry

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tabletManager.isConnected ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var displayName: String {
        guard tabletManager.isConnected else { return "No device connected" }
        let id = tabletManager.connectedProductID
        if let t = registry.knownTablets.first(where: { $0.id == id }) { return t.nickname }
        return TabletManager.deviceName(forProductID: id)
    }
}

// MARK: - ToolNameLabel

/// A compact caption line showing the active tool's user-assigned nickname
/// plus a green/grey proximity dot.  Used as a subtitle under the Pen Buttons
/// section heading, where settings are per-tool (not per-device).
struct ToolNameLabel: View {
    @ObservedObject var tabletManager: TabletManager
    @ObservedObject var registry:      DeviceRegistry

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tabletManager.activeToolID != nil ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var displayName: String {
        guard let toolID = tabletManager.activeToolID else {
            // Fall back to last-seen tool if registry has one
            return registry.knownTools.first?.nickname ?? "No tool in proximity"
        }
        if let t = registry.knownTools.first(where: { $0.id == toolID }) { return t.nickname }
        return toolID
    }
}

// MARK: - PresetStatusBar

/// Slim sticky footer that appears at the bottom of every settings pane.
/// Shows the active preset name (or "Device defaults" when none is active)
/// so the user always knows which configuration layer is in effect.
struct PresetStatusBar: View {
    @ObservedObject var settings: TabletSettings

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: settings.activePreset == nil ? "star" : "star.fill")
                    .font(.caption2)
                    .foregroundStyle(settings.activePreset == nil
                                     ? Color.secondary
                                     : Color.yellow)

                if let preset = settings.activePreset {
                    Text(preset.name)
                        .font(.caption)
                    if case .app(_, let appName) = settings.activationSource {
                        Text("· \(appName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Device defaults")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Preset picker — mirrors the Presets tab and the app menu.
                Menu {
                    // "Device defaults" always appears first; checkmark when active.
                    Button {
                        settings.activate(nil)
                    } label: {
                        if settings.activePreset == nil {
                            Label("Device defaults", systemImage: "checkmark")
                        } else {
                            Text("Device defaults")
                        }
                    }

                    if !settings.presets.isEmpty {
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
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }
}
