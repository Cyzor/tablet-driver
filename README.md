# MockTab

Native tablet driver for modern Macs that brings forgotten drawing tablets back to life.

MockTab is a minimal, high-performance driver for Wacom tablets on Apple Silicon and Intel Macs running macOS 13+. It revives decades of discontinued hardware with full pressure and tilt support — no kernel extensions, no Apple Developer account, no Rosetta emulation needed.

**Why you might care:** If you own an older Wacom tablet (Intuos, Intuos Pro, Cintiq) and switched to Apple Silicon, it probably stopped working. Official Wacom drivers were never ported. MockTab fixes that in a single lightweight app.

---

## What's supported

**Tablets**
- Intuos 5 / Intuos Pro (all sizes)
- Intuos3 / Intuos4
- Cintiq 24HD
- Bamboo (some models)
- ~95 other Wacom models via auto-detection

**Features**
- Full pressure and tilt support
- Multi-tablet switching (pressure-based activation)
- Configurable tablet area, pressure curve, button mapping, display mapping
- Touch ring support (where available)
- Wireless via USB dongle or Bluetooth
- App-specific settings (future)

**What's *not* supported**
- Pressure on Intuos tablets over Bluetooth (hardware limitation on some models)
- Touch input (disabled by default; patches welcome)
- Tablets from other vendors (Huion, XP-Pen, etc.)

---

## Get started

**Build & run**
```sh
git clone https://github.com/...tablet-driver.git
cd tablet-driver
xcodebuild -project MockTab.xcodeproj -scheme MockTab -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/MockTab-*/Build/Products/Debug/MockTab.app
```

**First launch**
1. Grant Accessibility permission when prompted (needed for pressure injection)
2. Open Settings (⌘, or menu bar icon → Settings)
3. Select your tablet model from the picker
4. Test pressure in the Scratchpad tab
5. Configure tablet area, buttons, and display mapping to suit your workflow

---

## What it does

- **Tablet area:** Choose which part of your tablet surface maps to the screen. Proportional mode keeps circles round at any aspect ratio.
- **Pressure curve:** Two-point Bézier editor with presets (Linear, Soft, Firm). Works in every pressure-aware app.
- **Button & key mapping:** Remap barrel buttons and express keys to any modifier + key combination. Live key capture — click, press the shortcut, done.
- **Display mapping:** Route your tablet to any of your connected displays (useful with multiple monitors).
- **Wireless:** Full support for USB dongle and Bluetooth (where hardware supports it).
- **Live pressure meter:** Built-in scratchpad to test everything before opening your real work.
- **Multi-tablet:** Connect multiple tablets; pressure-based activation switches automatically between them.

---

## Compatibility

Works with Photoshop, Affinity, Illustrator, Krita, GIMP, Blender, and any app that reads `NSEvent` tablet events or uses the standard pressure APIs. See the [detailed compatibility chart](COMPATIBILITY.md) for app-specific notes.

---

## Why this exists

[OpenTabletDriver](https://opentabletdriver.net) inspired this project but only runs x64 on macOS — broken on Apple Silicon without Rosetta. MockTab is fully native, small, and dependency-free. It started as a fix for two specific tablets and has grown to support ~95 Wacom models through a data-driven registry and auto-detection.

---

## Acknowledgments

- **Icons:** tablet illustration by [Anamika Singh](https://thenounproject.com), stylus by [Rolas Design](https://thenounproject.com)
- **HID specs:** [OpenTabletDriver](https://opentabletdriver.net), Linux kernel `drivers/input/tablet/wacom_wac.c`
- **Testing:** Wacom hardware community, especially those on older tablets

---

## License

GNU General Public License v3.0 or later. See `LICENSE` for details.

Free to run, study, modify, and share — with modifications available under the same license.

---

## Further reading

- [Supported hardware list](HARDWARE.md)
- [Build & development](DEVELOPMENT.md)
- [Troubleshooting](TROUBLESHOOTING.md) (coming soon)
