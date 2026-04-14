// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026 This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab. If not, see <https://www.gnu.org/licenses/>.

import Foundation

// MARK: - Calibration Steps

/// Ordered steps for the guided calibration wizard.
/// Each case represents a specific user action that produces a distinct HID signal.
enum CalibrationStep: Int, CaseIterable, Identifiable {
    case idle            = 0  // capture baseline (no input)
    case tipDown         = 1  // pen tip touches tablet
    case tipUp           = 2  // pen tip lifts
    case penButton1      = 3  // first side button on pen
    case penButton2      = 4  // second side button on pen
    case eraserDown      = 5  // eraser end touches tablet
    case eraserUp        = 6  // eraser lifts
    case hover5mm        = 7  // pen hovering ~5mm above tablet
    case tilt15          = 8  // pen tilted ~15 degrees
    case tilt45          = 9  // pen tilted ~45 degrees
    case rotationCW      = 10 // art pen rotated clockwise 180
    case rotationCCW     = 11 // art pen rotated counter-clockwise 180
    case expressKey1     = 12 // express key 1
    case expressKey2     = 13 // express key 2
    case expressKey3     = 14 // express key 3
    case expressKey4     = 15 // express key 4
    case expressKey5     = 16 // express key 5
    case expressKey6     = 17 // express key 6 (if exists)
    case expressKey7     = 18 // express key 7 (if exists)
    case expressKey8     = 19 // express key 8 (if exists)
    case touchRing       = 20 // finger touches touch ring
    case touchRingPos0   = 21 // touch ring at position 0
    case touchRingPos36  = 22 // touch ring at position ~36 (quarter turn)
    case touchRingPos71  = 23 // touch ring at position ~71 (max)

    var id: Int { rawValue }

    /// Human-readable instruction shown in the wizard UI.
    var instruction: String {
        switch self {
        case .idle:        return "Hold the pen still without touching the tablet"
        case .tipDown:     return "Touch the pen tip to the tablet"
        case .tipUp:       return "Lift the pen tip away from the tablet"
        case .penButton1:  return "Hold pen button 1 (near tip) down for 1 second"
        case .penButton2:  return "Hold pen button 2 (near eraser) down for 1 second"
        case .eraserDown:  return "Touch the eraser end to the tablet"
        case .eraserUp:    return "Lift the eraser from the tablet"
        case .hover5mm:    return "Hold the pen 5mm above the tablet without touching"
        case .tilt15:      return "Tilt the pen to about 15 degrees"
        case .tilt45:      return "Tilt the pen to about 45 degrees"
        case .rotationCW:  return "Rotate the art pen clockwise 180 degrees"
        case .rotationCCW: return "Rotate the art pen counter-clockwise 180 degrees"
        case .expressKey1: return "Press and hold express key 1"
        case .expressKey2: return "Press and hold express key 2"
        case .expressKey3: return "Press and hold express key 3"
        case .expressKey4: return "Press and hold express key 4"
        case .expressKey5: return "Press and hold express key 5"
        case .expressKey6: return "Press and hold express key 6"
        case .expressKey7: return "Press and hold express key 7"
        case .expressKey8: return "Press and hold express key 8"
        case .touchRing:   return "Touch the ring with one finger"
        case .touchRingPos0:   return "Rotate ring to position 0"
        case .touchRingPos36:  return "Rotate ring to quarter position (~36)"
        case .touchRingPos71:  return "Rotate ring to maximum position (~71)"
        }
    }

    /// One-line summary for progress display.
    var shortLabel: String {
        switch self {
        case .idle:        return "Idle baseline"
        case .tipDown:     return "Tip down"
        case .tipUp:       return "Tip up"
        case .penButton1:  return "Pen button 1"
        case .penButton2:  return "Pen button 2"
        case .eraserDown:  return "Eraser down"
        case .eraserUp:    return "Eraser up"
        case .hover5mm:    return "Hover 5mm"
        case .tilt15:      return "Tilt 15°"
        case .tilt45:      return "Tilt 45°"
        case .rotationCW:  return "Rotation CW"
        case .rotationCCW: return "Rotation CCW"
        case .expressKey1: return "Express key 1"
        case .expressKey2: return "Express key 2"
        case .expressKey3: return "Express key 3"
        case .expressKey4: return "Express key 4"
        case .expressKey5: return "Express key 5"
        case .expressKey6: return "Express key 6"
        case .expressKey7: return "Express key 7"
        case .expressKey8: return "Express key 8"
        case .touchRing:   return "Ring touch"
        case .touchRingPos0:   return "Ring pos 0"
        case .touchRingPos36:  return "Ring pos ~36"
        case .touchRingPos71:  return "Ring pos ~71"
        }
    }

    /// Steps that should be included for a basic pen-only device.
    static var basicPenSteps: [CalibrationStep] {
        [.idle, .tipDown, .tipUp, .penButton1, .penButton2, .eraserDown, .eraserUp]
    }

    /// Steps for a device with tilt support.
    static var withTilt: [CalibrationStep] {
        basicPenSteps + [.hover5mm, .tilt15, .tilt45]
    }

    /// Steps for a device with art pen rotation.
    static var withRotation: [CalibrationStep] {
        withTilt + [.rotationCW, .rotationCCW]
    }

    /// Steps for a device with express keys.
    static func withExpressKeys(_ count: Int) -> [CalibrationStep] {
        var steps = withRotation
        for i in 1...min(count, 8) {
            switch i {
            case 1: steps.append(.expressKey1)
            case 2: steps.append(.expressKey2)
            case 3: steps.append(.expressKey3)
            case 4: steps.append(.expressKey4)
            case 5: steps.append(.expressKey5)
            case 6: steps.append(.expressKey6)
            case 7: steps.append(.expressKey7)
            case 8: steps.append(.expressKey8)
            default: break
            }
        }
        return steps
    }

    /// Steps for a device with a touch ring.
    static var withTouchRing: [CalibrationStep] {
        withRotation + [.touchRing, .touchRingPos0, .touchRingPos36, .touchRingPos71]
    }
}

// MARK: - Captured Sample

/// A single captured HID report paired with its delta from the baseline.
struct CapturedSample: Identifiable {
    let id = UUID()
    let step: CalibrationStep
    let reportID: UInt8
    let timestamp: Date
    let baseline: [UInt8]
    let action: [UInt8]

    /// Byte positions (0-indexed) that differ between baseline and action.
    var changedIndices: [Int] {
        computeDeltaIndices(baseline: baseline, action: action)
    }

    /// Values at the changed positions in the action sample.
    var changedValues: [UInt8] {
        changedIndices.map { action[$0] }
    }

    /// Values at the changed positions in the baseline (for comparison).
    var baselineValues: [UInt8] {
        changedIndices.map { baseline[$0] }
    }

    /// Bit positions (within a byte) that changed, for each changed byte index.
    /// Useful for identifying individual button bits.
    func changedBits(byteIndex: Int) -> [Int] {
        guard let idx = changedIndices.firstIndex(of: byteIndex),
              baseline.count > byteIndex,
              action.count > byteIndex else { return [] }
        let oldVal = baseline[byteIndex]
        let newVal = action[byteIndex]
        var bits: [Int] = []
        for bit in 0..<8 {
            if ((oldVal ^ newVal) & (1 << bit)) != 0 {
                bits.append(bit)
            }
        }
        return bits
    }

    /// Hex string of the action sample.
    var actionHex: String {
        action.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Hex string of the baseline sample.
    var baselineHex: String {
        baseline.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func computeDeltaIndices(baseline: [UInt8], action: [UInt8]) -> [Int] {
        var indices: [Int] = []
        let minLen = Swift.min(baseline.count, action.count)
        for i in 0..<minLen {
            if baseline[i] != action[i] {
                indices.append(i)
            }
        }
        return indices
    }
}

// MARK: - Captured Report Summary

/// Aggregated information about a specific report ID across all calibration steps.
struct CapturedReportSummary: Identifiable {
    let id: String  // report ID as hex string, e.g. "0x10"

    var reportID: UInt8 = 0
    var length: Int = 0
    var samples: [CapturedSample] = []

    /// Union of all byte indices that changed in any sample for this report ID.
    var allChangedIndices: Set<Int> {
        Set(samples.flatMap { $0.changedIndices })
    }

    /// Frequency map: which byte positions changed and how often.
    /// A byte that changes in multiple steps is likely a meaningful field.
    var changeFrequency: [Int: Int] {
        var freq: [Int: Int] = [:]
        for idx in allChangedIndices {
            freq[idx] = samples.filter { $0.changedIndices.contains(idx) }.count
        }
        return freq
    }

    /// Byte positions that changed in >= 50% of samples — high-value fields.
    var highValueIndices: Set<Int> {
        let threshold = max(1, samples.count / 2)
        return Set(changeFrequency.filter { $0.value >= threshold }.keys)
    }
}

// MARK: - Calibration Result

/// Complete output of a calibration session — ready for JSON export.
struct CalibrationResult: Codable {
    let captureVersion: Int = 1
    let capturedAt: Date
    let deviceInfo: DeviceInfo
    let reports: [String: ReportInfo]
    let notes: String?
    let submitterContact: String?

    struct DeviceInfo: Codable {
        let vendorID: String
        let productID: String
        let name: String
        let locationID: String?
        let serialNumber: String?
    }

    struct ReportInfo: Codable {
        let length: Int
        let description: String?
        let fields: [String: FieldInfo]?
        let sampleIdle: String?
        let sampleAction: String?
    }

    struct FieldInfo: Codable {
        let role: String?
        let bitmask: String?
        let note: String?
        let rangeMin: Int?
        let rangeMax: Int?
        let bits: Int?
        let sampleValues: [String]?
    }
}


// MARK: - Discovery Result

/// Output of a discovery session — for unknown devices.
/// Records all report IDs seen and which bytes vary vs constant.
struct DiscoveryResult: Codable {
    let captureVersion: Int = 2
    let capturedAt: Date
    let mode: String  // always "discovery"
    let duration: TimeInterval
    let deviceInfo: DiscoveryDeviceInfo
    let reports: [String: DiscoveryReportSummary]
}

struct DiscoveryDeviceInfo: Codable {
    let vendorID: String
    let productID: String
    let name: String
}

struct DiscoveryReportSummary: Codable {
    let reportID: UInt8
    let length: Int
    let sampleCount: Int
    var varyingBytes: [Int]  // byte positions that vary across samples
    var constantBytes: [Int]  // byte positions that are constant
}

// MARK: - Capture Mode

/// Controls how `handleReport` feeds data to the capture system.
enum CaptureMode: Sendable {
    /// No capture — device runs at full speed.
    case off
    /// Full hex dump every report (legacy HIDCapture behavior).
    case full
    /// Delta mode: capture first report that differs from baseline.
    case delta(step: CalibrationStep)
}

// MARK: - Device Context for Capture

/// Lightweight descriptor of a device being captured.
/// Passed to CaptureEngine when calibration starts.
struct CaptureDeviceInfo {
    let vendorID: Int
    let productID: Int
    let name: String
    let locationID: String?
    let serialNumber: String?

    var vendorIDHex: String   { String(format: "0x%04X", vendorID) }
    var productIDHex: String  { String(format: "0x%04X", productID) }
}
