2026-07-03

## Wacom USB Product ID 0x033E — CTH-690 Intuos Art (M)

USB VID/PID **056A:033E** maps to the **Wacom CTH-690**, marketed as the **Intuos Art (Medium)** — a 2015-generation pen-and-touch graphics tablet. The "CTH" prefix in Wacom's model numbering scheme signals a tablet with **both pen and touch** capability (C = consumer line, T = touch, H = generation/variant), in contrast to the pen-only CTL-690 (Intuos Draw) that shares the same chassis.[^1][^2]

***

## Device Specifications

| Parameter | Value |
| :-- | :-- |
| **Model** | CTH-690 (Black: CTH-690AK, Blue: CTH-690AB/B0) |
| **Marketing Name** | Intuos Art / Intuos Comic (Medium) |
| **Active Area** | 216 × 135 mm (8.5 × 5.3 in) |
| **Physical Dimensions** | 375 × 220 × 10 mm |
| **Input Resolution** | 2540 lpi (0.01 mm) |
| **Pen Sampling Rate** | 133 pps |
| **Pen Pressure Levels** | 2048 (some regional SKUs documented as 1024; hardware was the same) |
| **Pen Model** | LP-190K (no eraser end; 1 side button) |
| **ExpressKeys** | 4 customizable |
| **Multi-Touch** | Yes — 16-point finger touch |
| **Touch Switch** | Hardware toggle (corner slide switch) |
| **Connectivity** | USB 2.0 (1.0 m cable); optional wireless via ACK-40401 |
| **Weight** | 480 ±50 g |
| **OS Support** | Windows 7/8/10, macOS 10.8.5+ |

[^3][^4][^5]

***

## USB Identity and Driver Classification

The full USB identifier is **VID 056A (Wacom Co., Ltd.) / PID 033E**. The Linux kernel's `input-wacom` driver assigns this device to the **`INTUOSHT2`** feature type — the **second-generation Intuos HT** family:[^2][^6][^1]

```c
static const struct wacom_features wacom_features_0x33E =
    { "Wacom Intuos PT M 2", 21600, 13500, 2047, 63,
      INTUOSHT2, WACOM_INTUOS_RES, WACOM_INTUOS_RES, .touch_max = 16,
      .check_for_hid_type = true, .hid_type = HID_TYPE_USBNONE };
```

The `INTUOSHT2` type distinguishes this device from the earlier CTH-680 (`INTUOSHT`, PID 0x0303), which also had 16-finger touch but used the first-generation HT protocol. The **`WACOM_INTUOS_RES`** constant (100 units/mm in both axes) sets the logical coordinate resolution. The coordinate space is 21600 × 13500 native units, mapping to the 216 × 135 mm physical active area.[^7][^6]

The `.check_for_hid_type = true, .hid_type = HID_TYPE_USBNONE` flags direct the kernel to **skip standard HID processing** for this device; the wacom driver intercepts all USB packets itself and interprets them using Wacom's proprietary packet format rather than the HID descriptor.[^8][^6]

The libwacom database entry (used by GNOME Control Center and related tools) classifies the device in the **`Bamboo`** class, reflecting the lineage from the Bamboo Pen \& Touch series :

```ini
[Device]
Name=Intuos Pen & Touch Medium
ModelName=CTH-690
DeviceMatch=usb|056a|033e
Class=Bamboo

[Features]
Stylus=true
Touch=true
TouchSwitch=true
```

Linux kernel support landed in **kernel 4.4**, and the `input-wacom` out-of-tree driver extends support back to **kernel 2.6.30** (with the touch arbitration caveat requiring 2.6.38+).[^2]

***

## Touch Protocol and Behavior

### Packet Routing

The CTH-690 presents a **single USB HID interface** that multiplexes pen, touch, and pad (ExpressKey) reports. The kernel driver routes incoming packets via `wacom_bpt_irq()`, which dispatches them based on report length and type:[^6]

- **Pen packets** (INTUOSHT2 pen device): routed to `wacom_intuos_irq()`, using the standard Intuos packet format
- **Touch packets** (`WACOM_PKGLEN_BBTOUCH3`): routed to `wacom_bpt3_touch()`
- **Status/USB packets** (`WACOM_REPORT_USB`): routed to `wacom_status_irq()`


### Touch Multitouch Protocol (BPT3 Touch)

The CTH-690 reports up to **16 simultaneous touch contacts** using a proprietary "BPT3" packet format (report ID `0x02`). The packet structure per finger slot is:[^6]


| Byte | Content |
| :-- | :-- |
| `data[^0]` | Slot key (finger ID for `input_mt_get_slot_by_key`) |
| `data[^1]` | Bit 7 = touch active flag |
| `data[^2]`, `data[^4]>>4` | X position (12-bit value) |
| `data[^3]`, `data[^4]&0x0F` | Y position (12-bit value) |
| `data[^5]` | Touch width (scaled ×100 for INTUOSHT/INTUOSHT2) |
| `data[^6]` | Touch height (scaled ×100 for INTUOSHT/INTUOSHT2) |

[^6]

The driver emits Linux **Type B (slot-based) multitouch events**: `ABS_MT_SLOT`, `ABS_MT_TRACKING_ID`, `ABS_MT_POSITION_X`, `ABS_MT_POSITION_Y`, `ABS_MT_TOUCH_MAJOR`, and `ABS_MT_TOUCH_MINOR`. For INTUOSHT2 devices (unlike earlier Bamboo-class touch tablets), the touch dimensions use the literal `data[^5] * 100` and `data[^6] * 100` values rather than a circular area approximation.[^6]

### Touch Arbitration

The CTH-690 implements **touch arbitration**: the driver suppresses touch input whenever the stylus is detected in proximity, preventing accidental palm or finger events during pen use. The arbitration logic in the kernel:[^9]

```c
static inline bool report_touch_events(struct wacom_wac *wacom) {
    return (touch_arbitration ? !wacom->shared->stylus_in_proximity : 1);
}
```

Arbitration is enabled by default but can be disabled via the kernel module parameter `touch_arbitration=0`.[^7][^9]

### Touch Switch (Hardware Mute)

The physical slide switch on the top-right corner of the tablet reports as a **`SW_MUTE_DEVICE`** Linux input event. When the wireless status packet arrives (`WACOM_REPORT_USB`) and the device type is INTUOSHT or INTUOSHT2, the driver reads bit 6 of `data[^5]` for the mute state and calls `input_report_switch(touch_input, SW_MUTE_DEVICE, data[^5] & 0x40)`.[^6]

***

## Pen / Stylus Protocol

The CTH-690 uses the **INTUOSHT2 pen format**, which routes through `wacom_intuos_irq()` instead of the older `wacom_bpt_pen()` path used by the CTH-680. Key behavioral differences from INTUOSHT (CTH-480/680):[^6]

- **No tilt reporting** — `ABS_TILT_X` and `ABS_TILT_Y` are suppressed for INTUOSHT2 even though the packet layout includes those bytes[^6]
- **Distance inversion** — hover distance is computed as `features->distance_max - raw_distance` for INTUOSHT2[^6]
- **Stylus in-proximity signaling** — the INTUOSHT2 *does not* set `stylus_in_proximity` on the "in range" sub-packet (unlike INTUOSHT); it sets it only on the "enter prox" packet[^6]
- **Pressure max**: 2047 (11-bit), with the raw field shifted: `t = (data[^6] << 3) | ((data[^7] & 0xC0) >> 5) | (data[^1] & 1)` [^6]

***

## Accessories

| Accessory | Part Number | Notes |
| :-- | :-- | :-- |
| Replacement pen | **LP-190K** | No eraser; 1 programmable side button; 2048 pressure levels [^10][^11] |
| Standard nibs (5-pack) | Standard Black Pen Nibs | Identical to CTH-490 nibs [^4] |
| Wireless Accessory Kit | **ACK-40401** | 2.4 GHz RF; 10 m range; 3.7V 1150 mAh Li-ion battery; charges via USB; ~15 hr use [^12][^13] |

The LP-190K pen is **exclusive to the 2015 Intuos generation** (CTL-490, CTH-490, CTH-690, CTL-472, CTL-672) and does not work with earlier Intuos, Intuos Pro, Bamboo, or Cintiq products. The ACK-40401 wireless kit slots into a bay concealed under a removable panel on the tablet's underside, alongside a hidden nib storage compartment with a nib-extraction tool hole.[^14][^10][^11]

***

## Linux Kernel Driver Support Summary

| Item | Detail |
| :-- | :-- |
| Native kernel support | Linux 4.4+ |
| input-wacom backport | 2.6.30+ (touch requires 2.6.38+) |
| libwacom minimum | 0.16 |
| Driver class | `INTUOSHT2` |
| Touch max contacts | 16 |
| HID type override | `HID_TYPE_USBNONE` |

<span style="display:none">[^15][^16][^17][^18][^19][^20][^21][^22][^23][^24][^25][^26][^27][^28][^29][^30][^31][^32][^33][^34][^35][^36][^37][^38][^39][^40][^41][^42][^43][^44][^45][^46][^47][^48][^49][^50][^51][^52][^53][^54][^55][^56][^57][^58][^59][^60][^61][^62][^63][^64][^65][^66][^67][^68][^69][^70][^71][^72][^73][^74][^75][^76][^77][^78][^79][^80][^81]</span>

<div align="center">⁂</div>

[^1]: https://devicehunt.com/view/type/usb/vendor/056A

[^2]: https://github.com/linuxwacom/input-wacom/wiki/Device-IDs

[^3]: https://binhminhdigital.com/bang-ve-wacom-intuos-art-medium-cth-690-k0-cx.html

[^4]: https://www.electrosonicbd.com/tab/wacom/wacom-intuos-art-medium-cth-690.html

[^5]: https://villman.com/Product-Detail/Wacom_CTH690

[^6]: https://github.com/torvalds/linux/blob/master/drivers/hid/wacom_wac.c

[^7]: https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html

[^8]: https://github.com/KurtE/WacomController

[^9]: https://developer-support.wacom.com/hc/en-us/articles/12845589645207-Kernel-Events

[^10]: https://www.reddit.com/r/wacom/comments/42zal0/pens_compatible_with_cth690/

[^11]: https://www.digitec.ch/en/s1/product/wacom-intuos-pen-for-cth-490690-ctl-490-styluses-5723482

[^12]: https://support.wacom.com/hc/en-us/articles/1500006340602-What-is-the-Wacom-Wireless-Accessory-kit-ACK40401

[^13]: https://www.ipohonline.biz/wacom-ack-40401-wireless-accessory-kit

[^14]: https://estore.wacom.kr/ko-kr/pen-for-intuos-art-comic-draw-and-photo-lp-190-0k-01-ca.html

[^15]: https://mocktab.org/hardware.html

[^16]: https://support.wacom.com/hc/en-us/articles/4412794852247-Where-can-I-find-the-model-number-serial-number-of-my-Wacom-device

[^17]: https://developer-support.wacom.com/hc/en-us/articles/9354492149527-Wacom-Device-Specifications

[^18]: https://outbyte.com/drivers/input-devices/wacom-technology-corporation/wacom-device/

[^19]: https://www.wacom.com/en-gb/support/product-support/drivers

[^20]: https://www.driveridentifier.com/scan/wacom-tablet/driver-detail/D77D7A1BB8E3414E8B19A52B2C10D423/2287881/18bbf7cd9dc1dbbe6f4d7a21b04ed9f4/16523730/USB\VID_056A\&PID_00B1

[^21]: https://github.com/hawku/TabletDriver/issues/32

[^22]: https://driverslab.ru/2024-wacom-driver-6-2-0w5-for-usb-tablets.html

[^23]: https://forum.ubuntu-fr.org/viewtopic.php?id=1967181

[^24]: https://driverslab.ru/1345-wacom-tablet-drivers-6-3-33-3.html

[^25]: https://cdn-media.wacom.com/en-us/events/-/media/files/downloads/product-support/ipis/stylus/intuos-creative-stylus-ipi131028web.pdf?rev=a7097d762bde4b559a0c33c534067dbc\&hash=645A16AAEE759ECE778E271BA2A368E9

[^26]: https://estore.wacom.com/en-us/tablets.html

[^27]: https://the-sz.com/products/usbid/index.php?v=0x056A

[^28]: https://www.generation-net.com/Tablettes-Graphiques/Wacom/fiche-3928769-Tablette-graphique-Wacom-INTUOS-ART-PT-MEDIUM-Blac--CTH-690AK-S.html

[^29]: https://101.wacom.com/UserHelpPDF_Legacy/CTH-690_en.pdf

[^30]: https://cellularkenya.co.ke/product/wacom-intuos-art-medium-cth-690-pen-and-touch-digital-graphics-drawing-tablet/

[^31]: https://www.mattonbutiken.se/produkt/wacom-pen-f-or-cth-490-cth-690

[^32]: https://sweetmonia.com/Sweet-Drawing-Blog/how-to-find-a-pen-replacement-for-your-wacom-pen-or-stylus-intuos-cintiq-intuos-pro-mobilestudio-pro/

[^33]: https://machollywood.com/blogs/news/wacom-pen-compatibility

[^34]: https://www.elite-electronics.com.au/Computer_IT/Pen_Tablets_eReaders/Wacom_Intuos_Art_Pen_Touch_Medium_Graphics_Tablet_CTH-690_K2-C

[^35]: https://www.youtube.com/watch?v=PAoDt4TpM_g

[^36]: https://www.indiamart.com/proddetail/wacom-intuos-art-pen-touch-medium-mint-blue-cth-690-b0-cx-10-8-x-8-5-inch-graphics-tablet-mi-15502709891.html

[^37]: https://101.wacom.com/UserHelpPDF_Legacy/CTH-690_de.pdf

[^38]: https://101.wacom.com/UserHelpPDF_Legacy/CTH-690_pt.pdf

[^39]: https://lkml.iu.edu/1406.3/04755.html

[^40]: https://101.wacom.com/UserHelpPDF_Legacy/CTH-690_pl.pdf

[^41]: https://support.wacom.com/hc/ja/sections/1500000552282-Other-Pen-Tablet-Models

[^42]: https://developer-docs.wacom.com/docs/icbt/macos/multi-touch/multitouch-framework-reference/

[^43]: https://developer-support.wacom.com/hc/en-us/articles/12845526953239-Multi-Touch-Framework

[^44]: https://github.com/linuxwacom/input-wacom/wiki

[^45]: https://www.wacomeng.com/touch/WacomFeelMulti-TouchFAQ.htm

[^46]: https://developer-support.wacom.com/hc/en-us/articles/9354478692503-STU-HID-Diagnostic-Tool

[^47]: https://github.com/linuxwacom/input-wacom/releases

[^48]: https://www.turkiyewacom.com/urun/wacom-wireless-kit-ack-40401

[^49]: https://www.wacom-store.ru/wireless-accessory-kit/

[^50]: https://ogurin.tokyo/shops/S63131463277/

[^51]: https://support.wacom.com/hc/zh-tw/articles/1500006340602-什麼是-Wacom-無線配件組-Wireless-Accessory-kit-ACK-404-01

[^52]: https://hausstauballergien.com/shop/g/g10812463277/

[^53]: https://oolin.be/?n=87581250712

[^54]: https://www.bol.com/nl/nl/p/wacom-wireless-accessoire-kit-voor-de-betreffende-bamboo-en-intuos-tablets/1003004011774393/

[^55]: https://www.yohohongkong.com/en-us/product/8363-Wacom-Wireless-Accessories-Kit-ACK-40401-

[^56]: https://dgtizers.eg/wacom-ack-40401-wireless-accessory-kit

[^57]: https://linuxwacom.github.io/libwacom/

[^58]: https://github.com/linuxwacom/libwacom

[^59]: https://github.com/linuxwacom

[^60]: https://linuxwacom.github.io/

[^61]: https://github.com/linuxwacom/libwacom/blob/master/libwacom/libwacom-database.c

[^62]: https://github.com/linuxwacom/libwacom/tree/master/data

[^63]: https://github.com/linuxwacom/libwacom/releases

[^64]: https://github.com/linuxwacom/input-wacom

[^65]: https://github.com/linuxwacom/libwacom/blob/master/tools/libwacom-update-db.py

[^66]: https://github.com/linuxwacom/libwacom/releases/tag/libwacom-2.1.0

[^67]: https://gist.github.com/AcouBass/76bfd10526b20c3ae598deebdf703205

[^68]: https://github.com/linuxwacom/wacom-hid-descriptors

[^69]: https://github.com/linuxwacom/libwacom/blob/master/data/layouts/README.md

[^70]: https://sourceforge.net/p/linuxwacom/libwacom/ci/master/tree/

[^71]: https://sourceforge.net/projects/linuxwacom/

[^72]: https://www.kernel.org/pub/linux/kernel/people/marcelo/linux-2.4/drivers/usb/wacom.c

[^73]: https://www.wacom.com/en-us/support/product-support/drivers

[^74]: https://man.archlinux.org/man/wacom.4.en

[^75]: https://101.wacom.com/UserHelp/en/TOC/CTH-490.html

[^76]: https://support.wacom.asia/tablet-drivers

[^77]: https://www.laptopdirect.co.za/Wacom-LP190K-p-158714.php

[^78]: https://help.ubuntu.com/community/Install_linuxwacom_driver

[^79]: https://support.wacom.asia/tw/manuals-brochures

[^80]: https://www.coloreurope.eu/shop/wacom-pen-for-9378p.html

[^81]: https://101.wacom.com/UserHelpPDF_Legacy/CTH-490_nl.pdf

