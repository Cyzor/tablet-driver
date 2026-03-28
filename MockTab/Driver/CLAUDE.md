# MockTab — Claude Context

Native ARM64 macOS tablet driver for Wacom tablets, similar to OpenTabletDriver but limited in scope and built as a Swift/SwiftUI app using best practices for compatibility, performance, and ease of use.  Attempts to do things the Mac way.

---

## 🚀 QUICK RESUMPTION GUIDE (Session 5 — CLI/JSON Profiles)

**Last updated:** 2026-03-28  
**Current phase:** Phase 1 Light Setup (1–2 hours) — NOT YET STARTED

### What Was Just Decided

User asked: "Could we add a CLI for older OS versions + JSON profiles?" 
→ Answer: **Highly feasible (Option 2: JSON file profiles chosen)**

**Why this works:** Settings models are already UI-agnostic and Codable. CLI shares Driver + Settings layers, not UI.

### What Needs Doing (Next Session)

**Phase 1 Light Setup (1–2 hours, choose this if resuming immediately):**
1. Create `MockTab/Settings/Profile.swift` — new Codable struct (37 lines)
2. Add `exportCurrentAsProfile()` + `importProfile()` to `TabletSettings` (28 lines)
3. Create `MockTab/example-profile.json` — schema docs (50 lines)
4. Add unit test `MockTabTests/ProfileCodingTests.swift` (25 lines)
5. Update `todo.md` + `progress.md` to mark Phase 1 complete

**Full details:** See `Notes/Session-5-CLI-JSON-Profiles-Plan.md` (comprehensive 387-line guide)

### Code Snippets Ready to Paste

All exact code is in `Notes/Session-5-CLI-JSON-Profiles-Plan.md` under:
- Section 1.1 → `Profile.swift` struct
- Section 1.2 → export/import methods
- Section 1.3 → example-profile.json
- Section 1.4 → unit test

### Why This Timing

- **Now:** Locks schema before Settings design changes further
- **Later:** Phase 2 CLI (4–8h) when GUI is feature-complete
- **Safe:** Zero GUI changes, just data models

**TL;DR:** Next session: copy 4 code blocks from the notes file, build & test. Takes 1–2 hours.

---


## Target hardware
- As many Wacom tablets made since the early 2000s as possible

## Build
```
xcodebuild -project MockTab.xcodeproj -scheme MockTab -configuration Debug build
```
Signed with self-signed "MockTab Dev" certificate (`CODE_SIGN_IDENTITY = "MockTab Dev"`)
for stable Accessibility permission across rebuilds. Bundle ID: `com.cyzor.mocktab`.

## Architecture
```
IOHIDManager (main run loop, kCFRunLoopCommonModes)
  └─ PTH851Device / PTH660Device / PTH860Device / PTZ631WDevice / DTK2400Device
       → TabletPoint → TabletManager
                           ├─ contexts: [Int: DeviceContext]  (per-device settings+injector)
                           ├─ activeContext (proximity-based switching)
                           └─ DeviceContext.injector → CGEvent tap

SwiftUI Settings scene (LSUIElement, no Dock icon)
  PreferencesWindowController — window manager (not NSWindowController)
    └─ SettingsWindowController (NSTabViewController, .toolbar style, 8 tabs)
         TabletAreaView | PressureCurveView | ButtonMappingView | DisplayMappingView
         DevicesView | PresetsView | ScratchpadView | InfoView

DeviceContext: owns TabletSettings + InputInjector + TabletDevice per product ID
DeviceRegistry: singleton tracking ever-connected tablets and tools (user-renamable)
TabletSettings: @MainActor ObservableObject, @AppStorage + UserDefaults
                Per-device namespace: "device-0x{HEX}.{key}"
```
Everything is `@MainActor`. IOHIDManager callbacks are scheduled on
`CFRunLoopGetMain()` so they land on the main thread natively.

### Multi-device support
Each connected tablet gets its own `DeviceContext` (settings, injector, device driver).
Only the *active* context posts CGEvents — activation switches automatically when a pen
enters proximity on a different tablet, with a proximity-exit posted for the outgoing device.
Legacy `TabletManager.settings`/`.injector` computed properties forward to `activeContext`.

## Critical implementation details

### Run loop mode — MUST be `kCFRunLoopCommonModes`
AppKit's drag-tracking loop runs in `NSEventTrackingRunLoopMode`. If IOHIDManager
is scheduled on `kCFRunLoopDefaultMode` (the naive choice), all HID callbacks
are silenced during any mouse-button-held state → pen lift never fires →
mouse gets permanently stuck down. Fix: `RunLoop.Mode.common.rawValue as CFString`
in every `IOHIDManagerScheduleWithRunLoop` / `IOHIDDeviceScheduleWithRunLoop` call.

### CGEvent field mapping for pressure
```swift
// On leftMouseDown / leftMouseDragged / leftMouseUp:
e.setDoubleValueField(.mouseEventPressure, value: pressure)  // field 6
e.setIntegerValueField(.mouseEventSubtype, value: 1)          // NSEventSubtype.tabletPoint
e.setIntegerValueField(.mouseEventClickState, value: count)   // 1/2/3 for click depth
```
- `.mouseEventPressure` (NOT `.tabletEventPointPressure`) → `NSEvent.pressure`
- Without `.mouseEventSubtype = 1`, AppKit/Qt/GTK ignore the pressure field entirely
- Without `.mouseEventClickState`, every injected mouseDown = click #1; double-click is impossible

### tabletPointer events — do NOT omit
Post a `.tabletPointer` CGEvent *before* each mouse event. Qt (Krita) and GTK (GIMP)
process `NSEventTypeTabletPoint` in a separate code path from mouse-subtype events.
Both are needed for full app coverage. Set `.tabletEventDeviceID = 1` to match
the proximity event.

### Proximity event — ALL identity fields required
Photoshop, Krita, GIMP, Affinity, Illustrator all do device registration: they
process a proximity event, store the deviceID, and only route pressure if subsequent
events match. Missing any field = pressure silently ignored forever.
```swift
e.type = .tabletProximity
e.setIntegerValueField(.tabletProximityEventVendorID,          value: 0x056A)
e.setIntegerValueField(.tabletProximityEventTabletID,          value: Int64(productID))
e.setIntegerValueField(.tabletProximityEventPointerID,         value: 1)
e.setIntegerValueField(.tabletProximityEventDeviceID,          value: 1)  // non-zero!
e.setIntegerValueField(.tabletProximityEventSystemTabletID,    value: 0)
e.setIntegerValueField(.tabletProximityEventPointerType,       value: 1)  // 1=pen 3=eraser
e.setIntegerValueField(.tabletProximityEventVendorPointerType, value: 0x0802) // 0x080A=eraser
e.setIntegerValueField(.tabletProximityEventCapabilityMask,    value: 0x04C3)
e.setIntegerValueField(.tabletProximityEventEnterProximity,    value: entering ? 1 : 0)
// NOTE: .tabletProximityEventPointerSerialNumber does NOT exist in Swift CGEventField
```
`deviceVendorID` / `deviceProductID` are set on `InputInjector` by `TabletManager`
when a device connects, so proximity events carry the real hardware IDs.

### Double-click: position snap + click count
`InputInjector.resolveClick()` tracks `lastClickPosition` + `lastClickTime`.
Within `NSEvent.doubleClickInterval` AND within `settings.doubleClickDistance` pt:
- Increment `clickCount` (set as `mouseEventClickState` on down+up)
- Snap mouseDown position to first-tap coordinates
Both are required: click count tells the app it's a double-click; position snap
ensures the OS and app agree on location. Default distance: 10 pt.

### HID report decoding
**PTH-851 (IntuosV1, 10-byte):** Feature init `[0x02, 0x02]` on open.
Do NOT filter on the high-confidence bit (report[1] & 0x40) — the pen-lift
transition emits low-confidence reports; filtering them out prevents pressure
from reaching zero → mouse stays down after lift.

**PTH-860 (IntuosV2, 192-byte):** Report IDs 0x10 (pen), 0x1E (offset pen),
0x11 (express keys), 0x21 (touch). Pressure is 13-bit (max 8191).

### Conflict detection (InfoView)
InfoView scans for competing tablet drivers (Wacom, OpenTabletDriver) using
`sysctl(KERN_PROC_ALL)` — NOT `NSWorkspace.runningApplications`, which only
sees GUI apps and misses daemons like `OpenTabletDriver.Daemon`.
`p_comm` is truncated to 16 chars; matching uses `hasPrefix` both ways.
Also monitors `InputInjector.jitterLevel` for RF interference (rolling window
of 60 hover-position deltas, threshold 3.0 pt/sample).

### Multi-window / SettingsWindowController
- `PreferencesWindowController` is a plain `@MainActor` class (not `NSWindowController`). It creates and tracks `SettingsWindowController` instances.
- `SettingsWindowController` bakes device label into `hosting.title` at init for device-specific tabs (0–3: Tablet Area, Pressure, Buttons, Display). NSTabViewController then manages `window.title` automatically on tab switch — no delegate override needed.
- **NEVER set `tabView.delegate` on NSTabViewController** — it owns that slot and crashes with `NSInternalInconsistencyException`. Use an NSTabViewController subclass override of `tabView(_:didSelect:)` if needed.
- `TabletAreaView.onDeviceSelected` callback fires when the user picks a different model from the picker, triggering `PreferencesWindowController.replaceWindow(_:withDeviceID:)` — closes old window, opens new one at same frame/tab.
- Default window auto-rebinds to the first device via Combine subscriber on `TabletManager.$connectedProductIDs` (fires once when the first device connects and default window has no productID).
- **Tablet menu** at index 1 in main menu (right after app menu). **View menu** in MockTabApp.swift commands block with ⌘1–⌘8.

### Swift gotchas in this codebase
- Never define `clamped(to:)` extension — conflicts with Swift 5.9 package-level symbol. Use `Swift.min(Swift.max(...))`.
- IOHIDManager device-matching callback: `device` param is non-optional. `guard let ctx` only, not `guard let ctx, let device`.
- `@AppStorage` + `@MainActor` requires all access on main thread; wrap external calls in `Task { @MainActor in }`.
- `ScratchpadNSView.mouseDragged`: never use `event.allTouches().first!` — returns empty set for mouse events, crashes silently.
- sysctl `kinfo_proc.kp_proc.p_comm`: use `withUnsafeBytes(of:)` + `assumingMemoryBound(to: CChar.self)`, NOT `withUnsafePointer` (exclusivity violation). `MAXCOMM` doesn't exist in Swift.

## App compatibility (confirmed)
| App | Status | Notes |
|-----|--------|-------|
| Acorn, Nomad, Blender, Houdini, Smooze Pro | ✅ | Standard NSEvent path |
| Photoshop, Affinity, Illustrator | ✅ | Require full proximity registration |
| Krita, GIMP | ✅ | Also require tabletPointer events |
| Marc Moini Smart Scroll (middle-click) | ❌ | Known issue with official Wacom driver too; intercepts below otherMouseDown/Up |

## Settings keys (AppStorage)
`activeAreaX/Y/Width/Height` · `targetDisplayIndex` · `penButton1Action` (default 2=rightClick) ·
`penButton2Action` (default 3=middleClick) · `smoothingStrength` (default 0.0) ·
`doubleClickDistance` (default 10.0 pt) · `pressureCurve` (JSON, UserDefaults key "pressureCurve")
