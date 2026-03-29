---
name: MockTab — Wacom tablet driver for modern macOS
description: Native Swift/SwiftUI driver for ~95 Wacom tablet models, supporting USB and Bluetooth
type: project
---

A Swift/SwiftUI native macOS application that brings discontinued Wacom drawing tablets back to life with modern macOS support.

**Target hardware:** ~95 Wacom tablet models from the early 2000s onward, including Intuos (all generations), Cintiq 24HD, Bamboo, and more.

**Architecture:** Menu bar app (LSUIElement), IOHIDManager for HID, CGEvent injection for cursor + pressure

**Why:** Wacom discontinued official driver support for older tablets. This project restores them with full pressure, tilt, and button support on modern Macs (13.0+). Works alongside or instead of OpenTabletDriver, with lighter resource footprint and native SwiftUI settings.

**Notable constraint:** Requires Wacom's official system extension to be absent — IOHIDManager returns `kIOReturnExclusiveAccess` otherwise.

---

## Architecture

```
IOHIDManager (main run loop, kCFRunLoopCommonModes)
    └── WacomGenericDevice / DeviceFamily-specific parsers
            → TabletPoint → TabletManager
                    ├── contexts: [Int: DeviceContext]  (per-device settings+injector)
                    ├── activeContext (proximity-based switching)
                    └── DeviceContext.injector → CGEvent tap

SwiftUI Settings scene (LSUIElement app, no Dock icon)
    PreferencesWindowController — window manager
        └── SettingsWindowController (NSTabViewController, .toolbar style, 8 tabs)
             TabletAreaView | PressureCurveView | ButtonMappingView | DisplayMappingView
             DevicesView | PresetsView | ScratchpadView | InfoView

DeviceContext: owns TabletSettings + InputInjector + TabletDevice per product ID
DeviceRegistry: singleton tracking all connected tablets and tools
TabletSettings: @MainActor ObservableObject, @AppStorage + UserDefaults per-device namespace
```

All code is `@MainActor`. IOHIDManager callbacks are scheduled on `CFRunLoopGetMain()` so they land on the main thread natively.

### Multi-device support
Each connected tablet gets its own `DeviceContext` (settings, injector, device driver).
Only the *active* context posts CGEvents — activation switches automatically when a pen
enters proximity on a different tablet. Legacy `TabletManager.settings`/`.injector` computed
properties forward to `activeContext` for backwards compatibility.

### Settings export/import (Phase 1)
Profile-based JSON export/import is implemented for portability. Full CLI implementation
deferred until `TabletSettings` API stabilizes (~1–2 months).

---

## Supported Devices (Examples)

| Family | Examples | Report Format | Decoders |
|--------|----------|---------------|----------|
| IntuosV1 (PTH-851, etc.) | Intuos 5 Large, Intuos Pro Medium | 10-byte 0x02 | IntuosV1Decoder |
| IntuosV2 (PTH-660, PTH-860, etc.) | Intuos Pro 2015+, Cintiq 22HD | 192-byte USB, 361-byte BT | IntuosV2Decoder |
| Intuos3 (PTZ-631W, etc.) | Intuos 3 / 4 | 10-byte multi-report | Intuos3Decoder |
| Cintiq 24HD (DTK-2400) | 24" display tablet | 192-byte, touch ring, buttons | DTK2400Decoder |
| BambooDecoder | Bamboo line | 20-byte | BambooDecoder |
| WacomGenericDevice | ~45 OTD-imported models | Auto-detection from HID spec | Auto-dispatch |

Total: ~95 models registered; auto-detection handles unregistered models via HID descriptor.

---

## HID Report Formats

### IntuosV1 (PTH-851) — 10-byte reports
- Feature init on open: `[0x02, 0x02]`
- Report ID: 0x02 (pen)
- Proximity: `report[1] & 0x20`
- High confidence: `report[1] & 0x40` — do NOT filter when this drops; pen lift emits low-confidence reports
- X/Y: 11-bit (left-padded in 16-bit fields with LSBs from report[9])
- Pressure: 11-bit (max 2047 for PTH-851)
- TiltX/Y: signed 6-bit
- Digitizer: maxX=44704, maxY=27940, maxPressure=2047

### IntuosV2 (PTH-660/860) — 192-byte USB / 361-byte BT reports
- Report IDs: 0x10 (pen), 0x11 (express keys), 0x21 (touch)
- X/Y: 24-bit LE
- Pressure: 13-bit (max 8191)
- Tilt/rotation: signed bytes
- Touch ring: 0x11 report, one-hot buttons + contact detection
- Digitizer: maxX=62200, maxY=43200, maxPressure=8191

### IntuosV2 Bluetooth Classic (PTH-860) — 99-byte reports
- Same 13-bit pressure as USB variant
- 7 frames × 14 bytes packed in 99-byte report
- 0x80 report ID with frame-based decoding
- Digitizer specs same as USB variant

---

## IOHIDManager — Critical Setup Detail

```swift
// MUST be kCFRunLoopCommonModes, not kCFRunLoopDefaultMode.
// AppKit drag-tracking enters NSEventTrackingRunLoopMode which silences
// defaultMode callbacks → pen lift never fires → mouse gets permanently stuck down.
let mode = RunLoop.Mode.common.rawValue as CFString
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), mode)
// Same for IOHIDDeviceScheduleWithRunLoop in each device parser.
```

- Context pointer pattern: `Unmanaged.passRetained(self).toOpaque()`
- The `device` arg in device-matching callback is **non-optional** — `guard let ctx` only
- All callbacks + TabletManager + InputInjector are `@MainActor`

---

## CGEvent Injection — Complete Field Reference

### Every mouse event (down/drag/up/move)
```swift
e.setDoubleValueField(.mouseEventPressure, value: pressure)  // NOT .tabletEventPointPressure
e.setIntegerValueField(.mouseEventSubtype, value: 1)          // NSEventSubtype.tabletPoint
e.setIntegerValueField(.mouseEventClickState, value: count)   // 1=single, 2=double, 3=triple
// Also for Photoshop (reads tablet union in mouse events):
e.setIntegerValueField(.tabletEventDeviceID, value: 1)
e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
e.setIntegerValueField(.tabletEventPointButtons, value: buttons)
```
- `.mouseEventPressure` (field 6) → `NSEvent.pressure` — wrong field = pressure always 0
- `.mouseEventSubtype = 1` — without this, AppKit/Qt/GTK ignore the pressure field entirely
- `.mouseEventClickState` — without this, every click is click #1; double-click is impossible
- Tablet union fields — required for Photoshop/Affinity/Illustrator

### tabletPointer event (post BEFORE each mouse event)
Required for Qt (Krita) and GTK (GIMP) which process `NSEventTypeTabletPoint` separately.
```swift
e.type = .tabletPointer
e.setIntegerValueField(.tabletEventDeviceID, value: 1)        // match proximity deviceID
e.setDoubleValueField(.tabletEventPointPressure, value: p)
e.setDoubleValueField(.tabletEventTiltX, value: tiltX)
e.setDoubleValueField(.tabletEventTiltY, value: tiltY)
e.setIntegerValueField(.tabletEventPointX, value: Int64(rawX))
e.setIntegerValueField(.tabletEventPointY, value: Int64(rawY))
e.setIntegerValueField(.tabletEventPointButtons, value: buttons)
```

### tabletProximity event — ALL fields required
Apps register a virtual device on proximity. Missing any identity field = pressure silently ignored in Photoshop, Krita, GIMP, Affinity, Illustrator.
```swift
e.type = .tabletProximity
e.setIntegerValueField(.tabletProximityEventVendorID,          value: 0x056A)
e.setIntegerValueField(.tabletProximityEventTabletID,          value: Int64(productID))
e.setIntegerValueField(.tabletProximityEventPointerID,         value: 1)
e.setIntegerValueField(.tabletProximityEventDeviceID,          value: 1)  // non-zero!
e.setIntegerValueField(.tabletProximityEventSystemTabletID,    value: 0)
e.setIntegerValueField(.tabletProximityEventPointerType,       value: 1)  // 1=pen, 3=eraser
e.setIntegerValueField(.tabletProximityEventVendorPointerType, value: 0x0802) // 0x080A=eraser
e.setIntegerValueField(.tabletProximityEventCapabilityMask,    value: 0x05C7)
// 0x05C7 = bit0(buttons)|bit1(pressure)|bit2(proximity)|bit6(tiltX)|bit7(tiltY)|bit10(hoverZ)
e.setIntegerValueField(.tabletProximityEventEnterProximity,    value: entering ? 1 : 0)
```

Post target: always `.cghidEventTap`.

---

## App Compatibility

| App | Pressure | Notes |
|-----|----------|-------|
| Acorn, Nomad, Blender, Houdini, Smooze Pro | ✅ | Standard `NSEvent.pressure` on mouse drag |
| Photoshop, Affinity, Illustrator | ✅ | Require full proximity registration + tablet union fields |
| Krita (Qt) | ✅ | Needs tabletPointer events + proximity deviceID |
| GIMP (GTK) | ✅ | Same as Krita |
| Marc Moini Smart Scroll | ❌ | Also failed with official Wacom drivers; likely intercepts below `otherMouseDown/Up` |

---

## Double-Click Implementation

**Root cause of failure:** `mouseEventClickState` never set → every mouseDown = click #1.

**Two-part fix in `InputInjector.resolveClick()`:**
1. **Click counting** — within `NSEvent.doubleClickInterval` AND ≤N pt: `clickCount++`. Set on mouseDown + matching mouseUp via `activeClickCount`.
2. **Position snapping** — if within user's `doubleClickDistance` setting, snap second tap's position to first tap's coordinates. Chains for triple-click.

Fallback count threshold when snap disabled: 8 pt (matches macOS default click distance).

---

## EMA Smoothing

```swift
let α = 1.0 - settings.smoothingStrength * 0.85   // 0→α=1.0 (raw), 1→α=0.15 (heavy)
smoothedPoint.x += α * (rawPoint.x - smoothedPoint.x)
// Snap to rawPoint on proximity entry to prevent cursor sliding in from old position
```
Default: 0.0 (hardware filtering on modern tablets is already good).

---

## Settings (@AppStorage defaults)

Per-device namespace: `"device-0x{ProductID_HEX}.{key}"`

| Key | Default |
|-----|---------|
| activeAreaX/Y/Width/Height | 0, 0, 1, 1 (full area) |
| targetDisplayIndex | 0 (primary) |
| penButton1Action | 2 (rightClick) |
| penButton2Action | 3 (middleClick) |
| smoothingStrength | 0.0 |
| doubleClickDistance | 10.0 pt |
| pressureCurve | .linear (JSON) |

---

## Pressure Curve

Cubic bezier (p1, p2 control points), bisection inversion for evaluate(t).
Use `Swift.min(Swift.max(...))` — never define `clamped(to:)` extension; Swift 5.9 has a package-level conflict.

---

## Scratchpad

`ScratchpadNSView: NSView` receives injected CGEvents. `event.pressure` in mouseDown/mouseDragged reflects real pen pressure once `.mouseEventPressure` is set correctly.

**Never** use `event.allTouches().first!` in mouseDragged — empty set on mouse events, force-unwrap crashes silently.

---

## Build Config

- `CODE_SIGN_IDENTITY = "MockTab Dev"` (self-signed, stable across rebuilds)
- Bundle ID: `com.cyzor.mocktab`
- `ARCHS = "$(ARCHS_STANDARD)"` — native ARM64 + Intel
- Deployment target: macOS 13.0
- `LSUIElement = YES` — menu bar only, no Dock icon
- `app-sandbox = false` — required for IOHIDManager + CGEvent
- `NSInputMonitoringUsageDescription` + `NSAccessibilityUsageDescription` in Info.plist

---

## Bugs Fixed (Reference)

| Bug | Fix |
|-----|-----|
| Preferences window seizes mouse | `kCFRunLoopCommonModes` instead of `kCFRunLoopDefaultMode` |
| Pressure always 0 | `.mouseEventPressure` not `.tabletEventPointPressure` on mouse events |
| Apps ignore pressure | `.mouseEventSubtype = 1` required on all mouse events |
| Krita/GIMP ignore pressure | tabletPointer events were removed; must be sent before each mouse event |
| Photoshop/Affinity ignore pressure | Proximity event missing vendorID/deviceID/pointerType fields, tablet union fields missing in mouse events |
| Double-click impossible | `.mouseEventClickState` never set; added full click counting + position snap |
| Scratchpad strokes on mouseUp only | `event.allTouches().first!` crashed drag handler silently |
| `tabletProximityEventPointerSerialNumber` compile error | Field doesn't exist in Swift CGEventField; removed |
| Duplicate `clamped(to:)` | Removed all custom extensions; use `Swift.min(Swift.max(...))` |
| `IOHIDManager callback device non-optional` | `guard let ctx` only, not `guard let ctx, let device` |
| CPU churn during backgrounding | Three-level gating: app foreground + window focus + tab visibility |
