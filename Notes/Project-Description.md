---
name: MockTab — Mac tablet driver for older Wacom tablets
description: Swift/SwiftUI driver supporting USB and Bluetooth
type: project
---

A macOS app that revives drawing tablets that Wacom no longer supports.

- **Hardware:** ~190 registered models (primarily Wacom — Intuos all
  generations, Cintiq, Bamboo), plus HID-descriptor auto-detection for
  unregistered ones. Decoders live in the **TabletKit** SwiftPM package
  (submodule at `TabletKit/`).
- **Constraint:** Wacom's official system extension must be absent —
  IOHIDManager returns `kIOReturnExclusiveAccess` otherwise.

`Architecture.md` is the authoritative architecture reference. This file
carries the CGEvent-injection field knowledge and the small set of tuning
constants and gotchas that aren't obvious from the code.

---

## Threading

Two threads carry live work (see `Architecture.md` for the full pipeline):

- **HIDThread** (`MockTab/Driver/HID/HIDThread.swift`) — a dedicated
  background `CFRunLoop` owning the IOHIDManager and every `handleReport`
  callback, so a busy main thread can't delay a pen sample. Hand-off:
  `CFRunLoopPerformBlock(HIDThread.shared.runLoop, …)` for state the hot path
  reads back, `Task { @MainActor }` for UI.
- **Main** — AppKit, SwiftUI, settings storage, most CGEvent posts.

### IOHIDManager run-loop mode (load-bearing)

Schedule with `kCFRunLoopCommonModes`, **not** `kCFRunLoopDefaultMode`. AppKit
drag-tracking enters `NSEventTrackingRunLoopMode`, which silences
default-mode callbacks → pen-lift never fires → mouse stuck down. Same for
`IOHIDDeviceScheduleWithRunLoop`.

---

## CGEvent injection — field reference

The knowledge here is "omit this field and pressure is silently 0 in app X."
Post target is always `.cghidEventTap`.

### Every mouse event (down / drag / up / move)

```swift
e.setDoubleValueField(.mouseEventPressure, value: pressure)   // field 6 → NSEvent.pressure; wrong field = always 0
e.setIntegerValueField(.mouseEventSubtype, value: 1)          // tabletPoint; without it AppKit/Qt/GTK ignore pressure
e.setIntegerValueField(.mouseEventClickState, value: count)   // 1/2/3; without it every click is #1, no double-click
// Tablet union — required for Photoshop / Affinity / Illustrator (they read it in mouse events):
e.setIntegerValueField(.tabletEventDeviceID, value: 1)
e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
e.setIntegerValueField(.tabletEventPointButtons, value: buttons)
```

### tabletPointer event

Required for Qt (Krita) and GTK (GIMP), which handle `NSEventTypeTabletPoint`
separately.

```swift
e.type = .tabletPointer
e.setIntegerValueField(.tabletEventDeviceID, value: 1)        // must match the proximity deviceID
e.setDoubleValueField(.tabletEventPointPressure, value: p)
e.setDoubleValueField(.tabletEventTiltX, value: tiltX)
e.setDoubleValueField(.tabletEventTiltY, value: tiltY)
e.setIntegerValueField(.tabletEventPointX, value: Int64(rawX))
e.setIntegerValueField(.tabletEventPointY, value: Int64(rawY))
e.setIntegerValueField(.tabletEventPointButtons, value: buttons)
```

### tabletProximity event — every field required

Apps register a virtual tablet on proximity enter. Miss any identity field and
pressure is silently ignored in Photoshop, Krita, GIMP, Affinity, Illustrator.

```swift
e.type = .tabletProximity
e.setIntegerValueField(.tabletProximityEventVendorID,          value: 0x056A)
e.setIntegerValueField(.tabletProximityEventTabletID,          value: Int64(productID))
e.setIntegerValueField(.tabletProximityEventPointerID,         value: 1)
e.setIntegerValueField(.tabletProximityEventDeviceID,          value: 1)   // non-zero
e.setIntegerValueField(.tabletProximityEventSystemTabletID,    value: 0)
e.setIntegerValueField(.tabletProximityEventPointerType,       value: 1)   // 1 = pen, 3 = eraser
e.setIntegerValueField(.tabletProximityEventVendorPointerType, value: 0x0802) // 0x080A = eraser
e.setIntegerValueField(.tabletProximityEventCapabilityMask,    value: 0x05C7)
// 0x05C7 = buttons | pressure | proximity | tiltX | tiltY | hoverZ
e.setIntegerValueField(.tabletProximityEventEnterProximity,    value: entering ? 1 : 0)
```

`tabletProximityEventPointerSerialNumber` does not exist as a Swift
`CGEventField` — don't reach for it.

---

## Double-click

`mouseEventClickState` drives it. Two parts in `InputInjector.resolveClick()`:

1. **Counting** — within `NSEvent.doubleClickInterval` and ≤ threshold:
   `clickCount++`, set on the mouseDown and its matching mouseUp. Falls back to
   an 8 pt distance threshold (macOS default) when position snapping is off.
2. **Snapping** — within the user's `doubleClickDistance` setting, snap the
   later tap's position onto the first. Chains for triple-click.

---

## HID report formats

Representative decoders; the registry and HID-descriptor auto-detection cover
the rest.

### IntuosV1 (PTH-851 family) — 10-byte, report ID 0x02

- Feature init on open: `[0x02, 0x02]`
- Proximity `report[1] & 0x20`; high-confidence `report[1] & 0x40` — do **not**
  filter when confidence drops, pen-lift arrives as low-confidence reports
- X/Y 11-bit (LSBs from `report[9]`); pressure 11-bit (2047 max on PTH-851)
- Tilt signed 6-bit; digitizer 44704 × 27940

### IntuosV2 (PTH-660 / 860) — 192-byte USB / 361-byte BT

- Report IDs: 0x10 pen, 0x11 express keys / touch ring, 0x21 touch
- X/Y 24-bit LE; pressure 13-bit (8191 max); tilt/rotation signed bytes
- Digitizer 62200 × 43200

### IntuosV2 Bluetooth Classic (PTH-860) — 99-byte, report ID 0x80

- 7 frames × 14 bytes packed per report; otherwise same specs as USB

---

## Settings persistence

Custom load chain in `TabletSettings` reading `UserDefaults.standard` (not
`@AppStorage`). Per-device keys are namespaced `device-0x{PID_HEX}.{key}`;
`reloadAll()` applies them between `isLoading = true/false` so the
`didSet → persist` echo is suppressed during load. A bare unprefixed key is
the lowest override layer.

Selected defaults: active area 0,0,1,1 (full); `targetDisplayIndex` 0;
`smoothingStrength` 0.0; `doubleClickDistance` 10 pt; pen buttons 2
(right-click) / 3 (middle-click); pressure curve `.linear`.

### Advanced defaults keys (no UI)

Same device / profile / app-override layering as everything else — a bare
`defaults write com.cyzor.mocktab <key> <value>` is the lowest layer. See
`reference_advanced_defaults_keys` (memory) for the procedure to add one.

| Key | Type | Default | Effect |
|-----|------|---------|--------|
| `touchOnsetDelayMs` | Double, 0–500 | `40` | ms a finger touch emits nothing after landing (`TouchStateTracker.onsetDelay`). Lower for a snappier start; raise if a resting palm nudges the cursor. `0` still leaves a ~2-frame floor. |
| `touchTapStabilizationPt` | Double, 0–4 | `1.5` | Points a single-finger touch may drift before it starts moving the cursor — absorbs lift-off skitter on a tap and the first point or two of a slow drag from rest, then tracks with no catch-up jump. Past ~2 it feels sticky; `0` disables. Relative touch mode only. |

---

## Pressure curve

Cubic Bézier (p1, p2 control points), bisection inversion for `evaluate(t)`.
Clamp with `Swift.min(Swift.max(...))` — never define a `clamped(to:)`
extension (package-level name conflict).

---

## Build config

- Bundle ID `com.cyzor.mocktab`; deployment target macOS 13.0;
  `ARCHS = $(ARCHS_STANDARD)` (arm64 + x86_64)
- Signing: `Developer ID Application`, team `3R62GZR6Q2`, hardened runtime
  (generic `CODE_SIGN_IDENTITY = "MockTab Dev"` is the non-macOS fallback and
  unused)
- `LSUIElement = YES`; `app-sandbox = false` (required for IOHIDManager +
  CGEvent)
- Info.plist: `NSInputMonitoringUsageDescription`,
  `NSAccessibilityUsageDescription`
- Build with `xcodebuild -scheme MockTab` (not `-target`)
