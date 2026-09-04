// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOBluetooth
import TabletKit

/// Samples RSSI and link quality for one Bluetooth-connected tablet during a
/// discovery capture, so a report of choppy Bluetooth cursor motion can be
/// checked against signal strength instead of guessed at.
///
/// **The address match is a best-effort guess, not a verified fact.** macOS
/// commonly — but undocumented, and not guaranteed — surfaces a Bluetooth HID
/// peripheral's `kIOHIDSerialNumberKey` as its BD_ADDR string. That is the
/// same observation already load-bearing for `TabletManager` distrusting that
/// key for instance identity over Bluetooth (see the comment at its read
/// site). This reuses the string for a much lower-stakes purpose: nothing
/// here feeds identity, injection, or settings, so a wrong guess costs an
/// absent or misleading diagnostic block, never a functional regression.
///
/// Confidence is checked at read time rather than assumed: every sample
/// compares the resolved device's own `isConnected()` against the fact that
/// we are, ourselves, actively receiving reports from *some* Bluetooth
/// tablet. A session where they disagree even once is flagged
/// `addressLikelyWrong` in the summary instead of silently trusted.
final class BluetoothLinkMonitor {
    struct Summary {
        let addressCandidate: String
        let sampleCount: Int
        let disconnectedSampleCount: Int
        let addressLikelyWrong: Bool
        let rssiMin: Int?
        let rssiMax: Int?
        let rssiAvg: Double?
        let rawRSSIMin: Int?
        let rawRSSIMax: Int?
        let rawRSSIAvg: Double?
    }

    /// Sentinel both `rssi()` and `rawRSSI()` return for "value unavailable"
    /// (disconnected, or the module doesn't support raw RSSI) — not a real
    /// reading, must be excluded before averaging.
    private static let unavailableRSSI: Int8 = 127

    /// How often to poll. Frequent enough to characterize a capture session
    /// (typically tens of seconds to an hour), infrequent enough that the
    /// bluetoothd round-trip each read triggers is never a meaningful load.
    private static let sampleInterval: TimeInterval = 2.0

    private let device: IOBluetoothDevice
    private let addressCandidate: String
    private let queue = DispatchQueue(
        label: "com.cyzor.mocktab.bluetooth-link-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?

    private var rssiSamples: [Int8] = []
    private var rawRSSISamples: [Int8] = []
    private var disconnectedSampleCount = 0
    private var sawDisagreement = false

    /// Resolves `addressCandidate` to a paired `IOBluetoothDevice` and starts
    /// sampling immediately if resolution succeeds. `nil` if the candidate
    /// isn't a plausible BD_ADDR or IOBluetooth has no paired device at that
    /// address — callers should treat that as "no data available," not an
    /// error worth surfacing.
    init?(addressCandidate: String) {
        guard let normalized = Self.normalize(addressCandidate),
            let resolved = IOBluetoothDevice(addressString: normalized)
        else { return nil }
        self.device = resolved
        self.addressCandidate = addressCandidate
        start()
    }

    /// Accepts the colon- or hyphen-separated forms macOS uses interchangeably
    /// across contexts; `IOBluetoothDevice(addressString:)` only accepts the
    /// colon form (`xx:xx:xx:xx:xx:xx`).
    private static func normalize(_ raw: String) -> String? {
        let lowered = raw.replacingOccurrences(of: "-", with: ":").lowercased()
        let parts = lowered.split(separator: ":")
        guard parts.count == 6,
            parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) })
        else { return nil }
        return parts.joined(separator: ":")
    }

    private func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.sampleInterval)
        t.setEventHandler { [weak self] in self?.sample() }
        timer = t
        t.resume()
    }

    /// Runs on `queue`, never on HIDThread: each read is a synchronous round
    /// trip to bluetoothd, and must never be allowed to stall report decoding.
    private func sample() {
        let connected = device.isConnected()
        if !connected {
            disconnectedSampleCount += 1
            // A tablet that is, in fact, still sending us reports right now
            // cannot itself be disconnected — so the resolved device and our
            // real one have diverged. One miss can be a momentary bluetoothd
            // hiccup; not fatal, but recorded as a strike against trusting
            // this session's numbers.
            sawDisagreement = true
            return
        }
        let rssi = device.rssi()
        let raw = device.rawRSSI()
        if rssi != Self.unavailableRSSI { rssiSamples.append(rssi) }
        if raw != Self.unavailableRSSI { rawRSSISamples.append(raw) }
    }

    /// Stops sampling and returns everything collected. Safe to call once;
    /// the monitor is not reusable afterward.
    func stopAndSummarize() -> Summary {
        timer?.cancel()
        timer = nil
        return queue.sync {
            Summary(
                addressCandidate: addressCandidate,
                sampleCount: rssiSamples.count,
                disconnectedSampleCount: disconnectedSampleCount,
                addressLikelyWrong: sawDisagreement,
                rssiMin: rssiSamples.min().map(Int.init),
                rssiMax: rssiSamples.max().map(Int.init),
                rssiAvg: rssiSamples.isEmpty
                    ? nil : Double(rssiSamples.map(Int.init).reduce(0, +)) / Double(rssiSamples.count),
                rawRSSIMin: rawRSSISamples.min().map(Int.init),
                rawRSSIMax: rawRSSISamples.max().map(Int.init),
                rawRSSIAvg: rawRSSISamples.isEmpty
                    ? nil
                    : Double(rawRSSISamples.map(Int.init).reduce(0, +)) / Double(rawRSSISamples.count))
        }
    }

    deinit {
        timer?.cancel()
    }
}
