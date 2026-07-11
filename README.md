# MockTab

Native Mac driver for Wacom drawing tablets that no longer have official support.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![License: GPL-3](https://img.shields.io/badge/license-GPL--3-blue)

---

## Supported hardware

Several Wacom models across multiple families:

- **Intuos 1–5 / Intuos Pro Gen 1** (PTH-x50/x51, PTZ, PTK series) — USB
- **Intuos Pro Gen 2** (PTH-460, PTH-660, PTH-860) — USB and Bluetooth Classic
- **Intuos Pro Gen 3** (PTK-470, PTK-670, PTK-870) — USB, experimental
- **Cintiq** pen displays (CintiqV1 and IntuosV2-format models)
- **DTU / DTUS** small pen displays — USB, experimental
- **Bamboo** and consumer CTL/CTH tablets
- **Xencelabs Pen Display** bundle — pen and Quick Keys puck, wired and wireless

Full list: [mocktab.org/hardware](https://mocktab.org/hardware.html)

For other devices, MockTab might not work with your configuration yet. Filing an issue with diagnostic detail can help improve support.

---

## Requirements

macOS 13 (Ventura) or later.

---

## Install

1. Download the latest `.dmg` from [Releases](https://github.com/Cyzor/tablet-driver/releases).
2. Drag `MockTab.app` to Applications and launch it.
3. **Grant Accessibility** when prompted — MockTab needs this for pen pressure. Open System Settings, toggle MockTab on, then relaunch.
4. **Grant Input Monitoring** if prompted.
5. Plug in or pair your tablet. It appears in the menu bar.

**If permissions don't seem to take effect:** remove MockTab from the pane and re-add it. Moving or reinstalling the app may invalidate previous approvals.

---

## Building from source

```sh
git clone --recurse-submodules https://github.com/Cyzor/tablet-driver.git
cd tablet-driver
open MockTab.xcodeproj
```

Requires Xcode 15 or later. Select the **MockTab** scheme and build. If you're
building a fork, switch code signing to your own team in the project's Signing
& Capabilities tab.

Existing clone without `--recurse-submodules`? Run `git submodule update --init`.

To run the decoder test suite: `cd TabletKit && swift test`.

---

## Screenshots

<img src="https://raw.githubusercontent.com/Cyzor/mocktab-web/main/images/ui/tablet-area-dark.png" alt="Tablet area settings" width="480">
<img src="https://raw.githubusercontent.com/Cyzor/mocktab-web/main/images/ui/pen-feel-dark.png" alt="Pressure curve editor" width="480">
<img src="https://raw.githubusercontent.com/Cyzor/mocktab-web/main/images/ui/buttons-dark.png" alt="Button mapping" width="480">

---

## Features

- **Tablet area mapping** — choose which part of the surface maps to the screen
- **Pressure curve** — curve editor with Linear, Soft, and Firm presets
- **Button mapping** — remap barrel buttons, express keys, and touch ring to any modifier + key combination
- **Per-app overrides** — customized settings that activate automatically
- **Touch ring** — multiple slots, each with its own clockwise/counterclockwise binding
- **Display mapping** — route the tablet to any connected display
- **Live scratchpad** — test pressure, tilt, and button assignments
- **Profile import/export** — save and restore profile configurations
- **Multiple tablets** — connect multiple tablets simultaneously
- **Wireless** — Bluetooth and USB dongle protocols
- **Capacitive touch** — two-finger scroll, tap-to-click, and adjustable touch area on supported models
- **Menu bar mode** — hides the Dock icon
- **Native AppKit** app, signed and notarized, without kernel extensions

---

## Incomplete or unsupported

- Huion, XP-Pen, or any other non-Wacom hardware besides Xencelabs
- Wacom tablets from recent product cycles not listed above (Cintiq Pro 2023 refresh, etc.)
- Windows, Linux, or iPad

---

## TabletKit

MockTab relies on [**TabletKit**](https://github.com/Cyzor/TabletKit), a Swift package that decodes raw HID reports into pen coordinates, pressure, tilt, rotation, and touch events. `MockTab/Driver/` contains the app-specific glue (IOKit transport, event injection, device routing) that depends on TabletKit but is not part of it.

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

It has no AppKit or system-event dependencies of its own; everything it does is driven off a registry of known devices, so it can run in any Swift context.

The public API is still at 0.1 (see [CHANGELOG.md](https://github.com/Cyzor/TabletKit/blob/main/CHANGELOG.md)) — workable today, but expect some breaking changes before 1.0, particularly once a second non-Wacom vendor lands and exercises the registry shape more.

TabletKit lives here as a git submodule at `TabletKit/`, pinned to the commit MockTab builds against:

```sh
git clone --recurse-submodules https://github.com/Cyzor/tablet-driver.git
```

Already cloned without `--recurse-submodules`? Run `git submodule update --init`. Decoder work happens directly in the submodule and is committed to the TabletKit repo, not here. Its test suite runs the same way: `cd TabletKit && swift test`.

---

## License

The app is **GPL-3.0-or-later** — see [`LICENSE`](LICENSE). Free to run, study, modify, and share; modifications must stay under the same license.

The TabletKit Swift package lives in the [TabletKit repo](https://github.com/Cyzor/TabletKit) and is **MPL-2.0** — see [`LICENSES/MPL-2.0.txt`](https://github.com/Cyzor/TabletKit/blob/main/LICENSES/MPL-2.0.txt). Changes to TabletKit's own files must stay open, but consumers can link it from any-licensed project.

Per-file licenses are declared via SPDX headers (`SPDX-License-Identifier:`) at the top of each source file.

---

## Acknowledgments

MockTab's protocol knowledge and device data draw from several open-source projects. TabletKit's non-Wacom registry entries are pulled from **[OpenTabletDriver](https://github.com/OpenTabletDriver/OpenTabletDriver)**'s per-vendor JSON configurations — still the most comprehensive public database of tablet PIDs and dimensions across vendors. The **[wacom-hid-descriptors](https://github.com/linuxwacom/wacom-hid-descriptors)** corpus shaped decoder development across multiple tablet families, and **[libwacom](https://github.com/linuxwacom/libwacom)** is the authority we check Wacom physical dimensions against whenever the kernel's own constants look off. Report formats and protocol constants ultimately trace back to **[input-wacom](https://github.com/linuxwacom/input-wacom)** and the Linux kernel HID subsystem; several decoder field mappings follow that source directly.

---

## Contributing

Bug reports, device-support requests, translation corrections, and decoder work are all in scope — see [`Contributing.md`](Contributing.md) for how each is handled. Decoder PRs belong on [TabletKit](https://github.com/Cyzor/TabletKit). Forking is a first-class option if MockTab doesn't fit your needs.

For decoder analysis, `tools/wacom_capture.d` is a dtrace script that records raw USB traffic before any decoder interprets it. Higher fidelity than the in-app capture flow, but requires disabling System Integrity Protection. See [TabletKit's CONTRIBUTING](https://github.com/Cyzor/TabletKit/blob/main/Contributing.md#data-sources-in-order-of-confidence) for the full hierarchy of data sources.

---

## Troubleshooting

If the tablet light is on but Wacom Center shows "No device connected", or Wacom's installer says "Supported tablet not found", the official driver has likely dropped your model. See [mocktab.org/troubleshooting.html](https://mocktab.org/troubleshooting.html) for symptoms, affected hardware, and steps to try.

For post-install issues (pressure not working, conflict warning, tablet not recognized), the same page covers each case.

## Resources

- [CHANGELOG.md](CHANGELOG.md) — release history
- [mocktab.org](https://mocktab.org) — website and FAQ
- [Hardware compatibility](https://mocktab.org/hardware.html) — full device list
- [Troubleshooting](https://mocktab.org/troubleshooting.html) — common problems and fixes
- [Issues](https://github.com/Cyzor/tablet-driver/issues) — bug reports and feature requests
