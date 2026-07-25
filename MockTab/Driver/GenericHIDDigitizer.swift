// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid
import OSLog
import TabletKit

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "driver")

/// Vendor-agnostic "universal floor" driver for any standards-compliant HID pen
/// digitizer (top-level usage Digitizer/Pen, `0x0D`/`0x02`).
///
/// Unlike `WacomKnownDevice` and `WacomFallbackDevice`, this reads no
/// vendor-specific report layout. It uses **element value callbacks**
/// (`IOHIDDeviceRegisterInputValueCallback`): the OS HID parser hands back each
/// field already decoded and keyed by (usagePage, usage), so there are no bit
/// offsets to compute. We filter for the standard digitizer usages and emit a
/// `TabletPoint` — the same contract every other driver produces, so
/// `InputInjector` consumes it unchanged.
///
/// Provides: absolute X/Y cursor tracking, tip→click, and (when the descriptor
/// exposes them) tip pressure, barrel buttons, eraser, and tilt. Anything the
/// descriptor doesn't describe simply does nothing.
///
/// Does NOT provide: express keys, touch ring/strip, rotation, vendor mode
/// switching, or device seizure. Those need a dedicated `*Device.swift` or a
/// vendor handshake. This is the rudimentary-usability tier, not full fidelity.
final class GenericHIDDigitizer: TabletDevice {

    let spec: DigitizerSpec

    /// Brand/category guessed from the USB manufacturer/product strings when
    /// the VID/PID didn't match any registry entry — nil when nothing in
    /// those strings hints at a tablet. Drives the "looks like a Huion
    /// device" wording on the unrecognised-device banner.
    let detectedBrand: String?

    private let device: IOHIDDevice
    private let onTablet: (TabletPoint) -> Void
    private let tag: String

    /// Pure decode state — maps standard HID usages to `TabletPoint`. Lives in
    /// TabletKit so it is unit-testable without IOKit; this class only does the
    /// IOKit plumbing (open, value callbacks) and forwards element values to it.
    private var frame: GenericDigitizerFrame

    // MARK: - Init

    init(device: IOHIDDevice, onTablet: @escaping (TabletPoint) -> Void) {
        self.device = device
        self.onTablet = onTablet

        let pid = hidIntProperty(device, kIOHIDProductIDKey)
        let vid = hidIntProperty(device, kIOHIDVendorIDKey)
        let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        let manufacturer = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String
        tag = productName ?? "HID-digitizer-\(String(vid, radix: 16))/\(String(pid, radix: 16))"
        detectedBrand = BrandHeuristic.likelyBrand(manufacturer: manufacturer, product: productName)

        let probed = queryHIDDigitizerSpec(device)
        spec = DigitizerSpec(maxX: probed.maxX, maxY: probed.maxY, maxPressure: probed.maxPressure)

        let maxReportSize = hidIntProperty(device, kIOHIDMaxInputReportSizeKey)
        reportBuffer = [UInt8](repeating: 0, count: Swift.max(maxReportSize, 64))

        // Scan elements once to learn which optional usages exist. This decides
        // proximity semantics (in-range vs. tip) and whether we synthesize a
        // click pressure for tip-only pens.
        var sawInRange = false
        var sawPressure = false
        if let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) {
            for i in 0..<CFArrayGetCount(elements) {
                guard let raw = CFArrayGetValueAtIndex(elements, i) else { continue }
                let elem = Unmanaged<IOHIDElement>.fromOpaque(raw).takeUnretainedValue()
                guard IOHIDElementGetUsagePage(elem) == GenericDigitizerFrame.Usage.digitizerPage
                else { continue }
                switch IOHIDElementGetUsage(elem) {
                case GenericDigitizerFrame.Usage.inRange: sawInRange = true
                case GenericDigitizerFrame.Usage.tipPressure: sawPressure = true
                default: break
                }
            }
        }
        frame = GenericDigitizerFrame(
            maxX: spec.maxX, maxY: spec.maxY, maxPressure: spec.maxPressure,
            hasInRange: sawInRange, hasPressure: sawPressure)
    }

    // MARK: - Open / Close

    private var selfRetain: Unmanaged<GenericHIDDigitizer>?

    /// Backing store for the raw input-report callback. Decoding never reads
    /// it — see `reportCallback` — but IOKit needs somewhere to put reports,
    /// and the buffer must outlive registration.
    private var reportBuffer: [UInt8]

    func open() {
        let ret = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard ret == kIOReturnSuccess else {
            logger.error("\(self.tag, privacy: .public): failed to open — \(ret, privacy: .public). Is another driver claiming it?")
            return
        }

        // Only fire callbacks for the two pages we read — keeps unrelated
        // collections (consumer-control, vendor) off the hot path.
        let valueMatch: [[String: Any]] = [
            [kIOHIDElementUsagePageKey: 0x01],
            [kIOHIDElementUsagePageKey: 0x0D],
        ]
        IOHIDDeviceSetInputValueMatchingMultiple(device, valueMatch as CFArray)

        let retain = Unmanaged.passRetained(self)
        selfRetain = retain
        IOHIDDeviceRegisterInputValueCallback(device, GenericHIDDigitizer.valueCallback, retain.toOpaque())

        // Raw reports, alongside the value callback above. Decoding doesn't use
        // these — value callbacks give us pre-parsed fields, which is the whole
        // point of this class — but device-data collection does, and without
        // this the *unrecognised, non-Wacom* devices that land here (i.e. the
        // exact population "Collect Device Data…" exists to serve) recorded
        // nothing at all. Input-value matching set above does not filter this
        // path, so vendor reports the decoder ignores still reach the capture.
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count,
            GenericHIDDigitizer.reportCallback, retain.toOpaque())

        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)

        let mx = spec.maxX; let my = spec.maxY; let mp = spec.maxPressure
        logger.info("\(self.tag, privacy: .public): generic HID digitizer attached (maxX=\(mx, privacy: .public) maxY=\(my, privacy: .public) pressure=\(self.frame.hasPressure ? mp : 0, privacy: .public) inRange=\(self.frame.hasInRange, privacy: .public))")
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(
            device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceRegisterInputReportCallback(device, &reportBuffer, reportBuffer.count, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        selfRetain?.release()
        selfRetain = nil
    }

    func setRingLED(index: Int) {}  // Generic digitizers expose no LED control.

    // MARK: - Value callback

    private static let valueCallback: IOHIDValueCallback = { ctx, _, _, value in
        guard let ctx else { return }
        Unmanaged<GenericHIDDigitizer>.fromOpaque(ctx).takeUnretainedValue()
            .handle(value: value)
    }

    /// Raw reports, for device-data collection only — never for decoding.
    ///
    /// Keys on the callback's `reportID` argument rather than `report[0]`: a
    /// standards-compliant digitizer with a single top-level collection may
    /// declare no Report ID at all, in which case reports carry no ID prefix
    /// and `report[0]` is the first *data* byte.
    private static let reportCallback: IOHIDReportCallback = {
        ctx, _, _, _, reportID, report, length in
        guard let ctx else { return }
        let me = Unmanaged<GenericHIDDigitizer>.fromOpaque(ctx).takeUnretainedValue()
        HIDCapture.shared.record(tag: me.tag, report: report, length: length)
        CaptureEngine.recordRaw(reportID: reportID, pointer: report, length: length)
    }

    /// One element changed. Update the decode frame, then emit a fresh point.
    ///
    /// We emit on every recognized element update rather than per report: IOKit
    /// delivers one callback per changed element with no stable frame boundary,
    /// so a frame may be momentarily one element stale (e.g. X updated, Y not
    /// yet). At pen rates that is sub-pixel and self-corrects on the next
    /// callback microseconds later, and `InputInjector`'s delta gate drops the
    /// redundant duplicates.
    private func handle(value: IOHIDValue) {
        let elem = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(elem)
        let usage = IOHIDElementGetUsage(elem)
        let v = IOHIDValueGetIntegerValue(value)

        if frame.update(usagePage: page, usage: usage, value: v) {
            onTablet(frame.point())
        }
    }
}
