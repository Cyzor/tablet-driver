2026-03-28

# PTH-850/K — Canonical HID Reference

**PID:** `0x0028` · **VID:** `0x056A` · **Kernel type:** `INTUOS5L` · **Kernel function:** `wacom_intuos_irq()`

The `/K` suffix is a Korean regional SKU designator. PID, protocol, and all electrical specs are identical to the global PTH-850.

***

## USB Interface Map

```
VendorID = 056A, ProductID = 0028
Speed: Full Speed (12 Mbit/s)
bNumConfigurations = 1
```

| Iface | EP | IN Size | Interval | HID Usage | Handler |
|---|---|---|---|---|---|
| 0 | EP3 | **16 bytes** | 1 ms | `0x010002` Mouse + `0x0D0001` Digitizer | `wacom_intuos_irq()` |
| 1 | EP2 | **64 bytes** | 2 ms | `0xFF000001` Vendor-specific | `wacom_bpt3_touch()` |

Interface 0's 243-byte HID descriptor exposes two top-level collections — a mouse emulation collection the OS will claim automatically (which you must suppress via `seizeUSB` or matching on the digitizer collection only), and the pen digitizer collection that carries both pen reports and pad reports.

Interface 1's 23-byte descriptor:
```
06 00 FF  09 01  A1 01  85 02  09 01
15 00  26 FF 00  75 08  95 3F  81 02  C0
```
Declares one input: **Report ID `0x02`, 63-byte payload**, Usage Page `0xFF00` (vendor). [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2)

***

## Feature Initialization

**Confirmed from live SET_REPORT capture** on the structurally-identical PTH-650: [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2)

```
bmRequestType = 0x21  (HID Class, host→device, interface)
bRequest      = 0x09  (SET_REPORT)
wValue        = 0x0302  (Type=Feature, ID=0x02)
wIndex        = 0x0000
wLength       = 2
Data          = [0x02, 0x02]
```

Interface 1 produces only zero-filled reports until this SET_REPORT is issued. No second-stage init, no delay required.

***

## Interface 0 — Report ID Dispatch

`wacom_intuos_irq()` accepts the following Report IDs: [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)

| Constant | Value | Purpose |
|---|---|---|
| `WACOM_REPORT_PENABLED` | `0x02` | Pen data + enter/exit prox |
| `WACOM_REPORT_INTUOS_ID1` | `0x20` | Feature report — triggers device to re-send tool serial if lost |
| `WACOM_REPORT_INTUOS_ID2` | `0x21` | Alternate serial re-send ID |
| `WACOM_REPORT_INTUOS5PAD` | `0x11` | Pad buttons + touch ring |
| `WACOM_REPORT_INTUOS_PEN` | `0x10` | Alternate pen report on some firmware revisions |
| `WACOM_REPORT_CINTIQ` | `0x02` | (same as PENABLED; only distinct by device type) |
| `WACOM_REPORT_CINTIQPAD` | `0x11` | (same as INTUOS5PAD; Cintiq-type devices) |

All other Report IDs on Interface 0 are silently discarded.

***

## Pen Report `0x02` — 10 Bytes

```
02  d1  d2  d3  d4  d5  d6  d7  d8  d9
```

### Proximity State Dispatch (first)

`wacom_intuos_inout()` checks `d [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2)` before any coordinate decode: [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)

| `d [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2)` pattern | State | Action |
|---|---|---|
| `(d [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2) & 0xFC) == 0xC0` | **Enter prox** | Decode serial + tool ID; set `stylus_in_proximity = true` |
| `(d [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2) & 0xFE) == 0x20` | **In range** | If exiting: flush pressure=0, distance=max, BTN_TOUCH=0 |
| `(d [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2) & 0xFE) == 0x80` | **Exit prox** | Call `wacom_exit_report()`; clear all state |

Dual tool tracking (`idx = data [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2) & 0x01`) applies **only to INTUOS type** (Intuos 1/2). For INTUOS5L, `idx` is always `0`.

### Enter Prox — Serial and Tool ID Decode

```c
serial  = ((__u64)(data[3] & 0x0F) << 28)
        | (data[4] << 20)
        | (data[5] << 12)
        | (data[6] << 4)
        | (data[7] >> 4);

tool_id = (data [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html) << 4)
        | (data[3] >> 4)
        | ((data[7] & 0x0F) << 16)
        | ((data[8] & 0xF0) << 8);

ABS_MISC = (tool_id & ~0xFFF) << 4 | (tool_id & 0xFFF);   // wacom_intuos_id_mangle()
MSC_SERIAL = serial;
```

### Coordinate and Pressure Decode (general pen — types `0x00`–`0x03`)

For INTUOS5L the `features->type >= INTUOS3S` check at source line 895 is **true**, so coordinates are NOT right-shifted: [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)

```c
x        = (be16_to_cpup(&data [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)) << 1) | ((data[9] >> 1) & 1);
y        = (be16_to_cpup(&data[4]) << 1) | (data[9] & 1);
distance = data[9] >> 2;

// pressure_max == 2047, so (pressure_max < 2047) is false → NO >>1 shift
t        = (data[6] << 3) | ((data[7] & 0xC0) >> 5) | (data [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2) & 1);

tilt_x   = (((data[7] << 1) & 0x7E) | (data[8] >> 7)) - 64;
tilt_y   = (data[8] & 0x7F) - 64;

BTN_STYLUS  = data [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2) & 0x02;
BTN_STYLUS2 = data [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2) & 0x04;
BTN_TOUCH   = (t > 10);
ABS_PRESSURE = t;
```

INTUOS5L is **not** in the Lens Cursor blocked list (only `INTUOS5`, `INTUOS5S`, `INTUOSPM`, `INTUOSPS` are blocked), so the Lens cursor accessory works on the PTH-850. [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)

### All Pen Packet Types

| `type = (d [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2) >> 1) & 0x0F` | Meaning |
|---|---|
| `0x00`–`0x03` | General pen — pressure, tilt, buttons (above) |
| `0x05` | Art Pen / Marker Pen rotation → `ABS_Z` |
| `0x04` | 4D Mouse packet 1 — throttle, side buttons |
| `0x06` | Intuos4 Mouse — left/middle/right, REL_WHEEL, tilt |
| `0x08` | Intuos 2D Mouse — left/middle/right, REL_WHEEL |
| `0x0A` | Airbrush second packet — `ABS_WHEEL` fingerwheel, tilt |
| `0x07`,`0x09`,`0x0B`–`0x0F` | Unhandled — silently ignored |

### Art Pen Rotation (`type 0x05`)

```c
t = (data[6] << 3) | ((data[7] >> 5) & 7);
ABS_Z = (data[7] & 0x20)
      ? ((t > 900) ? ((t-1)/2 - 1350) : ((t-1)/2 + 450))
      : (450 - t/2);
// Range: ±900 (in 0.5° steps, so ±450°)
```

***

## Pad Report `0x11` — Intuos5/Pro Path

For `features->type >= INTUOS5S && features->type <= INTUOSPL`, which includes `INTUOS5L`: [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)

```c
buttons = (data[4] << 1) | (data[3] & 0x01);   // 9-bit button mask
ring1   = data [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html);                               // touch ring
```

### Full Pad Byte Map

```
11  d1  d2  d3  d4  d5  d6  ...
```

| Byte | Field | Decode |
|---|---|---|
| `d [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2)` | Reserved | Not used in INTUOS5L path |
| `d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)` | **Touch ring** | `(d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html) & 0x80) ? (d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html) & 0x7F) : 0` → `ABS_WHEEL` (0 when no finger) |
| `d[3]` | **Ring mode switch** | `d[3] & 0x01` → button bit 0; no capacitive sensor on this byte |
| `d[4]` | **ExpressKeys (mechanical)** | bits 7–0 → button bits 8–1 (via `(d[4] << 1)`) |
| `d[5]` | **ExpressKeys (capacitive)** | Capacitive proximity data — informational only; not included in `buttons` mask |

### Button Mask Layout (9 bits)

```
bit 8  = d[4] & 0x80   → BTN_7 (top key, left column or right column depending on orientation)
bit 7  = d[4] & 0x40   → BTN_6
bit 6  = d[4] & 0x20   → BTN_5
bit 5  = d[4] & 0x10   → BTN_4
bit 4  = d[4] & 0x08   → BTN_3
bit 3  = d[4] & 0x04   → BTN_2
bit 2  = d[4] & 0x02   → BTN_1
bit 1  = d[4] & 0x01   → BTN_0 (bottom of 8-key group)
bit 0  = d[3] & 0x01   → touch ring mode toggle button
```

Pad proximity: fires when `buttons != 0` or `ring1 & 0x80`; clears when all zero. `MSC_SERIAL = 0xFFFFFFFF` on every pad event.

***

## Interface 1 — Touch Report `0x02` / Subtype `0x07`

**Report ID:** `0x02` (vendor HID) · **Payload:** 63 bytes · **First payload byte:** `0x07` = `WACOM_REPORT_INTUOS5TOUCH`

```
[HID: 0x02]  07  [slot0: 8 bytes]  [slot1: 8 bytes]  ...  [slot6: 8 bytes]  [6 bytes padding]
```

`1 + (7 × 8) + 6 = 63 bytes` confirmed by idle capture showing the `0x07` type byte followed by 7 records at 8-byte intervals. [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2)

### Contact Record — 8 Bytes per Slot

```
s0  s1  s2  s3  s4  s5  s6  s7
```

| Byte | Field | Decode |
|---|---|---|
| `s[0]` | **Status + ID** | `s[0] & 0x80` = NOT-touching flag (1 = no contact); `s[0] & 0x7F` = contact ID |
| `s [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2):s [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)` | **X** | `BE16(s [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2):s [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html))` |
| `s[3]:s[4]` | **Y** | `BE16(s[3]:s[4])` |
| `s[5]` | Touch width | Contact size major axis |
| `s[6]` | Touch height | Contact size minor axis |
| `s[7]` | Reserved | `0x00` in all observed captures |

**Active contact:** `s[0] & 0x80 == 0`, contact ID = `s[0] & 0x7F`
**Lifted contact:** `s[0] & 0x80 == 1`, coordinates hold last position

Touch arbitration: `wacom_intuos_irq()` suppresses pen events when `shared->touch_down` is set, and `wacom_bpt3_touch()` suppresses touch events when `shared->stylus_in_proximity` is set. [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)

***

## Wireless Dongle — ACK-40401 (PID `0x0084`)

The dongle enumerates with **the same two-interface HID structure** as the wired tablet. After wireless connection establishes, the dongle transparently relays all pen, pad, and touch reports using identical Report IDs and byte formats. No decoder changes are required relative to the wired path.

### Wireless Status Report — `WACOM_REPORT_WL`

**Length:** 32 bytes (`WACOM_PKGLEN_WIRELESS`) · **Sent when link state changes** [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)

```
WL  d1  d2  d3  d4  d5  d6  d7  d8..d31
```

| Byte | Field | Decode |
|---|---|---|
| `d[0]` | Report ID | `WACOM_REPORT_WL` |
| `d [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2)` | **Connection state** | `d [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2) & 0x01` = 1 → tablet connected; 0 → disconnected |
| `d[5]` | **Battery** | `(d[5] & 0x3F) * 100 / 31` → percent (0–100); `d[5] & 0x80` = charging |
| `d[6]:d[7]` | **Tablet PID** | `BE16(d[6]:d[7])` = `0x0028` for PTH-850 |
| `d[2..4]`, `d[8..31]` | Reserved | Not decoded by kernel |

On connection (`d [forum.pjrc](https://forum.pjrc.com/index.php?threads%2Fusb-host-teensy-4-1-with-wacom-intuos5.70824%2Fpage-2) & 0x01`), the kernel reads the PID from `d[6]:d[7]`, dynamically registers the tablet sub-device under that PID, and then routes all subsequent pen/pad/touch reports through the normal `wacom_intuos_irq()` path. On disconnection, the kernel unregisters the sub-device and calls `wacom_force_proxout()` to clear any in-flight proximity state.

### Battery Capacity Table — Intuos4 WL (`batcap_i4`)

```c
static unsigned short batcap_i4[8] = { 1, 15, 30, 45, 60, 70, 85, 100 };
```

This lookup table applies to **Intuos4 WL (PTK-540WL) only**. The PTH-850 via ACK-40401 uses the **linear formula** `(d[5] & 0x3F) * 100 / 31` directly, not this table. [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)