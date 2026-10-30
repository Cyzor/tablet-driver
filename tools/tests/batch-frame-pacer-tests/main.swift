// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

// Checks BatchFramePacer's timing on TabletKit's HID thread, where the app
// runs it: frames come out in order, one per interval, never bunched or
// late, and a flush delivers what's left at once. Batches are shaped like a
// Bluetooth Intuos Pro's: 5 samples spanning one ~22 ms report.

import Foundation
import TabletKit

var checks = 0
var failures = 0

func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        FileHandle.standardError.write(Data("FAIL (line \(line)): \(message())\n".utf8))
    }
}

func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

/// Frame IDs ride in `timestampNs`; the frames themselves are empty touch sets.
func frames(_ ids: [UInt64]) -> [(frame: BatchedFrame, timestampNs: UInt64)] {
    ids.map { (.touch([]), $0) }
}

/// Deliveries recorded on the HID thread, read from the main thread.
final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(id: UInt64, at: TimeInterval)] = []
    func add(_ id: UInt64) { lock.lock(); items.append((id, now())); lock.unlock() }
    var all: [(id: UInt64, at: TimeInterval)] { lock.lock(); defer { lock.unlock() }; return items }
    var ids: [UInt64] { all.map(\.id) }
}

/// Runs `body` on the HID thread and waits for it.
func onHIDThread<R>(_ body: @escaping () -> R) -> R {
    var result: R?
    let done = DispatchSemaphore(value: 0)
    CFRunLoopPerformBlock(HIDThread.shared.runLoop, CFRunLoopMode.commonModes.rawValue) {
        result = body()
        done.signal()
    }
    CFRunLoopWakeUp(HIDThread.shared.runLoop)
    done.wait()
    return result!
}

/// Waits until `log` holds `count` deliveries or `timeout` passes.
func wait(for count: Int, in log: Log, timeout: TimeInterval = 2) {
    let end = now() + timeout
    while log.all.count < count && now() < end { usleep(1000) }
}

let interval = 0.022 / 5
let late = 0.005   // a busy Mac can fire a timer a few milliseconds late
let early = 0.0005 // the pacer delivers up to 0.2 ms early to save a tick

// One batch: one frame per interval, in order, starting one interval out
do {
    let log = Log()
    let pacer = onHIDThread { BatchFramePacer { _, id in log.add(id) } }
    let start = onHIDThread { () -> TimeInterval in
        let t = now()
        pacer.schedule(frames([1, 2, 3, 4, 5]), interval: interval)
        return t
    }
    wait(for: 5, in: log)
    let got = log.all
    expect(got.map(\.id) == [1, 2, 3, 4, 5], "Every frame, in order: \(got.map(\.id))")
    for (i, item) in got.enumerated() {
        let due = start + Double(i + 1) * interval
        expect(item.at >= due - early, String(format: "Frame %d isn't early: %.2f ms", item.id, (item.at - due) * 1000))
        expect(item.at <= due + late, String(format: "Frame %d isn't late: %.2f ms", item.id, (item.at - due) * 1000))
    }
    let gaps = zip(got.dropFirst(), got).map { $0.at - $1.at }
    expect(gaps.allSatisfy { $0 > interval / 2 },
           "No two frames bunch together: \(gaps.map { String(format: "%.2f", $0 * 1000) }) ms")
    onHIDThread { withExtendedLifetime(pacer) {} }
}

// Frames appended to a running batch queue behind it
do {
    let log = Log()
    let pacer = onHIDThread { BatchFramePacer { _, id in log.add(id) } }
    onHIDThread {
        pacer.schedule(frames([1, 2]), interval: interval)
        // Asks for sooner than the queue's tail; the pacer raises it.
        pacer.append(.touch([]), timestampNs: 3, delay: 0)
        pacer.append(.touch([]), timestampNs: 4, delay: interval * 3)
    }
    wait(for: 4, in: log)
    expect(log.ids == [1, 2, 3, 4], "Appended frames follow the batch: \(log.ids)")
    onHIDThread { withExtendedLifetime(pacer) {} }
}

// Appending to an idle pacer starts it
do {
    let log = Log()
    let pacer = onHIDThread { BatchFramePacer { _, id in log.add(id) } }
    let start = onHIDThread { () -> TimeInterval in
        let t = now()
        pacer.append(.touch([]), timestampNs: 7, delay: 0.01)
        return t
    }
    wait(for: 1, in: log)
    let got = log.all
    expect(got.map(\.id) == [7], "An appended frame arrives on its own: \(got.map(\.id))")
    if let first = got.first {
        expect(first.at >= start + 0.01 - early && first.at <= start + 0.01 + late,
               String(format: "It waits its delay: %.2f ms", (first.at - start) * 1000))
    }
    onHIDThread { withExtendedLifetime(pacer) {} }
}

// A flush delivers the rest at once and stops the timer
do {
    let log = Log()
    let pacer = onHIDThread { BatchFramePacer { _, id in log.add(id) } }
    onHIDThread { pacer.schedule(frames([1, 2, 3, 4, 5]), interval: 0.05) }
    wait(for: 1, in: log)
    let flushed = onHIDThread { pacer.flush() }
    expect(flushed == 4, "Flush reports what it delivered: \(flushed)")
    expect(log.ids == [1, 2, 3, 4, 5], "Flushed frames come out in order: \(log.ids)")
    let all = log.all
    if all.count == 5 {
        expect(all[4].at - all[1].at < 0.005, "Flushed frames come out at once")
    }
    usleep(300_000)
    expect(log.ids.count == 5, "Nothing arrives after a flush: \(log.ids)")
    expect(onHIDThread { pacer.flush() } == 0, "A second flush has nothing left")
}

// A new batch flushes the old one first
do {
    let log = Log()
    let pacer = onHIDThread { BatchFramePacer { _, id in log.add(id) } }
    onHIDThread {
        pacer.schedule(frames([1, 2, 3]), interval: 0.05)
        pacer.schedule(frames([4, 5]), interval: interval)
    }
    wait(for: 5, in: log)
    expect(log.ids == [1, 2, 3, 4, 5], "The old batch goes out before the new one: \(log.ids)")
    onHIDThread { pacer.schedule([], interval: interval) }
    usleep(50_000)
    expect(log.ids.count == 5, "An empty batch adds nothing: \(log.ids)")
}

// Waiting costs no CPU: the timer sleeps until the next frame is due
// rather than firing over and over.
func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}
do {
    let log = Log()
    let pacer = onHIDThread { BatchFramePacer { _, id in log.add(id) } }
    let before = cpuSeconds()
    onHIDThread { pacer.schedule(frames([1, 2, 3, 4, 5]), interval: 0.06) }
    wait(for: 5, in: log)
    let used = cpuSeconds() - before
    expect(log.ids == [1, 2, 3, 4, 5], "A slow batch arrives whole: \(log.ids)")
    expect(used < 0.1, String(format: "Pacing 300 ms of frames used %.0f ms of CPU", used * 1000))
    onHIDThread { withExtendedLifetime(pacer) {} }
}

// A pacer released mid-batch delivers nothing more
do {
    let log = Log()
    onHIDThread {
        let pacer = BatchFramePacer { _, id in log.add(id) }
        pacer.schedule(frames([1, 2, 3]), interval: 0.02)
    }
    usleep(150_000)
    expect(log.ids.isEmpty, "A released pacer's timer is gone: \(log.ids)")
}

print("batch-frame-pacer-tests: \(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
