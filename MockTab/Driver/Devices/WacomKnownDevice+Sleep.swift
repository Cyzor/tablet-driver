// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import TabletKit

// The Intuos4 idle cycle: dims, then darkens, the ExpressKey OLEDs through
// report 0x20, as Wacom's driver does. The sleep states, timing and bytes are
// TabletKit's `Intuos4DisplayProperties`; this file runs the timer. Stored
// state lives in the main file, since extensions can't hold it.

private let logger = Logger(subsystem: "com.cyzor.mocktab", category: "driver")

extension WacomKnownDevice {

    /// True for the wired Intuos4 models Wacom's driver dims when idle.
    var supportsSleep: Bool {
        deviceSpec.format == .intuosV1 && !isBluetooth
            && Intuos4DisplayProperties.hasOLEDs(productID: deviceSpec.productID)
    }

    /// Any decoded input: restart the idle clock and wake the displays.
    ///
    /// Runs for every report, so while awake it only stamps the time; the
    /// pending timer sees the newer stamp when it fires and re-arms.
    func noteDeviceActivity() {
        ThreadContract.expectPenThread()
        guard supportsSleep else { return }
        lastActivity = CFAbsoluteTimeGetCurrent()
        guard sleepState != .awake else { return }
        logger.info("\(self.deviceSpec.name, privacy: .public): input — ExpressKey displays awake")
        sleepState = .awake
        setRingLED(index: pendingLEDIndex)
        armSleepTimer()
    }

    /// Schedules the end of the current sleep state, counted from the last input.
    /// Reuses the one timer; deep sleep drops it until input arrives.
    func armSleepTimer() {
        ThreadContract.expectPenThread()
        guard supportsSleep,
            let deadline = Intuos4DisplayProperties.deadline(leaving: sleepState, lastInput: lastActivity)
        else {
            sleepTimer.map { CFRunLoopTimerInvalidate($0) }
            sleepTimer = nil
            return
        }
        let fireDate = max(deadline, CFAbsoluteTimeGetCurrent())
        if let timer = sleepTimer {
            CFRunLoopTimerSetNextFireDate(timer, fireDate)
            return
        }
        // Repeating, so the timer stays valid after firing for the next
        // `SetNextFireDate`; every fire reschedules it explicitly.
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, fireDate, Intuos4DisplayProperties.lightSleepTimerInterval, 0, 0
        ) { [weak self] _ in
            self?.sleepTimerCallBack()
        }
        CFRunLoopAddTimer(HIDThread.shared.runLoop, timer, .commonModes)
        sleepTimer = timer
    }

    /// Steps one sleep state down unless input has moved the deadline. Wacom's
    /// driver allows the same 0.5 s of slack.
    private func sleepTimerCallBack() {
        ThreadContract.expectPenThread()
        if let deadline = Intuos4DisplayProperties.deadline(leaving: sleepState, lastInput: lastActivity),
            CFAbsoluteTimeGetCurrent() + 0.5 < deadline {
            armSleepTimer()
            return
        }
        guard let next = Intuos4DisplayProperties.nextSleepState(after: sleepState) else { return }
        sleepState = next
        logger.info("\(self.deviceSpec.name, privacy: .public): idle — ExpressKey displays \(next == .lightSleep ? "dimmed" : "off", privacy: .public)")
        setRingLED(index: pendingLEDIndex)
        armSleepTimer()
    }
}
