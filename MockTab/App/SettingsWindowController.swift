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
import SwiftUI

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - ResizableWindow

final class ResizableWindow: NSWindow {

    @objc dynamic override var styleMask: NSWindow.StyleMask {
        get { super.styleMask }
        set { super.styleMask = newValue.union(.resizable) }
    }

    @objc dynamic override var maxSize: NSSize {
        get { NSSize(width: super.maxSize.width, height: .greatestFiniteMagnitude) }
        set { super.maxSize = NSSize(width: newValue.width, height: .greatestFiniteMagnitude) }
    }

    override func toggleFullScreen(_ sender: Any?) { zoom(sender) }

    override func zoom(_ sender: Any?) {
        guard let screen = screen ?? NSScreen.main else {
            super.zoom(sender)
            return
        }
        let visible = screen.visibleFrame
        let alreadyMaximised =
            abs(frame.height - visible.height) < 2
            && abs(frame.minY - visible.minY) < 2
        if alreadyMaximised {
            super.zoom(sender)
        } else {
            setFrame(
                NSRect(
                    x: frame.minX, y: visible.minY,
                    width: frame.width, height: visible.height),
                display: true, animate: true)
        }
    }
}

// MARK: - ResizableTabViewController

final class ResizableTabViewController: NSTabViewController {

    private var defaultTabSizes: [String: NSSize] = [:]

    /// Set to true the first time the user manually resizes the window.
    /// Once set, tab switches no longer resize the window — the user's
    /// chosen size is used for all tabs.
    private var userHasResized = false

    /// Called when the active tab changes — used to notify TabletManager
    /// whether the Info tab is currently visible.
    var onTabSelected: ((String?) -> Void)?

    func register(defaultSize: NSSize, forTabLabeled label: String) {
        defaultTabSizes[label] = defaultSize
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        applyDefaultSize(for: tabViewItem)
        onTabSelected?(tabViewItem?.label)
        updateWindowTitle(for: tabViewItem)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        onTabSelected?(tabViewItems[safe: selectedTabViewItemIndex]?.label)
        updateWindowTitle(for: tabViewItems[safe: selectedTabViewItemIndex])

        // Begin tracking resize events now that the window exists.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: view.window)
    }

    @objc private func windowDidResize(_ notification: Notification) {
        userHasResized = true
    }

    private func applyDefaultSize(for item: NSTabViewItem?) {
        guard !userHasResized,
            let label = item?.label,
            let size = defaultTabSizes[label],
            let window = view.window
        else { return }
        if abs(window.frame.width - size.width) > 2
            || abs(window.frame.height - size.height) > 2
        {
            window.setContentSize(size)
        }
    }

    private func updateWindowTitle(for item: NSTabViewItem?) {
        guard let window = view.window else { return }
        // hosting.title was set to "Label — DeviceName" for device-specific tabs
        // and plain "Label" for shared tabs in SettingsWindowController.addTab.
        if let title = item?.viewController?.title, !title.isEmpty {
            window.title = title
        }
    }
}

// MARK: - SettingsWindowController

@MainActor
final class SettingsWindowController: NSWindowController {

    let settings: TabletSettings
    let deviceLabel: String
    let productID: Int?
    let docUndoManager = UndoManager()

    /// Expose undoManager for PreferencesWindowController access
    /// Named settingsUndoManager to avoid conflict with NSResponder.undoManager
    var settingsUndoManager: UndoManager? { docUndoManager }

    private let tabVC = ResizableTabViewController()

    static let tabLabels = [
        "Tablet Area", "Pressure", "Buttons", "Display",
        "Devices", "Profiles", "Scratchpad", "Info",
    ]

    private static let deviceSpecificTabIndices: Set<Int> = [0, 1, 2, 3]

    init(settings: TabletSettings, deviceLabel: String, productID: Int?) {
        self.settings = settings
        self.deviceLabel = deviceLabel
        self.productID = productID

        tabVC.tabStyle = .toolbar

        let window = ResizableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = tabVC
        window.title = "MockTab"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed]
        window.setFrameAutosaveName("MockTabSettingsWindow")

        super.init(window: window)

        // Set up undo manager for settings layer
        // Note: NSWindow.undoManager is read-only, so we can't wire Cmd+Z through the window
        // Instead, we rely on the Edit menu items being enabled via canUndo/canRedo
        settings.undoManager = docUndoManager
        settings.activeTool.undoManager = docUndoManager

        // Wire up the live-state visibility flag so TabletManager can skip
        // @Published UI writes when nobody is looking at live data.
        // Both "Info" (pen coordinates/pressure) and "Buttons" (live indicators)
        // consume livePoint/liveButtons, so either tab enables the updates.
        // Also check window focus: only update when this window is key (active).
        let updateVisibility = { [weak self, weak window] in
            guard let self else { return }
            let label =
                self.tabVC.tabViewItems[safe: self.tabVC.selectedTabViewItemIndex]?.label ?? ""
            let isInfoTab = (label == "Info" || label == "Buttons")
            let isKeyWindow = window?.isKeyWindow ?? false
            Task { @MainActor in
                TabletManager.shared.infoViewVisible = isInfoTab && isKeyWindow
            }
        }

        tabVC.onTabSelected = { [weak self] _ in
            guard self != nil else { return }
            updateVisibility()
        }

        // Update when window gains/loses focus.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            guard self != nil else { return }
            updateVisibility()
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main
        ) { _ in
            Task { @MainActor in
                TabletManager.shared.infoViewVisible = false
            }
        }

        // Clear the flag when the window closes.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window, queue: .main
        ) { _ in TabletManager.shared.infoViewVisible = false }

        let s = settings
        let tm = TabletManager.shared
        let dr = DeviceRegistry.shared
        let um = docUndoManager
        let onDevice: (Int) -> Void = { [weak self] pid in
            guard let self else { return }
            PreferencesWindowController.shared.replaceWindow(self, withDeviceID: pid)
        }

        addTab(label: "Tablet Area", symbol: "rectangle.dashed", height: 420) {
            TabletAreaView(
                settings: s, tabletManager: tm, registry: dr,
                onDeviceSelected: onDevice, boundProductID: productID)
        }
        addTab(label: "Pressure", symbol: "scribble.variable", height: 480) {
            PressureCurveView(settings: s, tool: s.activeTool, tabletManager: tm, registry: dr)
        }
        addTab(label: "Buttons", symbol: "square.grid.2x2.fill", height: 575) {
            ButtonMappingView(
                settings: s, tool: s.activeTool, tabletManager: tm, registry: dr,
                productID: productID)
        }
        addTab(label: "Display", symbol: "display", height: 370) {
            DisplayMappingView(settings: s, tabletManager: tm, registry: dr)
        }
        addTab(label: "Devices", symbol: "rectangle.on.rectangle", height: 480, width: 620) {
            DevicesView(tabletManager: tm, registry: dr, undoManager: um)
        }
        addTab(label: "Profiles", symbol: "star.circle", height: 450) {
            ProfilesView(settings: s)
        }
        addTab(label: "Scratchpad", symbol: "pencil.and.outline", height: 360) {
            ScratchpadView(settings: s)
        }
        addTab(label: "Info", symbol: "info.circle", height: 430) {
            InfoView(tabletManager: tm, settings: s)
        }

        // Set minimum window size to accommodate all tabs without truncation.
        // Use 1:1 aspect ratio (minWidth = minHeight) for compact square window.
        let tabLabels = Self.tabLabels
        let font = NSFont.systemFont(ofSize: 13)
        let tabWidths = tabLabels.map { label -> CGFloat in
            let textSize = (label as NSString).size(withAttributes: [.font: font])
            // Icon (~18) + label + padding (~20) + tab spacing
            return textSize.width + 65
        }
        let minWidth = tabWidths.reduce(0, +) + 60  // sum + window margins/borders
        //        window.minSize = NSSize(width: minWidth, height: minWidth)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public

    func show() {
        showWindow(nil)
        // Only activate if not already active to avoid focus cycling
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        // Sync the Info-tab visibility flag for whichever tab is already selected.
        // Only set true if the window is key (in focus) and tab is Info or Buttons.
        let label = tabVC.tabViewItems[safe: tabVC.selectedTabViewItemIndex]?.label
        TabletManager.shared.infoViewVisible =
            (label == "Info" || label == "Buttons") && window?.isKeyWindow == true
    }

    func showTab(at index: Int) {
        show()
        guard index >= 0, index < tabVC.tabViewItems.count else { return }
        tabVC.selectedTabViewItemIndex = index
    }

    func showTab(named name: String) {
        let idx = tabVC.tabViewItems.firstIndex(where: { $0.label == name })
        showTab(at: idx ?? 0)
    }
    //
    var selectedTabIndex: Int { tabVC.selectedTabViewItemIndex }

    // MARK: - Private

    private var nextTabIndex = 0

    private func addTab<Content: View>(
        label: String,
        symbol: String,
        height: CGFloat,
        width: CGFloat = 500,
        @ViewBuilder content: () -> Content
    ) {
        let aligned = content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        let hosting = NSHostingController(rootView: aligned)

        let isDeviceTab = Self.deviceSpecificTabIndices.contains(nextTabIndex)
        hosting.title = isDeviceTab ? "\(label) — \(deviceLabel)" : label

        hosting.preferredContentSize = NSSize(width: width, height: 0)
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
        }

        tabVC.register(
            defaultSize: NSSize(width: width, height: height),
            forTabLabeled: label)

        let item = NSTabViewItem(viewController: hosting)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        tabVC.addTabViewItem(item)

        nextTabIndex += 1
    }
}
