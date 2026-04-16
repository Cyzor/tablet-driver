2026-04-15

# Wacom PTH-660 / Intuos Pro — 192-Byte USB HID Report Layout

**Device:** Wacom Intuos Pro M (PTH-660)  
**USB VID:PID:** 056A:0357 (USB wired), 056A:0360 (Bluetooth, Intuos Pro M BT variant)  
**Protocol family:** IntuosV2 (USB), INTUOSP2_BT (Bluetooth)  
**Sources:** Linux kernel `wacom_wac.c` / `wacom_wac.h` (torvalds/linux master), OpenTabletDriver `IntuosV2ReportParser.cs` / `IntuosV2Report.cs` (OpenTabletDriver/OpenTabletDriver master), USB sysinfo captures (Arch Linux forum, bbs.archlinux.org thread #239232)

---

## 1. Protocol Architecture

The PTH-660 exposes **three USB HID interfaces**:

| Interface | Usage | Report parser |
|-----------|-------|---------------|
| 0 (Interface 0) | Pen + Pad | IntuosV2 / `wacom_wac_pen_irq` |
| 2 (Interface 2) | Finger touch | Vendor-specific multitouch |
| — | Pad aux keys | IntuosV2Aux (report ID 0x11) |

The pen interface issues reports of **192 bytes** (OpenTabletDriver `InputReportLength: 192`). The pad (express keys) interface issues reports of **44 bytes** on the same VID:PID as the pen interface. Bluetooth operation uses the `INTUOSP2_BT` kernel path with a fixed **282-byte** container instead.

### Report ID dispatch

The first byte of every 192-byte report is the **Report ID**:

| Report ID | Report type | Parser |
|-----------|-------------|--------|
| `0x10` | Standard pen/eraser data | `IntuosV2Report` |
| `0x1E` | Offset pen report (alternate layout) | `IntuosV2OffsetReport` |
| `0x11` | Pad/auxiliary button report | `IntuosV2AuxReport` |
| `0x21` | Touch report (finger) | `IntuosV2TouchReport` |
| `0xD2` | Touch report (alternate) | `IntuosV2TouchReport` |

> **WacomDriverIntuosV2ReportParser** (used when Wacom's official driver is co-present) strips `data[0]` and shifts all offsets by −1 before forwarding to the base parser. The offsets below assume OTD's standard path where `data[0]` is the Report ID byte.

---

## 2. Report 0x10 — Standard Pen Report (192 bytes)

This is the primary pen data report fired during hover and contact.

### Byte-Offset Table

| Byte(s) | Field | Type | Decode | Notes |
|---------|-------|------|--------|-------|
| `[0]` | Report ID | uint8 | `== 0x10` | Constant; identifies this as a pen report |
| `[1]` | Status / Pen Flags | uint8 | bitmask (see §2.1) | Proximity, eraser, confidence, barrel buttons |
| `[2–3]` | X coordinate (low 16 bits) | uint16 LE | `ReadUnaligned<ushort>(ref data[2])` | Combined with `data[4]` for full value |
| `[4]` | X coordinate (high byte) | uint8 | `data[4] << 16` | ORed with [2–3]; max X = 44800 for M |
| `[5–6]` | Y coordinate (low 16 bits) | uint16 LE | `ReadUnaligned<ushort>(ref data[5])` | Combined with `data[7]` for full value |
| `[7]` | Y coordinate (high byte) | uint8 | `data[7] << 16` | ORed with [5–6]; max Y = 29600 for M |
| `[8–9]` | Pressure | uint16 LE | `ReadUnaligned<ushort>(ref data[8])` | 0–8191 (13-bit, 8192 levels) |
| `[10]` | Tilt X | int8 (signed) | `(sbyte)data[10]` | −127 to +127; positive = right |
| `[11]` | Tilt Y | int8 (signed) | `(sbyte)data[11]` | −127 to +127; positive = toward user |
| `[12–15]` | Reserved / unknown | — | — | Not decoded in OTD or kernel |
| `[16]` | Hover distance | uint8 | `data[16]` | 0 = contact, 1–63 = hover height |
| `[17–191]` | Pad / reserved | — | — | Pad express keys may occupy later bytes via separate 44-byte report |

### 2.1 Status Byte (`data[1]`) Bitmask

| Bit | Mask | Field | Meaning when set |
|-----|------|-------|-----------------|
| 0 | `0x01` | (Proximity low) | Part of proximity state on some paths |
| 1 | `0x02` | Barrel Button 1 | Lower barrel side button pressed |
| 2 | `0x04` | Barrel Button 2 | Upper barrel side button pressed |
| 3 | `0x08` | (reserved / tip confirm) | — |
| 4 | `0x10` | Eraser | Eraser end of pen is active |
| 5 | `0x20` | High Confidence | Report is valid / in-range; `0` = ignore report |
| 6 | `0x40` | (reserved) | — |
| 7 | `0x80` | Proximity | Pen is within detection range of tablet |

> **Proximity vs. High Confidence:** Bit 7 (`0x80`) signals gross proximity (pen within sensor range). Bit 5 (`0x20` = `HighConfidence`) signals the report carries valid coordinate data. During approach/departure transitional frames, bit 7 may be set while bit 5 is clear — discard such frames for drawing purposes but use them for proximity tracking.

> **Eraser detection:** The eraser flag (bit 4) is based on the tool's physical orientation, not its tool ID. Combine with tool ID tracking to distinguish pen eraser tip from a separately-registered eraser tool. In your `IntuosV2Decoder.swift`, the canonical check is `currentToolCode & 0x0008 != 0` for non-Art-Pen tools, cross-referenced against the cached tool code, not the live status byte.

### 2.2 Coordinate Reconstruction

```
// X (20-bit value, device units, max 44800)
let xLow  = UInt32(data[2]) | (UInt32(data[3]) << 8)   // LE uint16
let x     = xLow | (UInt32(data[4]) << 16)

// Y (20-bit value, device units, max 29600)
let yLow  = UInt32(data[5]) | (UInt32(data[6]) << 8)   // LE uint16
let y     = yLow | (UInt32(data[7]) << 16)
```

This is meaningfully different from the legacy `wacom_intuos_general()` path, which uses **big-endian** `be16_to_cpup` with a 1-bit sub-pixel extension from `data[9]`. The IntuosV2 USB path uses **little-endian** 16-bit reads with a plain 8-bit high extension byte — no sub-pixel shifting.

### 2.3 Pressure Detail

```
let pressure = UInt16(data[8]) | (UInt16(data[9]) << 8)  // LE uint16, 0–8191
```

13-bit effective range (0–8191). The `MaxPressure: 8191` in OpenTabletDriver config confirms this. The Pro Pen 2 (`KP-504E`) and Pro Pen 3D all report into this same range. Tip touch threshold is `pressure > 10` (kernel convention).

### 2.4 Tilt Detail

```
let tiltX = Int8(bitPattern: data[10])   // −127..+127
let tiltY = Int8(bitPattern: data[11])   // −127..+127
```

Range is approximately ±60° physical tilt mapped to ±127 logical units at ~2.1 units/degree. The `WACOM_INTUOS3_RES` resolution constant (200 lpi) applies to coordinates; tilt resolution is independent and empirically ~±60 full range.

### 2.5 Hover Distance Detail

`data[16]` = 0 means pen is in contact (tip switch active or pressure > 0). Values 1–63 represent increasing hover height above the surface. The kernel's `features.distance_max = 63` for INTUOSP2 devices. On exit-proximity the tablet sends a report with all zero coordinates and this field at `distance_max`.

---

## 3. Report 0x1E — Offset Pen Report (192 bytes)

Report ID `0x1E` is emitted in certain framing contexts (Wacom driver mode, or some firmware states). All fields shift by +1 byte:

### Byte-Offset Table

| Byte(s) | Field | Type | Decode |
|---------|-------|------|--------|
| `[0]` | Report ID | uint8 | `== 0x1E` |
| `[1]` | High Confidence / sequence | uint8 | bit 5 = HighConfidence |
| `[2]` | Status / Pen Flags | uint8 | Same bitmask as 0x10's `data[1]` |
| `[3–4]` | X coordinate (low 16 bits) | uint16 LE | Same reconstruction as 0x10 |
| `[5]` | X coordinate (high byte) | uint8 | `data[5] << 16` |
| `[6–7]` | Y coordinate (low 16 bits) | uint16 LE | Same as 0x10 |
| `[8]` | Y coordinate (high byte) | uint8 | `data[8] << 16` |
| `[9–10]` | Pressure | uint16 LE | 0–8191 |
| `[11]` | Tilt X | int8 | `(sbyte)data[11]` |
| `[12]` | Tilt Y | int8 | `(sbyte)data[12]` |
| `[13+]` | Reserved | — | — |

> **Eraser / Buttons** come from `data[2]` (the shifted pen flags byte), using the same bitmask as 0x10's `data[1]`.

> **Note on 0x1E HoverDistance:** OTD's `IntuosV2OffsetReport` sets `HoverDistance = report[11]`, which is the same byte as Tilt X. This appears to be a bug in OTD — for 0x1E the hover field has no confirmed canonical offset. Use `data[16]` (same absolute position as 0x10) or treat it as unknown.

> **WacomDriverIntuosV2ReportParser** strips `data[0]` before calling the base parser, so from that path `0x1E` is seen at `data[0]` of the *stripped* array and all offsets above effectively shift by −1 back to the same physical positions.

---

## 4. Report 0x11 — Pad / Aux Button Report (44 bytes)

Express keys arrive on a 44-byte report, separate from the 192-byte pen report, on the same USB interface (PID 0x0357).

### Byte-Offset Table

| Byte(s) | Field | Type | Decode |
|---------|-------|------|--------|
| `[0]` | Report ID | uint8 | `== 0x11` |
| `[1]` | Express key bitmask | uint8 | One bit per key (bits 0–7 = keys 0–7) |
| `[2–43]` | Reserved / unknown | — | Pad touch ring may occupy later bytes |

### 4.1 Express Key Bit Map (`data[1]`)

| Bit | Mask | Key |
|-----|------|-----|
| 0 | `0x01` | Express Key 0 (top-left) |
| 1 | `0x02` | Express Key 1 |
| 2 | `0x04` | Express Key 2 |
| 3 | `0x08` | Express Key 3 |
| 4 | `0x10` | Express Key 4 |
| 5 | `0x20` | Express Key 5 |
| 6 | `0x40` | Express Key 6 |
| 7 | `0x80` | Express Key 7 (bottom-right) |

The PTH-660 has 8 express keys total (`AuxiliaryButtons.ButtonCount: 8` in OTD config). All 8 map directly to bits 0–7 of `data[1]`. The touch ring position is **not** present in the USB IntuosV2 aux report — it is only decoded in the Bluetooth path (see §6 below).

---

## 5. Report 0x21 / 0xD2 — Touch Reports

Touch data uses a multi-slot format. Up to 5 touch contact points per report, up to 16 simultaneous tracked contacts overall.

### Per-Contact Encoding (8 bytes per slot, starting at byte 2)

For contact slot `i` (i = 0..4):

| Relative Offset | Field | Type | Decode |
|-----------------|-------|------|--------|
| `base + 0` | Touch ID | uint8 | `touchID - 1` → slot index; 0 = empty |
| `base + 1` | Touch state | uint8 | 0 = lift, non-zero = down |
| `base + 2–3` | Touch X | uint16 LE | Coordinate in device units |
| `base + 4–5` | Touch Y | uint16 LE | Coordinate in device units |
| `base + 6` | Contact width | uint8 | × resolution = mm |
| `base + 7` | Contact height | uint8 | × resolution = mm |

Where `base = (i × 8) + 2`.

---

## 6. Bluetooth Path — INTUOSP2_BT (282 bytes)

When connected over Bluetooth (PID 0x0360), the kernel routes through `wacom_intuos_pro2_bt_irq()` with a **282-byte** container. This is a **different** physical layout from the 192-byte USB path.

### Report 0x80 / 0x81 Container Structure

| Byte range | Content |
|------------|---------|
| `[0]` | Report ID (`0x80` or `0x81`) |
| `[1–98]` | 7 pen frames × 14 bytes each (= 98 bytes) |
| `[99–106]` | Pen serial number (uint64 LE) |
| `[107–108]` | Tool ID (uint16 LE) |
| `[109–280]` | 4 touch frames × 43 bytes each (= 172 bytes) |
| `[281]` | Touch mute switch (bit 7) + pad center button (bit 6) |
| `[282]` | Express key bitmask (bits 0–7) |
| `[283]` | Reserved |
| `[284]` | Battery (bits 0–6 = %, bit 7 = charging) |
| `[285]` | Touch ring (bits 0–6 = position 0–71, bit 7 = active) |

### Per-Pen Frame Layout (14 bytes, frame `i` starts at `data[i*14 + 1]`)

Let `f = &data[i*14 + 1]`:

| Offset in frame | Field | Decode |
|-----------------|-------|--------|
| `f[0]` | Frame flags | bit 7 = valid, bit 6 = proximity, bit 5 = range, bit 4 = invert (eraser) |
| `f[1–2]` | X position | uint16 LE, 0–44800 |
| `f[3–4]` | Y position | uint16 LE, 0–29600 |
| `f[5–6]` | Pressure | uint16 LE, 0–8191 |
| `f[7]` | Tilt X | int8, signed |
| `f[8]` | Tilt Y | int8, signed |
| `f[9–10]` | Rotation (Art Pen) | int16 LE; add 450, wrap at ±900 |
| `f[11–12]` | Wheel (Airbrush) | uint16 LE |
| `f[13]` | Hover distance | uint8, 0–63 |

**Barrel buttons** are packed into `f[0]`:

| Bit | Mask | Field |
|-----|------|-------|
| 0 | `0x01` | BTN_TOUCH (tip) |
| 1 | `0x02` | BTN_STYLUS (lower barrel) |
| 2 | `0x04` | BTN_STYLUS2 (upper barrel) |
| 3 | `0x08` | BTN_TOUCH (alternate touch confirm) |

> **USB vs. BT barrel button encoding differs.** On USB (report 0x10), barrel buttons are in `data[1]` bits 1 and 2. On Bluetooth, they are in `f[0]` bits 1 and 2 of each per-frame flags byte. The bit positions are the same; only the containing byte differs.

---

## 7. Cross-Reference: USB vs. Bluetooth Field Locations

| Field | USB (Report 0x10) | Bluetooth (per-frame) |
|-------|-------------------|----------------------|
| Report ID | `data[0] = 0x10` | `data[0] = 0x80/0x81` |
| Proximity | `data[1] bit 7` | `frame[0] bit 6` |
| In-Range | `data[1] bit 5` (HighConfidence) | `frame[0] bit 5` |
| Eraser / Invert | `data[1] bit 4` | `frame[0] bit 4` |
| Barrel Button 1 | `data[1] bit 1` | `frame[0] bit 1` |
| Barrel Button 2 | `data[1] bit 2` | `frame[0] bit 2` |
| X coordinate | `data[2–4]` (LE + high byte) | `frame[1–2]` (uint16 LE) |
| Y coordinate | `data[5–7]` (LE + high byte) | `frame[3–4]` (uint16 LE) |
| Pressure | `data[8–9]` (uint16 LE) | `frame[5–6]` (uint16 LE) |
| Tilt X | `data[10]` (int8) | `frame[7]` (int8) |
| Tilt Y | `data[11]` (int8) | `frame[8]` (int8) |
| Hover distance | `data[16]` (uint8) | `frame[13]` (uint8) |
| Rotation (Art Pen) | `data[?]` (not in 0x10 standard path) | `frame[9–10]` (int16 LE) |
| Tool serial | Not in pen reports | `data[99–106]` (uint64 LE) |
| Tool ID | In-proximity ID report (0x05/0x06) | `data[107–108]` (uint16 LE) |
| Express keys | Separate 44-byte report 0x11 | `data[282]` bitmask |
| Touch ring | Not decoded in USB IntuosV2 path | `data[285]` bits 0–6 |
| Battery | Not in USB pen reports | `data[284]` bits 0–6 |

---

## 8. Example Report Parses

### Example A — USB pen hover (Report 0x10)

```
Bytes: 10 A0 00 80 00 40 4B 00 00 00 05 F8 00 00 00 00 1E ...
       [0] [1] [2] [3] [4] [5] [6] [7] [8] [9][10][11]    [16]
```

| Field | Raw bytes | Decoded value |
|-------|-----------|---------------|
| Report ID | `0x10` | Pen report |
| Status | `0xA0` | bit7=1 (proximity), bit5=1 (high confidence), bit1=0, bit2=0 |
| X | `0x00, 0x80, ext=0x00` | `0x8000 \| 0x000000 = 32768` |
| Y | `0x40, 0x4B, ext=0x00` | `0x4B40 \| 0x000000 = 19264` |
| Pressure | `0x00, 0x00` | 0 (hovering) |
| Tilt X | `0x05` | +5 (slight right tilt) |
| Tilt Y | `0xF8` | −8 (slight toward user) |
| Hover distance | `0x1E` | 30 (hovering ~mid-range) |

### Example B — USB pen on surface (Report 0x10)

```
Bytes: 10 A2 24 80 00 6F 4B 00 14 7F 08 F5 00 00 00 00 00 ...
       [0] [1] [2] [3] [4] [5] [6] [7] [8] [9][10][11]    [16]
```

| Field | Raw bytes | Decoded value |
|-------|-----------|---------------|
| Report ID | `0x10` | Pen report |
| Status | `0xA2` | bit7=1 (proximity), bit5=1 (high confidence), bit1=1 (barrel 1 pressed) |
| X | `0x24, 0x80, ext=0x00` | `0x8024 = 32804` |
| Y | `0x6F, 0x4B, ext=0x00` | `0x4B6F = 19311` |
| Pressure | `0x14, 0x7F` | `0x7F14 = 32532` (light tip contact) |
| Tilt X | `0x08` | +8 |
| Tilt Y | `0xF5` | −11 |
| Hover distance | `0x00` | 0 (tip in contact) |

### Example C — USB express key press (Report 0x11)

```
Bytes: 11 04 00 00 00 00 ... (44 bytes total)
       [0] [1]
```

| Field | Decoded |
|-------|---------|
| Report ID | `0x11` (aux buttons) |
| Key bitmask | `0x04` = bit 2 set → Express Key 2 pressed |

### Example D — Bluetooth pen frame (from 0x80 container)

```
Container byte 0: 0x80
Frame 0 (data[1..14]):
  f[0] = 0xE0   → valid=1, prox=1, range=1, invert=0
  f[1..2] = 0x24, 0x01  → X = 0x0124 = 292
  f[3..4] = 0x6F, 0x00  → Y = 0x006F = 111
  f[5..6] = 0x14, 0x03  → Pressure = 0x0314 = 788
  f[7] = 0x06  → Tilt X = +6
  f[8] = 0xFC  → Tilt Y = −4
  f[9..10] = 0x00, 0x00 → Rotation = 0 (standard pen, not Art Pen)
  f[11..12] = 0x00, 0x00 → Wheel = 0
  f[13] = 0x00 → Hover distance = 0 (in contact)
```

---

## 9. Known Unknowns and Caveats

| Item | Status | Notes |
|------|--------|-------|
| Bytes `[12–15]` of Report 0x10 | **Unknown** | Not decoded in OTD or Linux kernel IntuosV2 path; may carry tool sub-type data or be padding |
| HoverDistance in Report 0x1E | **Conflicted** | OTD reads `report[11]` (same byte as Tilt X); canonical offset unverified — treat as `data[16]` same as 0x10 |
| Art Pen rotation in USB path | **Not in 0x10** | Rotation only appears in BT path `frame[9–10]`; USB Art Pen rotation uses legacy Intuos3-era tool-type packets, not 0x10 |
| Touch ring position in USB path | **Missing** | Ring position (`data[285]` in BT) has no confirmed USB IntuosV2 equivalent in open sources |
| Bytes `[17–43]` of Report 0x11 | **Unknown** | Pad touch ring might encode here; unconfirmed |
| Sequence/frame counter | **Unverified** | Some captures show incrementing value at `data[1]` low bits in report 0x10 on certain firmware; OTD does not decode it |
| Tool ID via USB IntuosV2 | **Separate reports** | Tool identification uses Report IDs `0x05` and `0x06` (WACOM_REPORT_INTUOS_ID1/ID2), not report 0x10 itself |

---

## 10. Source Summary

| Source | Authority | URL |
|--------|-----------|-----|
| Linux kernel `wacom_wac.c` (master) | Primary — governs all Linux behavior | https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_wac.c |
| Linux kernel `wacom_wac.h` (master) | Report ID and enum constants | https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_wac.h |
| OpenTabletDriver `IntuosV2Report.cs` | Primary — most explicit USB byte map | https://github.com/OpenTabletDriver/OpenTabletDriver/blob/master/OpenTabletDriver.Configurations/Parsers/Wacom/IntuosV2/IntuosV2Report.cs |
| OpenTabletDriver `PTH-660.json` | Device config with InputReportLength | https://github.com/OpenTabletDriver/OpenTabletDriver/blob/master/OpenTabletDriver.Configurations/Configurations/Wacom/PTH-660.json |
| OpenTabletDriver `IntuosV2OffsetReport.cs` | 0x1E layout | https://github.com/OpenTabletDriver/OpenTabletDriver/blob/master/OpenTabletDriver.Configurations/Parsers/Wacom/IntuosV2/IntuosV2OffsetReport.cs |
| Arch Linux bbs thread #239232 | Live USB sysinfo for 056A:0357 | https://bbs.archlinux.org/viewtopic.php?id=239232 |
