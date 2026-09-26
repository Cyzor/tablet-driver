// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid
import OSLog
@_spi(TabletKitInternals) import TabletKit

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "capture")


/// One diagnostic collection run, owning both collectors for its lifetime.
///
/// `CaptureEngine` is per-window state; `HIDCapture` is a process-wide
/// singleton. Without a shared owner a second window's run would reset the
/// first's buffer mid-recording. Routing every start/stop through here gives
/// the singleton exactly one owner, and makes both collectors describe the
/// same span of time.
@MainActor
final class DiagnosticSession {

    /// The session currently owning `HIDCapture.shared`, if any. Weak so a
    /// window closing mid-run doesn't strand ownership forever.
    private static weak var rawCaptureOwner: DiagnosticSession?

    /// Whether some *other* session holds the raw-capture singleton — the
    /// signal for a second window to disable its own start control rather
    /// than silently truncating the first window's recording.
    static func rawCaptureHeldByOther(than session: DiagnosticSession?) -> Bool {
        guard let owner = rawCaptureOwner else { return false }
        return owner !== session
    }

    /// True once this session has claimed the singleton, so teardown only
    /// releases what it actually took.
    private(set) var ownsRawCapture = false

    init() {}

    // MARK: - Collection scope

    /// Every attached interface from a vendor we know
    /// (`TabletManager.knownVendorIDs`), not just the open window's tablet.
    ///
    /// A Cintiq 27QHD Touch is three USB devices (pen 0x032B, touch 0x032C,
    /// EKR-100 receiver 0x0331) — one physical desk that used to need three
    /// sessions and three files, and silence on one device only means
    /// something next to the others.
    ///
    /// Vendor-gated, not usage-gated: a usage net drags in keyboards while
    /// still missing accessories like the EKR receiver, which declares a
    /// vendor-defined page. Unknown vendors fall back to
    /// `CaptureGuideView.captureInterfaces()`.
    static func knownVendorDevices() -> [IOHIDDevice] {
        guard
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
                as IOHIDManager?
        else { return [] }
        let matching = TabletManager.knownVendorIDs.map {
            [kIOHIDVendorIDKey: $0 as NSNumber]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        // Vendor gating already keeps ordinary keyboards out, but a tablet
        // vendor's own keyboard accessory would pass it. A keyboard's input
        // reports are keystrokes and must never land in a file bound for a
        // public issue, so the check is by top-level usage here too.
        return devices.filter { device in
            let page = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int
            let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int
            let keep: Bool
            if page == kHIDPage_Consumer {
                keep = false
            } else if page == kHIDPage_GenericDesktop, let usage {
                keep = usage != kHIDUsage_GD_Keyboard && usage != kHIDUsage_GD_Keypad
            } else {
                keep = true
            }
            // Vendor matching already ran, so everything dropped here belongs
            // to a tablet vendor — see `CaptureEngine.recordExcludedDevice`.
            if !keep, let page,
               let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int {
                CaptureEngine.recordExcludedDevice(
                    vendorID: vendor,
                    productID: IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0,
                    usagePage: page,
                    usage: usage)
            }
            return keep
        }
    }

    /// Stable per-interface identity that survives re-enumeration.
    ///
    /// `IOHIDManagerCopyDevices` hands back a fresh CF wrapper each call, so
    /// `===` never matches across enumerations; `locationID` is shared by
    /// every interface of one device. The registry entry ID is neither.
    /// Nil once the device is gone.
    static func registryID(of device: IOHIDDevice) -> UInt64? {
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return nil }
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { return nil }
        return id
    }

    // MARK: - Lifecycle

    /// Claim `HIDCapture.shared`, if free. False when another session holds
    /// it — starting anyway would reset its buffer and repoint its file.
    @discardableResult
    func startRawCapture() -> Bool {
        guard Self.rawCaptureOwner == nil else {
            logger.info("raw capture already owned by another session — not starting")
            return false
        }
        Self.rawCaptureOwner = self
        ownsRawCapture = true
        HIDCapture.shared.start()
        return true
    }

    /// Stop and flush, returning the file. Safe on a session that never
    /// claimed the singleton — teardown paths run unconditionally.
    @discardableResult
    func finishRawCapture() -> URL? {
        guard ownsRawCapture else { return nil }
        HIDCapture.shared.stop()
        let url = HIDCapture.shared.finish()
        releaseRawCapture()
        return url
    }

    /// Drop ownership without keeping the recording — the cancel path.
    func cancelRawCapture() {
        guard ownsRawCapture else { return }
        HIDCapture.shared.stop()
        HIDCapture.shared.clear()
        releaseRawCapture()
    }

    private func releaseRawCapture() {
        ownsRawCapture = false
        if Self.rawCaptureOwner === self { Self.rawCaptureOwner = nil }
    }

    deinit {
        // A window closed mid-run must not strand the claim. `deinit` can't
        // hop actors, so this only clears the static; the capture auto-stops
        // on its own ceiling.
        MainActor.assumeIsolated {
            if Self.rawCaptureOwner === self { Self.rawCaptureOwner = nil }
        }
    }
}
