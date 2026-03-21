# MockTab

A native Swift driver for Wacom tablets on Apple Silicon Macs. MockTab uses IOHIDManager to read raw HID reports and CGEvent injection to deliver pressure, tilt, and click events to any app — no kernel extension, no Apple Developer account, no Rosetta.

**Supported hardware**

| Model | Product ID | Notes |
|---|---|---|
| Intuos 5 Large (PTH-851) | 0x0317 | IntuosV1 10-byte reports |
| Intuos Pro Large (PTH-860) | 0x0358 | IntuosV2 192-byte reports |
| Intuos3 Widescreen (PTZ-631W) | 0x00B5 | IntuosV1 10-byte reports |

The architecture is designed to make adding further Wacom tablets (any VendorID 0x056A device) straightforward: each tablet is a small Swift class implementing `TabletDevice`, and the UI auto-detects which one is connected.

<!-- Screenshots coming soon -->

---

## Why this exists

[OpenTabletDriver](https://opentabletdriver.net) is a well-engineered cross-platform tablet driver that directly inspired this project. Its macOS port, however, depends on Eto.Platform.Mac64, which pulls in Xamarin.Mac and only runs x64 — broken on Apple Silicon without Rosetta. MockTab trades OpenTabletDriver's broad hardware support for a small, fully native codebase that targets the two specific tablets it was written for.

The HID report decoding for both devices draws on OpenTabletDriver's `IntuosV1TabletReport.cs` and `IntuosV2Report.cs` as a reference for field offsets and bit layouts.

---

## Requirements

- macOS 13 Ventura or later
- Xcode 15 or later (command-line build) or any recent Xcode (GUI build)
- A supported Wacom tablet (see table above)

---

## Building

MockTab uses ad-hoc signing, so you don't need a paid Apple Developer account.

**Command line:**
```sh
git clone <this repo>
cd wacom-tablet-driver
xcodebuild -project MockTab.xcodeproj -scheme MockTab -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/MockTab-*/Build/Products/Debug/MockTab.app
```

**Xcode:** Open `MockTab.xcodeproj` and press ⌘R.

On first launch the app requests Accessibility permission — CGEvent injection requires it. Grant access in **System Settings → Privacy & Security → Accessibility**, then relaunch MockTab.

---

## Features

**Pen input**
- Full pressure sensitivity and x/y tilt, delivered as proper `NSEvent` tablet events so any pressure-aware app picks them up automatically
- Proximity detection — apps that register on proximity (Photoshop, Affinity, Illustrator) get the full device identity so pressure routing works
- Double-click snap: the second tap locks to the first tap's position within a configurable radius, making double-clicks reliable on a pressure surface

**Tablet Area**
- Drag the active rectangle interactively or type percentages
- Proportional mapping (on by default) crops the area to match the target display's aspect ratio — circles stay round
- The tablet model picker auto-selects the detected device on connection; you can override it to use a different model's canvas proportions

**Pressure Curve**
- Drag two Bézier control points to shape the pressure response
- Quick presets: Linear, Soft, Firm

**Button Mapping**
- Bind any key combination or mouse button to the pen's side buttons and express keys (PTH-860 and PTZ-631W each have eight)
- Live key capture: click the field, press the shortcut, done

**Display Mapping**
- Map the tablet to any connected display
- Visual layout shows the physical arrangement of your monitors

**Scratchpad**
- Built-in test canvas with a live pressure meter to confirm everything's working before opening your actual app

---

## App compatibility

| App | Status | Notes |
|---|---|---|
| Acorn, Nomad, Blender, Houdini, Smooze Pro | ✅ | Standard NSEvent path |
| Photoshop, Affinity Designer/Photo, Illustrator | ✅ | Require full proximity registration |
| Krita, GIMP | ✅ | Also require tabletPointer events alongside mouse subtype events |
| Smart Scroll (Marc Moini) | ❌ | Intercepts below `otherMouseDown/Up`; also fails with the official Wacom driver |

---

## Credits

**App icon** — tablet illustration by [Anamika Singh](https://thenounproject.com) via the Noun Project

**Menu bar icon** — stylus icon by [Rolas Design](https://thenounproject.com/icon/stylus-6582279/) via the Noun Project

**OpenTabletDriver** — [opentabletdriver.net](https://opentabletdriver.net) / [github.com/OpenTabletDriver](https://github.com/OpenTabletDriver/OpenTabletDriver) — HID report field layouts for both tablets reference OpenTabletDriver's open-source C# implementation
