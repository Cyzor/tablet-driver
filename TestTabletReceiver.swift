// TestTabletReceiver.swift — minimal AppKit app to verify NSEvent.rotation propagation
import AppKit

extension FileHandle: @unchecked Sendable {}

var stderr = FileHandle.standardError

func printStderr(_ msg: String) {
    let data = Data((msg + "\n").utf8)
    stderr.write(data)
}

printStderr("*** Starting TestTabletReceiver ***")

// Install monitor immediately, before window creation
NSEvent.addLocalMonitorForEvents(matching: [.tabletPoint, .leftMouseDragged, .mouseMoved]) { event in
    if abs(event.rotation) > 0.01 {
        printStderr(">>> ROTATION DETECTED: \(event.rotation)° pressure=\(event.pressure) tiltX=\(event.tilt.x) tiltY=\(event.tilt.y)")
    }
    return event
}

printStderr("*** Monitor installed ***")

let app = NSApplication.shared

// Create a simple window
let rect = NSRect(x: 200, y: 200, width: 500, height: 200)
let window = NSWindow(contentRect: rect,
                     styleMask: [.titled, .closable, .miniaturizable, .resizable],
                     backing: .buffered, defer: false)
window.title = "TestTabletReceiver — Twist Art Pen"

let label = NSTextField(labelWithString: "Window is active. Twist Art Pen. Check stderr for output.")
label.frame = NSRect(x: 20, y: 150, width: 460, height: 30)
window.contentView?.addSubview(label)

window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

printStderr("*** Window visible. Monitor active. ***")

// Simple quit delegate (keep strong reference)
class QuitDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let quitDelegate = QuitDelegate()
app.delegate = quitDelegate

// Run the app
app.run()
printStderr("*** App exited ***")
