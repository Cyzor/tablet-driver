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
                    ? String(localized: "\(tabletManager.connectedDeviceName) connected", comment: "Menu bar status: tablet connected with device name")
                    : String(localized: "No tablet detected", comment: "Menu bar status: no tablet currently connected"),
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
                        Label(String(localized: "Device Defaults", comment: "Profile option: use device's default settings"), systemImage: "checkmark")
                    } else {
                        Text(String(localized: "Device Defaults", comment: "Profile option: use device's default settings"))
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
                    Text(String(localized: "Profile: \(settings.activeProfile?.name ?? "Device Defaults")", comment: "Menu label showing current active profile"))
                case .app(_, let appName):
                    Text(
                        String(localized: "Profile: \(settings.activeProfile?.name ?? "Device Defaults")  (\(appName))", comment: "Menu label showing current active profile and triggering app"))
                }
            }

            Divider()
        }

        Divider()

        Toggle(String(localized: "Launch at Login", comment: "Menu toggle: start app automatically on login"), isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() }
                    else       { try SMAppService.mainApp.unregister() }
                } catch {
                    launchAtLogin = !enabled
                }
            }

        Toggle(String(localized: "Show in Dock", comment: "Menu toggle: show app icon in dock"), isOn: $showInDock)
            .onChange(of: showInDock) { show in
                NSApp.setActivationPolicy(show ? .regular : .accessory)
            }

        Divider()

        Button(String(localized: "Preferences…", comment: "Menu button: open preferences window")) {
            PreferencesWindowController.shared.show()
        }

        Divider()

        Button(String(localized: "Quit MockTab", comment: "Menu button: quit the application")) {
            NSApp.terminate(nil)
        }
    }
}
