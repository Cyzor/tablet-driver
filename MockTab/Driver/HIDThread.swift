// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026  This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab.  If not, see <https://www.gnu.org/licenses/>.

import CoreFoundation
import Foundation

/// Dedicated high-priority run-loop thread for IOHIDManager callbacks.
///
/// Scheduling IOHIDManager on the main run loop means HID reports are
/// delivered only when the main thread is idle — a SwiftUI rendering pass
/// can delay delivery by an entire frame (~8 ms at 120 Hz). HIDThread keeps
/// a CFRunLoop spinning on a `.userInteractive` background thread, so reports
/// arrive immediately regardless of what the main thread is doing.
///
/// Only IOHIDManager/IOHIDDevice scheduling should use this run loop.
/// All UI mutations and CGEvent posts still happen on the main actor
/// (via Task { @MainActor in … } hops from callbacks).
final class HIDThread {

    static let shared = HIDThread()

    /// The CFRunLoop running on the dedicated background thread.
    /// Safe to use from any thread for IOHIDDeviceScheduleWithRunLoop.
    let runLoop: CFRunLoop

    private init() {
        var captured: CFRunLoop?
        let sema = DispatchSemaphore(value: 0)

        let thread = Thread {
            captured = CFRunLoopGetCurrent()
            sema.signal()
            // Add a keep-alive source so the run loop doesn't exit when idle.
            let source = CFRunLoopSourceCreate(
                nil, 0,
                // UnsafeMutablePointer to CFRunLoopSourceContext — use a blank one.
                &HIDThread.blankSourceContext)
            if let source {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            CFRunLoopRun()
        }
        thread.name = "com.cyzor.mocktab.hid"
        thread.qualityOfService = .userInteractive
        thread.start()

        sema.wait()
        runLoop = captured!
    }

    // A do-nothing CFRunLoopSourceContext used to keep the run loop alive.
    private static var blankSourceContext = CFRunLoopSourceContext(
        version: 0, info: nil,
        retain: nil, release: nil, copyDescription: nil,
        equal: nil, hash: nil,
        schedule: nil, cancel: nil,
        perform: { _ in })
}
