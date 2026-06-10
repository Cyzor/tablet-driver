# MockTab

Native Mac driver for Wacom drawing tablets that no longer have official support on macOS.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![License: GPL-3](https://img.shields.io/badge/license-GPL--3-blue)

---

Drawing tablet equipment tends to outlast its driver support. MockTab aims to be a small, focused Mac driver for Wacom tablets from the early 2000s through the early 2020s, on macOS Ventura and later.

---

## Supported hardware

Several Wacom models across multiple families:

- **Intuos 1–5 / Intuos Pro Gen 1** (PTH-x50/x51, PTZ, PTK series) — USB
- **Intuos Pro Gen 2** (PTH-460, PTH-660, PTH-860) — USB and Bluetooth Classic
- **Intuos Pro Gen 3** (PTK-470, PTK-670, PTK-870) — USB, experimental
- **Cintiq** pen displays (CintiqV1 and IntuosV2-format models)
- **DTU / DTUS** small pen displays — USB, experimental
- **Bamboo** and consumer CTL/CTH tablets

Full list: [mocktab.org/hardware](https://mocktab.org/hardware.html)

For other devices, MockTab might not work with your configuration yet. Filing an issue with a diagnostic detail can help improve support.

---

## Requirements

macOS 13 (Ventura) or later.

---

## Install

1. Download the latest `.dmg` from [Releases](https://github.com/Cyzor/tablet-driver/releases).
2. Drag `MockTab.app` to Applications and launch it.
3. **Grant Accessibility** when prompted — click "Open System Settings", toggle MockTab on, relaunch. MockTab needs this to provide pen pressure.
4. **Grant Input Monitoring** if prompted.
5. Plug in or pair your tablet. It appears in the menu bar.

**If permissions don't seem to take effect:** remove MockTab from the pane and re-add it. Moving or reinstalling the app may invalidate previous approvals.

---

## Screenshots

<img src="https://raw.githubusercontent.com/Cyzor/mocktab-web/main/images/ui/tablet-area-dark.png" alt="Tablet area settings" width="480">
<img src="https://raw.githubusercontent.com/Cyzor/mocktab-web/main/images/ui/pen-feel-dark.png" alt="Pressure curve editor" width="480">
<img src="https://raw.githubusercontent.com/Cyzor/mocktab-web/main/images/ui/buttons-dark.png" alt="Button mapping" width="480">

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
- **Capacitive touch** — two-finger scroll, tap-to-click, and adjustable touch area on models with a touch surface
- **Undo everywhere** — ⌘Z across every settings pane
- **Menu bar mode** — hides the Dock icon
- **Native AppKit** app, signed and notarized, without kernel extensions

---

## Currently Unsupported

- Huion, XP-Pen, Xencelabs, or any non-Wacom hardware
- Wacom tablets from recent product cycles not listed above (Cintiq Pro 2023 refresh, etc.)
- Windows, Linux, or iPad

---

## TabletKit

MockTab relies on a related Swift package called [**TabletKit**](https://github.com/Cyzor/TabletKit) to communicate with tablet devices.  TabletKit processes raw Human Interface Device (HID) data reports and decodes them into events such as pen coordinates, pressure, position, tilt, rotation, and touch detail.  Everything in `MockTab/Driver/` is app-specific glue (IOKit transport, event injection, device routing) that depends on TabletKit but lives in this repo, not the package.

```swift
// Package.swift of a consumer project
dependencies: [
    .package(url: "https://github.com/Cyzor/TabletKit", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "TabletKit", package: "TabletKit"),
    ]),
],
```

```swift
import TabletKit

var state = DecoderState()
var decoder: any TabletReportDecoder = IntuosV2Decoder()
let results = decoder.decode(report: ptr, length: len, spec: spec, state: &state, deviceFamily: "intuosProGen2")
```

**Scope.** TabletKit is a Swift package without AppKit or system event requirements. It decodes based on its registry of known devices.

**Stability.** The public API surface (see [CHANGELOG.md](https://github.com/Cyzor/TabletKit/blob/main/CHANGELOG.md)) is at 0.1 — workable but pre-1.0. Expect breaking changes until the first vendor outside Wacom lands and with further protocol validation.

**Checkout.** TabletKit is included as a git submodule at `TabletKit/`, pinned to the commit MockTab builds against. Clone with:

```sh
git clone --recurse-submodules https://github.com/Cyzor/tablet-driver.git
```

(For an existing clone: `git submodule update --init`.) The submodule is a full TabletKit checkout — decoder work happens there and is committed/pushed to the TabletKit repo directly.

**Tests.** TabletKit's test suite runs from the submodule (`cd TabletKit && swift test`).

---

## License

The app is **GPL-3.0-or-later** — see [`LICENSE`](LICENSE). Free to run, study, modify, and share; modifications must stay under the same license.

The TabletKit Swift package lives in the [TabletKit repo](https://github.com/Cyzor/TabletKit) and is **MPL-2.0** — see [`LICENSES/MPL-2.0.txt`](https://github.com/Cyzor/TabletKit/blob/main/LICENSES/MPL-2.0.txt). File-level copyleft: changes to TabletKit's own files must stay open, but consumers can link it from any-licensed app.

Per-file licenses are declared via SPDX headers (`SPDX-License-Identifier:`) at the top of each source file.

---

## Acknowledgments

MockTab's protocol knowledge and device data draw from several open-source projects:

- **[OpenTabletDriver](https://github.com/OpenTabletDriver/OpenTabletDriver)** — TabletKit's non-Wacom registry entries come from OTD's per-vendor JSON configurations, the most comprehensive public database of tablet PIDs and dimensions across vendors.
- **[wacom-hid-descriptors](https://github.com/linuxwacom/wacom-hid-descriptors)** — the linuxwacom HID descriptor corpus informed decoder development across multiple tablet families.
- **[libwacom](https://github.com/linuxwacom/libwacom)** — libwacom's tablet files are the authoritative source for Wacom physical dimensions; they cross-check and correct entries where the kernel's constants are inaccurate.
- **[input-wacom](https://github.com/linuxwacom/input-wacom) / Linux kernel HID subsystem** — the kernel driver is the canonical reference for Wacom report formats and protocol constants; several decoder field mappings follow kernel source directly.

---

## Contributing

Bug reports, device-support requests, translation corrections, and decoder work are all in scope — see [`CONTRIBUTING.md`](CONTRIBUTING.md) for how each is handled. Decoder PRs belong on [TabletKit](https://github.com/Cyzor/TabletKit). Forking is a first-class option if MockTab doesn't fit your needs.

For decoder analysis, `tools/wacom_capture.d` is a dtrace script that records raw USB traffic before any decoder interprets it. Higher fidelity than the in-app capture flow, but requires disabling System Integrity Protection. See [TabletKit's CONTRIBUTING](https://github.com/Cyzor/TabletKit/blob/main/CONTRIBUTING.md#data-sources-in-order-of-confidence) for the full hierarchy of data sources.

---

## Troubleshooting

If the tablet light is on but Wacom Center shows "No device connected", or Wacom's installer says "Supported tablet not found", the official driver has likely dropped your model. See [mocktab.org/troubleshooting.html](https://mocktab.org/troubleshooting.html) for symptoms, affected hardware (Intuos 4, Intuos 5, Bamboo, and others), and steps to switch.

For post-install issues (pressure not working, conflict warning, tablet not recognized), the same page covers each case.

## Resources

- [mocktab.org](https://mocktab.org) — website and FAQ
- [Hardware compatibility](https://mocktab.org/hardware.html) — full device list
- [Troubleshooting](https://mocktab.org/troubleshooting.html) — common problems and fixes
- [Issues](https://github.com/Cyzor/tablet-driver/issues) — bug reports and feature requests
