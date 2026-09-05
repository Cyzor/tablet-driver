// SPDX-License-Identifier: GPL-3.0-or-later
//
// Prints the signed tilt any driver puts on the macOS event stream.
//
// Answers "which way is +Y?" objectively, without trusting an application's
// rendering or a convention argument: run it under the vendor's own driver,
// lean the pen, and read the sign the system actually receives. Then run it
// under MockTab and compare. Apple documents only magnitude and range for
// kCGTabletEventTiltY, never the sign, so a reference driver's output is the
// only authority available.
//
// Build:  swiftc -O tools/tilt_event_probe.swift -o /tmp/tilt_event_probe
// Run:    /tmp/tilt_event_probe          (needs Accessibility permission)
//
// Reports the extreme reached in each direction, so a deliberate lean to the
// mechanical stop yields the signed value at full deflection.

import Cocoa

final class Probe {
    private var minX = 0.0, maxX = 0.0, minY = 0.0, maxY = 0.0
    private var samples = 0
    private var lastPrint = Date.distantPast

    func consume(_ e: NSEvent) {
        // Tablet data rides both dedicated tablet events and mouse events
        // carrying a tablet subtype; ignore anything without pen data.
        guard e.subtype == .tabletPoint || e.type == .tabletPoint else { return }
        let t = e.tilt
        guard t.x != 0 || t.y != 0 else { return }

        samples += 1
        minX = Swift.min(minX, t.x); maxX = Swift.max(maxX, t.x)
        minY = Swift.min(minY, t.y); maxY = Swift.max(maxY, t.y)

        if Date().timeIntervalSince(lastPrint) > 0.1 {
            lastPrint = Date()
            let dirX = t.x > 0.05 ? "EAST" : (t.x < -0.05 ? "WEST" : "  --")
            let dirY = t.y > 0.05 ? "  +Y" : (t.y < -0.05 ? "  -Y" : "  --")
            print(String(format: "tilt  x=%+6.3f %@   y=%+6.3f %@", t.x, dirX, t.y, dirY))
            fflush(stdout)
        }
    }

    func summary() {
        print("\n--- extremes over \(samples) samples ---")
        print(String(format: "  X: %+.3f .. %+.3f", minX, maxX))
        print(String(format: "  Y: %+.3f .. %+.3f", minY, maxY))
        print("""

        Lean the pen to its stop in each direction, note the sign:
          north (away from you) -> Y was ____
          south (toward you)    -> Y was ____
        Run again under the other driver and compare. Matching signs mean
        matching polarity; opposite signs mean one of them inverts.
        """)
    }
}

// Global so the C signal handler, which cannot capture context, can reach it.
let probe = Probe()
func handleInterrupt(_ sig: Int32) {
    probe.summary()
    exit(0)
}

guard AXIsProcessTrusted() else {
    print("Needs Accessibility permission: System Settings > Privacy & Security")
    print("> Accessibility, then add the terminal running this.")
    exit(1)
}

print("Reading tablet events. Lean the pen to its stops. Ctrl-C when done.\n")

NSEvent.addGlobalMonitorForEvents(
    matching: [.tabletPoint, .mouseMoved, .leftMouseDragged, .leftMouseDown]
) { probe.consume($0) }

signal(SIGINT, handleInterrupt)

NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
