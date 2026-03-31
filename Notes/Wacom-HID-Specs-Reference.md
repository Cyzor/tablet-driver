2026-03-31

# Wacom HID Reference: Expanded Specification

## Part I — Transport Layer

### 1.1 USB Protocol Overview

All Wacom USB devices use HID-class communication with the following topology:

| Endpoint | Direction | Usage |
|---|---|---|
| `EP0` (Control) | Bidirectional | Descriptor queries, feature reports, SET_FEATURE/GET_FEATURE for init sequences |
| `EP1` (Interrupt IN) | IN only | Pen, pad, and touch data — polling interval varies by device class |

**Polling intervals by device class:**

| Device Class | Polling Interval | Notes |
|---|---|---|
| Graphire/Volito | 8 ms | Standard HID polling |
| Intuos 1/2 | 8 ms | Same as Graphire |
| Intuos3 | 8 ms | Can negotiate lower latency |
| Intuos4+ / Cintiq | 4 ms | Display-class latency for pen |
| Intuos Pro gen2 | 4 ms | Higher throughput for 8191 pressure levels |
| Cintiq Pro (27", Movink) | 1–2 ms | USB 3.0 controllers allow sub-ms polling |

**USB version support:**

| Device | USB Version | Notes |
|---|---|---|
| Graphire/Volito | USB 1.1 | Full-speed (12 Mbps) |
| Intuos 1/2 | USB 1.1 | Full-speed |
| Intuos3 | USB 2.0 | High-speed (480 Mbps) |
| Intuos4/5 | USB 2.0 | High-speed |
| Intuos Pro gen1 | USB 2.0 | High-speed |
| Intuos Pro gen2 | USB 2.0 | High-speed |
| Cintiq 13HD/20WSX | USB 2.0 | High-speed |
| Cintiq 24HD/22HD | USB 2.0 | High-speed |
| Cintiq Pro 27 | USB 3.0 | Super-speed (5 Gbps) |
| Movink 13 | USB 3.0 | Super-speed |

### 1.2 USB Descriptor Structure

Wacom devices expose a standard HID descriptor with Digitizer Usage Page (0x0D). The typical structure:

```
Usage Page (Digitizer)          05 0D
Usage (Digitizer)               09 01
Collection (Application)        A1 01
    Usage (Pen)                 09 02
    Collection (Physical)       A1 00
        Usage (X)               09 30
        Usage (Y)               09 31
        Usage (Pressure)        09 32
        Usage (Tilt X)          09 33
        Usage (Tilt Y)          09 34
        Usage (Azimuth)         09 35
        Usage (Altitude)        09 36
        Usage (Tip Switch)      09 42
        Usage (Barrel Switch)   09 44
        ...
    End Collection             C0
    Usage (Pad)                 09 39  (or 0x0C for Consumer page on some devices)
    Collection (Physical)       A1 00
        ...
    End Collection             C0
End Collection                 C0
```

**Key Usage Page assignments:**

| Page | Usage | Function |
|---|---|---|
| 0x0D (Digitizer) | 0x02 (Pen), 0x01 (Digitizer) | Primary tool reports |
| 0x0D | 0x39 (Pad) | ExpressKeys, touch strips, rings |
| 0x0D | 0x30 (X), 0x31 (Y), 0x32 (Pressure) | Position/pressure |
| 0x0D | 0x33 (Tilt X), 0x34 (Tilt Y) | Tilt sensing |
| 0x0D | 0x35 (Azimuth), 0x36 (Altitude) | Rotation sensing (Art Pen) |
| 0x0D | 0x42 (Tip Switch), 0x44 (Barrel Switch) | Button state |
| 0x0C (Consumer) | 0x01, 0x02, 0x06 | Some pad functions, OSD controls |

### 1.3 USB Feature Reports

Beyond the init sequences documented in Appendix B, Wacom devices support additional feature reports:

**Standard feature report IDs (varies by device):**

| Report ID | Direction | Purpose |
|---|---|---|
| `0x02` | IN | Device identity (serial, tool info) |
| `0x04` | IN/OUT | Feature query / LED control |
| `0x05` | IN | Unknown / reserved |
| `0x06` | IN/OUT | Touch strip configuration |
| `0x07` | IN/OUT | ExpressKey mapping |
| `0x0A` | OUT | LED brightness (Intuos4/5) |
| `0x0B` | IN | Wireless status (dongle query) |

**LED control sequence (Intuos4/5/Pro):**

```
// Enable LED (ring or per-key)
SET_FEATURE report ID 0x0A
Data: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
// Enable per-key LED on Intuos Pro
Data: [0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00]
```

**Wireless USB dongle query (Intuos4 WL, Intuos5 WL):**

```
// Query wireless connection status
GET_FEATURE report ID 0x0B
Returns: [status, battery, unknown, unknown, ...]
status: 0x00 = wired, 0x01 = wireless connected, 0x02 = wireless disconnected
```

### 1.4 Bluetooth HID Profile

Wacom's Bluetooth implementation uses the standard HID profile (Bluetooth SIG HID 1.1 specification). Key characteristics:

**Connection establishment:**

| Step | Action |
|---|---|
| 1 | Device performs SDP query for HID service |
| 2 | Opens L2CAP channel for Control (PSM 0x11) and Interrupt (PSM 0x13) |
| 3 | Device sends HID descriptor via Control channel |
| 4 | Connection enters ACTIVE state |

**Bluetooth device list:**

| PID | Name | BT Address Range | Notes |
|---|---|---|---|
| 0x0017 | Bamboo Fun MTE-450 | — | Some units support BT optional adapter |
| 0x00B8–0x00BC | Intuos4 WL | — | Integrated Bluetooth |
| 0x0026–0x0028 | Intuos5 WL | — | Integrated Bluetooth |
| 0x0314–0x0317 | Intuos Pro WL | — | Integrated Bluetooth |

**Bluetooth-specific behaviors:**

- **Idle timeout**: Wacom Bluetooth devices enter low-power mode after 10 seconds of no proximity activity. Proximity detection wakes the device instantly.
- **Battery reporting**: Wacom BT devices report battery level via HID reports (often encoded in pad report or as a separate feature report).
- **Pairing method**: Devices use Simple Secure Pairing (SSP) with Just Works or PIN entry depending on firmware version.

**Report format over Bluetooth:**
The HID report format remains identical to USB — same Report IDs, same byte structures. Only the transport layer (L2CAP vs USB) differs.

### 1.5 Wireless USB Dongles

Wacom wireless solutions use proprietary RF protocols over USB dongles:

**Dongle device IDs:**

| PID | Name | Paired Device |
|---|---|---|
| 0x009D | Wireless Receiver | Intuos4 WL, Intuos5 WL |
| 0x009A | Wireless Receiver | Intuos Pro gen1 WL |

**RF protocol characteristics:**

- **Frequency**: 2.4 GHz ISM band
- **Range**: Up to ~10 meters line of sight
- **Latency**: 8 ms typical (same as wired USB polling)
- **Pairing**: Factory-paired; replacement dongles require re-pairing via Wacom driver software

**Dongle initialization sequence:**

```
// Query paired device
GET_FEATURE report ID 0x0B
Returns: [0x01, battery_level, device_type, ...]

// Poll for pad input (wireless status embedded)
GET_FEATURE report ID 0x0B (polled at ~100ms interval)
```

**Power management:**

- Dongle maintains continuous USB connection
- Tablet enters sleep after 15 seconds of no proximity
- Wake via proximity detection (pen within range)
- Battery level available via feature report

### 1.6 I2C HID

Newer Wacom devices (Cintiq Pro 27, Movink 13, some embedded solutions) use I2C HID instead of USB:

**I2C topology:**

| Parameter | Value |
|---|---|
| Bus | I2C (standard mode, 100 kHz or 400 kHz) |
| HID descriptor | Downloaded over I2C at init |
| Interrupt | GPIO pin for data ready |
| Address | Device-specific (typically 0x09–0x0F) |

**I2C-specific init sequence (Cintiq Pro 27 example):**

```
// I2C write: query HID descriptor size
[0x00, 0x01] → read 2 bytes → descriptor_size

// I2C write: request HID descriptor
[0x00, 0x02, size_low, size_high] → read descriptor_size bytes

// I2C write: set report format
[0x00, 0x03, 0x00] → confirm

// Interrupt-driven data delivery after init
```

**Report format on I2C:**
Identical byte layout to USB versions — Report ID 0x02 for pen, 0x11 for pad. Only the transport handshake differs.

### 1.7 Boot Protocol Mode

All Wacom devices support a simplified "boot protocol" compatible mode as defined in USB HID 1.1 specification. This mode is entered via:

```
SET_REPORT (Feature) ID 0x00
Data: [0x00]  // Enter boot protocol
```

**Boot protocol characteristics:**

| Feature | Boot Protocol | Report Protocol |
|---|---|---|
| Report ID | None (fixed 8 bytes) | Variable (0x01, 0x02, etc.) |
| Report length | 8 bytes | 8–11 bytes depending on device |
| Features | Position + pressure only | Full feature set |
| Tilt/rotation | Not available | Available on supported devices |
| Pad data | Not available | Available |

Boot protocol is primarily used by BIOS-level input handling (pre-OS environments). Most operating systems switch to report protocol automatically after loading the Wacom driver.

---

## Part II — Device Behavior and Quirks

### 2.1 Proximity Detection Behavior

**Enter proximity sequence:**

1. **Proximity packet** (0xC0–0xCF on intuos families): Tool serial, tool ID encoded
2. **In-range packet** (0x20 on intuosV1/intuos3): Confirmation of hover state
3. **Data packets**: Streaming position/pressure data

**Exit proximity sequence:**

| Family | Sequence |
|---|---|
| graphire | Single 0x80 packet, immediate exit |
| intuos3 | Single 0x80 packet, immediate exit |
| intuosV1/intuosV2 | Packet with proximity bit clear, then 0x80 exit |
| Cintiq 24HD/22HD | Requires ring/touch strip activity to clear prox state |

### 2.2 Eraser Mode Detection

Wacom devices detect eraser vs pen through tool serial numbering:

| Tool Type | Serial Prefix | Detection Method |
|---|---|---|
| Pen | 0x00–0x7F | Standard serial |
| Eraser | 0x80–0xFF | Tool ID bit 3 (`tool_id & 0x0008`) set |
| Mouse (2D) | 0x09x | Tool ID indicates mouse |
| Art Pen | 0x10804, 0x204 | Tool ID for rotation support |

**Eraser proximity:**
Eraser activates `BTN_TOOL_RUBBER` (ABS_MISC bit 0x8000000 set via `wacom_intuos_id_mangle()`).

### 2.3 Touch Strip Behavior (Intuos3/4/5, Cintiq WS models)

**Touch strip encoding by device:**

| Device | Strip Count | Report ID | Encoding |
|---|---|---|---|
| Intuos3 PTZ-631W | 2 | 0x0C | 13-bit each, 0 = finger off |
| Intuos4 | 0 | — | No strips, ring only |
| Intuos5/Pro gen1 | 0 | — | No strips, ring only |
| Cintiq 20WSX | 2 | 0x11 | 10-bit each |
| Cintiq 24HD | 2 | 0x11 | 10-bit each |

**Strip activation threshold:**
Minimum value before reporting: strip must exceed ~50 units to be considered active. Full range: 0–1023 (10-bit) or 0–8191 (13-bit on Intuos3).

### 2.4 Touch Ring (Intuos4/5/Pro/Cintiq)

**Ring position encoding:**

```
Ring active: d[n] & 0x80 = 0x80
Ring position: d[n] & 0x7F  // 0–127 (0–360° mapped to 0–127)
```

**Ring functions by device:**

| Device | Left Ring | Right Ring |
|---|---|---|
| Intuos4 | ABS_WHEEL | — |
| Intuos5/Pro gen1 | ABS_WHEEL | — |
| Intuos Pro gen2 | ABS_WHEEL | ABS_THROTTLE |
| Cintiq 24HD | ABS_WHEEL | ABS_THROTTLE |
| Cintiq 22HD | ABS_WHEEL | — |

**Ring wrapping:** Position wraps from 127 to 0 (continuous rotation). Some drivers implement modulo-128 handling.

### 2.5 Sleep/Wake Behavior

**Sleep triggers:**

| Condition | Delay | Behavior |
|---|---|---|
| No proximity for 15 seconds | 15s | Device enters low-power mode |
| USB suspend (OS-driven) | OS-dependent | Device suspends HID communication |
| Bluetooth idle timeout | 10s | Device enters sniff mode |
| Wireless tab inactivity | 5 minutes | RF link powers down |

**Wake triggers:**

| Trigger | Wake Time |
|---|---|
| Proximity (pen within detection range) | < 1 ms (USB), < 10 ms (BT) |
| Button press (ExpressKey) | < 1 ms |
| Touch strip activation | < 5 ms |
| USB resume (host-initiated) | ~50 ms |

**Battery reporting during sleep:**
Bluetooth devices continue advertising battery level in the HID descriptor even when asleep. USB devices do not report battery during suspend.

### 2.6 Device-Specific Quirks

| PID | Device | Quirk |
|---|---|---|
| 0x0003 | PenPartner | Uses 8-byte packet with unique format — see graphire section |
| 0x003F | Cintiq 21UX (original) | PL protocol (wacom_pl_irq) — distinct 17-bit X/Y encoding |
| 0x00CC | Cintiq 21UX DTZ-2100 ² | RDY bit gate (0x40 in d[0]) — only intuosV1 device requiring this check |
| 0x00F4 | Cintiq 24HD | Dual ring support, keyboard shortcut encoding in d[4] |
| 0x00FA/0x00F9 | Cintiq 22HD | Single ring, extended button encoding (18 bits) |
| 0x0352/0x0357/0x0358 | Intuos Pro gen2 | intuosV2 protocol, 8191 max pressure, dual ring |
| 0x03A6 | DTC-133 | intuosV2 protocol, no buttons, no ring |
| 0x03C0 | Cintiq Pro 27 | intuosV2 protocol, USB 3.0, I2C optional |
| 0x03F0 | Movink 13 | intuosV2 protocol, USB 3.0, thinnest form factor |

---

## Part III — Tool Type Reference

### 3.1 Complete Tool ID Table

| Tool ID (decimal) | Tool ID (hex) | Device(s) | Tool Type | Features |
|---|---|---|---|---|
| 18 | 0x012 | Intuos 1/2 | BTN_TOOL_PENCIL | Standard pen |
| 33 | 0x021 | Intuos 1/2 | BTN_TOOL_PEN | Standard pen |
| 206 | 0x0CE | Intuos3 | BTN_TOOL_PEN | Standard pen |
| 512 | 0x200 | Intuos3 | BTN_TOOL_PEN | Standard pen |
| 513 | 0x201 | Intuos3 | BTN_TOOL_PEN | Standard pen |
| 2050 | 0x802 | Intuos 1/2 | BTN_TOOL_PENCIL | Inking pen |
| 2051 | 0x803 | Intuos 1/2 | BTN_TOOL_PEN | Standard pen |
| 2066 | 0x812 | Intuos3 | BTN_TOOL_PENCIL | Inking pen |
| 2098 | 0x832 | Intuos3 | BTN_TOOL_BRUSH | Stroke pen |
| 8962 | 0x2302 | Intuos3 | BTN_TOOL_PEN | Standard pen |
| 32774 | 0x8006 | Intuos 1/2 | BTN_TOOL_RUBBER | Eraser |
| 32781 | 0x801D | Intuos3 | BTN_TOOL_RUBBER | Eraser |
| 32795 | 0x801B | Intuos3 | BTN_TOOL_RUBBER | Eraser |
| 32804 | 0x8024 | Intuos4 | BTN_TOOL_RUBBER | Eraser |
| 65664 | 0x10100 | Intuos Pro gen2 | BTN_TOOL_PEN | Standard pen |
| 65860 | 0x10184 | Intuos Pro gen2 | BTN_TOOL_RUBBER | Eraser |
| 66084 | 0x10224 | Intuos Pro gen2 | BTN_TOOL_PEN | Standard pen |
| 0x885 | 0x885 | Intuos4/5 | BTN_TOOL_PEN | Art Pen (rotation) |
| 0x804 | 0x804 | Intuos3/4 | BTN_TOOL_PEN | Marker Pen (rotation) |
| 0x10804 | 0x10804 | Intuos4/5 | BTN_TOOL_PEN | Art Pen 2 (rotation) |
| 0x204 | 0x204 | Intuos5/Pro | BTN_TOOL_PEN | Art Pen 2 (rotation) |

### 3.2 Tool ID Mangling Function

The Linux kernel applies `wacom_intuos_id_mangle()` to encode tool type into ABS_MISC:

```c
static int wacom_intuos_id_mangle(int tool_id)
{
    return (tool_id & 0xfff) | ((tool_id & ~0xfff) << 20);
}
```

This produces the value sent to userspace as `ABS_MISC`, enabling userspace to distinguish tools by extracting bits:

```
tool_id = (abs_misc & 0xfff) | ((abs_misc >> 20) & 0xfff)
```

---

## Part IV — Feature Report Reference

### 4.1 Complete Feature Report Matrix

| Report ID | Direction | Device(s) | Purpose | Data Format |
|---|---|---|---|---|
| 0x01 | IN/OUT | Graphire | LED control? | Device-specific |
| 0x02 | IN/OUT | All Intuos | Feature query | `[0x02, 0x02]` for init |
| 0x03 | IN | Intuos3 | Pad aux | Touch strip data |
| 0x04 | IN/OUT | All Intuos | Feature query | `[0x04, 0x00]` on intuos3 |
| 0x05 | IN | Some devices | Unknown | Reserved |
| 0x06 | IN/OUT | Intuos3/4 | Touch strip config | Device-specific |
| 0x07 | IN/OUT | Intuos3/4 | ExpressKey config | Device-specific |
| 0x0A | OUT | Intuos4/5/Pro | LED control | LED state bitmap |
| 0x0B | IN | Wireless dongles | Wireless status | [connected, battery, type] |
| 0x0C | IN | Intuos3 | Pad primary | Touch strip + buttons |
| 0x11 | IN | Intuos4/5/Pro, Cintiq | Pad | Buttons + ring data |
| 0x12 | IN | Intuos4 PTK | Pad (alternate) | Buttons only |

### 4.2 Init Sequence Timing Details

| Device Family | Step 1 | Delay | Step 2 | Delay | Step 3 |
|---|---|---|---|---|---|
| graphire | None | — | — | — | — |
| intuos3 | `[0x02, 0x02]` | 0 ms | `[0x04, 0x00]` | 150 ms | Optional feature query |
| intuosV1 | `[0x02, 0x02]` | 0 ms | — | — | — |
| intuosV2 | `[0x02, 0x02]` | 0 ms | — | — | — |
| Bluetooth | `[0x02, 0x02]` | 0 ms | — | — | — |

---

## Part V — Report ID Quick Reference (Expanded)

| Report ID | Family | Content | Length |
|---|---|---|---|
| 0x01 | graphire | Pen/Mouse/Pad combined | 8 bytes |
| 0x02 | intuos3/intuosV1/intuosV2 | Pen data | 10 bytes |
| 0x03 | intuos3 | Pad aux (alternate) | 10 bytes |
| 0x04 | intuos3 | Feature response | 10 bytes |
| 0x0C | intuos3 | Pad primary (touch strips) | 10 bytes |
| 0x0E | intuos3 | Unknown | — |
| 0x11 | intuosV1/intuosV2 | Pad (Intuos4/5/Pro, Cintiq) | 10 bytes |
| 0x12 | intuosV1 | Pad (Intuos4 PTK only) | 10 bytes |
| 0x13 | intuos3 | Unknown | — |

---

## Part VI - Wacom Puck Reference

### Supported Devices

| Device | Puck Support | Puck Model |
|---|---|---|
| Intuos4 (all sizes) | Yes | Wacom Intuos4 Puck |
| Intuos5 (all sizes) | Yes | Wacom Intuos5 Puck |
| Intuos Pro gen1 | Yes | Wacom Intuos Pro Puck |
| Intuos Pro gen2 | Yes | Wacom Pro Pen Puck (combined) |
| Cintiq 24HD | Yes | Wacom Cintiq 24HD Puck |
| Cintiq 22HD | Yes | Wacom Cintiq 22HD Puck |
| Cintiq Pro 27 | No | — |
| Movink 13 | No | — |

### Physical Characteristics

| Parameter | Value |
|---|---|
| Power | AAA battery (2x for some models) |
| Communication | 2.4 GHz wireless (same RF as wireless tablets) |
| Range | ~10 meters |
| Battery life | ~80 hours continuous use |
| Scroll wheel | Optical encoder, 20 steps per revolution |
| Buttons | 5–7 (model dependent) |

### Puck Detection and Tool ID

Pucks are identified via the same enter-proximity sequence as other tools, with specific tool IDs:

| Tool ID (hex) | Device(s) | Tool Type |
|---|---|---|
| 0x007 | Intuos1/2/3 | 2D Mouse |
| 0x09C | Intuos3 | 2D Mouse |
| 0x094 | Intuos3 | 2D Mouse |
| 0x017 | Intuos3 | 2D Mouse |
| 0x806 | Intuos 1/2 | 2D Mouse |
| 0x096 | Intuos1/2/3 | Lens Cursor |
| 0x097 | Intuos1/2/3 | Lens Cursor |
| 0x006 | Intuos3 | Lens Cursor |

The **Lens Cursor** (0x096, 0x097, 0x006) is a special high-precision cursor mode used for some puck variants.

### Puck Report Format (Report ID 0x02)

Pucks use the same Report ID 0x02 as pen input, with packet type encoded in `type = (d[0]>>1) & 0x0F`:

#### Type 0x06 — Intuos4 Mouse Packet (10 bytes)

```
02  d1  d2  d3  d4  d5  d6  d7  d8  d9
```

| Byte | Field | Formula |
|---|---|---|
| `d[0]` | Status | Proximity + packet type |
| `d[1]:d[2]` | X position (high bits) | `BE16(d[1]:d[2])` |
| `d[3]:d[4]` | Y position (high bits) | `BE16(d[3]:d[4])` |
| `d[5]` | X/Y low bits | `d[5] >> 4` (X), `d[5] & 0x0F` (Y) |
| `d[6]` | Buttons | `d[6] & 0x1F` — see below |
| `d[7]` | Scroll wheel | `((d[7]&0x80)>>7) - ((d[7]&0x40)>>6)` — signed |
| `d[8]` | Tilt X | Same formula as pen |
| `d[9]` | Tilt Y | Same formula as pen |

**Button encoding (d[6]):**

| Bit | Button |
|---|---|
| 0x01 | BTN_LEFT |
| 0x02 | BTN_MIDDLE |
| 0x04 | BTN_RIGHT |
| 0x08 | BTN_SIDE (side button 1) |
| 0x10 | BTN_EXTRA (side button 2) |

#### Type 0x08 — Intuos 2D Mouse Packet (10 bytes)

Earlier protocol used by Intuos1/2/3 pucks:

```
02  d1  d2  d3  d4  d5  d6  d7  d8  d9
```

| Byte | Field | Formula |
|---|---|---|
| `d[0]` | Status | Proximity + packet type |
| `d[1]:d[2]` | X position | BE16 |
| `d[3]:d[4]` | Y position | BE16 |
| `d[5]` | Distance | Hover height (proximity sensor) |
| `d[6]` | Pressure | Tablet proximity pressure |
| `d[7]` | Reserved | — |
| `d[8]` | Buttons + scroll | See below |
| `d[9]` | Reserved | — |

**Button encoding (d[8]):**

| Bit | Button |
|---|---|
| 0x04 | BTN_LEFT |
| 0x08 | BTN_MIDDLE |
| 0x10 | BTN_RIGHT |
| 0x01 | Scroll up (`(d[8]&0x01) - ((d[8]&0x02)>>1)`) |
| 0x02 | Scroll down |
| 0x40 | BTN_SIDE (Intuos3 only) |
| 0x20 | BTN_EXTRA (Intuos3 only) |

### Scroll Wheel Behavior

**Intuos4/5/Pro puck wheel:**

- Reports as `REL_WHEEL` (relative scroll) in `d[7]`
- Value range: -1, 0, +1 per event (one tick per detent)
- Wheel is clicky — each detent generates one packet with signed value

**Wheel button (middle click):**

- Pressing the wheel down generates `BTN_MIDDLE` (0x02 in d[6])
- Wheel can be clicked without scrolling

### Puck Power Management

| State | Behavior |
|---|---|
| Idle | Puck enters low-power mode after ~20 seconds of no movement |
| Sleeping | Does not respond to tablet proximity — must move to wake |
| Wake | Movement detected via optical encoder, ~50ms wake time |
| Battery | Reported via same feature report 0x0B as tablet battery |

---

## Gaps in Puck Documentation

1. **Pairing procedure** — How the puck is paired to the tablet is not documented in driver source. Likely requires Wacom driver software for initial pairing.

2. **Firmware updates** — Pucks may have firmware but no public update mechanism.

3. **Lens Cursor mode** — The high-precision "lens" tool ID (0x096, 0x097) behavior is not fully decoded — may affect sensitivity or filtering.

4. **Intuos Pro gen2 puck** — The Pro Pen Puck combines pen and puck in one body; switching between modes may involve a physical switch or button combination.

---


## Appendix D — Device Enumeration Summary

### By Transport

**USB-only devices:**
0x0003, 0x0004, 0x0010, 0x0011, 0x0013, 0x0014, 0x0015, 0x0016, 0x0017, 0x0060, 0x0061, 0x0062, 0x0065, 0x003F, 0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x00B4, 0x00B5, 0x00B7, 0x00C0, 0x00C4, 0x00C6, 0x00CC, 0x00F4, 0x00F8, 0x00FA, 0x00F9, 0x00FB

**USB + Bluetooth (integrated):**
0x00B8, 0x00B9, 0x00BA, 0x00BB, 0x00BC, 0x0026, 0x0027, 0x0028, 0x0314, 0x0315, 0x0316, 0x0317

**USB + Bluetooth (wireless adapter option):**
0x0017 (Bamboo Fun MTE-450)

**Wireless USB dongle paired:**
0x009D, 0x009A (dongles only; paired devices use same PIDs as wired)

**I2C HID capable:**
0x03C0 (Cintiq Pro 27), 0x03F0 (Movink 13), 0x034F, 0x0390, 0x03AE (Cintiq 16)

---

## Appendix E — Known Limitations and Areas of Uncertainty

1. **Feature report 0x05** — Purpose unclear; some Intuos3 devices respond but data format undocumented
2. **I2C HID descriptors** — Not publicly available; decoded via kernel driver reverse-engineering
3. **Bluetooth battery reporting** — Encoding varies by device; some use HID feature report, others embed in pad data
4. **OSD controls** — Some Cintiq devices support on-screen display via USB feature reports; encoding not documented in driver source
5. **Firmware update protocol** — Wacom does not publish; driver support varies by device generation
