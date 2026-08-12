// virtual_digitizer_spike_corehid.swift — CoreHID (macOS 15+) variant of the
// IOHIDUserDevice spike. Same pen descriptor and scripted stroke as
// virtual_digitizer_spike.c; exists to test whether the modern CoreHID path
// avoids the restricted com.apple.developer.hid.virtual.device entitlement
// that AMFI enforces on the IOKit path (ad-hoc and Developer ID signatures
// both get SIGKILLed there without a provisioning profile).
//
// This variant only answers "can we create + stream?" — for the full
// self-measuring verdict, run the C tool's tap alongside:
//     ./virtual_digitizer_spike --observe-only
//
// Build:  swiftc -O -o virtual_digitizer_spike_corehid virtual_digitizer_spike_corehid.swift
// Run:    ./virtual_digitizer_spike_corehid [seconds]

import CoreHID
import Foundation

let reportDescriptor: [UInt8] = [
    0x05, 0x0D,        // Usage Page (Digitizers)
    0x09, 0x02,        // Usage (Pen)
    0xA1, 0x01,        // Collection (Application)
    0x09, 0x20,        //   Usage (Stylus)
    0xA1, 0x00,        //   Collection (Physical)
    0x09, 0x42,        //     Tip Switch
    0x09, 0x44,        //     Barrel Switch
    0x09, 0x3C,        //     Invert
    0x09, 0x45,        //     Eraser
    0x09, 0x32,        //     In Range
    0x15, 0x00, 0x25, 0x01,
    0x75, 0x01, 0x95, 0x05,
    0x81, 0x02,
    0x75, 0x03, 0x95, 0x01, 0x81, 0x03,
    0x05, 0x01,        //     Generic Desktop
    0x09, 0x30,        //     X
    0x15, 0x00, 0x26, 0xFF, 0x7F,
    0x75, 0x10, 0x95, 0x01,
    0x81, 0x02,
    0x09, 0x31,        //     Y
    0x81, 0x02,
    0x05, 0x0D,
    0x09, 0x30,        //     Tip Pressure
    0x26, 0xFF, 0x1F,
    0x81, 0x02,
    0x09, 0x3D,        //     X Tilt
    0x15, 0xC4, 0x25, 0x3C,
    0x75, 0x08,
    0x81, 0x02,
    0x09, 0x3E,        //     Y Tilt
    0x81, 0x02,
    0xC0,
    0xC0,
]

let logicalMax = 32767
let pressureMax = 8191

func report(tip: Bool, inRange: Bool, x: Int, y: Int, pressure: Int,
            tiltX: Int8, tiltY: Int8) -> Data {
    var r = [UInt8](repeating: 0, count: 9)
    r[0] = (tip ? 1 : 0) | (inRange ? 0x10 : 0)
    r[1] = UInt8(x & 0xFF); r[2] = UInt8((x >> 8) & 0xFF)
    r[3] = UInt8(y & 0xFF); r[4] = UInt8((y >> 8) & 0xFF)
    r[5] = UInt8(pressure & 0xFF); r[6] = UInt8((pressure >> 8) & 0xFF)
    r[7] = UInt8(bitPattern: tiltX); r[8] = UInt8(bitPattern: tiltY)
    return Data(r)
}

final class Delegate: HIDVirtualDeviceDelegate {
    func hidVirtualDevice(_ device: HIDVirtualDevice,
                          receivedSetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, data: Data) throws {}
    func hidVirtualDevice(_ device: HIDVirtualDevice,
                          receivedGetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, maxSize: Int) throws -> Data { Data() }
}

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 6 : 6

let properties = HIDVirtualDevice.Properties(descriptor: Data(reportDescriptor),
                                             vendorID: 0x4D54,
                                             productID: 0x0002)
// properties.product = "MockTab Virtual Pen (CoreHID)" — set if the
// Properties type exposes it on this SDK; descriptor is the required part.

guard let device = HIDVirtualDevice(properties: properties) else {
    fputs("error: HIDVirtualDevice(properties:) returned nil — CoreHID path is gated too.\n", stderr)
    exit(1)
}

let delegate = Delegate()

let task = Task {
    await device.activate(delegate: delegate)
    fputs("[device] CoreHID virtual pen created and activated\n", stderr)
    try await Task.sleep(for: .seconds(2))  // enumeration

    fputs("[stroke] pen entering range\n", stderr)
    try await device.dispatchInputReport(
        data: report(tip: false, inRange: true, x: logicalMax / 5, y: logicalMax / 5,
                     pressure: 0, tiltX: 20, tiltY: -15),
        timestamp: SuspendingClock.now)
    try await Task.sleep(for: .milliseconds(300))

    fputs("[stroke] tip down, sweeping with pressure ramp (watch the cursor)\n", stderr)
    let hz = 200.0
    let steps = Int(seconds * hz)
    let lo = logicalMax / 5, hi = logicalMax * 4 / 5
    for i in 0..<steps {
        let phase = Double(i) / Double(steps)
        let leg = phase < 0.5 ? phase * 2 : 2 - phase * 2
        let pos = lo + Int(Double(hi - lo) * leg)
        let pressure = Int(Double(pressureMax) * leg)
        try await device.dispatchInputReport(
            data: report(tip: pressure > 0, inRange: true, x: pos, y: pos,
                         pressure: pressure, tiltX: 20, tiltY: -15),
            timestamp: SuspendingClock.now)
        try await Task.sleep(for: .milliseconds(5))
    }

    fputs("[stroke] pen leaving range\n", stderr)
    try await device.dispatchInputReport(
        data: report(tip: false, inRange: true, x: hi, y: hi, pressure: 0,
                     tiltX: 20, tiltY: -15),
        timestamp: SuspendingClock.now)
    try await device.dispatchInputReport(
        data: report(tip: false, inRange: false, x: hi, y: hi, pressure: 0,
                     tiltX: 0, tiltY: 0),
        timestamp: SuspendingClock.now)
    fputs("[done] stroke complete\n", stderr)
    exit(0)
}

_ = task
RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds + 6))
fputs("timeout\n", stderr)
exit(2)
