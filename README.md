# MockTab

Mac driver for Wacom drawing tablets that no longer have official support.

One self-contained app. Responsive pen input is its top priority.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![License: GPL-3](https://img.shields.io/badge/license-GPL--3-blue)

MockTab is a community project, not affiliated with Wacom Co., Ltd. or Xencelabs. Product names describe compatibility only.

***

## Supported hardware

MockTab supports these Wacom families:

- **Intuos 1–5 / Intuos Pro Gen 1** (PTH-x50/x51, PTZ, PTK series), USB.
- **Intuos Pro Gen 2** (PTH-460, PTH-660, PTH-860), USB and Bluetooth.
- **Intuos Pro Gen 3** (PTK-470, PTK-670, PTK-870), USB, experimental.
- **Cintiq** pen displays, including CintiqV1 and IntuosV2-format models.
- **DTU / DTUS** small pen displays, USB, experimental.
- **Bamboo** and consumer CTL/CTH tablets.
- **Xencelabs Pen Display** and Quick Keys remote, wired and wireless.

Full list: [mocktab.org/hardware](https://mocktab.org/hardware.html)

Other tablets may not work yet.  For support, file an issue with the data from **Help › Collect Device Data…**

***

## Requirements

- macOS 13 Ventura or later.

***

## Install

1. Download the latest `.dmg` from [Releases](https://github.com/Cyzor/tablet-driver/releases). [Snapshots](https://github.com/Cyzor/tablet-driver/releases/tag/snapshot) are newer but may be incomplete.
2. Drag `MockTab.app` to Applications and launch it.
3. Grant **Accessibility** if asked.
4. Grant **Input Monitoring** if asked.
5. Plug in or pair your tablet.

If a permission has no effect, remove MockTab from the list and add it again. Moving or reinstalling the app can undo earlier permissions.

***

## Screenshots

| Tablet area | Pen feel |
|:---:|:---:|
| <img src="https://raw.githubusercontent.com/Cyzor/mocktab-web/main/images/ui/tablet-area-dark.png" alt="Tablet area settings" width="400"> | <img src="https://raw.githubusercontent.com/Cyzor/mocktab-web/main/images/ui/pen-feel-dark.png" alt="Pressure curve editor" width="400"> |
| **Button mapping** | **Display mapping** |
| <img src="https://raw.githubusercontent.com/Cyzor/mocktab-web/main/images/ui/buttons-dark.png" alt="Button mapping" width="400"> | <img src="https://raw.githubusercontent.com/Cyzor/mocktab-web/main/images/ui/displays-dark.png" alt="Display mapping" width="400"> |
| **Touch** | **Scratchpad** |
| <img src="https://raw.githubusercontent.com/Cyzor/mocktab-web/main/images/ui/touch-dark.png" alt="Touch settings" width="400"> | <img src="https://raw.githubusercontent.com/Cyzor/mocktab-web/main/images/ui/scratchpad-dark.png" alt="Scratchpad" width="400"> |

***

## Features

- Map the tablet to any part of any display.
- Tune pressure and pen feel.
- Assign pen buttons, ExpressKeys, touch rings, and dials.
- Give each app its own settings.
- Connect over USB, Bluetooth, or a USB dongle.
- Touch to scroll, zoom, rotate, and click, when available.
- Test input in a live scratchpad.
- Import and export profiles.
- Hide the Dock icon and run from the menu bar.
- Connect tablets across different generations at the same time.
- Low-latency pen performance.
- One self-contained, signed, and notarized app, with no background services or launchers.

***

## Incomplete/Not planned

- Huion, XP-Pen, and other makers besides Xencelabs.
- Recent Wacom models. Without further testing, support is experimental.
- Windows, Linux, and iPad.

***

## Build from source

```sh
git clone --recurse-submodules https://github.com/Cyzor/tablet-driver.git
cd tablet-driver
open MockTab.xcodeproj
```

You need Xcode 26 or later. Select the **MockTab** scheme and build. To build a fork, set signing to your own team under Signing & Capabilities.

If you cloned without `--recurse-submodules`, run `git submodule update --init`. To run the TabletKit tests, run `swift test` in `TabletKit/`.

***

## TabletKit

[TabletKit](https://github.com/Cyzor/TabletKit) is the Swift package that turns a tablet's raw reports into pen position, pressure, tilt, rotation, and touch. It has no AppKit dependencies, so it works in any Swift project. See its [README](https://github.com/Cyzor/TabletKit#add-it-to-your-project) to add it to yours.

It lives here as a git submodule at `TabletKit/`.

***

## License

The app is **GPL-3.0-or-later** ([`LICENSE`](LICENSE)). You can run, study, change, and share it. Changed versions must keep the same license.

TabletKit is **MPL-2.0** ([`LICENSES/MPL-2.0.txt`](https://github.com/Cyzor/TabletKit/blob/main/LICENSES/MPL-2.0.txt)). Changes to its own files must stay open, but any project can use it, whatever its license.

Each file names its license in an `SPDX-License-Identifier:` header.

***

## Acknowledgments

MockTab builds on several open-source projects. [OpenTabletDriver](https://github.com/OpenTabletDriver/OpenTabletDriver) supplies all of TabletKit’s non-Wacom tablet entries and some Wacom ones. [wacom-hid-descriptors](https://github.com/linuxwacom/wacom-hid-descriptors) guided decoders for many tablet families, and [libwacom](https://github.com/linuxwacom/libwacom) supplies Wacom tablet sizes. Much of the report format knowledge traces back to [input-wacom](https://github.com/linuxwacom/input-wacom) and the Linux kernel.

***

## Contributing

Options to help include filing bug reports, providing hardware details, improving localization, and revising decoders. See [`Contributing.md`](Contributing.md). Decoder pull requests go to [TabletKit](https://github.com/Cyzor/TabletKit).

See [TabletKit’s Contributing notes](https://github.com/Cyzor/TabletKit/blob/main/Contributing.md#work-out-a-new-format) for an overview of analyzing tablet behavior.

***

## Troubleshooting

Wacom’s official driver may still work with some coaxing. If the tablet light is on but Wacom Center shows “No device connected,” or Wacom’s installer says “Supported tablet not found,” Wacom has likely retired your model. [Troubleshooting](https://mocktab.org/troubleshooting.html) covers symptoms, affected tablets, and steps to try, plus problems after installing MockTab.

## Resources

- [CHANGELOG.md](CHANGELOG.md) — release history.
- [mocktab.org](https://mocktab.org) — website and FAQ.
- [Hardware compatibility](https://mocktab.org/hardware.html) — full device list.
- [Tablet protocol notes](Notes/README.md) — report formats for Wacom and Xencelabs tablets, and how Mac apps read tablet events.
- [Troubleshooting](https://mocktab.org/troubleshooting.html) — common problems and fixes.
- [Issues](https://github.com/Cyzor/tablet-driver/issues) — bug reports and feature requests.
