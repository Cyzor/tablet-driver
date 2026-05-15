2026-03-25

This technical report synthesizes Wacom protocol specifications from the Linux Wacom Project kernel driver source, OpenTabletDriver configuration schema, and the `wacom_wac.c`/`wacom_wac.h` kernel files. All data below derives from those open sources.

***

# Wacom macOS Reverse-Engineered Driver: Technical Specification

## 1. Scope and Objectives

This document specifies the low-level communication protocol, USB identification data, HID initialization sequences, packet formats, and macOS driver architecture needed to build a user-mode or DriverKit-based driver for aging Wacom USB drawing tablets on macOS. The target models span Graphire through Intuos5/Cintiq generations — tablets that Wacom's official macOS driver no longer supports.[^1]

The design mirrors OpenTabletDriver's user-mode philosophy: avoid kernel extensions (KEXTs), consume raw HID reports directly, and inject pointer/tablet events through the OS abstraction layer.[^2]

***

## 2. macOS Driver Architecture

### 2.1 Stack Selection

Modern macOS (12+) deprecates KEXTs in favor of DriverKit System Extensions. Three viable implementation layers exist:


| Layer | API | Privilege | Use Case |
| :-- | :-- | :-- | :-- |
| User daemon | `IOHIDManager` (IOKit) | User | Simplest; reads HID events after device attach |
| User daemon | `IOUSBHostInterface` (IOKit) | User (with entitlement) | Raw USB access; needed to send mode-switch feature reports |
| DriverKit extension | `IOUSBHostInterface` + `HIDDriverKit` | SIP-exempt | Proper driver lifecycle; survives sleep/wake |

For aging tablets, a **user-space daemon using `IOUSBHostInterface`** is the most practical path. It can claim the USB device before macOS's generic HID stack does (via `IOUSBDevice::USBDeviceOpenSeize`), issue the mode-switch initialization report, then read from the interrupt-in endpoint.[^1]

### 2.2 Initialization Sequence (All USB Models)

All Wacom USB tablets connect initially as HID-compliant devices. The driver must immediately switch them to **Wacom Mode 2** (vendor-specific protocol), which unlocks pressure, tilt, Z-rotation, and tool proximity data:[^1]

```
1. Match device by VID=0x056A and PID (see §6).
2. Open USB device interface (IOUSBDeviceInterface).
3. Claim interface 0.
4. Send USB SET_REPORT (HID feature report) to switch mode:
     bmRequestType = 0x21  (Host→Device, Class, Interface)
     bRequest      = 0x09  (SET_REPORT)
     wValue        = 0x0300 | <report_id>
     wIndex        = 0x0000
     Data          = model-specific (see §5 below)
5. Open interrupt-IN endpoint (bEndpointAddress = 0x81).
6. Read 8–64 byte packets in a loop (transfer size = model's PKGLEN).
7. Parse each packet per device family protocol (see §4).
8. Inject events via CGEventCreate / HIDUserDevice.
```

macOS will not automatically yield the device to a custom daemon — the daemon must open the USB device with `kIOUSBDeviceInterfaceID` and call `USBDeviceOpenSeize` before `IOHIDManager` initializes.[^2][^1]

### 2.3 Event Injection

Use `IOHIDUserDevice` (via the `HIDDriverKit` framework or the user-space `IOKit` C API) to create a virtual HID device that presents a standard digitizer/tablet HID descriptor. Map parsed tablet data onto:

- `kHIDPage_GenericDesktop` / `kHIDUsage_GD_X`, `_Y` — absolute coordinates
- `kHIDPage_Digitizer` / `kHIDUsage_Dig_TipPressure` — pressure
- `kHIDPage_Digitizer` / `kHIDUsage_Dig_XTilt`, `_YTilt` — tilt axes
- `kHIDPage_Button` — pen tip, eraser, barrel buttons

***

## 3. USB Identification

All Wacom tablets share **Vendor ID `0x056A`** (Wacom Co., Ltd).  Product IDs are listed in §6. Every identifier also requires a known **Input Report Length** (packet size in bytes) because report parsers expect a fixed-length buffer.[^3][^4][^5]

***

## 4. Protocol Families

Wacom uses three distinct protocol generations across the aging product range.[^1]

### 4.1 Protocol IV — Graphire, Volito, early Bamboo

**Packet length:** 8 bytes (PKGLEN\_GRAPHIRE = 8)[^5]

All multi-byte coordinate values are **little-endian**.

```
Byte  Bits  Field
────────────────────────────────────────────────────────
 0    [7:0]  Report ID (always 0x02 in Wacom mode)
 1    [^7]    Proximity flag  (1 = tool in range)
             [6:5]  Tool type: 00=pen, 01=rubber, 10=cursor/mouse
             [^4]    Reserved
             [^3]    Barrel button 2 (upper side switch)
             [^2]    Barrel button 1 (lower side switch)
             [^1]    Eraser tip / cursor button 3
             [^0]    Pen tip switch
 2    [7:0]  X coordinate, low byte
 3    [7:0]  X coordinate, high byte   → X = uint16 LE
 4    [7:0]  Y coordinate, low byte
 5    [7:0]  Y coordinate, high byte   → Y = uint16 LE
 6    [7:0]  Pressure, low 8 bits
 7    [1:0]  Pressure, high 2 bits     → Pressure = 10-bit (0–1023)
             [7:4]  Scroll wheel delta (cursor/mouse tool)
```

**Coordinate ranges:**

- Graphire (ET-0405-U): MaxX=5103, MaxY=3711
- Graphire2 4x5 (ET-0405A-U): MaxX=5103, MaxY=3711
- Graphire3 4x5 (CTE-430): MaxX=10208, MaxY=7424
- Graphire3 6x8 (CTE-440): MaxX=16704, MaxY=12064
- Graphire4 4x5 (CTE-430): MaxX=10208, MaxY=7424

**Pen max pressure:** 511 (Graphire/Graphire2), 1023 (Graphire3/4), 511 (Volito).

**No tilt data** on Protocol IV devices.

**Auxiliary buttons** (express keys on pad): reported on Report ID `0x03`, byte 1 bitmask. CTE-430/440/630: 4 buttons.[^6]

***

### 4.2 Protocol V — Intuos I and Intuos II

**Packet length:** 10 bytes (PKGLEN\_INTUOS = 10)[^7]

Intuos tablets report up to two simultaneous tools. Report IDs encode tool class:

```
Report ID  Tool
─────────────────────────
  0x02     Pen tip / general stylus
  0x03     Cursor / puck (4D mouse)
  0x0A     Airbrush
  0x0B     Airbrush (second tool)
  0x0C     Cursor (second tool)
  0x20     Proximity in/out event
  0x23     4D mouse / lens cursor
```

**10-byte packet layout:**

```
Byte  Bits  Field
────────────────────────────────────────────────────────────────
 0    [7:0]  Report ID (see table above)
 1    [^6]    Proximity (1 = in range)
             [5:4]  Reserved
             [^1]    Barrel button 1
             [^0]    Tip switch / barrel button 2
 2    [7:0]  X, bits [15:8]
 3    [7:0]  X, bits [7:0]   → X = 16-bit; actual range uses 24-bit
             (some sources: byte 2 bit[^0] carries X bit 16 → 0x1XXXX)
 4    [7:4]  X bits [19:16] (Intuos only; 0 on Intuos2 at this position)
             [3:0]  Y bits [19:16]
 5    [7:0]  Y, bits [15:8]
 6    [7:0]  Y, bits [7:0]
 7    [9:8]  Pressure, high 2 bits
 8    [7:0]  Pressure, low byte    → 10-bit pressure (0–1023)
 9    [6:0]  Tilt X (signed 7-bit, −63 to +63 degrees)
10*   [6:0]  Tilt Y (signed 7-bit)   *byte 10 in extended packets
```

> **Note:** Intuos uses a 20-bit coordinate space (MaxX≈20480, MaxY≈15360 for 9x12). Intuos2 shares the same packet format with identical sizing.

**Airbrush tool** (0x0A) replaces tilt bytes with wheel/fingerwheel position (10-bit).

**Cursor / 4D mouse** reports rotation (Z-axis, byte 9 full 8-bit) and 5 buttons.

**Proximity packet** (Report ID `0x20`) carries 8-byte serial number of the tool entering/leaving proximity, allowing multi-tool identification.

***

### 4.3 Protocol VI — Intuos3, Intuos4, Intuos5, Cintiq

**Packet lengths:**

- Intuos3: 9 bytes (PKGLEN\_INTUOS3 = 9)
- Intuos4/5: 10 bytes with extended pressure
- Cintiq 12WX/21UX: 10 bytes

**Intuos3 9-byte layout:**

```
Byte  Bits  Field
────────────────────────────────────────────────────────────────
 0    [7:0]  Report ID  (0x02 pen, 0x03 cursor, 0x0A airbrush)
 1    [^6]    Proximity
             [^2]    Barrel button 2 (upper)
             [^1]    Barrel button 1 (lower)
             [^0]    Tip / eraser
 2    [7:0]  X high byte
 3    [7:0]  X low byte
 4    [7:0]  Y high byte
 5    [7:0]  Y low byte
 6    [7:0]  Pressure, high byte (bits [11:8] in bits [3:0])
 7    [7:0]  Pressure, low byte  → 12-bit pressure (0–2047 for PTZ; 0–1023 mapped)
 8    [7:4]  Tilt X (signed 4-bit, −8 to +7 for legacy; 7-bit on newer)
             [3:0]  Tilt Y
```

Intuos3 coordinate ranges:

- PTZ-430 (4x5): MaxX=25400, MaxY=20320
- PTZ-630 (6x8): MaxX=40640, MaxY=30480
- PTZ-930 (9x12): MaxX=60960, MaxY=45720
- PTZ-1230 (12x12): MaxX=60960, MaxY=60960

**Intuos3 express keys:** reported as separate HID interface (interface 1), 8-byte report, bytes 1–2 as bitmask for 8 hardware keys + touch strip.

**Intuos4 (PTK series)** increases pen pressure to **2047 levels** and adds an OLED display on the side keys. The initialization sequence must additionally send an output report to configure OLED brightness (see §5).

**Intuos5/Pro** adds multi-touch on a second USB interface with touch report ID `0x02`, 6-byte touch records (up to 16 touches), and requires touch mode initialization.

***

## 5. Mode-Switch Initialization Reports

The mode-switch feature report is the critical "secret handshake." Without it, the tablet delivers only generic HID mouse data with no pressure.[^3][^1]

### 5.1 Standard Wacom Mode Switch

Applies to: all USB models except Bluetooth.

```c
// USB HID SET_REPORT (Feature), Report ID 2
uint8_t init_report[^2] = { 0x02, 0x02 };
// Send via USB control transfer:
// bmRequestType=0x21, bRequest=0x09, wValue=0x0302, wIndex=0x0000
```


### 5.2 Graphire4 / Volito2 Additional Initialization

After the standard mode switch, Graphire4 and Volito2 require a second feature report to enable full tablet mode:[^6]

```c
uint8_t init2[^9] = { 0x02, 0x02, 0x00, 0x00, 0x00,
                     0x00, 0x00, 0x00, 0x00 };
// Delay: 50 ms between reports (FeatureInitDelayMs = 50)
```


### 5.3 Bamboo CTL/CTH Touch Initialization

Bamboo Pen \& Touch models require touch mode to be explicitly enabled on interface 1:[^3]

```c
// Interface 0: pen, standard init
uint8_t pen_init[^12]   = { 0x02, 0x02, ... };
// Interface 1: touch, Report ID 0x03
uint8_t touch_init[^12] = { 0x03, 0x01, 0x00, ... };
```


### 5.4 Intuos4 OLED Display Report

```c
// Output report to configure side-key OLED (interface 0):
uint8_t oled_report[^9] = { 0x03, 0x00, 0x00, 0x00,
                            0x00, 0x00, 0x00, 0x00, 0x00 };
// FeatureInitDelayMs = 150 ms
```


### 5.5 HID_GENERIC Input Mode Initialization (PTH-660, PTH-860)

Devices using the `HID_GENERIC` driver path (PTH-660 PID 0x0357, PTH-860 PID 0x0358) do NOT use the `[0x02, 0x02]` feature report. Instead, the Linux driver calls `wacom_hid_set_device_mode()`:

1. During HID descriptor parsing (`feature_mapping`), the kernel finds the feature report field with usage `HID_DG_INPUTMODE` (HID digitizer Input Mode) and records its report ID.
2. A `SET_REPORT` (HID feature report) is sent on that report ID with the `InputMode` field value set to `2` (tablet mode).
3. If the descriptor instead exposes `WACOM_HID_WD_DATAMODE` (a Wacom vendor usage, page `0xFF00`), the driver sends a two-byte feature report `[report_id, 2]` with up to 3 retries.

**Without this init**, pressure and tilt still work for pen tools, but **cursor/mouse tool button state does not appear in reports**. The device is effectively in HID compatibility mode.

**To implement in MockTab:** after opening the device, read its HID report descriptor (`kIOHIDReportDescriptorKey`), parse the descriptor to find the feature report that contains `HID_DG_INPUTMODE` (usage `0x0D/0x29`) or a vendor datamode usage, then call:

```swift
var initBuf: [UInt8] = [reportID, 2]
IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature,
                     CFIndex(reportID), &initBuf, initBuf.count)
```

This is the blocking prerequisite for mouse button support on PTH-660/860.

***

## 6. Device Table by Model Series

All devices: VID = `0x056A`. All coordinate units are device-native. Physical dimensions in mm. Pressure max is the highest raw value reported before normalization to a percentage.

***

### 6.1 PenPartner Series

| Model | Name | PID | PKGLEN | MaxX | MaxY | Width mm | Height mm | Pressure Max | Buttons | Notes |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| CT-0405-U | PenPartner | 0x00 | 7 | 5040 | 3780 | 127 | 96 | 255 | 2 | Oldest USB Wacom; 8-bit pressure |
| CT-0405A-U | PenPartner 4x5 | 0x03 | 7 | 5040 | 3780 | 127 | 96 | 255 | 2 | Slight revision |

Protocol: Pre-Protocol-IV. 7-byte packet. X/Y little-endian 16-bit. Pressure 8-bit only (byte 6, no high bits). No tilt.

***

### 6.2 Graphire Series (ET-series)

| Model | Name | PID | PKGLEN | MaxX | MaxY | Width mm | Height mm | Pressure Max | Pad Buttons |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| ET-0405-U | Graphire | 0x10 | 8 | 5103 | 3711 | 127 | 96 | 511 | 0 |
| ET-0405A-U | Graphire2 4x5 | 0x11 | 8 | 5103 | 3711 | 127 | 96 | 511 | 0 |
| ET-0607A-U | Graphire2 6x8 | 0x12 | 8 | 7536 | 5659 | 158 | 128 | 511 | 0 |

**Pen packet (Graphire):** Report ID `0x01`. Proximity bit 7 of byte 1. Tip = byte 1 bit 0. Pressure = (byte7[1:0] << 8) \| byte6, 10-bit. No tilt. [^5]

**Cursor/mouse tool:** Reports on same packet format; bytes 6–7 carry wheel delta instead of pressure.

***

### 6.3 Graphire3 Series (CTE-series)

| Model | Name | PID | PKGLEN | MaxX | MaxY | Width mm | Height mm | Pressure Max | Pad Buttons |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| CTE-430 | Graphire3 4x5 | 0x13 | 8 | 10208 | 7424 | 127 | 97 | 511 | 4 |
| CTE-440 | Graphire3 6x8 | 0x14 | 8 | 16704 | 12064 | 200 | 150 | 511 | 4 |

Pad buttons report on Report ID `0x03`. Byte 1 bitmask: bits [3:0] = keys 1–4.[^6]

***

### 6.4 Graphire4 Series (CTE-series)

| Model | Name | PID | PKGLEN | MaxX | MaxY | Width mm | Height mm | Pressure Max | Pad Buttons |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| CTE-630 | Graphire4 4x5 | 0x15 | 8 | 10208 | 7424 | 127 | 97 | 511 | 4 |
| CTE-640 | Graphire4 6x8 | 0x16 | 8 | 16704 | 12064 | 200 | 150 | 511 | 4 |
| CTE-630BT | Graphire4 Bluetooth 6x8 | 0x81 | 8 | 16704 | 12064 | 200 | 150 | 511 | 4 |

> Graphire4 requires two-stage feature initialization (§5.2).[^6]

***

### 6.5 Volito / Bamboo Fun (First Gen)

| Model | Name | PID | PKGLEN | MaxX | MaxY | Pressure Max | Pad Buttons |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| CTF-420 | Volito | 0x60 | 8 | 5104 | 3712 | 511 | 0 |
| CTF-430 | Volito2 | 0x61 | 8 | 10208 | 7424 | 511 | 2 |
| CTE-450 | Bamboo Fun S (1st gen) | 0x46 | 8 | 14720 | 9200 | 511 | 4 |
| CTE-650 | Bamboo Fun M (1st gen) | 0x47 | 8 | 20480 | 12800 | 511 | 4 |


***

### 6.6 Bamboo (CTL/CTH series, 2nd and 3rd gen)

These tablets use an extended 10-byte report format and require touch initialization on a separate HID interface.[^8][^3]

**Pen packet (10 bytes):** Report ID `0x02`. Proximity = byte1 bit6. Tip = byte1 bit0. X = LE16 from bytes 2–3. Y = LE16 from bytes 4–5. Pressure = LE16 from bytes 6–7, 10-bit (max 1023).

**Touch packet (10 bytes on interface 1):** Report ID `0x01`. Up to 2 touch contacts. Each contact: 3 bytes (contact ID 1 bit, X 7-bit, Y 7-bit in packed form), scaled to touch MaxX/MaxY.


| Model | Name | PID | Pen PKGLEN | MaxX | MaxY | Touch MaxX | Touch MaxY | Pressure Max | Pad Buttons | Touch |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| CTL-460 | Bamboo Pen S | 0xD1 | 10 | 14720 | 9200 | — | — | 1023 | 4 | No |
| CTH-460 | Bamboo Pen \& Touch S | 0xD1 | 10 | 14720 | 9200 | 1024 | 1024 | 1023 | 4 | Yes |
| CTL-660 | Bamboo Pen M | 0xD2 | 10 | 21648 | 13530 | — | — | 1023 | 4 | No |
| CTH-661 | Bamboo Pen \& Touch M | 0xD3 | 10 | 21648 | 13530 | 1024 | 1024 | 1023 | 4 | Yes |
| CTH-460A | Bamboo Pen \& Touch S (rev) | 0xD4 | 10 | 14720 | 9200 | 1024 | 1024 | 1023 | 4 | Yes |
| CTL-471 | Bamboo Connect (Pen S) | 0xD6 | 10 | 14720 | 9200 | — | — | 1023 | 4 | No |
| CTH-471 | Bamboo Connect (P\&T) | 0xD7 | 10 | 14720 | 9200 | 1024 | 1024 | 1023 | 4 | Yes |
| CTH-680 | Bamboo Create | 0xD8 | 10 | 21648 | 13530 | 1024 | 1024 | 1023 | 4 | Yes |

> **CTH-460 "flipped endpoint" variant:** Some units enumerate with HID interface ordering inverted (pen on interface 1, touch on interface 0). Detect via `Interface` attribute in device matching; use `\"Interface\": \"1\"` for pen.[^8]

***

### 6.7 Intuos I (GD-series)

Protocol V, 10-byte packets, 20-bit coordinate space. 1024 pressure levels. Tilt ±63°.[^1]


| Model | Name | PID | PKGLEN | MaxX | MaxY | Width mm | Height mm | Pressure Max |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| GD-0405-U | Intuos 4x5 | 0x20 | 10 | 12700 | 10360 | 127 | 97 | 1023 |
| GD-0608-U | Intuos 6x8 | 0x21 | 10 | 20320 | 16002 | 203 | 152 | 1023 |
| GD-0912-U | Intuos 9x12 | 0x22 | 10 | 30480 | 24060 | 305 | 229 | 1023 |
| GD-1212-U | Intuos 12x12 | 0x23 | 10 | 30480 | 30480 | 305 | 305 | 1023 |
| GD-1218-U | Intuos 12x18 | 0x24 | 10 | 45720 | 30480 | 457 | 305 | 1023 |

Supported tools: Pen (0x0802), Eraser (0x080A), Cursor (0x0006), Airbrush (0x0902). Tool type carried in proximity packet (Report ID 0x20), bytes 3–5.

***

### 6.8 Intuos2 (XD-series)

Functionally identical to Intuos I at the protocol level; same packet layout. Different hardware coating and Bluetooth option (XD-0608-BT, PID 0x0CA).[^1]


| Model | Name | PID | PKGLEN | MaxX | MaxY | Width mm | Height mm | Pressure Max |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| XD-0405-U | Intuos2 4x5 | 0x41 | 10 | 12700 | 10360 | 127 | 97 | 1023 |
| XD-0608-U | Intuos2 6x8 | 0x42 | 10 | 20320 | 16002 | 203 | 152 | 1023 |
| XD-0912-U | Intuos2 9x12 | 0x43 | 10 | 30480 | 24060 | 305 | 229 | 1023 |
| XD-1212-U | Intuos2 12x12 | 0x44 | 10 | 30480 | 30480 | 305 | 305 | 1023 |
| XD-1218-U | Intuos2 12x18 | 0x45 | 10 | 45720 | 30480 | 457 | 305 | 1023 |


***

### 6.9 Intuos3 (PTZ-series)

Protocol VI, 9-byte packets. Coordinate resolution doubles vs. Intuos2. **12-bit pressure** (0–2047). Tilt ±60°. Dedicated express-key interface (interface 1).[^7]

**9-byte pen packet:**

```
Byte 0: Report ID (0x02)
Byte 1: [^6]=proximity [^2]=btn2 [^1]=btn1 [^0]=tip
Bytes 2–3: X (big-endian 16-bit)
Bytes 4–5: Y (big-endian 16-bit)
Bytes 6–7: Pressure 12-bit (byte6 bits[3:0] = high nibble, byte7 = low byte)
Byte  8: Tilt X (signed 7-bit, bits[6:0]); bit7=Tilt Y sign
Byte  9*: Tilt Y magnitude  (*10th byte in some models)
```

**Express key report (9 bytes, Report ID 0x0C on interface 1):**

- Byte 1: Keys 1–4 bitmask
- Byte 2: Keys 5–8 bitmask
- Bytes 3–4: Left touch strip (10-bit, signed)
- Bytes 5–6: Right touch strip (10-bit, signed)

| Model | Name | PID | PKGLEN | MaxX | MaxY | Width mm | Height mm | Pressure Max | Pad Buttons |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| PTZ-430 | Intuos3 4x5 | 0xB0 | 9 | 25400 | 20320 | 127 | 97 | 2047 | 4+2 strips |
| PTZ-630 | Intuos3 6x8 | 0xB1 | 9 | 40640 | 30480 | 203 | 152 | 2047 | 8+2 strips |
| PTZ-930 | Intuos3 9x12 | 0xB2 | 9 | 60960 | 45720 | 305 | 229 | 2047 | 8+2 strips |
| PTZ-1230 | Intuos3 12x12 | 0xB3 | 9 | 60960 | 60960 | 305 | 305 | 2047 | 8+2 strips |
| PTZ-1231W | Intuos3 12x19 | 0xB4 | 9 | 97536 | 60960 | 492 | 305 | 2047 | 8+2 strips |
| PTZ-631W | Intuos3 6x11 | 0xB7 | 9 | 54204 | 31750 | 274 | 159 | 2047 | 8+2 strips |
| PTZ-431W | Intuos3 4x6 | 0xB8 | 9 | 31496 | 19685 | 159 | 100 | 2047 | 4+2 strips |


***

### 6.10 Intuos4 (PTK-series)

Protocol VI extended. **2047 pressure levels**. Rotation/fingerwheel on airbrush (10-bit). OLED express keys (8 keys with per-key icons, 13×13 px mono OLED). Interface 0 = pen, interface 1 = pad.[^3]

**10-byte pen packet (same layout as Intuos3 but byte 7 carries full 12-bit pressure high nibble):**

```
Byte 0: Report ID 0x12 (pen in range) or 0x10 (proximity out)
Bytes 1–2: Tool ID / serial (upper 16 bits on prox-in)
Bytes 3–4: X (LE16)
Bytes 5–6: Y (LE16)
Byte  7: Pressure high nibble [3:0]
Byte  8: Pressure low byte  → 12-bit (0–2047)
Byte  9: Tilt X signed 7-bit
Byte 10: Tilt Y signed 7-bit (11-byte total for some models)
```

| Model | Name | PID | PKGLEN | MaxX | MaxY | Width mm | Height mm | Pressure Max | Pad Buttons |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| PTK-440 | Intuos4 S | 0xB8 | 10 | 31496 | 19685 | 160 | 101 | 2047 | 8 OLED |
| PTK-640 | Intuos4 M | 0xB9 | 10 | 44704 | 27940 | 224 | 140 | 2047 | 8 OLED |
| PTK-840 | Intuos4 L | 0xBA | 10 | 63496 | 39370 | 325 | 203 | 2047 | 8 OLED |
| PTK-1240 | Intuos4 XL | 0xBB | 10 | 97536 | 60960 | 483 | 305 | 2047 | 8 OLED |
| PTK-540WL | Intuos4 WL (USB) | 0xBC | 10 | 44704 | 27940 | 224 | 140 | 2047 | 8 OLED |

> **OLED initialization:** Send output report 0x03 with 9 bytes after pen mode-switch. `FeatureInitDelayMs = 150`. Omitting this report causes the OLED keys to show garbled icons.[^3]

***

### 6.11 Intuos5 / Intuos Pro (PTH/PTK-series)

This family splits into two distinct protocol generations based on PID.

**Intuos5 (PIDs 0x26–0x2A):** Use the legacy INTUOSPM/INTUOSPL type in the Linux driver. 10-byte pen packets, standard `[0x02, 0x02]` mode-switch init, `wacom_intuos_general()` for report parsing.

**Intuos Pro 2nd gen (PIDs 0x0314–0x0358):** Use `HID_GENERIC` type in the Linux driver — no explicit entry in `wacom_features`. These devices enumerate as two HID interfaces and use a 27-byte pen report (Report ID `0x10`) over the standard HID path. See §6.11a for full details.

| Model | Name | PID | Pen PKGLEN | MaxX | MaxY | Width mm | Height mm | Pressure Max | Pad Buttons | Touch | Linux Type |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| PTH-450 | Intuos5 Touch S | 0x26 | 10 | 31496 | 19685 | 160 | 101 | 2047 | 8 | Yes | INTUOSPM |
| PTH-650 | Intuos5 Touch M | 0x27 | 10 | 44704 | 27940 | 224 | 140 | 2047 | 8 | Yes | INTUOSPM |
| PTH-851 | Intuos5 Touch L / Intuos Pro Large (1st) | 0x0317 | 10 | 44704 | 27940 | 325 | 203 | 2047 | 8 | Yes | INTUOSPL |
| PTK-450 | Intuos5 Pen S | 0x29 | 10 | 31496 | 19685 | 160 | 101 | 2047 | 8 | No | INTUOSPM |
| PTK-650 | Intuos5 Pen M | 0x2A | 10 | 44704 | 27940 | 224 | 140 | 2047 | 8 | No | INTUOSPM |
| PTH-660 | Intuos Pro Medium (2nd gen) | 0x0357 | 27 | 44704 | 27940 | 224 | 140 | 8191 | 8 | Yes | HID_GENERIC |
| PTH-860 | Intuos Pro Large (2nd gen) | 0x0358 | 27 | 63496 | 39370 | 325 | 203 | 8191 | 8 | Yes | HID_GENERIC |

> **PTH-851 init:** Send `[0x02, 0x02]` feature report immediately after open. Do NOT filter on the high-confidence bit (byte 1 bit 6) — pen-lift emits low-confidence reports; filtering them blocks pressure reaching zero and leaves mouse stuck down.

> **PTH-660/860 init:** The Linux driver sends a `SET_REPORT` on the feature report containing `HID_DG_INPUTMODE`, setting it to value `2` (see §5.5). The exact report ID is read from the HID descriptor, not hardcoded. Without this init, the device delivers position data but **cursor tool button state is absent from all reports**.

***

### 6.11a Intuos Pro 2nd Gen (PTH-660/860) — 27-Byte HID_GENERIC Report Format

PTH-660 (0x0357) and PTH-860 (0x0358) use Report ID `0x10` for all pen/tool events. The report is 27 bytes. **13-bit pressure** (max 8191). All multi-byte values are little-endian.

```
Byte   Field
───────────────────────────────────────────────────────────────────
 [0]   Report ID = 0x10
 [1]   Status byte
          bit 5 (0x20) = high confidence (set when tool reliably tracked)
          bit 6 (0x40) = in proximity
          bit 1 (0x02) = pen button 1 (side switch lower) — pen only
          bit 2 (0x04) = pen button 2 (side switch upper) — pen only
          bit 4 (0x10) = eraser — pen only
          NOTE: for cursor/mouse tools, none of these bits carry button state
 [2–4]  X position, 24-bit LE
 [5–7]  Y position, 24-bit LE
 [8–9]  Pressure, 13-bit LE (0–8191); always 0x0000 for cursor/mouse tool
[10]   Tilt X, signed 8-bit
[11]   Tilt Y, signed 8-bit
[12–13] Rotation, signed 16-bit LE ÷ 10 = degrees (pen/art pen only;
         constant value for cursor/mouse tool)
[14–15] Always 0x00 (observed)
[16]   Cursor/scroll counter (cursor/mouse tool only):
         absolute 8-bit counter, wraps at 255;
         delta = Int8(bitPattern: current &- previous) → signed scroll steps;
         for pen tools: hover distance (0 = contact, higher = farther away)
[17–20] Tool serial number, 32-bit LE
[21–22] Tool code, 16-bit LE (identifies pen model / cursor type)
[23–26] Static tail: always 0x10 0x00 0x06 0x08 (observed; purpose unknown)
```

**Report IDs on interface 0 (usagePage=0x0001, usage=0x0002, maxRptSize=192):**

| ID | Content |
| :-- | :-- |
| 0x10 | Pen / tool position (27 bytes, layout above) |
| 0x1E | Offset pen (alternative pen report) |
| 0x21 | Touch data |

**Interface 1 (usagePage=0xFF00, usage=0x0005, maxRptSize=44):** Express keys / pad controls. Report ID `0x11`, 9 bytes: byte 2 = button bitmask.

**Tool codes (16-bit, LE from bytes [21–22]):**

| Pattern | Tool |
| :-- | :-- |
| low nibble `0x_2` | Standard pen (e.g. `0x0802`) |
| low nibble `0x_4` | Art Pen / 6D pen |
| low nibble `0x_A` | Eraser |
| low nibble `0x_6` | **Cursor / cordless mouse** (e.g. KC-100-00 = `0x0806`) |

Detection: `(toolCode & 0x000F) == 0x0006` for cursor/mouse. **Do not use `(toolCode & 0x0800) == 0`** — the KC-100-00 reports `0x0806` which has the 0x0800 bit set; that test gives a false negative.

#### Cursor/Mouse Tool (KC-100-00): Button State — Known Limitation

**Mouse button state (L/R/Middle/Side) does NOT appear in any byte of the 0x10 report.** Exhaustive logging of all 27 bytes during button presses confirms byte 1 remains `0x60` throughout. This has been verified against both MockTab and OpenTabletDriver — neither can decode mouse buttons from the raw HID stream without the proper mode initialization.

The Linux kernel driver (`wacom_wac_pen_report`, the HID_GENERIC path) also does not decode cursor buttons — `BTN_LEFT`/`BTN_RIGHT`/`BTN_MIDDLE` are simply not reported for cursor tools on PTH-660/860. Only `BTN_TOOL_MOUSE` is set on proximity-in.

Wacom's official driver works because it:
1. Parses the device's HID report descriptor to locate the feature report containing `HID_DG_INPUTMODE` (or `WACOM_HID_WD_DATAMODE`)
2. Sends `SET_REPORT` with value `2` to switch the device into full tablet mode
3. After this init, button state presumably becomes available (exact byte positions require HID descriptor analysis — see §5.5)

**To decode mouse buttons:** dump the raw HID descriptor from the device:
- macOS command: `ioreg -l -x -d 2 -c IOHIDDevice | grep -B 10 -A 30 "0x0357"`
- Or read via API: `IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data`

The descriptor will identify which report ID and which bit positions carry each button usage. This is the prerequisite for implementing button support.

#### Cursor/Mouse Tool: Scroll Wheel (byte [16]) — Confirmed Working

Byte [16] is an absolute scroll position counter. To get scroll delta:
```swift
let delta = Int8(bitPattern: report[16] &- lastScrollPos)
lastScrollPos = report[16]
// delta > 0 = scroll up, delta < 0 = scroll down
```
`Int8(bitPattern:)` handles 8-bit wraparound correctly (255 → 0 = +1 step).

***

### 6.12 Cintiq (DTZ/DTK series, pen displays)

Cintiq tablets add a built-in display; from the USB protocol perspective they behave like oversized Intuos. The display drives via a separate video connection (DisplayPort/VGA); the USB port carries only pen data and express key events.

**Cintiq 12WX and 21UX (1st gen)** use Protocol VI, 10-byte packets.[^1]


| Model | Name | PID | PKGLEN | MaxX | MaxY | Width mm | Height mm | Pressure Max | Pad Buttons |
| :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- | :-- |
| DTZ-2100 | Cintiq 21UX (1st gen) | 0x3F | 10 | 87200 | 65600 | 432 | 325 | 1023 | 8 |
| DTZ-1200W | Cintiq 12WX | 0xC6 | 10 | 53020 | 33440 | 261 | 163 | 2047 | 4+2 strips |
| DTK-2100 | Cintiq 21UX (2nd gen) | 0xCC | 10 | 87200 | 65600 | 432 | 325 | 2047 | 8 |
| DTK-2400 | Cintiq 24HD | 0xF4 | 10 | 104480 | 65600 | 526 | 329 | 2047 | 8+4 strips |
| DTH-2200 | Cintiq 22HD Touch | 0xF8 | 10 | 95440 | 53720 | 476 | 268 | 2047 | 8 + touch |


***

## 7. macOS-Specific Implementation Notes

### 7.1 HID Blacklisting

macOS's `IOHIDFamily` will claim any device matching standard digitizer HID usage pages before your daemon can. Before your daemon opens the USB device, install a **user-space DriverKit personality** that matches on `VendorID`/`ProductID` and claims priority. Alternatively, use `IOUSBHostDevice::deviceRequest` with `kUSBDeviceInterfaceID650` to seize the device at the USB layer before HID matching.[^2]

### 7.2 Coordinate Mapping

Map device-native coordinates to macOS screen space using `CGDisplayBounds()` for the target display. Compute scale factors:

```swift
let scaleX = displayWidth  / Double(tablet.maxX)
let scaleY = displayHeight / Double(tablet.maxY)
```

For displays attached to a Cintiq, map 1:1 to that display's bounds; otherwise apply the user's area mapping preference.

### 7.3 Pressure Curve

Normalize raw pressure to `[0.0, 1.0]` by dividing by `pressureMax`. Apply a configurable Bézier curve (like Wacom's official driver) before injecting as `kHIDUsage_Dig_TipPressure`. The linear mapping is technically correct but perceptually harsh.

### 7.4 Sleep/Wake Handling

Register for `IOPMrootDomain` sleep/wake notifications via `IORegisterForSystemPower`. On wake, re-issue the full initialization sequence (§5) because USB devices reset to HID-compliant mode after a power cycle. Failure to re-initialize is the most common field-reported bug in DIY Wacom macOS drivers.[^2]

### 7.5 Multi-Interface Devices

Tablets with touch (CTH-series, Intuos5, Cintiq 22HD) enumerate two HID interfaces. Open both via `IOUSBHostInterface` using `IOUSBHostDevice::copyInterface(with: matchingDict)`, with separate initialization reports per interface. Run two independent read loops on separate dispatch queues — pen data and touch data arrive asynchronously.[^3]

***

## 8. Quick Reference: Protocol Selection by PID Range

| PID Range | Family | Protocol | PKGLEN | Pressure Bits | Tilt |
| :-- | :-- | :-- | :-- | :-- | :-- |
| 0x00–0x03 | PenPartner | Pre-IV | 7 | 8 | No |
| 0x10–0x12 | Graphire | IV | 8 | 10 | No |
| 0x13–0x17 | Graphire3/4 | IV | 8 | 10 | No |
| 0x20–0x24 | Intuos I | V | 10 | 10 | Yes |
| 0x26–0x2A | Intuos5/Pro (1st gen) | VI ext | 10 | 11 | Yes |
| 0x0357–0x0358 | Intuos Pro 2nd gen | HID_GENERIC | 27 | 13 | Yes |
| 0x3F | Cintiq 21UX (1st) | VI | 10 | 10 | Yes |
| 0x41–0x45 | Intuos2 | V | 10 | 10 | Yes |
| 0x46–0x47 | Bamboo Fun (1st) | IV | 8 | 10 | No |
| 0x60–0x61 | Volito | IV | 8 | 10 | No |
| 0x81 | Graphire4 BT | IV-BT | 8 | 10 | No |
| 0xB0–0xB8 | Intuos3 | VI | 9 | 12 | Yes |
| 0xB8–0xBC | Intuos4 | VI+OLED | 10 | 12 | Yes |
| 0xC6, 0xCC | Cintiq 12WX/21UX2 | VI | 10 | 12 | Yes |
| 0xD1–0xD8 | Bamboo 2nd/3rd gen | VI-BT | 10 | 10 | No |
| 0xF4, 0xF8 | Cintiq 24HD/22HD | VI ext | 10 | 12 | Yes |

<span style="display:none">[^10][^11][^13][^14][^15][^16][^17][^18][^19][^20][^21][^22][^23][^24][^25][^26]</span>

<div align="center">⁂</div>

[^1]: https://documentation.fandom.com/wiki/Wacom_Linux

[^2]: https://www.reddit.com/r/wacom/comments/1hle2zj/revive_your_old_wacom_tablets_on_macos_with/

[^3]: https://opentabletdriver.net/Wiki/Development/Configurations

[^4]: https://github.com/torvalds/linux/blob/master/drivers/hid/wacom.h

[^5]: https://www.kernel.org/pub/linux/kernel/people/marcelo/linux-2.4/drivers/usb/wacom.c

[^6]: https://github.com/OpenTabletDriver/OpenTabletDriver/releases

[^7]: https://git.riwo.eu/Opensource/linux-toradex-kernel/-/blob/7742e7756c0637ae5378e394ca03978826e31a78/drivers/input/tablet/wacom_wac.h

[^8]: https://github.com/ppy/osu/discussions/29245

[^9]: https://github.com/OpenTabletDriver/OpenTabletDriver/issues/3204

[^10]: https://opentabletdriver.net/Wiki/Documentation/ConfigurationGuide

[^11]: https://www.reddit.com/r/Fedora/comments/wc7zql/wacom_tablet_driver_interfering_with/

[^12]: https://opentabletdriver.net/Wiki/FAQ/General

[^13]: https://github.com/linuxwacom/wacom-hid-descriptors

[^14]: https://developer-support.wacom.com/hc/en-us/articles/9354461938711-Silent-installation-or-uninstallation-of-tablet-and-video-drivers

[^15]: https://android.googlesource.com/kernel/common/+/4c2ae844b5ef85fd4b571c9c91ac48afa6ef2dfc/drivers/usb/input/hid-core.c

[^16]: https://stackoverflow.com/questions/37163207/reverse-engineering-a-hid-handshake-by-examining-bytes-over-usb

[^17]: https://github.com/OpenTabletDriver/OpenTabletDriver

[^18]: https://opentabletdriver.net/Wiki/Documentation/RequiredPermissions

[^19]: https://codelab.wordpress.com/2010/02/21/wacom-hacking/

[^20]: https://www.reddit.com/r/ReverseEngineering/comments/69h489/introducing_hidviz_the_ultimate_tool_for/

[^21]: https://pages.amd.e-technik.uni-rostock.de/mesh/apu-linux-kernel/-/blob/v3.0-rc3/drivers/input/tablet/wacom_wac.h

[^22]: https://docs.huihoo.com/doxygen/linux/kernel/3.7/wacom__wac_8c.html

[^23]: https://support.wacom.com/hc/en-us/articles/1500006273521-Why-is-pen-pressure-data-important

[^24]: https://help.ubuntu.com/community/Install_linuxwacom_driver

[^25]: https://developer-docs.wacom.com/docs/icbt/linux/kernel-events/kernel-events-basics/

[^26]: https://forum.pjrc.com/index.php?threads%2Fpen-stylus-digitizer-hid-descriptor-feature-needed.42729%2F

