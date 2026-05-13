# MockTab

Native macOS driver for Wacom drawing tablets that no longer have official support on modern macOS releases.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![License: GPL-3](https://img.shields.io/badge/license-GPL--3-blue)

---

Wacom hardware tends to outlast its driver support. MockTab aims to be a small, focused driver for Wacom tablets from the early 2000s up to roughly 2020, on macOS Ventura and later.

---

## Supported hardware

Several Wacom models across five families:

- **Intuos** — every generation (Intuos 1 through Intuos Pro Gen 2)
- **Cintiq** pen displays (DTK-2400)
- **Bamboo** and consumer CTL/CTH tablets
- **Intuos Pro Gen 2** (PTH-460, PTH-660, PTH-860) — USB and Bluetooth

Full list: [mocktab.org/hardware](https://mocktab.org/hardware.html)

MockTab covers a small set of hardware so far and may not work with your configuration. Filing an issue with a diagnostic detail can help improve support.

---

## Install

1. Download the latest `.dmg` from [Releases](https://github.com/Cyzor/mocktab-app/releases).
2. Drag `MockTab.app` to Applications and launch it.
3. **Grant Accessibility** when prompted — click "Open System Settings", toggle MockTab on, relaunch. MockTab needs this to provide pen pressure.
4. **Grant Input Monitoring** if prompted — same flow. Some configurations work without it; grant it to be safe.
5. Plug in or pair your tablet. It appears in the menu bar.

**If permissions don't seem to take effect:** remove MockTab from the pane and re-add it. Moving or reinstalling the app may invalidate previous approvals.

---

## Screenshots

<img src="https://github.com/Cyzor/mocktab-web/blob/main/images/ui/tablet-area-light.png" alt="Tablet area settings" width="480">
<img src="https://github.com/Cyzor/mocktab-web/blob/main/images/ui/pen-feel-light.png" alt="Pressure curve editor" width="480">
<img src="https://github.com/Cyzor/mocktab-web/blob/main/images/ui/buttons-light.png" alt="Button mapping" width="480">

---

## Features

- **Tablet area mapping** — choose which part of the surface maps to the screen; proportional lock keeps circles round at any aspect ratio
- **Pressure curve** — two-point Bézier editor with Linear, Soft, and Firm presets; tested with Photoshop, Affinity, Krita, and Clip Studio
- **Button mapping** — remap barrel buttons, express keys, and touch ring to any modifier + key combination; live key capture
- **Per-app overrides** — different area, pressure curve, buttons, and display routing per app; switches automatically when the app comes forward
- **Touch ring** — multi-slot modes with per-slot clockwise/counter-clockwise actions; cycle slots with a button assignment
- **Display mapping** — route the tablet to any connected display; Display Toggle action cycles displays from a button
- **Live scratchpad** — test pressure, tilt, and button assignments before opening your real work
- **Profile import/export** — drag a profile card to Finder to export as JSON; drag a file back in to import
- **Multiple tablets** — connect several tablets simultaneously; switches automatically based on which one you pick up
- **Wireless** — USB dongle and Bluetooth where hardware supports it
- **Undo everywhere** — ⌘Z across every settings pane
- **Menu bar mode** — hides the Dock icon
- Native AppKit app, signed and notarized, without kernel extensions

---

## What it doesn't do

- Huion, XP-Pen, Xencelabs, or any non-Wacom hardware
- Post-2020 Wacom tablets
- Windows, Linux, or iPad
- Touch and gesture input (detected but not processed)

---

## License

GPL-3. See `LICENSE`. Free to run, study, modify, and share — modifications must stay under the same license.

---

## More

- [mocktab.org](https://mocktab.org) — website and FAQ
- [Hardware compatibility](https://mocktab.org/hardware.html) — full device list
- [Issues](https://github.com/Cyzor/mocktab-app/issues) — bug reports and feature requests
