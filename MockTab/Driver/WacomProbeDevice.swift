// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid
import OSLog

private let probeLog = Logger(subsystem: "com.cyzor.mocktab", category: "probe")

/// Temporary shim attached to any unrecognised Wacom device whose
/// `MaxInputReportSize` is 10 (IntuosV1 wire format).
///
/// It applies the standard feature-init, decodes each 10-byte report with
/// the same IntuosV1 formula used by PTH851Device, and continuously logs
/// running maxima to the unified system log.  Open **Console.app**, filter
/// on `com.cyzor.mocktab` (category `probe`), then move the pen to all four
/// corners and press hard —
/// the resulting X / Y / pressure peaks appear as structured log entries and
/// are also printed to stderr so they show in Xcode's debug console.
///
/// Once you have the numbers, create a proper `*Device.swift` and add it to
/// `TabletManager.deviceConnected(_:)`.
final class WacomProbeDevice: TabletDevice {

    // Placeholder spec — not used for injection; WacomProbeDevice never calls onTablet.
    let spec = DigitizerSpec(maxX: 65535, maxY: 65535, maxPressure: 2047)

    private let device: IOHIDDevice
    private var reportBuffer = [UInt8](repeating: 0, count: 10)

    // Running coordinate / pressure peaks.
    private var maxX: Int = 0
    private var maxY: Int = 0
    private var maxP: Int = 0
    private var sampleCount: Int = 0

    init(device: IOHIDDevice) {
        self.device = device
    }

    func open() {
        let ret = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard ret == kIOReturnSuccess else {
            probeLog.error(
                "WacomProbe: cannot open device (err \(ret)). Is another driver running?")
            return
        }

        // Same feature init as PTH-851 / PTZ-631W; activates the digitiser endpoint.
        var init1: [UInt8] = [0x02, 0x02]
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0x02, &init1, init1.count)

        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count,
            WacomProbeDevice.reportCB, ctx)
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetCurrent(),
            RunLoop.Mode.common.rawValue as CFString)

        let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
        probeLog.notice("WacomProbe: listening on \(productName, privacy: .public) — move pen to all four corners and press hard")
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(
            device, CFRunLoopGetCurrent(),
            RunLoop.Mode.common.rawValue as CFString)
        IOHIDDeviceRegisterInputReportCallback(device, &reportBuffer, reportBuffer.count, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        probeLog.notice("WacomProbe: final maxima — X=\(self.maxX, privacy: .public) Y=\(self.maxY, privacy: .public) P=\(self.maxP, privacy: .public) (from \(self.sampleCount, privacy: .public) samples)")
    }

    // MARK: - C callback

    private static let reportCB: IOHIDReportCallback = { ctx, _, _, _, _, report, length in
        guard let ctx else { return }
        Unmanaged<WacomProbeDevice>.fromOpaque(ctx).takeUnretainedValue()
            .handle(report: report, length: length)
    }

    private func handle(report: UnsafePointer<UInt8>, length: CFIndex) {
        guard length >= 10 else { return }

        let status = report[1]
        // Require in-proximity + high-confidence for reliable position data.
        guard (status & 0x20) != 0, (status & 0x40) != 0 else { return }

        // IntuosV1 coordinate decode (identical to PTH851Device).
        let x = ((Int(report[3]) | Int(report[2]) << 8) << 1) | ((Int(report[9]) >> 1) & 1)
        let y = ((Int(report[5]) | Int(report[4]) << 8) << 1) | (Int(report[9]) & 1)
        let p = (Int(report[6]) << 3) | (Int(report[7] & 0xC0) >> 5) | (Int(report[1]) & 1)

        sampleCount += 1
        var updated = false

        if x > maxX {
            maxX = x
            updated = true
        }
        if y > maxY {
            maxY = y
            updated = true
        }
        if p > maxP {
            maxP = p
            updated = true
        }

        if updated {
            probeLog.notice("WacomProbe: new peak — X=\(self.maxX, privacy: .public) Y=\(self.maxY, privacy: .public) P=\(self.maxP, privacy: .public)")
        }
    }
}
