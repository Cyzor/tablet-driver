2026-03-29

# PTH-860 — Intuos Pro L (gen2) — Canonical HID Reference

**USB PID:** `0x0358` · **VID:** `0x056A` · **Kernel type (USB):** `INTUOSP2` · **Kernel type (BT Classic):** `INTUOSP2_BT`

***

## The Dual Bluetooth Identity — The Peculiar Behavior

The PTH-860 simultaneously advertises **two separate Bluetooth personalities**: [github](https://github.com/linuxwacom/input-wacom/issues/291)

| Advertised Name | Protocol | Purpose | Works as tablet? |
|---|---|---|---|
| `LE IntuosPro L` | BLE / HOGP | **Paper Mode only** (Tuhi app) | **No** |
| `BT IntuosPro L` | **Bluetooth Classic HID** | Full tablet digitizer | **Yes** |

Every user who connects to `LE IntuosPro L` and wonders why the pen produces no cursor movement has hit this. The kernel driver explicitly refuses tablet operation on the BLE interface. To enter BT Classic pairing mode: power on while **not** holding the ring center button, with USB **disconnected** — the surface LED near the USB-C port will blink, not the ring LED. [support.wacom](https://support.wacom.com/hc/en-us/articles/8495786896791-How-can-I-diagnose-an-issue-with-my-Bluetooth-connection-on-Wacom-device)

Beyond the dual-identity confusion, three additional hardware-level defects exist in the BT Classic path, all confirmed in `input-wacom` bug tracking: [github](https://github.com/linuxwacom/input-wacom/issues/445)

1. **Tilt sign encoding error** — tilt bytes are signed two's-complement but the kernel read them as unsigned until the `(signed char)` cast fix. Negative tilts (left/upward) reported as large positive values (~128–255 range). See decode detail below.
2. **Missing exit report on BT** — pen leaving proximity over BT Classic did not emit a proper `wacom_exit_report()` call, leaving applications with pen state permanently asserted until next entry. Fixed by "send exit report for recent devices."
3. **Multi-frame packing** — BT Classic delivers 7 queued pen frames per packet to compensate for lower BT bandwidth. USB delivers one frame per interrupt. This causes USB and BT to have **structurally different decoders**, not just different Report IDs.

***

## Connection Mode Summary

| Property | USB (wired) | BT Classic | BLE HOGP |
|---|---|---|---|
| Kernel type | `INTUOSP2` | `INTUOSP2_BT` | not a tablet path |
| Pen Report ID | `0x10` | (multi-frame, see below) | `0x01` |
| Pad Report ID | `0x11` | (multi-frame, see below) | `0x03` |
| Coordinate endian | **LE24** | **LE16** | LE |
| Pressure bits | 13 (0–8191) | 13 (0–8191) | 13 |
| Frames/packet | 1 | **7** | 1 |
| Tilt encoding | signed char | signed char (was bug: unsigned) | signed |
| Feature init | `[0x02, 0x02]` | none required | — |
| seizeUSB | false | N/A | — |

***

## USB Path — Report `0x10`, 192 Bytes

The PTH-860 departs entirely from the legacy 10-byte BE16 intuosV1 format used by the PTH-850. The USB pen interface presents a fully HID-descriptor-driven layout routed through `wacom_wac_pen_irq()`. [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)

```
10  d1  d2  d3  d4  d5  d6  d7  d8  d9  d10  d11  [d12..d191 = 0x00]
```

### Pen Report Byte Map (USB)

| Byte(s) | Field | Formula |
|---|---|---|
| `d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)` | Status byte | proximity / button flags (see table below) |
| `d [github](https://github.com/linuxwacom/input-wacom/issues/291):d [support.wacom](https://support.wacom.com/hc/en-us/articles/8495786896791-How-can-I-diagnose-an-issue-with-my-Bluetooth-connection-on-Wacom-device):d [github](https://github.com/linuxwacom/input-wacom/issues/445)` | **X** | `d [github](https://github.com/linuxwacom/input-wacom/issues/291) \| (d [support.wacom](https://support.wacom.com/hc/en-us/articles/8495786896791-How-can-I-diagnose-an-issue-with-my-Bluetooth-connection-on-Wacom-device) << 8) \| (d [github](https://github.com/linuxwacom/input-wacom/issues/445) << 16)` — **LE24** |
| `d [reddit](https://www.reddit.com/r/wacom/comments/1g5wx7q/tilt_sensitivity_not_working_correctly_on_wacom/):d [youtube](https://www.youtube.com/watch?v=IqOuun2GtlE):d [support.wacom](https://support.wacom.com/hc/en-us/articles/8810276474775-Pen-input-or-touch-input-does-not-work-as-expected)` | **Y** | `d [reddit](https://www.reddit.com/r/wacom/comments/1g5wx7q/tilt_sensitivity_not_working_correctly_on_wacom/) \| (d [youtube](https://www.youtube.com/watch?v=IqOuun2GtlE) << 8) \| (d [support.wacom](https://support.wacom.com/hc/en-us/articles/8810276474775-Pen-input-or-touch-input-does-not-work-as-expected) << 16)` — **LE24** |
| `d [support.wacom](https://support.wacom.com/hc/en-us/community/posts/28644647344791-Tilt-Settings):d [bbs.archlinux](https://bbs.archlinux.org/viewtopic.php?id=296435)` | **Pressure** | `d [support.wacom](https://support.wacom.com/hc/en-us/community/posts/28644647344791-Tilt-Settings) \| ((d [bbs.archlinux](https://bbs.archlinux.org/viewtopic.php?id=296435) & 0x1F) << 8)` — 13-bit |
| `d [support.wacom](https://support.wacom.com/hc/en-us/articles/8342308503063-My-pen-is-lagging-jumping-or-always-drawing-without-touching-the-surface-What-can-I-do)` | **Tilt X** | `(signed char)d [support.wacom](https://support.wacom.com/hc/en-us/articles/8342308503063-My-pen-is-lagging-jumping-or-always-drawing-without-touching-the-surface-What-can-I-do)` — range −127 to +127 |
| `d [youtube](https://www.youtube.com/watch?v=ZyAnSGDBszo)` | **Tilt Y** | `(signed char)d [youtube](https://www.youtube.com/watch?v=ZyAnSGDBszo)` — range −127 to +127 |

### USB `d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)` Status Byte

| `d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)` value | State |
|---|---|
| `(d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html) & 0xFC) == 0xC0` | Enter prox (tool ID bytes follow) |
| `0x20` / `0x21` | Hover / in range |
| `0x25` | Hover + BTN_STYLUS2 |
| `0x60` | Tip touching |
| `0x61` | Tip + BTN_STYLUS |
| `0x65` | Tip + BTN_STYLUS2 |
| `0x28` | Eraser hover |
| `0x68` | Eraser touching |
| `0x80` | Exit prox |
| `d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html) & 0x02` | BTN_STYLUS (barrel 1) |
| `d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html) & 0x04` | BTN_STYLUS2 (barrel 2) |
| `d [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html) & 0x01` | BTN_TOUCH |

### USB Pad Report `0x11`

Same layout as PTH-850 (`INTUOS5S`–`INTUOSPL` branch of `wacom_intuos_pad()`):

```c
buttons = (data [github](https://github.com/linuxwacom/input-wacom/issues/445) << 1) | (data [support.wacom](https://support.wacom.com/hc/en-us/articles/8495786896791-How-can-I-diagnose-an-issue-with-my-Bluetooth-connection-on-Wacom-device) & 0x01);   // 9-bit mask
ring1   = data [github](https://github.com/linuxwacom/input-wacom/issues/291);                               // bit 7 = active, bits 6–0 = position 0–71
ABS_WHEEL = (ring1 & 0x80) ? (ring1 & 0x7F) : 0;
```

***

## Bluetooth Classic Path — `wacom_intuos_pro2_bt_irq()`

### Packet Structure

One BT Classic HID input report carries **7 pen frames** packed sequentially, each 14 bytes, for a total payload of 99 bytes: [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)

```
[header: 1 byte]  [frame 0: 14 bytes]  [frame 1: 14 bytes]  ...  [frame 6: 14 bytes]
= 1 + (7 × 14) = 99 bytes
```

Each frame is processed independently. Frames with bit 7 of byte 0 clear (`valid == 0`) are silently skipped — the tablet sends fewer than 7 valid frames if the sampling window is not fully populated.

### Per-Frame Decode (14 bytes, zero-indexed within frame)

```
f0  f1  f2  f3  f4  f5  f6  f7  f8  f9  f10  f11  f12  f13
```

| Byte(s) | Field | Formula |
|---|---|---|
| `f[0]` | Frame status | see flags below |
| `f [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html):f [github](https://github.com/linuxwacom/input-wacom/issues/291)` | **X** | `LE16(f [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html):f [github](https://github.com/linuxwacom/input-wacom/issues/291))` |
| `f [support.wacom](https://support.wacom.com/hc/en-us/articles/8495786896791-How-can-I-diagnose-an-issue-with-my-Bluetooth-connection-on-Wacom-device):f [github](https://github.com/linuxwacom/input-wacom/issues/445)` | **Y** | `LE16(f [support.wacom](https://support.wacom.com/hc/en-us/articles/8495786896791-How-can-I-diagnose-an-issue-with-my-Bluetooth-connection-on-Wacom-device):f [github](https://github.com/linuxwacom/input-wacom/issues/445))` |
| `f [reddit](https://www.reddit.com/r/wacom/comments/1g5wx7q/tilt_sensitivity_not_working_correctly_on_wacom/):f [youtube](https://www.youtube.com/watch?v=IqOuun2GtlE)` | **Pressure** | `LE16(f [reddit](https://www.reddit.com/r/wacom/comments/1g5wx7q/tilt_sensitivity_not_working_correctly_on_wacom/):f [youtube](https://www.youtube.com/watch?v=IqOuun2GtlE)) & 0x1FFF` — 13-bit |
| `f [support.wacom](https://support.wacom.com/hc/en-us/articles/8810276474775-Pen-input-or-touch-input-does-not-work-as-expected)` | **Tilt X** | `(signed char)f [support.wacom](https://support.wacom.com/hc/en-us/articles/8810276474775-Pen-input-or-touch-input-does-not-work-as-expected)` — **⚠ unsigned before patch; causes negative tilt bug** |
| `f [support.wacom](https://support.wacom.com/hc/en-us/community/posts/28644647344791-Tilt-Settings)` | **Tilt Y** | `(signed char)f [support.wacom](https://support.wacom.com/hc/en-us/community/posts/28644647344791-Tilt-Settings)` — **⚠ unsigned before patch** |
| `f [bbs.archlinux](https://bbs.archlinux.org/viewtopic.php?id=296435)`–`f [forum.kde](https://forum.kde.org/viewtopic.php%3Ff=139&t=164858.html)` | Reserved / padding | not decoded by kernel |

### Frame Status Byte `f[0]`

| Bit | Mask | Field |
|---|---|---|
| 7 | `0x80` | **frame valid** — if 0, skip entire frame |
| 6 | `0x40` | **pen in prox** — set on entry; drives tool-type detection |
| 5 | `0x20` | **pen in range** (hover) |
| 3 | `0x08` | **eraser tool** — `BTN_TOOL_RUBBER` when set |
| 2 | `0x04` | **BTN_STYLUS2** (barrel 2) |
| 1 | `0x02` | **BTN_STYLUS** (barrel 1) |
| 0 | `0x01` | **BTN_TOUCH** |

### Proximity State Logic (per frame)

```c
valid = frame[0] & 0x80;
if (!valid) continue;

prox  = frame[0] & 0x40;
range = frame[0] & 0x20;

if (prox) {
    tool = (frame[0] & 0x08) ? BTN_TOOL_RUBBER : BTN_TOOL_PEN;
    shared->stylus_in_proximity = true;
}

if (!prox && !range) {
    // Exit proximity — sends wacom_exit_report()
    // ← THIS was the missing-exit-report bug before the "send exit report" patch
    shared->stylus_in_proximity = false;
}
```

### The Tilt Bug — Exact Mechanism

Before the fix, the kernel executed:
```c
input_report_abs(pen_input, ABS_TILT_X, frame [support.wacom](https://support.wacom.com/hc/en-us/articles/8810276474775-Pen-input-or-touch-input-does-not-work-as-expected));   // read as unsigned byte
input_report_abs(pen_input, ABS_TILT_Y, frame [support.wacom](https://support.wacom.com/hc/en-us/community/posts/28644647344791-Tilt-Settings));   // read as unsigned byte
```

After the fix: [github](https://github.com/linuxwacom/input-wacom/issues/445)
```c
input_report_abs(pen_input, ABS_TILT_X, (signed char)frame [support.wacom](https://support.wacom.com/hc/en-us/articles/8810276474775-Pen-input-or-touch-input-does-not-work-as-expected));
input_report_abs(pen_input, ABS_TILT_Y, (signed char)frame [support.wacom](https://support.wacom.com/hc/en-us/community/posts/28644647344791-Tilt-Settings));
```

The consequence: a pen tilted 6° left transmits `f [support.wacom](https://support.wacom.com/hc/en-us/articles/8810276474775-Pen-input-or-touch-input-does-not-work-as-expected) = 0xFA` (= −6 in two's-complement). Read as unsigned: `0xFA = 250`. The input subsystem clamps `ABS_TILT_X` range to ±63 in normalized units, so 250 would clip to +63 — a hard rightward tilt instead of a leftward one. Artists using tilt-sensitive brushes in Krita experienced strokes deforming to maximum rightward/downward tilt whenever they tilted the pen left or up. [reddit](https://www.reddit.com/r/wacom/comments/1g5wx7q/tilt_sensitivity_not_working_correctly_on_wacom/)

### BT Classic Pad Report

Follows the same 7-frame container. Pad frames are distinguished by a separate report ID within the BT packet (not yet confirmed in publicly available captures — **⚠ byte layout of BT pad frames unverified**).

The pad logical output — ring position, 8 express keys, ring mode toggle — is functionally identical to the USB path.

***

## Touch Interface

The PTH-860 has capacitive multitouch. The touch interface follows the same vendor-specific FF00 channel and `wacom_bpt3_touch()` decoder described for the PTH-850, with up to 16 simultaneous contacts at the higher sensor resolution (maxX: 62200, maxY: 43200).

Touch arbitration applies on both USB and BT Classic paths: pen proximity suppresses touch, and touch suppresses pen exactly as in `delay_pen_events()` / `report_touch_events()`. [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)