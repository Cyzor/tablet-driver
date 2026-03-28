import AppKit

// WacomShim — headless Apple Events responder for Adobe Photoshop / Illustrator.
//
// Bundle ID: com.wacom.TabletDriver
//
// Adobe queries for a process with this bundle ID before trusting NSEvent
// tablet pressure.  This helper runs as a background-only process alongside
// MockTab and responds to the Apple Events protocol that Wacom's official
// macOS driver exposes.
//
// When Adobe sends an eSendTabletEvent request asking for a pointer or
// proximity replay, this process posts a distributed notification to MockTab
// so the actual HID state can be re-injected.

let delegate = ShimApp()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
