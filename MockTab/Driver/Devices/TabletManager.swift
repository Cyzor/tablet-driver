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
final class LiveTouchPublisher: ObservableObject, @unchecked Sendable {  // split as each property notes
    @MainActor @Published var contacts: [TouchContact] = []

    /// HID-thread reads, main-thread writes, behind a lock.
    var isPublishingEnabled: Bool {
        get { _isPublishingEnabled.withLock { $0 } }
        set { _isPublishingEnabled.withLock { $0 = newValue } }
    }
    private let _isPublishingEnabled = OSAllocatedUnfairLock(initialState: false)

    /// HID-thread-only.  Last time the throttle let a publish through.
    /// Lives here (rather than on `TabletManager`, which is `@MainActor`)
    /// so the cross-thread read/write is no longer a concurrency violation.
    /// 8-byte loads/stores are atomic on aarch64; a torn read is impossible.
    nonisolated(unsafe) var lastPublishTime: TimeInterval = 0

    /// Throttle target: ~30 Hz.  HID delivers touch at ~100 Hz under load,
    /// and even after `isPublishingEnabled` gates inactive consumers, the
    /// active scratchpad doesn't benefit from canvas redraws faster than this.
    static let publishInterval: TimeInterval = 1.0 / 30.0
}

/// Manages IOHIDManager lifecycle, per-device contexts, and proximity-based
/// activation for multi-tablet support.
///
/// Each connected tablet gets its own `DeviceContext` (settings, injector,
/// driver).  Only the *active* context posts CGEvents — activation happens
/// automatically when a pen enters proximity on a given tablet.
///
/// `@MainActor` for this class's own observable state. Injection is **not**
/// main-thread work: IOHIDManager runs on HIDThread, and the active injector's
/// `inject()` is called inline there, reading only `injectionSnapshot`. Main
/// owns device lifecycle and UI, reached via a gated `Task { @MainActor }` so
/// ordinary in-proximity reports allocate none. When main needs an injector
/// to act, as on a context switch, it sends the work to HIDThread. See "Two
/// Threads" in `Architecture.md`.
@MainActor
final class TabletManager: ObservableObject {

    static let shared = TabletManager()

    /// Finds, connects, and decodes the tablets; set in `start()`.
    private var session: TabletSession?

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

    /// Pre-creates contexts for a tablet's companion peripherals (Xencelabs
    /// Quick Keys puck) that the registry has seen in an earlier session but
    /// that haven't connected in this one. Lets the owner's Buttons pane keep
    /// the companion's section visible and editable instead of hiding it — the same
    /// stub mechanism window restore uses; the real connect adopts the stub.
    func ensureCompanionStubs(forOwnerProductID productID: Int) {
        guard let companions = VendorDeviceRegistry.profile(forProductID: productID)?.companions
        else { return }
        for cpid in companions where contexts[cpid] == nil {
            guard let row = DeviceRegistry.shared.knownTablets.first(
                where: { $0.productID == cpid })
            else { continue }
            registerRestoredContext(
                DeviceContext(productID: cpid, vendorID: row.vendorID ?? 0x056A))
        }
    }

    /// The ACK-40401 wireless dongle's own raw PID. Its paired tablet is
    /// discovered only at runtime (report 0x80), so unlike BT/USB pairs it
    /// has no static canonical PID mapping.
    private static let ack40401ProductID = 0x0084

    /// True when `productID` is the dongle's raw identity, regardless of
    /// pairing state — for callers with no live context to consult yet
    /// (e.g. restoring a saved window at launch). The dongle never gets a
    /// window of its own, full stop.
    func isDongleRawProductID(_ productID: Int) -> Bool {
        productID == Self.ack40401ProductID
    }

    /// The tablet a dongle is relaying for, once pairing has moved it onto
    /// that tablet's context. A key with no live match (e.g. a saved window's
    /// empty-instance form) falls back to any relaying dongle.
    func relayedTabletKey(forDongleKey key: DeviceInstanceKey) -> DeviceInstanceKey? {
        let transports = dongleTransports[key].map { [$0] } ?? Array(dongleTransports.values)
        return transports.compactMap(\.home)
            .first { !isDongleRawProductID($0.productID) }?.instanceKey
    }

    /// True when `productID` is a connected dongle that hasn't yet reported
    /// its paired tablet. Once it does, `rehomeDongleTransport` moves it onto
    /// that tablet and its own context is gone, so this is the only state in
    /// which the dongle is visible as a device of its own.
    func isDongleAwaitingPairing(productID: Int) -> Bool {
        guard productID == Self.ack40401ProductID else { return false }
        return contexts[productID]?.pairedProductID == 0
    }

    /// Context for a registry row. A row with an instance token matches the
    /// exact instance; the legacy row (nil/empty token) matches the unit
    /// holding the model's claimed namespace, via the compatibility view.
    func context(for tablet: DeviceRegistry.KnownTablet) -> DeviceContext? {
        context(forKey: tablet.instanceKey)
    }

    /// Context for a window/pane identity. An exact instance matches its own
    /// unit; the legacy empty-instance identity resolves the way PID keying
    /// did — to the unit holding the model's claimed namespace.
    /// The screen a pen display draws on, matched by physical size; nil for
    /// pen tablets and for models with no registered size.
    static func penDisplayID(forProductID pid: Int) -> CGDirectDisplayID? {
        let mm: (Double?, Double?)
        if let p = VendorDeviceRegistry.profile(forProductID: pid), p.isPenDisplay {
            mm = (p.activeWidthMM, p.activeHeightMM)
        } else if let s = WacomDeviceRegistry.spec(for: pid), s.isPenDisplay {
            mm = (s.activeWidthMM, s.activeHeightMM)
        } else {
            return nil
        }
        guard let w = mm.0, w > 0, let h = mm.1, h > 0 else { return nil }
        return DisplayMapper.penDisplayID(widthMM: w, heightMM: h)
    }

    /// Physical width ÷ height of a tablet's whole surface, before rotation.
    /// Vendor millimeters where registered: raw units aren't square on every
    /// tablet (Xencelabs' Pen Display differs per axis), so maxX ÷ maxY alone
    /// can draw a landscape surface as portrait.
    func surfaceAspectRatio(for key: DeviceInstanceKey?) -> Double {
        guard let pid = key?.productID else { return 44800.0 / 29600.0 }
        if let profile = VendorDeviceRegistry.profile(forProductID: pid),
            let w = profile.activeWidthMM, w > 0, let h = profile.activeHeightMM, h > 0
        {
            return w / h
        }
        let dims: (Int, Int)?
        if let s = context(forKey: key)?.tabletDevice?.spec {
            dims = (s.maxX, s.maxY)
        } else if let s = WacomDeviceRegistry.spec(for: pid) {
            dims = (s.maxX, s.maxY)
        } else if let p = VendorDeviceRegistry.profile(forProductID: pid), let x = p.maxX, let y = p.maxY {
            dims = (x, y)
        } else {
            dims = nil
        }
        guard let (x, y) = dims, y > 0 else { return 44800.0 / 29600.0 }
        return Double(x) / Double(y)
    }

    /// The active surface in millimeters, unrotated, or nil when no
    /// registry knows it. The vendor profile comes first, as in
    /// `surfaceAspectRatio(for:)`.
    func surfaceSizeMM(for key: DeviceInstanceKey?) -> CGSize? {
        guard let pid = key?.productID else { return nil }
        if let profile = VendorDeviceRegistry.profile(forProductID: pid),
            let w = profile.activeWidthMM, w > 0, let h = profile.activeHeightMM, h > 0
        {
            return CGSize(width: w, height: h)
        }
        let spec = WacomDeviceRegistry.spec(for: pid)
        guard let w = spec?.activeWidthMM, w > 0, let h = spec?.activeHeightMM, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    func context(forKey key: DeviceInstanceKey?) -> DeviceContext? {
        guard let key else { return nil }
        if !key.instance.isEmpty {
            if let exact = deviceContexts[key] { return exact }
            // The claimed unit connects over Bluetooth without its serial,
            // under the empty instance its key normalizes to.
            let normalized = DeviceRegistry.shared.normalizedKey(key)
            return normalized.instance.isEmpty ? deviceContexts[normalized] : nil
        }
        return contexts[key.productID]
    }

    /// The device whose injector is currently posting CGEvents.
    /// `didSet` keeps `injector.isActive` in lockstep so the HIDThread fast path in
    /// `onTablet` is gated by a flag that exactly mirrors `activeContext`. Without
    /// this, `injector.isActive` would only flip on a context *change*; the very
    /// first device (where `installDriver` does `if activeContext == nil` …)
    /// would have its activation skipped and the cursor would never move.
    @Published var activeContext: DeviceContext? = nil {
        didSet {
            if oldValue !== activeContext { oldValue?.injector.isActive = false }
            activeContext?.injector.isActive = true
            if let context = activeContext, !isDongleRawProductID(context.productID) {
                UserDefaults.standard.set(context.instanceKey.stringValue, forKey: Self.lastActiveDeviceKey)
            }
        }
    }
    /// Instance key of the tablet most recently driving the cursor, persisted
    /// so "most recently seen" survives disconnects and relaunches.
    static let lastActiveDeviceKey = "lastActiveDeviceID"
    var lastActiveInstanceKey: DeviceInstanceKey? {
        UserDefaults.standard.string(forKey: Self.lastActiveDeviceKey)
            .flatMap(DeviceInstanceKey.init(stringValue:))
    }
    /// Most-recent touch contacts from the active device's touch surface.
    /// Empty when no contacts are active or the device has no finger touch.
    ///
    /// Lives on its own `ObservableObject` so the ~30 Hz touch-frame stream
    /// invalidates only the one view that consumes it (ScratchpadView) and
    /// not every settings pane that observes `TabletManager`.  Broadcasting
    /// touch updates through `TabletManager` collapsed every pane's body
    /// at touch-frame rate, which was the dominant CPU cost under a palm.
    nonisolated let liveTouch = LiveTouchPublisher()

    private var hidDeviceMap: [IOHIDDevice: DeviceContext] = [:]
    /// Raw (transport-specific) PID each registered interface belongs to —
    /// the slot key in that interface's context. Needed on disconnect:
    /// `hidDeviceMap` only gets you back to the context, and owner-aware
    /// teardown has to know which transport slot just departed.
    private var deviceRawProductID: [IOHIDDevice: Int] = [:]
    /// Live ACK-40401 dongles, keyed by the dongle's own instance. Pairing
    /// moves a dongle's driver slot onto its tablet's context; this tracks
    /// where it went so late interfaces, re-pairing and teardown can follow.
    private var dongleTransports: [DeviceInstanceKey: DongleTransport] = [:]
    /// Each session transport's driver slot, and the handle its callbacks
    /// reach their context through.
    private var sessionDrivers: [TabletTransport.ID: SessionDriver] = [:]
    private var transportHandles: [TabletTransport.ID: DriverContextHandle] = [:]
    /// Each transport's identity as it connected; a dongle keeps its own
    /// after it moves onto the tablet it relays.
    private var transportProbes: [TabletTransport.ID: DeviceIdentityProbe] = [:]
    /// The context each session tablet's transports share.
    private var tabletContexts: [ConnectedTablet.ID: DeviceContext] = [:]

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
    /// Lock-backed, not `@Published`: this is read on the HID thread at ~200 Hz
    /// inside the `onTablet` gate. `@Published`'s Combine-wrapped getter showed up
    /// as ~13% of HID-thread time when this was published. No SwiftUI view binds
    /// to this directly — only the HID-thread gates and main-thread setters touch it.
    nonisolated var appIsFrontmost: Bool {
        get { _appIsFrontmost.withLock { $0 } }
        set { _appIsFrontmost.withLock { $0 = newValue } }
    }
    private nonisolated let _appIsFrontmost = OSAllocatedUnfairLock(initialState: false)

    /// Set true by SettingsWindowController when the Info or Buttons tab is frontmost
    /// in the active window. Combined with appIsFrontmost: both must be true to update
    /// livePoint/liveButtons, eliminating all SwiftUI overhead when MockTab is in the
    /// background or a different tab is active. Lock-backed like `appIsFrontmost`.
    nonisolated var infoViewVisible: Bool {
        get { _infoViewVisible.withLock { $0 } }
        set { _infoViewVisible.withLock { $0 = newValue } }
    }
    private nonisolated let _infoViewVisible = OSAllocatedUnfairLock(initialState: false)

    /// Call when `infoViewVisible` turns true (Info/Buttons tab becomes
    /// visible and frontmost again) to reconcile any proximity-exit that
    /// happened while hidden — that clearing is deliberately skipped in the
    /// background (see the `onTablet` closure) to avoid a flash-to-blank
    /// redraw, which leaves `livePoint`/`liveButtons` stale until either this
    /// runs or the next real report arrives. No-op if the pen is genuinely
    /// still in proximity.
    func resyncLiveStateForVisibility() {
        guard let context = activeContext, context.livePoint != nil else { return }
        guard !context.injector.proximityForMain else { return }
        context.activeToolID = nil
        context.activeToolCode = 0
        context.liveButtons = LiveButtonState()
        context.livePoint = nil
    }

    /// Optional raw-data callback for calibration. When set, every active-context
    /// TabletPoint is forwarded here *in addition to* the normal injection path.
    /// Always assign through `setCalibrationPointHandler(_:)` so the HID-thread
    /// gate `calibrationActive` stays in sync.
    private(set) var calibrationPointHandler: ((TabletPoint) -> Void)?

    /// Mirror of `calibrationPointHandler != nil` for the HID-thread gate in
    /// `onTablet`. Reading the optional closure itself across threads is unsafe.
    nonisolated var calibrationActive: Bool { _calibrationActive.withLock { $0 } }
    private nonisolated let _calibrationActive = OSAllocatedUnfairLock(initialState: false)

    func setCalibrationPointHandler(_ handler: ((TabletPoint) -> Void)?) {
        calibrationPointHandler = handler
        let active = handler != nil
        _calibrationActive.withLock { $0 = active }
    }

    private var uiUpdateCounter = 0
    private static let uiUpdateInterval = 8  // every 8th report ≈ 16 Hz at 133 Hz

    /// A contact alive this many frames or fewer when it disappears counts
    /// as "short-lived" for `CaptureTouchPipeline.shortLivedContacts` — at
    /// ~100 Hz touch reporting, roughly 30 ms, well under any deliberate tap.
    private nonisolated static let shortLivedContactFrames = 3

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
        if WacomDeviceRegistry.vendorIDs.contains(vendorID) {
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

    // MARK: - Known vendors

    /// Every USB vendor whose tablets MockTab recognizes, decoded or not.
    ///
    /// Drives both this manager's device matching and the scope of a
    /// diagnostic collection run (`DiagnosticSession.knownVendorDevices`) —
    /// one list so the two can't drift. Gated by vendor ID rather than by
    /// product name on purpose: names lie. Xencelabs hardware reports itself
    /// as "HANVON UGEE", so any name-based match would miss it.
    ///
    /// - 0x056A Wacom.
    /// - 0x0531 Wacom Technology Corp. — a second Wacom VID used by the
    ///   consumer "Wacom One" CTC line (CTC-4110WL/6110WL). Confirmed via
    ///   Linux's device-ID table and libwacom, not just OTD (see
    ///   WacomDeviceRegistry's CTC section) — routed the same as 0x056A in
    ///   `vendorGate` below.
    /// - 0x256C Huion (recognition only).
    /// - 0x28BD Xencelabs / XP-Pen (recognition only).
    /// - 0x5543 UC-Logic OEMs (recognition only).
    nonisolated static let knownVendorIDs: [Int] = [0x056A, 0x0531, 0x256C, 0x28BD, 0x5543]

    // MARK: - Init

    private init() {}

    func start() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)

        // Matched by vendor (see `knownVendorIDs`), plus any vendor's
        // standards-compliant pen digitizer, the universal floor. Devices the
        // session recognizes but can't drive are named in the log, so a user
        // can see the tablet was found even though MockTab can't drive it.
        let session = TabletSession(vendorIDs: Self.knownVendorIDs, anyPenDigitizer: true, delegate: self)
        self.session = session
        #if DEBUG
        // Reads one owned tablet as unknown, for testing the guesses:
        // `defaults write com.cyzor.mocktab debugFallbackProductID -int 855` (0x0357, in decimal).
        // `debugGenericFallback` reads it as another maker's standard pen.
        // Both last one launch, so a relaunch undoes a test that goes wrong.
        let defaults = UserDefaults.standard
        let fallbackPID = defaults.integer(forKey: "debugFallbackProductID")
        session.readsUnknownWacomAsGeneric = defaults.bool(forKey: "debugGenericFallback")
        defaults.removeObject(forKey: "debugFallbackProductID")
        defaults.removeObject(forKey: "debugGenericFallback")
        if fallbackPID != 0 {
            session.unregisteredProductIDs = [fallbackPID]
            logger.notice("debug: reading 0x\(String(fallbackPID, radix: 16, uppercase: true), privacy: .public) as an unknown tablet")
        }
        // Switches on other makers' tablets, by brand, until removed:
        // `defaults write com.cyzor.mocktab enabledTabletBrands -array huion xppen`.
        // Brands: huion, gaomon, xppen, ugee, and parblo.
        for name in defaults.stringArray(forKey: "enabledTabletBrands") ?? [] {
            if let brand = TabletBrand(name: name) {
                session.experimentalTabletBrands.insert(brand)
            } else {
                logger.notice("debug: enabledTabletBrands has \(name, privacy: .public), which isn't a brand MockTab knows")
            }
        }
        if !session.experimentalTabletBrands.isEmpty {
            logger.notice("debug: switching on \(session.experimentalTabletBrands.map(\.description).sorted().joined(separator: ", "), privacy: .public) tablets")
        }
        // Reads a Xencelabs tablet the way an XP-Pen is read, for one launch:
        // `defaults write com.cyzor.mocktab debugXencelabsAsUGEE -bool YES`.
        session.readsXencelabsAsUGEE = defaults.bool(forKey: "debugXencelabsAsUGEE")
        defaults.removeObject(forKey: "debugXencelabsAsUGEE")
        #endif
        let ret = session.start()
        hidManagerOpen = (ret == kIOReturnSuccess)
        if !hidManagerOpen {
            logger.error("TabletManager: failed to open HID manager (\(ret, privacy: .public)). Check Input Monitoring permission or uninstall any existing tablet driver.")
        }

        // A tablet that stays connected through sleep may lose its mode, and
        // the Linux driver resends the mode switch on resume. The writes are
        // idempotent, so resend them a second after every wake.
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                logger.info("TabletManager: woke from sleep, resending init to \(self.contexts.count, privacy: .public) device(s)")
                for context in self.contexts.values { context.tabletDevice?.reawaken() }
            }
        }
    }

    /// Re-attempt the HID open after an Input Monitoring grant.
    ///
    /// A denied grant makes the open fail outright, so the permission
    /// arriving later doesn't bring the tablet to life by itself. Only the
    /// open is repeated, and only when it previously failed.
    @discardableResult
    func reopenIfClosed() -> Bool {
        guard !hidManagerOpen, let session else { return hidManagerOpen }
        let ret = session.retryOpen()
        hidManagerOpen = (ret == kIOReturnSuccess)
        // .notice: this fires at most once per launch, and it's the
        // difference between a working tablet and a dead one, which a
        // support log needs to show.
        if hidManagerOpen {
            logger.notice("TabletManager: HID manager opened on retry after permission grant.")
        } else {
            logger.notice("TabletManager: HID manager retry failed (\(ret, privacy: .public)) despite Input Monitoring being granted.")
        }
        return hidManagerOpen
    }

    /// Closes every tablet, restoring what connecting changed, as at quit.
    func stop() {
        // Fallback drivers close themselves; the session closes its own.
        for ctx in hidDeviceMap.values { ctx.tabletDevice?.close() }
        session?.stop()
        session = nil
        hidDeviceMap.removeAll()
        deviceRawProductID.removeAll()
        sessionDrivers.removeAll()
        transportHandles.removeAll()
        transportProbes.removeAll()
        tabletContexts.removeAll()
        dongleTransports.removeAll()
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
    static func staticSpec(forProductID productID: Int) -> TabletSpec? {
        if let spec = WacomDeviceRegistry.spec(for: productID) { return spec }
        let vendorID = DeviceRegistry.shared.vendorID(forProductID: productID)
            ?? lastSeenVendorID[productID]
            ?? 0x056A
        return VendorDeviceRegistry.drivableSpec(forVendorID: vendorID, productID: productID)
    }

    /// Everything connecting needs to know about one `IOHIDDevice`
    /// before it touches any mutable state — pure property reads plus
    /// canonicalization, no side effects. Split out so the two steps read as
    /// what they are: figure out what this interface is, then decide what to
    /// do about it.
    private struct DeviceIdentityProbe {
        let productID: Int
        let usagePage: Int
        let usage: Int
        let maxRptSize: Int
        let transport: String
        let productString: String
        let isBLE: Bool
        let usbSerial: String?
        /// The serial string as reported, before the BT-untrusted nil-out
        /// that produces `usbSerial` — kept only so the connect-time log line
        /// can show what the device actually said, not what identity trusts.
        let rawSerialProbe: String?
        let locationID: Int
        let instanceKey: DeviceInstanceKey
    }

    /// Reads the HID properties connecting needs and folds transport
    /// variants (BT/dongle PIDs) onto the canonical PID this device's
    /// context, settings namespace, and window key off. See the inline
    /// comments in `beginConnecting` for the serial/locationID
    /// trust caveats this bakes in.
    private static func probeIdentity(
        _ device: IOHIDDevice, rawProductID: Int, vendorID: Int
    ) -> DeviceIdentityProbe {
        let productID = WacomDeviceRegistry.vendorIDs.contains(vendorID)
            ? WacomDeviceRegistry.canonicalProductID(for: rawProductID)
            : VendorDeviceRegistry.canonicalProductID(for: rawProductID)
        let usagePage = hidIntProperty(device, kIOHIDPrimaryUsagePageKey)
        let usage = hidIntProperty(device, kIOHIDPrimaryUsageKey)
        let maxRptSize = hidIntProperty(device, kIOHIDMaxInputReportSizeKey)
        let transport =
            IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
        let productString =
            IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
        let isBLE = transport.lowercased().contains("bluetooth")
        // kIOHIDSerialNumberKey is only trusted for instance identity on
        // non-Bluetooth transports — see the doc comment at the
        // comment in `beginConnecting` for why BT serial is untrusted here.
        let rawSerialProbe =
            IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        let usbSerial = isBLE ? nil : rawSerialProbe
        let locationID = hidIntProperty(device, kIOHIDLocationIDKey)
        // Instance identity: token is serial-only for now — the locationID
        // fallback stays off until confirmed live; see the comment above
        // `DeviceInstanceKey` construction at the call site.
        let instanceKey = DeviceInstanceKey(
            productID: productID, usbSerial: usbSerial, locationID: 0)
        return DeviceIdentityProbe(
            productID: productID, usagePage: usagePage, usage: usage,
            maxRptSize: maxRptSize, transport: transport, productString: productString,
            isBLE: isBLE, usbSerial: usbSerial, rawSerialProbe: rawSerialProbe,
            locationID: locationID, instanceKey: instanceKey)
    }

    /// Per-connect setup shared by a direct connect and a dongle rehoming
    /// onto a context that may never have been live.
    private func prepareConnectingContext(_ context: DeviceContext) {
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
        }

        // Propagate context.objectWillChange to TabletManager so SwiftUI observers
        // get updates when per-device state changes (transport, battery, livePoint, etc).
        if context.cancellables.isEmpty {
            context.objectWillChange
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &context.cancellables)
        }
    }

    /// The context a connecting interface joins, set up for connecting.
    /// `joining` is the context the interface's tablet already has, if any.
    private func beginConnecting(
        _ device: IOHIDDevice, joining: DeviceContext? = nil
    ) -> (context: DeviceContext, probe: DeviceIdentityProbe, rawProductID: Int, vendorID: Int) {
        // Connect-phase work stalls report delivery; keep those episodes out
        // of the steady-state latency stats. The probe belongs to the pen thread.
        HIDThread.shared.perform {
            LatencyProbe.shared.noteDeviceConnected()
        }
        let vendorID = hidIntProperty(device, kIOHIDVendorIDKey)
        let rawProductID = hidIntProperty(device, kIOHIDProductIDKey)
        Self.lastSeenVendorID[rawProductID] = vendorID

        // Transport variants fold into one identity: the context, settings
        // namespace, and window all key off the canonical PID. The serial is
        // trusted for identity only off Bluetooth, whose stack reports a
        // different one for the same tablet; that split a PTH-660 into
        // separate USB and Bluetooth contexts.
        let probe = Self.probeIdentity(device, rawProductID: rawProductID, vendorID: vendorID)
        let productID = probe.productID
        Self.lastSeenVendorID[productID] = vendorID
        let pidStr =
            rawProductID == productID
            ? "0x\(String(productID, radix:16))"
            : "0x\(String(rawProductID, radix:16)) → 0x\(String(productID, radix:16))"
        logger.info("TabletManager: device pid=\(pidStr, privacy: .public) usagePage=0x\(String(probe.usagePage, radix:16), privacy: .public) usage=0x\(String(probe.usage, radix:16), privacy: .public) maxRptSize=\(probe.maxRptSize, privacy: .public) transport=\(probe.transport, privacy: .public) product=\"\(probe.productString, privacy: .public)\" serial=\(probe.rawSerialProbe ?? "—", privacy: .public)\(probe.isBLE ? " (BT, untrusted)" : "") locationID=0x\(String(probe.locationID, radix:16), privacy: .public)")

        let context = joining ?? resolveContext(probe: probe, rawProductID: rawProductID, vendorID: vendorID)
        deviceContexts[context.instanceKey] = context
        prepareConnectingContext(context)
        // A fresh connection attempt gets a clean slate; an open failure sets
        // the message again.
        context.connectionErrorMessage = nil
        context.isConnected = true
        context.transport = probe.transport
        context.usbSpeed = Self.connectionInfo(for: device).speed
        // Diagnostic only; see `bluetoothAddressCandidate`.
        if probe.isBLE { context.bluetoothAddressCandidate = probe.rawSerialProbe }

        // The first tablet is when injection becomes possible, so ask for
        // Accessibility here, where the request has context.
        promptForAccessibilityIfNeeded()
        return (context, probe, rawProductID, vendorID)
    }

    /// Installs a driver into its context's slot for its transport and
    /// finishes connecting the context.
    private func installDriver(
        _ driver: any TabletDevice, device: IOHIDDevice, context: DeviceContext,
        contextHandle: DriverContextHandle, probe: DeviceIdentityProbe,
        rawProductID: Int, vendorID: Int, delivers: Bool
    ) {
        let productID = probe.productID
        let instanceKey = probe.instanceKey
        let hadNoDriverYet = !context.hasAnyDriverSlot
        context.installDriver(driver, forRawProductID: rawProductID)
        updateDockBadge()
        if rawProductID == Self.ack40401ProductID {
            dongleTransports[instanceKey] = DongleTransport(handle: contextHandle, home: context)
        }
        // Only the first driver interface claims `hidDevice`; see its doc comment.
        if !context.firstDriverInterfaceClaimed {
            context.firstDriverInterfaceClaimed = true
            context.hidDevice = device
        }
        Self.offerForCapture(device, usagePage: probe.usagePage, on: context, delivers: delivers)
        hidDeviceMap[device] = context
        deviceRawProductID[device] = rawProductID
        driver.open()
        if hadNoDriverYet {
            // The first transport this context has seen wires the settings
            // sinks, once: they target whichever slot wins, so a second
            // subscription would send every write twice.
            context.observeRingLED()
            context.observeInjectionSnapshot()
            context.hasWiredDriverLifecycle = true
        } else if context.activeDriverRawProductID == rawProductID {
            // This transport just outranked the one already installed, and
            // missed the settings writes made while it wasn't driving.
            context.resyncActiveDriverDisplayState()
        }
        // Aux-only accessories (Quick Keys, ExpressKey Remote) move no
        // pointer, so their display toggles steer the tablet driving the
        // cursor.
        if driver.spec.maxX == 0 {
            let accessoryVendor = context.vendorID
            context.injector.displayToggleForwarder = { [weak self] in
                Task { @MainActor in self?.toggleDisplayOnPenTablet(vendorID: accessoryVendor) }
            }
            context.injector.relativeModeToggleForwarder = { [weak self] in
                Task { @MainActor in self?.toggleRelativeModeOnPenTablet(vendorID: accessoryVendor) }
            }
            context.injector.spanDisplaysForwarder = { [weak self] in
                Task { @MainActor in self?.toggleSpanOnPenTablet(vendorID: accessoryVendor) }
            }
        }
        context.settings.applyExpressKeyDefaults(
            vendorID: context.vendorID,
            splitPad: WacomDeviceRegistry.spec(for: context.productID)?.hasSplitPadLayout == true)
        refreshConnectedIDs(mostRecent: productID)

        context.settings.penDisplayLocator = { Self.penDisplayID(forProductID: productID) }
        context.settings.migrateTargetDisplayUUID()

        // First connection of a pen display: map it to its own screen.
        let prefix = DeviceInstanceClaims.prefix(productID: productID)
        if UserDefaults.standard.object(forKey: prefix + "proportionalMapping") == nil,
            let screen = Self.penDisplayID(forProductID: productID)
        {
            context.settings.applyPenDisplayDefaults(display: screen)
        }

        // A dongle still pairing must never become the active context.
        if activeContext == nil && !isDongleAwaitingPairing(productID: productID) {
            activeContext = context
        }

        DeviceRegistry.shared.recordTablet(
            instanceKey: context.instanceKey, usbSerial: probe.usbSerial,
            vendorID: vendorID, productString: probe.productString)
        if rawProductID == Self.ack40401ProductID {
            // Undo the paired-model rename earlier builds gave its row.
            DeviceRegistry.shared.updateModelName(
                forDonglePairing: instanceKey, to: Self.deviceName(forProductID: rawProductID))
        }
    }

    /// The context this interface joins: its dongle's home, an existing
    /// context, a window-restore stub, or a new one.
    private func resolveContext(
        probe: DeviceIdentityProbe, rawProductID: Int, vendorID: Int
    ) -> DeviceContext {
        let productID = probe.productID
        let usbSerial = probe.usbSerial
        let locationID = probe.locationID
        let instanceKey = probe.instanceKey
        let context: DeviceContext
        if rawProductID == Self.ack40401ProductID,
            let home = dongleTransports[instanceKey]?.home
        {
            // A late interface of a dongle already rehomed onto its tablet.
            context = home
        } else if let existing = deviceContexts[instanceKey] {
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
        return context
    }

    /// The HID-thread callbacks for one connecting interface.
    private func makeCallbacks(
        context: DeviceContext, contextHandle: DriverContextHandle, device: IOHIDDevice,
        productID: Int, instanceKey: DeviceInstanceKey
    ) -> SessionDriver.Callbacks {
        // Only handed back to main.
        nonisolated(unsafe) let device = device

        // ── Tool-enter closure (IntuosV2 only) ──────────────────────────────
        // Called on HIDThread — hop to main before touching @Published properties.
        let onToolEnter: @Sendable (ToolIdentity) -> Void = { [weak self, contextHandle] identity in
            let context = contextHandle.context
            // Set synchronously: pen points inject inline on this thread, so
            // the main-actor Task below loses the race by ~6 ms.
            // `postProximityEvent` derives `vendorPointerType` from
            // `activeToolCode`, so losing it reported the Art Pen as a Grip
            // Pen and apps ignored its rotation. `previousToolCode` is read
            // first — the main-actor block needs the code this one replaced.
            let previousToolCode = context?.injector.activeToolCode
            if let injector = context?.injector {
                // Identity can arrive after the pen entered range: the PTK-x70
                // sends none in its first frame, and the identity left over is
                // the previous pen's. Apps read capabilities such as rotation
                // only from proximity, so leave as the old tool and re-enter.
                let changed = identity.toolCode != injector.activeToolCode
                    || identity.serial != injector.activeToolSerial
                let reannounce = changed && injector.lastProximity
                if reannounce {
                    injector.postProximityEvent(
                        entering: false, at: injector.shimLastScreen,
                        eraser: injector.activeToolIsEraser)
                }
                injector.activeToolCode = identity.toolCode
                injector.activeToolSerial = identity.serial
                injector.activeToolIsMouse = identity.isMouse
                injector.activeToolIsEraser = identity.isEraser
                if reannounce {
                    injector.postProximityEvent(
                        entering: true, at: injector.shimLastScreen,
                        eraser: injector.activeToolIsEraser)
                }
            }
            Task { @MainActor [weak self, weak context] in
            guard self != nil, let context else { return }
            // A different tool just came into range, so the previous one is off
            // the tablet and anything it was holding must come up. Hop to
            // HIDThread: the held-button state is confined there, same as
            // `releaseOnAppSwitch`. See `releaseBindingHeldButton` for why a
            // tool change is the right trigger and proximity exit is not.
            //
            // Compares the pre-overwrite value: the injector already holds
            // this tool's code, so reading it here would make every swap look
            // like "same tool" and strand the outgoing tool's held buttons.
            if identity.toolCode != previousToolCode {
                let injector = context.injector
                HIDThread.shared.perform {
                    injector.releaseHeldStateForToolChange()
                }
            }
            // Published values are set only on a change, so a repeated enter
            // from the same tool doesn't redraw the panes.
            if context.activeToolSerial != identity.serial { context.activeToolSerial = identity.serial }
            if context.activeToolIsMouse != identity.isMouse { context.activeToolIsMouse = identity.isMouse }
            if context.activeToolCode != identity.toolCode { context.activeToolCode = identity.toolCode }
            if context.lastKnownToolCode != identity.toolCode { context.lastKnownToolCode = identity.toolCode }
            // Propagate tool code to calibration session so tool changes are tracked.
            CaptureEngine.updateToolCode(identity.toolCode, device: device)
            let toolID = DeviceRegistry.shared.recordTool(
                identity: identity, forDevice: context.instanceKey)
            // An eraser end uses its pen's settings, so flipping the pen over
            // doesn't swap the settings panes to a second copy of the pen.
            let settingsID = DeviceRegistry.tipSiblingID(of: toolID) ?? toolID
            let toolSets = context.settings.toolSettings(forID: settingsID, isMouse: identity.isMouse)
            // Reassigning the same tool would reload all its settings.
            if context.activeTool !== toolSets { context.activeTool = toolSets }
            if context.settings.activeTool !== toolSets { context.settings.activeTool = toolSets }
            // Settings must resolve here — the lookup needs the registry and
            // settings store, neither reachable from HIDThread. Arriving late
            // affects only tuning, not tool recognition. Handed over on
            // HIDThread: its `didSet` reconciles modifier state owned there.
            // The identity fields aren't re-set here; the synchronous block
            // above always sets them, and a late copy could overwrite a newer
            // pen's.
            let injector = context.injector
            HIDThread.shared.perform {
                injector.activeToolSettings = toolSets
            }
            context.activeToolID = toolID
            } // end Task @MainActor
        }

        // ── Tablet point closure ─────────────────────────────────────────────
        // Called on HIDThread.
        //
        // Fast path: when this device's injector is the active one, inject() runs
        // inline on HIDThread — no Task @MainActor hop, no scheduler wait. Inject
        // reads everything it needs from `injectionSnapshot`, which the main side
        // pushes onto HIDThread whenever settings change.
        //
        // Slow path: active-context switching (proximity-enter from a non-active
        // device) and per-report UI updates still hop to main. Throughput-critical
        // CGEvent posting never waits on either.
        let onTablet: @Sendable (TabletPoint) -> Void = { [weak self, contextHandle] point in
            guard let context = contextHandle.context else { return }
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
            // At 200 Hz, a Task per report with nothing to do would allocate on
            // the most common path.
            let needsHop: Bool
            if isActive {
                needsHop = !point.inProximity  // proximity-exit cleanup
                    || (point.inProximity && !wasInProximity)  // proximity-enter: re-arm assertion
                    || self?.appIsFrontmost == true && self?.infoViewVisible == true  // UI update
                    || self?.calibrationActive == true  // calibration sample
            } else {
                // A device that isn't driving the cursor still owes apps the
                // exit for a pen it brought into range. Here, not on main:
                // the injector's state belongs to this thread.
                if !point.inProximity && injector.lastProximity {
                    injector.inject(point: point, settings: context.settings)
                }
                needsHop = point.inProximity  // proximity-enter → context switch
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
                let outgoing = self.activeContext
                self.activeContext = context
                self.penEnteredProximity()
                // Both injects run on HIDThread, which owns injector state:
                // from main they raced that thread's own injects of the same
                // injectors. The outgoing pen leaves first.
                let outgoingInjector = outgoing?.injector
                let outgoingSettings = outgoing?.settings
                let settings = context.settings
                HIDThread.shared.perform {
                    if let outgoingInjector, outgoingInjector.lastProximity {
                        let exitPoint = TabletPoint(
                            x: 0, y: 0, maxX: 1, maxY: 1,
                            pressure: 0, maxPressure: 1,
                            tiltX: 0, tiltY: 0,
                            penButton1: false, penButton2: false,
                            eraser: false, inProximity: false, hoverDistance: 0)
                        outgoingInjector.inject(point: exitPoint, settings: outgoingSettings)
                    }
                    // The report that asked for the switch, unless a newer one
                    // already arrived through the fast path.
                    if !injector.lastProximity {
                        injector.inject(point: point, settings: settings)
                    }
                }
            }

            // Only the active context updates UI.
            guard self.activeContext === context else { return }

            // Forward raw data to calibration session if active.
            self.calibrationPointHandler?(point)

            // ── UI state — gated + throttled ─────────────────────────────────
            if !point.inProximity {
                self.uiUpdateCounter = 0
                self.penExitedProximity()
                // Clearing livePoint/liveButtons/activeToolID while hidden made
                // Info flash on every proximity change instead of staying put —
                // worse than a stale frame. Leave the fields as they were; they
                // get reconciled by resyncLiveStateForVisibility() the moment
                // Info becomes visible again, or by the next real report.
                guard appIsFrontmost && infoViewVisible else { return }
                context.activeToolID = nil
                context.activeToolCode = 0
                context.liveButtons = LiveButtonState()
                context.mouseWheelTurning = false
                context.livePoint = nil
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

            // Ahead of the throttle, which would drop most single wheel steps.
            let now = ProcessInfo.processInfo.systemUptime
            if point.mouseWheelDelta != 0 { context.mouseWheelLastStep = now }

            // Throttle continuous updates to ~16 Hz.
            self.uiUpdateCounter += 1
            guard self.uiUpdateCounter >= Self.uiUpdateInterval else { return }
            self.uiUpdateCounter = 0

            let toolIsMouse = context.activeToolIsMouse
            // Must match the injection path exactly — run the raw reading
            // through the same tool LUT (dead zone + curve) before testing the
            // floor. Comparing the raw value here would light the Info pane's
            // tip indicator inside a user-configured Click Threshold, where no
            // click is actually being injected.
            let tipDown =
                toolIsMouse
                ? point.penButton1
                : InputInjector.curvedPressure(
                    point.normalizedPressure, lut: context.settings.activeTool.pressureLUT)
                    > InputInjector.tipPressureThreshold
            let newButtons = LiveButtonState(
                tipDown: tipDown && !point.eraser,
                eraserDown: tipDown && point.eraser,
                button1Down: point.penButton1,
                button2Down: point.penButton2,
                // A mouse's middle button stands in the third slot, which mice leave empty.
                button3Down: point.penButton3 || (toolIsMouse && point.mouseMiddleButton),
                button4Down: point.penButton4,
                button5Down: point.penButton5,
                expressKeys: context.liveButtons.expressKeys,
                bezelButtons: context.liveButtons.bezelButtons,
                touchRingActive: context.liveButtons.touchRingActive,
                touchRingButtonDown: context.liveButtons.touchRingButtonDown,
                touchRing2Active: context.liveButtons.touchRing2Active,
                touchRing2ButtonDown: context.liveButtons.touchRing2ButtonDown,
                touchStrip1Active: context.liveButtons.touchStrip1Active,
                touchStrip2Active: context.liveButtons.touchStrip2Active
            )
            // Only assign when values changed — avoids spurious objectWillChange.
            if newButtons != context.liveButtons { context.liveButtons = newButtons }
            // Lit from a step until the wheel has been still a moment; a mouse
            // in range keeps reporting, so the next update turns it off.
            let wheelTurning = toolIsMouse && now - context.mouseWheelLastStep < 0.35
            if wheelTurning != context.mouseWheelTurning { context.mouseWheelTurning = wheelTurning }
            context.livePoint = point
            } // end Task @MainActor
        }

        // ── Express key closure ──────────────────────────────────────────────
        // Called on HIDThread. injectAux runs inline (it reads from injectionSnapshot
        // and posts CGEvents — both thread-safe). UI state mutations hop to main.
        let onAux: @Sendable (PadState) -> Void = { [weak self, contextHandle] aux in
            guard let context = contextHandle.context else { return }
            context.injector.injectAux(pad: aux, settings: context.settings)
            // HID-thread gate: skip the Task hop entirely when no UI is watching.
            // Ring scrubbing streams aux reports at ~100 Hz; without this gate every
            // report spawned a main-actor Task whose body did nothing. Same pattern
            // as the needsHop gate in onTablet; both flags are HID-thread-readable.
            guard self?.appIsFrontmost == true && self?.infoViewVisible == true else { return }
            Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            // Update UI only when app is frontmost, state changed, and Info/Buttons tab is visible.
            guard appIsFrontmost && infoViewVisible else { return }
            let keys = (0..<16).map { aux.button($0) }
            if keys != context.liveButtons.expressKeys {
                context.liveButtons.expressKeys = keys
            }
            let bezelKeys = (16..<(16 + ControlTarget.bezelSlotCount)).map { aux.button($0) }
            let ring1 = aux.rings.first, ring2 = aux.rings.dropFirst().first
            let touchRingActive = ring1?.position != nil
            let touchRing2Active = ring2?.position != nil
            let touchRingButtonDown = ring1?.buttonDown ?? false
            let touchRing2ButtonDown = ring2?.buttonDown ?? false
            let touchStrip1Active = aux.strips.first?.position != nil
            let touchStrip2Active = aux.strips.dropFirst().first?.position != nil
            if bezelKeys != context.liveButtons.bezelButtons {
                context.liveButtons.bezelButtons = bezelKeys
            }
            if touchRingActive != context.liveButtons.touchRingActive {
                context.liveButtons.touchRingActive = touchRingActive
            }
            if touchRing2Active != context.liveButtons.touchRing2Active {
                context.liveButtons.touchRing2Active = touchRing2Active
            }
            if touchRingButtonDown != context.liveButtons.touchRingButtonDown {
                context.liveButtons.touchRingButtonDown = touchRingButtonDown
            }
            if touchRing2ButtonDown != context.liveButtons.touchRing2ButtonDown {
                context.liveButtons.touchRing2ButtonDown = touchRing2ButtonDown
            }
            if touchStrip1Active != context.liveButtons.touchStrip1Active {
                context.liveButtons.touchStrip1Active = touchStrip1Active
            }
            if touchStrip2Active != context.liveButtons.touchStrip2Active {
                context.liveButtons.touchStrip2Active = touchStrip2Active
            }
            } // end Task @MainActor
        }

        // ── Battery status closure ───────────────────────────────────────────
        // Called when a Bluetooth tablet or the wireless kit reports its battery.
        // Fires only when the reading changes, not on every report. A nil
        // percentage while charging means the level is unknown.
        // Called on HIDThread — hop to main.
        let onBattery: @Sendable (Int?, Bool) -> Void = { [weak self, contextHandle] percent, charging in
            let context = contextHandle.context
            Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            context.applyBatteryReading(percent: percent, charging: charging)
            self.updateDockBadge()
            } // end Task @MainActor
        }

        // Called on HIDThread when a wireless kit's tablet links or sleeps.
        let onWirelessLink: @Sendable (Bool) -> Void = { [contextHandle] linked in
            let context = contextHandle.context
            Task { @MainActor [weak context] in context?.wirelessLinked = linked }
        }

        // ── USB HID mouse button closure (KC-100 cordless mouse) ────────────────
        // Called when a 4-byte Report ID 0x01 arrives from the mouse interface
        // (usagePage=0x01, seized).  Routes directly to the injector so buttons
        // fire at the current screen cursor position without a position remap.
        // Called on HIDThread; injectMouseButtons runs inline.
        let onMouseButton: @Sendable (UInt8) -> Void = { [contextHandle] mask in
            guard let context = contextHandle.context else { return }
            context.injector.injectMouseButtons(mask: mask, settings: context.settings)
        }

        // ── Relative wheel closure (IntuosV3 PTK-x70 scroll wheels) ────────────
        // Called on HIDThread; injectWheel runs inline (same threading contract
        // as injectAux).
        // When each dial last stepped, and whether the pane shows it turning.
        // Written on HIDThread, read by the main-actor watch below.
        let dialActivity = OSAllocatedUnfairLock(initialState: (lastStep: [0.0, 0.0], lit: [false, false]))
        let onWheel: @Sendable (Int, Int) -> Void = { [weak self, contextHandle] index, delta in
            guard let context = contextHandle.context else { return }
            context.injector.injectWheel(index: index, delta: delta, settings: context.settings)
            // Same gate as onAux: no hop while no pane is watching. Only the
            // step that starts a turn hops; later steps just move the time.
            guard index < 2, self?.appIsFrontmost == true && self?.infoViewVisible == true else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let starts = dialActivity.withLock { a -> Bool in
                a.lastStep[index] = now
                guard !a.lit[index] else { return false }
                a.lit[index] = true
                return true
            }
            guard starts else { return }
            Task { @MainActor [weak context] in
                guard let context else { return }
                context.dialsTurning[index] = true
                // Off once the dial has been still for a third of a second.
                while true {
                    try? await Task.sleep(for: .milliseconds(150))
                    let still = dialActivity.withLock { a -> Bool in
                        guard ProcessInfo.processInfo.systemUptime - a.lastStep[index] > 0.35 else { return false }
                        a.lit[index] = false
                        return true
                    }
                    if still { break }
                }
                context.dialsTurning[index] = false
            }
        }

        // ── Touch closure (capacitive finger input on touch-capable Cintiqs) ───
        // Called on HIDThread when a decoder emits a `.touch` result.  When
        // touch is disabled in settings, return early — the hardware switch
        // on PTH-660/860 streams 0x21 reports at ~100 Hz, and publishing
        // them would redraw panes and burn CPU with no input injected.
        // Per-contact-id position, area, and lifetime, purely to derive the
        // erratic-touch diagnostics below (`maxContactJump`/
        // `shortLivedContacts`/`maxStallBeforeLift`) — not used by
        // injection. Lives for this device connection's lifetime, same as
        // the closures below.
        nonisolated(unsafe) var touchContactTrack: [Int: (x: Int, y: Int, area: Int?, framesAlive: Int, stalledFrames: Int)] = [:]  // HIDThread-only

        // mm per touch unit, for the contact-spacing diagnostic; nil when the
        // registry has no physical size for this tablet.
        let touchMMPerUnit: (x: Double, y: Double)? = WacomDeviceRegistry.spec(for: productID)
            .flatMap { spec in
                guard let w = spec.activeWidthMM, let h = spec.activeHeightMM,
                    spec.touchMaxX > 0, spec.touchMaxY > 0
                else { return nil }
                return (w / Double(spec.touchMaxX), h / Double(spec.touchMaxY))
            }

        let onTouch: @Sendable ([TouchContact]) -> Void = { [weak self, contextHandle] contacts in
            // Erratic-touch diagnostics: a same-id jump far larger than a
            // finger can move in one ~10ms report period, a contact that
            // flickers away again within a couple of frames, or a contact
            // whose position stops advancing while still reported "down" are
            // each a distinct signature a noisy/wet/dirty/marginal
            // capacitive surface can produce — see the probe fields' doc
            // comments.
            var frameMaxJump: Int?
            let currentIDs = Set(contacts.map(\.id))
            for contact in contacts {
                if let prev = touchContactTrack[contact.id] {
                    let dx = contact.x - prev.x, dy = contact.y - prev.y
                    let stalledFrames = (dx == 0 && dy == 0) ? prev.stalledFrames + 1 : 0
                    let jump = Int(sqrt(Double(dx * dx + dy * dy)))
                    frameMaxJump = Swift.max(frameMaxJump ?? 0, jump)
                    touchContactTrack[contact.id] =
                        (contact.x, contact.y, contact.contactArea, prev.framesAlive + 1, stalledFrames)
                } else {
                    touchContactTrack[contact.id] = (contact.x, contact.y, contact.contactArea, 1, 0)
                }
            }
            var newlyShortLived = 0
            var longestDepartingStall: (frames: Int, area: Int?, x: Int, y: Int)?
            for id in touchContactTrack.keys where !currentIDs.contains(id) {
                let departed = touchContactTrack[id]!
                if departed.framesAlive <= Self.shortLivedContactFrames {
                    newlyShortLived += 1
                }
                if departed.stalledFrames > (longestDepartingStall?.frames ?? -1) {
                    longestDepartingStall = (departed.stalledFrames, departed.area, departed.x, departed.y)
                }
                touchContactTrack.removeValue(forKey: id)
            }

            // First stage of the pipeline probe: everything the decoder
            // produced, counted before any gate can discard it. See
            // TouchPipelineProbe.
            TouchPipelineProbe.note {
                $0.framesDecoded += 1
                $0.contactsDecoded += contacts.count
                $0.noteFrameContacts(
                    contacts.count, withSize: contacts.filter { $0.contactArea != nil }.count)
                if let mm = touchMMPerUnit, contacts.count >= 2 {
                    var closest = Double.infinity
                    for i in contacts.indices {
                        for j in contacts.indices where j > i {
                            let dx = Double(contacts[i].x - contacts[j].x) * mm.x
                            let dy = Double(contacts[i].y - contacts[j].y) * mm.y
                            closest = Swift.min(closest, (dx * dx + dy * dy).squareRoot())
                        }
                    }
                    $0.noteContactSpacing(mm: closest)
                }
                for contact in contacts { $0.noteExtent(x: contact.x, y: contact.y) }
                if let frameMaxJump {
                    $0.maxContactJump = Swift.max($0.maxContactJump ?? 0, frameMaxJump)
                }
                $0.shortLivedContacts += newlyShortLived
                if let stall = longestDepartingStall, stall.frames > ($0.maxStallBeforeLift ?? -1) {
                    $0.maxStallBeforeLift = stall.frames
                    $0.stallAreaAtLift = stall.area
                    $0.stallX = stall.x
                    $0.stallY = stall.y
                }
            }
            // The snapshot, not `settings`: this runs on HIDThread.
            guard let context = contextHandle.context,
                context.injector.injectionSnapshot?.touchEnabled == true
            else {
                TouchPipelineProbe.note { $0.framesTouchDisabled += 1 }
                return
            }
            context.injector.injectTouch(contacts: contacts, settings: context.settings)
            // Skip the publish path entirely when no UI is observing — the
            // scratchpad sets `isPublishingEnabled` only while it is the
            // active tab and the app is frontmost.
            guard let self else { return }
            let publisher = self.liveTouch
            guard publisher.isPublishingEnabled else { return }
            // Throttle the live-contacts publish to ~30 Hz.  Always let the
            // "empty" frame through so a finger lift updates the UI promptly.
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - publisher.lastPublishTime
            if !contacts.isEmpty && elapsed < LiveTouchPublisher.publishInterval { return }
            publisher.lastPublishTime = now
            DispatchQueue.main.async {
                publisher.contacts = contacts
            }
        }

        return SessionDriver.Callbacks(
            onTablet: onTablet, onAux: onAux, onToolEnter: onToolEnter,
            onMouseButton: onMouseButton, onBattery: onBattery, onWirelessLink: onWirelessLink,
            onWheel: onWheel, onTouch: onTouch)
    }

    /// List `device` as an interface a capture session may record from, if
    /// its reports reach a driver.
    ///
    /// The filter keeps a capture file honest. `CaptureEngine` records every
    /// listed interface and reports each one's sample count, so a zero reads
    /// as a fact about the hardware: it stayed silent, as a device awaiting a
    /// mode switch does. An interface nobody listened to would read zero for
    /// a reason that has nothing to do with the hardware.
    private static func offerForCapture(
        _ device: IOHIDDevice, usagePage: Int, on context: DeviceContext, delivers: Bool
    ) {
        guard delivers else { return }
        guard !context.captureInterfaces.contains(where: { $0.device === device }) else { return }
        context.captureInterfaces.append(
            CaptureInterfaceCandidate(device: device, usagePage: usagePage))
    }


    /// Drops one interface from the maps and from its context.
    private func forgetInterface(_ device: IOHIDDevice, of context: DeviceContext) {
        hidDeviceMap.removeValue(forKey: device)
        deviceRawProductID.removeValue(forKey: device)
        // Only the interface `hidDevice` points to clears it; see its doc comment.
        if context.hidDevice === device {
            context.hidDevice = nil
            context.firstDriverInterfaceClaimed = false
        }
        context.captureInterfaces.removeAll { $0.device == nil || $0.device === device }
    }

    /// Removes one transport's driver slot. A context can have more than one
    /// live transport (Quick Keys on its cable and receiver), and losing one
    /// mustn't blank a context whose other transport is still connected.
    private func releaseSlot(_ rawPID: Int, of context: DeviceContext) {
        let wasOwner = context.activeDriverRawProductID == rawPID
        let removed = context.removeDriverSlot(forRawProductID: rawPID)
        removed?.close()
        updateDockBadge()
        if removed != nil, rawPID == Self.ack40401ProductID {
            dongleTransports = dongleTransports.filter { $0.value.home !== context }
        }
        if let survivorPID = context.activeDriverRawProductID {
            if wasOwner {
                // The survivor sat in a losing slot and missed the settings
                // writes meant for the active driver.
                context.resyncActiveDriverDisplayState()
                logger.info("TabletManager: \(Self.deviceName(forProductID: context.productID), privacy: .public) — transport 0x\(String(rawPID, radix: 16), privacy: .public) disconnected, promoted 0x\(String(survivorPID, radix: 16), privacy: .public)")
            }
            refreshConnectedIDs(mostRecent: nil)
            return
        }
        markFullyDisconnected(context)
    }

    /// Resets a context whose last transport just left.
    private func markFullyDisconnected(_ context: DeviceContext) {
        // Anything the departing tool was holding (a barrel button, a puck's
        // mouse-mode click, a Scroll Drag pan) gets no proximity-exit report
        // to release it — there's no more device to send one. Same release call as a tool
        // change; see `releaseHeldStateForToolChange`.
        let injector = context.injector
        HIDThread.shared.perform {
            injector.releaseHeldStateForDisconnect()
        }
        // Drop the sinks with the flag that gates installing them: reconnect
        // re-runs the observers and `.store(in:)` appends.
        context.teardownDriverLifecycleObservers()
        context.hasWiredDriverLifecycle = false
        context.isConnected = false
        context.transport = "—"
        context.usbSpeed = "—"
        context.batteryPercent = nil
        context.batteryCharging = false
        context.wirelessLinked = nil
        context.activeToolID = nil
        context.activeToolCode = 0
        context.livePoint = nil
        context.liveButtons = LiveButtonState()
        logger.info("TabletManager: \(Self.deviceName(forProductID: context.productID), privacy: .public) disconnected")
        refreshConnectedIDs(mostRecent: nil)
        if activeContext === context {
            activeContext = hidDeviceMap.values.first(where: {
                !isDongleAwaitingPairing(productID: $0.productID)
            })
            updateDockBadge()
        }
    }

    /// The pen tablet an accessory's toggle should steer: the active one if
    /// it's the accessory's own brand, else any connected one that is. Never
    /// another vendor's — a Quick Keys press once flipped a Wacom tablet into
    /// relative mode because it happened to be the active one.
    private func penTablet(forAccessoryVendor vendorID: Int) -> DeviceContext? {
        let isTarget: (DeviceContext) -> Bool = {
            $0.isConnected && $0.vendorID == vendorID
                && ($0.tabletDevice.map { $0.spec.maxX > 0 } ?? false)
        }
        if let active = activeContext, isTarget(active) { return active }
        return deviceContexts.values.first(where: isTarget)
    }

    /// `.displayToggle` from an aux-only accessory (Quick Keys, ExpressKey
    /// Remote). Target as in `penTablet(forAccessoryVendor:)`. Mirrors the
    /// injector's own handling: cycle the target's mapper on HIDThread,
    /// persist the mode on main.
    private func toggleDisplayOnPenTablet(vendorID: Int) {
        guard let target = penTablet(forAccessoryVendor: vendorID) else { return }
        let injector = target.injector
        HIDThread.shared.perform {
            if let snap = injector.injectionSnapshot {
                injector.cycleToggleDisplay(snapshot: snap)
            }
        }
        target.settings.targetDisplayIndex = TabletSettings.displayModeToggle
    }

    /// `.spanDisplaysToggle` from an aux-only accessory. Target as in
    /// `penTablet(forAccessoryVendor:)`.
    private func toggleSpanOnPenTablet(vendorID: Int) {
        penTablet(forAccessoryVendor: vendorID)?.settings.toggleTemporarySpan()
    }

    /// `.relativeModeToggle` from an aux-only accessory (Quick Keys,
    /// ExpressKey Remote), which has no cursor of its own. Target as in
    /// `penTablet(forAccessoryVendor:)`.
    private func toggleRelativeModeOnPenTablet(vendorID: Int) {
        guard let target = penTablet(forAccessoryVendor: vendorID) else { return }
        let injector = target.injector
        HIDThread.shared.perform {
            injector.displayMapper.clearRelativeAnchor()
        }
        target.settings.relativeCursorMovement.toggle()
    }

    private func refreshConnectedIDs(mostRecent: Int?) {
        // hidDeviceMap has one entry per IOHIDDevice interface, and a
        // multi-interface tablet's siblings all point at the same
        // DeviceContext (see registerDevice/the `.driver` case above) — dedupe
        // by context identity, not just productID, so two genuinely separate
        // units of the same model still both count.
        var seen = Set<ObjectIdentifier>()
        connectedProductIDs = hidDeviceMap.values
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
            .map { $0.productID }
            .sorted()
        updateActivityAssertion()
        if let pid = mostRecent, connectedProductIDs.contains(pid) {
            connectedProductID = pid
        } else {
            connectedProductID = connectedProductIDs.last ?? 0
        }
    }

    /// Moves a dongle's driver slot onto the context of the tablet it relays,
    /// so the tablet keeps one identity, settings and window across USB and
    /// wireless — the way BT/USB fold at connect. Pairing arrives after the
    /// dongle connects, so this happens mid-session: the slot, its interfaces
    /// and its callbacks all move, and the context it leaves is torn down if
    /// that was its last transport.
    private func rehomeDongleTransport(dongleKey: DeviceInstanceKey, pairedProductID pid: Int) {
        let rawPID = Self.ack40401ProductID
        guard let transport = dongleTransports[dongleKey],
            let source = transport.home,
            source.productID != pid,
            let driver = source.driverSlot(forRawProductID: rawPID)
        else { return }
        // An unknown paired PID has no spec to drive with; the dongle stays
        // on its own context and the panes fall back to `pairedProductID`.
        guard WacomDeviceRegistry.spec(for: pid) != nil else {
            source.pairedProductID = pid
            objectWillChange.send()
            return
        }
        let target = contexts[pid] ?? {
            let stub = DeviceContext(productID: pid)
            registerRestoredContext(stub)
            return stub
        }()
        prepareConnectingContext(target)

        source.removeDriverSlot(forRawProductID: rawPID)
        target.installDriver(driver, forRawProductID: rawPID)
        transport.home = target
        // Retarget on HIDThread, between reports, so none is split across
        // the two contexts.
        let handle = transport.handle
        HIDThread.shared.perform {
            handle.context = target
        }

        for (device, context) in hidDeviceMap
        where context === source && deviceRawProductID[device] == rawPID {
            hidDeviceMap[device] = target
            if let candidate = source.captureInterfaces.first(where: { $0.device === device }) {
                source.captureInterfaces.removeAll { $0 === candidate }
                target.captureInterfaces.append(candidate)
            }
            if source.hidDevice === device {
                source.hidDevice = nil
                source.firstDriverInterfaceClaimed = false
            }
            if !target.firstDriverInterfaceClaimed {
                target.firstDriverInterfaceClaimed = true
                target.hidDevice = device
            }
        }

        target.connectionErrorMessage = nil
        target.isConnected = true
        if target.activeDriverRawProductID == rawPID {
            target.transport = source.transport
            target.usbSpeed = source.usbSpeed
        }
        if target.batteryPercent == nil {
            target.batteryPercent = source.batteryPercent
            target.batteryCharging = source.batteryCharging
        }
        target.wirelessLinked = source.wirelessLinked
        if !target.hasWiredDriverLifecycle {
            target.observeRingLED()
            target.observeInjectionSnapshot()
            target.hasWiredDriverLifecycle = true
        } else if target.activeDriverRawProductID == rawPID {
            target.resyncActiveDriverDisplayState()
        }
        target.settings.applyExpressKeyDefaults(
            vendorID: target.vendorID,
            splitPad: WacomDeviceRegistry.spec(for: target.productID)?.hasSplitPadLayout == true)

        if activeContext == nil || activeContext === source {
            activeContext = target
            updateDockBadge()
        }
        if !source.hasAnyDriverSlot {
            markFullyDisconnected(source)
            if source.instanceKey == dongleKey {
                deviceContexts.removeValue(forKey: dongleKey)
            }
        }
        DeviceRegistry.shared.recordTablet(
            instanceKey: target.instanceKey, usbSerial: nil, vendorID: target.vendorID)
        logger.info("TabletManager: ACK-40401 now relaying for \(Self.deviceName(forProductID: pid), privacy: .public)")
        refreshConnectedIDs(mostRecent: pid)
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

    /// Whether any connected tablet has a pen in range.
    private func anyPenInProximity() -> Bool {
        deviceContexts.values.contains { $0.isConnected && $0.injector.proximityForMain }
    }

    /// Schedules assertion drop after `proximityIdleDelay` seconds, unless another
    /// connected device still has a pen in proximity.
    private func penExitedProximity() {
        guard !anyPenInProximity() else { return }
        proximityIdleTimer?.invalidate()
        proximityIdleTimer = Timer.scheduledTimer(
            withTimeInterval: Self.proximityIdleDelay, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.proximityIdleTimer = nil
                guard !self.anyPenInProximity(), let token = self.latencyActivityToken else { return }
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
                    case 0: return ("USB", String(localized: "Low Speed (1.5 Mb/s)", comment: "USB speed on the Info tab"))
                    case 1: return ("USB", String(localized: "Full Speed (12 Mb/s)", comment: "USB speed on the Info tab"))
                    case 2: return ("USB", String(localized: "High Speed (480 Mb/s)", comment: "USB speed on the Info tab"))
                    case 3: return ("USB", String(localized: "SuperSpeed (5 Gb/s)", comment: "USB speed on the Info tab"))
                    default: break
                    }
                }
            }
        }
        return ("USB", "USB")
    }

    /// One-shot per launch. CGEventPost silently drops events without the
    /// Accessibility grant, so the pen would move nothing with no explanation.
    ///
    /// Also read by the Info tab: the system alert appears only on an app's
    /// *first* ask and is silent forever after, so this doubles as "has the
    /// alert already had its one chance this launch" — see
    /// `requestAccessibility` there, which uses it to decide whether it still
    /// needs to open System Settings itself.
    private(set) var accessibilityPromptShown = false

    /// Show the Accessibility alert if it hasn't been shown yet this launch.
    /// Returns whether it was actually asked for — false means the caller is
    /// on its own for getting the user to the setting.
    @discardableResult
    func promptForAccessibilityIfNeeded() -> Bool {
        guard !accessibilityPromptShown, !AXIsProcessTrusted() else { return false }
        accessibilityPromptShown = true
        // The value of `kAXTrustedCheckOptionPrompt`, which Swift 6 treats as mutable global state.
        let opts: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        AXIsProcessTrustedWithOptions(opts)
        return true
    }

    private func updateDockBadge() {
        let anyLow = deviceContexts.values.contains {
            guard let pct = $0.batteryPercent else { return false }
            return pct < 20 && !$0.batteryCharging
        }
        NSApp.dockTile.badgeLabel = anyLow ? "!" : nil
    }
}

extension TabletSpec {
    /// Keys and a dial or ring, no pen: the Quick Keys puck and the
    /// ExpressKey Remote. Gets the Buttons, Devices and Info window.
    var isAuxOnly: Bool {
        maxX == 0 && (format == .xencelabs || format == .expressKeyRemote)
    }

    /// Each touch strip has its own mode toggle and its own modes, as on the
    /// Cintiq 21UX2 and 22HD. The toggles are buttons 16 and 17, so they
    /// arrive in bezel slots 0 and 1. The 21UX, 12WX, and 20WSX have none.
    var hasStripToggles: Bool { format == .cintiqV1 && hasTouchStrips && buttonCount > 16 }

    /// The bezel slot of the first bezel button: after the strip toggles,
    /// as on the Cintiq 22HD, whose panel keys take slots 2 to 4.
    var firstBezelButtonSlot: Int { hasStripToggles ? 2 : 0 }

    /// Two touch strips, each with its own modes, as two rings or dials have.
    var hasIndependentStrips: Bool { touchStripCount == 2 }
}

/// Accessories folded into a pen tablet's window while both are connected:
/// the vendor companions `VendorDeviceRegistry` knows (Quick Keys), plus the
/// ExpressKey Remote, which works with any Wacom pen tablet. With several,
/// the remote joins the tablet sharing its USB hub (the Cintiq 27QHD's
/// built-in receiver), else the lowest product ID so its home doesn't move.
@MainActor
enum DeviceCompanions {
    nonisolated static let expressKeyRemoteProductID = 0x0331

    static func connectedCompanion(forProductID productID: Int, connectedProductIDs: [Int]) -> Int? {
        if let vendor = VendorDeviceRegistry.connectedCompanion(
            forProductID: productID, connectedProductIDs: connectedProductIDs) {
            return vendor
        }
        guard connectedProductIDs.contains(expressKeyRemoteProductID),
              remoteOwner(connectedProductIDs) == productID
        else { return nil }
        return expressKeyRemoteProductID
    }

    static func isConnectedCompanion(productID: Int, connectedProductIDs: [Int]) -> Bool {
        connectedCompanionOwner(forProductID: productID, connectedProductIDs: connectedProductIDs) != nil
    }

    static func connectedCompanionOwner(forProductID productID: Int, connectedProductIDs: [Int]) -> Int? {
        if productID == expressKeyRemoteProductID {
            return remoteOwner(connectedProductIDs)
        }
        return VendorDeviceRegistry.connectedCompanionOwner(
            forProductID: productID, connectedProductIDs: connectedProductIDs)
    }

    private static func remoteOwner(_ connectedProductIDs: [Int]) -> Int? {
        let tablets = connectedProductIDs
            .filter { (WacomDeviceRegistry.spec(for: $0)?.maxX ?? 0) > 0 }
        let contexts = TabletManager.shared.contexts
        if let hub = contexts[expressKeyRemoteProductID].flatMap({ parentHub($0.locationID) }),
           let owner = tablets
               .filter({ contexts[$0].flatMap { parentHub($0.locationID) } == hub })
               .min()
        {
            return owner
        }
        return tablets.min()
    }

    /// The hub a USB location ID hangs off, or nil on a root port. Each
    /// nibble below the bus byte is one tier; the deepest nonzero one is the
    /// device's own port.
    nonisolated static func parentHub(_ locationID: Int) -> Int? {
        var shift = 0
        while shift < 24, (locationID >> shift) & 0xF == 0 { shift += 4 }
        guard shift < 20 else { return nil }
        return locationID & ~(0xF << shift)
    }
}

// MARK: - The session

extension TabletManager: TabletSessionDelegate {
    func session(_ session: TabletSession, didAttach transport: TabletTransport, to tablet: ConnectedTablet) {
        guard let device = (transport.primary as? IOKitHIDInterface)?.device else { return }
        let (context, probe, rawProductID, vendorID) = beginConnecting(device, joining: tabletContexts[tablet.id])
        tabletContexts[tablet.id] = context
        // The callbacks reach their context through this handle, so a
        // dongle's transport can move onto its tablet's context.
        let handle = DriverContextHandle(context)
        let callbacks = makeCallbacks(
            context: context, contextHandle: handle, device: device,
            productID: probe.productID, instanceKey: probe.instanceKey)
        let driver = SessionDriver(transport, callbacks: callbacks)
        sessionDrivers[transport.id] = driver
        transportHandles[transport.id] = handle
        transportProbes[transport.id] = probe
        logger.info("\(transport.spec.name, privacy: .public) connected")
        let delivers = transport.spec.format != .xencelabs || probe.usagePage == 0xFF0A
        installDriver(
            driver, device: device, context: context, contextHandle: handle, probe: probe,
            rawProductID: rawProductID, vendorID: vendorID, delivers: delivers)
    }

    func session(_ session: TabletSession, inputSinkFor transport: TabletTransport) -> any TabletInputSink {
        sessionDrivers[transport.id]?.handler ?? DiscardingSink()
    }

    func session(_ session: TabletSession, didAdd interface: any HIDInterface, to transport: TabletTransport) {
        guard let device = (interface as? IOKitHIDInterface)?.device,
            let context = self.context(of: transport),
            let handler = sessionDrivers[transport.id]?.handler
        else { return }
        HIDThread.shared.perform {
            LatencyProbe.shared.noteDeviceConnected()
            handler.siblingCount += 1
        }
        hidDeviceMap[device] = context
        deviceRawProductID[device] = transport.rawProductID
        // A touch sensor is the interface a touch problem needs in the file,
        // and an interface that arrives early is just as capturable as one
        // that arrives late.
        Self.offerForCapture(
            device, usagePage: interface.usagePage, on: context,
            delivers: transport.deliveringInterfaces.contains { $0 === interface })
        refreshConnectedIDs(mostRecent: nil)
    }

    func session(_ session: TabletSession, transportDidChangeState transport: TabletTransport) {
        guard case .faulted(let failure) = transport.state,
            let context = self.context(of: transport)
        else { return }
        let ret: IOReturn
        switch failure {
        case .permissionDenied: ret = kIOReturnNotPermitted
        case .openFailed(let code): ret = code
        }
        let hex = String(format: "0x%08x", ret)
        context.connectionErrorMessage = String(
            localized: "Couldn't open this device (\(hex)) — another tablet driver may already be using it.",
            comment: "Shown when IOHIDDeviceOpen fails, with the IOReturn code substituted")
    }

    func session(_ session: TabletSession, transport: TabletTransport, didReadSerial serial: UInt32) {
        guard let probe = transportProbes[transport.id] else { return }
        DeviceRegistry.shared.recordHardwareSerial(serial, forDevice: probe.productID)
    }

    func session(_ session: TabletSession, transport: TabletTransport, didPairWith productID: Int) {
        sessionDrivers[transport.id]?.pairedTabletChanged()
        guard let probe = transportProbes[transport.id] else { return }
        rehomeDongleTransport(dongleKey: probe.instanceKey, pairedProductID: productID)
    }

    func session(
        _ session: TabletSession, didRegroup transport: TabletTransport, from old: ConnectedTablet, to new: ConnectedTablet
    ) {
        if tabletContexts[new.id] == nil { tabletContexts[new.id] = self.context(of: transport) }
        if old.transports.isEmpty { tabletContexts.removeValue(forKey: old.id) }
    }

    func session(_ session: TabletSession, didDetach transport: TabletTransport, from tablet: ConnectedTablet) {
        let context = self.context(of: transport)
        transportHandles.removeValue(forKey: transport.id)
        sessionDrivers.removeValue(forKey: transport.id)
        transportProbes.removeValue(forKey: transport.id)
        if tablet.transports.isEmpty { tabletContexts.removeValue(forKey: tablet.id) }
        guard let context else { return }
        let rawPID = transport.rawProductID
        for (device, owner) in hidDeviceMap where owner === context && deviceRawProductID[device] == rawPID {
            forgetInterface(device, of: context)
        }
        releaseSlot(rawPID, of: context)
    }

    /// The context a transport delivers into, as main sees it. A dongle's
    /// handle is retargeted on HIDThread, so its main-actor view is `home`.
    private func context(of transport: TabletTransport) -> DeviceContext? {
        if let key = transportProbes[transport.id]?.instanceKey, let dongle = dongleTransports[key] {
            return dongle.home
        }
        return transportHandles[transport.id]?.context
    }

    nonisolated func transport(_ id: TabletTransport.ID, didRun step: ConnectStep) {
        // Recorded whether or not a capture is running: this happens at open,
        // long before one starts, and a device left in a reduced mode
        // otherwise yields a capture that looks healthy.
        switch step {
        case .wrote(let reportID, let value, let result, let usagePage):
            CaptureEngine.recordAutoInitReport(
                reportID: reportID, value: value, ioReturn: result, usagePage: usagePage)
        case .read(let purpose, let reportID, let result, let reply, let usagePage):
            CaptureEngine.recordAutoInitRead(
                purpose: purpose, reportID: reportID, ioReturn: result, reply: reply, usagePage: usagePage)
        case .inputMode:
            break
        }
    }
}

/// A sink for a transport the app lost track of.
private final class DiscardingSink: TabletInputSink {
    func didDecode(_ events: [TabletEvent], from report: HIDReport, on interface: any HIDInterface, at receivedNs: UInt64) {}
}

/// The context a driver's HIDThread callbacks deliver into. Retargeted only
/// on HIDThread, the same thread that reads it, so a report is never decoded
/// into one context and delivered to another.
final class DriverContextHandle: @unchecked Sendable {  // HIDThread-confined after init
    weak var context: DeviceContext?

    init(_ context: DeviceContext) {
        self.context = context
    }
}

/// Where an ACK-40401 dongle's transport currently lives. `home` is the
/// main-actor view of the context `handle` points the callbacks at.
private final class DongleTransport {
    let handle: DriverContextHandle
    weak var home: DeviceContext?

    init(handle: DriverContextHandle, home: DeviceContext) {
        self.handle = handle
        self.home = home
    }
}
