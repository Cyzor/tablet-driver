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
/// Within the EA family, pens produce two sub-types depending on model/firmware:
///   0xEA sub-type (bit 3 set):  rawPressure reflects actual tip force.
///   0xE2/0xE3 sub-type (bit 3 clear): may carry rawPressure OR may be zero-force
///     position frames interleaved with 0xEA frames while the tip is down.
///   Some pens (e.g. a noisy/aging sensor) emit non-zero rawPressure in 0xEA
///   frames even while hovering above the surface — rawPressure alone cannot
///   reliably discriminate hover from contact for these pens.
///
/// Hover detection via report[9] hover-distance field:
///   report[9] is packed as [hover_dist:6][x_lsb:1][y_lsb:1].
///   hover_dist == 0  →  pen tip is physically touching the surface.
///   hover_dist  > 0  →  pen is hovering above the surface.
///   This field is the ground-truth contact signal and is used to:
///     • Reset the e0 counter in EA frames when touching, so rawPressure>0 from
///       a noisy sensor while hovering does NOT prevent HOVER from firing.
///     • Reset the e0 counter in E0 frames when touching, so pens that send only
///       ONE EA-pressure frame per contact (then E0-only while pressing) remain
///       clicked for the full duration of the stroke.
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
    // EA frame with rawPressure >= tipContactThreshold → set to rawPressure
    // EA frame with rawPressure < tipContactThreshold → set to 0
    // E0 frames don't update this; they use the latched value.
    private var lastEAPressure = 0

    // Minimum rawPressure for a valid tip-contact event.  Values below this are
    // in the hover / proximity zone — the pen is near the surface but not touching.
    // Source: Wacom driver prefs (com.wacom.wacomtablet.prefs) for the DTK-2400:
    //   PressureCurveControlPoint = "81 0 1023 1023 2047 2047"
    //   UpperPressureThreshold    = 81
    // The curve output is 0 at rawPressure=81 and rises from there; below 81 is
    // hover/proximity with no real contact force registered.  Both working pens
    // (PlumpBarrel 0x24809081, SlenderRattle 0x21801d4e) use this same threshold.
    private static let tipContactThreshold = 81

    // Button state for injection, computed as the OR of the current and previous
    // E0-type frame's button bits.  The DTK-2400 ping-pongs between two E0 sub-types
    // even while a button is physically held: one sub-type carries the button bit set
    // (e.g. 0xE4) and the next has it clear (0xE0), alternating at ~30 Hz.  A direct
    // assignment would cause rapid true/false oscillation visible to InputInjector as
    // dozens of button-down/up events per second ("barrel buttons barely behave").
    // The 2-frame OR: button stays true as long as either of the last two E0-type frames
    // had the bit set; it clears only after two consecutive frames with it clear.
    private var lastButton1: Bool = false
    private var lastButton2: Bool = false
    private var prevE0Button1: Bool = false
    private var prevE0Button2: Bool = false

    // Per-proximity diagnostic flag: did we receive any EA frame this session?
    // Printed once so we can detect pens that generate no EA frames at all.
    private var seenEAThisProximity = false

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
            lastButton1 = false
            lastButton2 = false
            seenEAThisProximity = false
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
            let rawPressure = (Int(report[6]) << 3) | ((Int(report[7] & 0xC0)) >> 5) | (Int(report[1]) & 1)

            // One-shot per-proximity diagnostic — detects pens with no EA pressure output.
            if !seenEAThisProximity {
                seenEAThisProximity = true
                print(String(format: "DTK-2400 FIRST-EA  status=%02X report[6]=%d rawPressure=%d",
                             status, report[6], rawPressure))
            }

            // Map rawPressure through tipContactThreshold.
            // >= threshold: pen pressing → output pressure
            // < threshold: pen hovering or sub-threshold interleave → output zero
            // No hover detection timeouts. Just stream the current pressure state.
            if rawPressure >= Self.tipContactThreshold {
                if lastEAPressure == 0 {
                    print(String(format: "DTK-2400 EA PRESS  status=%02X rawPressure=%d norm=%.1f%%",
                                 status, rawPressure, Double(rawPressure) / 20.47))
                }
                lastEAPressure = rawPressure
            } else {
                // Sub-threshold EA frame: clear pressure output.
                if lastEAPressure > 0 {
                    print(String(format: "DTK-2400 EA RELEASE rawPressure=%d (below threshold %d)",
                                 rawPressure, Self.tipContactThreshold))
                }
                lastEAPressure = 0
            }

        } else {
            // E0 frame: update button state via 2-frame OR to smooth ping-pong alternation.
            // While a button is held, the device alternates between a frame with the button
            // bit set (e.g. 0xE4) and a frame with it clear (0xE0) at ~30 Hz.  A direct
            // assignment would make lastButton1 oscillate true/false/true/false, causing
            // InputInjector to fire dozens of button-down/up events per second.  The OR of
            // the current frame and the previous E0-type frame holds the state true for the
            // entire duration and clears it only after two consecutive frames with the bit
            // unset (i.e. genuinely released).
            let curButton1 = (status & 0x04) != 0
            let curButton2 = (status & 0x10) != 0
            let newButton1 = curButton1 || prevE0Button1
            let newButton2 = curButton2 || prevE0Button2
            if newButton1 != lastButton1 || newButton2 != lastButton2 {
                print(String(format: "DTK-2400 E0 BUTTON status=%02X btn1=%d btn2=%d",
                             status, newButton1 ? 1 : 0, newButton2 ? 1 : 0))
            }
            lastButton1  = newButton1
            lastButton2  = newButton2
            prevE0Button1 = curButton1
            prevE0Button2 = curButton2
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
