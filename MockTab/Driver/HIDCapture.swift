import Foundation

/// Lightweight raw-HID capture buffer.
///
/// Call `HIDCapture.shared.record(tag:report:length:)` at the top of every
/// `handleReport()` to accumulate a hex dump of every incoming report.
/// Start/stop/save are driven from InfoView.
///
/// Thread safety: all device callbacks fire on the main thread (IOHIDManager
/// is scheduled on CFRunLoopGetMain / kCFRunLoopCommonModes), so no locking
/// is needed.
final class HIDCapture {

    static let shared = HIDCapture()
    private init() {}

    // MARK: - State (read from UI, main thread only)

    private(set) var isCapturing = false
    private(set) var reportCount = 0

    // MARK: - Buffer

    private var lines: [String] = []
    private var startTime: Date = .init()

    // MARK: - Control

    func start() {
        lines.removeAll()
        reportCount = 0
        startTime = Date()
        isCapturing = true
    }

    func stop() {
        isCapturing = false
    }

    func clear() {
        lines.removeAll()
        reportCount = 0
    }

    // MARK: - Recording

    /// Append one report to the in-memory buffer.
    /// Called from IOHIDReportCallback — must stay allocation-light and fast.
    func record(tag: String, report: UnsafePointer<UInt8>, length: Int) {
        guard isCapturing, length > 0 else { return }

        let elapsed = Date().timeIntervalSince(startTime)
        let mins  = Int(elapsed) / 60
        let secs  = Int(elapsed) % 60
        let ms    = Int((elapsed - Double(Int(elapsed))) * 1000)
        let ts    = String(format: "%02d:%02d.%03d", mins, secs, ms)

        let id  = String(format: "%02X", report[0])
        let hex = (0..<length)
            .map { String(format: "%02X", report[$0]) }
            .joined(separator: " ")

        // Pad tag to 20 chars for column alignment across devices.
        let padded = tag.count <= 20
            ? tag + String(repeating: " ", count: 20 - tag.count)
            : String(tag.prefix(20))

        lines.append("[\(ts)] \(padded) ID=\(id) len=\(String(format: "%-4d", length))  \(hex)")
        reportCount += 1
    }

    // MARK: - Persistence

    /// Write captured lines to ~/Desktop/mocktab_capture_<timestamp>.txt.
    /// Returns the URL on success, nil if the buffer is empty or write fails.
    @discardableResult
    func save() -> URL? {
        guard !lines.isEmpty else { return nil }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = fmt.string(from: startTime)

        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/mocktab_capture_\(stamp).txt")

        let header = """
            MockTab HID Capture
            Started : \(startTime)
            Reports : \(reportCount)
            Format  : [mm:ss.ms] <device-tag>            ID=<hex> len=<n>  <hex bytes>
            ──────────────────────────────────────────────────────────────────────────────────────

            """

        let content = header + lines.joined(separator: "\n") + "\n"
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("HIDCapture: save failed — \(error)")
            return nil
        }
    }
}
