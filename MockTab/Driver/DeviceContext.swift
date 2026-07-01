// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import Foundation
import IOKit.hid
import TabletKit

/// Per-device bundle of settings, input injector, and tablet driver.
///
/// Each connected tablet gets its own context so that smoothing history,
/// click counters, proximity state, and user preferences are fully isolated.
/// `TabletManager` keeps a dictionary of these keyed by product ID and
/// tracks which one is currently active (posting CGEvents).
@MainActor
final class DeviceContext: ObservableObject, Identifiable {

    let id: Int  // productID — also serves as Identifiable key
    let productID: Int  // canonical (USB) product ID
    let rawProductID: Int  // actual transport-specific PID from hardware

    /// For the ACK-40401 wireless dongle, the PID of the paired tablet
    /// discovered from the 0x80 status report (e.g. 0x0316 for PTH-651).
    /// 0 until the first status report identifies the tablet.
    @Published var pairedProductID: Int = 0
    let settings: TabletSettings
    let injector: InputInjector

    /// The decoded HID driver for this tablet.  Set when the IOHIDDevice
    /// connects and cleared on disconnect (but the context itself survives
    /// so settings are preserved for reconnection).
    var tabletDevice: (any TabletDevice)?

    /// The raw IOHIDDevice handle — weak because IOKit owns the lifetime.
    weak var hidDevice: IOHIDDevice?

    /// Serial number of the pen currently in proximity on this device.
    /// 0 = unknown (IntuosV1) or no pen in proximity.
    @Published var activeToolSerial: UInt32 = 0

    /// True when the tool currently in proximity is a cordless mouse accessory.
    @Published var activeToolIsMouse: Bool = false

    /// Wacom tool code for the pen currently in proximity (e.g. 0x0802 Grip Pen).
    /// 0 when no tool is in proximity.
    @Published var activeToolCode: UInt16 = 0

    /// The ToolSettings for the pen currently in proximity.
    /// Points to the device-default ToolSettings until the first tool-enter fires.
    @Published var activeTool: ToolSettings

    // MARK: - Per-device observable state (synced from driver callbacks)

    /// True when this device is currently connected.
    @Published var isConnected: Bool = false

    /// Transport type for this device: "USB", "Bluetooth", "Other", or "—".
    @Published var transport: String = "—"

    /// USB speed label if connected via USB: "Low Speed", "Full Speed", "High Speed", "Super Speed", etc.
    @Published var usbSpeed: String = "—"

    /// Battery percentage (0–100) if this device is BT; nil if USB or unknown.
    @Published var batteryPercent: Int? = nil

    /// True if the device is currently charging (BT only).
    @Published var batteryCharging: Bool = false

    /// Short string to append to a tablet's menu label when battery data is available.
    /// Returns "" for USB devices or when no battery report has been received yet.
    var batteryMenuSuffix: String {
        guard let pct = batteryPercent else { return "" }
        return batteryCharging ? "  \(pct)% ⚡" : "  \(pct)%"
    }

    /// Serial ID (as hex string) of the tool currently in proximity, or nil.
    @Published var activeToolID: String? = nil

    /// Last-seen pen/stylus point at tablet coordinates.
    @Published var livePoint: TabletPoint? = nil

    /// Live button state for the pen/stylus and device.
    @Published var liveButtons: LiveButtonState = .init()

    /// Subscriptions managed by this context (e.g., to TabletManager for change propagation).
    var cancellables: Set<AnyCancellable> = []

    /// Subscriptions for the input-injection snapshot pipeline. Cleared and rebuilt
    /// whenever `settings.activeTool` changes so the inner ToolSettings observer
    /// always tracks the live tool.
    private var snapshotCancellables: Set<AnyCancellable> = []
    private var activeToolObserver: AnyCancellable?

    /// Subscribe to ring slot changes so the physical LED tracks the active mode.
    /// Call this once after `tabletDevice` is assigned.
    func observeRingLED() {
        settings.$touchRingActiveSlotIndex
            .sink { [weak self] index in
                self?.tabletDevice?.setRingLED(index: index)
            }
            .store(in: &cancellables)
    }

    /// Keep `injector.injectionSnapshot` in sync with the live TabletSettings/ToolSettings.
    ///
    /// `objectWillChange` fires *before* the new value is published, so we hop through
    /// `RunLoop.main` and debounce so the rebuild reads the post-update state. Each
    /// rebuild is published onto HIDThread via `CFRunLoopPerformBlock`, so inject()
    /// reads the snapshot from the same thread that wrote it (HIDThread is a serial
    /// run-loop thread). The inner ToolSettings subscription is replaced whenever
    /// `activeTool` swaps, so per-tool field edits (pressure curve, smoothing,
    /// button bindings) are also reflected.
    func observeInjectionSnapshot() {
        // Seed synchronously so the first inject() always sees a snapshot.
        // Both the main-side property and the HIDThread-visible read path are written
        // here; on the inject path, HIDThread reads what was last written via
        // CFRunLoopPerformBlock.
        let initial = settings.makeInjectionSnapshot()
        injector.injectionSnapshot = initial
        let injectorRef = injector
        CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) {
            injectorRef.injectionSnapshot = initial
        }
        CFRunLoopWakeUp(HIDThread.shared.runLoop)

        let rebuild: () -> Void = { [weak self] in
            guard let self else { return }
            let snap = self.settings.makeInjectionSnapshot()
            let injectorRef = self.injector
            CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) {
                injectorRef.injectionSnapshot = snap
            }
            CFRunLoopWakeUp(HIDThread.shared.runLoop)
        }

        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { _ in rebuild() }
            .store(in: &snapshotCancellables)

        // Re-bind the inner tool observer whenever activeTool swaps.
        let bindTool: (ToolSettings) -> Void = { [weak self] tool in
            guard let self else { return }
            self.activeToolObserver = tool.objectWillChange
                .receive(on: RunLoop.main)
                .sink { _ in rebuild() }
        }
        bindTool(settings.activeTool)
        settings.$activeTool
            .sink { tool in
                bindTool(tool)
                rebuild()  // tool reference itself changed — refresh immediately
            }
            .store(in: &snapshotCancellables)
    }

    init(productID: Int, rawProductID: Int? = nil, vendorID: Int = 0x056A) {
        self.id = productID
        self.productID = productID
        self.rawProductID = rawProductID ?? productID
        let s = TabletSettings(productID: productID)
        self.settings = s
        self.injector = InputInjector(vendorID: vendorID, productID: productID)
        self.activeTool = s.activeTool
    }
}
