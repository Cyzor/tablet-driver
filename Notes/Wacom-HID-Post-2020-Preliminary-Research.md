2026-04-15

# Wacom Tablet Families & Byte Report Layouts
## Linux Kernel Driver Reference

**Source files:** [`drivers/hid/wacom_wac.c`](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_wac.c) · [`drivers/hid/wacom_wac.h`](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_wac.h) · [`drivers/hid/wacom_sys.c`](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_sys.c)

---

## Tablet Families

The enum in [`wacom_wac.h`](https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_wac.h) defines all supported families. Those beyond Intuosv1/v2/v3 and Bamboo:

| Family Constant | Products |
|---|---|
| `INTUOS5S` / `INTUOS5` / `INTUOS5L` | Intuos5 (USB) |
| `INTUOSPS` / `INTUOSPM` / `INTUOSPL` | Intuos Pro first gen (USB) |
| `INTUOSP2_BT` / `INTUOSP2S_BT` | Intuos Pro 2 M/L and S (Bluetooth) |
| `INTUOSHT` / `INTUOSHT2` | Consumer Intuos — CTL/CTH/CTE series (USB) |
| `INTUOSHT3_BT` | Intuos BT S/M — PIDs 0x377, 0x379, 0x3c6, 0x3c8 |
| `CINTIQ_HYBRID` / `CINTIQ_COMPANION_2` | Cintiq Companion and Companion 2 |
| `WACOM_24HD` / `WACOM_24HDT` | Cintiq 24HD / 24HD touch |
| `WACOM_27QHD` / `WACOM_27QHDT` | Cintiq 27QHD / 27QHD touch |
| `WACOM_21UX2` / `WACOM_22HD` / `WACOM_13HD` | Cintiq display tablets |
| `DTK` / `DTUS` / `DTUSX` | DTK/DTU pen display tablets |
| `REMOTE` | Express Key Remote (PID 0x331) |
| `BAMBOO_PAD` | Wireless/USB Bamboo Pad (PIDs 0x318, 0x319) |
| `HID_GENERIC` | All modern USB/I2C/BT/PCI devices via standard HID descriptors |
| `BOOTLOADER` | Bootloader mode (PID 0x94) |

---

## Byte Report Layouts — Newer Families

### `INTUOSP2_BT` / `INTUOSP2S_BT` — Intuos Pro 2 Bluetooth

**Report IDs:** `0x80` and `0x81`

Handler: `wacom_intuos_pro2_bt_irq()` → dispatches to pen, touch, pad, and battery sub-parsers.

The packet is a multi-frame container with three sections.

---

#### Pen Section — `wacom_intuos_pro2_bt_pen()`

**Serial and Tool ID location:**

| Bytes | Field | Applies To |
|---|---|---|
| `[99..106]` | Tool serial number (LE64) | `INTUOSP2_BT` only |
| `[107..108]` | Tool ID (LE16) | `INTUOSP2_BT` only |
| `[33..40]` | Tool serial number (LE64) | `INTUOSP2S_BT` / gen3 |
| `[41..42]` | Tool ID (LE16) | `INTUOSP2S_BT` / gen3 |

If `serial >> 52 == 1`, the device is a non-USI EMR pen and missing ID bits are recovered: `id |= (serial >> 32) & 0xFFFFF`.

**Frame layout — INTUOSP2_BT (7 frames × 14 bytes, starting at `data[1]`):**

| Frame byte offset | Field |
|---|---|
| `[0]` | Flags: bit7=valid, bit6=prox, bit5=range, bit4=invert, bit3+bit0=touch, bit1=barrel1, bit2=barrel2 |
| `[1..2]` | X (LE16) |
| `[3..4]` | Y (LE16) |
| `[5..6]` | Pressure (LE16) |
| `[7]` | Tilt X (signed byte) |
| `[8]` | Tilt Y (signed byte) |
| `[9..10]` | Rotation / ABS_Z (LE16); add 450, wrap at 900 for userspace alignment |
| `[11..12]` | ABS_WHEEL / fingerwheel (LE16) |
| `[13]` | Distance |

**Frame layout — INTUOSP2S_BT / gen3 (4 frames × 8 bytes, starting at `data[1]`):**

| Frame byte offset | Field |
|---|---|
| `[0]` | Flags: same bit layout as above |
| `[1..2]` | X (LE16) |
| `[3..4]` | Y (LE16) |
| `[5..6]` | Pressure (LE16) |
| `[7]` | Distance |

> No tilt, rotation, or fingerwheel fields in S/gen3 frames.

**Tool type resolution** (first frame in range):
- `frame[0] & 0x10` (invert set) → `BTN_TOOL_RUBBER`
- Tool ID non-zero → `wacom_intuos_get_tool_type(id)`
- Otherwise → `BTN_TOOL_PEN`

---

#### Touch Section — `wacom_intuos_pro2_bt_touch()` (`INTUOSP2_BT` only)

4 touch frames × 43 bytes each, starting at `data[109]`.  
Each frame contains up to 5 finger contacts × 8 bytes.

**Frame header (1 byte at frame offset `[0]`):**

| Bits | Field |
|---|---|
| bit7 | Frame valid |
| bits6:0 | Contact count (non-zero only in first frame of series) |

**Per-contact layout (8 bytes at `frame[j*8 + 1]`):**

| Contact byte offset | Field |
|---|---|
| `[0]` | Contact ID |
| `[1]` | bit0 = touch active |
| `[2..3]` | X (LE16) |
| `[4..5]` | Y (LE16) |
| `[6]` | Width (multiplied by X resolution for ABS_MT_TOUCH_MAJOR/MINOR) |
| `[7]` | Height (multiplied by Y resolution) |

**Touch mute switch:** `data[281] >> 7` (0 = muted; reported as `SW_MUTE_DEVICE`)

---

#### Pad Section — `wacom_intuos_pro2_bt_pad()` (`INTUOSP2_BT` only)

| Byte | Field |
|---|---|
| `data[281]` | bit7 = touch mute switch; bit6 = center button |
| `data[282]` | Express key buttons (bitmask, count = `features.numbered_buttons`) |
| `data[285]` | bit7 = ring active; bits6:0 = raw ring value (0–71, inverted and offset for userspace: `ring = 71 - ring + 13; if > 71: ring -= 72`) |

---

#### Battery Section — `wacom_intuos_pro2_bt_battery()` (`INTUOSP2_BT` only)

| Byte | Field |
|---|---|
| `data[284]` | bit7 = charging; bits6:0 = battery level (0–100) |

---

### `INTUOSHT3_BT` — Intuos BT S/M (gen3 Bluetooth)

Uses the same `wacom_intuos_pro2_bt_irq()` entry point but the `else` branch:

- Pen: 4 frames × 8 bytes (the S/gen3 layout above)
- Serial at `data[33..40]`, Tool ID at `data[41..42]`
- No touch section
- Pad: `wacom_intuos_gen3_bt_pad()` — `data[44]` is a 4-button bitmask
- Battery: `wacom_intuos_gen3_bt_battery()` — `data[45]` bit7=charging, bits6:0=level

---

### `INTUOSHT` / `INTUOSHT2` — Consumer Intuos (USB)

Pen handling routes through the shared `wacom_intuos_irq()` → `wacom_intuos_inout()` + `wacom_intuos_general()` path (same handlers as Intuos5 / Intuos Pro gen1).

- Report IDs: `WACOM_REPORT_PENABLED` (2), `WACOM_REPORT_CINTIQ` (16), `WACOM_REPORT_INTUOS_PEN` (16)
- Pad reports: `WACOM_REPORT_INTUOSPAD` (12) or `WACOM_REPORT_INTUOS5PAD` (3)
- `INTUOSHT2` adds report ID 8 (`WACOM_REPORT_INTUOSHT2_ID`) for proximity scheduling via `wacom_intuos_schedule_prox_event()`
- Byte layout within `wacom_intuos_general()` is identical to Intuos5 — see Intuosv3 documentation

---

### `INTUOS5S` / `INTUOS5` / `INTUOS5L` / `INTUOSPS` / `INTUOSPM` / `INTUOSPL` — Intuos5 & Intuos Pro gen1 (USB)

These share the `wacom_intuos_irq()` path with the classic Intuos families. The pen general report layout (`wacom_intuos_general()`, report ID 16 or 2):

| Bytes | Field |
|---|---|
| `[0]` | Report ID |
| `[1]` | Flags: bit7=prox (via inout), bits3:1=frame type |
| `[2..3]` | X, upper bits; combined with `data[9]` bit1 for full precision: `(BE16 << 1) \| (data[9] >> 1 & 1)` |
| `[4..5]` | Y, upper bits; combined with `data[9]` bit0 |
| `[9] >> 2` | Distance (bits7:2) |
| `[6]` | Pressure high byte (combined with `data[7]` bits7:6 and `data[1]` bit0 for 10- or 11-bit value) |
| `[7..8]` | Tilt X/Y (each offset −64 from raw) |
| `[1] & 0x02` | Barrel switch 1 |
| `[1] & 0x04` | Barrel switch 2 |

Pad report (`WACOM_REPORT_INTUOS5PAD`, report ID 3), layout varies by model:

| Model | Buttons source | Ring source |
|---|---|---|
| INTUOS5S / INTUOSPS | `data[6]` (6 buttons) | — |
| INTUOS5 / INTUOSPM | `(data[8] << 8) \| data[6]` | ring1=`data[1]`, ring2=`data[2]` |
| INTUOS5L / INTUOSPL | `(data[8] << 8) \| data[6]` + strips | strip1=`((data[1]&0x1f)<<8)\|data[2]`, strip2=`((data[3]&0x1f)<<8)\|data[4]` |

---

### `DTUS` / `DTUSX` — DTU-S Display Tablets

Handler: `wacom_dtus_irq()`, report IDs `WACOM_REPORT_DTUS` (17) and `WACOM_REPORT_DTUSPAD` (21).

**Pad report (ID 21):**

| Byte | Field |
|---|---|
| `data[1]` | bits3:0 = buttons 0–3 (BTN_0 through BTN_3) |

**Pen report (ID 17):**

| Byte | Field |
|---|---|
| `data[1]` | bit7=prox; bits4:3=tool type; bit5=barrel1; bit6=barrel2; bits1:0=pressure high bits |
| `data[2]` | Pressure low byte (combined with `data[1]` bits1:0 for 10-bit value) |
| `data[3..4]` | X (BE16) |
| `data[5..6]` | Y (BE16) |

---

### `REMOTE` — Express Key Remote (PID 0x331)

Handler: `wacom_remote_irq()`, report ID `WACOM_REPORT_REMOTE` (17).

Supports up to `WACOM_MAX_REMOTES` (5) simultaneous remotes. Button mapping is handled by `wacom_remote_status_irq()` which reconciles serial numbers against the known remote list. Byte layout is not fully commented in-source; the driver reads buttons and ring values through indexed report fields rather than hardcoded byte offsets.

---

## `HID_GENERIC` — Modern Devices (No Hardcoded Byte Layout)

Devices matched as `HID_GENERIC` — including Cintiq Pro, MobileStudio Pro, One by Wacom (USB-C), and all I2C bus (built-in) tablets — have **no hardcoded byte layout** in the driver. The driver uses the device's HID report descriptor to map fields dynamically via `wacom_wac_pen_usage_mapping()`.

### Recognized Vendor-Defined Usages (Usage Page `0xff0d`)

| Usage ID | Constant | Meaning |
|---|---|---|
| `0xff0d0001` | `WACOM_HID_WD_DIGITIZER` | Digitizer application |
| `0xff0d0002` | `WACOM_HID_WD_PEN` | Pen application |
| `0xff0d0036` | `WACOM_HID_WD_SENSE` | Proximity sense (maps to `BTN_TOOL_PEN`); presence enables `WACOM_QUIRK_SENSE` |
| `0xff0d0039` | `WACOM_HID_WD_DIGITIZERFNKEYS` | Physical = pad function keys |
| `0xff0d005b` | `WACOM_HID_WD_SERIALNUMBER` | Tool serial (lower 32 bits) |
| `0xff0d005c` | `WACOM_HID_WD_SERIALHI` | Tool serial upper 32 bits; if `value >> 20 == 1`, also OR's low 20 bits into tool ID |
| `0xff0d005d` | `WACOM_HID_WD_BARRELSWITCH3` | Third barrel button (`BTN_STYLUS3`) |
| `0xff0d0077` | `WACOM_HID_WD_TOOLTYPE` | Tool type ID, OR'd incrementally across events |
| `0xff0d0132` | `WACOM_HID_WD_DISTANCE` | Distance (maps to `ABS_DISTANCE`) |
| `0xff0d0136` | `WACOM_HID_WD_TOUCHSTRIP` | Touch strip 1 |
| `0xff0d0137` | `WACOM_HID_WD_TOUCHSTRIP2` | Touch strip 2 |
| `0xff0d0138` | `WACOM_HID_WD_TOUCHRING` | Touch ring |
| `0xff0d0139` | `WACOM_HID_WD_TOUCHRINGSTATUS` | Touch ring active status |
| `0xff0d01d0` | `WACOM_HID_WD_REPORT_VALID` | Frame validity flag; `0` causes the entire report to be discarded |
| `0xff0d0220` | `WACOM_HID_WD_SEQUENCENUMBER` | Packet sequence number; driver logs dropped packet count on gaps |
| `0xff0d0454` | `WACOM_HID_WD_TOUCHONOFF` | Touch enable/disable |
| `0xff0d0910` | `WACOM_HID_WD_EXPRESSKEY00` | Express key base usage |
| `0xff0d0980` | `WACOM_HID_WD_MODE_CHANGE` | Mode change |
| `0xff0d0981` | `WACOM_HID_WD_MUTE_DEVICE` | Mute touch |
| `0xff0d0d03` | `WACOM_HID_WD_FINGERWHEEL` | Airbrush fingerwheel (maps to `ABS_WHEEL`; enables `BTN_TOOL_AIRBRUSH`) |
| `0xff0d0d30..33` | `WACOM_HID_WD_OFFSET*` | Active area offsets (left/top/right/bottom) read from descriptor |
| `0xff0d1002` | `WACOM_HID_WD_DATAMODE` | Data mode |
| `0xff0d1013` | `WACOM_HID_WD_DIGITIZERINFO` | Physical = digitizer info |
| `0xff0d1032` | `WACOM_HID_WD_TOUCH_RING_SETTING` | Touch ring mode setting |

### AES vs. EMR Detection

The `WACOM_QUIRK_AESPEN` flag is set at probe time (`wacom_sys.c`) when the device uses the AES (Active Electrostatic) protocol. AES pens use `WACOM_HID_WD_SENSE` for proximity rather than `HID_DG_INRANGE`. EMR pens use `HID_DG_INRANGE`.

### Obtaining Byte Layouts for HID_GENERIC Devices

For any device using `HID_GENERIC`, the authoritative byte layout lives in the device's own HID report descriptor. Retrieval methods:

- **Linux:** `hid-recorder` (from `hid-tools`) or read raw from `/dev/hidraw*`
- **macOS:** Parse `IOHIDDeviceGetProperty(device, CFSTR(kIOHIDReportDescriptorKey))`

---

## Packet Length Constants (`wacom_wac.h`)

| Constant | Value | Used For |
|---|---|---|
| `WACOM_PKGLEN_BBFUN` | 9 | Bamboo Fun |
| `WACOM_PKGLEN_TPC1FG` | 5 | TabletPC single-finger touch |
| `WACOM_PKGLEN_TPC1FG_B` | 10 | TabletPC single-finger touch variant B |
| `WACOM_PKGLEN_TPC2FG` | 14 | TabletPC two-finger touch |
| `WACOM_PKGLEN_BBTOUCH` | 20 | Bamboo touch (low-res) |
| `WACOM_PKGLEN_BBTOUCH3` | 64 | Bamboo touch (full) |
| `WACOM_PKGLEN_BBPEN` | 10 | Bamboo pen |
| `WACOM_PKGLEN_WIRELESS` | 32 | Wireless receiver dongle |
| `WACOM_PKGLEN_PENABLED` | 8 | Generic pen-enabled |
| `WACOM_PKGLEN_BPAD_TOUCH` | 32 | Bamboo Pad touch |
| `WACOM_PKGLEN_BPAD_TOUCH_USB` | 64 | Bamboo Pad touch (USB) |
| `WACOM_BYTES_PER_MT_PACKET` | 11 | MT contact data |
| `WACOM_BYTES_PER_24HDT_PACKET` | 14 | 24HD touch contact data |
| `WACOM_BYTES_PER_QHDTHID_PACKET` | 6 | 27QHD touch HID contact data |

---

## Report ID Constants (`wacom_wac.h`)

| Constant | Value | Description |
|---|---|---|
| `WACOM_REPORT_PENABLED` | 2 | Standard pen report |
| `WACOM_REPORT_PENABLED_BT` | 3 | Bluetooth pen report |
| `WACOM_REPORT_INTUOS_ID1` | 5 | Intuos tool ID frame 1 |
| `WACOM_REPORT_INTUOS_ID2` | 6 | Intuos tool ID frame 2 |
| `WACOM_REPORT_INTUOSPAD` | 12 | Intuos pad |
| `WACOM_REPORT_INTUOS5PAD` | 3 | Intuos5/Pro pad |
| `WACOM_REPORT_DTUSPAD` | 21 | DTUS pad |
| `WACOM_REPORT_TPC1FG` | 6 | TabletPC 1-finger |
| `WACOM_REPORT_TPC2FG` | 13 | TabletPC 2-finger |
| `WACOM_REPORT_TPCMT` | 13 | TabletPC MT |
| `WACOM_REPORT_TPCMT2` | 3 | TabletPC MT variant 2 |
| `WACOM_REPORT_TPCHID` | 15 | TabletPC HID |
| `WACOM_REPORT_CINTIQ` | 16 | Cintiq pen |
| `WACOM_REPORT_CINTIQPAD` | 17 | Cintiq pad |
| `WACOM_REPORT_TPCST` | 16 | TabletPC single-touch |
| `WACOM_REPORT_DTUS` | 17 | DTUS pen |
| `WACOM_REPORT_TPC1FGE` | 18 | TabletPC 1-finger extended |
| `WACOM_REPORT_24HDT` | 1 | 24HD touch |
| `WACOM_REPORT_WL` | 128 | Wireless (0x80) |
| `WACOM_REPORT_USB` | 192 | USB status (0xC0) |
| `WACOM_REPORT_BPAD_PEN` | 3 | Bamboo Pad pen |
| `WACOM_REPORT_BPAD_TOUCH` | 16 | Bamboo Pad touch |
| `WACOM_REPORT_INTUOS_PEN` | 16 | Intuos pen (shared with Cintiq) |
| `WACOM_REPORT_REMOTE` | 17 | Express Key Remote |
| `WACOM_REPORT_INTUOSHT2_ID` | 8 | INTUOSHT2 proximity scheduling |

---

*Generated from Linux kernel master branch, April 2026.*  
*Primary source: https://github.com/torvalds/linux/tree/master/drivers/hid*
