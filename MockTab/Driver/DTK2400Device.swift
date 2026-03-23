import Foundation
import IOKit.hid

/// Wacom Cintiq 24HD (DTK-2400) — IntuosV1 HID report format.
/// VendorID: 0x056A  ProductID: 0x00F4  InputReportLength: 10 bytes
///
/// Coordinate space confirmed by live probe (WacomProbeDevice):
///   maxX = 104480  (pen reached 104253 at right bezel; Linux input-wacom: 104480)
///   maxY =  65600  (clean firmware plateau)
///   maxPressure = 2047  (11-bit field, same formula as PTH-851)
///
/// The Cintiq 24HD is a pen display: its active area covers the full 1920×1200 screen
/// surface.  On first connection `proportionalMapping` is disabled and `targetDisplayIndex`
/// is set to the matching display automatically.
///
/// EA/E0 alternating report pattern (unique to Cintiq 24HD):
///   Status bit 1 (0x02) is the EA/E0 discriminator — NOT barrel button 1.
///   EA reports (bit 1 set): carry real pressure in report[6].
///   E0 reports (bit 1 clear): carry barrel-button bits in status; report[6]=0.
///
/// Within the EA family, two sub-types exist (per OTD IntuosV1ReportParser and
/// linux input-wacom):
///   0xEA sub-type (bits 1+3 set):  Art Pen ROTATION frame — report[6..7] carries
///     barrel rotation angle, NOT tip pressure.  Decoding as pressure yields the
///     pen's neutral rotation offset (~80–86), straddling tipContactThreshold.
///   0xE2/0xE3 sub-type (bit 1 set, bit 3 clear): Normal PRESSURE frame —
///     report[6..7] carries real 11-bit tip pressure.  Some pens interleave
///     zero-pressure 0xE2 sub-frames while actively pressing (do not clear
///     lastEAPressure on rawPressure==0).
///
/// Hover detection:
///   E0-frame counter: counts E0 frames since the last contact-zone pressure EA.
///   After hoverE0Threshold frames without a confirming pressure EA, force pressure
///   release.  Rotation frames (0xEA) are transparent to this counter — they do NOT
///   reset it, so an Art Pen that lifts mid-stroke still triggers HOVER.
///
///   report[9] hover-distance field is unreliable on tested pens (constant 20–45,
///   never reaching 0 on contact).  It is still passed through as hoverDistance for
///   possible future use but is NOT used for contact/hover decisions.
///
///   Do NOT rely on rawPressure==0 in an EA frame to signal pen lift — some pens
///   interleave zero-pressure 0xE2 EA sub-frames while actively pressing, causing
///   rapid mouseDown/mouseUp oscillation if we cleared pressure there.
///
/// Status byte bit assignments (confirmed unless noted):
///   Bit 1 (0x02): EA/E0 discriminator
///   Bit 2 (0x04): barrel button 1  ← confirmed via live capture
///   Bit 4 (0x10): barrel button 2  ← unverified; remove this note once confirmed
///   Bit 5 (0x20): in-proximity
///   Bit 6 (0x40): high-confidence (position quality)
final class DTK2400Device: TabletDevice {

    let spec = DigitizerSpec(maxX: 104480, maxY: 65600, maxPressure: 2047)

    private let device: IOHIDDevice
    private let onTablet: (TabletPoint) -> Void
    private let onAux: ((AuxButtons) -> Void)?
    private var reportBuffer = [UInt8](repeating: 0, count: 10)
    private var lastX = 0
    private var lastY = 0

    // Pressure state carried forward from most recent EA frame.
    // Set when EA frame has hoverDist==0 (contact confirmed) AND rawPressure >= threshold.
    // Cleared when hover detected or E0 counter expires.
    private var lastEAPressure = 0

    // E0 frame counter: incremented on each E0, reset when contact-zone EA arrives.
    // When counter >= hoverE0Threshold (no contact EA for N frames), force pressure release.
    private var e0FramesSinceLastContact = 0

    // E0 release threshold: if this many E0 frames pass without a contact-confirming EA,
    // the pen has lifted.
    //
    // The DTK-2400 has ≥12 E0 frames between consecutive EA frames during normal
    // pressing — threshold must be well above 12 to avoid false HOVER mid-stroke.
    //
    // For Grip Pen (pen:E2): EA RELEASE (rawPressure drops to hover zone 1..80) handles
    //   normal pen lift.  The E0 counter is only a safety net for edge cases where no
    //   hover-zone EA frame arrives before proximity-out.
    //
    // For Art Pen (pen:EA): E0 HOVER IS the primary release mechanism — when the pen
    //   lifts, pressure frames stop and only rotation + E0 continue.  The counter fires
    //   after the pen stops sending contact-zone pressure EA frames.
    //
    // At ~130 Hz E0 rate, 30 frames ≈ 230 ms — fast enough release for Art Pen,
    // well above the ~12 natural E0 gap for Grip Pen.
    private static let hoverE0Threshold = 30

    // Minimum rawPressure for a valid tip-contact event.  Values below this are
    // in the hover / proximity zone — the pen is near the surface but not touching.
    // Source: Wacom driver prefs (com.wacom.wacomtablet.prefs) for the DTK-2400:
    //   PressureCurveControlPoint = "81 0 1023 1023 2047 2047"
    //   UpperPressureThreshold    = 81
    // The curve output is 0 at rawPressure=81 and rises from there; below 81 is
    // hover/proximity with no real contact force registered.  Both working pens
    // (PlumpBarrel 0x24809081, SlenderRattle 0x21801d4e) use this same threshold.
    private static let tipContactThreshold = 81

    // Button state for injection, with clear-counter debouncing.
    //
    // The DTK-2400 ping-pongs between two E0 sub-types even while a button is physically
    // held: one sub-type carries the button bit set (e.g. 0xE4) and the next has it clear
    // (0xE0).  A direct assignment causes rapid true/false oscillation → dozens of
    // button-down/up events per second.
    //
    // Debounce: on any E0 frame with the bit set, latch true immediately and reset the
    // clear counter to 0.  On a frame with the bit clear, increment the counter; only
    // release after `buttonClearThreshold` consecutive clear frames (~45 ms at 66 Hz).
    // This survives up to (threshold−1) consecutive clear frames without false release.
    private var lastButton1: Bool = false
    private var lastButton2: Bool = false
    private var btn1ClearCount = 0
    private var btn2ClearCount = 0
    // Within the E0 stream, the device's E4/E0 sub-pattern places exactly 3
    // consecutive clear (E0) frames between each button-set (E4) frame.
    // Threshold must exceed 3 to avoid releasing during normal holds.
    // 5 gives margin and still releases in ~38 ms at 130 Hz.
    private static let buttonClearThreshold = 5

    // Per-proximity diagnostic flag: did we receive any EA frame this session?
    // Printed once so we can detect pens that generate no EA frames at all.
    private var seenEAThisProximity = false

    // Per-proximity pen label, derived from the first EA status byte seen.
    // E.g. "pen:E2" for SlenderRattle (sub-type), "pen:EA" for standard EA pens.
    // Prefixed on all diagnostic prints so different pens are distinguishable in the console.
    private var penLabel = "pen:??"

    // Rotation frame sub-counter: tracks how many 0xEA / 0xEB rotation frames
    // arrive vs normal 0xE2 / 0xE3 pressure frames per proximity session.
    // Printed once at proximity-exit so we can confirm whether a pen is an Art Pen
    // (mostly rotation) or a standard Grip Pen (no rotation frames).
    private var rotationFrameCount = 0
    private var pressureFrameCount = 0

    init(device: IOHIDDevice,
         onTablet: @escaping (TabletPoint) -> Void,
         onAux: ((AuxButtons) -> Void)? = nil)
    {
        self.device = device
        self.onTablet = onTablet
        self.onAux = onAux
    }

    func open() {
        // Seize the device so macOS's built-in IOHIDEventDriver stops processing it.
        // The Cintiq 24HD descriptor includes a mouse-compatible collection (Report ID 1,
        // tip-switch → left button).  Without seizure the system fires spurious left-click
        // CGEvents from the pen's tip-switch independently of our pressure logic, causing
        // rapid phantom clicks whenever the pen is near the surface.
        // kIOHIDOptionsTypeSeizeDevice also prevents a second DTK2400Device from being
        // created if the OS exposes two IOHIDDevice entries for the same interface.
        let ret = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard ret == kIOReturnSuccess else {
            print("DTK-2400: failed to seize device (\(ret)). Is another tablet driver running?")
            return
        }

        // Feature init: [0x02, 0x02] — activates the digitiser endpoint.
        // Identical to PTH-851; confirmed working by probe session.
        var initBytes: [UInt8] = [0x02, 0x02]
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0x02, &initBytes, initBytes.count)

        let ctx = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, &reportBuffer, reportBuffer.count,
                                              DTK2400Device.reportCallback, ctx)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(),
                                       RunLoop.Mode.common.rawValue as CFString)
    }

    func close() {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(),
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
        guard length >= 10 else { return }

        // Report IDs seen on this device: 0x02 (pen), 0x0C (touch/ring — ignored here).
        let id = report[0]
        guard id == 0x02 || id == 0x10 else {
            // Phase 1 serial probe: log any report ID we don't recognise.
            let hex = (0..<Swift.min(Int(length), 20))
                .map { String(format: "%02X", report[$0]) }.joined(separator: " ")
            print("DTK-2400 UNKNOWN REPORT id=\(String(format:"0x%02X", id)) len=\(length): \(hex)")
            return
        }

        let status      = report[1]
        let inProximity = (status & 0x20) != 0  // bit 5
        let highConf    = (status & 0x40) != 0  // bit 6

        if !inProximity {
            lastEAPressure = 0
            e0FramesSinceLastContact = 0
            lastButton1 = false
            lastButton2 = false
            btn1ClearCount = 0
            btn2ClearCount = 0
            if seenEAThisProximity {
                print(String(format: "DTK-2400 [\(penLabel)] PROX-OUT  pressureFrames=%d rotationFrames=%d",
                             pressureFrameCount, rotationFrameCount))
            }
            seenEAThisProximity = false
            penLabel = "pen:??"
            rotationFrameCount = 0
            pressureFrameCount = 0
            onTablet(TabletPoint(x: lastX, y: lastY, maxX: spec.maxX, maxY: spec.maxY,
                                 pressure: 0, maxPressure: spec.maxPressure,
                                 tiltX: 0, tiltY: 0,
                                 penButton1: false, penButton2: false,
                                 eraser: false, inProximity: false, hoverDistance: 0))
            return
        }
        // Low-confidence: position unreliable — emit zero-pressure so mouseUp fires.
        // Use latched button state; highConf is a position-quality flag independent
        // of which physical buttons are held.
        guard highConf else {
            onTablet(TabletPoint(x: lastX, y: lastY, maxX: spec.maxX, maxY: spec.maxY,
                                 pressure: 0, maxPressure: spec.maxPressure,
                                 tiltX: 0, tiltY: 0,
                                 penButton1: lastButton1,
                                 penButton2: lastButton2,
                                 eraser: false, inProximity: true, hoverDistance: 0))
            return
        }

        // IntuosV1 coordinate / pressure / tilt decode — identical to PTH851Device.
        let x        = ((Int(report[3]) | Int(report[2]) << 8) << 1) | ((Int(report[9]) >> 1) & 1)
        let y        = ((Int(report[5]) | Int(report[4]) << 8) << 1) | (Int(report[9]) & 1)

        // EA/E0 alternating report pattern unique to the Cintiq 24HD:
        //   EA frames (bit 1 set):  pressure channel.
        //   E0 frames (bit 1 clear): button-state channel.  report[6] always 0.
        //
        // Hover detection: the e0 counter is reset ONLY by EA frames whose rawPressure
        // is in the contact zone (≥ tipContactThreshold).  When the pen lifts, EA frames
        // drop into the hover zone (< tipContactThreshold) and stop resetting the counter.
        // After hoverE0Threshold E0 frames the counter fires HOVER and clears pressure.
        //
        // We do NOT rely on the report[9] hover-distance field for this decision: E0
        // frames appear to be lightweight button-state packets that do not carry a valid
        // hover-distance reading (the field reads 0 regardless of pen position), so
        // testing it in E0 frames would permanently suppress HOVER and cause sticky release.
        //
        // We do NOT clear lastEAPressure on zero-pressure EA sub-frames (e.g. 0xE2):
        // some pen models interleave zero-pressure 0xE2 sub-frames while actively
        // pressing, and clearing pressure there would cause rapid mouseDown/mouseUp chatter.
        let isEA = (status & 0x02) != 0

        if isEA {
            // Art Pen rotation detection (from OTD IntuosV1ReportParser + linux input-wacom):
            // When bits 1 AND 3 are both set (e.g. 0xEA, 0xEB), the EA frame carries
            // barrel rotation angle in report[6..7], NOT tip pressure.  Decoding report[6..7]
            // as pressure produces the pen's neutral rotation offset (~80–86 on the DTK-2400),
            // which straddles tipContactThreshold and causes phantom contact events.
            //
            // Standard pens (Grip Pen) set bit 1 but NOT bit 3 (e.g. 0xE2, 0xE3) — these
            // carry real tip pressure in report[6..7] and are decoded normally.
            let isRotation = (status & 0x0A) == 0x0A  // bits 1+3 both set

            // One-shot per-proximity diagnostic.
            if !seenEAThisProximity {
                seenEAThisProximity = true
                penLabel = String(format: "pen:%02X", status)
                let hex = (0..<10).map { String(format: "%02X", report[$0]) }.joined(separator: " ")
                print(String(format: "DTK-2400 [\(penLabel)] FIRST-EA  status=%02X rotation=%d bytes=[%@]",
                             status, isRotation ? 1 : 0, hex))
            }

            if isRotation {
                // Art Pen rotation frame — report[6..7] is rotation angle, not pressure.
                // Do NOT decode rawPressure.  Do NOT update lastEAPressure.
                // Do NOT reset e0FramesSinceLastContact — rotation frames are transparent
                // to the pressure/hover state machine.  If lastEAPressure is latched from
                // a previous contact-zone pressure frame, the E0 counter will still fire
                // HOVER when the pen lifts (rotation frames don't suppress it).
                rotationFrameCount += 1

            } else {
                // Normal pressure frame (e.g. 0xE2, 0xE3).
                pressureFrameCount += 1
                let rawPressure = (Int(report[6]) << 3) | ((Int(report[7] & 0xC0)) >> 5) | (Int(report[1]) & 1)

                // State machine: rawPressure as contact signal; E0 counter detects lift.
                if rawPressure >= Self.tipContactThreshold {
                    // Pen tip pressing with real contact force.
                    if lastEAPressure == 0 {
                        let hex = (0..<10).map { String(format: "%02X", report[$0]) }.joined(separator: " ")
                        print(String(format: "DTK-2400 [\(penLabel)] EA PRESS  status=%02X rawPressure=%d norm=%.1f%% bytes=[%@]",
                                     status, rawPressure, Double(rawPressure) / 20.47, hex))
                    }
                    lastEAPressure = rawPressure
                    e0FramesSinceLastContact = 0  // reset E0 hover counter on confirmed contact
                } else if rawPressure == 0 {
                    // rawPressure==0 exactly: zero-pressure interleave sub-frame (e.g. 0xE2 sub-type).
                    // Do NOT clear lastEAPressure — some pens (e.g. SlenderRattle 0x21801D4E)
                    // alternate contact EA frames with rawPressure=0 inert sub-frames while pressing.
                    // Clearing here would cause rapid PRESS/RELEASE oscillation on every EA pair.
                    //
                    // DO reset the E0 counter — this EA frame proves the pen is still actively
                    // reporting, even though this particular sub-frame carries no pressure data.
                    // Without this reset, the counter accumulates across two consecutive E0 batches
                    // (6 E0s before the interleave + 6 after = 12) and fires E0 HOVER mid-tap.
                    e0FramesSinceLastContact = 0
                } else {
                    // rawPressure in hover zone (1..tipContactThreshold-1): pen is near but not touching.
                    // Clear pressure so mouseUp fires on genuine lift.
                    if lastEAPressure > 0 {
                        print(String(format: "DTK-2400 [\(penLabel)] EA RELEASE rawPressure=%d (hover zone) → pressure cleared",
                                     rawPressure))
                    }
                    lastEAPressure = 0
                }
            }

        } else {
            // E0 frame: update button state with clear-counter debouncing.
            // The device ping-pongs E4/E0 at ~30 Hz even while a button is held.
            // Button latches true on any E4 frame; requires buttonClearThreshold
            // consecutive E0-no-button frames to release (~45 ms at 66 Hz).
            let curButton1 = (status & 0x04) != 0
            let curButton2 = (status & 0x10) != 0

            if curButton1 {
                btn1ClearCount = 0
                if !lastButton1 {
                    print(String(format: "DTK-2400 [\(penLabel)] E0 BUTTON btn1=DOWN status=%02X", status))
                    lastButton1 = true
                }
            } else {
                btn1ClearCount += 1
                if btn1ClearCount >= Self.buttonClearThreshold && lastButton1 {
                    print(String(format: "DTK-2400 [\(penLabel)] E0 BUTTON btn1=UP   status=%02X (after %d clear frames)",
                                 status, btn1ClearCount))
                    lastButton1 = false
                }
            }

            if curButton2 {
                btn2ClearCount = 0
                if !lastButton2 {
                    print(String(format: "DTK-2400 [\(penLabel)] E0 BUTTON btn2=DOWN status=%02X", status))
                    lastButton2 = true
                }
            } else {
                btn2ClearCount += 1
                if btn2ClearCount >= Self.buttonClearThreshold && lastButton2 {
                    print(String(format: "DTK-2400 [\(penLabel)] E0 BUTTON btn2=UP   status=%02X (after %d clear frames)",
                                 status, btn2ClearCount))
                    lastButton2 = false
                }
            }

            // E0 hover counter: safety net for sparse-EA pens.
            // If lastEAPressure is still latched but we haven't seen a confirming EA frame
            // for too long, force release. This handles pens that send 1 EA then go E0-only.
            if lastEAPressure > 0 {
                e0FramesSinceLastContact += 1
                if e0FramesSinceLastContact >= Self.hoverE0Threshold {
                    print(String(format: "DTK-2400 [\(penLabel)] E0 HOVER  e0streak=%d → pressure cleared (timeout)",
                                 e0FramesSinceLastContact))
                    lastEAPressure = 0
                    e0FramesSinceLastContact = 0
                }
            }
        }

        let pressure = lastEAPressure

        let tiltXRaw = (((Int(report[7]) << 1) & 0x7E) | (Int(report[8]) >> 7)) - 64
        let tiltYRaw = (Int(report[8]) & 0x7F) - 64

        lastX = x
        lastY = y

        onTablet(TabletPoint(
            x: x, y: y, maxX: spec.maxX, maxY: spec.maxY,
            pressure: pressure, maxPressure: spec.maxPressure,
            tiltX: Double(tiltXRaw) / 63.0,
            tiltY: Double(tiltYRaw) / 63.0,
            penButton1: lastButton1,
            penButton2: lastButton2,
            eraser: false,
            inProximity: true,
            hoverDistance: Int(report[9])
        ))
    }
}
