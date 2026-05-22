2026-05-21

> **Correction (2026-05-21, post-research):** The "no BT touch protocol" framing below is wrong for the Intuos Pro Gen 2 family (PTH-460/660/860) specifically. The Linux kernel implements `wacom_intuos_pro2_bt_touch()` in `drivers/hid/wacom_wac.c` for `INTUOSP2_BT`/`INTUOSP2S_BT`, and Wacom's own macOS driver supports BT touch on these tablets. Touch is woven into the same 361-byte 0x80 container as the pen, at byte offset 109, in 4 frames of 43 bytes each. MockTab ports this in `IntuosV2Decoder+BT.swift::decodeBTTouch`. The libwacom `Touch=false` convention the notes cite applies to the Intuos BT S (CTL-4100WL) — a different family — not to PTH-660/860. The bandwidth-tradeoff history below remains accurate context; the no-BT-touch verdict is the part to disregard for Intuos Pro Gen 2.

## Touch Over Bluetooth: The Fundamental Constraint

**Wacom produced no public specification for touch input over Bluetooth for IntuosV2, IntuosV3, or touch-capable Cintiq models between 2000 and 2020, because touch data was not transmitted over Bluetooth in any of those generations.** This is not a documentation gap — it is an intentional architectural decision that persists through much of the period you asked about.

***

## Bluetooth Transport Generations (2000–2020)

Wacom's Bluetooth-capable tablet families divide into three distinct transport generations, each with different protocol characteristics, and none of them carry touch over the wireless link during your target window.

### Generation 1: Graphire Bluetooth (CTE-630BT, ~2003–2005)
The first Wacom Bluetooth tablet used **Bluetooth 1.1 Classic HID profile**. The device connected as a standard HID peripheral over L2CAP. The kernel identifies this device as type `GRAPHIRE_BT` in `wacom_wac.h`. The Wacom Graphire had no touch sensor at all — it was a pen-only device — so there is simply no touch protocol to specify. Report ID `WACOM_REPORT_PENABLED_BT` (value 3) was used for pen data, diverging from the USB pen report ID of 2. The BT packet format for the Graphire differs from USB mainly in how pres mainly in how pressure is encoded: `data [github](https://github.com/linuxwacom/input-wacom/wiki/Wacom-Protocols) | (((u16)(data [101.wacom](https://101.wacom.com/productsupport/manual/BTManual.pdf) & 0x08)) << 5)` rather than the USB encoding of `data [github](https://github.com/linuxwacom/input-wacom/wiki/Wacom-Protocols) | ((data [kernel](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-driver-wacom) & 0x03) << 8)`  [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html). Pad data (ExpressKeys) also differs: the GRAPHIRE_BT variant reads pad state from `data [kernel](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-driver-wacom) & 0x03`  [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html).

### Generation 2: Intuos4 Wireless (CTE-450W, CTE-650W, ~2010–2013)
The Intuos4 Wireless (driver type `INTUOS4WL`) used **Bluetooth 2.1+EDR**  via the `wacom-hid.ko` kernel driver. The linuxwacom protocol wiki explicitly states that Bluetooth support at this time was "limited to the Graphire4 Wireless and the Intuos4 Wireless". The Intuos4 Wireless is a **pen-only device over Bluetooth** — it has no touch sensor at all, so again no touch protocol exists. The kernel exposes a `speed` sysfs attribute for BT reporting rate control. Battery capacity state is tracked via an 8-level table `batcap_i4[]` distinct from the Graphire table `batcap_gr[]`. A high-speed mode (`bt_high_speed`) can be toggled via the sysfs interface, which changes the pen data report rate. [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html)

### Generation 3: Intuos Pro (PTH-460/660/860, ~2017–2020)
The 2017 Intuos Pro added **Bluetooth 4.2 Low Energy (BLE/BTLE)** and appears in the kernel as device types `INTUOSP2_BT`, `INTUOSP2S_BT`, and (for the Intuos BT S/M) `INTUOSHT3_BT`. This is the first generation where Wacom uses BLE's HID over GATT Profile (HOGP) alongside Classic BT HID. The device advertises two profiles: `BT IntuosPro` (Classic BT, for computers) and `LE IntuosPro` (BLE, for mobile). The linuxwacom driver implements `wacom_intuos_pro2_bt_irq()` and `wacom_intuos_pro2_bt_touch()` for this family. **However, Wacom's own official guidance explicitly recommends disabling the touch function when operating in Bluetooth mode** to reduce data transfer load. The libwacom `.tablet` definition file for the CTL-4100WL (Intuos BT S) explicitly sets `Touch=false` for the Bluetooth device match while setting `Touch=true` for the USB device match. This means the driver treats the device as a **non-touch device when connected over Bluetooth**. [youtube](https://www.youtube.com/watch?v=8cjehwQa8Pg)

***

## Why Touch Is Absent Over BT: The Bandwidth Argument

Wacom's reasoning is documented indirectly through official support articles: [support.wacom](https://support.wacom.com/hc/en-us/articles/1500006265761-How-to-optimize-your-Wacom-Intuos-Pro)

- USB 2.0 provides ~50 MB/s effective throughput; Bluetooth 2 provides ~724 KB/s and Bluetooth 4 ~3 MB/s [reddit](https://www.reddit.com/r/wacom/comments/1gi68cf/wacom_intuos_pro_wirelessbluetooth_latency_issue/)
- Touch multitouch data at 200 Hz with up to 16 finger contacts (16FGT on Intuos5/Cintiq 24HD touch) would consume bandwidth comparable to pen data, making the combined load problematic [github](https://github.com/linuxwacom/xf86-input-wacom/wiki/Multitouch)
- Pen latency is the primary performance requirement, and Wacom opted to protect it by shedding touch over BT entirely
- The `WACOM_BYTES_PER_MT_PACKET` constant (11 bytes per contact) and `WACOM_PKGLEN_BBTOUCH` (20 bytes) and `WACOM_PKGLEN_BBTOUCH3` (64 bytes) show the touch packet sizes that were never transmitted over BT [lxr.missinglinkelectronics](https://lxr.missinglinkelectronics.com/linux+v5.4/drivers/hid/wacom_wac.h)

***

## What *Is* Documented for BT (Pen-Only Paths)

The kernel source reveals the following BT-specific pen protocol details you can use for comparison against your USB reports:

| Feature | USB | Bluetooth |
|---|---|---|
| Pen report ID | `WACOM_REPORT_PENABLED` = 2 | `WACOM_REPORT_PENABLED_BT` = 3  [lxr.missinglinkelectronics](https://lxr.missinglinkelectronics.com/linux+v5.4/drivers/hid/wacom_wac.h) |
| WL status report | — | `WACOM_REPORT_WL` = 0x80 (128)  [lxr.missinglinkelectronics](https://lxr.missinglinkelectronics.com/linux+v5.4/drivers/hid/wacom_wac.h) |
| Pressure encoding (Graphire) | `data [github](https://github.com/linuxwacom/input-wacom/wiki/Wacom-Protocols) \| ((data [kernel](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-driver-wacom) & 0x03) << 8)` | `data [github](https://github.com/linuxwacom/input-wacom/wiki/Wacom-Protocols) \| (((u16)(data [101.wacom](https://101.wacom.com/productsupport/manual/BTManual.pdf) & 0x08)) << 5)`  [codebrowser](https://codebrowser.dev/linux/linux/drivers/hid/wacom_wac.c.html) |
| Max packet length | 192 bytes (kernel 4.7) | 361 bytes (kernel 5.4, BT added headroom)  [lxr.missinglinkelectronics](https://lxr.missinglinkelectronics.com/linux+v5.4/drivers/hid/wacom_wac.h) |
| BT Intuos4 speed control | n/a | sysfs `speed` attribute, 0=low, 1=high  [kernel](https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-driver-wacom) |
| BT IntuosP2 command | — | `WAC_CMD_WL_INTUOSP2` = 0x82  [lxr.missinglinkelectronics](https://lxr.missinglinkelectronics.com/linux+v5.4/drivers/hid/wacom_wac.h) |
| Touch arbitration state | Maintained in kernel | Not applicable (no BT touch) |

***

## The Cintiq Touch Family

The Cintiq touch line (Cintiq 24HD touch, Wacom27QHDT, etc.) are **USB-only devices** for their touch functionality. No Cintiq model in the 2000–2020 window supported Bluetooth connectivity at all — the Cintiq connects via USB for both pen and touch. Multitouch for the 24HD touch uses report ID `WACOM_REPORT_24HDT` = 1 with `WACOM_BYTES_PER_24HDT_PACKET` = 14 bytes per contact, but this is strictly a USB-only path. [michaelmcguffin](https://www.michaelmcguffin.com/code/cintiq/)

***

## Critical Contrarian Takeaway

If your existing USB touch reports contain fields for connection-type flags or BT-specific behavior, **no BT counterpart exists to validate against**. The correct framing for your driver work is: the touch subsystem should be **conditioned on connection type**, disabling itself when `hid_is_using_ll_driver(hdev, &bt_hid_drv)` is true or when the PID maps to a `_BT` variant in the device table — precisely what the linuxwacom libwacom definitions already do. If you need to exercise the touch path, USB is the only transport for all Wacom touch families in the 2000–2020 window. [github](https://github.com/linuxwacom/libwacom/issues/359)