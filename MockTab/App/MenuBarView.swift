// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026  This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab.  If not, see <https://www.gnu.org/licenses/>.

import AppKit
import ServiceManagement
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var tabletManager: TabletManager
    @EnvironmentObject var settings: TabletSettings

    @AppStorage("showInDock") private var showInDock: Bool = true
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)

    var body: some View {
        // Status indicator — disabled so it's informational only.
        Button {
        } label: {
            Label(
                tabletManager.isConnected
                    ? "\(tabletManager.connectedDeviceName) connected"
                    : "No tablet detected",
                systemImage: tabletManager.isConnected ? "circle.fill" : "circle"
            )
        }
        .disabled(true)

        Divider()

        // Profile submenu — shown only when at least one profile exists.
        if !settings.profiles.isEmpty {
            Menu {
                Button {
                    settings.activate(nil)
                } label: {
                    if settings.activeProfile == nil {
                        Label("Device Defaults", systemImage: "checkmark")
                    } else {
                        Text("Device Defaults")
                    }
                }

                Divider()

                ForEach(settings.profiles) { profile in
                    Button {
                        settings.activate(profile)
                    } label: {
                        if settings.activeProfile?.id == profile.id {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
            } label: {
                switch settings.activationSource {
                case .manual:
                    Text("Profile: \(settings.activeProfile?.name ?? "Device Defaults")")
                case .app(_, let appName):
                    Text(
                        "Profile: \(settings.activeProfile?.name ?? "Device Defaults")  (\(appName))")
                }
            }

            Divider()
        }

        Divider()

        Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() }
                    else       { try SMAppService.mainApp.unregister() }
                } catch {
                    launchAtLogin = !enabled
                }
            }

        Toggle("Show in Dock", isOn: $showInDock)
            .onChange(of: showInDock) { show in
                NSApp.setActivationPolicy(show ? .regular : .accessory)
            }

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
