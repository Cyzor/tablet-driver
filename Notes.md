---
name: Wacom tablet driver Swift project
description: New standalone Swift macOS app being built as an alternative to OpenTabletDriver for Wacom-only use
type: project
---

A new Swift/SwiftUI macOS tablet driver was started at `OpenTabletDriver/wacom-tablet-driver/`. It's a separate project from OpenTabletDriver.

**Target devices:** PTH-851 (Intuos 5 Large) and PTH-860 (Intuos Pro Large)

**Architecture:** Menu bar app (LSUIElement), IOHIDManager for HID, CGEvent injection for cursor + pressure

**Why:** OpenTabletDriver's C#/Eto.Forms stack can't run natively on ARM64 due to HID entitlement issues and Eto.Platform.Mac64's Xamarin.Mac x64 dependency. The Swift app bypasses all of that.

**Known constraint:** Requires Wacom's official system extension to be absent — IOHIDManager returns kIOReturnExclusiveAccess otherwise.

**How to apply:** When working in this project, context is the `wacom-tablet-driver/` subdirectory, not the OpenTabletDriver C# codebase.

---

## Architecture

```
IOHIDManager (main run loop, kCFRunLoopCommonModes)
    └── PTH851Device / PTH860Device   (HID report parsers → TabletPoint)
            └── TabletManager.onTablet closure
                    └── InputInjector.inject()   (CGEvent posting)

SwiftUI Settings scene (LSUIElement app, no Dock icon)
    └── PreferencesView (TabView)
        ├── TabletAreaView     — active area rectangle editor
        ├── PressureCurveView  — bezier curve + stabilization + double-click sliders
        ├── ButtonMappingView  — pen button actions
        ├── DisplayMappingView — target display picker
        └── ScratchpadView     — live pressure test canvas (NSViewRepresentable)

TabletSettings (@MainActor ObservableObject, @AppStorage + UserDefaults)
TabletManager  (@MainActor, singleton, owns IOHIDManager + InputInjector)
```

---

## Device IDs

| Device | VendorID | ProductID |
|--------|----------|-----------|
| Wacom (all) | 0x056A (1386) | — |
| PTH-851 Intuos 5 Large | 0x056A | 0x0317 (791) |
| PTH-860 Intuos Pro Large | 0x056A | 0x0358 (856) |

---

## HID Report Formats

### PTH-851 (IntuosV1) — 10-byte reports
- Feature init on open: `[0x02, 0x02]`
- Report ID: 0x02 (pen)
- Proximity: `report[1] & 0x20`
- High confidence: `report[1] & 0x40` — **do NOT filter out reports when this drops; pen lift emits low-confidence reports and that's how pressure reaches zero**
- X: `(report[3] | report[2]<<8) << 1 | ((report[9]>>1) & 1)`
- Y: `(report[5] | report[4]<<8) << 1 | (report[9] & 1)`
- Pressure: `(report[6]<<3) | ((report[7]&0xC0)>>5) | (report[1]&1)`  (max 1023)
- TiltX: `report[7] & 0x3F` (signed, center=0), TiltY: `report[8]` (signed)
- PenButton1: `report[1] & 0x02`, PenButton2: `report[1] & 0x04`, Eraser: `report[1] & 0x08`
- Digitizer: maxX=44704, maxY=27940, maxPressure=1023

### PTH-860 (IntuosV2) — 192-byte reports
- Report IDs: 0x10 (pen), 0x1E (offset pen), 0x11 (aux/express keys), 0x21 (touch)
- X: `UInt32(report[2]) | UInt32(report[3])<<8 | UInt32(report[4])<<16`
- Y: `UInt32(report[5]) | UInt32(report[6])<<8 | UInt32(report[7])<<16`
- Pressure: `UInt16(report[8]) | UInt16(report[9])<<8`  (max 8191)
- Digitizer: maxX=62200, maxY=43200, maxPressure=8191

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
```
- `.mouseEventPressure` (field 6) → `NSEvent.pressure` — wrong field = pressure always 0
- `.mouseEventSubtype = 1` — without this, AppKit/Qt/GTK ignore the pressure field entirely
- `.mouseEventClickState` — **without this, every click is click #1; double-click is impossible**

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
e.setIntegerValueField(.tabletProximityEventCapabilityMask,    value: 0x04C3)
// 0x04C3 = bit0(buttons)|bit1(pressure)|bit6(tiltX)|bit7(tiltY)|bit10(hoverZ)
e.setIntegerValueField(.tabletProximityEventEnterProximity,    value: entering ? 1 : 0)
// NOTE: tabletProximityEventPointerSerialNumber does NOT exist in Swift's CGEventField enum
```

Post target: always `.cghidEventTap`.

---

## App Compatibility

| App | Pressure | Notes |
|-----|----------|-------|
| Acorn, Nomad, Blender | ✅ | Simple `NSEvent.pressure` on mouse drag |
| Photoshop, Affinity, Illustrator | ✅ | Need full proximity device registration |
| Krita (Qt) | ✅ | Needs tabletPointer events + proximity deviceID |
| GIMP (GTK) | ✅ | Same as Krita |

---

## Double-Click Implementation

**Root cause of failure:** `mouseEventClickState` never set → every mouseDown = click #1.

**Two-part fix in `InputInjector.resolveClick()`:**
1. **Click counting** — within `NSEvent.doubleClickInterval` AND ≤N pt: `clickCount++`. Set on mouseDown + matching mouseUp via `activeClickCount`.
2. **Position snapping** — if within user's `doubleClickDistance` setting, snap second tap's position to first tap's coordinates. Chains for triple-click (update `lastClickPosition = snapped`).

Fallback count threshold when snap disabled: 8 pt (matches macOS default click distance).

---

## EMA Smoothing

```swift
let α = 1.0 - settings.smoothingStrength * 0.85   // 0→α=1.0 (raw), 1→α=0.15 (heavy)
smoothedPoint.x += α * (rawPoint.x - smoothedPoint.x)
// Snap to rawPoint on proximity entry to prevent cursor sliding in from old position
```
Default: 0.0 (hardware filtering on PTH-851/860 is already good).

---

## Settings (@AppStorage defaults)

| Key | Default |
|-----|---------|
| activeAreaX/Y/Width/Height | 0, 0, 1, 1 |
| targetDisplayIndex | 0 (primary) |
| penButton1Action | 2 (rightClick) |
| penButton2Action | 3 (middleClick) |
| smoothingStrength | 0.0 |
| doubleClickDistance | 10.0 pt |
| pressureCurve | .linear (JSON → UserDefaults) |

---

## Pressure Curve

Cubic bezier (p1, p2 control points), bisection inversion for evaluate(t).
Use `Swift.min(Swift.max(...))` — never define `clamped(to:)` extension; Swift 5.9 has a package-level conflict.

---

## Scratchpad

`ScratchpadNSView: NSView` receives injected CGEvents. `event.pressure` in mouseDown/mouseDragged reflects real pen pressure once `.mouseEventPressure` is set correctly.

**Never** use `event.allTouches().first!` in mouseDragged — empty set on mouse events, force-unwrap crashes silently → strokes only appear on mouseUp.

---

## Build Config

- `CODE_SIGN_IDENTITY = "-"` (ad-hoc, no Developer account)
- `ARCHS = "$(ARCHS_STANDARD)"` — native ARM64
- Deployment target: macOS 13.0
- `LSUIElement = YES` — menu bar only
- `app-sandbox = false` — required for IOHIDManager + CGEvent
- `NSInputMonitoringUsageDescription` + `NSAccessibilityUsageDescription` in Info.plist
- macOS 14+: `@Environment(\.openSettings)`; macOS 13: `showSettingsWindow:` selector + 50ms asyncAfter

---

## Bugs Fixed (Reference)

| Bug | Fix |
|-----|-----|
| Preferences window seizes mouse | `kCFRunLoopCommonModes` instead of `kCFRunLoopDefaultMode` |
| Pressure always 0 | `.mouseEventPressure` not `.tabletEventPointPressure` on mouse events |
| Apps ignore pressure | `.mouseEventSubtype = 1` required on all mouse events |
| Krita/GIMP ignore pressure | tabletPointer events were removed; must be sent before each mouse event |
| Photoshop/Affinity ignore pressure | Proximity event missing vendorID/deviceID/pointerType fields |
| Double-click impossible | `.mouseEventClickState` never set; added full click counting + position snap |
| Scratchpad strokes on mouseUp only | `event.allTouches().first!` crashed drag handler silently |
| `tabletProximityEventPointerSerialNumber` compile error | Field doesn't exist in Swift CGEventField; removed |
| Duplicate `clamped(to:)` | Removed all custom extensions; use `Swift.min(Swift.max(...))` |
| `IOHIDManager callback device non-optional` | `guard let ctx` only, not `guard let ctx, let device` |
| Thread not in scope | Missing `import Foundation` in TabletManager/TabletDevice |
