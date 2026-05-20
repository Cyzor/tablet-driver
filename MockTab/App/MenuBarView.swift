// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ServiceManagement
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var tabletManager: TabletManager
    @EnvironmentObject var settings: TabletSettings
    @EnvironmentObject var pwc: PreferencesWindowController

    @AppStorage("showInDock") private var showInDock: Bool = true
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)

    var body: some View {
        Button(String(localized: "Tablet Area", comment: "Menu item: open Tablet Area tab")) {
            pwc.showTab(at: 0)
        }

        Button(String(localized: "Button Mapping", comment: "Menu item: open Button Mapping tab")) {
            pwc.showTab(at: 2)
        }

        Divider()

        Button(String(localized: "Detect Tablet", comment: "Menu item: detect and focus active tablet")) {
            AppMenuController.activateBestDevice()
        }

        // Known-tablet list — mirrors the Tablet menu in the main menu bar.
        // A filled checkmark marks currently connected devices; disconnected
        // (but previously seen) devices are listed without an indicator so the
        // user can still open their settings window.
        let knownTablets = DeviceRegistry.shared.knownTablets
        if !knownTablets.isEmpty {
            Divider()
            ForEach(knownTablets) { tablet in
                // SwiftUI strips Label icons from top-level items in a
                // `.menu`-style MenuBarExtra, so encode the connected indicator
                // directly in the title text.  A two-space prefix on all entries
                // pre-indents the block so the ✓/blank variation is visually
                // contained within the section rather than shifting the name.
                let name = pwc.menuLabel(forProductID: tablet.id)
                // Use an em space (U+2003) as the gutter placeholder so the
                // name column stays fixed regardless of checkmark presence.
                // ✓ + regular space ≈ 1em in SF Pro at menu size, so both
                // variants reach the name at the same horizontal position.
                let title = tabletManager.connectedProductIDs.contains(tablet.id)
                    ? "✓ \(name)"
                    : "\u{2003}\(name)"
                Button(title) {
                    pwc.openWindow(forProductID: tablet.id)
                }
            }
        }

        // Window list — shown when more than one window is open so the user
        // can jump directly to a specific tablet without opening the app first.
        if pwc.windowDescriptors.count > 1 {
            Divider()
            ForEach(pwc.windowDescriptors) { descriptor in
                Button(descriptor.label) {
                    pwc.focusWindow(id: descriptor.id)
                }
            }
        }

        // Profile submenu — shown only when at least one profile exists.
        if !settings.profiles.isEmpty {
            Divider()
            Menu {
                Button {
                    settings.activate(nil)
                } label: {
                    if settings.activeProfile == nil {
                        Label(
                            String(
                                localized: "Device Defaults",
                                comment: "Profile option: use device's default settings"),
                            systemImage: "checkmark")
                    } else {
                        Text(
                            String(
                                localized: "Device Defaults",
                                comment: "Profile option: use device's default settings"))
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
                    Text(
                        String(
                            localized: "Profile: \(settings.activeProfile?.name ?? "Device Defaults")",
                            comment: "Menu label showing current active profile"))
                case .app(_, let appName):
                    Text(
                        String(
                            localized:
                                "Profile: \(settings.activeProfile?.name ?? "Device Defaults")  (\(appName))",
                            comment:
                                "Menu label showing current active profile and triggering app"))
                }
            }
        }

        Divider()

        Toggle(
            String(localized: "Launch at Login", comment: "Menu toggle: start app automatically on login"),
            isOn: $launchAtLogin)
        .onChange(of: launchAtLogin) { enabled in
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = !enabled
            }
        }

        Toggle(
            String(localized: "Show in Dock", comment: "Menu toggle: show app icon in dock"),
            isOn: $showInDock)
        .onChange(of: showInDock) { show in
            NSApp.setActivationPolicy(show ? .regular : .accessory)
        }

        Divider()

        Button(String(localized: "Quit MockTab", comment: "Menu button: quit the application")) {
            NSApp.terminate(nil)
        }
    }
}
