// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import IOKit.hid
import OSLog

/// How seriously to treat an IOHIDDeviceSetReport failure.
enum HIDSetReportSeverity {
    /// Activation / init reports that should always succeed. Logged at .error
    /// on non-success — these failures usually mean the device isn't usable.
    case required
    /// Best-effort writes (e.g. LED slot, optional features) where firmware
    /// may silently ignore the write. Logged at .info.
    case bestEffort
}

/// Wrapper around `IOHIDDeviceSetReport` that logs non-success returns at the
/// requested severity. Replaces the historical pattern of either silently
/// dropping the return value or assigning it to `_`, which masked the class
/// of bug behind PTH-860 USB ring-LED writes being silently ignored.
@discardableResult
func hidSetReport(
    _ device: IOHIDDevice,
    type: IOHIDReportType = kIOHIDReportTypeFeature,
    reportID: CFIndex,
    bytes: inout [UInt8],
    tag: String,
    severity: HIDSetReportSeverity = .required,
    log: Logger
) -> IOReturn {
    let ret = IOHIDDeviceSetReport(device, type, reportID, &bytes, bytes.count)
    if ret != kIOReturnSuccess {
        let hex = String(format: "0x%08x", ret)
        switch severity {
        case .required:
            log.error("hidSetReport \(tag, privacy: .public) failed: \(hex, privacy: .public)")
        case .bestEffort:
            log.info("hidSetReport \(tag, privacy: .public): \(hex, privacy: .public)")
        }
    }
    return ret
}
