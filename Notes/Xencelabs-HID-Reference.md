2026-05-23

# Xencelabs Drawing Tablets

## 1. USB Enumeration Identifiers

All currently confirmed Xencelabs devices share **Vendor ID `0x28BD`** (decimal 10429). The kernel's `hid-ids.h` assigns this vendor symbol to `USB_VENDOR_ID_UGEE` — Xencelabs hardware is manufactured by Hanvon UGEE, as confirmed by the `Manufacturer` string reported in every user-submitted HID diagnostic.[^1][^2]

### Confirmed Product IDs

| Device | Model Number | VID (hex) | PID (hex) | PID (dec) | Manufacturer String |
|---|---|---|---|---|---|
| Pen Tablet Medium (USB/wired) | BPH1012W-A | `0x28BD` | `0x5201` | 20993 | `HANVON UGEE` |
| Pen Tablet Medium (variant B) | BPH1012W-A | `0x28BD` | `0x5201` | 20993 | `HANVON UGEE` |
| Pen Tablet Small | BPH0812W-A | `0x28BD` | `0x5204` | 20996 | `HANVON UGEE` |
| Dongle (wireless receiver) | ACD12-A | `0x28BD` | `0x5203` | 20995 | `HANVON UGEE` |
| Pen Display 24 | LPH2412U-A | `0x28BD` | `0x520A` | 21002 | `hanvon ugee` |
| Pen Display 16 (requested) | LPH1612U-A | `0x28BD` | *(not yet in OTD)* | — | — |
| Quick Keys Remote (puck) | K02-A | `0x28BD` | `0x5202` | 20994 | — |
| Pen Display (MockTab-confirmed) | — | `0x28BD` | `0x520D` | 21005 | — |

> **Notes:**
> - PID `0x5201` and `0x5204` are **not** present in the mainline Linux kernel `hid-ids.h` or any `hid-uclogic` / `wacom` device table as of kernel 6.15. No in-tree kernel driver exists for these devices.[^1]
> - The Pen Display 24 (PID `0x520A`) was confirmed via a live HID diagnostic dump on Linux 6.15.7.[^2]
> - The dongle (PID `0x5203`) enumerates as **two** HID interfaces (interface 0 and interface 1) with different report lengths — see Section 3.
> - **`0x520A` vs `0x520D`:** MockTab's own macOS captures (2026-07) consistently report the Pen Display at PID `0x520D`, not `0x520A`. Left both rows in the table rather than assuming they're the same hardware — could be a distinct pen-display model/revision, unconfirmed either way.
> - Section 10 below (Quick Keys) predates MockTab's own protocol work and is now superseded for the puck/dongle — see the note there.

***

## 2. Digitizer Active Area & Coordinate Space

| Parameter | Pen Tablet Medium | Pen Tablet Small |
|---|---|---|
| **Active area (mm)** | 261.62 × 148.00 mm | 176.10 × 99.05 mm |
| **Active area (official)** | ~10.3 × 5.8 in | 6.93 × 3.89 in |
| **Aspect ratio** | 16:9 | 16:9 |
| **Max X (logical units)** | 52324 | 35600 |
| **Max Y (logical units)** | 29600 | 20200 |
| **Resolution (derived X)** | 52324 / 261.62 mm ≈ **200 LU/mm (5080 LPI)** | 35600 / 176.10 mm ≈ **202 LU/mm (~5080 LPI)** |
| **Resolution (derived Y)** | 29600 / 148.00 mm ≈ **200 LU/mm** | 20200 / 99.05 mm ≈ **204 LU/mm** |

These values come directly from OTD's `Specifications.Digitizer` block. The derived LPI (~5080) is consistent with the 5080 LPI figure reported by the Pen Display 24 support request, confirming the same sensor family.[^3][^1]

***

## 3. HID Interface Layout

### Pen Tablet Medium (PID `0x5201`)

The device enumerates with **at least two HID interfaces** on the same USB configuration:[^2]

| Interface | `InputReportLength` | `OutputReportLength` | `FeatureReportLength` | Role |
|---|---|---|---|---|
| Interface 0 (hidraw N) | **8** | 0 | 0 | Mouse/keyboard fallback (standard HID) |
| Interface 1 (hidraw N+1) | **10** | **0 or 32** | 0 | Tablet digitizer (pen + aux) |
| Interface 2 (hidraw N+2) | **10** | **0 or 33** | 0 | Tablet digitizer (variant — see OTD variant B below) |

OTD defines two `DigitizerIdentifiers` entries for the Medium, differing only in `OutputReportLength` (32 vs. 33). This accommodates firmware variants. A driver should attempt initialization with the 32-byte output first; fall back to 33-byte if the tablet does not respond correctly.[^3]

### Pen Tablet Small (PID `0x5204`)

| Interface | `InputReportLength` | `OutputReportLength` | `FeatureReportLength` | Role |
|---|---|---|---|---|
| Interface 0 | **8** | 0 | 0 | Standard HID fallback |
| Interface 1 | **10** | **33** | 0 | Tablet digitizer |

### Dongle / Wireless Receiver (PID `0x5203`)

The wireless dongle also presents two interfaces:[^2]

| Interface | `InputReportLength` | `OutputReportLength` | HID_REPORTS string |
|---|---|---|---|
| Interface 0 | **8** | 0 | `09:0001:0002, 06:0001:0006` |
| Interface 1 | **10** | 0 | `07:000D:0002` |

Interface 1's report descriptor (`07:000D:0002`) matches the digitizer interface — report ID `0x07`, HID usage page `0x000D` (Digitizer), 2-byte count. The driver binds to **interface 1** for pen data when using the dongle.

### Pen Display 24 (PID `0x520A`)

| Interface | `InputReportLength` | `OutputReportLength` | HID_REPORTS string |
|---|---|---|---|
| Interface 0 | **8** | 0 | `09:0001:0002, 01:0001:0002, 06:0001:0006` |
| Interface 1 | **10** | 0 | `07:000D:0002` |

Same digitizer interface layout as the dongle — report ID `0x07`, usage page `0x000D`.[^2]

***

## 4. Initialization Sequence

All Xencelabs pen tablet devices require an **output report sent at startup** to switch the tablet into digitizer mode. OTD's configuration specifies:[^3]

```
OutputInitReport: ["ArAE"]
```

`"ArAE"` is a Base64-encoded byte sequence. Decoded:

```
Base64("ArAE") → bytes: 0x02, 0xB0, 0x04
```

This 3-byte payload is padded to the `OutputReportLength` (32 or 33 bytes, zero-padded) and sent as an **HID Output report** to the digitizer interface. Without this initialization, the tablet does not emit pen reports — it remains in its default HID mouse/keyboard mode.

The `libinputoverride` attribute is set to `"1"` for all Xencelabs tablets, meaning udev rules must tag these devices so that `libinput` does not attempt to claim the digitizer interface before the driver can open it.[^3]

***

## 5. Input Report Structure (10-byte digitizer report)

The OTD parser is `XenceLabsReportParser`, with the tablet report struct defined in `XenceLabsTabletReport.cs`.[^3]

### Report Byte Map

```
Byte  0:  Report ID (typically 0x07 for pen events)
Byte  1:  Status / flag byte
Byte  2:  X position, low byte   (little-endian uint16)
Byte  3:  X position, high byte
Byte  4:  Y position, low byte   (little-endian uint16)
Byte  5:  Y position, high byte
Byte  6:  Pressure, low byte     (little-endian uint16)
Byte  7:  Pressure, high byte
Byte  8:  Tilt X                 (signed int8, degrees)
Byte  9:  Tilt Y                 (signed int8, degrees)
```

### Status Byte (Byte 1) Bit Definitions

| Bit | Mask | Meaning |
|---|---|---|
| 0 | `0x01` | *(reserved / proximity, see note)* |
| 1 | `0x02` | Pen button 1 pressed |
| 2 | `0x04` | Pen button 2 pressed |
| 3 | `0x08` | Pen button 3 pressed |
| 4 | `0x10` | *(reserved)* |
| 5 | `0x20` | **Pen event valid** — this bit set means report is a `XenceLabsTabletReport` |
| 6 | `0x40` | **Eraser** end active |
| 7 | `0x80` | *(reserved)* |

Parser dispatch logic:[^3]
- If `(byte[^1] & 0xF0) == 0xF0` → auxiliary/express-key report (handled by `XP_PenAuxReport`)
- Else if `byte[^1].bit5 == 1` → pen digitizer report (`XenceLabsTabletReport`)
- Otherwise → generic `DeviceReport` (ignored by tablet handler)

> **Key contrarian note:** The Xencelabs parser **reuses** XP-Pen's `XP_PenAuxReport` for button events. This is not coincidental — both product lines originate from Hanvon UGEE and share a common firmware protocol for auxiliary buttons.[^1][^3]

***

## 6. Pen Pressure & Tilt

| Parameter | Value | Source |
|---|---|---|
| **MaxPressure (OTD logical units)** | **8191** (13-bit range, 0–8191) | OTD config[^3] |
| **Pressure levels (marketing)** | **8192 levels** | Official specs[^1][^2] |
| **Tilt axes** | X and Y, both signed int8 | OTD parser[^3] |
| **Tilt range** | ±60° (each axis) | Official spec[^4] |
| **Tilt encoding** | `(sbyte)report[^8]`, `(sbyte)report[^9]` | OTD parser[^3] |
| **Technology** | Battery-free EMR (Electro-Magnetic Resonance) | Official spec[^4] |
| **LPI (resolution)** | 5080 LPI | Derived + issue #3954[^2] |

The pressure value at byte[6:7] is a raw 16-bit little-endian read; values above 8191 should be clamped or treated as invalid. The OTD `MaxPressure` field is 8191, not 8192, because the range is **0-inclusive to 8191** (2¹³ − 1).

***

## 7. Auxiliary Button (Express Key) Report

When `(byte[^1] & 0xF0) == 0xF0`, the report is parsed as `XP_PenAuxReport`. This struct decodes up to **20 auxiliary buttons** and **2 analog wheel deltas**.[^3]

### Aux Report Byte Map (shared with XP-Pen firmware)

```
Byte  0:  Report ID
Byte  1:  Flag byte (upper nibble = 0xF, confirming aux report type)
Byte  2:  AuxButtons[ 0– 7]  — one bit per button (LSB = button 0)
Byte  3:  AuxButtons[ 8–15]
Byte  4:  AuxButtons[16–19]  — lower nibble only
Bytes 5–6: (unassigned in Xencelabs context)
Byte  7:  Wheel byte
          bit 0: Wheel 1 clockwise (+1)
          bit 1: Wheel 1 counter-clockwise (−1)
          bit 4: Wheel 2 clockwise (+1)
          bit 5: Wheel 2 counter-clockwise (−1)
Bytes 8–9: (padding)
```

OTD configures **3 auxiliary buttons** (`AuxiliaryButtons.ButtonCount: 3`) for both the Small and Medium tablets. This matches the 3 physical express keys on the tablet body. The remaining button bits in the aux report structure are unused in the Xencelabs context, though the struct technically supports up to 20.[^3]

### Pen Display onboard bezel buttons (confirmed 2026-07-14)

The Pen Display's three capacitive buttons built into its bezel ride **the exact same aux frame format** as the Quick Keys puck's express keys: report ID 2, tag `0xF0`, with bits 0–2 of the button bytes going one-hot on a clean tap. The wire format gives no way to tell a bezel-button frame from a puck express-key frame; the display has no puck of its own, so its driver-side handling remaps these frames to dedicated bezel-button slots (16–18 in the shared slot convention) rather than express-key slots. Confirmed by live capture during field testing.

***

## 8. Pen Hardware Specifications

Both the Pen Tablet Small and Medium ship with the same two pens:[^4]

| Parameter | 3 Button Pen (PH25 / PH26-A) | Thin Pen (PH6-A) |
|---|---|---|
| **Pen buttons** | 3 side buttons + eraser | 2 side buttons + eraser |
| **Pressure levels** | 8192 | 8192 |
| **Tilt range** | ±60° | ±60° |
| **Technology** | Battery-free EMR | Battery-free EMR |
| **Dimensions** | 157.56 × Ø14.73 mm | 157.54 × Ø9.5 mm |
| **Weight** | 17 g | 12 g |
| **Nib type** | Standard / Felt (interchangeable) | Standard / Felt |

From the driver perspective, **both pens use the same report format**. The `Eraser` flag (byte, bit 6) distinguishes eraser-end use. There is no separate pen-ID field in the protocol; a driver cannot distinguish which physical pen is in use — only which end (tip vs. eraser).[^5]

***

## 9. Pen Tablet Physical Specs

| Parameter | Pen Tablet Medium | Pen Tablet Small |
|---|---|---|
| **Model number** | BPH1012W-A | BPH0812W-A |
| **Dimensions (W × H × D)** | ~320 × 232 × ~8 mm | 234.18 × 184.66 × 8 mm |
| **Active area** | 261.62 × 148 mm | 176.10 × 99.05 mm |
| **Active area aspect ratio** | 16:9 | 16:9 |
| **Weight** | ~600 g (est.) | 398 g |
| **Connectivity** | USB-C wired + wireless | USB-C wired + wireless |
| **Wireless** | Dongle (2.4 GHz RF via ACD12-A) | Dongle (2.4 GHz RF) |
| **Battery life** | ~16 h | 16 h (2.5 h charge) |
| **Interface port** | USB-C | USB-C |

***

## 10. Quick Keys Remote

> **Superseded 2026-07:** the claims below (no confirmed PID, no open-source parser, Bluetooth wireless) predate MockTab's own reverse-engineering work and are no longer accurate for this transport. MockTab has fully decoded and implemented the wired and wireless-dongle protocol on macOS: puck PID `0x5202`, dongle PID `0x5203`, wireless transport is **2.4 GHz RF via the bundled dongle, not Bluetooth**. Full opcode-level detail lives in `Notes/Xencelabs-Quick-Keys-Puck-Reference.md`; the living implementation is `TabletKit/Sources/TabletKit/Decoders/XencelabsDecoder.swift`, `TabletKit/Sources/TabletKit/XencelabsControl.swift`, and `MockTab/Driver/WacomKnownDevice.swift`. Left the original text below for historical context (it may still be accurate for Linux/OpenTabletDriver's Bluetooth path, which MockTab has not tested).

The Quick Keys (model K02-A) is a **separate HID device** — it does not share a PID with the pen tablet. Its USB/wireless VID/PID is not present in the OTD configuration tree as of v0.6.x, meaning OTD does not natively support it. Linux users have reported it functions as a standard HID consumer-control device when connected via USB, but wireless connectivity (Bluetooth 5.0) can be unstable under certain compositors.[^6][^2]

| Parameter | Value |
|---|---|
| **Model** | K02-A |
| **Dimensions** | 157.6 × 62.5 × 12 mm |
| **Buttons** | 8 programmable per profile × 5 profiles = 40, plus 4 dial functions |
| **Dial** | Up to 4 modes (user-defined) |
| **Display** | OLED (shows shortcut labels) |
| **Connectivity** | USB-C wired + Bluetooth 5.0 wireless |
| **Protocol (USB)** | Standard HID consumer-control / vendor-defined |

To support the Quick Keys in a custom driver, a separate HID descriptor capture (via `usbhid-dump` or `hidrd-convert`) is required, as no open-source parser exists yet.

***

## 11. Kernel & Driver Ecosystem Status

| Layer | Status |
|---|---|
| **Linux mainline kernel** | No in-tree driver for any Xencelabs PID (`0x5201`, `0x5203`, `0x5204`, `0x520A`)[^1] |
| **hid-uclogic** | Handles some UGEE-family devices (XP-Pen), but does **not** include Xencelabs PIDs[^1] |
| **hid-wacom / xf86-input-wacom** | No Xencelabs support — wacom.c does not reference `0x28BD:0x52xx`[^1] |
| **OpenTabletDriver v0.6.x** | Supports Pen Tablet Small and Medium (full pen + tilt + aux)[^3] |
| **OpenTabletDriver — Pen Display 16/24** | Support requested (issues #3904, #3954); not yet merged as of mid-2025[^1] |
| **Xencelabs official Linux driver** | Closed-source `.deb`/`.rpm` package; users report instability under Wayland compositors (Hyprland, KDE)[^2] |
| **libinput** | Must be suppressed via udev `TAG+="uaccess"` + `libinputoverride=1`; otherwise claims the device before OTD can open it[^3] |

***

## 12. udev Rule Template

A minimal udev rule to grant userspace access to all confirmed Xencelabs digitizer interfaces:

```udev
# Xencelabs Pen Tablet Medium
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="28bd", ATTRS{idProduct}=="5201", TAG+="uaccess"
# Xencelabs Pen Tablet Small
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="28bd", ATTRS{idProduct}=="5204", TAG+="uaccess"
# Xencelabs Wireless Dongle
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="28bd", ATTRS{idProduct}=="5203", TAG+="uaccess"
# Xencelabs Pen Display 24
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="28bd", ATTRS{idProduct}=="520a", TAG+="uaccess"
# Suppress libinput on all UGEE/Xencelabs digitizers
SUBSYSTEM=="input", ATTRS{idVendor}=="28bd", ENV{LIBINPUT_IGNORE_DEVICE}="1"
```

OTD auto-generates this via `generate-rules.sh` by processing the JSON configuration tree.[^3]

***

## 13. Driver Implementation Checklist

A minimal user-space driver (e.g., via `hidapi` or a kernel `hid` driver) needs to:

1. **Enumerate**: Match VID `0x28BD` + PID from the table in Section 1.
2. **Select interface**: Open the HID interface with `InputReportLength == 10` (not the fallback 8-byte mouse interface).
3. **Initialize**: Send the decoded `OutputInitReport` (`0x02 0xB0 0x04`, zero-padded to `OutputReportLength`) as an HID Output report.
4. **Set udev/access rules**: Ensure `libinput` does not claim the device first.
5. **Read loop**: `read()` 10-byte input reports.
6. **Dispatch on byte**:[^5]
   - `(byte[^1] & 0xF0) == 0xF0` → aux/express-key path
   - `byte[^1] & 0x20` → pen digitizer path
7. **Parse pen report** per the byte map in Section 5.
8. **Clamp pressure** to range .
9. **Interpret tilt** as two signed bytes in degrees (range ±60°).
10. **Wireless**: When using the dongle (PID `0x5203`), bind to interface 1 (not interface 0).

***

## 14. Known Gaps & What Still Needs Capture

The following data requires a live HID descriptor capture (`sudo usbhid-dump -d 28bd:5201 | usbhid-dump` + `hidrd-convert`) or Wireshark USB trace to fully document:

- **Full HID Report Descriptor** for each interface (usage pages, logical min/max, unit exponents)
- **Feature reports**: Whether any feature report controls tablet configuration (e.g., pen pressure curve, tilt enable/disable)
- **Quick Keys VID/PID**: confirmed by MockTab (`0x5202` puck, `0x5203` dongle) — see Section 10 note and `Notes/Xencelabs-Quick-Keys-Puck-Reference.md`
- **Pen Display 16 PID**: Issue #3904 filed but no diagnostic dump attached[^1]
- **Firmware version query command**: Whether a vendor-specific HID report exists to read firmware version
- **Wireless protocol details**: Whether the RF dongle protocol differs from wired in any way beyond the interface layout

## 15. Display Color Controls (Pen Display, MockTab reverse-engineering)

> **MockTab-original, not from OTD/community sources.** Decoded 2026-07-10 through 2026-07-12 from static analysis of the XencelabsAgent vendor app plus hardware cross-testing. Uses the same `02 B5` vendor output-report pipe as the dial LED work (`Notes/Xencelabs-Quick-Keys-Puck-Reference.md`) — same pacing requirements apply (see Section 4 above / the dial-LED write-pacing note): writes need ~3 ms spacing or they desync. Living implementation: `TabletKit/Sources/TabletKit/XencelabsControl.swift`, pipeline in `MockTab/Driver/WacomKnownDevice.swift`, UI in `MockTab/UI/Panes/DisplayMappingView.swift`.

### Frame format

8-byte vendor output report on the Pen Display's vendor HID interface: `02 B5 b1 b2 b3 b4 b5 b6`.

| Sub-command | Bytes | Meaning |
|---|---|---|
| Color-space preset select | `1,1,1,0,presetIndex,0` | see wire index note below |
| Color temperature | `1,1,2,0,temp,0` | not yet implemented |
| RGB gain | `1,1,3,1,{1\|2\|3},value` | not yet implemented |
| Gamma | `1,2,0,0,gamma×10,0` | scalar, single byte |
| Contrast | `1,4,0,0,value,0` | scalar, single byte |
| Brightness | `1,3,0,0,value,0` | scalar, single byte |
| Commit/refresh | `0,0xF0,0,0,0,0` | **required** after a preset switch — see bug below |

### Bug 1 — gamma/contrast bleeding into named presets

The vendor only exposes gamma/contrast/color-temperature controls in Custom (User) mode — confirmed from a screenshot of the vendor's own "Set User Mode Preferences" dialog. Named presets (Adobe RGB, sRGB, etc.) own their gamma/contrast internally and the vendor never lets the user touch them directly. MockTab's first implementation wrote gamma/contrast unconditionally regardless of which preset was active, corrupting the panel's built-in preset curves (symptom: Adobe RGB looked "too dark, contrasted, and warm"). Fix: gate gamma/contrast writes behind `displayColorMode == customIndex`; re-apply saved values when switching *into* Custom.

### Bug 2 — missing commit frame causes stale values to persist across preset switches and power cycles

Switching color-space presets without sending the trailing `02 B5 00 F0 00 00 00 00` commit frame left previously-written gamma/contrast values silently attached to the new preset — confirmed to survive a full panel power cycle (rules out volatile RAM; the corruption is written into whatever the panel treats as persistent state). Reselecting the same preset from the *vendor's own* driver on the same hardware instantly fixed it, proving the panel's stored curve for that preset wasn't itself damaged — it was a wire protocol correctness issue, not a data-corruption issue. Fix: send the commit frame immediately after every `colorModePayload` preset switch.

### Bug 3 — off-by-one wire index for color-space presets

The `presetIndex` byte in the preset-select sub-command does not match the vendor UI's row order 1:1. Empirically cross-matched by cycling every MockTab preset against the vendor driver's preset list on the same panel, by eye:

```
vendor Adobe RGB → wire byte 1   (was sending byte 0 — invalid, root cause of Bug 1's visible symptom)
vendor sRGB      → wire byte 2
vendor REC 709   → wire byte 3
vendor DCI-P3    → wire byte 4
vendor REC 2020  → wire byte 5
vendor Pantone   → wire byte 6
Custom           → wire byte 7   (still unverified on hardware — one past anything confirmed)
```

Fix: send `UI row index + 1`. Wire byte `0` is presumed invalid/reserved and is never sent.

### Still open

- **Custom mode's wire byte (7)** is unverified — the +1 pattern holds for every named preset tested but hasn't been confirmed for Custom itself.
- **Continuous gamma** (vendor range 1.1–3.0; MockTab ships a 4-choice dropdown: 1.8/2.0/2.2/2.4) and **color temperature** (5000K–10000K) are decoded in the sub-command table above but not wired into the UI — deferred pending a Custom-mode-parity pass.
- Default preset is **Adobe RGB** (wire byte 1), not sRGB — matches macOS's own Displays-pane default for this panel.

***

---

## References

1. [Add Support for Xencelabs Pen Display 16 · Issue #3904 - GitHub](https://github.com/OpenTabletDriver/OpenTabletDriver/issues/3904) - Diagnostic information is mandatory and must be supplied for us to be able to support your tablet. P…

2. [Quick Keys, Linux, App recognition - Xencelabs Technologies Ltd.](https://solutions.xencelabs.com/en/support/discussions/topics/67000674407) - I have just received my Quick Keys and it's really great but it has an issue where it is not seeing …

3. [Tablet configuration reference - OpenTabletDriver](https://opentabletdriver.net/Wiki/Development/Configurations) - Tablet configuration specifications provide OpenTabletDriver with information it needs in order to c…

4. [Pen Tablet Medium | Xencelabs US Official Store](https://www.xencelabs.com/us/store/pen-tablets/xencelabs-pen-tablet-medium) - Professional OLED pen tablet with curved palm rest for comfort. Includes free shipping - perfect for…

5. [How to get Vendor ID and Product Id of connected USB Device On …](https://forum.arduino.cc/t/how-to-get-vendor-id-and-product-id-of-connected-usb-device-on-arduino-due-board/191251) - In order to get that, you go through the USB descriptors (Device, Config, Interface and End Points) …

6. [Xencelabs Quick Keys](https://www.xencelabs.com/us/products/xencelabs-quick-keys-remote) - Boost your creative drawing workflow with Xencelabs Quick Keys, featuring 8 shortcut keys with 5 set…

8. [linuxwacom/xf86-input-wacom: X.Org driver for …](https://github.com/linuxwacom/xf86-input-wacom) - X.Org driver for Wacom devices. Contribute to linuxwacom/xf86-input-wacom development by creating an…

9. [How to Find Vendor ID and Product ID for Your USB Device](https://acroname.com/blog/how-find-vendor-id-and-product-id-your-usb-device) - Method 1: Using Device Manager The Device Manager is the most straightforward way to find VID and PI…

