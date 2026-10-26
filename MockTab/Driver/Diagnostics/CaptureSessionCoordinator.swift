// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import IOKit.hid
import TabletKit

/// The device side of a Collect Device Data session: which interfaces to
/// record, what they are, the settings that go in the file, and the
/// mode-switch write. `CaptureGuideView` keeps only presentation state.
@MainActor
final class CaptureSessionCoordinator: ObservableObject {

    let engine: CaptureEngine
    let tabletManager: TabletManager
    let productID: Int
    /// Stop and flush the paired raw capture, returning its file so it can go
    /// into the package. Nil when no raw capture is running.
    private let onFinalizeRawCapture: (() -> URL?)?

    /// Set when the session can't start at all (no device, or a device that
    /// won't tell us what it is). Distinct from `engine.lastError`, which
    /// covers failures after collection has begun.
    @Published private(set) var startupError: String? = nil
    /// The device identity actually written into the capture file, kept so the
    /// issue-submission text describes the same hardware.
    @Published private(set) var resolvedInfo: CaptureDeviceInfo? = nil
    /// The finished package, or the loose summary when packaging failed.
    @Published private(set) var savedURL: URL? = nil
    /// Set when the device's own descriptor names a feature report carrying a
    /// mode-switch usage — see `DescriptorLayout.modeSwitchUsages` in TabletKit
    /// — in which case the report ID is correct rather than a guess.
    @Published private(set) var autoDetectedModeReportID: UInt8? = nil
    /// The interface whose descriptor declared `autoDetectedModeReportID`, so
    /// the Send button writes to that one rather than to the primary.
    ///
    /// These differ on exactly the hardware the control exists for: a
    /// multitouch interface carries the standard Device Mode usage while the
    /// pen interface carries Wacom's vendor DATAMODE, and a mode-switch write
    /// addressed to the wrong sibling is simply NAK'd — indistinguishable, to
    /// the tester, from the device not supporting the report at all.
    private var modeSwitchDevice: IOHIDDevice? = nil
    /// Periodic whole-desk rescan, live only while collecting.
    private var companionScanTimer: Timer? = nil

    init(
        engine: CaptureEngine, tabletManager: TabletManager, productID: Int,
        onFinalizeRawCapture: (() -> URL?)?
    ) {
        self.engine = engine
        self.tabletManager = tabletManager
        self.productID = productID
        self.onFinalizeRawCapture = onFinalizeRawCapture
    }

    /// Stops the background rescan. Called when the sheet goes away.
    func stop() {
        companionScanTimer?.invalidate()
        companionScanTimer = nil
    }

    /// Writes a device-mode feature report to the interface whose descriptor
    /// declared it when one did. Otherwise to the primary, which is the right
    /// target for the hand-entered legacy 0x02 case this control started as.
    func sendModeSwitch(reportID: Int, value: Int) {
        guard let dev = modeSwitchDevice ?? tabletManager.contexts[productID]?.hidDevice else { return }
        engine.sendInitReport(device: dev, reportID: reportID, value: value)
    }

    /// `deviceInfo()` (and therefore collection) needs a currently-connected
    /// `IOHIDDevice` for `productID`. Distinguishing "no such device" from the
    /// ordinary brief startup lag matters: without it, a device that dropped
    /// its connection — or was never found under this productID — reads
    /// identically to "still starting", and stays that way forever with no
    /// way to tell why.
    var deviceIsConnected: Bool {
        tabletManager.contexts[productID]?.hidDevice != nil
    }

    // MARK: - Interfaces

    /// Every interface of this tablet worth listening to, primary first.
    ///
    /// The session records all of them at once rather than asking which one to
    /// use. A tablet whose pen and touch data arrive on separate HID
    /// interfaces (PTH-850 — see `DeviceContext.hidDevice`'s doc comment)
    /// otherwise yields a file covering half the hardware, and *which* half is
    /// enumeration-order luck. Nobody submitting a capture for an unrecognized
    /// device can be expected to know which interface carries the traffic
    /// worth having — that judgment is the whole point of reading the file
    /// afterward, so it can't be a precondition for producing one.
    ///
    /// `hidDevice` leads when it's among the listed interfaces: it's the one
    /// the driver reads pen reports from, so its data is what fills the
    /// top-level block of the capture file that existing triage tooling reads.
    ///
    /// It is *not* promoted when it was left off that list. `hidDevice` is
    /// claimed by the first `.driver`-routed interface whether or not the
    /// driver installed a report callback on it, while `captureInterfaces`
    /// deliberately omits interfaces that got none (see
    /// `TabletManager.offerForCapture`). Leading with one of those would put
    /// a permanently empty block at the top level of the file — which is
    /// exactly the block a `captureVersion` 6 reader treats as the whole
    /// capture — while the real traffic sat in a section it doesn't read.
    ///
    /// The bare `hidDevice` fallback remains for a device whose interfaces
    /// never got listed at all.
    /// Just this tablet's own interfaces — the ones a driver already reads
    /// and forwards to `recordRaw`. Separated from `captureInterfaces()` so
    /// the caller can tell them from devices swept up for breadth, which
    /// need their own listener.
    private func ownCaptureInterfaces() -> [IOHIDDevice] {
        let context = tabletManager.contexts[productID]
        let listed = (context?.captureInterfaces ?? []).compactMap(\.device)
        if !listed.isEmpty {
            guard let primary = context?.hidDevice, listed.contains(where: { $0 === primary })
            else { return listed }
            return [primary] + listed.filter { $0 !== primary }
        }
        if let hidDevice = context?.hidDevice { return [hidDevice] }
        return []
    }

    private func captureInterfaces() -> [IOHIDDevice] {
        let own = ownCaptureInterfaces()
        if !own.isEmpty {
            return own + companionDevices(excluding: own)
        }
        // No known device at all — rather than error out, profile every HID
        // device on the bus instead. TabletManager's own `IOHIDManager` only
        // matches vendors we already know, so it can't answer "is the tablet
        // even visible to the OS." If nothing shows up here either, that's
        // itself the diagnosis (unpowered hub, cable fault, wrong port).
        // Likeliest tablet first, since the first device names the hardware
        // in the file and the issue text; IOKit's set has no order.
        return Self.allConnectedHIDDevices()
            .map { ($0, DiagnosticSession.tabletLikeness(of: $0), DiagnosticSession.registryID(of: $0) ?? .max) }
            .sorted { (-$0.1, $0.2) < (-$1.1, $1.2) }
            .map(\.0)
    }

    /// Every other known-vendor device, so one run covers the whole desk.
    ///
    /// Appended *after* the target's own interfaces: the first entry names the
    /// hardware in the header and fills the top-level block triage tooling
    /// reads, so the opened window stays primary.
    private func companionDevices(excluding claimed: [IOHIDDevice]) -> [IOHIDDevice] {
        // Compared by registry ID rather than `===`: `claimed` holds the
        // driver's long-lived device objects while the enumeration returns
        // fresh CF wrappers for the same hardware, so identity never matches
        // and every already-recorded interface would be added a second time.
        let claimedIDs = Set(claimed.compactMap(DiagnosticSession.registryID(of:)))
        return DiagnosticSession.knownVendorDevices().filter { candidate in
            guard let id = DiagnosticSession.registryID(of: candidate) else { return true }
            return !claimedIDs.contains(id)
        }
    }

    /// One-shot, unfiltered enumeration of every HID device IOKit currently
    /// sees — independent of `TabletManager`'s vendor-matched manager, which
    /// would omit exactly the unrecognized hardware this exists to surface.
    private static func allConnectedHIDDevices() -> [IOHIDDevice] {
        guard let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            as IOHIDManager?
        else { return [] }
        IOHIDManagerSetDeviceMatching(manager, nil)
        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return deviceSet.filter { !isTextEntryDevice($0) }
    }

    /// True for devices whose input reports can carry what the user is typing.
    ///
    /// This sweep is otherwise indiscriminate by design, but a keyboard's
    /// reports *are* keystrokes and must never reach a file bound for a public
    /// issue — a session opened on an Apple sensor hub fell through here and
    /// recorded 14 of them. Matched by top-level usage, never by name.
    ///
    /// Mice are **not** excluded: a DTK-2400 and a PTH-860's pen interface
    /// both declare Generic Desktop/Mouse, and excluding it dropped a real
    /// tablet and its 1,500 samples.
    private static func isTextEntryDevice(_ device: IOHIDDevice) -> Bool {
        let page = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int
        let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int
        guard let page else { return false }
        let excluded: Bool
        if page == kHIDPage_Consumer {
            excluded = true
        } else if page == kHIDPage_GenericDesktop, let usage {
            excluded = usage == kHIDUsage_GD_Keyboard || usage == kHIDUsage_GD_Keypad
        } else {
            excluded = false
        }
        // A tablet vendor's accessory dropped here is silent otherwise —
        // see `CaptureEngine.recordExcludedDevice`.
        if excluded, let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int {
            CaptureEngine.recordExcludedDevice(
                vendorID: vendor,
                productID: IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0,
                usagePage: page,
                usage: usage)
        }
        return excluded
    }

    /// This tablet's touch configuration, for the capture file.
    ///
    /// Nil for a device whose spec declares no finger touch: these settings
    /// exist on every `TabletSettings` but do nothing without a touch sensor,
    /// and recording them there would invite reading a meaningless `false` as
    /// a cause.
    /// Mapping and pen-feel settings for the capture file. Unconditional,
    /// unlike `touchSettingsSnapshot()` — gating these the same way left
    /// non-Wacom captures with no app-side configuration at all.
    private func appSettingsSnapshot(_ source: DeviceContext?) -> CaptureAppSettings? {
        guard let s = source?.settings else { return nil }
        return CaptureAppSettings(
            activeAreaX: s.activeAreaX,
            activeAreaY: s.activeAreaY,
            activeAreaWidth: s.activeAreaWidth,
            activeAreaHeight: s.activeAreaHeight,
            proportionalMapping: s.proportionalMapping,
            tabletOrientationRawValue: s.tabletOrientation.rawValue,
            targetDisplayIndex: s.targetDisplayIndex,
            displayRegionX: s.displayRegionX,
            displayRegionY: s.displayRegionY,
            displayRegionWidth: s.displayRegionWidth,
            displayRegionHeight: s.displayRegionHeight,
            hasCalibration: !s.calibrationEntries.isEmpty,
            // Omitted when linear, so its presence in a file always means
            // the curve is a candidate cause.
            pressureCurve: s.pressureCurve == .linear
                ? nil
                : String(
                    format: "%.3f,%.3f %.3f,%.3f",
                    s.pressureCurve.p1.x, s.pressureCurve.p1.y,
                    s.pressureCurve.p2.x, s.pressureCurve.p2.y),
            smoothingStrength: s.smoothingStrength,
            pressureSmoothingStrength: s.pressureSmoothingStrength,
            dragThreshold: s.dragThreshold,
            tipUpAssistDelay: s.tipUpAssistDelay,
            requireContact: s.requireContact.kindNames,
            doubleClickDistance: s.doubleClickDistance,
            relativeCursorMovement: s.relativeCursorMovement,
            invertRotation: s.invertRotation,
            penBindings: [
                "tip": s.activeTool.tipBinding.kind.rawValue,
                "eraser": s.activeTool.eraserBinding.kind.rawValue,
                "button1": s.activeTool.penButton1Binding.kind.rawValue,
                "button2": s.activeTool.penButton2Binding.kind.rawValue,
                "button3": s.activeTool.penButton3Binding.kind.rawValue,
            ])
    }

    /// Every tool the registry has ever recorded for this tablet, newest
    /// naming first. Nil rather than an empty array when the registry has no
    /// entry for the device at all — "never asked" and "asked, none" are
    /// different answers and the file should not blur them.
    /// The tablet whose settings belong in the file: the one recorded, not
    /// necessarily the one whose window opened this sheet. A window whose
    /// tablet isn't connected sweeps the bus, and its own settings would
    /// then be filed under whatever tablet the sweep found.
    private func settingsSource(
        recording primary: IOHIDDevice, ownInterfaces: [IOHIDDevice]
    ) -> DeviceContext? {
        if !ownInterfaces.isEmpty { return tabletManager.contexts[productID] }
        guard let id = DiagnosticSession.registryID(of: primary) else { return nil }
        return tabletManager.deviceContexts.values.first { context in
            let devices = context.captureInterfaces.compactMap(\.device) + [context.hidDevice].compactMap { $0 }
            return devices.contains { DiagnosticSession.registryID(of: $0) == id }
        }
    }

    private func knownTabletsSnapshot() -> [CaptureKnownTablet]? {
        let tablets = DeviceRegistry.shared.knownTablets
        guard !tablets.isEmpty else { return nil }
        return tablets.map { row in
            CaptureKnownTablet(
                productID: String(format: "0x%04X", row.productID),
                model: row.modelName,
                connected: tabletManager.context(for: row)?.isConnected == true,
                isWindowTablet: row.productID == productID)
        }
    }

    private func everSeenToolsSnapshot(_ source: DeviceContext?) -> [String]? {
        let registry = DeviceRegistry.shared
        guard let source,
            registry.knownTablets.contains(where: { $0.productID == source.productID })
        else { return nil }
        return registry.allKnownTools.map { tool in
            let kind = tool.kind.isEmpty ? tool.nickname : tool.kind
            // Stand-in, matching the raw log; captures go to public issues.
            if let serial = tool.serial, serial != 0 {
                let shown = CaptureSerialRedaction.standIn(forPenSerial: serial)
                return "\(kind) (0x\(String(format: "%08X", shown)))"
            }
            return "\(kind) (\(tool.displayID))"
        }
    }

    private func settingsIdentitySnapshot(_ source: DeviceContext?) -> CaptureSettingsIdentity? {
        guard let context = source else { return nil }
        let registry = DeviceRegistry.shared
        let prefix = context.settings.devicePrefix
        let key = registry.normalizedKey(context.instanceKey)
        let row = registry.knownTablets.first { $0.instanceKey == key }
        return CaptureSettingsIdentity(
            usbSerialReported: row.map { !($0.usbSerial ?? "").isEmpty },
            sharedNamespace: !prefix.contains("#"),
            knownUnitsOfModel: registry.knownTablets.filter { $0.productID == context.productID }.count,
            storedSettingCount: UserDefaults.standard.dictionaryRepresentation().keys
                .filter { $0.hasPrefix(prefix) }.count,
            windowProductID: context.productID == productID || productID == 0
                ? nil : String(format: "0x%04X", productID))
    }

    private func appEnvironmentSnapshot() -> CaptureAppEnvironment {
        let path = Bundle.main.bundlePath
        let location =
            path.contains("/AppTranslocation/") ? "translocated"
            : (path.hasPrefix("/Applications/") ? "applications" : "other")
        let running = NSWorkspace.shared.runningApplications
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let otherCopies = running.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != ownPID
        }.count
        let names = Set(running.compactMap(\.localizedName) + running.compactMap(\.bundleIdentifier))
        return CaptureAppEnvironment(
            accessibilityGranted: AXIsProcessTrusted(),
            inputMonitoringGranted:
                IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
            installLocation: location,
            otherMockTabCopies: otherCopies,
            competingDrivers: ConflictProcessMatcher.matchedLabels(liveNames: names))
    }

    private func touchSettingsSnapshot(_ source: DeviceContext?) -> CaptureTouchSettings? {
        guard let source else { return nil }
        let settings = source.settings
        // Omitted only when a spec positively says the device has no finger
        // touch — there the settings are inert and a `false` would read as a
        // cause. A device with *no* spec is a different case: we can't rule
        // touch out, and dropping the block left every non-Wacom capture with
        // no touch configuration at all (an Xencelabs session recorded none,
        // which is how this was found).
        if let spec = WacomDeviceRegistry.spec(for: source.productID), !spec.hasFingerTouch {
            return nil
        }
        return CaptureTouchSettings(
            touchEnabled: settings.touchEnabled,
            tapToClick: settings.tapToClick,
            twoFingerScroll: settings.twoFingerScroll,
            pinchZoom: settings.pinchZoomEnabled,
            twoFingerScrollMomentum: settings.twoFingerScrollMomentum,
            reverseScrollDirection: settings.reverseScrollDirection,
            rotateEnabled: settings.rotateEnabled,
            twoFingerRightClick: settings.twoFingerRightClick,
            threeFingerDrag: settings.threeFingerDrag,
            touchOnsetDelayMs: settings.touchOnsetDelayMs,
            sensitivity: settings.touchSensitivity,
            areaX: settings.touchAreaX,
            areaY: settings.touchAreaY,
            areaWidth: settings.touchAreaWidth,
            areaHeight: settings.touchAreaHeight,
            tabletOrientationRawValue: settings.tabletOrientation.rawValue)
    }

    /// Change notifications from this tablet's `DeviceContext`, or a publisher
    /// that never fires when there's no context to watch.
    var contextChanges: ObservableObjectPublisher {
        tabletManager.contexts[productID]?.objectWillChange ?? Self.silentChanges
    }

    private static let silentChanges = ObservableObjectPublisher()

    /// Fold any interface that has attached since collection started into the
    /// running session, keeping what's already been gathered.
    ///
    /// Reads only this context's already-cached interface list. It must stay
    /// that cheap: `DeviceContext` publishes on routine pen traffic
    /// (`activeToolSerial`, `liveButtons`, battery), so this runs repeatedly
    /// while the user is drawing. The whole-desk enumeration in
    /// `companionDevices` is deliberately *not* here — it creates an
    /// `IOHIDManager` and copies the device set, which has no business
    /// running on the main actor mid-stroke. Companions are picked up once at
    /// session start, and by `adoptNewCompanions()` on its own slow timer.
    func adoptNewInterfaces() {
        guard engine.isRunning else { return }
        let context = tabletManager.contexts[productID]
        let listed = (context?.captureInterfaces ?? []).compactMap(\.device)
        for device in listed where !engine.isRecording(device) {
            guard let info = deviceInfo(device: device) else { continue }
            engine.addInterface(device: device, deviceInfo: info)
        }
    }

    /// Fold in hardware connected mid-run. Separate from
    /// `adoptNewInterfaces` and on a slow timer: this pays for a full IOKit
    /// enumeration.
    private func adoptNewCompanions() {
        guard engine.isRunning else { return }
        for device in DiagnosticSession.knownVendorDevices() where !engine.isRecording(device) {
            guard let info = deviceInfo(device: device) else { continue }
            // Tapped: nothing else is listening to these. Unlike this
            // tablet's own interfaces, which a driver already reads and
            // forwards, a device picked up purely for breadth has no driver
            // behind it — see `CaptureEngine.openPassiveTap`.
            engine.addInterface(device: device, deviceInfo: info, tapped: true)
        }
    }

    // MARK: - Collection logic

    /// Starts collecting. Returns false, with `startupError` set, when there's
    /// nothing to record.
    @discardableResult
    func start() -> Bool {
        // Each interface is described from its own `IOHIDDevice`: the usage
        // page and the report descriptor differ between them, and those are
        // exactly what the capture file needs in order to say which interface
        // a report came from and whether that interface declared it.
        let interfaces = captureInterfaces()
        guard !interfaces.isEmpty else {
            // captureInterfaces() already falls back to every HID device on
            // the bus when nothing is known — reaching here with productID
            // != 0 means the previously-known device disappeared; with
            // productID == 0 it means IOKit reports no HID devices at all,
            // which is itself useful evidence.
            startupError =
                productID != 0
                ? String(
                    localized: "That tablet isn't connected anymore.",
                    comment: "Capture error shown when the target device disappeared before collection started")
                : String(
                    localized: "No HID devices are visible to macOS at all right now.",
                    comment: "Capture error shown when no tablet is known and no HID device of any kind is found on the system")
            return false
        }
        let targets = interfaces.compactMap { device in
            deviceInfo(device: device).map { (device, $0) }
        }
        // Only the failure to describe *any* interface stops collection. A
        // sibling that won't name itself is dropped quietly: the tablet is
        // still fully capturable through the interfaces that will, and its
        // absence from the file is visible there.
        guard let primary = targets.first else {
            startupError = String(
                localized: "This tablet doesn't report a usable USB ID, so a recording from it couldn't identify it.",
                comment: "Capture error shown when the device's USB identifiers are missing or zero")
            return false
        }
        resolvedInfo = primary.1
        // Cleared first: a device that reconnected without the interface that
        // declared the report must not leave the previous one's ID pre-filled.
        startupError = nil
        applyAutoDetectedModeSwitch(from: targets)

        engine.onCaptureComplete = { [weak self] result in
            Task { @MainActor in
                guard let self,
                    let summaryURL = self.engine.exportCaptureJSON(result: result)
                else { return }
                // Finalized here rather than on dismiss: the summary is
                // written when the user clicks Done, while this sheet is
                // still up, so packaging at dismiss time would zip a log
                // that hadn't been flushed yet.
                let rawLogURL = self.onFinalizeRawCapture?()
                let productID = result.deviceInfo.productID
                // Off main: packaging copies files and waits for ditto.
                let packaged = await Task.detached(priority: .utility) {
                    let packaged = DiagnosticPackage.build(
                        summaryURL: summaryURL, rawLogURL: rawLogURL, productID: productID)
                    if packaged != nil {
                        // Only once the archive holds them.
                        try? FileManager.default.removeItem(at: summaryURL)
                        if let rawLogURL { try? FileManager.default.removeItem(at: rawLogURL) }
                    }
                    return packaged
                }.value
                // Falls back to the loose summary when packaging fails, so a
                // zip problem can never cost the user their capture.
                self.savedURL = packaged ?? summaryURL
            }
        }
        // Everything past this tablet's own interfaces was swept up for
        // breadth and has no driver reading it.
        let ownInterfaces = ownCaptureInterfaces()
        let companions = targets.map(\.0).filter { candidate in
            !ownInterfaces.contains { $0 === candidate }
        }
        let source = settingsSource(recording: primary.0, ownInterfaces: ownInterfaces)
        engine.startCapture(
            devices: targets, duration: HIDCapture.maxCaptureDuration, touchSettings: touchSettingsSnapshot(source),
            appSettings: appSettingsSnapshot(source),
            everSeenTools: everSeenToolsSnapshot(source),
            settingsIdentity: settingsIdentitySnapshot(source),
            knownTablets: knownTabletsSnapshot(),
            appEnvironment: appEnvironmentSnapshot(),
            bluetoothAddressCandidate: source?.bluetoothAddressCandidate,
            tapped: companions)

        // Picks up hardware powered on or plugged in mid-session. Slow on
        // purpose — `adoptNewCompanions` pays for an IOKit enumeration, and a
        // few seconds' delay adopting a device the user just connected costs
        // nothing, since they still have to pick it up and use it.
        companionScanTimer?.invalidate()
        companionScanTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.adoptNewCompanions() }
        }
        return true
    }

    /// Parses the device's own raw descriptor bytes for a mode-switch feature
    /// report. The view pre-fills its report field from
    /// `autoDetectedModeReportID`, replacing the 0x02 legacy guess with the
    /// ID this specific device actually uses.
    ///
    /// The usage list lives in TabletKit beside the lookup
    /// (`DescriptorLayout.modeSwitchUsages`) because TabletKit's guess for an
    /// unknown Wacom consults the same one for its init. A
    /// second copy here would let the tester's pre-filled value and the
    /// driver's actual write drift apart, which is the one discrepancy this
    /// screen must never introduce.
    ///
    /// Runs once, before the tester can have typed anything.
    ///
    /// Not only modern hardware: the PTK-870's 1324-byte USB descriptor
    /// declares `WACOM_HID_WD_DATAMODE` at feature report `0x02`, so this does
    /// fire on classic Wacom tablets. (An earlier note here claimed no tested
    /// Wacom or Xencelabs descriptor declared either usage.)
    private func applyAutoDetectedModeSwitch(from targets: [(IOHIDDevice, CaptureDeviceInfo)]) {
        for (device, info) in targets {
            guard let hex = info.parsedDescriptor?.rawHex,
                  let layout = try? HIDReportDescriptorParser.parse(hex: hex),
                  let reportID = layout.modeSwitchFeatureReportID()
            else { continue }

            autoDetectedModeReportID = reportID
            modeSwitchDevice = device
            return
        }
    }

    /// Wacom's USB vendor ID. Only devices reporting it may be described using
    /// the Wacom device registry.
    static let wacomVendorID = 0x056A

    /// Build the capture header from the **device itself**, not from what the
    /// app guessed about it: both IDs come off the `IOHIDDevice`, and the
    /// Wacom registry is consulted only once the vendor ID says Wacom. A
    /// header whose job is to say what the hardware is mustn't fall back to
    /// a guess.
    ///
    /// Free of side effects: it runs once per interface, and a sibling that
    /// can't name itself is left out rather than failing the session. The
    /// caller decides; `startCollection` raises the error only when *no*
    /// interface could be described.
    private func deviceInfo(device dev: IOHIDDevice) -> CaptureDeviceInfo? {
        let vendorID = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int
        let deviceProductID = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int

        // A capture whose header can't name the hardware can't become a
        // registry entry — TabletKit/tools/triage_discovery.py rejects exactly this.
        // Better to say so now than after an hour of collecting.
        guard let vendorID, let deviceProductID, deviceProductID != 0 else { return nil }

        let manufacturer = IOHIDDeviceGetProperty(dev, kIOHIDManufacturerKey as CFString) as? String
        let transport    = IOHIDDeviceGetProperty(dev, kIOHIDTransportKey    as CFString) as? String
        // Device serial is deliberately not read: capture files are pasted into
        // public issues, and the serial adds nothing to decoding.
        let productString = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String
        let locationID   = (IOHIDDeviceGetProperty(dev, kIOHIDLocationIDKey  as CFString) as? Int)
            .map { String(format: "0x%08X", $0) }
        let parsed = LiveHIDDescriptorInspector.read(dev)

        let registryName =
            vendorID == Self.wacomVendorID
            ? WacomDeviceRegistry.spec(for: deviceProductID)?.name : nil
        let name =
            registryName
            ?? TabletManager.deviceName(
                forProductID: deviceProductID, vendorID: vendorID, productString: productString)

        return CaptureDeviceInfo(
            vendorID: vendorID,
            productID: deviceProductID,
            name: name,
            locationID: locationID,
            manufacturer: manufacturer,
            transport: transport,
            parsedDescriptor: parsed,
            usagePage: hidIntProperty(dev, kIOHIDPrimaryUsagePageKey),
            usage: hidIntProperty(dev, kIOHIDPrimaryUsageKey)
        )
    }
}
