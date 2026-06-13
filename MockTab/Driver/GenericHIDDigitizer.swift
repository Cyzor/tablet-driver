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

    private let device: IOHIDDevice
    private let onTablet: (TabletPoint) -> Void
    private let tag: String

    // ── Standard digitizer usages (HID Usage Tables, Digitizer page 0x0D) ──
    private enum GD {  // Generic Desktop page 0x01
        static let x: UInt32 = 0x30
        static let y: UInt32 = 0x31
    }
    private enum Dig {  // Digitizer page 0x0D
        static let tipPressure: UInt32 = 0x30
        static let inRange: UInt32 = 0x32
        static let invert: UInt32 = 0x3C
        static let tiltX: UInt32 = 0x3D
        static let tiltY: UInt32 = 0x3E
        static let tipSwitch: UInt32 = 0x42
        static let barrelSwitch: UInt32 = 0x44
        static let eraserSwitch: UInt32 = 0x45
        static let secondaryBarrel: UInt32 = 0x5A
    }

    // Which optional usages this device actually exposes — decided once at init.
    private let hasInRange: Bool
    private let hasPressure: Bool

    // Latest decoded field values, accumulated across per-element callbacks.
    private var curX = 0
    private var curY = 0
    private var curPressure = 0
    private var tip = false
    private var inRange = false
    private var barrel1 = false
    private var barrel2 = false
    private var eraser = false
    private var tiltX = 0
    private var tiltY = 0

    // MARK: - Init

    init(device: IOHIDDevice, onTablet: @escaping (TabletPoint) -> Void) {
        self.device = device
        self.onTablet = onTablet

        let pid = hidIntProperty(device, kIOHIDProductIDKey)
        let vid = hidIntProperty(device, kIOHIDVendorIDKey)
        let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        tag = productName ?? "HID-digitizer-\(String(vid, radix: 16))/\(String(pid, radix: 16))"

        let probed = queryHIDDigitizerSpec(device)
        spec = DigitizerSpec(maxX: probed.maxX, maxY: probed.maxY, maxPressure: probed.maxPressure)

        // Scan elements once to learn which optional usages exist. This decides
        // proximity semantics (in-range vs. tip) and whether we synthesize a
        // click pressure for tip-only pens.
        var sawInRange = false
        var sawPressure = false
        if let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) {
            for i in 0..<CFArrayGetCount(elements) {
                guard let raw = CFArrayGetValueAtIndex(elements, i) else { continue }
                let elem = Unmanaged<IOHIDElement>.fromOpaque(raw).takeUnretainedValue()
                guard IOHIDElementGetUsagePage(elem) == 0x0D else { continue }
                switch IOHIDElementGetUsage(elem) {
                case Dig.inRange: sawInRange = true
                case Dig.tipPressure: sawPressure = true
                default: break
                }
            }
        }
        hasInRange = sawInRange
        hasPressure = sawPressure
    }

    // MARK: - Open / Close

    private var selfRetain: Unmanaged<GenericHIDDigitizer>?

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
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)

        let mx = spec.maxX; let my = spec.maxY; let mp = spec.maxPressure
        logger.info("\(self.tag, privacy: .public): generic HID digitizer attached (maxX=\(mx, privacy: .public) maxY=\(my, privacy: .public) pressure=\(self.hasPressure ? mp : 0, privacy: .public) inRange=\(self.hasInRange, privacy: .public))")
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(
            device, CFRunLoopGetCurrent(), RunLoop.Mode.common.rawValue as CFString)
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
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

    /// One element changed. Update the cached field, then emit a fresh point.
    ///
    /// We emit on every element update rather than per report: IOKit delivers one
    /// callback per changed element with no stable frame boundary, so a frame may
    /// be momentarily one element stale (e.g. X updated, Y not yet). At pen rates
    /// that is sub-pixel and self-corrects on the next callback microseconds
    /// later, and `InputInjector`'s delta gate drops the redundant duplicates.
    private func handle(value: IOHIDValue) {
        let elem = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(elem)
        let usage = IOHIDElementGetUsage(elem)
        let v = IOHIDValueGetIntegerValue(value)

        switch (page, usage) {
        case (0x01, GD.x): curX = v
        case (0x01, GD.y): curY = v
        case (0x0D, Dig.tipPressure): curPressure = v
        case (0x0D, Dig.tipSwitch): tip = v != 0
        case (0x0D, Dig.inRange): inRange = v != 0
        case (0x0D, Dig.barrelSwitch): barrel1 = v != 0
        case (0x0D, Dig.secondaryBarrel): barrel2 = v != 0
        case (0x0D, Dig.eraserSwitch), (0x0D, Dig.invert): eraser = v != 0
        case (0x0D, Dig.tiltX): tiltX = v
        case (0x0D, Dig.tiltY): tiltY = v
        default: return  // Unrelated element — don't bother re-emitting.
        }

        // Proximity: trust In Range if present; otherwise reports only arrive
        // while the pen is active, so treat any report as in-proximity.
        let proximity = hasInRange ? inRange : true

        // Click is derived downstream from pressure (`pressure > 0.004`). A
        // tip-only pen with no pressure axis gets a synthesized full-scale
        // pressure on contact so taps register; pressure-reporting pens pass
        // their real value through.
        let effPressure = hasPressure ? curPressure : (tip ? spec.maxPressure : 0)

        onTablet(
            TabletPoint(
                x: curX, y: curY, maxX: spec.maxX, maxY: spec.maxY,
                pressure: effPressure, maxPressure: spec.maxPressure,
                tiltX: Double(tiltX), tiltY: Double(tiltY), rotation: 0.0,
                penButton1: barrel1, penButton2: barrel2,
                eraser: eraser, inProximity: proximity, hoverDistance: 0))
    }
}
