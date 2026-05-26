2026-05-25

# Huion Drawing Tablet Hardware & Protocol Spec Sheet

## 1. USB Identity

All current Huion tablets share a single USB Vendor ID:[^1][^2]

| Field | Value |
|-------|-------|
| USB Vendor ID | `0x256C` (decimal 9580) |
| Kernel symbol | `USB_VENDOR_ID_HUION` |

**Important caveat:** VID `0x256C` is also re-used by Gaomon and some other OEM tablet brands that share the underlying UC-Logic controller silicon. Device-string probing (§4) is required to disambiguate models.[^3]

### Known Product IDs

The following PIDs appear across the full OpenTabletDriver configuration corpus combined with `hid-ids.h`:[^4][^1]

| PID (hex) | Kernel symbol / Notes | Representative models |
|-----------|----------------------|----------------------|
| `0x006E` | `USB_DEVICE_ID_HUION_TABLET` | H420, H690, 1060 Plus (legacy), GC610, GT-221, Kamvas Pro 20/22/24 (first-gen), WH1409 |
| `0x006D` | `USB_DEVICE_ID_HUION_TABLET2` | H1060P, H1161, HS610, HS611, Kamvas 13/16, Kamvas Pro 13/16/24, Q11K, Q620M, RDS-160 |
| `0x0064` | *(no kernel symbol)* | H580X, H610X, H950P, RTE-100 |
| `0x0061` | *(no kernel symbol)* | G930L |
| `0x0060` | *(no kernel symbol)* | Q630M |
| `0x0067` | *(no kernel symbol)* | H951P (Inspiroy 2) |
| `0x0066` | *(no kernel symbol)* | H641P |
| `0x0068` | *(no kernel symbol)* | H1061P |
| `0x006B` | *(no kernel symbol)* | Kamvas Pro 19 (4K) |
| `0x006A` | *(no kernel symbol)* | RTM 500 (seen in wild) |
| `0x2008` | *(Gen 3 pen display)* | Kamvas 13 Gen 3 (16384-level pen) |

Many older/legacy models (H420, H690, 1060 Plus v1) enumerate as `0x006E` *without* a firmware version string at descriptor index 201, and use the v1 protocol (§4).

***

## 2. USB Enumeration & Interface Layout

Huion tablets enumerate as standard **USB HID** devices. The relevant interface structure is:[^5]

- **Interface 0** — Digitizer / pen interface (always the primary target)
- **Interface 1** — Keyboard/hotkey interface (present on multi-interface models; mark `pen.usage_invalid = true` and leave intact)[^6]
- **Interface 2+** — Additional consumer/system-control collections on some pen display models

The driver must set `HID_QUIRK_MULTI_INPUT` so that the pad node appears on a separate input device from the pen node — a requirement enforced by libinput.[^7]

***

## 3. Protocol Generations

Huion hardware divides into three protocol generations, determined at probe time:[^5][^6]

| Generation | Init descriptor | Pen report ID | Report length | Tilt | High-res coords |
|------------|----------------|---------------|---------------|------|----------------|
| **v0 (legacy)** | None; static fixed descriptor | `0x09` / `0x08` | 8 bytes | No | No |
| **v1** | String desc #100, 12 bytes | `0x07` | 8 bytes | No | No (16-bit X/Y) |
| **v2 (Giano / "modern")** | String desc #200, 18–32 bytes | `0x08` | 12 bytes | Yes (±60°) | Yes (fragmented 24-bit X) |
| **Gen 3** | String desc #200 | `0x08` | 14 bytes | Yes | Yes (fragmented_hires2) |

A transition firmware `"HUION_T153_160607"` exists: if string descriptor #201 returns exactly that string, skip v2 probing and fall directly to v1.[^6][^5]

***

## 4. Initialization Sequence

### Step 1 — Retrieve firmware version string

```
USB GET_DESCRIPTOR  bmRequestType=0x80  bRequest=0x06
  wValue = (0x03 << 8) | 201   // string descriptor #201
  wIndex = 0x0409              // language ID (US English)
  wLength = sizeof(transition_ver) + 1
```

The returned UTF-16LE string identifies the firmware, e.g. `"HUION_T194_210628"`. The kernel copies this into `hdev->uniq`. OpenTabletDriver uses the regex pattern from `DeviceStrings["201"]` in the JSON configuration to select among multiple models sharing the same PID.[^4][^6]

### Step 2 — Probe pen parameters (v2 path)

```
USB GET_DESCRIPTOR  bRequest=0x06
  wValue = (0x03 << 8) | 200   // string descriptor #200
  wIndex = 0x0409
  wLength = 32                 // accept 18–32 bytes
```

The driver validates the response is not a plain ASCII string (which would indicate the device ignores unknown descriptor indices). If valid binary data is returned, proceed with v2 parsing (§5). If `EPIPE` or ASCII response, fall back to v1.[^6]

### Step 3 — Probe pen parameters (v1 path, fallback)

```
USB GET_DESCRIPTOR  bRequest=0x06
  wValue = (0x03 << 8) | 100   // string descriptor #100
  wIndex = 0x0409
  wLength = 12
```

### Step 4 — Enable frame buttons (v1 only)

```
USB usb_string(dev, 123, buf, 16)
```

If the response is the string `"HK On"`, hardware buttons are successfully activated. OpenTabletDriver expresses this as `InitializationStrings: [100, 123]` for v1 devices and `` for v2.[^4][^6]

***

## 5. Parameter String Descriptor Layout

Both descriptors begin with 2 standard USB string header bytes (`bLength`, `bDescriptorType = 0x03`) followed by the payload.

### v1 Descriptor (index #100, 12 bytes total)

| Byte offset | Size | Field | Notes |
|-------------|------|-------|-------|
| 0 | 1 | `bLength` | Total length (12) |
| 1 | 1 | `bDescriptorType` | 0x03 |
| 2–3 | LE16 | `X_LM` | Logical maximum X (native coordinates) |
| 4–5 | LE16 | `Y_LM` | Logical maximum Y |
| 6–7 | LE16 | *(reserved/unknown)* | — |
| 8–9 | LE16 | `PRESSURE_LM` | Pressure logical maximum (e.g. 2047) |
| 10–11 | LE16 | `resolution` | lpi; 0 means unknown → set physical max to 0 |

Physical maximum is derived: `X_PM = X_LM * 1000 / resolution` (units: mils = 10⁻³ inch).[^5]

### v2 Descriptor (index #200, 18–32 bytes)

| Byte offset | Size | Field | Notes |
|-------------|------|-------|-------|
| 0 | 1 | `bLength` | Total length (18–32) |
| 1 | 1 | `bDescriptorType` | 0x03 |
| 2–4 | LE24 | `X_LM` | 24-bit logical maximum X |
| 5–7 | LE24 | `Y_LM` | 24-bit logical maximum Y |
| 8–9 | LE16 | `PRESSURE_LM` | Pressure logical maximum (e.g. 8191) |
| 10–11 | LE16 | `resolution` | lpi |
| 12–17 | 6 bytes | *(reserved/model-specific)* | Used to identify touch-ring models (see §8) |
| 18–31 | variable | *(optional extra)* | Present on some newer firmware versions |

The 24-bit LE fields use the `get_le24()` helper: `b | (b[^1] << 8) | (b[^2] << 16)`[^6].

**Touch-ring model identifier:** For the HS610, the kernel compares bytes 0–18 of the returned buffer against a known magic sequence to select between touch-ring and touch-strip frame descriptors:[^6]

```c
static const __u8 touch_ring_model_params_buf[] = {
    0x13, 0x03, 0x70, 0xC6, 0x00, 0x06, 0x7C, 0x00,
    0xFF, 0x1F, 0xD8, 0x13, 0x03, 0x0D, 0x10, 0x01,
    0x04, 0x3C, 0x3E
};
```

***

## 6. HID Report Descriptor Templates

The driver *replaces* the device's native report descriptor with a synthesised one built from templates populated with the probed parameters. Key report IDs:[^6]

| Constant | Value | Purpose |
|----------|-------|---------|
| `UCLOGIC_RDESC_V1_PEN_ID` | `0x07` | v1 pen reports |
| `UCLOGIC_RDESC_V2_PEN_ID` | `0x08` | v2 pen reports |
| `UCLOGIC_RDESC_V1_FRAME_ID` | `0xF7` | v1 frame/button reports |
| `UCLOGIC_RDESC_V2_FRAME_BUTTONS_ID` | `0xF7` | v2 frame button sub-reports |
| `UCLOGIC_RDESC_V2_FRAME_TOUCH_ID` | `0xF8` | v2 touch ring/strip reports |
| `UCLOGIC_RDESC_V2_FRAME_DIAL_ID` | `0xF9` | v2 rotary dial reports |

### v1 Pen Report Descriptor Summary

- Usage Page: Digitizer (`0x0D`), Usage: Pen (`0x02`)
- Report Size: 1-bit fields for buttons + 16-bit X, 16-bit Y, 16-bit pressure
- Buttons declared: Tip Switch (`0x42`), Barrel Switch (`0x44`), Eraser/Tablet Pick (`0x46`), In Range (`0x32`)
- In-range polarity: **inverted** — bit 6 of byte 1 is `1` when *out of range*[^5][^6]

### v2 Pen Report Descriptor Summary

- X and Y declared as **24-bit** fields (`Report Size (24)`)
- Pressure declared as **16-bit**
- Tilt: X tilt (`0x3D`) and Y tilt (`0x3E`), each signed 8-bit, physical range −60° to +60°
- In-range polarity: **none** — the driver synthesises in-range by setting bit 6 and arming a 100 ms timeout timer[^7][^6]
- Y tilt direction: **flipped** in hardware — the driver negates `data[^11]`[^6]

***

## 7. Input Report Byte Maps

All pen reports start with a 1-byte HID Report ID (`data`).

### v1 Pen Report (8 bytes, Report ID `0x07`)

```
Byte  Bits   Field
          Report ID = 0x07
[^1]      Tip Switch (pen touching surface)
[^1]   [^1]    Barrel Switch 1 (lower pen button)
[^1]   [^2]    Barrel Switch 2 (upper pen button / eraser side button)
[^1]   [^6]    In-Range (INVERTED: 1 = out of range, 0 = in range)
[2–3] LE16   X coordinate (logical, 0 to X_LM)
[4–5] LE16   Y coordinate (logical, 0 to Y_LM)
[6–7] LE16   Tip Pressure (0 to PRESSURE_LM)
```

In-range inversion is corrected by XOR-ing `data[^1]` with `0x40` before passing the report to the HID subsystem.[^7]

### v2 Pen Report — Wire Format (12 bytes, Report ID `0x08`)

The raw wire packet from the hardware is *not* the final report seen by HID. The kernel performs a byte rearrangement before the HID core processes it:

```
Wire packet (before rearrangement):
Byte  Field
   Report ID = 0x08
[^1]   Button/status flags (see below)
[2–3] X low 16 bits (LE16)
[4–5] Y low 16 bits (LE16)
[^6]   Pressure low byte
[^7]   Pressure high byte
[^8]   X high byte (bit 0 = X bit 16)
[^9]   Y high byte (bit 0 = Y bit 16) — present in fragmented_hires2
[^10]  X tilt (signed 8-bit, degrees, −60 to +60)
[^11]  Y tilt (signed 8-bit, degrees, −60 to +60) — negated by driver
```

**After rearrangement** (`fragmented_hires = true`) the driver rewrites the buffer in-place so the HID descriptor's 24-bit X and 16-bit pressure fields align correctly:[^7]

```c
pressure_low  = data[^6];
pressure_high = data[^7];
data[^6] = data[^5];       // Y byte 1 → offset 6
data[^5] = data[^4];       // Y byte 0 → offset 5
data[^4] = data[^8];       // X high byte → offset 4
data[^7] = data[^9];       // Y high byte → offset 7
data[^8] = pressure_low;
data[^9] = pressure_high;
```

Post-rearrangement layout consumed by HID:

```
[2–4]  X (24-bit LE, logical 0 to X_LM)
[5–7]  Y (24-bit LE, logical 0 to Y_LM)
[8–9]  Pressure (16-bit LE, 0 to PRESSURE_LM)
[^10]   X tilt (signed 8-bit)
[^11]   Y tilt (signed 8-bit, already negated)
```

**OpenTabletDriver `GianoReport` byte map** (no kernel rearrangement; OTD reads the wire packet directly):[^4]

```csharp
Position.X = LE16(report[^2]) | ((report[^8] & 1) << 16);
Position.Y = LE16(report[^4]);          // Y high byte in report[^9] but OTD ignores it
Pressure   = LE16(report[^6]);
Tilt.X     = (sbyte)report[^10];
Tilt.Y     = (sbyte)report[^11];
PenButton1 = report[^1].bit(1);
PenButton2 = report[^1].bit(2);
```

### v1 Pen Report Status Byte (byte 1) Bit Assignments

| Bit | Meaning |
|-----|---------|
| 0 | Tip Switch (touch) |
| 1 | Barrel Switch 1 (lower pen button) |
| 2 | Barrel Switch 2 (upper pen button) |
| 3–5 | Reserved / Constant |
| 6 | In-Range (inverted on v1; emulated on v2) |
| 7 | Reserved |

### v2 Pen Report Status Byte (byte 1) Special Values

| Value | Meaning |
|-------|---------|
| `0xE0` | Frame/button sub-report (redirect to Aux report ID `0xF7`) |
| `0xF0` | Touch ring/strip data (redirect to frame ID `0xF8`) |
| `0xF1` | Rotary dial data (redirect to frame ID `0xF9`) |
| bit 5 + bit 6 set simultaneously | GianoReportParser: treat as UCLogicAuxReport |
| `0x00` | Pen out-of-range (OutOfRangeReport) |

The kernel checks `data[^1] & pen_frame_flag` (flag = `0x20`, i.e. bit 5) to detect embedded frame control reports and rewrites `data` to the appropriate frame report ID.[^7]

***

## 8. Frame / Auxiliary Controls

### v1 Frame Report (Report ID `0xF7`, 8 bytes)

Triggered when byte 1 of the pen report equals `0xE0`:[^7]

```
[^4]   bits 0–7  Buttons 1–8
[^5]   bits 0–7  Buttons 9–16
[^6]   bits 0–3  Buttons 17–20
```

Up to 20 hardware buttons are decoded from bytes 4–6.[^4]

### v2 Frame Button Report (Report ID `0xF7`)

Same bit layout as v1 frame; linked via sub-report value `0xE0`.[^6]

### v2 Touch Ring/Strip Report (Report ID `0xF8`)

| Field | Location | Notes |
|-------|----------|-------|
| Touch value | `data[^5]` | 1–`touch_max`; 0 = finger lifted |
| Device ID | `data[^4]` | Set to `0x0F` when active, 0 when finger lifted |
| Ring max | 12 (HS610 touch ring) or 8 (strip models) | |
| Flip anchor | 7 (ring) or none (strip) | For reversing the reported direction |

Touch-ring value is optionally flipped: `value = (flip_at * 2) - value` when the reversed direction is needed, wrapping around `touch_max`.[^6]

### v2 Rotary Dial Report (Report ID `0xF9`)

- State stored at `frame.bitmap_dial_byte = 5`
- Bitmap encoding: bit 0 = clockwise (+1), bit 1 = counter-clockwise (−1) — differs from the Gray-coded dial used on other vendors[^7]
- A second bitmap dial destination byte is supported for tablets with dual dials

### Gray-Coded Dial (older models, v1 frame)

The driver decodes a 2-bit Gray code from `data[re_lsb/8]` and emits a 2-bit signed change (`+1` or `−1`) for each state transition. Gray state → change mapping:[^7]

```
prev=1, state=0  →  +1 (clockwise)
prev=2, state=3  →  +1
prev=2, state=0  →  -1 (counterclockwise, encoded as 0x03 = -1 in 2-bit signed)
prev=1, state=3  →  -1
```

***

## 9. Report Parsers Reference

OpenTabletDriver uses the following parser classes:[^4]

| Parser Class | When Used | Key Behavior |
|-------------|-----------|--------------|
| `TabletReport` | Legacy v1 (no tilt) | X=LE16[^8], Y=LE16[^9], P=LE16[^10], Buttons=byte1 bits 1–3 |
| `TiltTabletReport` | UCLogic v2 with tilt | Adds Tilt.X=(sbyte)[^11], Tilt.Y=(sbyte)[^12] |
| `UCLogicReportParser` | v1 or older v2 | Routes byte1 bit 6 set → UCLogicAuxReport, else TabletReport |
| `UCLogicTiltReportParser` | v2 with tilt | Routes byte1 bit 6 set → UCLogicAuxReport, else TiltTabletReport |
| `UCLogicV1ReportParser` | v1 explicit | byte1=0xE0 → AuxReport; bit6 set → TabletReport; else OutOfRange |
| `UCLogicV2ReportParser` | v2 generic | 0xE0 → Aux; 0xF0 → DeviceReport (wheel, ignored); else TiltTabletReport |
| `GianoReportParser` | Giano/Kamvas v2 | bits 5+6 both set → UCLogicAuxReport; else GianoReport (custom decoder) |
| `InspiroyReportParser` | Inspiroy 2 series | 0xE0 → Aux; 0xE3 → group buttons (Aux); 0xF1 → wheel (ignored); 0x00 → OOR; bit7 set → Tilt |

***

## 10. Device Model Table

All models confirmed in the OpenTabletDriver configuration repository as of May 2026. VID is `0x256C` for all entries.[^4]

| Model | PID | Report Len | Parser | Max Pressure | Active Area | MaxX × MaxY | Pen Btns | Aux Btns | Firmware Regex |
|-------|-----|-----------|--------|-------------|-------------|-------------|---------|---------|---------------|
| **Inspiroy Series** | | | | | | | | | |
| H420 | 0x006E | 8 | UCLogicReportParser | 2047 | 101.6×57.0 mm | 8340×4680 | 2 | 3 | *(none — v1)* |
| H690 | 0x006E | 8 | UCLogicReportParser | 2047 | 228.6×142.9 mm | 36000×22500 | 2 | 3 | *(none — v1)* |
| H420X | 0x006D | 12 | UCLogicReportParser | 8191 | 106×66 mm | 21200×13200 | 2 | 0 | T210 |
| H430P | 0x006D | 12 | UCLogicReportParser | 4095 | 121.9×76.2 mm | 24384×15240 | 2 | 4 | T176\|T18a\|T21c |
| H580X | 0x0064 | 12 | UCLogicTiltReportParser | 8191 | 203.2×127 mm | 40640×25400 | 2 | 8 | T211\|T224 |
| H610 Pro | 0x006D | 12 | UCLogicReportParser | 8191 | 254×158.8 mm | 50800×31750 | 2 | 8 | T175 |
| H610 Pro V2 | 0x006D | 12 | UCLogicTiltReportParser | 8191 | 254×158.8 mm | 50800×31750 | 2 | 8 | T184 |
| H610X | 0x0064 | 12 | UCLogicTiltReportParser | 8191 | 254×158.8 mm | 50800×31760 | 2 | 8 | T212\|T229 |
| H640P | 0x006D | 12 | UCLogicTiltReportParser | 8191 | 160×100 mm | 32000×20000 | 2 | 6 | T173 |
| H641P | 0x0066 | 12 | UCLogicTiltReportParser | 8191 | 160×100 mm | 32000×20000 | 2 | 6 | T21j |
| H642 | 0x006D | 12 | UCLogicTiltReportParser | 8191 | 160×99.1 mm | 32004×19812 | 2 | 6 | T19g |
| H950P | 0x0064 | 12 | UCLogicTiltReportParser | 8191 | 221×138 mm | 44200×27600 | 2 | 8 | T22d |
| H951P | 0x0067 | 12 | InspiroyReportParser | 8191 | 221×138 mm | 44200×27600 | 2 | 11 | T21k |
| H1060P | 0x006D | 12 | UCLogicTiltReportParser | 8191 | 254×158.8 mm | 50800×31750 | 2 | 12 | T167\|T205 |
| H1061P | 0x0068 | 12 | UCLogicTiltReportParser | 8191 | 266.7×166.7 mm | 53340×33340 | 2 | 11 | T21m |
| H1161 | 0x006D | 12 | UCLogicTiltReportParser | 8191 | 279.4×174.6 mm | 55880×34925 | 2 | 10 | T191 |
| H320M | 0x006D | 12 | UCLogicTiltReportParser | 8191 | 228.5×142.9 mm | 45700×28580 | 2 | 11 | T198 |
| HS64 | 0x006D | 12 | UCLogicReportParser | 8191 | 160×102 mm | 32000×20400 | 2 | 4 | T181\|T193 |
| HS95 | 0x006D | 12 | UCLogicTiltReportParser | 8191 | 203.2×127 mm | 40638×25398 | 2 | 6 | T206 |
| HS610 | 0x006D/0x0064 | 12 | UCLogicTiltReportParser | 8191 | 254×158.8 mm | 50800×31750 | 2 | 12 | T194 |
| HS611 | 0x006D | 12 | UCLogicTiltReportParser | 8191 | 258.4×161.5 mm | 51680×32300 | 2 | 10 | T19c |
| HC16 | 0x006D/0x0064 | 12 | UCLogicTiltReportParser | 8191 | 254×158.8 mm | 50800×31750 | 2 | 12 | T18C |
| **Inspiroy Q/G Series** | | | | | | | | | |
| Q11K | 0x006D | 12 | UCLogicReportParser | 8191 | 279.4×174.6 mm | 55880×34925 | 2 | 8 | T164 |
| Q11K V2 | 0x006E | 12 | UCLogicTiltReportParser | 8191 | 279.4×174.6 mm | 55880×34925 | 2 | 8 | T185 |
| Q620M | 0x006D | 12 | GianoReportParser | 8191 | 266.7×165.1 mm | 53340×33020 | 2 | 8 | T18d |
| Q630M | 0x0060 | 12 | GianoReportParser | 8191 | 266.7×166.7 mm | 53340×33340 | 2 | 6 | T216 |
| G10T | 0x006E | 12 | UCLogicReportParser | 8191 | 254×158.8 mm | 50800×31750 | 2 | 6 | T161 |
| G930L | 0x0061 | 12 | GianoReportParser | 8191 | 345.4×215.9 mm | 69088×43180 | 2 | 6 | T209 |
| GC610 | 0x006E | 12 | UCLogicReportParser | 8191 | 254×158.8 mm | 50800×31750 | 2 | 6 | T166 |
| **Wireless** | | | | | | | | | |
| WH1409 | 0x006E | 12 | GianoReportParser | 8191 | 350×218 mm | 70000×43600 | 2 | 12 | T153 |
| WH1409 V2 | 0x006E | 12 | GianoReportParser | 8191 | 350×218 mm | 70000×43600 | 2 | 12 | T188 |
| **RTM/RTP/RDS/RTE Series** | | | | | | | | | |
| RTE-100 | 0x0064 | 12 | UCLogicReportParser | 8191 | 121.9×76.2 mm | 24384×15238 | 2 | 4 | T217 |
| RTM 500 | 0x006D | 12 | UCLogicTiltReportParser | 8191 | 221×138 mm | 44199×27599 | 2 | 4 | T19h |
| RTP-700 | 0x006D | 12 | UCLogicTiltReportParser | 8191 | 279.4×174.6 mm | 55880×34920 | 2 | 6 | T19k |
| RDS-160 | 0x006D | 12 | GianoReportParser | 8191 | 344.2×193.6 mm | 68840×38720 | 2 | 10 | M211 |
| **Kamvas Pen Displays** | | | | | | | | | |
| Kamvas 12 | 0x006D | 12 | GianoReportParser | 8191 | 267.9×168.2 mm | 53580×33640 | 2 | 8 | M19p |
| Kamvas 13 | 0x006D | 12 | UCLogicTiltReportParser | 8191 | 293.8×165.2 mm | 58752×33048 | 2 | 10 | M20h\|M19f\|M215 |
| Kamvas 13 Gen 3 | **0x2008** | **14** | UCLogicTiltReportParser | **16383** | 293.8×165.2 mm | 58760×33040 | **3** | 7 | M22c |
| Kamvas 16 | 0x006D | 12 | GianoReportParser | 8191 | 344.2×193.6 mm | 68840×38720 | 2 | 10 | M18e |
| Kamvas 16 (2021) | 0x006D | 12 | GianoReportParser | 8191 | 344.2×193.6 mm | 68840×38720 | 2 | 10 | M19s |
| Kamvas 20 | 0x006E | 12 | GianoReportParser | 8191 | 434.8×238.8 mm | 86950×47750 | 2 | 0 | M192\|M189 |
| Kamvas 22 | 0x006D | 12 | GianoReportParser | 8191 | 476.8×268.2 mm | 95352×53645 | 2 | 0 | M19g |
| Kamvas 22 Plus | 0x006D | 12 | GianoReportParser | 8191 | 476.6×268.1 mm | 95328×53622 | 2 | 0 | M19t |
| Kamvas 24 Plus | 0x006D | 12 | GianoReportParser | 8191 | 526.9×296.4 mm | 105370×59270 | 2 | 0 | M205 |
| Kamvas Pro 12 | 0x006E | 12 | GianoReportParser | 8191 | 267.9×168.2 mm | 53580×33640 | 2 | 4 | M171 |
| Kamvas Pro 13 | 0x006D | 12 | UCLogicTiltReportParser | 8191 | 293.8×165.2 mm | 58752×33048 | 2 | 4 | M182 |
| Kamvas Pro 13 (2.5K) | 0x006D | 12 | UCLogicTiltReportParser | 8191 | 286.5×179 mm | 57293×35808 | 2 | 7 | M210\|M213 |
| Kamvas Pro 16 | 0x006D | 12 | GianoReportParser | 8191 | 344.2×193.6 mm | 68840×38720 | 2 | 6 | M183 |
| Kamvas Pro 16 (2.5K) | 0x006D | 12 | GianoReportParser | 8191 | 349.6×196.7 mm | 69926×39333 | 2 | 8 | M214 |
| Kamvas Pro 16 (4K) | 0x006D | 12 | GianoReportParser | 8191 | 344.2×193.6 mm | 68840×38720 | 2 | 0 | M202 |
| Kamvas Pro 16 Plus (4K) | 0x006D | 12 | GianoReportParser | 8191 | 344.2×193.6 mm | 68840×38720 | 2 | 0 | M20a |
| Kamvas Pro 19 (4K) | 0x006B | **14** | GianoReportParser | **16383** | 409×230 mm | 81792×46006 | 2 | 0 | M220 |
| Kamvas Pro 20 | 0x006E | 12 | GianoReportParser | 8191 | 435.4×238.8 mm | 87075×47750 | 2 | 16 | M193 |
| Kamvas Pro 22 (2019) | 0x006E | 12 | GianoReportParser | 8191 | 476.8×268.2 mm | 95350×53644 | 2 | 20 | M194 |
| Kamvas Pro 24 | 0x006E | 12 | GianoReportParser | 8191 | 526.9×296.2 mm | 105379×59236 | 2 | 20 | M184 |
| Kamvas Pro 24 (4K) | 0x006D | 12 | GianoReportParser | 8191 | 527×296.5 mm | 105370×59270 | 2 | 0 | M207 |
| **Legacy pen displays** | | | | | | | | | |
| GT-156HD V2 | 0x006E | 12 | GianoReportParser | 8191 | 343.9×193.6 mm | 68780×38710 | 2 | 14 | M174 |
| GT-220 V2 | 0x006E | 12 | GianoReportParser | 8191 | 476.7×268.1 mm | 95336×53629 | 2 | 0 | M165 |
| GT-221 | 0x006E | 12 | GianoReportParser | 8191 | 476.7×268.2 mm | 95346×53641 | 2 | 10 | M175 |
| GT-221 Pro | 0x006E | 12 | GianoReportParser | 8191 | 476.7×268.2 mm | 95346×53641 | 2 | 10 | M167 |

***

## 11. Coordinate System

- **Origin:** Top-left corner of the active area
- **X axis:** Increases left → right
- **Y axis:** Increases top → bottom
- **Physical units:** Logical values map to physical mm via: `mm = logical_value × active_area_mm / MaxXY`
- **Resolution formula (v1/v2):** `X_PM (mils) = X_LM × 1000 / resolution_lpi`
- **Coordinate scaling example:** Kamvas Pro 16 active area 344.2×193.6 mm at MaxX=68840 → resolution = 200 lpi (68840/344.2 ≈ 200 lpi)

***

## 12. Pressure Levels

| Generation | MaxPressure | Bit depth | Notes |
|-----------|-------------|-----------|-------|
| v0 legacy | 1023 | 10-bit | WP4030U-era |
| v1 old | 2047 | 11-bit | H420, H690, 1060 Plus legacy |
| v1/v2 current | 4095 | 12-bit | H430P |
| v2 standard | 8191 | 13-bit | Most current models |
| v2 Gen 3 | 16383 | 14-bit | Kamvas 13 Gen 3, Kamvas Pro 19 (4K) |

***

## 13. Tilt Reporting

- Available on: all v2 models using `UCLogicTiltReportParser`, `GianoReportParser`, or `InspiroyReportParser`
- Range: −60° to +60° on both axes
- Encoding: signed 8-bit integer (`sbyte`), direct degree value
- Y-axis direction: **hardware sends inverted sign**; kernel negates `data[^11]` before exposing to userspace[^6]
- Report bytes: `data[^10]` = X tilt, `data[^11]` = Y tilt (post-rearrangement offsets for kernel; OTD reads same offsets from wire packet)

***

## 14. Gen 3 / 14-byte Reports

The Kamvas 13 Gen 3 (`0x2008`) and Kamvas Pro 19 (4K) (`0x006B`) use a 14-byte report. The extra 2 bytes extend the coordinate or pressure resolution. Both use `fragmented_hires2 = true` in the kernel, which performs a different byte rearrangement:[^6]

```c
// fragmented_hires2 — moves bytes 10–11 (X LSB extension) into X coordinate
lsb_low  = data[^10];
lsb_high = data[^11];
data[^11] = data[^9];
data[^10] = data[^8];
data[^9]  = data[^7];
data[^8]  = data[^6];
data[^7]  = data[^5];
data[^6]  = data[^4];
data[^4]  = lsb_low;
data[^5]  = lsb_high;
```

***

## 15. Firmware Version String Format

String descriptor #201 returns UTF-16LE ASCII, e.g.:

```
HUION_T194_210628
       ^^^^  ^^^^^^
       model  YYMMDD (firmware date)
```

- Prefix: `HUION_`
- Model code: 4-character alphanumeric code (e.g. `T194`, `M183`, `M22c`)
- Suffix: `_` + 6-digit date `YYMMDD`
- OpenTabletDriver matches this with a regex such as `HUION_T194_\d{6}$`[^4]
- The model code uniquely identifies the hardware SKU regardless of PID collisions

***

## 16. MCU / Hardware Notes

One confirmed instance of the underlying silicon (HS610): **GigaDevice GD32F350C8T6** — an ARM Cortex-M4 derivative with DFU bootloader at VID/PID `0x28E9:0x0189`. The DFU bootloader version is `1.1a` (DfuSe variant). Firmware update mode is triggered by holding buttons 1 and 5 during plug-in. This is not required for normal driver operation.[^13]

***

## 17. udev / libinput Integration

- The `libinputoverride: "1"` attribute in OpenTabletDriver configurations suppresses libinput from also claiming the device[^4]
- Set `SUBSYSTEM=="hidraw", ATTRS{idVendor}=="256c", MODE="0660", GROUP="input"` for user-space hidraw access
- For HID eBPF programs (the recommended modern approach), use `huion-switcher` to place the device into vendor reporting mode before the eBPF program attaches[^3]
- `huion-switcher --all` switches all connected `0x256C` devices; note this also affects Gaomon devices sharing the VID[^3]

***

## 18. Known Gaps and Caveats

| Issue | Detail |
|-------|--------|
| PID collisions | `0x006D` and `0x006E` each cover dozens of distinct models; firmware string #201 is the only reliable discriminator |
| Wireless protocol | WH1409 and G930L enumerate as USB HID when connected via the USB dongle; the wireless RF protocol itself has not been published |
| Bluetooth | No known open documentation for Bluetooth Huion tablets |
| Gen 3 full report map | The 14-byte report layout for Kamvas 13 Gen 3 / Kamvas Pro 19 is partially documented; the extra 2 bytes have not been exhaustively decoded in public sources |
| Express Key Remote | The HC16 remote device (`0x006D`, firmware `T18C`) works via UCLogicTiltReportParser but its secondary dial encoding is not separately documented |
| Touch input | Some Kamvas Pro pen displays include a capacitive touch panel; its HID collection is unrelated to the digitizer and is not covered by `hid-uclogic` |
| Vendor mode (eBPF path) | `huion-switcher` puts hardware into a *different* reporting mode suitable for HID eBPF programs; the vendor-mode report format is not identical to the standard mode format described here |

***

## 19. Key Source References

| Source | URL |
|--------|-----|
| Linux kernel `hid-uclogic-params.c` | https://github.com/torvalds/linux/blob/master/drivers/hid/hid-uclogic-params.c |
| Linux kernel `hid-uclogic-rdesc.c` | https://github.com/torvalds/linux/blob/master/drivers/hid/hid-uclogic-rdesc.c |
| Linux kernel `hid-uclogic-params.h` | https://github.com/torvalds/linux/blob/master/drivers/hid/hid-uclogic-params.h |
| Linux kernel `hid-uclogic-core.c` | https://github.com/torvalds/linux/blob/master/drivers/hid/hid-uclogic-core.c |
| DIGImend Huion fork | https://github.com/Huion-Linux/DIGImend-kernel-drivers-for-Huion |
| OpenTabletDriver configurations | https://github.com/OpenTabletDriver/OpenTabletDriver/tree/master/OpenTabletDriver.Configurations/Configurations/Huion |
| OpenTabletDriver parsers | https://github.com/OpenTabletDriver/OpenTabletDriver/tree/master/OpenTabletDriver.Configurations/Parsers |
| OTD tablet config reference | https://opentabletdriver.net/Wiki/Development/Configurations |
| huion-switcher (vendor mode) | https://github.com/whot/huion-switcher |
| HS610 hardware teardown notes | https://github.com/Lucretia/hs610-info |

---

## References

1. [Huion-Linux/DIGImend-kernel-drivers-for-Huion: This is a ... - GitHub](https://github.com/Huion-Linux/DIGImend-kernel-drivers-for-Huion) - This is a collection of huion graphics tablet drivers for the Linux kernel, produced and maintained ...

2. [System showed 256c:006d as the ID pair for Huion H950p · ...](https://github.com/DIGImend/digimend-kernel-drivers/issues/427) - Hello, Revised the question after I read and dug a little more. My tablet Huion H950p. VID:PID suppo...

3. [switch Huion tablets to vendor reporting mode | Man Page - ManKier](https://www.mankier.com/1/huion-switcher) - In vendor mode the device uses a HID vendor collection to report input data in a more precise and de...

4. [Tablet Support | OpenTabletDriver/OpenTabletDriver | DeepWiki](https://deepwiki.com/OpenTabletDriver/OpenTabletDriver/3-tablet-support) - This page provides an overview of how OpenTabletDriver supports diverse tablet hardware through conf...

5. [[PATCH v2 2/6] HID: uclogic: merge hid-huion driver in hid-uclogic](https://lkml.iu.edu/hypermail/linux/kernel/1502.3/02365.html)

6. [[PATCH 1/7] HID: uclogic: Support Huion tilt reporting](https://lkml.indiana.edu/hypermail/linux/kernel/2202.1/04264.html)

7. [DIGImend-kernel-drivers-for-Huion/hid-uclogic-params.c at master · Huion-Linux/DIGImend-kernel-drivers-for-Huion](https://github.com/Huion-Linux/DIGImend-kernel-drivers-for-Huion/blob/master/hid-uclogic-params.c) - This is a collection of huion graphics tablet drivers for the Linux kernel, produced and maintained ...

8. [Open source, cross-platform, user-mode tablet driver](https://github.com/OpenTabletDriver/OpenTabletDriver) - Open source, cross-platform, user-mode tablet driver - OpenTabletDriver/OpenTabletDriver

9. [HELP! Huion gt-191 pen display tablet, not getting it to work ... - GitHub](https://github.com/DIGImend/digimend-kernel-drivers/issues/78) - Hello everyone, I have recently bought the huion kamvas gt-191 graphic pen display tablet. Not too l...

10. [Device Descriptor Request Failed kamvas pro 13 - Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/4043233/device-descriptor-request-failed-kamvas-pro-13) - Hello, im having a problem with my Huion Kamvas Pro 13. I try to connect it the USB to my PC but it ...

11. [Attempting to reverse engineer the Surface Pro 4 Digitizer, need ...](https://www.reddit.com/r/SurfaceLinux/comments/1aiwcnf/attempting_to_reverse_engineer_the_surface_pro_4/) - What I am looking for is info about the I2C and SPI protocols. I know that they have been reverse en...

12. [OpenTabletDriver](https://opentabletdriver.net)

13. [GitHub - Lucretia/hs610-info: Information on HUION's HS610 tablet](https://github.com/Lucretia/hs610-info) - Information on HUION's HS610 tablet. Contribute to Lucretia/hs610-info development by creating an ac...

