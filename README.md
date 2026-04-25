# MockTab

Native tablet driver for modern Macs to bring discontinued Wacom drawing tablets back to life.

MockTab is a minimal, high-performance driver for Wacom tablets on Apple Silicon and Intel Macs running macOS 13+. It supports the full span of Wacom USB hardware from 1996 through the current generation, with full pressure, tilt, and rotation depending on hardware capabilities.

**Why you might care:** Wacom makes excellent hardware, but like any venture, can't support old, discontinued products indefinitely. Reliable and perfectly healthy equipment becomes increasingly incompatible with the newer computing and operating system demands.

---

## What's supported

**Features**
- Run different generations of abandoned Wacom tablets simultaneously
- Full pressure, tilt, and rotation support, depending on input device
- Wireless via USB dongle or Bluetooth
- Configurable tablet area, pressure curve, button mapping, display mapping
- Touch ring and touch strip support
- App-specific settings
- Native application built upon Apple frameworks for ease of use and staying out of the way

**What's *not* supported**
- Tablets from other vendors (Xencelab, Huion, XP-Pen, etc.)
- Contemporary Wacom tablets made after ~2020
- macOS older than macOS 13 (for now)
- Linux, BSD, Apple iOS / iPadOS, Android, Google ChromeOS, Microsoft Windows, Haiku, ReactOS, KolibriOS, Solaris, AmigaOS, MorphOS, AROS, SerenityOS, Redox
- Touch/gesture input (detected but disabled for now)
- Old tablets with a serial or ADB connection
- Graphire-family and original Bamboo (CTL/CTH-4xx) pen decoders (registered for future support; decoder not yet implemented)

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

## Hardware compatibility

All registered tablets and tools are listed below. Specs are sourced from the Linux kernel `wacom_wac.c` driver and OpenTabletDriver configs; many have been cross-checked against live hardware captures.

**Legend**
- ✓ &nbsp;Confirmed working on owned hardware
- ⚠ &nbsp;Decoder implemented; coordinates/pressure estimated from driver sources — untested on this specific hardware
- ✕ &nbsp;Registered for future support; decoder not yet implemented

---

### Tablets

#### PenPartner / Graphire (1996–2007)

Graphire-era consumer line. These share a compact 8-byte HID report format. The pen decoder is not yet implemented; all models in this family are registered for future support.

| Name | Connection | Year | Notes |
|------|-----------|------|-------|
| PenPartner | USB | 1996 | ✕ No eraser end |
| Graphire | USB | 1998 | ✕ |
| Graphire 2 (4×5) | USB | 2001 | ✕ |
| Graphire 2 (5×7) | USB | 2001 | ✕ |
| Graphire 3 (4×5) | USB | 2003 | ✕ |
| Graphire 3 (6×8) | USB | 2003 | ✕ |
| Graphire 4 (4×5) | USB | 2004 | ✕ |
| Graphire 4 (6×8) | USB | 2004 | ✕ |
| Volito | USB | 2003 | ✕ No eraser end |
| Volito 2 | USB | ~2004 | ✕ No eraser end |
| PenStation | USB | ~2003 | ✕ No eraser end |
| Bamboo One (CTF-430) | USB | 2007 | ✕ |
| Bamboo Fun (MTE-450) | USB | 2007 | ✕ |

---

#### Intuos 1 (1998–2002)

Original Intuos professional line. 10-byte reports, 1024-level pressure (10-bit).

| Name | Connection | Year | Notes |
|------|-----------|------|-------|
| Intuos 4×5 | USB | 1998 | ⚠ |
| Intuos 6×8 | USB | 1998 | ⚠ |
| Intuos 9×12 | USB | 1998 | ⚠ |
| Intuos 12×12 | USB | 1998 | ⚠ |
| Intuos 12×18 | USB | 1998 | ⚠ |

---

#### Intuos 2 (2002–2004)

| Name | Connection | Year | Notes |
|------|-----------|------|-------|
| Intuos 2 (4×5) | USB | 2002 | ⚠ |
| Intuos 2 (6×8) | USB | 2002 | ⚠ |
| Intuos 2 (9×12) | USB | 2002 | ⚠ |
| Intuos 2 (12×12) | USB | 2002 | ⚠ |
| Intuos 2 (12×18) | USB | 2002 | ⚠ |

---

#### Intuos 3 (2003–2006)

PTZ-series. 10-byte reports with a different status-byte layout from Intuos 1/2. Two-stage hardware initialization required. All models support Art Pen rotation.

| Name | Connection | Year | Notes |
|------|-----------|------|-------|
| Intuos3 4×5 (PTZ-431) | USB | 2003 | ⚠ 4 express keys |
| Intuos3 4×6 (PTZ-431W) | USB | 2004 | ⚠ 4 express keys |
| Intuos3 6×8 (PTZ-631) | USB | 2003 | ⚠ 8 express keys |
| Intuos3 6×8 WS (PTZ-631W) | USB | 2004 | ✓ 8 express keys, dual touch strips |
| Intuos3 9×12 (PTZ-930) | USB | 2003 | ⚠ 8 express keys |
| Intuos3 12×12 (PTZ-1231) | USB | 2005 | ⚠ 8 express keys |
| Intuos3 12×19 (PTZ-1231W) | USB | 2004 | ⚠ 8 express keys |

---

#### Intuos 4 (2009–2012)

PTK-series. OLED labels on each express key. 11-bit pressure (2048 levels). Touch ring per tablet. Art Pen rotation supported.

| Name | Connection | Year | Notes |
|------|-----------|------|-------|
| Intuos4 S (PTK-440) | USB | 2009 | ⚠ 8 express keys, touch ring |
| Intuos4 M (PTK-640) | USB | 2009 | ⚠ 8 express keys, touch ring |
| Intuos4 L (PTK-840) | USB | 2009 | ⚠ 8 express keys, touch ring |
| Intuos4 XL (PTK-1240) | USB | 2009 | ⚠ 8 express keys, touch ring |
| Intuos4 WL (PTK-540WL) | USB, Wireless | 2010 | ⚠ 8 express keys, touch ring |
| PTK-450 | USB | 2009 | ⚠ |
| PTK-650 | USB | 2009 | ⚠ |

---

#### Intuos 5 / Intuos Pro Gen 1 (2012–2015)

PTH-series. Rebrand from "Intuos5" to "Intuos Pro" mid-cycle; same HID format throughout. 11-bit pressure, touch ring.

| Name | Connection | Year | Notes |
|------|-----------|------|-------|
| Intuos5 S (PTH-450) | USB | 2012 | ⚠ 8 express keys, touch ring |
| Intuos5 M (PTH-650) | USB | 2012 | ⚠ 8 express keys, touch ring |
| Intuos5 L (PTH-850) | USB | 2012 | ⚠ 8 express keys, touch ring |
| Intuos Pro S (PTH-451) | USB | 2013 | ⚠ 8 express keys, touch ring |
| Intuos Pro M (PTH-651) | USB | 2013 | ⚠ 8 express keys, touch ring |
| Intuos Pro L (PTH-851) | USB | 2013 | ✓ 8 express keys, touch ring |

---

#### Intuos Pro Gen 2 (2017–present)

192-byte reports with 13-bit pressure (8192 levels). Bluetooth Classic and optional wireless dongle in addition to USB.

| Name | Connection | Year | Notes |
|------|-----------|------|-------|
| Intuos Pro S (PTH-460) | USB, Bluetooth | 2017 | ⚠ 8 express keys, touch ring |
| Intuos Pro M (PTH-660) | USB, Bluetooth, Wireless | 2017 | ✓ 8 express keys, touch ring |
| Intuos Pro L (PTH-860) | USB, Bluetooth, Wireless | 2017 | ✓ USB and Bluetooth confirmed; 8 express keys, touch ring |

---

#### Bamboo / Consumer CTL/CTH (2009–2019)

This family covers the Bamboo line and its successors marketed as "Bamboo", "Intuos", and "Wacom One" in different regions and generations. Pressure ranges from 1024 to 4096 levels depending on model; no tilt or rotation.

Models using the original Bamboo pen decoder (decoder not yet implemented) are marked ✕. Models in the same family that were later updated to use the IntuosV1 or IntuosV2 decoder are marked ⚠ and should theoretically work.

| Name | Connection | Year | Notes |
|------|-----------|------|-------|
| Bamboo Touch (CTT-460) | USB | 2009 | ✕ Touch-only, no pen |
| Bamboo Pen & Touch (CTH-460) | USB | 2009 | ✕ |
| Bamboo Capture (CTH-470) | USB | 2011 | ✕ |
| Bamboo Pen (CTL-460) | USB | 2009 | ✕ |
| Bamboo Pen (CTL-660) | USB | 2009 | ✕ |
| Bamboo Pen & Touch 2 (CTH-461) | USB | 2011 | ✕ |
| Bamboo Connect (CTL-470) | USB | 2011 | ✕ |
| CTE-460 | USB | ~2009 | ⚠ |
| CTE-650 | USB | ~2009 | ⚠ |
| CTE-660 | USB | ~2009 | ✕ |
| CTF-430 | USB | ~2007 | ✕ |
| CTH-300 | USB | ~2013 | ✕ |
| CTH-301 | USB | ~2013 | ✕ |
| CTH-461 | USB | ~2011 | ⚠ |
| CTH-470 | USB | ~2012 | ⚠ |
| CTH-480 | USB | ~2013 | ⚠ |
| CTH-490 | USB | ~2016 | ⚠ |
| CTH-661 | USB | ~2011 | ⚠ |
| CTH-670 | USB | ~2012 | ⚠ |
| CTH-680 | USB | ~2013 | ⚠ |
| CTH-690 | USB | ~2016 | ⚠ |
| CTL-470 | USB | ~2012 | ⚠ |
| CTL-471 | USB | ~2013 | ⚠ |
| CTL-472 | USB | ~2016 | ⚠ |
| CTL-480 | USB | ~2013 | ⚠ |
| CTL-490 | USB | ~2016 | ⚠ |
| CTL-671 | USB | ~2013 | ⚠ |
| CTL-672 | USB | ~2016 | ⚠ |
| CTL-680 | USB | ~2013 | ⚠ |
| CTL-690 | USB | ~2016 | ⚠ |
| CTL-4100 | USB | 2019 | ⚠ 4,096 pressure levels |
| CTL-4100WL | USB, Wireless | 2019 | ⚠ 4,096 pressure levels |
| CTL-6100 | USB | 2019 | ⚠ 4,096 pressure levels |
| CTL-6100WL | USB, Wireless | 2019 | ⚠ 4,096 pressure levels |

---

#### Cintiq Pen Displays (2002–present)

Pen displays with integrated screens. Older models (CintiqV1 family) use a 10-byte report format with an additional express-key report. Newer models (Cintiq 16 and later) use the same 192-byte format as Intuos Pro Gen 2.

| Name | Connection | Year | Notes |
|------|-----------|------|-------|
| Cintiq 21UX (DTZ-2100) | USB | 2002 | ✕ Original first-gen; distinct PL protocol; decoder not implemented |
| Cintiq 21UX (DTZ-2100) | USB | 2006 | ⚠ Second hardware revision; different PID, live decoder |
| Cintiq 12WX | USB | 2007 | ⚠ 8 express keys |
| Cintiq 20WSX | USB | 2008 | ⚠ 4 express keys |
| Cintiq 21UX 2 (DTZ-2100B) | USB | 2010 | ⚠ 8 express keys |
| Cintiq 22HD (DTK-2200) | USB | 2012 | ⚠ 8 express keys, touch ring |
| Cintiq 13HD (DTK-1300) | USB | 2012 | ⚠ |
| Cintiq 24HD (DTK-2400) | USB | 2012 | ✓ 8 express keys, dual touch rings |
| Cintiq 24HD Touch (DTH-2400) | USB | 2013 | ⚠ 8 express keys, dual touch rings, touch overlay |
| DTH-1320 | USB | ~2014 | ⚠ 8,192 pressure levels |
| Cintiq 16 (DTK-1660) | USB | 2018 | ⚠ 8,192 pressure levels |
| DTC-133 | USB | ~2019 | ⚠ 4,096 pressure levels |
| Cintiq Pro 27 (DTH-271) | USB | 2022 | ⚠ 8,192 pressure levels; 4 express keys |
| Movink 13 (DTH-135) | USB | 2024 | ⚠ 8,192 pressure levels; OLED display |

---

### Pens and tools

All tools listed below can be used on any compatible tablet from the indicated family. Erasers are the tail end of their parent pen; they share pressure and tilt capabilities.

#### Graphire / PenPartner era

| Name | Type | Tilt | Rotation | Notes |
|------|------|------|----------|-------|
| PenPartner Pen | Stylus | — | — | No eraser end; 256-level pressure |
| Graphire Pen | Stylus | — | — | 512-level pressure |
| Graphire Pen (Eraser) | Eraser | — | — | |
| Graphire Mouse | Mouse | — | — | |

#### Intuos 3

| Name | Type | Tilt | Rotation | Notes |
|------|------|------|----------|-------|
| Intuos3 Grip Pen (ZP-600) | Stylus | ✓ | — | 1024-level pressure |
| Intuos3 Grip Pen (Eraser) | Eraser | ✓ | — | |
| Art Pen (ZP-600) | Art Pen | ✓ | ✓ | Barrel rotation; ZP-600 model |
| Art Pen (Eraser) | Eraser | ✓ | ✓ | |
| Inking Pen (ZP-130) | Inking Pen | — | — | Ink cartridge; no eraser end |
| Intuos3 Inking Pen | Inking Pen | ✓ | — | |
| Intuos3 Inking Pen (Eraser) | Eraser | ✓ | — | |
| Airbrush (ZP-400E) | Airbrush | ✓ | — | Fingerwheel |
| Airbrush (Eraser) | Eraser | ✓ | — | |
| 2D Mouse (ZC-100) | Mouse | — | — | Scroll wheel |
| Mouse | Mouse | — | — | |
| Lens Cursor | Mouse | — | — | Large tablets only (PTZ-930, PTZ-1231) |

#### Intuos 4 / Intuos 5 / Intuos Pro Gen 1

| Name | Type | Tilt | Rotation | Notes |
|------|------|------|----------|-------|
| Grip Pen | Stylus | ✓ | — | Standard bundled pen; Intuos3–Pro Gen1 |
| Grip Pen (Eraser) | Eraser | ✓ | — | |
| Intuos4 Grip Pen | Stylus | ✓ | — | Intuos4/5 and Cintiq variant |
| Intuos4 Grip Pen (Eraser) | Eraser | ✓ | — | |
| Art Pen | Art Pen | ✓ | ✓ | Intuos3/4; barrel rotation |
| Art Pen (Eraser) | Eraser | ✓ | ✓ | |
| Art Pen (0x1804) | Art Pen | ✓ | ✓ | Intuos4/5 and Cintiq extended ID |
| Art Pen (0x1804, Eraser) | Eraser | ✓ | ✓ | |
| Art Pen 2 | Art Pen | ✓ | ✓ | Intuos5 / Intuos Pro Gen 1 |
| Art Pen 2 (Eraser) | Eraser | ✓ | ✓ | |
| Marker Pen | Art Pen | ✓ | ✓ | Intuos4; limited market |
| Marker Pen (Eraser) | Eraser | ✓ | ✓ | |
| Inking Pen | Inking Pen | ✓ | — | Intuos4/5 |
| Inking Pen (Eraser) | Eraser | ✓ | — | |
| Airbrush (KP-400E-2) | Airbrush | ✓ | — | Intuos4/5; fingerwheel |
| Airbrush (Eraser) | Eraser | ✓ | — | |
| Pen 5K | Stylus | ✓ | — | 2048-level pressure; Intuos Pro Gen1 |
| Pen 5K (Eraser) | Eraser | ✓ | — | |
| Intuos Mouse | Mouse | — | — | Intuos4/5 |
| Lens Cursor | Mouse | — | — | |

#### Intuos Pro Gen 2

| Name | Type | Tilt | Rotation | Notes |
|------|------|------|----------|-------|
| Pro Pen 2 | Stylus | ✓ | — | 8192-level pressure; bundled with PTH-660/860 |
| Pro Pen 2 (Eraser) | Eraser | ✓ | — | |
| Pro Pen 3 | Stylus | ✓ | — | 8192-level pressure; bundled with PTH-860 |
| Pro Pen 3 (Eraser) | Eraser | ✓ | — | |
| Art Pen (0x1108) | Art Pen | ✓ | ✓ | Rotation available over USB; confirmed from live capture |
| Pen 4K | Stylus | ✓ | — | 4096-level pressure; consumer Wacom One line |
| Pen 4K (Eraser) | Eraser | ✓ | — | |

#### Bamboo / CTL/CTH consumer

| Name | Type | Tilt | Rotation | Notes |
|------|------|------|----------|-------|
| Bamboo Pen | Stylus | — | — | 1024-level pressure; no tilt |
| Bamboo Pen (Eraser) | Eraser | — | — | |
| Bamboo Touch | Touch | — | — | Capacitive finger contact; detected but not processed |

---

## Compatibility

Works with Photoshop, Affinity, Illustrator, Krita, GIMP, Blender, and any app that reads `NSEvent` tablet events or uses the standard pressure APIs. See the [detailed compatibility chart](COMPATIBILITY.md) for app-specific notes.

---

## Why this exists

The open-source project [OpenTabletDriver](https://opentabletdriver.net) has expansive device compatibility and cross-platform support. MockTab has more modest aims and focuses instead on macOS and Wacom hardware.

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

- [Build & development](DEVELOPMENT.md)
- [Troubleshooting](TROUBLESHOOTING.md)
