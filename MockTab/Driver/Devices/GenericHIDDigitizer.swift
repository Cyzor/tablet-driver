// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid
import OSLog
import TabletKit

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "driver")

/// The universal floor: a driver for any standards-compliant HID pen
/// digitizer (top-level usage Digitizer/Pen, `0x0D`/`0x02`).
///
/// It reads no vendor layout. Each pen report the device's own descriptor
/// declares gets a `GenericPenDecoder`, and reports arrive on HIDThread.
///
/// Provides: absolute position, tip, and, when the descriptor declares
/// them, pressure, barrel buttons, eraser, tilt, twist, and hover distance.
/// Does not provide express keys, rings, vendor mode switching, or seizure.
final class GenericHIDDigitizer: TabletDevice, @unchecked Sendable {  // fixed after init; reports run on HIDThread

    let spec: DigitizerSpec

    /// Brand guessed from the USB manufacturer and product strings, or nil
    /// when nothing in them hints at a tablet. Drives the "looks like a
    /// Huion device" wording on the unrecognized-device banner.
    let detectedBrand: String?

    /// A CTL-x100 Intuos in Android mode, which swaps Wacom's vendor ID for
    /// 0x2D1F and offers only a basic pen report. Holding the outer
    /// ExpressKeys switches it back to PC mode.
    let isWacomAndroidMode: Bool
    private static let androidModeVendorID = 0x2D1F
    private static let androidModeProductIDs: Set<Int> = [0x0374, 0x0375, 0x0376, 0x0378, 0x03C5, 0x03C7]

    private let device: IOHIDDevice
    private let interface: IOKitHIDInterface
    private let onTablet: (TabletPoint) -> Void
    private let tag: String
    private let penDecoders: [UInt8: GenericPenDecoder]
    /// False when the descriptor declares no report IDs, so reports start
    /// with data.
    private let usesReportIDs: Bool

    /// Opens the interface and records its reports for discovery, but never
    /// moves the cursor. For multitouch-only interfaces: a device with no
    /// driver gets no `DeviceContext`, which would hide it from capture.
    private let observeOnly: Bool

    init(
        device: IOHIDDevice,
        onTablet: @escaping (TabletPoint) -> Void,
        observeOnly: Bool = false
    ) {
        self.device = device
        interface = IOKitHIDInterface(device)
        self.onTablet = onTablet
        self.observeOnly = observeOnly

        let pid = hidIntProperty(device, kIOHIDProductIDKey)
        let vid = hidIntProperty(device, kIOHIDVendorIDKey)
        let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        let manufacturer = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String
        tag = productName ?? "HID-digitizer-\(String(vid, radix: 16))/\(String(pid, radix: 16))"
        detectedBrand = BrandHeuristic.likelyBrand(manufacturer: manufacturer, product: productName)
        isWacomAndroidMode = vid == Self.androidModeVendorID && Self.androidModeProductIDs.contains(pid)

        let probed = queryHIDDigitizerSpec(device)
        spec = DigitizerSpec(maxX: probed.maxX, maxY: probed.maxY, maxPressure: probed.maxPressure)

        let layout = try? HIDReportDescriptorParser.parse(interface.reportDescriptor)
        var decoders: [UInt8: GenericPenDecoder] = [:]
        for penLayout in layout.map(GenericPenLayout.derive(from:)) ?? [] {
            decoders[penLayout.reportID] = GenericPenDecoder(layout: penLayout)
        }
        penDecoders = decoders
        usesReportIDs = layout?.reports.contains { $0.reportID != 0 } ?? true
    }

    func open() {
        let ret = interface.open(seize: false) { [self] report, _ in handle(report) }
        guard ret == kIOReturnSuccess else {
            logger.error("\(self.tag, privacy: .public): failed to open — \(ret, privacy: .public). Is another driver claiming it?")
            return
        }
        if observeOnly {
            logger.info("\(self.tag, privacy: .public): attached for observation only — reports recorded for discovery, no cursor input")
        } else if penDecoders.isEmpty {
            logger.info("\(self.tag, privacy: .public): descriptor declares no pen report this driver can read — recording reports only")
        } else {
            let ids = penDecoders.keys.sorted().map { String(format: "0x%02X", $0) }.joined(separator: ", ")
            logger.info("\(self.tag, privacy: .public): generic HID digitizer attached (maxX=\(self.spec.maxX, privacy: .public) maxY=\(self.spec.maxY, privacy: .public) pressure=\(self.spec.maxPressure, privacy: .public), pen reports \(ids, privacy: .public))")
        }
    }

    func close() {
        interface.close()
    }

    /// On HIDThread, once per report.
    private func handle(_ report: HIDReport) {
        let reportID = usesReportIDs ? report.reportID : 0
        CaptureEngine.recordRaw(device: device, reportID: UInt32(reportID), pointer: report.pointer, length: report.count)
        guard !observeOnly, let decoder = penDecoders[reportID], let point = decoder.decode(report: report) else {
            HIDCapture.shared.record(tag: tag, report: report.pointer, length: report.count)
            CaptureActivityProbe.noteUndecoded()
            return
        }
        HIDCapture.shared.record(tag: tag, report: report.pointer, length: report.count, decoded: [.pen(point)])
        CaptureActivityProbe.note([.pen(point)])
        onTablet(point)
    }
}
