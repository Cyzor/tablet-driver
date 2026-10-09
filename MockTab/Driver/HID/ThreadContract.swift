// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import TabletKit

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "threading")

/// Debug-build checks of which thread runs what. See "Two Threads" in
/// `Architecture.md` for who owns which state.
///
/// A call on the wrong thread logs a fault the first time each call site
/// does it, then stays quiet. It never stops the app, so everyday use of a
/// Debug build doubles as the test. Release builds compile the checks away.
enum ThreadContract {

    /// The caller touches state the pen thread owns.
    @inline(__always)
    static func expectPenThread(
        _ function: StaticString = #function, file: StaticString = #fileID, line: UInt = #line
    ) {
        #if DEBUG
        guard CFRunLoopGetCurrent() !== HIDThread.shared.runLoop else { return }
        report(expected: "the pen thread", function: function, file: file, line: line)
        #endif
    }

    /// The caller touches state the main thread owns.
    @inline(__always)
    static func expectMainThread(
        _ function: StaticString = #function, file: StaticString = #fileID, line: UInt = #line
    ) {
        #if DEBUG
        guard !Thread.isMainThread else { return }
        report(expected: "the main thread", function: function, file: file, line: line)
        #endif
    }

    #if DEBUG
    private static let reportedSites = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    private static func report(
        expected: String, function: StaticString, file: StaticString, line: UInt
    ) {
        let site = "\(file):\(line)"
        guard reportedSites.withLock({ $0.insert(site).inserted }) else { return }
        let actual = Thread.isMainThread ? "the main thread" : (Thread.current.name ?? "an unnamed thread")
        logger.fault(
            "\(function, privacy: .public) at \(site, privacy: .public) expects \(expected, privacy: .public) but ran on \(actual, privacy: .public)"
        )
    }
    #endif
}

extension HIDThread {

    /// Runs `body` on the pen thread and returns its result, for main-thread
    /// readers of pen-thread state, such as the diagnostics text. Waits about
    /// as long as one report takes to handle. The pen thread never waits on
    /// main, so this can't deadlock; from the pen thread itself it runs inline.
    func performAndWait<T>(_ body: @escaping () -> T) -> T {
        if CFRunLoopGetCurrent() === runLoop { return body() }
        var result: T?
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            result = body()
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        done.wait()
        return result!
    }
}
