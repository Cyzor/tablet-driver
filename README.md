# MockTab

Native tablet driver for modern Macs to bring discontinued Wacom drawing tablets back to life.

MockTab is a minimal, high-performance driver for Wacom tablets on Apple Silicon and Intel Macs running macOS 13+. It has the potential to power older tablets with full pressure and tilt support.

**Why you might care:** Wacom makes excellent hardware, but like any venture, can't support old, discontinued products indefinitely.  Reliable and perfectly healthy equipment becomes increasingly incompatible with the newer computing and operating system demands.

---

## What's supported

**Tablets**
- Intuos 5 / Intuos Pro (all sizes)
- Intuos 3 / Intuos 4
- Cintiq 24HD
- Bamboo (some models)
- ~95 other Wacom models via auto-detection

**Features**
- Run different generations of abandoned Wacom tablets simultaneously
- Full pressure, tilt, and rotation support, depending on input device
- Wireless via USB dongle or Bluetooth
- Configurable tablet area, pressure curve, button mapping, display mapping
- Touch ring support
- App-specific settings
- Native application built upon Apple frameworks for ease of use and staying out of the way

**What's *not* supported**
- Tablets from other vendors (Xencelab, Huion, XP-Pen, etc.)
- Contemporary Wacom Tablets made after 2020
- System software older than macOS 13 (for now)
- Linux, BSD, Apple iOS / iPadOS, Android, Google ChromeOS, Microsoft Windows, Haiku, ReactOS, KolibriOS, Solaris, AmigaOS, MorphOS, AROS, SerenityOS, Redox
- Touch/gesture input (detected but disabled disabled for now)
- Old tablets with a serial or ADB connection type

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

The open-source project [OpenTabletDriver](https://opentabletdriver.net) has expansive device compatibility and cross-platform support.  MockTab has more modest aims and focuses instead on macOS and Wacom hardware.

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
- [Troubleshooting](TROUBLESHOOTING.md)
