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

import Foundation
import IOKit.hid

/// Wacom Cintiq 24HD (DTK-2400) — IntuosV1 HID report format.
/// VendorID: 0x056A  ProductID: 0x00F4  InputReportLength: 10 bytes
///
/// Coordinate space: maxX=104480, maxY=65600, maxPressure=2047 (11-bit).
/// Active area covers the full 1920×1200 display surface.
///
/// **Status byte (report[1]) encoding — per Linux kernel wacom_wac.c WACOM_24HD:**
///   bit 0: tip switch (BTN_TOUCH); also the pressure LSB in the 11-bit formula
///   bit 1: barrel button 1 (BTN_STYLUS)
///   bit 2: barrel button 2 (BTN_STYLUS2)
///   bits 7:5: 111 when in proximity (base value 0xE0)
///
/// **Packet type nibble:** `(status >> 1) & 0x0F`  — from `wacom_intuos_general()`
///   0x00–0x03: general pen packet (position, pressure, tilt, all buttons)
///   0x05:      Art Pen / Marker Pen rotation packet  (no fresh position)
///   0x0A:      Airbrush second packet (wheel + tilt)
///
/// **Tool-change packets:** status 0xC0–0xC3 (bits 7:2 == 0b110000) on enter prox.
///   Bytes 2–7 carry packed serial number and tool code per IntuosV1 protocol.
///   Eraser detected via tool_id bit 3: `toolCode & 0x0008 != 0`.
///
/// **Barrel button debounce:** the device pulses the barrel button bit approximately
///   1:5 (set:clear) while a button is held.  Clear-counter threshold of 7 survives
///   the gap without false release.
final class DTK2400Device: TabletDevice {

    let spec = DigitizerSpec(maxX: 104480, maxY: 65600, maxPressure: 2047)

    private let device: IOHIDDevice
    private let onTablet: (TabletPoint) -> Void
    private let onAux: ((AuxButtons) -> Void)?
    private let onToolEnter: ((ToolIdentity) -> Void)?
    private var reportBuffer = [UInt8](repeating: 0, count: 10)

    // ── Position and pen state ───────────────────────────────────────────────
    private var lastX = 0
    private var lastY = 0
    private var lastPressure = 0
    private var lastTiltX = 0
    private var lastTiltY = 0
    private var lastRotation: Double = 0.0
    private var lastHoverDistance = 0

    // ── Tip-switch (Report ID 0x01) ─────────────────────────────────────────
    private var lastTipSwitch: Bool = false
    // Minimum synthetic pressure injected when tip-switch fires but 0x02 pressure
    // reads zero (grip-pen bare-tap; hardware limitation).
    private static let tipContactThreshold = 81

    // ── Button debounce ─────────────────────────────────────────────────────
    private var lastButton1: Bool = false
    private var lastButton2: Bool = false
    private var btn1ClearCount = 0
    private var btn2ClearCount = 0
    private static let buttonClearThreshold = 7

    // ── Tool identity ────────────────────────────────────────────────────────
    private var currentSerial: UInt32 = 0
    private var currentToolCode: UInt16 = 0
    private var isEraser: Bool = false

    init(
        device: IOHIDDevice,
        onTablet: @escaping (TabletPoint) -> Void,
        onAux: ((AuxButtons) -> Void)? = nil,
        onToolEnter: ((ToolIdentity) -> Void)? = nil
    ) {
        self.device = device
        self.onTablet = onTablet
        self.onAux = onAux
        self.onToolEnter = onToolEnter
    }

    func open() {
        // Seize to prevent macOS from processing Report ID 0x01 (tip-switch →
        // left click) as native mouse events.  Without seizure, the system fires
        // phantom left-clicks independently of our pressure logic.
        let ret = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard ret == kIOReturnSuccess else {
            print("DTK-2400: failed to seize device (\(ret)). Is another tablet driver running?")
            return
        }

        // Feature init [0x02, 0x02]: activates the digitiser endpoint (same as PTH-851).
        var initBytes: [UInt8] = [0x02, 0x02]
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0x02, &initBytes, initBytes.count)

        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, &reportBuffer, reportBuffer.count,
            DTK2400Device.reportCallback, ctx)
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetCurrent(),
            RunLoop.Mode.common.rawValue as CFString)
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(
            device, CFRunLoopGetCurrent(),
            RunLoop.Mode.common.rawValue as CFString)
        IOHIDDeviceRegisterInputReportCallback(device, &reportBuffer, reportBuffer.count, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    }

    // MARK: - C callback

    private static let reportCallback: IOHIDReportCallback = { ctx, _, _, _, _, report, length in
        guard let ctx else { return }
        Unmanaged<DTK2400Device>.fromOpaque(ctx).takeUnretainedValue()
            .handleReport(report: report, length: length)
    }

    private func handleReport(report: UnsafePointer<UInt8>, length: CFIndex) {
        HIDCapture.shared.record(tag: "DTK-2400", report: report, length: length)
        guard length >= 2 else { return }

        let id = report[0]

        // ── Report 0x01: mouse-compatible collection — physical tip-switch ──
        if id == 0x01 {
            handleTipSwitch(report: report, length: length)
            return
        }

        // ── Report 0x0C: express keys + touch rings ──────────────────────────
        if id == 0x0C {
            handleExpressKeys(report: report, length: length)
            return
        }

        // WACOM_24HD pen reports use only Report ID 0x02.
        guard length >= 10, id == 0x02 else { return }

        let status = report[1]

        // ── Tool-change packet: status bits 7:2 == 0b110000 (enter prox) ────
        if (status & 0xFC) == 0xC0 {
            handleToolChange(report: report)
            return
        }

        let inProximity = (status & 0x20) != 0  // bit 5

        // ── Proximity-out ────────────────────────────────────────────────────
        if !inProximity {
            resetProximityState()
            onTablet(
                TabletPoint(
                    x: lastX, y: lastY, maxX: spec.maxX, maxY: spec.maxY,
                    pressure: 0, maxPressure: spec.maxPressure,
                    tiltX: 0, tiltY: 0, rotation: 0.0,
                    penButton1: false, penButton2: false,
                    eraser: isEraser, inProximity: false, hoverDistance: 0))
            return
        }

        // ── Barrel buttons from every in-proximity frame ─────────────────────
        // Kernel: BTN_STYLUS = d[1] & 0x02, BTN_STYLUS2 = d[1] & 0x04.
        // The device pulses the bit ~1:5 while held; debounce with clear-counter.
        let curBtn1 = (status & 0x02) != 0
        let curBtn2 = (status & 0x04) != 0

        if curBtn1 {
            btn1ClearCount = 0
            lastButton1 = true
        } else {
            btn1ClearCount += 1
            if btn1ClearCount >= Self.buttonClearThreshold { lastButton1 = false }
        }
        if curBtn2 {
            btn2ClearCount = 0
            lastButton2 = true
        } else {
            btn2ClearCount += 1
            if btn2ClearCount >= Self.buttonClearThreshold { lastButton2 = false }
        }

        // ── Packet type nibble: (status >> 1) & 0x0F ─────────────────────────
        let typeNibble = (Int(status) >> 1) & 0x0F

        if typeNibble == 0x05 {
            // ── Art Pen / Marker Pen rotation packet ─────────────────────────
            // Kernel formula (wacom_intuos_general, type 0x05):
            //   t = (d[6]<<3) | ((d[7]>>5) & 7)
            //   ABS_Z = (d[7]&0x20) ? ((t>900) ? (t-1)/2-1350 : (t-1)/2+450) : 450-t/2
            // ABS_Z range: -900..+899 in 0.5° steps; map to 0–360°.
            let t = (Int(report[6]) << 3) | ((Int(report[7]) >> 5) & 7)
            let absZ: Int
            if (report[7] & 0x20) != 0 {
                absZ = (t > 900) ? ((t - 1) / 2 - 1350) : ((t - 1) / 2 + 450)
            } else {
                absZ = 450 - t / 2
            }
            // absZ is in [-900, +899]; shift to [0, 1799], scale to 0–360°.
            var degrees = Double(absZ + 900) / 1800.0 * 360.0
            if degrees < 0 { degrees += 360.0 }
            if degrees >= 360 { degrees -= 360.0 }
            lastRotation = degrees

        } else if typeNibble <= 0x03 {
            // ── General pen packet: position, pressure, tilt ──────────────────
            // Kernel: X = (BE16(d2:d3)<<1) | ((d9>>1)&1) — 17-bit
            let x = ((Int(report[3]) | Int(report[2]) << 8) << 1) | ((Int(report[9]) >> 1) & 1)
            let y = ((Int(report[5]) | Int(report[4]) << 8) << 1) | (Int(report[9]) & 1)

            // Kernel: pressure = (d6<<3) | ((d7&0xC0)>>5) | (d1&1) — 11-bit, max 2047
            let rawPressure =
                (Int(report[6]) << 3)
                | ((Int(report[7]) & 0xC0) >> 5)
                | (Int(status) & 1)

            // Hover distance: top 6 bits of report[9]; bottom 2 bits are X/Y LSBs.
            let hoverDist = Int(report[9]) >> 2

            // Kernel tilt formula (signed, ±63):
            //   tiltX = (((d7<<1) & 0x7E) | (d8>>7)) - 64
            //   tiltY = (d8 & 0x7F) - 64
            let tiltXRaw = (((Int(report[7]) << 1) & 0x7E) | (Int(report[8]) >> 7)) - 64
            let tiltYRaw = (Int(report[8]) & 0x7F) - 64

            lastX = x
            lastY = y
            lastPressure = rawPressure
            lastHoverDistance = hoverDist
            lastTiltX = tiltXRaw
            lastTiltY = tiltYRaw
        }
        // type 0x0A (airbrush wheel) — not yet decoded; falls through using cached state.

        onTablet(
            TabletPoint(
                x: lastX, y: lastY, maxX: spec.maxX, maxY: spec.maxY,
                pressure: lastPressure, maxPressure: spec.maxPressure,
                tiltX: Double(lastTiltX) / 63.0,
                tiltY: Double(lastTiltY) / 63.0,
                rotation: lastRotation,
                penButton1: lastButton1,
                penButton2: lastButton2,
                eraser: isEraser,
                inProximity: true,
                hoverDistance: lastHoverDistance))
    }

    // MARK: - Report 0x01: physical tip-switch

    private func handleTipSwitch(report: UnsafePointer<UInt8>, length: CFIndex) {
        let tipDown = (report[1] & 0x01) != 0
        guard tipDown != lastTipSwitch else { return }
        lastTipSwitch = tipDown

        if tipDown {
            // Safety net: if pressure formula hasn't crossed the contact threshold yet
            // (grip-pen bare-tap hardware limitation), inject minimum contact pressure.
            if lastPressure == 0 {
                lastPressure = Self.tipContactThreshold
            }
        } else {
            lastPressure = 0
        }
    }

    // MARK: - Report 0x0C: touch rings + express keys
    //
    // Confirmed layout (live capture + Linux kernel wacom_wac.c wacom_intuos_pad):
    //   byte[1] — left  touch ring: raw absolute position, 0 = no contact, 1–255 = position
    //   byte[2] — right touch ring: same encoding as byte[1]
    //   byte[6] — express keys: bits 0–3 = left keys 0–3, bits 4–7 = right keys 4–7
    //   byte[8] — right-side buttons 8–15 (bits 0–7); 0 if only 8 buttons present
    //   bytes[3–5], [7], [9] — unused
    //
    // Ring positions are normalized from 0–255 to 0–71 to match the injector's
    // 72-step wrap-aware delta logic.

    private func handleExpressKeys(report: UnsafePointer<UInt8>, length: CFIndex) {
        guard length >= 7, let onAux = onAux else { return }

        let leftRingRaw = report[1]
        let leftRingActive = leftRingRaw != 0
        let leftRingPos = leftRingActive ? UInt8(Int(leftRingRaw) * 72 / 256) : UInt8(0x7F)

        let rightRingRaw = report[2]
        let rightRingActive = rightRingRaw != 0
        let rightRingPos = rightRingActive ? UInt8(Int(rightRingRaw) * 72 / 256) : UInt8(0x7F)

        // Left  buttons 0–7:  byte[6] bits 0–7
        // Right buttons 8–15: byte[8] bits 0–7  (kernel formula: (data[8]<<8)|data[6])
        let leftByte = report[6]
        let rightByte = length >= 9 ? report[8] : 0
        let buttons =
            (0..<8).map { bit in (leftByte & (1 << bit)) != 0 }
            + (0..<8).map { bit in (rightByte & (1 << bit)) != 0 }

        onAux(
            AuxButtons(
                buttons: buttons,
                touchRingActive: leftRingActive,
                touchRingPosition: leftRingPos,
                touchRing2Active: rightRingActive,
                touchRing2Position: rightRingPos))
    }

    // MARK: - Tool-change packet (status bits 7:2 == 0xC0)

    private func handleToolChange(report: UnsafePointer<UInt8>) {
        let serial =
            UInt32(report[3] & 0x0F) << 28
            | UInt32(report[4]) << 20
            | UInt32(report[5]) << 12
            | UInt32(report[6]) << 4
            | UInt32(report[7]) >> 4
        let toolCode =
            UInt16(report[2]) << 4
            | UInt16(report[3]) >> 4
            | UInt16(report[7] & 0x0F) << 12
            | UInt16(report[8] & 0xF0) << 4

        currentSerial = serial
        currentToolCode = toolCode
        // Kernel (wacom_intuos_get_tool_type): eraser detected by tool_id bit 3.
        isEraser = (toolCode & 0x0008) != 0

        onToolEnter?(
            ToolIdentity(
                serial: serial,
                toolCode: toolCode,
                isEraser: isEraser,
                isMouse: false))
    }

    // MARK: - State reset

    private func resetProximityState() {
        lastPressure = 0
        lastTipSwitch = false
        lastButton1 = false
        lastButton2 = false
        lastRotation = 0.0
        lastTiltX = 0
        lastTiltY = 0
        lastHoverDistance = 0
        btn1ClearCount = 0
        btn2ClearCount = 0
    }
}
