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
/// `TabletManager` keeps a dictionary of these keyed by physical instance
/// (`DeviceInstanceKey`) and tracks which one is currently active (posting
/// CGEvents).
@MainActor
final class DeviceContext: ObservableObject, Identifiable {

    /// Physical-instance identity. Mutable only through `adoptInstance` —
    /// a window-restore stub is created before the device connects (empty
    /// instance token) and adopts the real identity at first connect so the
    /// window and driver keep sharing one settings object.
    private(set) var instanceKey: DeviceInstanceKey
    private(set) var usbSerial: String?  // IOKit serial at last connect; nil if none
    private(set) var locationID: Int = 0  // IOKit port location at last connect; 0 if none

    /// The raw `kIOHIDSerialNumberKey` string read on a Bluetooth interface,
    /// kept **only** as a candidate Bluetooth address for
    /// `BluetoothLinkMonitor` diagnostics. Deliberately never fed into
    /// `usbSerial` or `instanceKey` — the same value is untrusted for
    /// identity purposes over Bluetooth (see `TabletManager`'s
    /// `rawSerialProbe` read site), and mixing the two uses would risk
    /// re-introducing that bug for a much smaller benefit. `nil` on USB.
    var bluetoothAddressCandidate: String?

    /// Identifiable key. Stored (not derived from `instanceKey`) so it is
    /// nonisolated for the protocol and stays stable when a restore stub
    /// adopts its real instance mid-session.
    nonisolated let id: String
    let productID: Int  // canonical (USB) product ID — model identity
    let rawProductID: Int  // actual transport-specific PID from hardware
    let vendorID: Int  // 0x056A (Wacom) unless a non-Wacom drivable device

    /// For the ACK-40401 wireless dongle, the PID of the paired tablet
    /// discovered from the 0x80 status report (e.g. 0x0316 for PTH-651).
    /// 0 until the first status report identifies the tablet.
    @Published var pairedProductID: Int = 0
    let settings: TabletSettings
    let injector: InputInjector

    /// Decoded HID drivers for this tablet, keyed by raw (transport-specific)
    /// product ID. A canonical identity can have more than one simultaneously
    /// live transport — the Xencelabs Quick Keys puck reachable over both its
    /// wired PID (0x5202) and its wireless dongle (0x5203) is the motivating
    /// case — so this is a set of candidate drivers, not a single slot.
    /// `tabletDevice` below is the computed winner among them.
    private var driverSlots: [Int: any TabletDevice] = [:]

    /// The winning driver among `driverSlots`, ranked by
    /// `VendorDeviceRegistry.transportPriority`. Kept as the property name
    /// and assignment style every existing call site already uses — set
    /// files the driver into today's `rawProductID` slot (matching prior
    /// single-slot behavior 1:1 until callers start passing an explicit raw
    /// PID); nil clears every slot, matching the old unconditional clear on
    /// disconnect.
    var tabletDevice: (any TabletDevice)? {
        get {
            driverSlots.max { lhs, rhs in
                VendorDeviceRegistry.transportPriority(forRawProductID: lhs.key)
                    < VendorDeviceRegistry.transportPriority(forRawProductID: rhs.key)
            }?.value
        }
        set {
            if let newValue {
                driverSlots[rawProductID] = newValue
            } else {
                driverSlots.removeAll()
            }
        }
    }

    /// The raw PID of the slot `tabletDevice` currently resolves to, or nil
    /// if no transport is live.
    var activeDriverRawProductID: Int? {
        driverSlots.max { lhs, rhs in
            VendorDeviceRegistry.transportPriority(forRawProductID: lhs.key)
                < VendorDeviceRegistry.transportPriority(forRawProductID: rhs.key)
        }?.key
    }

    var hasAnyDriverSlot: Bool { !driverSlots.isEmpty }

    func driverSlot(forRawProductID rawPID: Int) -> (any TabletDevice)? {
        driverSlots[rawPID]
    }

    func installDriver(_ driver: any TabletDevice, forRawProductID rawPID: Int) {
        driverSlots[rawPID] = driver
    }

    /// Removes and returns the driver for a departing transport, if any.
    /// Does not touch other slots — a surviving transport keeps running.
    @discardableResult
    func removeDriverSlot(forRawProductID rawPID: Int) -> (any TabletDevice)? {
        driverSlots.removeValue(forKey: rawPID)
    }

    /// Re-applies every persisted display-affecting setting directly to the
    /// current winning driver. `observeRingLED`'s Combine sinks only reach
    /// whatever `tabletDevice` resolves to *at the moment a setting changes*
    /// — a driver that just won its slot via transport promotion (its rival
    /// transport disconnected) or transport takeover (a higher-priority
    /// transport just connected) sat through all of those while losing, so
    /// it never received them. Call once, right after the winner changes.
    func resyncActiveDriverDisplayState() {
        guard let device = tabletDevice else { return }
        let activeSlotIndex = settings.touchRingActiveSlotIndex
        let displayBrightness = settings.displayBrightness
        let displayColorMode = settings.displayColorMode
        let customColorMode = isCustomColorMode
        let displayContrast = settings.displayContrast
        let displayGamma = settings.displayGamma
        let bezelColor = TabletSettings.bezelLEDColor(from: settings.bezelLEDColor)
        let quickKeysOrientation = settings.quickKeysOrientation
        let quickKeysSleepMinutes = settings.quickKeysSleepMinutes
        let quickKeysOledBrightness = settings.quickKeysOledBrightness
        // Every TabletDevice control-surface write is confined to HIDThread —
        // see the header comment on `onHIDThread`. Values are snapshotted
        // above on the main actor since `device` isn't Sendable.
        onHIDThread {
            device.setRingLED(index: activeSlotIndex)
            if displayBrightness >= 0 {
                device.setDisplayBrightness(displayBrightness)
            }
            if displayColorMode >= 0 {
                device.setColorMode(displayColorMode)
            }
            if customColorMode {
                if displayContrast >= 0 { device.setDisplayContrast(displayContrast) }
                if displayGamma >= 0 { device.setDisplayGamma(displayGamma) }
            }
            if let c = bezelColor {
                device.setBezelLEDColor(
                    r: UInt8(Int(c.r) * Int(c.a) / 255),
                    g: UInt8(Int(c.g) * Int(c.a) / 255),
                    b: UInt8(Int(c.b) * Int(c.a) / 255))
            }
            if quickKeysOrientation >= 0 {
                device.setQuickKeysOrientation(steps: quickKeysOrientation)
            }
            if quickKeysSleepMinutes >= 0 {
                device.setQuickKeysSleepMinutes(quickKeysSleepMinutes)
            }
            if quickKeysOledBrightness >= 0 {
                device.setQuickKeysOledBrightness(quickKeysOledBrightness)
            }
        }
        pushDeviceDisplayState()
    }

    /// The raw IOHIDDevice handle for this context's primary digitizer
    /// interface — weak because IOKit owns the lifetime.
    ///
    /// A multi-interface tablet (touch, pad/aux, LED-only siblings alongside
    /// the pen interface) enumerates one `IOHIDDevice` per interface, all
    /// mapped to this same context, but only one of them is the interface the
    /// driver actually reads pen reports from and passes to
    /// `CaptureEngine.recordRaw`. `TabletManager.deviceConnected` sets this
    /// only the first time a `.driver`-routed interface attaches for this raw
    /// product ID (see `firstDriverInterfaceClaimed`) — never overwritten by a
    /// sibling interface that attaches later. Before that guard existed, an
    /// `.intuosV1`-family device with `seizeUSB: false` (no defer/seize
    /// gating in `DeviceRouter.route`) would route *every* interface through
    /// `.driver` independently, and this property took whichever one attached
    /// last — order-dependent and silently wrong. Confirmed on a PTH-850: two
    /// discovery captures both came back scoped to its touch interface
    /// instead of the pen interface, because that was the one that happened
    /// to attach second. Only consumer today is `CaptureGuideView`, which
    /// hands this to `CaptureEngine.startDiscovery(device:)`; if it pointed
    /// at the wrong interface, that session would silently record zero events
    /// for the whole capture window (0 events despite reports flowing
    /// normally through the app) because `recordRaw`'s device never matches
    /// the registered accumulator's key.
    weak var hidDevice: IOHIDDevice?

    /// True once `hidDevice` has been claimed by a `.driver`-routed interface
    /// for the first time. Guards `hidDevice`'s assignment against later
    /// sibling interfaces of the same raw product ID — see that property's
    /// doc comment. Deliberately not derived from `hidDevice != nil`: that
    /// would let the property be reclaimed after the original interface
    /// disconnects and `hidDevice` goes nil, which is fine (a fresh claim on
    /// reconnect is correct), so this flag alone can't just mirror it either
    /// — it's reset in the same place `hidDevice` is cleared.
    var firstDriverInterfaceClaimed = false

    /// Every `.driver`-routed interface currently attached for this context,
    /// most recently attached last — not just the one `hidDevice` pins to.
    /// Exists so `CaptureGuideView` can offer a picker when a device (like
    /// PTH-850) exposes more than one capturable interface, instead of only
    /// ever being able to record whichever one `hidDevice` happened to claim.
    /// Weakly held via `CaptureInterfaceCandidate`, mirroring `hidDevice`,
    /// since IOKit owns the lifetime; pruned on disconnect in
    /// `TabletManager.deviceDisconnected`.
    ///
    /// `@Published`, unlike `hidDevice` — a second interface routinely
    /// attaches a moment after `CaptureGuideView` opens (its own capture
    /// session already under way against the first), and the picker that
    /// reads this needs SwiftUI to actually notice the update and redraw,
    /// not just have the right data sitting unseen in the context.
    @Published var captureInterfaces: [CaptureInterfaceCandidate] = []

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

    /// Last-seen pen/stylus point at tablet coordinates. Deliberately NOT
    /// @Published: TabletManager forwards every context.objectWillChange up
    /// to its own objectWillChange, which every SwiftUI view holding
    /// @ObservedObject tabletManager observes — including panes (e.g.
    /// ButtonMappingView) that never read livePoint at all. With this
    /// published, plain hovering (no button change) re-ran those views' full,
    /// expensive bodies at ~16 Hz for no reason, which is what caused the
    /// Buttons pane's 100% CPU/choppy-scroll behavior while a pen hovered.
    /// Consumers that need live position (InfoView, ScratchpadView's tilt
    /// disc) subscribe to `livePointPublisher` directly instead of relying
    /// on the general cascade.
    var livePoint: TabletPoint? = nil {
        didSet { livePointPublisher.send(livePoint) }
    }

    /// Fires on every `livePoint` write, independent of `objectWillChange` — see above.
    let livePointPublisher = PassthroughSubject<TabletPoint?, Never>()

    /// Live button state for the pen/stylus and device.
    @Published var liveButtons: LiveButtonState = .init()

    /// Subscriptions managed by this context (e.g., to TabletManager for change propagation).
    var cancellables: Set<AnyCancellable> = []

    /// Subscriptions for the input-injection snapshot pipeline. Cleared and rebuilt
    /// whenever `settings.activeTool` changes so the inner ToolSettings observer
    /// always tracks the live tool.
    private var snapshotCancellables: Set<AnyCancellable> = []
    private var activeToolObserver: AnyCancellable?

    /// True when the panel's color-space preset is Custom/User Mode — the
    /// only mode where contrast/gamma writes are valid on the hardware.
    private var isCustomColorMode: Bool {
        settings.displayColorMode == TabletSettings.displayColorModeCustomIndex
    }

    /// True once `observeRingLED`/`observeInjectionSnapshot` have been wired
    /// for this context. A second transport connecting (e.g. the Xencelabs
    /// dongle joining a context the wired puck already owns) installs into
    /// its own driver slot but must not re-subscribe — these sinks target
    /// whichever slot currently wins, so a second subscription would just
    /// fire every hardware write twice.
    var hasWiredDriverLifecycle = false

    /// Runs `body` on `HIDThread`, the sole thread `TabletDevice` control
    /// writes are confined to.
    ///
    /// `DeviceContext` is `@MainActor`, but every one of these settings sinks
    /// used to call straight into the driver from the main thread — at the
    /// same time `registerDevice()`/`flushPendingVendorWrites()` mutate the
    /// same unsynchronized "last-sent" cache vars from HIDThread on a
    /// reconnect/relink. A brightness-slider drag landing mid-relink was a
    /// live, reachable data race, not a theoretical one. Every write here and
    /// in `pushDeviceDisplayState`/`resyncActiveDriverDisplayState` now goes
    /// through this same hop, matching the existing `CFRunLoopPerformBlock`
    /// convention `observeInjectionSnapshot` already uses for the same reason.
    private func onHIDThread(_ body: @escaping () -> Void) {
        CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue, body)
        CFRunLoopWakeUp(HIDThread.shared.runLoop)
    }

    /// Subscribe to ring slot changes so the physical LED tracks the active mode.
    /// Call this once after `tabletDevice` is assigned.
    func observeRingLED() {
        settings.$touchRingActiveSlotIndex
            .sink { [weak self] index in
                guard let self, let device = self.tabletDevice else { return }
                self.onHIDThread { device.setRingLED(index: index) }
                self.pushDeviceDisplayState(activeSlotIndex: index)
            }
            .store(in: &cancellables)
        // Panel brightness (Xencelabs pen displays). Fires once on subscribe,
        // which replays the saved value to the hardware on (re)connect; -1
        // means the user has never touched the slider, so the panel keeps
        // its own stored value.
        settings.$displayBrightness
            .sink { [weak self] value in
                guard value >= 0, let self, let device = self.tabletDevice else { return }
                self.onHIDThread { device.setDisplayBrightness(value) }
            }
            .store(in: &cancellables)
        // Panel contrast and gamma ride the same 0xB5 control family and
        // replay-on-connect the same way; -1 means untouched, leave the panel's
        // own value alone. Named color presets (Adobe RGB, sRGB, etc.) own
        // their own contrast/gamma internally — the vendor driver only
        // exposes these controls in Custom/User Mode, and writing them under
        // a named preset visibly corrupts its color transform.
        settings.$displayContrast
            .sink { [weak self] value in
                guard value >= 0, let self, self.isCustomColorMode,
                    let device = self.tabletDevice
                else { return }
                self.onHIDThread { device.setDisplayContrast(value) }
            }
            .store(in: &cancellables)
        settings.$displayGamma
            .sink { [weak self] value in
                guard value >= 0, let self, self.isCustomColorMode,
                    let device = self.tabletDevice
                else { return }
                self.onHIDThread { device.setDisplayGamma(value) }
            }
            .store(in: &cancellables)
        // Bezel-button backlight LED (Xencelabs pen displays). Same wire
        // command as the Quick Keys dial LED; the stored alpha is the
        // brightness and gets premultiplied into the RGB here, matching how
        // the vendor stack scales it. Empty/unset leaves the panel's own
        // stored color alone.
        settings.$bezelLEDColor
            .sink { [weak self] value in
                guard let self, let device = self.tabletDevice,
                    let c = TabletSettings.bezelLEDColor(from: value)
                else { return }
                self.onHIDThread {
                    device.setBezelLEDColor(
                        r: UInt8(Int(c.r) * Int(c.a) / 255),
                        g: UInt8(Int(c.g) * Int(c.a) / 255),
                        b: UInt8(Int(c.b) * Int(c.a) / 255))
                }
            }
            .store(in: &cancellables)
        settings.$displayColorMode
            .sink { [weak self] value in
                guard let self, value >= 0, let device = self.tabletDevice else { return }
                // Entering Custom mode re-applies any contrast/gamma the user
                // already set, since presets don't accept those writes.
                let customMode = self.isCustomColorMode
                let contrast = self.settings.displayContrast
                let gamma = self.settings.displayGamma
                self.onHIDThread {
                    device.setColorMode(value)
                    guard customMode else { return }
                    if contrast >= 0 { device.setDisplayContrast(contrast) }
                    if gamma >= 0 { device.setDisplayGamma(gamma) }
                }
            }
            .store(in: &cancellables)
        // Quick Keys OLED orientation/brightness and sleep timer. Pre-wired
        // ahead of a UI control — -1 sentinel means untouched, so these never
        // fire in practice until a control writes something else.
        settings.$quickKeysOrientation
            .sink { [weak self] value in
                guard value >= 0, let self, let device = self.tabletDevice else { return }
                self.onHIDThread { device.setQuickKeysOrientation(steps: value) }
            }
            .store(in: &cancellables)
        settings.$quickKeysSleepMinutes
            .sink { [weak self] value in
                guard value >= 0, let self, let device = self.tabletDevice else { return }
                self.onHIDThread { device.setQuickKeysSleepMinutes(value) }
            }
            .store(in: &cancellables)
        settings.$quickKeysOledBrightness
            .sink { [weak self] value in
                guard value >= 0, let self, let device = self.tabletDevice else { return }
                self.onHIDThread { device.setQuickKeysOledBrightness(value) }
            }
            .store(in: &cancellables)
    }

    /// Push host-side display state (mode name, key labels) to devices with
    /// their own screen — currently the Xencelabs Quick Keys OLED. No-ops on
    /// everything else via the TabletDevice protocol defaults; the device
    /// layer dedupes, so redundant calls are cheap.
    func pushDeviceDisplayState(activeSlotIndex: Int? = nil) {
        guard let device = tabletDevice else { return }
        let index = activeSlotIndex ?? settings.touchRingActiveSlotIndex
        let ringModeLabel = settings.touchRingSlots.indices.contains(index)
            ? settings.touchRingSlots[index].label : nil
        // Brightness (the panel's opacity) is premultiplied into the RGB
        // here — the dial LED has no brightness register, the vendor stack
        // scales the color bytes the same way.
        let ringColors = settings.touchRingSlots.map { slot in
            slot.ledColor.map { c in
                (r: UInt8(Int(c.r) * Int(c.a) / 255),
                 g: UInt8(Int(c.g) * Int(c.a) / 255),
                 b: UInt8(Int(c.b) * Int(c.a) / 255))
            }
        }
        let keyLabels = settings.expressKeyBindings.map { $0.displayLabel }
        // See `onHIDThread`'s header comment: every TabletDevice write is
        // confined to HIDThread, so this hops rather than calling inline.
        onHIDThread {
            if let ringModeLabel { device.setRingModeLabel(ringModeLabel) }
            device.setRingLEDColors(ringColors)
            device.setAuxKeyLabels(keyLabels)
        }
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
    ///
    /// Each install also drops the display mapper's cached calibration entry, so
    /// every path that edits calibration — calibrate, clear, undo/redo, preset
    /// switch, import, reset — picks up the change without its own invalidate call.
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
            injectorRef.displayMapper.invalidateCalibrationCache()
        }
        CFRunLoopWakeUp(HIDThread.shared.runLoop)

        let rebuild: () -> Void = { [weak self] in
            guard let self else { return }
            let snap = self.settings.makeInjectionSnapshot()
            let injectorRef = self.injector
            CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) {
                injectorRef.injectionSnapshot = snap
                // Drop the mapper's cached calibration in the same block that
                // installs the snapshot it was read from. Invalidating from the
                // settings-edit site instead would land *before* the new snapshot
                // arrives, letting an inject() in the gap re-cache the old entry.
                injectorRef.displayMapper.invalidateCalibrationCache()
            }
            CFRunLoopWakeUp(HIDThread.shared.runLoop)
            // Binding/slot renames should reach devices with their own display
            // (Quick Keys OLED); deduped downstream, cheap when nothing changed.
            self.pushDeviceDisplayState()
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

    init(
        instanceKey: DeviceInstanceKey, rawProductID: Int? = nil,
        vendorID: Int = 0x056A, usbSerial: String? = nil, locationID: Int = 0
    ) {
        self.instanceKey = instanceKey
        self.id = instanceKey.stringValue
        self.usbSerial = usbSerial
        self.locationID = locationID
        self.productID = instanceKey.productID
        self.rawProductID = rawProductID ?? instanceKey.productID
        self.vendorID = vendorID
        let s = TabletSettings(instanceKey: instanceKey)
        self.settings = s
        self.injector = InputInjector(vendorID: vendorID, productID: instanceKey.productID)
        self.activeTool = s.activeTool
    }

    /// Model-only construction: window-restore stubs and callers that predate
    /// instance identity. The empty instance token resolves to the model's
    /// legacy settings namespace, matching pre-instance behavior.
    convenience init(productID: Int, rawProductID: Int? = nil, vendorID: Int = 0x056A) {
        self.init(
            instanceKey: DeviceInstanceKey(productID: productID, instance: ""),
            rawProductID: rawProductID, vendorID: vendorID)
    }

    /// Fills in the physical identity on a context created before the device
    /// connected (window-restore stub). No-op once an instance is known.
    /// The caller re-keys its dictionary and reconciles the settings prefix.
    func adoptInstance(_ key: DeviceInstanceKey, usbSerial: String?, locationID: Int) {
        guard instanceKey.instance.isEmpty, key.productID == productID else { return }
        instanceKey = key
        self.usbSerial = usbSerial
        self.locationID = locationID
    }
}
