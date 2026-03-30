2026-03-30

**USB Interface Map** (verbatim from kernel `struct wacom_features`)

**Graphire / PenPartner / Volito family**  
`static const struct wacom_features wacom_features_0x00 = { "Wacom Penpartner", 5040, 3780, 255, 0, PENPARTNER, WACOM_PENPRTN_RES, WACOM_PENPRTN_RES };`  
`static const struct wacom_features wacom_features_0x10 = { "Wacom Graphire", 10206, 7422, 511, 63, GRAPHIRE, WACOM_GRAPHIRE_RES, WACOM_GRAPHIRE_RES };`  
`static const struct wacom_features wacom_features_0x11 = { "Wacom Graphire2 4x5", 10206, 7422, 511, 63, GRAPHIRE, WACOM_GRAPHIRE_RES, WACOM_GRAPHIRE_RES };`  
`static const struct wacom_features wacom_features_0x12 = { "Wacom Graphire2 5x7", 13918, 10206, 511, 63, GRAPHIRE, WACOM_GRAPHIRE_RES, WACOM_GRAPHIRE_RES };`  
`static const struct wacom_features wacom_features_0x13 = { "Wacom Graphire3", 10208, 7424, 511, 63, GRAPHIRE, WACOM_GRAPHIRE_RES, WACOM_GRAPHIRE_RES };`  
`static const struct wacom_features wacom_features_0x14 = { "Wacom Graphire3 6x8", 16704, 12064, 511, 63, GRAPHIRE, WACOM_GRAPHIRE_RES, WACOM_GRAPHIRE_RES };`  
`static const struct wacom_features wacom_features_0x15 = { "Wacom Graphire4 4x5", 10208, 7424, 511, 63, WACOM_G4, WACOM_GRAPHIRE_RES, WACOM_GRAPHIRE_RES };`  
`static const struct wacom_features wacom_features_0x16 = { "Wacom Graphire4 6x8", 16704, 12064, 511, 63, WACOM_G4, WACOM_GRAPHIRE_RES, WACOM_GRAPHIRE_RES };`  
`static const struct wacom_features wacom_features_0x17 = { "Wacom BambooFun 4x5", 14760, 9225, 511, 63, WACOM_MO, WACOM_INTUOS_RES, WACOM_INTUOS_RES };`  
`static const struct wacom_features wacom_features_0x60 = { "Wacom Volito", 5104, 3712, 511, 63, GRAPHIRE, WACOM_VOLITO_RES, WACOM_VOLITO_RES };`  
`static const struct wacom_features wacom_features_0x65 = { "Wacom Bamboo", 14760, 9225, 511, 63, WACOM_MO, WACOM_INTUOS_RES, WACOM_INTUOS_RES };`

**Intuos 1 / 2 family**  
`static const struct wacom_features wacom_features_0x20 = { "Wacom Intuos 4x5", 12700, 10600, 1023, 31, INTUOS, WACOM_INTUOS_RES, WACOM_INTUOS_RES };`  
`static const struct wacom_features wacom_features_0x21 = { "Wacom Intuos 6x8", 20320, 16240, 1023, 31, INTUOS, WACOM_INTUOS_RES, WACOM_INTUOS_RES };`  
`static const struct wacom_features wacom_features_0x22 = { "Wacom Intuos 9x12", 30480, 24060, 1023, 31, INTUOS, WACOM_INTUOS_RES, WACOM_INTUOS_RES };`  
`static const struct wacom_features wacom_features_0x23 = { "Wacom Intuos 12x12", 30480, 31680, 1023, 31, INTUOS, WACOM_INTUOS_RES, WACOM_INTUOS_RES };`  
`static const struct wacom_features wacom_features_0x24 = { "Wacom Intuos 12x18", 45720, 31680, 1023, 31, INTUOS, WACOM_INTUOS_RES, WACOM_INTUOS_RES };`  
`static const struct wacom_features wacom_features_0x41 = { "Wacom Intuos2 4x5", 12700, 10600, 1023, 31, INTUOS, WACOM_INTUOS_RES, WACOM_INTUOS_RES };`  
`static const struct wacom_features wacom_features_0x42 = { "Wacom Intuos2 6x8", 20320, 16240, 1023, 31, INTUOS, WACOM_INTUOS_RES, WACOM_INTUOS_RES };`  
`static const struct wacom_features wacom_features_0x43 = { "Wacom Intuos2 9x12", 30480, 24060, 1023, 31, INTUOS, WACOM_INTUOS_RES, WACOM_INTUOS_RES };`  
`static const struct wacom_features wacom_features_0x44 = { "Wacom Intuos2 12x12", 30480, 31680, 1023, 31, INTUOS, WACOM_INTUOS_RES, WACOM_INTUOS_RES };`  
`static const struct wacom_features wacom_features_0x45 = { "Wacom Intuos2 12x18", 45720, 31680, 1023, 31, INTUOS, WACOM_INTUOS_RES, WACOM_INTUOS_RES };`

**Intuos3 family**  
`static const struct wacom_features wacom_features_0xB0 = { "Wacom Intuos3 4x5", 25400, 20320, 1023, 63, INTUOS3S, WACOM_INTUOS3_RES, WACOM_INTUOS3_RES, 4 };`  
`static const struct wacom_features wacom_features_0xB1 = { "Wacom Intuos3 6x8", 40640, 30480, 1023, 63, INTUOS3, WACOM_INTUOS3_RES, WACOM_INTUOS3_RES, 8 };`  
`static const struct wacom_features wacom_features_0xB2 = { "Wacom Intuos3 9x12", 60960, 45720, 1023, 63, INTUOS3, WACOM_INTUOS3_RES, WACOM_INTUOS3_RES, 8 };`  
`static const struct wacom_features wacom_features_0xB3 = { "Wacom Intuos3 12x12", 60960, 60960, 1023, 63, INTUOS3L, WACOM_INTUOS3_RES, WACOM_INTUOS3_RES, 8 };`  
`static const struct wacom_features wacom_features_0xB4 = { "Wacom Intuos3 12x19", 97536, 60960, 1023, 63, INTUOS3L, WACOM_INTUOS3_RES, WACOM_INTUOS3_RES, 8 };`  
`static const struct wacom_features wacom_features_0xB5 = { "Wacom Intuos3 6x11", 54204, 31750, 1023, 63, INTUOS3, WACOM_INTUOS3_RES, WACOM_INTUOS3_RES, 8 };`  
`static const struct wacom_features wacom_features_0xB7 = { "Wacom Intuos3 4x6", 31496, 19685, 1023, 63, INTUOS3S, WACOM_INTUOS3_RES, WACOM_INTUOS3_RES, 4 };`

**Intuos4 / Intuos5 / Intuos Pro first-gen / Cintiq**  
`static const struct wacom_features wacom_features_0xB8 = { "Wacom Intuos4 4x6", 31496, 19685, 2047, 63, INTUOS4S, WACOM_INTUOS3_RES, WACOM_INTUOS3_RES, 7 };`  
`static const struct wacom_features wacom_features_0xB9 = { "Wacom Intuos4 6x9", 44704, 27940, 2047, 63, INTUOS4, WACOM_INTUOS3_RES, WACOM_INTUOS3_RES, 9 };`  
`static const struct wacom_features wacom_features_0x26 = { "Wacom Intuos5 touch S", 31496, 19685, 2047, 63, INTUOS5S, WACOM_INTUOS3_RES, WACOM_INTUOS3_RES, 7, .touch_max = 16 };`  
`static const struct wacom_features wacom_features_0x314 = { "Wacom Intuos Pro S", 31496, 19685, 2047, 63, INTUOSPS, WACOM_INTUOS3_RES, WACOM_INTUOS3_RES, 7, .touch_max = 16, .check_for_hid_type = true, .hid_type = HID_TYPE_USBNONE };`  
`static const struct wacom_features wacom_features_0x317 = { "Wacom Intuos Pro L", 65024, 40640, 2047, 63, INTUOSPL, WACOM_INTUOS3_RES, WACOM_INTUOS3_RES, 9, .touch_max = 16, .check_for_hid_type = true, .hid_type = HID_TYPE_USBNONE };`  
`static const struct wacom_features wacom_features_0xF4 = { "Wacom Cintiq 24HD", 104480, 65600, 2047, 63, WACOM_24HD, WACOM_INTUOS3_RES, WACOM_INTUOS3_RES, 16, WACOM_CINTIQ_OFFSET, WACOM_CINTIQ_OFFSET, WACOM_CINTIQ_OFFSET, WACOM_CINTIQ_OFFSET };`

**Intuos Pro second-gen**  
(Features use INTUOSHT / INTUOSHT2 types with 192-byte reports; exact struct entries for 0x0352/0x0357/0x0358 map to same coordinate/pressure ranges as registry.)

**Bamboo / CTL / CTH family**  
(Features use WACOM_MO or GRAPHIRE types with 20-byte or 16-byte touch packets.)

**All Pen Packet Types**  
`static int wacom_graphire_irq(...)` (Report ID 0x01 / WACOM_REPORT_PENABLED or 0x03 for BT)  
`static int wacom_pl_irq(...)` (Report ID 0x01 / WACOM_REPORT_PENABLED)  
`static int wacom_ptu_irq(...)` (Report ID 0x01 / WACOM_REPORT_PENABLED)  
`static int wacom_dtu_irq(...)` (Report ID 0x01 / WACOM_REPORT_PENABLED)

**Bluetooth Packet Structure**  
`#define WACOM_REPORT_PENABLED_BT 3`  
Graphire BT uses same pen payload as USB but with GRAPHIRE_BT type.

**Wireless Dongle (ACK-40401, PID 0x0084)**  
```c
#define WACOM_REPORT_WL 0x80
#define WACOM_PKGLEN_WIRELESS 8
```
| Byte | Field              | Decode |
|------|--------------------|--------|
| d[0] | Report ID          | WACOM_REPORT_WL |
| d[1] | Connection state   | d[1] & 0x01 → tablet connected |
| d[5] | Battery            | (d[5] & 0x3F) * 100 / 31 → percent; d[5] & 0x80 → charging |
| d[6]:d[7] | Tablet PID    | BE16(d[6]:d[7]) |
| d[2..4], d[8..31] | Reserved | (unused) |

**Frame Status Byte f[0]**  
(No standalone “f[0]” definition; status is always data[1] in pen reports.)

**Full Pad Byte Map** (Bamboo touch)  
`static int wacom_bamboo_pad_touch_event(...)`  
```c
prefix = data[0];
for (id = 0; id < touch_max; id++) {
    finger_data = data + 1 + id * 3;
    x = finger_data[0] | ((finger_data[1] & 0x0f) << 8);
    y = (finger_data[2] << 4) | (finger_data[1] >> 4);
}
input_report_key(..., BTN_LEFT, prefix & 0x40);
input_report_key(..., BTN_RIGHT, prefix & 0x80);
```

**Pen Report Byte Map (USB) — Graphire family**  
| Byte | Field | Decode |
|------|-------|--------|
| d[0] | Report ID | 0x01 |
| d[1] | Status / Prox / Tool | prox = d[1] & 0x80; tool = (d[1] >> 5) & 3 |
| d[2:3] | X | le16_to_cpup(&data[2]) |
| d[4:5] | Y | le16_to_cpup(&data[4]) |
| d[6] | Pressure low | — |
| d[7] | Pressure high / aux | pressure = d[6] \| ((d[7] & 0x03) << 8) (non-BT) |

**Pen Report Byte Map (USB) — IntuosV1 family (pl_irq)**  
| Byte | Field | Decode |
|------|-------|--------|
| d[0] | Report ID | 0x01 |
| d[1] | Status | prox = d[1] & 0x40 |
| d[2] | X mid | — |
| d[3] | X low | X = d[3] \| (d[2] << 7) \| ((d[1] & 0x03) << 14) |
| d[4] | Y / pressure bits | — |
| d[5] | Y mid | — |
| d[6] | Y low | Y = d[6] \| (d[5] << 7) \| ((d[4] & 0x03) << 14) |
| d[7] | Pressure base | pressure = (signed char)((d[7] << 1) \| ((d[4] >> 2) & 1)); if (pressure_max > 255) pressure = (pressure << 1) \| ((d[4] >> 6) & 1) |

**Pen Report Byte Map (USB) — IntuosV1 family (ptu_irq / dtu_irq)**  
| Byte | Field | Decode |
|------|-------|--------|
| d[0] | Report ID | 0x01 |
| d[1] | Status | tool = (d[1] & 0x04) ? rubber : pen; prox = d[1] & 0x20 (dtu) |
| d[2:3] | X | le16_to_cpup(&data[2]) |
| d[4:5] | Y | le16_to_cpup(&data[4]) |
| d[6:7] | Pressure | le16_to_cpup(&data[6]) (ptu); ((d[7] & 0x01) << 8) \| d[6] (dtu) |

**Pen Report Byte Map (USB) — IntuosV2 family (192-byte, Report ID 0x10)**  
| Byte(s) | Field | Decode |
|---------|-------|--------|
| d[1] | Status byte | (see table below) |
| d[2:4] | X | LE24: d[2] \| (d[3] << 8) \| (d[4] << 16) |
| d[5:7] | Y | LE24: d[5] \| (d[6] << 8) \| (d[7] << 16) |
| d[8:9] | Pressure | d[8] \| ((d[9] & 0x1F) << 8) — 13-bit |
| d[10] | Tilt X | (signed char)d[10] |
| d[11] | Tilt Y | (signed char)d[11] |

**Proximity State Logic (per frame) — IntuosV1 (pl_irq)**  
prox = data[1] & 0x40  
if (!wacom->id[0]) { tool = ((data[0] & 0x10) \| (data[4] & 0x20)) ? eraser : pen }  
if (eraser && !(data[4] & 0x20)) force pen  
if (prox) report data  
if (!prox) wacom->id[0] = 0  
report tool active only while prox true

**USB d[1] Status Byte — IntuosV1 (pl_irq)**  
prox = d[1] & 0x40  
eraser = (d[0] & 0x10) \| (d[4] & 0x20)  
BTN_TOUCH = d[4] & 0x08  
BTN_STYLUS = d[4] & 0x10  
BTN_STYLUS2 = (pen && (d[4] & 0x20))

**Status Byte (d[1]) — IntuosV2**  
| d[1] value / Mask | State |
|-------------------|-------|
| (d[1] & 0xFC) == 0xC0 | Enter prox (tool ID follows) |
| 0x20 / 0x21 | Hover / in range |
| 0x25 | Hover + BTN_STYLUS2 |
| 0x60 | Tip touching |
| 0x61 | Tip + BTN_STYLUS |
| 0x65 | Tip + BTN_STYLUS2 |
| 0x28 | Eraser hover |
| 0x68 | Eraser touching |
| 0x80 | Exit prox |
| d[1] & 0x02 | BTN_STYLUS |
| d[1] & 0x04 | BTN_STYLUS2 |
| d[1] & 0x01 | BTN_TOUCH |

**USB Pad Report 0x11 / Intuos3 aux**  
Intuos3 aux reports use IDs 0x03 and 0x0C (8-key and split 4+4).  
Bamboo touch uses Report 0x80 (WACOM_REPORT_BPAD_TOUCH) with the pad byte map above.