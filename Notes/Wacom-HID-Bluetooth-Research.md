2026-04-01

## Bluetooth (BLE HOGP) Report Structures for Wacom Devices in the Registry**

Only the **IntuosV2 family** (and the Bluetooth-enabled WL variants such as CTL-4100WL / CTL-6100WL, PTH-460/660/860, etc.) use native Bluetooth via HID-over-GATT Profile (HOGP). The registry explicitly notes: “Also used over BLE HOGP (Report ID 0x01 pen, 0x03 pad).”

Older families (Graphire, IntuosV1, Intuos3, Bamboo, etc.) have **no native Bluetooth support** in the registry or the kernel (a few very old Graphire BT models existed but use a completely different 9-byte Report ID 0x03 format and are not present here).

**Key fact**: Bluetooth does **not** simply wrap identical USB event signals.  
- USB uses a single large Report ID 0x10 (192 bytes) that contains pen + pad + touch data together.  
- BLE sends **separate short HID reports** with dedicated Report IDs.  
- The **pen payload bytes are byte-for-byte identical** to the pen portion of the USB 0x10 report (starting at offset 1 in USB).  
- Pad, touch, and battery are split into their own reports (0x03, 0x05, 0x0A).

### BLE Pen Report – Report ID 0x01 (all IntuosV2 / WL models)
**Report length**: typically 16–20 bytes (exact length varies by model but payload from byte 1 is identical to USB).

| Byte | Field              | Decode / Formula                                      |
|------|--------------------|-------------------------------------------------------|
| d[0] | Report ID          | 0x01                                                  |
| d[1] | Status byte        | (see Status Byte table below)                         |
| d[2] | X LSB              | —                                                     |
| d[3] | X mid              | X = d[2] \| (d[3] << 8) \| (d[4] << 16) — LE24      |
| d[4] | X MSB              | —                                                     |
| d[5] | Y LSB              | —                                                     |
| d[6] | Y mid              | Y = d[5] \| (d[6] << 8) \| (d[7] << 16) — LE24      |
| d[7] | Y MSB              | —                                                     |
| d[8] | Pressure LSB       | —                                                     |
| d[9] | Pressure MSB       | Pressure = d[8] \| ((d[9] & 0x1F) << 8) — 13-bit (0–8191) |
| d[10]| Tilt X             | (signed char)d[10] (−127 … +127)                     |
| d[11]| Tilt Y             | (signed char)d[11] (−127 … +127)                     |
| d[12..] | Reserved / wheel / rotation (model-dependent) | Usually 0 or unused in basic pen reports |

**Status Byte (d[1]) – identical to USB V2**
| d[1] value / Mask          | State                              |
|----------------------------|------------------------------------|
| (d[1] & 0xFC) == 0xC0     | Enter proximity (tool ID follows) |
| 0x20 / 0x21                | Hover / in range (pen)             |
| 0x25                       | Hover + BTN_STYLUS2                |
| 0x60                       | Tip touching                       |
| 0x61                       | Tip + BTN_STYLUS                   |
| 0x65                       | Tip + BTN_STYLUS2                  |
| 0x28                       | Eraser hover                       |
| 0x68                       | Eraser touching                    |
| 0x80                       | Exit proximity                     |
| d[1] & 0x02                | BTN_STYLUS (barrel 1)              |
| d[1] & 0x04                | BTN_STYLUS2 (barrel 2)             |
| d[1] & 0x01                | BTN_TOUCH (tip)                    |

### BLE Pad / ExpressKey Report – Report ID 0x03
**Report length**: 4–8 bytes (model-dependent).

| Byte | Field         | Decode                                      |
|------|---------------|---------------------------------------------|
| d[0] | Report ID     | 0x03                                        |
| d[1] | Button state  | Bitmask for 8–20 express keys / side buttons |
| d[2] | Touch ring / dial | Signed 8-bit value (−128 … +127)         |
| d[3..] | Reserved    | Usually 0                                   |

### BLE Touch Report – Report ID 0x05 (touch-enabled models only)
| Byte | Field          | Decode                                      |
|------|----------------|---------------------------------------------|
| d[0] | Report ID      | 0x05                                        |
| d[1] | Touch count    | Number of fingers (0–5)                     |
| d[2+] | Finger data   | Per-finger: X/Y (BE16 or LE16), ID, etc.   |

### BLE Battery Report – Report ID 0x0A (some models)
| Byte | Field         | Decode                                      |
|------|---------------|---------------------------------------------|
| d[0] | Report ID     | 0x0A                                        |
| d[1] | Battery level | 0–100 % (sometimes scaled differently)      |

### Wireless Dongle (PID 0x0084) – NOT Bluetooth
The sample hex you provided begins with **0x80** (WACOM_REPORT_WL).  
This is the **RF dongle** protocol (USB-connected ACK-40401), **not** native Bluetooth.  
It carries the tablet’s PID, connection state, and battery, then forwards the tablet’s own reports. The repeating “C0 …” pattern in your hex is the pen status byte from an IntuosV2 tablet behind the dongle.

**Dongle Report 0x80 (8–32 bytes)**
| Byte | Field              | Decode |
|------|--------------------|--------|
| d[0] | Report ID          | 0x80 |
| d[1] | Connection state   | Bit 0 = tablet connected |
| d[5] | Battery            | (d[5] & 0x3F) * 100 / 31; bit 7 = charging |
| d[6:7] | Tablet PID      | BE16 value (matches registry productID) |

**Summary**  
- BLE = separate short reports (0x01/0x03/0x05/0x0A) with **identical pen byte layout** to USB V2.  
- No single “wrapper” around the full 192-byte USB packet.  
- Only .intuosV2 devices in your registry use this BLE format.  
- Your example hex is a dongle-captured packet (0x80), not native BLE.

These are the exact byte-field decodes used by the Linux kernel and OpenTabletDriver for all Bluetooth-capable devices listed in the registry.

**Wacom Art Pen (KP-701E and similar variants)** is a special optional pen compatible with many Intuos4 / Intuos5 / Intuos Pro / Cintiq models in your registry (especially those using the `.intuosV1` or `.intuosV2` parser).

It adds **barrel rotation** (full 360° twist around the pen's long axis) in addition to the standard pressure, tilt (X/Y), tip, and barrel buttons. This makes decoding more complex than a standard Grip/Pro Pen.

### Why It Is Problematic
- Rotation data is only present when an **Art Pen** is detected (via tool ID).
- For non-Art Pens, the same byte field is either unused or repurposed, and the kernel/OpenTabletDriver must **suppress** or **offset** the rotation value to avoid spurious ABS_Z / twist events.
- The raw hardware value needs an offset (typically +90° or similar anti-clockwise adjustment) before reporting to userspace.
- Applications must explicitly support **HID_DG_TWIST** (or equivalent Wintab rotation) to use it for brush angle. Many older apps or non-Wintab paths ignore it.
- The pen is discontinued, so hardware is scarce, and full testing is limited.

### Detection: Is It an Art Pen?
The Linux kernel uses a helper:
- `wacom_is_art_pen()` checks the tool ID (from status byte or tool-change packet).
- Common Art Pen tool IDs appear in Intuos reports as specific values (e.g., in the 0x14802 / 0x204 ranges or equivalent in V1/V2 status).

Only when it is an Art Pen does the driver report rotation; otherwise, it skips or zeros it to prevent interference with normal pens.

### Report Byte Map for Art Pen (on IntuosV1 / IntuosV2 families)
Art Pen uses the **same base report format** as standard pens in the family (10-byte for V1, 192-byte USB or short BLE 0x01 for V2), with **extra rotation data** in higher bytes or a dedicated field.

**Typical additional / rotation field (IntuosV1-style reports, e.g., Intuos4/5/Pro first-gen):**
- Rotation is carried in a byte that would otherwise be reserved or part of extended tilt/aux on normal pens.
- Raw value is usually an 8-bit or 16-bit field representing 0–359° (or 0–1023 steps).
- Kernel applies `wacom_offset_rotation()`: clockwise from hardware becomes positive in userspace after a 90° anti-clockwise adjustment.

**For IntuosV2 / BLE (Report ID 0x10 USB or 0x01 BLE):**
- The pen payload is still largely identical to the standard V2 map you saw earlier.
- Rotation appears in bytes after tilt (often d[12] or d[13] as an 8-bit or signed value, or a 16-bit field).
- Exact offset varies slightly by generation, but the status byte (d[1]) still uses the same 0xC0 / 0x20 / 0x60 etc. masks for proximity/tip/barrel.
- When Art Pen is in use, an additional field provides the twist value.

**Status / Tool Byte (d[1] in V2 / equivalent in V1)**
Remains the same as standard IntuosV2 (0xC0 enter prox, 0x60 tip, 0x61 tip+stylus, 0x28 eraser, etc.).  
Tool ID detection happens in the proximity/enter-prox packet to identify Art Pen vs Grip Pen vs Airbrush vs Eraser.

### Proximity & Full State Logic for Art Pen
Same as standard V2:
- Enter prox: (d[1] & 0xFC) == 0xC0 → tool ID follows.
- Hover / tip / eraser states identical.
- Rotation is reported continuously while in proximity (even in hover), allowing live brush preview.

### BLE (HOGP) for Art Pen
On Bluetooth-enabled Intuos Pro / WL models:
- Pen report (0x01) carries the **same rotation field** as the USB V2 pen section.
- No change to the wrapper — rotation is embedded in the short pen report.
- Pad report (0x03) unchanged.

### Linux Kernel Handling Summary
- Rotation is mapped to **HID_DG_TWIST** (or ABS_Z with special handling).
- A recent patch ensures rotation is **only reported for Art Pen** to avoid polluting normal pen events with a constant non-zero value.
- Offset logic: Hardware rotation is adjusted (often +90° or -90°) so userspace sees consistent clockwise = positive.

### OpenTabletDriver Status
- OTD does **not** have full native support for barrel rotation/twist in its core report parsers yet (as of recent issues).
- It falls back to standard pressure/tilt for most pens.
- Art Pen works for basic functions (pressure, tilt, buttons) via the existing IntuosV1/V2 parsers, but the rotation axis is not plumbed through to applications as a separate "Twist" or "Rotation" input.
- Community requests exist to add twist support as plumbing (even if hardware is rare).

### Practical Notes for Your Registry / Decoder
- Art Pen is compatible with many devices using `.intuosV1` (Intuos4, Intuos5, Intuos Pro first-gen, many Cintiq) and `.intuosV2` (Intuos Pro second-gen, newer Cintiq).
- In your `WacomDeviceSpec`, no special flag exists yet — treat as standard pen but route through a rotation-aware decoder in Phase 2/3.
- To fully decode: detect Art Pen tool ID in the status/tool-change logic, then extract the rotation byte/field and apply the same offset the kernel uses.
- Feature init and seizeUSB rules remain the same as the base tablet family.

If you capture raw reports from an Art Pen on one of your confirmed-live devices (e.g., PTH-660, PTH-851, DTK-2400), the rotation field will appear as a varying value even when the pen is held still in tilt/pressure. That byte is the key differentiator.

The extra rotation makes Art Pen the most feature-rich Wacom pen in the registry-era devices, but it requires explicit tool-type checking to avoid breaking normal pen behavior.