2026-03-28

# Contemporary Wacom HID Reference — ⚠ EXPERIMENTAL

> All entries in this section should be treated as **unverified against live hardware** unless explicitly noted. The `intuosV2` HID-generic path is descriptor-driven; byte offsets below reflect the **typical layout observed in contributed descriptors** but can vary between firmware revisions. Flag these as experimental in your registry.

***

## Architecture Context

Contemporary Wacom devices expose **three to four USB HID interfaces**:

| Interface | Contents | Needs Seize? |
|---|---|---|
| 0 | Pen digitizer (Report `0x10` or `0x02`) | No |
| 1 | Touch multitouch (if equipped) | No |
| 2 | Pad / buttons / ring | No |
| 3 | Generic HID mouse emulation | **Yes — suppress on macOS** |

The kernel routes all of these through `wacom_wac_pen_irq()`, `wacom_wac_finger_irq()`, and `wacom_wac_pad_irq()` respectively, reading field positions from the HID descriptor at enumeration rather than hardcoded offsets. The byte maps below reflect what is common across descriptor contributions, not guaranteed constants. [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)

***

## HID Usage Map — Pen (All Contemporary EMR Devices)

All contemporary EMR pen events map through these standard HID usages. Your parser needs to locate these by usage tag in the descriptor rather than by fixed byte offset: [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)

| HID Usage | Page:ID | Input Event | Notes |
|---|---|---|---|
| `GD_X` | `0x01:0x30` | X position | LE, bit width from descriptor |
| `GD_Y` | `0x01:0x31` | Y position | LE, bit width from descriptor |
| `DIG_TIP_PRESSURE` | `0x0D:0x30` | Pressure | 13-bit on 8191-max devices |
| `DIG_TILT_X` | `0x0D:0x3D` | Tilt X | Signed; Intuos Pro BT: interpret as signed int8 ⚠ was misread as unsigned in older kernel  [github](https://github.com/linuxwacom/input-wacom/releases) |
| `DIG_TILT_Y` | `0x0D:0x3E` | Tilt Y | Signed |
| `DIG_TWIST` | `0x0D:0x41` | Rotation (ABS_Z) | Art Pen / Pro Pen 3 rotation only |
| `DIG_IN_RANGE` | `0x0D:0x32` | Proximity | Hover without touch |
| `DIG_TIP_SWITCH` | `0x0D:0x42` | BTN_TOUCH | Tip contact |
| `DIG_BARREL_SWITCH` | `0x0D:0x44` | BTN_STYLUS | Barrel button 1 |
| `DIG_SECONDARY_BARREL_SWITCH` | `0x0D:0x5A` | BTN_STYLUS2 | Barrel button 2 |
| `DIG_ERASER` | `0x0D:0x45` | BTN_TOOL_RUBBER | EMR eraser end |
| `DIG_INVERT` | `0x0D:0x3C` | BTN_TOOL_RUBBER | **AES only** — eraser signaled by Invert bit, not tool-ID |

***

## EMR vs. AES Pen Behavior Differences

| Behavior | EMR (Cintiq Pro, Intuos Pro) | AES (consumer, some Wacom One) |
|---|---|---|
| Tool identification | Serial negotiation via enter-prox packet; `ABS_MISC` set to tool ID | None — tool type from `DIG_INVERT` only |
| Eraser detection | Separate tool-ID in enter-prox (`tool_id & 0x0008`) | `DIG_INVERT` bit set in same packet as tip data |
| Eraser persistence | State maintained via tool serial until exit-prox | State sent continuously each packet  [github](https://github.com/OpenTabletDriver/OpenTabletDriver/releases) |
| Proximity range | ~10mm typical | ~3–5mm; shorter hover range |
| Tilt | Yes (±63 normalized) | Limited or absent on lower-end AES |
| Rotation | Art Pen / Pro Pen 3 only | Not present |

> **OTD note:** As of OTD v0.6.x, a bug existed where AES erasers would get "stuck" after pen flip because eraser state was only captured in an initial report, not updated continuously. Fixed in OTD v0.7.0+. [github](https://github.com/OpenTabletDriver/OpenTabletDriver/releases)

***

## Pro Pen 3 — New Tool IDs (2022+)

The Pro Pen 3 shipped with the Cintiq Pro 27 and subsequent devices. The kernel's `wacom_intuos_get_tool_type()` required explicit additions to handle its tool IDs. The pen still uses the same `DIG_TWIST` usage for rotation. [github](https://github.com/linuxwacom/input-wacom/releases)

| Tool ID | Tool |
|---|---|
| `0x0804` | Pro Pen 3 (standard tip) |
| `0x080c` | Pro Pen 3 (eraser end) |
| `0x0812` ⚠ | Pro Pen 3 Art (rotation capable) — *unconfirmed exact ID* |

All other decoding (pressure, tilt, buttons) follows the standard `intuosV2` pen path.

***

## Device Breakdowns

### Cintiq Pro 27 — PID `0x03C0` ⚠ Estimated

**Parser:** `intuosV2` (HID-generic) · **featureInit:** `[0x02, 0x02]` · **seizeUSB:** false

| Property | Value |
|---|---|
| maxX | 120032 |
| maxY | 67868 |
| maxPressure | 8191 (13-bit) |
| Express keys | 4 (2 per side) |
| Touch rings | **2 rings, relative motion** |

**Key difference from DTK-2400:** The Cintiq Pro 27 rings send **relative delta** values, not absolute position. The kernel commit "Support touchrings with relative motion" and "Support devices with two touchrings" handle this. Your parser cannot treat ring values as absolute 0–127 positions. [github](https://github.com/linuxwacom/input-wacom/releases)

**Pad Report — ⚠ byte offsets unverified:**
```
[0x0n]  d1  d2  d3  d4  ...
```

| Field | Notes |
|---|---|
| Ring 1 delta | `REL_WHEEL`-style signed increment; direction + magnitude per packet |
| Ring 2 delta | Same encoding, second ring |
| Buttons 0–3 | 4 express keys as HID `BUTTON_1`–`BUTTON_4` usages |

Touch ring center button: reports as a distinct `BUTTON` usage in the pad collection — **exact bit position unconfirmed**.

***

### Cintiq 16 — PID `0x0390` / `0x03AE` ⚠ Estimated

**Parser:** `intuosV2` · **featureInit:** `[0x02, 0x02]` · **seizeUSB:** false

| Property | Value |
|---|---|
| maxX | 69632 |
| maxY | 39518 |
| maxPressure | 8191 |
| Express keys | 0 |
| Touch ring | None |

No pad interface of consequence. Pen-only decode, standard HID-generic path. The Cintiq 16 uses EMR with Pro Pen 2 compatibility.

***

### DTH-1320 — PID `0x034F` ⚠ Estimated

**Parser:** `intuosV2` · **featureInit:** `[0x02, 0x02]`

| Property | Value |
|---|---|
| maxX | 59552 |
| maxY | 33848 |
| maxPressure | 8191 |
| Touch | Yes (separate interface) |
| Express keys | 0 |

Touch interface uses a separate HID report collection; pen report is standard HID-generic EMR. Touch decoding follows `wacom_wac_finger_irq()` with standard multitouch HID usages (`DIG_CONTACT_ID`, `DIG_TOUCH_VALID`, `GD_X`, `GD_Y`).

***

### DTC-133 — PID `0x03A6` ⚠ Estimated

**Parser:** `intuosV2` · **featureInit:** `[0x02, 0x02]`

| Property | Value |
|---|---|
| maxX | 29434 |
| maxY | 16556 |
| maxPressure | 4095 (12-bit) |
| Express keys | 0 |

Entry-level Wacom One. Likely uses **AES**, not EMR — the 4095 pressure ceiling (12-bit) rather than 8191 (13-bit) is a marker consistent with AES sensor generations. If AES, eraser detection uses `DIG_INVERT`, not a tool-ID serial. [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)

***

### Movink 13 — PID `0x03F0` ⚠ Estimated

**Parser:** `intuosV2` · **featureInit:** `[0x02, 0x02]`

| Property | Value |
|---|---|
| maxX | 59552 |
| maxY | 33848 |
| maxPressure | 8191 |
| Touch | Yes (separate interface) — registry notes "Missing Features – touch"  [opentabletdriver](https://opentabletdriver.net/Tablets) |
| Express keys | 0 |

The Movink 13 is an OLED pen display. Pen interface follows standard HID-generic EMR. Touch interface present but not reliably documented in public sources as of early 2026.

***

### Cintiq Pro 22 DTH-227 / Cintiq 22HD Touch DTH-2200 ⚠ Unknown PID

**Not in registry.** Both flagged in OpenTabletDriver as "Missing Features – touch". Pen interface follows `intuosV2` path. PIDs not confirmed in available public sources. [opentabletdriver](https://opentabletdriver.net/Tablets)

***

### Wacom One 12 DTC-121 / Wacom One 13 Touch DTH-134 ⚠ Unknown PID

**Not in registry.** Added to input-wacom in v0.46.0 and v0.49.0 respectively. DTC-121 is a basic EMR pen display; DTH-134 adds touch. Both likely use AES based on price point and the 4095 pressure ceiling seen on peer devices. Feature init sequence **unknown** — may differ from `[0x02, 0x02]`. [github](https://github.com/linuxwacom/input-wacom/releases)

***

## What Remains Genuinely Unknown

These gaps exist because public reverse-engineering has not reached them:

- **Feature init sequences** for Cintiq Pro 27, Cintiq Pro 24, Wacom One 12/13 — the `[0x02, 0x02]` pattern from legacy devices may not apply, and no confirmed capture exists in public sources
- **Exact pad report IDs and byte offsets** for Cintiq Pro 27 pad (ring and button) — the HID-generic path means these must be read from the live descriptor
- **Pro Pen 3 rotation tool IDs** — kernel added entries but exact IDs not surfaced in accessible changelogs
- **Touch decoding** for Movink 13, DTH-2200, and DTH-227 — present in hardware, absent in open documentation
- **AES vs. EMR classification** for borderline devices (DTC-133, Wacom One 12) — inferred from pressure ceiling and price tier, not confirmed from descriptor captures

The most reliable path to filling these gaps remains USB capture on live hardware, exactly as you've already done for the PTZ-631W.