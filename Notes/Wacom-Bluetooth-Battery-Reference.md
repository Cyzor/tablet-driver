2026-04-04

# Wacom Bluetooth Battery Report — Decode Reference

**Vendor ID (all Wacom HID):** `0x056a`  
**Primary source:** `linux/drivers/hid/wacom_wac.c` and `wacom_wac.h`, Linux kernel mainline

---

## Quick Reference

| Kernel Type | Commercial Name | Era | Report ID | Battery Offset | Decode | Charge Flag |
|---|---|---|---|---|---|---|
| `GRAPHIRE_BT` | Graphire Bluetooth (CTE-630BT) | 2005–2007 | `0x03` | `data[7]` bits 2:0 | Lookup `batcap_gr[]` | `data[7]` bit 4 |
| `INTUOS4WL` | Intuos4 WL (PTK-540WL) | 2010–2013 | `0x03` / `0x04` | `data[21]` or `data[31]` | Lookup `batcap_i4[]` | same byte bit 3 |
| `INTUOSP2_BT` | Intuos Pro M/L (PTH-660, PTH-860) | 2017–present | `0x80` / `0x81` | `data[284]` bits 6:0 | Direct % | bit 7 same byte |
| `INTUOSP2S_BT` | Intuos Pro S (PTH-460) | 2019–present | `0x80` / `0x81` | `data[284]` bits 6:0 | Direct % | bit 7 same byte |
| `INTUOSHT3_BT` | Intuos BT S/M (CTL-4100WL, CTL-6100WL) | 2018–present | `0x80` / `0x81` | `data[45]` bits 6:0 | Direct % | bit 7 same byte |
| USB dongle | Intuos5 / IntuosPro Gen1 / Bamboo wireless | 2011–2016 | `0x80` (WL), `0xC0` (USB) | `data[5]` / `data[8]` | `(val & 0x3F) × 100 / 31` | bit 7 same byte |

> **Protocol note:** All Wacom wireless tablet connections are **Bluetooth Classic HID**, not BLE. No standard GATT Battery Service (UUID `0x180F`) is exposed on the primary tablet interface.

---

## Lookup Tables

### `batcap_gr[]` — Graphire BT

Defined at `wacom_wac.c` line 81. A 3-bit index into 8 coarse steps.

```c
static unsigned short batcap_gr = { 1, 15, 25, 35, 50, 70, 100, 100 }; [support.wacom](https://support.wacom.com/hc/en-us/articles/15688460743319-How-to-see-the-battery-status-on-the-Wacom-One-Pen-Tablets)
```

| Index (`data[7] & 0x07`) | Reported % | Notes |
|---|---|---|
| 0 | 1% | Nearly dead |
| 1 | 15% | |
| 2 | 25% | |
| 3 | 35% | |
| 4 | 50% | |
| 5 | 70% | |
| 6 | 100% | |
| 7 | 100% | AC/charging implied |

---

### `batcap_i4[]` — Intuos4 WL

Defined at `wacom_wac.c` line 86. Also 3-bit, but finer steps.

```c
static unsigned short batcap_i4 = { 1, 15, 30, 45, 60, 70, 85, 100 }; [support.wacom](https://support.wacom.com/hc/en-us/articles/15688460743319-How-to-see-the-battery-status-on-the-Wacom-One-Pen-Tablets)
```

| Index (`power_raw & 0x07`) | Reported % |
|---|---|
| 0 | 1% |
| 1 | 15% |
| 2 | 30% |
| 3 | 45% |
| 4 | 60% |
| 5 | 70% |
| 6 | 85% |
| 7 | 100% |

---

## Per-Family Detail

### 1. Graphire BT — `GRAPHIRE_BT`

| productID | Model |
|---|---|
| `0x0081` | Graphire Bluetooth (CTE-630BT) |

**Report constants**

```
WACOM_REPORT_PENABLED_BT = 0x03
WACOM_PKGLEN_PENABLED    = 8 bytes
```

**Battery decode** (`wacom_graphire_irq()`, `wacom_wac.c` ≈ line 483)

```c
rw               = data & 0x07;            // bits 2:0 → 3-bit index [community.particle](https://community.particle.io/t/unable-to-make-bluetooth-gatt-connection-to-a-service/69549)
ps_connected     = (data & 0x10) ? 1 : 0; // bit 4 → external power [community.particle](https://community.particle.io/t/unable-to-make-bluetooth-gatt-connection-to-a-service/69549)
battery_capacity = batcap_gr[rw];
```

Index 7 maps to 100% and coincides with `ps_connected` being true.

---

### 2. Intuos4 WL — `INTUOS4WL`

| productID | Model |
|---|---|
| `0x00BD` | Intuos4 Wireless (PTK-540WL) |

**Report format** (`wacom_intuos_bt_irq()`, `wacom_wac.c` ≈ line 1203)

The handler accepts two report IDs carrying different payload sizes:

| Report ID | Total length | Pen blocks included | Battery byte index |
|---|---|---|---|
| `0x03` | 22 bytes | 2 | `data[21]` |
| `0x04` | 32 bytes | 3 | `data[31]` |

**Battery decode**

```c
power_raw        = data[i];                    // i = 21 or 31
bat_charging     = (power_raw & 0x08) ? 1 : 0; // bit 3
ps_connected     = (power_raw & 0x10) ? 1 : 0; // bit 4
battery_capacity = batcap_i4[power_raw & 0x07]; // bits 2:0
```

Charging and AC-present are separate flags, unlike Graphire.

---

### 3. Intuos Pro M/L Gen 2 — `INTUOSP2_BT`

| productID | Model |
|---|---|
| `0x0357` | Intuos Pro L USB (PTH-860) |
| `0x0358` | Intuos Pro L BT (PTH-860) |
| `0x0360` | Intuos Pro M USB/BT (PTH-660) |
| `0x0361` | Intuos Pro M BT alternate PID (PTH-660) |

**Report format** (`wacom_intuos_pro2_bt_irq()`, `wacom_wac.c` ≈ line 1541)

- Report IDs: `0x80` or `0x81` — handler discards anything else
- Packet length: **285 bytes**
- Layout: pen frames → touch frames → pad data → battery tail

**Battery decode** (`wacom_intuos_pro2_bt_battery()`, `wacom_wac.c` ≈ line 1503)

```c
bool chg        = data & 0x80;  // bit 7 → charging
int  bat_status = data & 0x7F;  // bits 6:0 → direct percentage (0–100)
```

No lookup table — value is already a percentage. This is a significant
protocol change from the 3-bit lookup used in earlier generations.

---

### 4. Intuos Pro S Gen 2 — `INTUOSP2S_BT`

| productID | Model |
|---|---|
| `0x035E` | Intuos Pro S USB (PTH-460) |
| `0x035F` | Intuos Pro S BT (PTH-460) |

Uses the same `wacom_intuos_pro2_bt_irq()` dispatcher and the same
`wacom_intuos_pro2_bt_battery()` function as `INTUOSP2_BT`.

**Battery decode** — identical:

```c
bool chg        = data & 0x80;
int  bat_status = data & 0x7F;
```

---

### 5. Intuos BT Consumer — `INTUOSHT3_BT`

| productID | Model |
|---|---|
| `0x0374` | Intuos BT S USB (CTL-4100WL) |
| `0x0375` | Intuos BT S BT (CTL-4100WL) |
| `0x0376` | Intuos BT M USB (CTL-6100WL) |
| `0x037B` | Intuos BT M BT (CTL-6100WL) |

Routes through the same `wacom_intuos_pro2_bt_irq()` dispatcher but
branches to `wacom_intuos_gen3_bt_battery()` because type is neither
`INTUOSP2_BT` nor `INTUOSP2S_BT`.

**Battery decode** (`wacom_intuos_gen3_bt_battery()`, `wacom_wac.c` ≈ line 1530)

```c
bool chg        = data & 0x80;  // bit 7 → charging [github](https://github.com/capn-damo/wacom-intuos-pro/blob/master/README.md)
int  bat_status = data & 0x7F;  // bits 6:0 → direct percentage (0–100) [github](https://github.com/capn-damo/wacom-intuos-pro/blob/master/README.md)
```

Same encoding as the Pro2 family, but battery is at byte **45**, not 284.
The report is simply smaller — no touch layer.

---

### 6. USB Wireless Dongle Path (proprietary RF, not BT Classic)

Tablets in this group use a 2.4 GHz USB receiver (`WACOM_REPORT_WL`).
This is **not Bluetooth**; it is included for completeness because it
appears in the same driver and is sometimes confused with BT operation.

Affected families: Intuos5 (PTK-x50), IntuosPro Gen 1 (PTH-x51),
Bamboo wireless, MobileStudio Pro.

**Two report paths exist:**

| Report | ID | Seen on | Battery byte | Decode formula |
|---|---|---|---|---|
| Wireless tablet | `WACOM_REPORT_WL` = `0x80` | Receiver HID interface | `data[5]` | `(data[5] & 0x3F) × 100 / 31` |
| USB status | `WACOM_REPORT_USB` = `0xC0` | Receiver USB interface | `data[8]` | `(data[8] & 0x3F) × 100 / 31` |

**Battery decode** (`wacom_wireless_irq()`, `wacom_wac.c` ≈ line 3392)

```c
battery  = (data & 0x3f) * 100 / 31;  // 6-bit linear: 31 raw = 100% [101.wacom](https://101.wacom.com/UserHelp/en/BatteryStatus_CC.htm)
charging = !!(data & 0x80);            // bit 7 [101.wacom](https://101.wacom.com/UserHelp/en/BatteryStatus_CC.htm)
```

The 6-bit field (0–63) is linearly scaled so that raw value 31 maps to
100%. Values above 31 saturate; in practice the hardware never reports
above 31.

---

## Reading Battery Without the Wacom Driver

### macOS (IOKit)

Open the HID device with `kIOHIDOptionsTypeSeizeDevice` (required for
exclusive raw access when the Wacom kext is not loaded). Register a
`IOHIDDeviceRegisterInputReportCallback` and filter by the report IDs
in the table above. The OS `IOKit` battery API returns nothing useful
for these devices without the full Wacom driver.

### Linux (no driver)

```bash
# Requires user to be in the 'input' group or run as root
hid-recorder /dev/hidrawN          # from hid-tools package

# Or raw hex dump:
cat /dev/hidrawN | xxd | head
```

### Python (`hidapi`)

```python
import hid

WACOM_VID = 0x056a

def read_battery(pid: int, report_len: int, batt_offset: int) -> None:
    dev = hid.device()
    dev.open(WACOM_VID, pid)
    dev.set_nonblocking(False)
    while True:
        data = dev.read(report_len)
        if data and data in (0x80, 0x81):
            pct = data[batt_offset] & 0x7F
            chg = bool(data[batt_offset] & 0x80)
            print(f"Battery: {pct}%  Charging: {chg}")

# Intuos Pro M (PTH-660)
read_battery(pid=0x0360, report_len=285, batt_offset=284)

# Intuos BT M (CTL-6100WL)
read_battery(pid=0x037B, report_len=46, batt_offset=45)
```

For the Graphire BT and Intuos4 WL you must apply the lookup tables
`batcap_gr[]` / `batcap_i4[]` to the 3-bit index instead of using the
direct-percentage path.

---

## Notes

- **No GATT Battery Service.** Because all Wacom tablet connections are
  Bluetooth Classic HID (not BLE), there is no UUID `0x180F` service
  and no characteristic `0x2A19` to query. Any BLE advertisement you
  see from an Intuos Pro (e.g., "LE IntuosPro M") is the Paper Mode
  accessory path (project Tuhi), not the tablet's drawing interface.

- **Report ID `0x81` vs. `0x80`.** The `wacom_intuos_pro2_bt_irq()`
  handler accepts both `0x80` and `0x81`. The kernel source treats them
  identically; the battery byte position is the same in both.

- **Percentage is a true 0–100 value** in Gen 2+ devices (7 bits).
  Wacom's desktop software may display this in coarser steps, but the
  underlying byte is a real percentage. Earlier generations (Graphire,
  Intuos4 WL) report only 8 discrete levels via the lookup tables.

- **Linux `power_supply` integration.** The kernel's `wacom_notify_battery()`
  publishes the decoded value to the `power_supply` subsystem, making
  it visible to `upower` and any UPower-aware desktop (GNOME, KDE,
  etc.) without extra code once the `hid-wacom` module is loaded.

---

*Source: `linux/drivers/hid/wacom_wac.c` and `linux/drivers/hid/wacom_wac.h`,*  
*Linux kernel mainline — verified April 2026.*