// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import IOKit.hid
import OSLog
import TabletKit

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "manager")

/// Standalone publisher for live touch contacts.  Kept off `TabletManager`
/// so the ~30 Hz touch stream invalidates only views that explicitly observe
/// this object, not every view that observes `TabletManager`.
///
/// `isPublishingEnabled` lets the sole consumer (ScratchpadView) gate updates
/// on its own visibility — when the scratchpad tab is hidden or the app
/// resigns active, the HID-thread closure skips both the throttle bookkeeping
/// and the main-thread dispatch entirely.
final class LiveTouchPublisher: ObservableObject {
    @MainActor @Published var contacts: [TouchContact] = []

    /// HID-thread reads, main-thread writes.  Bool reads/writes are atomic on
    /// aarch64; a brief disagreement during a state transition just costs one
    /// or two redundant frames, which is harmless.
    nonisolated(unsafe) var isPublishingEnabled: Bool = false

    /// HID-thread-only.  Last time the throttle let a publish through.
    /// Lives here (rather than on `TabletManager`, which is `@MainActor`)
    /// so the cross-thread read/write is no longer a concurrency violation.
    /// 8-byte loads/stores are atomic on aarch64; a torn read is impossible.
    nonisolated(unsafe) var lastPublishTime: CFAbsoluteTime = 0

    /// Throttle target: ~30 Hz.  HID delivers touch at ~100 Hz under load,
    /// and even after `isPublishingEnabled` gates inactive consumers, the
    /// active scratchpad doesn't benefit from canvas redraws faster than this.
    static let publishInterval: CFAbsoluteTime = 1.0 / 30.0
}

/// Manages IOHIDManager lifecycle, per-device contexts, and proximity-based
/// activation for multi-tablet support.
///
/// Each connected tablet gets its own `DeviceContext` (settings, injector,
/// driver).  Only the *active* context posts CGEvents — activation happens
/// automatically when a pen enters proximity on a given tablet.
///
/// @MainActor because all mutable state and CGEvent posts require the main thread.
/// IOHIDManager is scheduled on HIDThread (a dedicated background run loop) so
/// HID report callbacks arrive immediately regardless of SwiftUI frame work on main.
/// Device-lifecycle and inject() calls hop back to @MainActor via Task.
@MainActor
final class TabletManager: ObservableObject {

    static let shared = TabletManager()

    private let manager: IOHIDManager

    // MARK: - Per-device state

    /// The real context store, keyed by physical instance so two identical
    /// devices (same PID) each get their own settings, injector, and state.
    @Published var deviceContexts: [DeviceInstanceKey: DeviceContext] = [:]

    /// PID-keyed compatibility view for callers that predate instance
    /// identity (all the settings panes). When a model has several connected
    /// instances, the one holding the legacy settings namespace wins —
    /// deterministic, and identical to the old collapse behavior.
    var contexts: [Int: DeviceContext] {
        Dictionary(
            deviceContexts.values.map { ($0.productID, $0) },
            uniquingKeysWith: { a, b in
                a.settings.devicePrefix.contains("#") ? b : a
            })
    }
    /// Inserts a window-restore stub context created before the device has
    /// connected this session. Keyed under its empty-instance key; the first
    /// real connect of that model adopts and re-keys it.
    func registerRestoredContext(_ context: DeviceContext) {
        deviceContexts[context.instanceKey] = context
    }

    /// Context for a registry row. A row with an instance token matches the
    /// exact instance; the legacy row (nil/empty token) matches the unit
    /// holding the model's claimed namespace, via the compatibility view.
    func context(for tablet: DeviceRegistry.KnownTablet) -> DeviceContext? {
        if let inst = tablet.instance, !inst.isEmpty {
            return deviceContexts[tablet.instanceKey]
        }
        return contexts[tablet.productID]
    }

    /// The device whose injector is currently posting CGEvents.
    /// `didSet` keeps `injector.isActive` in lockstep so the HIDThread fast path in
    /// `onTablet` is gated by a flag that exactly mirrors `activeContext`. Without
    /// this, `injector.isActive` would only flip on a context *change*; the very
    /// first device (where `deviceConnected` does `if activeContext == nil` …)
    /// would have its activation skipped and the cursor would never move.
    @Published var activeContext: DeviceContext? = nil {
        didSet {
            if oldValue !== activeContext { oldValue?.injector.isActive = false }
            activeContext?.injector.isActive = true
        }
    }
    /// Most-recent touch contacts from the active device's touch surface.
    /// Empty when no contacts are active or the device has no finger touch.
    ///
    /// Lives on its own `ObservableObject` so the ~30 Hz touch-frame stream
    /// invalidates only the one view that consumes it (ScratchpadView) and
    /// not every settings pane that observes `TabletManager`.  Broadcasting
    /// touch updates through `TabletManager` collapsed every pane's body
    /// at touch-frame rate, which was the dominant CPU cost under a palm.
    let liveTouch = LiveTouchPublisher()

    private var hidDeviceMap: [IOHIDDevice: DeviceContext] = [:]
    private var shimObservers: [NSObjectProtocol] = []
    /// Interfaces deferred because they arrived before the control interface (0xFF00) for their PID.
    /// Drained into registerDevice() once a WacomKnownDevice is created for that PID.
    private var pendingInterfaces: [Int: [IOHIDDevice]] = [:]

    // MARK: - Manager-level published state
    //
    // Per-device state (connection, transport, battery, live pen state) lives on
    // `DeviceContext` only — views read it through `contexts` / `activeContext`.
    // The manager publishes just the aggregate list and its own health.

    /// Product ID of the most recently connected device (0 when none).
    @Published var connectedProductID: Int = 0
    @Published var connectedProductIDs: [Int] = []
    @Published var hidManagerOpen: Bool = false

    var isConnected: Bool { !connectedProductIDs.isEmpty }

    // MARK: - UI throttle
    //
    // @Published mutations fire objectWillChange.send() on every write, which
    // triggers SwiftUI diffing on the main thread.  At 133 Hz that's hundreds
    // of invalidations per second even when no values changed.
    //
    // Two-level gate:
    //   1. infoViewVisible — set by SettingsWindowController when the Info tab
    //      is frontmost.  When false, livePoint / liveButtons are never written
    //      at all, so @Published fires zero times during normal use.
    //   2. uiUpdateCounter — when the Info tab IS visible, further throttle to
    //      ~16 Hz so SwiftUI layout work stays negligible.

    /// True when MockTab is the frontmost application. Set by AppDelegate on
    /// didBecomeActive/willResignActive. Combined with infoViewVisible to gate updates.
    ///
    /// Plain `Bool`, not `@Published`: this is read on the HID thread at ~200 Hz
    /// inside the `onTablet` gate. `@Published`'s Combine-wrapped getter showed up
    /// as ~13% of HID-thread time when this was published. No SwiftUI view binds
    /// to this directly — only same-thread gate code and main-thread setters touch it.
    var appIsFrontmost: Bool = false

    /// Set true by SettingsWindowController when the Info or Buttons tab is frontmost
    /// in the active window. Combined with appIsFrontmost: both must be true to update
    /// livePoint/liveButtons, eliminating all SwiftUI overhead when MockTab is in the
    /// background or a different tab is active.
    var infoViewVisible: Bool = false

    /// Optional raw-data callback for calibration. When set, every active-context
    /// TabletPoint is forwarded here *in addition to* the normal injection path.
    /// Always assign through `setCalibrationPointHandler(_:)` so the HID-thread
    /// gate `calibrationActive` stays in sync.
    private(set) var calibrationPointHandler: ((TabletPoint) -> Void)?

    /// Single-word mirror of `calibrationPointHandler != nil`, safe to read from
    /// HID thread. Reading the optional closure itself across threads is unsafe
    /// (two-word load can tear); this Bool is the cheap gate used in `onTablet`.
    private(set) var calibrationActive: Bool = false

    func setCalibrationPointHandler(_ handler: ((TabletPoint) -> Void)?) {
        calibrationPointHandler = handler
        calibrationActive = handler != nil
    }

    private var uiUpdateCounter = 0
    private static let uiUpdateInterval = 8  // every 8th report ≈ 16 Hz at 133 Hz

    // MARK: - Device name helpers

    /// Vendor ID last seen for a given product ID, recorded as devices connect.
    /// Lets `deviceName` resolve the right vendor for the many UI callers that
    /// only have a product ID on hand, instead of silently assuming Wacom.
    @MainActor private static var lastSeenVendorID: [Int: Int] = [:]

    /// Resolve a human-readable model name. `vendorID` defaults to whatever
    /// vendor was last seen connected under `pid` (falling back to Wacom if
    /// none), so PID-only UI callers still show the right name for non-Wacom
    /// hardware. Pass the real vendor (and the device's IOKit product string)
    /// explicitly when calling from a context that already has them.
    static func deviceName(
        forProductID pid: Int, vendorID: Int? = nil, productString: String? = nil
    ) -> String {
        let vendorID = vendorID ?? lastSeenVendorID[pid] ?? 0x056A
        if vendorID == 0x056A {
            if let spec = WacomDeviceRegistry.spec(for: pid) { return spec.name }
            return WacomDeviceRegistry.deviceName(forProductID: pid)
        }
        // Non-Wacom naming, accuracy first. Many vendors (Huion especially)
        // share one PID across a dozen models, so a curated profile name is only
        // trustworthy when the PID maps to exactly one product. Otherwise the
        // device's own product string is the honest source — better to show
        // "HUION Tablet" than to assert the wrong model.
        let profiles = VendorDeviceRegistry.profiles(forVendorID: vendorID, productID: pid)
        if profiles.count == 1, let name = profiles.first?.productName { return name }
        if let ps = productString, !ps.isEmpty { return ps }
        if let name = profiles.first?.productName { return name }  // ambiguous, but better than a PID
        return WacomDeviceRegistry.deviceName(forProductID: pid)
    }

    var connectedDeviceName: String {
        switch connectedProductIDs.count {
        case 0: return "No tablet"
        case 1: return Self.deviceName(forProductID: connectedProductIDs[0])
        default:
            let first = Self.deviceName(forProductID: connectedProductIDs[0])
            return "\(first) + \(connectedProductIDs.count - 1) more"
        }
    }

    // MARK: - Legacy single-device accessors

    var settings: TabletSettings? {
        get { activeContext?.settings }
        set { /* no-op: settings are now per-context */  }
    }

    var injector: InputInjector? {
        activeContext?.injector
    }

    // MARK: - Init

    private init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func start() {
        if #available(macOS 10.15, *) {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        // Primary match: Wacom (VID 0x056A) — the only vendor we actually decode.
        //
        // Secondary matches: Huion, Xencelabs/XP-Pen, UC-Logic — vendors covered
        // by VendorDeviceRegistry.  These devices are *not* decoded; deviceConnected
        // logs them by name and returns immediately, so the user can see in
        // `log show --predicate 'subsystem == "com.cyzor.mocktab"'` that the device
        // was recognised even though MockTab can't drive it yet.  This keeps the
        // unknown-device discovery flow honest: "your tablet is a Huion H1060P,
        // and we don't support it" beats "your tablet is invisible to us."
        let matching: [[String: Any]] = [
            [kIOHIDVendorIDKey: 0x056A as NSNumber],  // Wacom
            [kIOHIDVendorIDKey: 0x256C as NSNumber],  // Huion (recognition only)
            [kIOHIDVendorIDKey: 0x28BD as NSNumber],  // Xencelabs / XP-Pen (recognition only)
            [kIOHIDVendorIDKey: 0x5543 as NSNumber],  // UC-Logic OEMs (recognition only)
            // Universal floor: any vendor's standards-compliant pen digitizer
            // (top-level usage Digitizer/Pen). Matching on the Pen usage — not
            // just the page — excludes trackpads (0x05) and touch screens (0x04),
            // so we never claim the built-in trackpad.
            [kIOHIDDeviceUsagePageKey: 0x0D as NSNumber,
             kIOHIDDeviceUsageKey: 0x02 as NSNumber],  // any-vendor pen digitizer
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let ctx = Unmanaged.passRetained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            { ctx, _, _, device in
                guard let ctx else { return }
                let mgr = Unmanaged<TabletManager>.fromOpaque(ctx).takeUnretainedValue()
                // Hop to main — TabletManager is @MainActor; HIDThread fires this callback.
                Task { @MainActor in mgr.deviceConnected(device) }
            }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            { ctx, _, _, device in
                guard let ctx else { return }
                let mgr = Unmanaged<TabletManager>.fromOpaque(ctx).takeUnretainedValue()
                Task { @MainActor in mgr.deviceDisconnected(device) }
            }, ctx)

        setupShimBridge()
        // Schedule on the dedicated HID thread so report delivery is not gated
        // on main-thread availability (e.g. during SwiftUI rendering passes).
        IOHIDManagerScheduleWithRunLoop(
            manager, HIDThread.shared.runLoop, RunLoop.Mode.common.rawValue as CFString)
        let ret = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManagerOpen = (ret == kIOReturnSuccess)
        if !hidManagerOpen {
            logger.error("TabletManager: failed to open HID manager (\(ret, privacy: .public)). Check Input Monitoring permission or uninstall any existing tablet driver.")
        }
    }

    // MARK: - Adobe shim bridge

    /// Subscribe to distributed notifications posted by WacomShim when Adobe apps
    /// send eSendTabletEvent Apple Events requesting a replay of the last tablet event.
    private func setupShimBridge() {
        let dn = DistributedNotificationCenter.default()
        let pointer = dn.addObserver(
            forName: NSNotification.Name("com.cyzor.mocktab.shim.replayPointer"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeContext?.injector.replayPointerEvent() }
        }
        let proximity = dn.addObserver(
            forName: NSNotification.Name("com.cyzor.mocktab.shim.replayProximity"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeContext?.injector.replayProximityEvent() }
        }
        shimObservers = [pointer, proximity]
    }

    func stop() {
        let dn = DistributedNotificationCenter.default()
        for obs in shimObservers { dn.removeObserver(obs) }
        shimObservers.removeAll()
        IOHIDManagerUnscheduleFromRunLoop(
            manager, HIDThread.shared.runLoop, RunLoop.Mode.common.rawValue as CFString)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        for (_, ctx) in hidDeviceMap { ctx.tabletDevice?.close() }
        hidDeviceMap.removeAll()
        deviceContexts.removeAll()
        activeContext = nil
        connectedProductIDs = []
        connectedProductID = 0
        updateActivityAssertion()
    }

    // MARK: - Device lifecycle

    /// Best-available spec for a product ID with no live connection required:
    /// the Wacom registry row if one exists, otherwise a spec synthesized from
    /// the device's vendor profile. Lets UI decide capability-based layout
    /// (tab set, pane sections) for recognized-but-unplugged devices of any
    /// vendor — `WacomDeviceRegistry.spec(for:)` alone returns nil for
    /// non-Wacom hardware.
    @MainActor
    static func staticSpec(forProductID productID: Int) -> WacomDeviceSpec? {
        if let spec = WacomDeviceRegistry.spec(for: productID) { return spec }
        let vendorID = DeviceRegistry.shared.vendorID(forProductID: productID)
            ?? lastSeenVendorID[productID]
            ?? 0x056A
        return vendorDeviceSpec(forVendorID: vendorID, productID: productID)
    }

    /// Synthesizes the `WacomDeviceSpec` for a drivable non-Wacom device from
    /// its `VendorDeviceRegistry` profile. Shared by `deviceConnected` (which
    /// needs it live, to attach a driver) and UI callers like
    /// `ButtonMappingView` (which need the same shape — `hasTouchRing`,
    /// `buttonCount`, etc. — even when no live `DeviceContext` spec is
    /// reachable, since these devices aren't in the Wacom-only
    /// `WacomDeviceRegistry` the UI otherwise consults).
    static func vendorDeviceSpec(forVendorID vendorID: Int, productID: Int) -> WacomDeviceSpec? {
        guard vendorID != 0x056A,
            let profile = VendorDeviceRegistry.drivableProfile(
                forVendorID: vendorID, productID: productID)
        else { return nil }
        // Profiles without coordinate maxima are aux-only devices
        // (Quick Keys: express keys + dial, no pen digitizer).
        let isAuxOnly = profile.maxX == nil
        return WacomDeviceSpec(
            productID: productID,
            name: profile.productName,
            parser: .xencelabs,
            maxX: profile.maxX ?? 0,
            maxY: profile.maxY ?? 0,
            maxPressure: profile.maxPressure ?? 8191,
            buttonCount: profile.auxButtonCount ?? 0,
            bezelButtonCount: profile.bezelButtonCount ?? 0,
            // Tilt confirmed live in report 2 (signed bytes at
            // offsets 8–9); degree scale still unverified.
            // hasTouchRing reuses the entire Wacom touch-ring UI/LED
            // architecture for the Quick Keys dial (4 modes on both,
            // ringSlotCount defaults to 4) — see XencelabsDecoder's
            // touchRingButtonDown/buttons[8] mapping. Only the aux-only
            // puck/dongle has a dial; the pen tablets/display themselves
            // have neither express keys nor a ring of their own (those are
            // the companion's, folded into the tablet's Buttons pane
            // instead — see ButtonMappingView's Quick Keys section), so
            // this must not be forced on for every Xencelabs PID.
            hasTouchRing: isAuxOnly, hasEraser: !isAuxOnly, hasTilt: !isAuxOnly,
            isPenDisplay: profile.isPenDisplay,
            seizeUSB: false,
            // Tablet-mode handshake; without it the device stays in
            // mouse emulation (see Xencelabs-G1D-Feasibility note).
            initSteps: [.outputReport([0x02, 0xB0, 0x04])],
            confidence: .experimental,
            activeWidthMM: profile.activeWidthMM,
            activeHeightMM: profile.activeHeightMM)
    }

    private func deviceConnected(_ device: IOHIDDevice) {
        // Connect-phase work (handshakes, paced writes) stalls report
        // delivery; keep those episodes out of the steady-state latency stats.
        LatencyProbe.shared.noteDeviceConnected()
        let vendorID = hidIntProperty(device, kIOHIDVendorIDKey)
        let rawProductID = hidIntProperty(device, kIOHIDProductIDKey)
        Self.lastSeenVendorID[rawProductID] = vendorID

        // Non-Wacom path. Devices on the drivable allowlist (currently the two
        // Xencelabs Pen Tablets) get a spec synthesized from their vendor
        // profile and continue through the normal routing below; everything
        // else is recognition-only — name it, log it, and bail out before any
        // Wacom-specific state touches it.
        let vendorSpec = Self.vendorDeviceSpec(forVendorID: vendorID, productID: rawProductID)
        if vendorID != 0x056A {
            if let profile = VendorDeviceRegistry.drivableProfile(
                forVendorID: vendorID, productID: rawProductID)
            {
                logger.info("TabletManager: drivable \(profile.vendor, privacy: .public) device — \(profile.productName, privacy: .public) (PID=0x\(String(rawProductID, radix: 16), privacy: .public)) — attaching experimental decoder")
            } else {
                // Not on the drivable allowlist. If this interface is a
                // standards-compliant pen digitizer (top-level usage Pen), let it
                // fall through to normal routing with no spec — DeviceRouter
                // attaches the vendor-agnostic GenericHIDDigitizer (universal
                // floor: pen motion + tap + absolute). Otherwise it's a non-pen
                // interface or a vendor we only recognise: name it and bail.
                let primaryUsagePage = hidIntProperty(device, kIOHIDPrimaryUsagePageKey)
                let primaryUsage = hidIntProperty(device, kIOHIDPrimaryUsageKey)
                // Xencelabs' whole family declares a standards-compliant
                // report-7 digitizer collection on every interface (dongle,
                // puck) but never actually sends data on it — confirmed live,
                // see XencelabsDecoder's header comment. Attaching the generic
                // floor there produces a phantom tablet-area window sized off
                // that decorative descriptor (which mirrors the real display's
                // logical bounds, hence looking plausible) for hardware that
                // isn't a digitizer at all.
                //
                // 0xFEED/0xBEEF is Karabiner-Elements' VirtualHIDDevice (its
                // well-known synthetic keyboard/pointer identity) — not real
                // drawing hardware. It also exposes a digitizer usage page,
                // and it's not just cosmetic here: attaching the generic
                // floor to it lets its synthetic events assert proximity,
                // which steals `activeContext` (and with it CGEvent posting)
                // away from a real connected tablet whenever Karabiner is
                // running, so real pen motion silently stops reaching the
                // screen.
                let isPenDigitizer =
                    primaryUsagePage == 0x0D && primaryUsage == 0x02
                    && vendorID != 0x28BD && vendorID != 0xFEED
                let profiles = VendorDeviceRegistry.profiles(
                    forVendorID: vendorID, productID: rawProductID)
                let name = profiles.first?.productName ?? "(unknown product)"
                let vendorName = profiles.first?.vendor
                    ?? "non-Wacom vendor 0x\(String(vendorID, radix: 16))"
                if isPenDigitizer {
                    logger.info("TabletManager: \(vendorName, privacy: .public) \(name, privacy: .public) (PID=0x\(String(rawProductID, radix: 16), privacy: .public)) — generic pen digitizer, attaching universal floor")
                    // vendorSpec stays nil; fall through to routing below.
                } else {
                    let candidateCount = profiles.count
                    logger.info("TabletManager: recognised \(vendorName, privacy: .public) device — \(name, privacy: .public) (VID=0x\(String(vendorID, radix: 16), privacy: .public) PID=0x\(String(rawProductID, radix: 16), privacy: .public), \(candidateCount, privacy: .public) profile candidates) — no decoder support yet")
                    return
                }
            }
        }

        // Fold transport variants into one device identity — the context,
        // settings namespace, and window all key off the canonical PID.
        // Wacom BT/dongle PIDs map to the USB PID; the Xencelabs Quick Keys
        // dongle maps to the wired puck. The driver layer keeps the raw PID
        // (via `vendorSpec` above) because relay handling is
        // transport-specific.
        let productID = vendorID == 0x056A
            ? WacomDeviceRegistry.canonicalProductID(for: rawProductID)
            : VendorDeviceRegistry.canonicalProductID(for: rawProductID)
        Self.lastSeenVendorID[productID] = vendorID
        let usagePage = hidIntProperty(device, kIOHIDPrimaryUsagePageKey)
        let usage = hidIntProperty(device, kIOHIDPrimaryUsageKey)
        let maxRptSize = hidIntProperty(device, kIOHIDMaxInputReportSizeKey)
        let transport =
            IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        let productString =
            IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
        let isBLE = transport.lowercased().contains("bluetooth")
        // Instance-identity probe: serial and locationID are logged per
        // interface to establish, on real hardware, whether the interfaces of
        // one USB device share a locationID (serial is uniform; locationID is
        // unverified) before DeviceInstanceKey's fallback relies on it.
        let usbSerial =
            IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        let locationID = hidIntProperty(device, kIOHIDLocationIDKey)
        let pidStr =
            rawProductID == productID
            ? "0x\(String(productID, radix:16))"
            : "0x\(String(rawProductID, radix:16)) → 0x\(String(productID, radix:16))"
        logger.info("TabletManager: device pid=\(pidStr, privacy: .public) usagePage=0x\(String(usagePage, radix:16), privacy: .public) usage=0x\(String(usage, radix:16), privacy: .public) maxRptSize=\(maxRptSize, privacy: .public) transport=\(transport, privacy: .public) product=\"\(productString, privacy: .public)\" serial=\(usbSerial ?? "—", privacy: .public) locationID=0x\(String(locationID, radix:16), privacy: .public)")

        // BLE tablets expose multiple interfaces. Log all of them; skip ghost mouse only.
        if isBLE && usagePage == 0x01 {
            logger.debug("TabletManager: BLE usagePage=0x01 interface — maxRptSize=\(maxRptSize, privacy: .public) usage=0x\(String(usage, radix:16), privacy: .public) — skipping ghost mouse")
            return
        }

        // Instance identity: token is serial-only for now — the locationID
        // fallback stays off until the probe log above confirms whether the
        // interfaces of one USB device share a locationID. An empty token
        // degrades to PID-only identity, exactly the old behavior.
        let instanceKey = DeviceInstanceKey(
            productID: productID, usbSerial: usbSerial, locationID: 0)
        let context: DeviceContext
        if let existing = deviceContexts[instanceKey] {
            context = existing
        } else if instanceKey.instance.isEmpty {
            // No serial on this interface: fall back to the model's existing
            // context (claimed-namespace instance first), as PID keying did.
            context = contexts[productID]
                ?? DeviceContext(
                    instanceKey: instanceKey, rawProductID: rawProductID, vendorID: vendorID)
        } else if let stub = deviceContexts.first(where: {
            $0.key.productID == productID && $0.key.instance.isEmpty
        })?.value {
            // A window-restore stub (created before connect, no instance
            // token) exists for this model — adopt it so the open window and
            // the driver keep sharing one settings object, then re-key it.
            deviceContexts.removeValue(forKey: stub.instanceKey)
            stub.adoptInstance(instanceKey, usbSerial: usbSerial, locationID: locationID)
            // Register the claim for this instance; if another unit already
            // owns the legacy namespace, move the stub's settings off it.
            let prefix = DeviceRegistry.shared.settingsPrefix(for: instanceKey)
            if prefix != stub.settings.devicePrefix {
                stub.settings.loadForDevice(instanceKey)
            }
            context = stub
        } else {
            context = DeviceContext(
                instanceKey: instanceKey, rawProductID: rawProductID,
                vendorID: vendorID, usbSerial: usbSerial, locationID: locationID)
        }
        deviceContexts[context.instanceKey] = context
        context.hidDevice = device

        // Seed the per-app override for whatever app is currently frontmost.
        // AppWatcher seeds existing contexts at start(), but a device may connect
        // after launch (or in dockless mode where no app switch occurred yet).
        if let app = NSWorkspace.shared.frontmostApplication,
            let bundleID = app.bundleIdentifier
        {
            let name = app.localizedName ?? bundleID
            context.settings.handleAppOverrideActivation(bundleID: bundleID, appName: name)
            context.injector.activeAppNeedsTabletPointerEvents =
                AppWatcher.qtGtkBundleIDs.contains(bundleID)
            context.injector.activeAppProfile = AppWatcher.inputProfile(for: bundleID)
        }

        // Propagate context.objectWillChange to TabletManager so SwiftUI observers
        // get updates when per-device state changes (transport, battery, livePoint, etc).
        if context.cancellables.isEmpty {
            context.objectWillChange
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &context.cancellables)
        }

        // Set initial connection state for this device.
        context.isConnected = true
        context.transport = transport
        context.usbSpeed = Self.connectionInfo(for: device).speed

        // First tablet is the moment injection becomes possible — prompt for
        // Accessibility here rather than at launch so the request has context.
        promptForAccessibilityIfNeeded()

        // ── Tool-enter closure (IntuosV2 only) ──────────────────────────────
        // Called on HIDThread — hop to main before touching @Published properties.
        let onToolEnter: (ToolIdentity) -> Void = { [weak self, weak context] identity in
            Task { @MainActor [weak self, weak context] in
            guard self != nil, let context else { return }
            context.activeToolSerial = identity.serial
            context.activeToolIsMouse = identity.isMouse
            context.activeToolCode = identity.toolCode
            // Propagate tool code to calibration session so tool changes are tracked.
            CaptureEngine.shared.updateToolCode(identity.toolCode)
            let toolID = DeviceRegistry.shared.recordTool(
                identity: identity, forDevice: context.instanceKey)
            let toolSets = context.settings.toolSettings(forID: toolID, isMouse: identity.isMouse)
            context.activeTool = toolSets
            context.settings.activeTool = toolSets
            context.injector.activeToolSettings = toolSets
            context.injector.activeToolIsMouse = identity.isMouse
            context.injector.activeToolIsEraser = identity.isEraser
            context.injector.activeToolSerial = identity.serial
            context.injector.activeToolCode = identity.toolCode
            context.activeToolID = toolID
            } // end Task @MainActor
        }

        // ── Tablet point closure ─────────────────────────────────────────────
        // Called on HIDThread (the dedicated CFRunLoop thread that drives IOHIDManager).
        //
        // Fast path: when this device's injector is the active one, inject() runs
        // inline on HIDThread — no Task @MainActor hop, no scheduler wait. Inject
        // reads everything it needs from `injectionSnapshot`, which the main side
        // pushes via CFRunLoopPerformBlock whenever settings change.
        //
        // Slow path: active-context switching (proximity-enter from a non-active
        // device) and per-report UI updates still hop to main. Throughput-critical
        // CGEvent posting never waits on either.
        let onTablet: (TabletPoint) -> Void = { [weak self, weak context] point in
            guard let context else { return }
            let injector = context.injector

            // ── Fast path: inject inline on HIDThread ─────────────────────────
            let isActive = injector.isActive
            // Snapshot before inject() — inject() sets lastProximity = point.inProximity
            // at its tail, so reading after would always equal point.inProximity.
            let wasInProximity = injector.lastProximity
            if isActive {
                injector.inject(point: point, settings: context.settings)
            }

            // ── HID-thread gate: skip the Task hop when nothing needs to run.
            // At 200 Hz USB report rate the active-pen-backgrounded case used to
            // spawn a Task per report whose body did nothing; this short-circuit
            // collapses that to zero allocations on the dominant idle path.
            let needsHop: Bool
            if isActive {
                needsHop = !point.inProximity  // proximity-exit cleanup
                    || (point.inProximity && !wasInProximity)  // proximity-enter: re-arm assertion
                    || self?.appIsFrontmost == true && self?.infoViewVisible == true  // UI update
                    || self?.calibrationActive == true  // calibration sample
            } else {
                needsHop = point.inProximity  // proximity-enter → context switch
                    || injector.lastProximity  // dangling-proximity cleanup
            }
            guard needsHop else { return }

            // ── UI / context-switch path: throttled hop to main ───────────────
            Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            let injector = context.injector

            // Proximity-enter activates this device's context.
            // Note: `activeContext`'s `didSet` flips `injector.isActive` for both
            // the outgoing and incoming contexts, so we don't touch it here.
            if point.inProximity && self.activeContext !== context {
                if let old = self.activeContext, old.injector.lastProximity {
                    let exitPoint = TabletPoint(
                        x: 0, y: 0, maxX: 1, maxY: 1,
                        pressure: 0, maxPressure: 1,
                        tiltX: 0, tiltY: 0,
                        penButton1: false, penButton2: false,
                        eraser: false, inProximity: false, hoverDistance: 0)
                    // The outgoing exit must be injected *before* the active-context
                    // change flips `old.injector.isActive` off (didSet hasn't fired yet
                    // because we're still on the prior assignment). Inject still works
                    // because it doesn't gate on isActive — only the HIDThread fast
                    // path does.
                    old.injector.inject(point: exitPoint, settings: old.settings)
                }
                self.activeContext = context
                self.penEnteredProximity()
                // Inject this report from main (slow, one-time per switch). Cheap.
                injector.inject(point: point, settings: context.settings)
            }
            // Proximity-exit from a non-active device: still post so apps
            // don't get stuck with a dangling proximity state.
            else if !point.inProximity && injector.lastProximity && self.activeContext !== context {
                injector.inject(point: point, settings: context.settings)
                return
            }

            // Only the active context updates UI.
            guard self.activeContext === context else { return }

            // Forward raw data to calibration session if active.
            self.calibrationPointHandler?(point)

            // ── UI state — gated + throttled ─────────────────────────────────
            // Proximity exit always clears state immediately, regardless of app foreground/tab visibility.
            if !point.inProximity {
                self.uiUpdateCounter = 0
                context.activeToolID = nil
                context.activeToolCode = 0
                context.liveButtons = LiveButtonState()
                context.livePoint = nil
                self.penExitedProximity()
                return
            }

            // Pen is in proximity. Re-arm the latency assertion if it was dropped during
            // an idle period (covers the same-context re-entry path not caught by the
            // context-switch block above).
            self.penEnteredProximity()

            // Skip UI updates when MockTab is in the background OR the Info/Buttons
            // tab isn't visible. This eliminates every @Published write during
            // normal drawing use, including when MockTab is backgrounded.
            guard appIsFrontmost && infoViewVisible else { return }

            // Throttle continuous updates to ~16 Hz.
            self.uiUpdateCounter += 1
            guard self.uiUpdateCounter >= Self.uiUpdateInterval else { return }
            self.uiUpdateCounter = 0

            let toolIsMouse = context.activeToolIsMouse
            let tipDown = toolIsMouse ? point.penButton1 : point.normalizedPressure > 0.004
            let newButtons = LiveButtonState(
                tipDown: tipDown && !point.eraser,
                eraserDown: tipDown && point.eraser,
                button1Down: point.penButton1,
                button2Down: point.penButton2,
                button3Down: point.penButton3,
                button4Down: point.penButton4,
                button5Down: point.penButton5,
                expressKeys: context.liveButtons.expressKeys,
                bezelButtons: context.liveButtons.bezelButtons,
                touchRingActive: context.liveButtons.touchRingActive,
                touchRingButtonDown: context.liveButtons.touchRingButtonDown,
                touchRing2Active: context.liveButtons.touchRing2Active,
                touchStrip1Active: context.liveButtons.touchStrip1Active,
                touchStrip2Active: context.liveButtons.touchStrip2Active
            )
            // Only assign when values changed — avoids spurious objectWillChange.
            if newButtons != context.liveButtons { context.liveButtons = newButtons }
            context.livePoint = point
            } // end Task @MainActor
        }

        // ── Express key closure ──────────────────────────────────────────────
        // Called on HIDThread. injectAux runs inline (it reads from injectionSnapshot
        // and posts CGEvents — both thread-safe). UI state mutations hop to main.
        let onAux: (AuxButtons) -> Void = { [weak self, weak context] aux in
            guard let context else { return }
            context.injector.injectAux(buttons: aux, settings: context.settings)
            // HID-thread gate: skip the Task hop entirely when no UI is watching.
            // Ring scrubbing streams aux reports at ~100 Hz; without this gate every
            // report spawned a main-actor Task whose body did nothing. Same pattern
            // as the needsHop gate in onTablet; both flags are HID-thread-readable.
            guard self?.appIsFrontmost == true && self?.infoViewVisible == true else { return }
            Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            // Update UI only when app is frontmost, state changed, and Info/Buttons tab is visible.
            guard appIsFrontmost && infoViewVisible else { return }
            let keys = (0..<16).map { aux[$0] }
            if keys != context.liveButtons.expressKeys {
                context.liveButtons.expressKeys = keys
            }
            let bezelKeys = (16..<19).map { aux[$0] }
            if bezelKeys != context.liveButtons.bezelButtons {
                context.liveButtons.bezelButtons = bezelKeys
            }
            if aux.touchRingActive != context.liveButtons.touchRingActive {
                context.liveButtons.touchRingActive = aux.touchRingActive
            }
            if aux.touchRing2Active != context.liveButtons.touchRing2Active {
                context.liveButtons.touchRing2Active = aux.touchRing2Active
            }
            if aux.touchRingButtonDown != context.liveButtons.touchRingButtonDown {
                context.liveButtons.touchRingButtonDown = aux.touchRingButtonDown
            }
            if aux.touchStrip1Active != context.liveButtons.touchStrip1Active {
                context.liveButtons.touchStrip1Active = aux.touchStrip1Active
            }
            if aux.touchStrip2Active != context.liveButtons.touchStrip2Active {
                context.liveButtons.touchStrip2Active = aux.touchStrip2Active
            }
            } // end Task @MainActor
        }

        // ── Battery status closure ───────────────────────────────────────────
        // Called when a BT device reports its battery state (INTUOSP2_BT family).
        // Only fires when the raw battery byte changes — not on every pen report.
        // Called on HIDThread — hop to main.
        let onBattery: (Int, Bool) -> Void = { [weak self, weak context] percent, charging in
            Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            context.batteryPercent = percent
            context.batteryCharging = charging
            self.updateDockBadge()
            } // end Task @MainActor
        }

        // ── USB HID mouse button closure (KC-100 cordless mouse) ────────────────
        // Called when a 4-byte Report ID 0x01 arrives from the mouse interface
        // (usagePage=0x01, seized).  Routes directly to the injector so buttons
        // fire at the current screen cursor position without a position remap.
        // Called on HIDThread; injectMouseButtons runs inline.
        let onMouseButton: (UInt8) -> Void = { [weak context] mask in
            guard let context else { return }
            context.injector.injectMouseButtons(mask: mask, settings: context.settings)
        }

        // ── Hardware serial closure (device unification) ─────────────────────
        // Called when a WACOM_REPORT_USB (Report ID 0x03) feature report query
        // succeeds on USB or wireless dongle. Serial is 0 if the query fails or
        // the device does not support Report ID 0x03 (e.g. old models).
        // Used to unify multi-transport variants of the same physical tablet.
        // Called on HIDThread — hop to main (DeviceRegistry is @MainActor).
        let onHardwareSerial: (UInt32) -> Void = { serial in
            Task { @MainActor in
                DeviceRegistry.shared.recordHardwareSerial(serial, forDevice: productID)
            }
        }

        // ── Create the device driver ─────────────────────────────────────────
        // Multi-interface devices (e.g. ACK-40401 dongle) enumerate separate
        // IOHIDDevices for each interface (digitizer, wireless status, touch,
        // etc). We create one driver per product and reuse it across
        // interfaces; each IOHIDDevice still registers independently for its
        // own reports.
        if let existingDriver = context.tabletDevice as? WacomKnownDevice {
            hidDeviceMap[device] = context
            existingDriver.registerDevice(device)
            return
        }

        // ── Relative wheel closure (IntuosV3 PTK-x70 scroll wheels) ────────────
        // Called on HIDThread; injectWheel runs inline (same threading contract
        // as injectAux).
        let onWheel: (Int, Int) -> Void = { [weak context] index, delta in
            guard let context else { return }
            context.injector.injectWheel(index: index, delta: delta, settings: context.settings)
        }

        // ── Touch closure (capacitive finger input on touch-capable Cintiqs) ───
        // Called on HIDThread when a decoder emits a `.touch` result.  When
        // touch is disabled in settings, return early — the hardware switch
        // on PTH-660/860 streams 0x21 reports at ~100 Hz, and publishing
        // them to `liveTouchContacts` invalidates every view that observes
        // `TabletManager` (which is every settings pane), making the UI
        // choppy and burning CPU even though no input is being injected.
        let onTouch: ([TouchContact]) -> Void = { [weak self, weak context] contacts in
            guard let context, context.settings.touchEnabled else { return }
            context.injector.injectTouch(contacts: contacts, settings: context.settings)
            // Skip the publish path entirely when no UI is observing — the
            // scratchpad sets `isPublishingEnabled` only while it is the
            // active tab and the app is frontmost.
            guard let self else { return }
            let publisher = self.liveTouch
            guard publisher.isPublishingEnabled else { return }
            // Throttle the live-contacts publish to ~30 Hz.  Always let the
            // "empty" frame through so a finger lift updates the UI promptly.
            let now = CFAbsoluteTimeGetCurrent()
            let elapsed = now - publisher.lastPublishTime
            if !contacts.isEmpty && elapsed < LiveTouchPublisher.publishInterval { return }
            publisher.lastPublishTime = now
            DispatchQueue.main.async {
                publisher.contacts = contacts
            }
        }

        // ── Wireless dongle paired PID ──────────────────────────────────────────
        // Called once on HIDThread when the 0x80 status report reveals the
        // paired tablet's PID, so ButtonMappingView can fall back to its spec
        // (the dongle's own PID isn't in WacomDeviceRegistry).
        let onPairedPID: (Int) -> Void = { [weak self, weak context] pid in
            Task { @MainActor [weak self, weak context] in
                context?.pairedProductID = pid
                // DeviceContext is nested inside `contexts`, so observers of
                // TabletManager (e.g. ButtonMappingView) don't see this
                // @Published change on its own — nudge them explicitly.
                self?.objectWillChange.send()
            }
        }

        let callbacks = DeviceRouter.Callbacks(
            onTablet: onTablet, onAux: onAux, onToolEnter: onToolEnter,
            onMouseButton: onMouseButton, onBattery: onBattery,
            onHardwareSerial: onHardwareSerial, onWheel: onWheel,
            onTouch: onTouch, onPairedPID: onPairedPID)

        switch DeviceRouter.route(
            device: device, productID: productID, usagePage: usagePage,
            isBLE: isBLE, contexts: deviceContexts, callbacks: callbacks,
            overrideSpec: vendorSpec)
        {
        case .deferred:
            pendingInterfaces[productID, default: []].append(device)
            return

        case .ledCompanion(let parentCtx):
            if let driver = parentCtx.tabletDevice as? WacomKnownDevice {
                driver.registerLEDDevice(device)
                hidDeviceMap[device] = parentCtx
            }
            return

        case .skip:
            return

        case .driver(let wacomDevice, _):
            context.tabletDevice = wacomDevice
            hidDeviceMap[device] = context
            wacomDevice.open()
            // Drain any interfaces that arrived before this driver was created.
            for pending in pendingInterfaces.removeValue(forKey: productID) ?? [] {
                hidDeviceMap[pending] = context
                (wacomDevice as? WacomKnownDevice)?.registerDevice(pending)
            }
            context.observeRingLED()  // after open() so initial LED sync reaches the device
            context.observeInjectionSnapshot()
            // Aux-only accessories (Xencelabs Quick Keys puck/dongle,
            // spec.maxX == 0) move no pointer, so a display-toggle press on
            // them must steer the tablet driving the cursor, not the
            // accessory's own — invisible — mapping. Pen-bearing devices
            // (all Wacom hardware) never get a forwarder.
            if wacomDevice.spec.maxX == 0 {
                context.injector.displayToggleForwarder = { [weak self] in
                    Task { @MainActor in self?.toggleDisplayOnPenTablet() }
                }
            }
            context.settings.applyExpressKeyDefaults(vendorID: context.vendorID)
            refreshConnectedIDs(mostRecent: productID)

            if productID == 0x00F4 {
                let prefix = "device-0x\(String(productID, radix: 16, uppercase: true))."
                if UserDefaults.standard.object(forKey: prefix + "proportionalMapping") == nil {
                    context.settings.applyPenDisplayDefaults(width: 1920, height: 1200)
                }
            }

            if activeContext == nil { activeContext = context }

            DeviceRegistry.shared.recordTablet(
                instanceKey: context.instanceKey, usbSerial: usbSerial,
                vendorID: vendorID, productString: productString)
        }
    }

    private func deviceDisconnected(_ device: IOHIDDevice) {
        guard let context = hidDeviceMap.removeValue(forKey: device) else { return }
        context.tabletDevice?.close()
        context.tabletDevice = nil
        context.hidDevice = nil
        // Clear per-device state
        context.isConnected = false
        context.transport = "—"
        context.usbSpeed = "—"
        context.batteryPercent = nil
        context.batteryCharging = false
        context.activeToolID = nil
        context.activeToolCode = 0
        context.livePoint = nil
        context.liveButtons = LiveButtonState()
        logger.info("TabletManager: \(Self.deviceName(forProductID: context.productID), privacy: .public) disconnected")
        refreshConnectedIDs(mostRecent: nil)
        if activeContext === context {
            activeContext = hidDeviceMap.values.first
            updateDockBadge()
        }
    }

    /// Performs a display toggle on behalf of an aux-only accessory (Quick
    /// Keys): targets the pen-bearing context currently driving the cursor,
    /// falling back to any connected pen-bearing tablet. Mirrors the two
    /// steps of the injector's own `.displayToggle` handling — cycle the
    /// target's mapper on HIDThread, persist the mode on main.
    private func toggleDisplayOnPenTablet() {
        let isPenBearing: (DeviceContext) -> Bool = {
            $0.isConnected && ($0.tabletDevice.map { $0.spec.maxX > 0 } ?? false)
        }
        var target: DeviceContext?
        if let active = activeContext, isPenBearing(active) {
            target = active
        } else {
            target = deviceContexts.values.first(where: isPenBearing)
        }
        guard let target else { return }
        let injector = target.injector
        CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) {
            if let snap = injector.injectionSnapshot {
                injector.cycleToggleDisplay(snapshot: snap)
            }
        }
        CFRunLoopWakeUp(HIDThread.shared.runLoop)
        target.settings.targetDisplayIndex = TabletSettings.displayModeToggle
    }

    private func refreshConnectedIDs(mostRecent: Int?) {
        connectedProductIDs = hidDeviceMap.values.map { $0.productID }.sorted()
        updateActivityAssertion()
        if let pid = mostRecent, connectedProductIDs.contains(pid) {
            connectedProductID = pid
        } else {
            connectedProductID = connectedProductIDs.last ?? 0
        }
    }

    // MARK: - Latency-critical activity assertion

    /// Held while a pen is in proximity. Tells the system this process performs
    /// latency-critical input injection, opting out of App Nap and timer coalescing.
    /// Armed on proximity-enter; dropped after `proximityIdleDelay` seconds without
    /// any pen in proximity; dropped immediately on tablet disconnect.
    private var latencyActivityToken: NSObjectProtocol?
    private var proximityIdleTimer: Timer?
    private static let proximityIdleDelay: TimeInterval = 60.0

    /// Called on tablet connect/disconnect. Connection alone no longer arms the
    /// assertion; that happens in `penEnteredProximity()` so idle connected tablets
    /// don't block App Nap.
    private func updateActivityAssertion() {
        guard !isConnected else { return }
        proximityIdleTimer?.invalidate()
        proximityIdleTimer = nil
        if let token = latencyActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            latencyActivityToken = nil
        }
    }

    /// Arms the latency assertion. Idempotent — no-op if already held.
    private func penEnteredProximity() {
        proximityIdleTimer?.invalidate()
        proximityIdleTimer = nil
        guard isConnected, latencyActivityToken == nil else { return }
        latencyActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Pen in proximity — latency-critical input injection")
    }

    /// Schedules assertion drop after `proximityIdleDelay` seconds, unless another
    /// connected device still has a pen in proximity.
    private func penExitedProximity() {
        let anyStillDown = deviceContexts.values.contains { $0.isConnected && $0.injector.lastProximity }
        guard !anyStillDown else { return }
        proximityIdleTimer?.invalidate()
        proximityIdleTimer = Timer.scheduledTimer(
            withTimeInterval: Self.proximityIdleDelay, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.proximityIdleTimer = nil
                let anyDown = self.deviceContexts.values.contains { $0.isConnected && $0.injector.lastProximity }
                guard !anyDown, let token = self.latencyActivityToken else { return }
                ProcessInfo.processInfo.endActivity(token)
                self.latencyActivityToken = nil
            }
        }
    }

    private static func connectionInfo(
        for device: IOHIDDevice
    ) -> (transport: String, speed: String) {
        let transport =
            IOHIDDeviceGetProperty(
                device, kIOHIDTransportKey as CFString) as? String ?? "Unknown"
        guard transport.caseInsensitiveCompare("USB") == .orderedSame else {
            return (transport, "—")
        }
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return ("USB", "USB") }
        for key in ["USB Device Speed", "Device Speed"] as [CFString] {
            if let prop = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, key, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            ) {
                if let n = (prop as? NSNumber)?.intValue {
                    switch n {
                    case 0: return ("USB", "Low Speed (1.5 Mb/s)")
                    case 1: return ("USB", "Full Speed (12 Mb/s)")
                    case 2: return ("USB", "High Speed (480 Mb/s)")
                    case 3: return ("USB", "SuperSpeed (5 Gb/s)")
                    default: break
                    }
                }
            }
        }
        return ("USB", "USB")
    }

    /// One-shot per launch. CGEventPost silently drops events without the
    /// Accessibility grant, so the pen would move nothing with no explanation.
    private var accessibilityPromptShown = false

    private func promptForAccessibilityIfNeeded() {
        guard !accessibilityPromptShown, !AXIsProcessTrusted() else { return }
        accessibilityPromptShown = true
        let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
        AXIsProcessTrustedWithOptions(opts)
    }

    private func updateDockBadge() {
        let anyLow = deviceContexts.values.contains {
            guard let pct = $0.batteryPercent else { return false }
            return pct < 20 && !$0.batteryCharging
        }
        NSApp.dockTile.badgeLabel = anyLow ? "!" : nil
    }
}
