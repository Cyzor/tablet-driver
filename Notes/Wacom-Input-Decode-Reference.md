2026-03-25

# Wacom Tablet Input Data Decode Reference

**Scope:** USB/Bluetooth devices, approximately 2003–2017 (last 20 years from time of this writing). All values are unsigned unless marked **signed**. All multi-byte fields are **big-endian** on Intuos and **little-endian** on Graphire/Bamboo unless noted. VID = `0x056A` for all.[^2][^1]

***

## Legend and Shared Definitions

### Report Packet Structure Header

Every packet begins with a **Report ID** byte that identifies which input device is reporting and what type of data follows. The driver dispatches to the correct parser based on this byte plus the device's known packet length.[^1]

### Common Event Code Mapping

| Linux EV_KEY Code | Value | Meaning |
| :-- | :-- | :-- |
| `BTN_TOUCH` | 0x14A | Pen tip physically touching surface |
| `BTN_STYLUS` | 0x14B | Lower barrel button (side switch 1) |
| `BTN_STYLUS2` | 0x14C | Upper barrel button (side switch 2) |
| `BTN_TOOL_PEN` | 0x140 | Pen in proximity |
| `BTN_TOOL_RUBBER` | 0x141 | Eraser in proximity |
| `BTN_TOOL_BRUSH` | 0x142 | Stroke brush tool in proximity |
| `BTN_TOOL_PENCIL` | 0x143 | Inking pen in proximity |
| `BTN_TOOL_AIRBRUSH` | 0x144 | Airbrush in proximity |
| `BTN_TOOL_MOUSE` | 0x146 | 4D mouse / cursor in proximity |
| `BTN_TOOL_LENS` | 0x147 | Lens cursor in proximity |
| `BTN_LEFT/MID/RIGHT` | 0x110–0x112 | Mouse/cursor buttons |
| `BTN_SIDE / BTN_EXTRA` | 0x113–0x114 | 4D mouse extra buttons |

| Linux EV_ABS Code | Meaning | Range (typical) |
| :-- | :-- | :-- |
| `ABS_X` | X coordinate (absolute) | 0 – MaxX |
| `ABS_Y` | Y coordinate (absolute) | 0 – MaxY |
| `ABS_PRESSURE` | Tip pressure | 0 – PressureMax |
| `ABS_DISTANCE` | Hover distance from surface | 0 – 15 or 31 |
| `ABS_TILT_X` | X tilt (signed) | −63 to +63 |
| `ABS_TILT_Y` | Y tilt (signed) | −63 to +63 |
| `ABS_WHEEL` | Airbrush fingerwheel / scroll | 0 – 1023 |
| `ABS_RZ` | Z-axis rotation (4D mouse) | −900 to +899 |
| `ABS_THROTTLE` | 4D mouse throttle wheel (signed) | −1023 to +1023 |
| `MSC_SERIAL` | Tool serial number | 32-bit unsigned |

[^2]

***

## Family 1 — Graphire3 / Graphire4 (CTE-series)

**Models:** CTE-430, CTE-440, CTE-630, CTE-640
**Protocol:** IV (extended) | **Packet length:** 8 bytes | **Endian:** Little-endian
**Interfaces:** 1 (pen+mouse on interface 0)
**PID range:** 0x13–0x17[^1]

All packets begin with Report ID = **`0x02`** for pen/eraser/mouse data and **`0x03`** for pad buttons.

***

### 1A. Pen Packet (Report ID `0x02`, tool type bits [6:5] = `00`)

| Byte | Bits | Field | Encoding | Range | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 0 | [7:0] | Report ID | Fixed | `0x02` | Any other value = unknown, discard |
| 1 | [^4] | Proximity | Boolean | 0=out, 1=in | Set when pen is within hover range |
| 1 | [6:5] | Tool type | Enum | `00`=pen, `01`=eraser, `10`=cursor | Determines BTN_TOOL_* to assert |
| 1 | [4:3] | Reserved | — | 0 | Ignore |
| 1 | [^5] | Barrel btn 2 | Boolean | 0/1 | `BTN_STYLUS2` (upper side switch) |
| 1 | [^6] | Barrel btn 1 | Boolean | 0/1 | `BTN_STYLUS` (lower side switch) |
| 1 |  | Tip switch | Boolean | 0/1 | `BTN_TOUCH`; pen tip contact |
| 2 | [7:0] | X low byte | Uint8 LE | — | Low byte of X coordinate |
| 3 | [7:0] | X high byte | Uint8 LE | — | High byte: X = `data[^2] \| (data[^3]<<8)` |
| 4 | [7:0] | Y low byte | Uint8 LE | — | Low byte of Y coordinate |
| 5 | [7:0] | Y high byte | Uint8 LE | — | Y = `data[^4] \| (data[^5]<<8)` |
| 6 | [7:0] | Pressure low | Uint8 | — | Low 8 bits of pressure value |
| 7 | [1:0] | Pressure high | 2-bit | — | Bits [9:8]: pressure = `data[^6] \| ((data[^7]&0x03)<<8)` |
| 7 | [7:2] | Reserved | — | 0 |  |

**Coordinate ranges by model:**


| Model | MaxX | MaxY | PressureMax |
| :-- | :-- | :-- | :-- |
| CTE-430 (Graphire3 4x5) | 10208 | 7424 | 511 |
| CTE-440 (Graphire3 6x8) | 16704 | 12064 | 511 |
| CTE-630 (Graphire4 4x5) | 10208 | 7424 | 511 |
| CTE-640 (Graphire4 6x8) | 16704 | 12064 | 511 |

**No tilt data on any Graphire model.** Hover distance is not reported on Graphire series.[^1]

***

### 1B. Eraser Packet (Report ID `0x02`, tool type bits [6:5] = `01`)

Identical byte layout to 1A. Assert `BTN_TOOL_RUBBER` instead of `BTN_TOOL_PEN`. Barrel buttons are not physically present on eraser end; assert `BTN_STYLUS` = 0, `BTN_STYLUS2` = 0. Pressure encoding is the same (byte 6–7).[^1]

***

### 1C. Cursor / Mouse Packet (Report ID `0x02`, tool type bits [6:5] = `10`)

The Graphire optical mouse uses the same 8-byte packet but repurposes the pressure bytes.


| Byte | Bits | Field | Encoding | Range | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 0 | [7:0] | Report ID | Fixed | `0x02` |  |
| 1 | [^4] | Proximity | Boolean | 0/1 | `BTN_TOOL_MOUSE` active when `data[^7] > 24` |
| 1 | [6:5] | Tool type | Fixed | `10` | Cursor/mouse |
| 1 | [^5] | Mouse btn 3 | Boolean | 0/1 | `BTN_MIDDLE` |
| 1 | [^6] | Mouse btn 2 | Boolean | 0/1 | `BTN_RIGHT` |
| 1 |  | Mouse btn 1 | Boolean | 0/1 | `BTN_LEFT` |
| 2 | [7:0] | X low | LE | — | X = `data[^2] \| (data[^3]<<8)` |
| 3 | [7:0] | X high | LE | — |  |
| 4 | [7:0] | Y low | LE | — | Y = `data[^4] \| (data[^5]<<8)` |
| 5 | [7:0] | Y high | LE | — |  |
| 6 | [7:0] | Scroll wheel | Signed int8 | −127 to +127 | `REL_WHEEL`; negative = scroll down |
| 7 | [7:0] | Distance | Uint8 | 0–31 | `ABS_DISTANCE`; >24 = in range |

[^1]

***

### 1D. Pad / Express Key Packet (Report ID `0x03`)

| Byte | Bits | Field | Encoding | Range | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 0 | [7:0] | Report ID | Fixed | `0x03` | Pad device report |
| 1 | [^7] | Pad key 4 | Boolean | 0/1 | Rightmost key (BTN_4) |
| 1 | [^5] | Pad key 3 | Boolean | 0/1 | BTN_3 |
| 1 | [^6] | Pad key 2 | Boolean | 0/1 | BTN_2 |
| 1 |  | Pad key 1 | Boolean | 0/1 | Leftmost key (BTN_1) |
| 2–7 | — | Reserved | 0 | — |  |

CTE-430/630 have **4 pad keys** (bits [3:0] of byte 1). CTE-440/640 have the same layout. Report fires only on key state change.[^8]

***

## Family 2 — Bamboo (CTL/CTH series, 2nd and 3rd gen)

**Models:** CTL-460/660, CTH-460/461/660/661/680, CTL/CTH-471
**Protocol:** VI simplified | **Pen packet:** 10 bytes | **Touch packet:** 10 bytes
**Interfaces:** 2 (pen on iface 0, touch on iface 1 for CTH models)
**PID range:** 0xD1–0xD8[^9]

***

### 2A. Bamboo Pen Packet (Interface 0, Report ID `0x02`)

| Byte | Bits | Field | Encoding | Range | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 0 | [7:0] | Report ID | Fixed | `0x02` | Pen data |
| 1 | [^3] | Proximity | Boolean | 0/1 | `BTN_TOOL_PEN` when bit6=1 and bit5=0; `BTN_TOOL_RUBBER` when bit5=1 |
| 1 | [^10] | Eraser flag | Boolean | 0/1 | Switches tool to eraser end |
| 1 | [^5] | Barrel btn 2 | Boolean | 0/1 | `BTN_STYLUS2` |
| 1 | [^6] | Barrel btn 1 | Boolean | 0/1 | `BTN_STYLUS` |
| 1 |  | Tip switch | Boolean | 0/1 | `BTN_TOUCH` |
| 2 | [7:0] | X low | Uint8 LE | — |  |
| 3 | [7:0] | X high | Uint8 LE | — | X = `data[^2] \| (data[^3]<<8)`; range 0–MaxX |
| 4 | [7:0] | Y low | Uint8 LE | — |  |
| 5 | [7:0] | Y high | Uint8 LE | — | Y = `data[^4] \| (data[^5]<<8)` |
| 6 | [7:0] | Pressure low | Uint8 | — |  |
| 7 | [1:0] | Pressure high | 2-bit | — | Pressure = `data[^6] \| ((data[^7]&0x03)<<8)`; 10-bit, 0–1023 |
| 8–9 | — | Reserved | 0 | — |  |

**No tilt on Bamboo series.**[^9]

**Coordinate ranges by model:**


| Model | MaxX | MaxY | PressureMax |
| :-- | :-- | :-- | :-- |
| CTL-460 / CTH-460 | 14720 | 9200 | 1023 |
| CTL-660 / CTH-661 | 21648 | 13530 | 1023 |
| CTH-460A | 14720 | 9200 | 1023 |
| CTH-680 (Bamboo Create) | 21648 | 13530 | 1023 |
| CTL/CTH-471 (Connect) | 14720 | 9200 | 1023 |


***

### 2B. Bamboo Pad / Express Key Packet (Interface 0, Report ID `0x03`)

| Byte | Bits | Field | Encoding | Range | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 0 | [7:0] | Report ID | Fixed | `0x03` | Pad device |
| 1 | [^7] | Pad key 4 | Boolean | 0/1 |  |
| 1 | [^5] | Pad key 3 | Boolean | 0/1 |  |
| 1 | [^6] | Pad key 2 | Boolean | 0/1 |  |
| 1 |  | Pad key 1 | Boolean | 0/1 |  |
| 2–9 | — | Reserved | 0 | — | Some revisions carry scroll ring delta in byte 2 |


***

### 2C. Bamboo Touch Packet (Interface 1, CTH models, Report ID `0x01`)

Bamboo Pen \& Touch models report up to **2 simultaneous touch contacts** on interface 1.[^9]


| Byte | Bits | Field | Encoding | Range | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 0 | [7:0] | Report ID | Fixed | `0x01` | Touch data |
| 1 | [^6] | Contact 2 active | Boolean | 0/1 | 1 = second finger on surface |
| 1 |  | Contact 1 active | Boolean | 0/1 | 1 = first finger on surface |
| 2 | [7:0] | Touch 1 X high | Uint8 | — |  |
| 3 | [7:4] | Touch 1 X low | 4-bit | — | X1 = `(data[^2]<<4) \| (data[^3]>>4)`; 12-bit |
| 3 | [3:0] | Touch 1 Y high | 4-bit | — |  |
| 4 | [7:0] | Touch 1 Y low | Uint8 | — | Y1 = `((data[^3]&0x0F)<<8) \| data[^4]`; 12-bit |
| 5 | [7:0] | Touch 2 X high | Uint8 | — |  |
| 6 | [7:4] | Touch 2 X low | 4-bit | — | X2 = `(data[^5]<<4) \| (data[^6]>>4)` |
| 6 | [3:0] | Touch 2 Y high | 4-bit | — |  |
| 7 | [7:0] | Touch 2 Y low | Uint8 | — | Y2 = `((data[^6]&0x0F)<<8) \| data[^7]` |
| 8–9 | — | Reserved | 0 | — |  |

Touch coordinate space: 0–1024 (normalized). Scale to screen using `TouchMaxX`/`TouchMaxY` = 1024.

***

## Family 3 — Intuos3 (PTZ-series)

**Models:** PTZ-430, PTZ-431W, PTZ-630, PTZ-631W, PTZ-930, PTZ-1230, PTZ-1231W
**Protocol:** VI | **Pen packet:** 9 bytes | **Pad packet:** 9 bytes
**Interfaces:** 2 (pen on iface 0, pad on iface 1)
**Coordinate endian:** Big-endian | **PID range:** 0xB0–0xB8 [^11]

***

### 3A. Intuos3 Proximity Enter Packet (Report ID `0xC0` on iface 0)

When a tool enters the active area, the tablet sends a dedicated enter packet before any positional data.[^1]


| Byte | Bits | Field | Encoding | Range | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 0 | [7:0] | Report ID | Fixed | `0xC0` | Proximity enter |
| 1 |  | Tool index | Boolean | 0 or 1 | Tracks up to 2 concurrent tools |
| 2 | [7:4] | Tool ID high | 4-bit | — | Tool class: combined with data[^7] |
| 2 | [3:0] | Tool ID mid | 4-bit | — |  |
| 3 | [7:4] | Tool ID low | 4-bit | — | Full tool ID = `(data[^2]<<4) \| (data[^3]>>4)` |
| 3 | [3:0] | Serial hi | 4-bit | — | Upper bits of tool serial |
| 4 | [7:0] | Serial byte 2 | Uint8 | — |  |
| 5 | [7:0] | Serial byte 3 | Uint8 | — |  |
| 6 | [7:0] | Serial byte 4 | Uint8 | — |  |
| 7 | [7:4] | Serial low | 4-bit | — | Serial = 32-bit unique tool ID |
| 7 | [3:0] | Reserved | — | 0 |  |
| 8 | — | Reserved | 0 | — |  |

**Tool ID decode table:**


| Tool ID (hex) | Tool Type | BTN_TOOL_* |
| :-- | :-- | :-- |
| `0x012`, `0x832` | Inking pen / pencil | `BTN_TOOL_PENCIL` |
| `0x022`, `0x822` | Standard pen | `BTN_TOOL_PEN` |
| `0x032`, `0x812` | Stroke brush | `BTN_TOOL_BRUSH` |
| `0x094`, `0x09C` | 4D mouse | `BTN_TOOL_MOUSE` |
| `0x096` | Lens cursor | `BTN_TOOL_LENS` |
| `0x0FA`, `0x82A`, `0x91A` | Eraser | `BTN_TOOL_RUBBER` |
| `0x112` | Airbrush | `BTN_TOOL_AIRBRUSH` |

[^1]

***

### 3B. Intuos3 Proximity Exit Packet (Report ID `0x80`)

| Byte | Bits | Field | Encoding | Notes |
| :-- | :-- | :-- | :-- | :-- |
| 0 | [7:0] | Report ID | Fixed `0x80` | Proximity exit |
| 1 |  | Tool index | 0 or 1 | Which tool slot exited |
| 2–8 | — | Reserved | 0 | Assert `BTN_TOOL_*` = 0 for this slot |


***

### 3C. Intuos3 General Pen Packet (Report ID `0x02`)

This packet fires for all standard stylus tools (pen, pencil, brush, eraser) while in proximity.[^11][^1]


| Byte | Bits | Field | Encoding | Range | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 0 | [7:0] | Report ID | Fixed `0x02` | — |  |
| 1 | [^4] | Reserved | — | 0 |  |
| 1 | [^3] | Proximity | Boolean | 0/1 | 1 = tool is in range; 0 = lifting off |
| 1 | [^10] | Reserved | — | 0 |  |
| 1 | [^9] | Reserved | — | 0 |  |
| 1 | [^7] | Tilt X sign | Boolean | 0=pos, 1=neg | Sign bit for Tilt X interpretation |
| 1 | [^5] | Barrel btn 2 | Boolean | 0/1 | `BTN_STYLUS2` (upper barrel switch) |
| 1 | [^6] | Barrel btn 1 | Boolean | 0/1 | `BTN_STYLUS` (lower barrel switch) |
| 1 |  | Tip switch | Boolean | 0/1 | `BTN_TOUCH` |
| 2 | [7:0] | X high byte | BE | — |  |
| 3 | [7:0] | X low byte | BE | — | X = `(data[^2]<<8) \| data[^3]`; 0–MaxX |
| 4 | [7:0] | Y high byte | BE | — |  |
| 5 | [7:0] | Y low byte | BE | — | Y = `(data[^4]<<8) \| data[^5]`; 0–MaxY |
| 6 | [7:0] | Pressure high | Uint8 | — | Pressure bits [11:4] |
| 7 | [7:4] | Pressure low | 4-bit | — | Pressure = `(data[^6]<<4) \| (data[^7]>>4)`; 12-bit, 0–2047 |
| 7 | [3:0] | Tilt X high | 4-bit | — | Combined with byte 8 |
| 8 | [7:4] | Tilt X low | 4-bit | — | TiltX (signed 7-bit) = `((data[^7]&0x0F)<<3) \| (data[^8]>>5)`; −63 to +63° |
| 8 | [4:0] | Tilt Y | 5-bit (+ sign in byte 1) | — | TiltY (signed 7-bit) = `data[^8]&0x1F` + sign from byte 1 context |

> **Pressure interpretation:** Raw value 0–2047 mapped to 0–100%. `BTN_TOUCH` fires when pressure exceeds ~10 raw counts. Physical touch threshold varies by nib type.

**Coordinate ranges by model:**


| Model | MaxX | MaxY | PressureMax | Tilt Range |
| :-- | :-- | :-- | :-- | :-- |
| PTZ-430 | 25400 | 20320 | 2047 | ±63° |
| PTZ-431W | 31496 | 19685 | 2047 | ±63° |
| PTZ-630 | 40640 | 30480 | 2047 | ±63° |
| PTZ-631W | 54204 | 31750 | 2047 | ±63° |
| PTZ-930 | 60960 | 45720 | 2047 | ±63° |
| PTZ-1230 | 60960 | 60960 | 2047 | ±63° |
| PTZ-1231W | 97536 | 60960 | 2047 | ±63° |


***

### 3D. Intuos3 Airbrush Packet (Report ID `0x02`, context-distinguished by tool type from proximity enter)

Airbrush uses the same Report ID as the standard pen but repurposes the pressure bytes for fingerwheel. The driver tracks tool type from the proximity enter packet.[^1]


| Byte | Bits | Field | Encoding | Range | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 0–1 | — | (same as 3C) | — | — | Proximity, buttons identical |
| 2–5 | — | X, Y | BE 16-bit | — | Same as 3C |
| 6 | [7:0] | Wheel high | Uint8 | — | Fingerwheel bits [9:2] |
| 7 | [7:6] | Wheel low | 2-bit | — | Wheel = `(data[^6]<<2) \| (data[^7]>>6)`; 10-bit, 0–1023 |
| 7 | [5:4] | Tilt X high | 2-bit | — |  |
| 7 | [3:0] | (padding) | — | 0 |  |
| 8 | [7:0] | Tilt X/Y | packed | ±63° | Same tilt encoding as 3C, byte 8 |

The fingerwheel models `ABS_WHEEL`. Clockwise rotation increases value; counter-clockwise decreases.

***

### 3E. Intuos3 Cursor / 4D Mouse Packet (Report ID `0x03`)

| Byte | Bits | Field | Encoding | Range | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 0 | [7:0] | Report ID | Fixed `0x03` | — | Cursor tool |
| 1 | [^3] | Proximity | Boolean | 0/1 | `BTN_TOOL_MOUSE` or `BTN_TOOL_LENS` |
| 2–3 | — | X | BE 16-bit | 0–MaxX |  |
| 4–5 | — | Y | BE 16-bit | 0–MaxY |  |
| 6 | [7:0] | Rotation/throttle high | Uint8 | — | Depending on data[^6] bit flags |
| 7 | [7:6] | Rotation/throttle low | 2-bit | — |  |
| 7 | [^10] | Rotation direction | Boolean | 0=CW, 1=CCW | Sign for ABS_RZ |
| 8 | [7:0] | Button mask | Bitmask | — | See button table below |
| 9 | [7:4] | Distance | 4-bit | 0–15 | `ABS_DISTANCE` |

**Cursor / 4D Mouse button byte (data):**[^12]


| Bit | 4D Mouse | Lens Cursor |
| :-- | :-- | :-- |
|  | `BTN_LEFT` | `BTN_LEFT` |
| [^6] | `BTN_MIDDLE` | `BTN_MIDDLE` |
| [^5] | `BTN_RIGHT` | `BTN_RIGHT` |
| [^7] | `BTN_EXTRA` (throttle key) | `BTN_EXTRA` |
| [^9] | `BTN_SIDE` (4th button) | `BTN_SIDE` |
| [^10] | `BTN_SIDE` (5th button) | — |
| [7:6] | Reserved | Reserved |

**Rotation / throttle decode for 4D mouse:**

```
If data[^1] bit[^1] = 1 (rotation packet):
  raw = (data[^6] << 2) | (data[^7] >> 6)    // 10-bit
  ABS_RZ = (data[^7] & 0x20) ? raw : -(raw) - 1
  Range: −900 to +899 tenths of a degree

If data[^1] bit[^1] = 0 (button/throttle packet):
  raw = (data[^6] << 2) | (data[^7] >> 6)
  ABS_THROTTLE = (data[^8] & 0x08) ? raw : -raw
  Range: −1023 to +1023
```


***

### 3F. Intuos3 Express Key / Pad Packet (Interface 1, Report ID `0x0C`)

| Byte | Bits | Field | Encoding | Range | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 0 | [7:0] | Report ID | Fixed `0x0C` | — | Pad device |
| 1 | [7:4] | Keys 8–5 | Bitmask | 0/1 each | Key 5 = bit4, Key 6 = bit5, Key 7 = bit6, Key 8 = bit7 |
| 1 | [3:0] | Keys 4–1 | Bitmask | 0/1 each | Key 1 = bit0 (leftmost) |
| 2 | [7:0] | Keys 9–16 | Bitmask | 0/1 each | PTZ-930/1230/1231W only (8 additional keys) |
| 3 | [7:0] | Left strip high | Uint8 | — | Left touch strip position, bits [9:2] |
| 4 | [1:0] | Left strip low | 2-bit | — | Strip pos = `(data[^3]<<2) \| (data[^4]>>6)`; 10-bit signed |
| 4 | [5:2] | Right strip high | 4-bit | — | Right touch strip |
| 5 | [7:0] | Right strip low | Uint8 | — | Right strip = packed 10-bit signed |
| 6–8 | — | Reserved | 0 | — |  |

**Express key layout by model:**


| Model | Total Keys | Touch Strips | Notes |
| :-- | :-- | :-- | :-- |
| PTZ-430 / PTZ-431W | 4 keys | 1 strip (left only) | Keys numbered 1–4; byte 1 bits [3:0] |
| PTZ-630 / PTZ-631W | 8 keys | 2 strips (left + right) | Byte 1 = keys 1–8 |
| PTZ-930 / PTZ-1230 | 8 keys | 2 strips | Same as PTZ-630 |
| PTZ-1231W | 8 keys | 2 strips | Wide format; same pad layout |

Touch strip values are relative delta, not absolute position. A finger resting on the strip sends no event; sliding upward sends positive delta.[^2]

***

## Family 4 — Intuos4 (PTK-series)

**Models:** PTK-440/640/840/1240, PTK-540WL
**Protocol:** VI extended | **Pen packet:** 10 bytes | **OLED pad:** 9 bytes
**Interfaces:** 2 (pen iface 0, pad iface 1)
**PID range:** 0xB8–0xBC[^9]

***

### 4A. Intuos4 Pen Packet (Interface 0, Report ID `0x12`)

Intuos4 upgrades pressure to **12-bit (0–2047)** and changes the report ID scheme.[^9]


| Byte | Bits | Field | Encoding | Range | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 0 | [7:0] | Report ID | `0x12`=pen data, `0x10`=prox out | — | `0xC2` = enter event (tool ID packet) |
| 1 |  | Tool index | Boolean | 0 or 1 | Dual-tool slot |
| 1 | [^6] | Proximity | Boolean | 0/1 | 1 = tool in range |
| 1 | [^5] | Tip switch | Boolean | 0/1 | `BTN_TOUCH` |
| 1 | [^7] | Barrel btn 1 | Boolean | 0/1 | `BTN_STYLUS` |
| 1 | [^9] | Barrel btn 2 | Boolean | 0/1 | `BTN_STYLUS2` |
| 1 | [7:5] | Reserved | 0 | — |  |
| 2 | [7:0] | X high | BE | — |  |
| 3 | [7:0] | X low | BE | — | X = `(data[^2]<<8) \| data[^3]`; 0–MaxX |
| 4 | [7:0] | Y high | BE | — |  |
| 5 | [7:0] | Y low | BE | — | Y = `(data[^4]<<8) \| data[^5]` |
| 6 | [7:0] | Pressure high | Uint8 | — | Pressure bits [11:4] |
| 7 | [7:4] | Pressure low | 4-bit | — | Pressure = `(data[^6]<<4) \| (data[^7]>>4)`; 12-bit, 0–2047 |
| 7 | [3:0] | Distance high | 4-bit | — | Hover distance bits [5:2] |
| 8 | [7:6] | Distance low | 2-bit | — | `ABS_DISTANCE` = 6-bit, 0–63 |
| 8 | [5:0] | Reserved | — | 0 |  |
| 9 | [6:0] | Tilt X | Signed 7-bit | −63 to +63° | Two's complement; positive = right |
| 10 | [6:0] | Tilt Y | Signed 7-bit | −63 to +63° | Positive = toward user (down) |

**Coordinate ranges by model:**


| Model | MaxX | MaxY | PressureMax |
| :-- | :-- | :-- | :-- |
| PTK-440 (Intuos4 S) | 31496 | 19685 | 2047 |
| PTK-640 (Intuos4 M) | 44704 | 27940 | 2047 |
| PTK-840 (Intuos4 L) | 63496 | 39370 | 2047 |
| PTK-1240 (Intuos4 XL) | 97536 | 60960 | 2047 |
| PTK-540WL (Intuos4 WL) | 44704 | 27940 | 2047 |


***

### 4B. Intuos4 Proximity Enter/Exit

Same structure as Intuos3 (§3A / §3B), Report IDs `0xC2` (enter) and `0x80` (exit). Tool ID decode table identical. Serial number encoding unchanged.

***

### 4C. Intuos4 OLED Pad Packet (Interface 1, Report ID `0x0C`)

Intuos4 has **8 OLED express keys** (4 per side of the tablet) plus a touch ring between them.


| Byte | Bits | Field | Encoding | Range | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 0 | [7:0] | Report ID | Fixed `0x0C` | — | Pad device |
| 1 | [^4] | Key 8 (top right) | Boolean | 0/1 | `BTN_8` |
| 1 | [^3] | Key 7 | Boolean | 0/1 | `BTN_7` |
| 1 | [^10] | Key 6 | Boolean | 0/1 | `BTN_6` |
| 1 | [^9] | Key 5 | Boolean | 0/1 | `BTN_5` |
| 1 | [^7] | Key 4 | Boolean | 0/1 | `BTN_4` |
| 1 | [^5] | Key 3 | Boolean | 0/1 | `BTN_3` |
| 1 | [^6] | Key 2 | Boolean | 0/1 | `BTN_2` |
| 1 |  | Key 1 (bottom left) | Boolean | 0/1 | `BTN_1` |
| 2 | [7:0] | Touch ring position | Uint8 | 0–71 | Angular position in 5° steps; 72 steps = 360° |
| 2 | [^4] | Touch ring active | Boolean | 0/1 | 1 = finger detected on ring |
| 3 | [7:0] | Reserved | 0 | — |  |
| 4–8 | — | Reserved | 0 | — |  |

> **OLED icon output** (driver → device): Send output report `0x03` with 9 bytes: byte 0 = `0x03`, byte 1 = key index (0–7), bytes 2–8 = 7-row × 13-column monochrome bitmap, packed MSB-first. This is a **write-only** operation; no ack required.[^9]

***

## Family 5 — Intuos5 / Intuos Pro (PTH/PTK series)

**Models:** PTH-450/650/851, PTK-450/650
**Protocol:** VI extended with multi-touch | **Pen packet:** 10 bytes | **Touch packet:** variable
**Interfaces:** 2 (pen on iface 0, touch on iface 1 for PTH models)
**PID range:** 0x26–0x2A[^9]

Pen packets, proximity enter/exit, and pad packets are **identical to Intuos4 (Family 4)** above. Coordinate MaxX/MaxY values differ per model (see prior table). The following covers only the **touch interface** unique to PTH models.

***

### 5A. Intuos5 Touch Finger Packet (Interface 1, Report ID `0x02`)

Supports up to **16 simultaneous touch contacts**.


| Byte | Bits | Field | Encoding | Range | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 0 | [7:0] | Report ID | Fixed `0x02` | — | Touch data |
| 1 | [7:0] | Contact count | Uint8 | 0–16 | Number of active contacts in this report |
| 2–7 | — | Contact 1 data | 6 bytes | — | See contact record below |
| 8–13 | — | Contact 2 data | 6 bytes | — | Repeats for each contact (max 16) |
| … | — | … | … | — | Packet length = 2 + (6 × contact_count) |

**Per-contact record (6 bytes):**


| Offset | Bits | Field | Encoding | Range | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 0 | [7:0] | Contact ID | Uint8 | 0–15 | Persistent across frames; same finger = same ID |
| 0 | [^4] | Contact active | Boolean | 0/1 | 1 = touching; 0 = lift-off (last packet for this ID) |
| 1 | [7:0] | X high byte | BE | — |  |
| 2 | [7:0] | X low byte | BE | — | X = `(data[^1]<<8) \| data[^2]`; 0–4095 |
| 3 | [7:0] | Y high byte | BE | — |  |
| 4 | [7:0] | Y low byte | BE | — | Y = `(data[^3]<<8) \| data[^4]`; 0–4095 |
| 5 | [7:0] | Reserved | 0 | — | Future: contact width/height |

Scale touch coordinates to screen via `TouchMaxX` = 4096, `TouchMaxY` = 4096.

***

### 5B. Intuos Pro Pad (Interface 1, Report ID `0x0C`)

Identical to Intuos4 pad (§4C): 8 OLED keys + touch ring. PTH models support **multi-function touch ring** with 4 programmable modes.


| Byte | Bits | Field | Encoding | Notes |
| :-- | :-- | :-- | :-- | :-- |
| 2 | [^4] | Touch ring active | Boolean | Finger detected |
| 2 | [6:0] | Touch ring position | 7-bit | 0–71; 5° resolution |
| 3 | [1:0] | Ring mode | 2-bit | 0–3; which of 4 programmed functions is active |


***

## Family 6 — Cintiq (Pen Display, DTZ/DTK/DTH series)

**Models:** DTZ-2100, DTZ-1200W, DTK-2100, DTK-2400, DTH-2200
**Protocol:** VI (same as Intuos3/4) | **Pen packet:** 10 bytes
**Interfaces:** 2 (pen iface 0, pad iface 1); video via separate DisplayPort/HDMI
**PID range:** 0x3F, 0xC6, 0xCC, 0xF4, 0xF8[^9]

Cintiq pen packets are **structurally identical to Intuos3/4 pen packets**. The only differences are coordinate MaxX/MaxY values (mapped to screen pixels) and the express key layout.

***

### 6A. Cintiq Pen Packets

Use Family 3 (§3C) or Family 4 (§4A) decode tables per Cintiq generation:


| Model | Generation | Use Decode Table | MaxX | MaxY | PressureMax |
| :-- | :-- | :-- | :-- | :-- | :-- |
| DTZ-2100 (Cintiq 21UX 1st gen) | Intuos3-era | §3C | 87200 | 65600 | 1023 |
| DTZ-1200W (Cintiq 12WX) | Intuos3-era | §3C | 53020 | 33440 | 2047 |
| DTK-2100 (Cintiq 21UX 2nd gen) | Intuos4-era | §4A | 87200 | 65600 | 2047 |
| DTK-2400 (Cintiq 24HD) | Intuos4-era | §4A | 104480 | 65600 | 2047 |
| DTH-2200 (Cintiq 22HD Touch) | Intuos5-era | §4A + §5A | 95440 | 53720 | 2047 |

**Coordinate-to-pixel mapping:** Device coordinates are not 1:1 with screen pixels. Scale as:

```
pixel_x = (raw_x / MaxX) * display_width_px
pixel_y = (raw_y / MaxY) * display_height_px
```

Fuzz value = 4 (discard changes < 4 raw units to suppress jitter).[^2]

***

### 6B. Cintiq Express Key Packets (Interface 1, Report ID `0x0C`)

| Model | Keys | Touch Strips | Layout |
| :-- | :-- | :-- | :-- |
| DTZ-2100 | 8 (4 per side) | 0 | Byte 1 bits [7:0] = keys 1–8 |
| DTZ-1200W | 4 + 2 strips | 1 left, 1 right | Same as PTZ-630 (§3F) |
| DTK-2100 | 8 (4 per side) | 0 | Byte 1 bits [7:0] = keys 1–8 |
| DTK-2400 | 8 + 4 strips | 2 left, 2 right | Extended pad (byte 3–6 = strip data) |
| DTH-2200 Touch | 8 | 0 | 8 keys + touch interface (§5A) |

**DTK-2400 extended strip packet (9 bytes):**


| Byte | Bits | Field | Encoding | Notes |
| :-- | :-- | :-- | :-- | :-- |
| 0 | [7:0] | Report ID | `0x0C` |  |
| 1 | [7:0] | Keys 1–8 | Bitmask |  |
| 2 | [7:0] | Keys 9–13 | Bitmask | Bits [4:0]; 5 additional rocker keys |
| 3–4 | — | Left strip 1 | 10-bit signed | Upper left touch strip |
| 5–6 | — | Left strip 2 | 10-bit signed | Lower left touch strip |
| 7–8 | — | Right strip 1/2 | Packed | Right side strips (DTK-2400 only) |


***

## Appendix A — Hover Distance and Bearing Notes

### Distance (`ABS_DISTANCE`)

All Intuos-family tablets report hover distance when the pen is above the surface but within range. The raw value represents the **normalized gap** from the tablet surface, not a physical measurement:[^2]


| Family | ABS_DISTANCE Bits | Raw Max | Physical Approximation |
| :-- | :-- | :-- | :-- |
| Graphire3/4 | Not reported | — | Tool either in range (prox=1) or not |
| Bamboo | Not reported | — | Proximity-only |
| Intuos3 | 4-bit (`data[^9]>>4`) | 15 | 0 = touching, 15 ≈ 10mm above surface |
| Intuos4/5 | 6-bit (bytes 7–8) | 63 | 0 = touching, 63 ≈ 10mm above surface |
| Cintiq | Same as parent Intuos gen | Same | Same |

### Bearing / Z-axis Rotation

Only the **4D Mouse** (tool ID `0x094`/`0x09C`) and the **airbrush** (ID `0x112`) report Z-axis data. Standard pens do **not** report bearing (in-plane rotation around the pen's long axis). If your application needs pen bearing, it is not available on any Wacom model in this scope.[^1]

The 4D Mouse reports `ABS_RZ` in tenths-of-degrees (range −900 to +899). The airbrush reports `ABS_WHEEL` as a linear fingerwheel value (0–1023), not an angular bearing.

***

## Appendix B — Bluetooth Protocol Notes (PTK-540WL, future BT tablets)

The Intuos4 Wireless (PTK-540WL) connects as a Bluetooth HID device. The HID report format is **identical** to the USB version, but wrapped in a BT HID report with a prepended 1-byte connection status byte.[^9]


| Byte | Field | Notes |
| :-- | :-- | :-- |
| 0 | BT status | `0x02` = connected, `0x05` = battery low |
| 1–10 | Pen packet | Same as §4A above (shift all byte indices by +1) |

Re-initialization on BT reconnect must resend the mode switch via a BT HID SET_REPORT (Control channel) instead of a USB control transfer. Battery level is reported via a separate BT HID battery service report (Report ID `0x08`, byte 1 = 0–100 percent).

***

## Appendix C — Parsing Decision Tree (Implementation Reference)

```
On interrupt-in packet arrival:
│
├─ data[^0] == 0x02 ?
│   ├─ Device is Graphire3/4 (PKGLEN=8):
│   │   └─ data[^1]>>5 & 0x03 == 0 → pen;  1 → eraser;  2 → cursor
│   │
│   ├─ Device is Bamboo CTL/CTH (PKGLEN=10):
│   │   └─ data[^1]&0x20 → eraser;  else pen
│   │
│   └─ Device is Intuos3/4/5 or Cintiq (PKGLEN=9 or 10):
│       ├─ data[^1] & 0xFC == 0xC0 → proximity ENTER (tool ID packet)
│       ├─ data[^1] & 0xFE == 0x80 → proximity EXIT
│       ├─ data[^1] & 0xB8 == 0xA0 → general pen / eraser data
│       ├─ data[^1] & 0xBC == 0xB4 → airbrush fingerwheel data
│       └─ data[^1] & 0xBC == 0xA8 OR data[^1] & 0xBE == 0xB0 → cursor/4D mouse
│
├─ data[^0] == 0x03 ?
│   └─ Pad device report (express keys); parse per §1D / §2B / §3F
│
└─ data[^0] == 0x0C ?
    └─ Intuos3/4/5 or Cintiq pad report; parse per §3F / §4C / §5B / §6B
```

<div align="center">⁂</div>

[^1]: https://www.kernel.org/pub/linux/kernel/people/marcelo/linux-2.4/drivers/usb/wacom.c

[^2]: https://developer-docs.wacom.com/docs/icbt/linux/kernel-events/kernel-events-basics/

[^3]: https://github.com/torvalds/linux/blob/master/drivers/hid/wacom.h

[^4]: https://github.com/linuxwacom/wacom-hid-descriptors

[^5]: https://opentabletdriver.net/Wiki/Documentation/ConfigurationGuide

[^6]: https://github.com/OpenTabletDriver/OpenTabletDriver/issues/3204

[^7]: https://www.reddit.com/r/Fedora/comments/wc7zql/wacom_tablet_driver_interfering_with/

[^8]: https://github.com/OpenTabletDriver/OpenTabletDriver/releases

[^9]: https://opentabletdriver.net/Wiki/Development/Configurations

[^10]: https://opentabletdriver.net/Wiki/FAQ/General

[^11]: https://git.riwo.eu/Opensource/linux-toradex-kernel/-/blob/7742e7756c0637ae5378e394ca03978826e31a78/drivers/input/tablet/wacom_wac.h

[^12]: https://www.reddit.com/r/wacom/comments/1hle2zj/revive_your_old_wacom_tablets_on_macos_with/

