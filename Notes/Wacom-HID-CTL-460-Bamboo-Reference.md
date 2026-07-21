2026-07-21

# Wacom CTL-460 (Bamboo Pen) — Technical Specification Sheet

The Wacom CTL-460, marketed as the **Bamboo Pen**, is an entry-level, pen-only USB graphics tablet released around September 2009. It is part of the "Bamboo" family alongside the touch-only CTT-460 and the pen+touch CTH-460, all of which are documented in the same official Wacom user manual. It uses Wacom's electromagnetic resonance digitizer technology and connects over a standard USB-A cable — there is no Bluetooth or wireless variant of this specific model.[^1][^2][^3][^4]

## Physical Dimensions

| Attribute | Value |
|---|---|
| Overall tablet size (W x D x H) | 248.2 x 176.1 x 8.5 mm (9.78 x 6.94 x 0.33 in), excluding pen holder and rubber feet[^2] |
| Weight | 210 g (0.46 lb) approx. for the pen-only mechanism; full CTH-460 pen+touch unit weighs 360 g (0.79 lb)[^2][^5] |
| Format | A6 Wide[^1] |
| Cable | USB Type-A, 1.5 m (4.9 ft) length[^2] |
| Case color | Black with grey accents[^1] |

Note: some retailer listings show a slightly different footprint (208.4 x 137.6 x 7.5 mm) for a variant/packaging revision, so buyers should verify the exact box dimensions against their specific unit.[^4]

## Active Area and Resolution

| Attribute | Value |
|---|---|
| Pen active area (W x D) | 147.2 x 92.0 mm (5.80 x 3.62 in)[^2][^6] |
| Aspect ratio | 16:10[^2] |
| Coordinate resolution (pen) | 100 lines/mm — 2540 lpi[^2] |
| Pen accuracy | ±0.25 mm (0.01 in)[^2] |
| Pen detection/hover height | 7 mm (0.28 in)[^2] |
| Average reading height with pen | 16 mm (0.63 in)[^2] |
| Report rate (pen) | 133 points per second, maximum[^2] |

Some regional retailer datasheets cite a slightly different resolution figure of 1270 lpi rather than 2540 lpi, and this discrepancy likely reflects differing definitions between "lines per inch" as raw sensor pitch versus effective addressable resolution — the official Wacom manual's 2540 lpi figure should be treated as authoritative.[^2][^7]

## Pen (Stylus) Capabilities

| Attribute | Value |
|---|---|
| Pen model | Battery-free electromagnetic resonance pen (e.g., LP-160)[^5] |
| Pressure sensitivity | 512 levels[^8][^1] |
| Pen buttons | 2 programmable side switches (no barrel toggle beyond these); no eraser tip on the base CTL-460 pen[^8][^6] |
| Tilt sensing | Not supported — the CTL-460 (and all pen-only CTL models of this generation) always report tilt as zero, unlike the later touch-enabled CTH-480/490[^9] |
| Pen dimensions | ~149 mm length, ~11.8 mm diameter, ~13 g weight (per regional retail spec sheet)[^1] |

## Tablet Buttons

The CTL-460 has **no ExpressKeys, wheel, or touch strips** — it is Wacom's most minimal Bamboo variant. Button functionality is limited entirely to the two switches on the pen barrel itself, decoded from the pad's inline status byte rather than a separate pad interface. This distinguishes it from the CTH-460 (pen+touch) sibling, which adds four physical ExpressKeys on the tablet body.[^9]

## USB Identification

| Attribute | Value |
|---|---|
| USB Vendor ID (Wacom) | 0x056A[^10] |
| USB Product ID (CTL-460 / "Bamboo Pen (S)") | 0x00D4[^10] |
| USB device class | 03-01-02 (HID, boot interface, mouse subclass)[^10] |
| Linux kernel driver support | Native since kernel 2.6.37, via `drivers/input/tablet/wacom_wac.c`[^10] |
| Interface | USB 1.1/2.0, USB Type-A connector[^2] |
| Power draw | DC 5V, 70 mA or less, drawn entirely from the USB port (no external power or battery)[^2] |

The neighboring CTH-461 (Bamboo Fun/Craft/Comic Pen & Touch, small) carries USB PID 0x00D2, confirming that Wacom allocated sequential PIDs across this 2009 Bamboo refresh generation.[^11]

## Bluetooth Behavior

The CTL-460 has **no Bluetooth radio and no wireless operating mode**. It is a wired-only USB tablet; Wacom's Bluetooth-capable Bamboo/Intuos models (e.g., CTL-4100WL "Intuos BT S" or CTL-6100WL "Intuos BT M") are separate, later product lines with distinct USB PIDs (0x0376/0x0377) and a completely different report-ID structure that includes pad reports over BLE HOGP. Any reference to "CTL-460 Bluetooth" in the wild is a misattribution — the CTL-460 nomenclature strictly denotes the wired Bamboo Pen.[^12][^13]

## HID Report / Byte-Level Protocol

The CTL-460 uses Wacom's **"bamboo" parser family**, handled in the Linux kernel by `wacom_bpt_irq()` dispatching to `wacom_bpt2_pen()`. This is distinct from the older "graphire" protocol and from the "intuosV1" protocol used by professional Intuos/Cintiq tablets.[^9]

### Pen/Eraser Report (Report ID 0x10, 10 bytes)

```
10  d1  d2  d3  d4  d5  d6  d7  d8  d9
```

| Byte(s) | Field | Formula |
|---|---|---|
| d0 | Status byte | see status table below |
| d1:d2 | X position | Big-endian 16-bit: `BE16(d1:d2)` |
| d3:d4 | Y position | Big-endian 16-bit: `BE16(d3:d4)` |
| d5:d6 | Pressure | `(d5 << 3) \| (d6 >> 5)` — 11-bit for devices with 2047 max; shifted right one bit for 1023-max devices |
| d7 | Tilt X | Not populated on CTL-460 (tilt-capable field only active on CTH-480/490) |
| d8 | Tilt Y | Not populated on CTL-460 |

[^9]

### Status Byte (d0) Bit Map

| Bit | Field | Meaning |
|---|---|---|
| 0x80 | Proximity | 1 = pen in range |
| 0x20 | Proximity confirm | Alternate proximity bit on some models |
| (d0 >> 3) & 0x03 | Tool type | 0 = Pen, 1 = Eraser, 2 = Mouse |
| 0x02 | BTN_STYLUS | Barrel button 1 |
| 0x04 | BTN_STYLUS2 | Barrel button 2 |
| 0x01 | BTN_TOUCH | Tip contact |

[^9]

There is no tool-serial or tool-ID negotiation packet on the Bamboo protocol — the eraser/pen/mouse distinction is derived purely from the type bits in each packet, so the driver cannot report a persistent `ABS_MISC` tool ID as it does for Intuos-class devices.[^9]

### Pad (Button) Report

Unlike higher-end tablets, the CTL-460 has no dedicated pad report ID — button state for the two pen-side switches is inline within the same 10-byte pen report:

| Field | Formula | Applicable models |
|---|---|---|
| BTN_0 | `d7 & 0x01` | CTL-460/470 (pen-only, 2-key variant) |
| BTN_1 | `d7 & 0x02` | CTL-460/470 (pen-only, 2-key variant) |

The touch-enabled CTH-460 sibling instead uses `d7 & 0x08`, `0x10`, `0x20`, `0x40` for its four physical ExpressKeys — a different bit map entirely, underscoring that the CTL and CTH share silicon but not the exact button decode.[^9]

## Software and Certification

| Attribute | Value |
|---|---|
| Bundled software | Corel Painter Essentials (version varies by bundle/region)[^8][^6] |
| Supported OS (at release) | Windows 2000/XP/Vista, Mac OS X 10.4.8 and later; modern listings show Windows 7/8.1/10 and macOS 10.10+ support via updated drivers[^1][^8] |
| Operating temperature | 5 to 40 degrees C (41 to 104 degrees F)[^2] |
| Storage temperature | -15 to +55 degrees C (5 to 131 degrees F)[^2] |
| Certifications | FCC Class B, Industry Canada Class B, CE, VCCI Class B, BSMI, C-Tick, MIC, GOST-R, EU RoHS Directive 2002/95/EC, Chinese RoHS[^2] |
| Orientation | Reversible for right- or left-handed use[^6] |

## Known Ambiguities and Gaps

Public documentation contains a few unresolved discrepancies worth flagging for anyone reverse-engineering this device. Retail spec sheets disagree on resolution (1270 vs. 2540 lpi) and on box dimensions across regional SKUs, likely reflecting packaging or firmware revision differences rather than hardware changes. No official Wacom HID report descriptor (the raw USB descriptor bytes, as opposed to the decoded field map) for PID 0x00D4 was found in public archives during this research; the byte-level decode above is derived from the open-source Linux kernel driver logic rather than a leaked or published descriptor file, so exact bit-for-bit descriptor byte offsets should be verified with a USB packet capture (e.g., Wireshark/usbmon) against a physical unit if firmware-level certainty is required.[^7][^14][^2][^4][^9]

---

## Correction (MockTab, 2026-07-21)

The "HID Report / Byte-Level Protocol" section above is wrong for this device.
The Linux kernel routes the CTL-460 (BAMBOO_PT family) through
`wacom_bpt_pen()`, which decodes **Report ID 0x02, 9 bytes, little-endian** —
not Report ID 0x10 big-endian:

```
[0] 0x02   [1] status   [2:3] X LE16   [4:5] Y LE16   [6:7] pressure LE16   [8] distance
status: 0x01 tip, 0x02 barrel 1, 0x04 barrel 2, 0x08 eraser tool, 0x20 proximity
```

The device only emits these after the host sends HID **feature report
[0x02, 0x02]** (mode 2); until then it stays in boot-mouse emulation and sends
4-byte relative packets on Report ID 0x01 — exactly what the 2026-07-21 user
capture recorded. The capture's descriptor (vendor page 0xFF00, input report
0x02 with X/Y logical max 480/320 plus 13 vendor bytes) is consistent with
this. There is also no inline pad-button byte: the CTL-460 has no ExpressKeys,
and the two switches are on the pen barrel (status bits 0x02/0x04).

The capture also confirmed PID 0x00D4 with the physical label "CTL-460/K",
settling the registry misattribution ("Bamboo Capture (CTH-470)" — the
CTH-470 is actually PID 0x00DE).

## References

1. [TAVOLETTA GRAFICA WACOM BAMBOO Pen (CTL-460 ...](https://www.elektrasystem.it/CLT-460.htm)

2. [Bamboo Touch Tablet (Model Ctt-460); Bamboo Tablet (Model Cth-460); Product Specifications; General Specifications - Wacom BAMBOO CTL-460 User Manual [Page 70]](https://www.manualslib.com/manual/188356/Wacom-Bamboo-Ctl-460.html?page=70) - Wacom BAMBOO CTL-460 Manual Online: bamboo touch tablet (model ctt-460), Bamboo Tablet (Model Cth-46...

3. [Bamboo User's Manual for Windows & Macintosh](https://cdn.wacom.com/u/productsupport/manuals/bamboo1/user's%20manual.pdf) - Bamboo Pen. (model CTL-460) shown. Status LED. Glows white when your Bamboo tablet is connected to a...

4. [Bamboo Pen Graphics Tablet](https://www.drawingtablet.info/tablets/wacom-bamboo-pen-ctl460) - Full details about the wacom Bamboo Pen (CTL-460) graphics tablet. Latest info on pen displays, grap...

5. [Графический планшет Wacom Bamboo Pen [CTL-460-RU]: характеристики, описание](https://www.technocity.ru/catalog/detail/997/) - Купить графический планшет Wacom Bamboo Pen [CTL-460-RU] в интернет-магазине ТехноСити Новосибирск; ...

6. [Wacom Bamboo Pen Digital Tablet](https://www.bhphotovideo.com/c/product/653304-REG/Wacom_CTL460_Bamboo_Pen_Digital_Tablet.html) - Wacom Bamboo Pen Digital Tablet · 5.8 x 3.6" Active Area · Textured Work Surface · Pressure-Sensitiv...

7. [Tableta Digitalizadora Wacom Bamboo Pen CTL460](https://www.computershopping.com.ar/Producto/Tableta-Digitalizadora-Wacom-Bamboo-Pen-CTL460) - Marca: Wacom Modelo: Ba mboo Pen Area Táctil activa: 147mm x 91mm (5,8 x 3,6) Resolución: 1270 LPI (...

8. [Amazon.com: Wacom CTL460 Bamboo Pen Tablet : Electronics](https://www.amazon.com/Wacom-CTL460-Bamboo-Pen-Tablet/dp/B0013T1Z7O) - Amazon.com: Wacom CTL460 Bamboo Pen Tablet : Electronics

9. [tablet-driver/Notes/Wacom-HID-Family-Reference.md at main](https://github.com/Cyzor/tablet-driver/blob/main/Notes/Wacom-HID-Family-Reference.md) - General Pen ( type = (d >>1) & 0x0F , cases 0x00 – 0x03 ). Field ... All earlier CTH-460/470 and all...

10. [Device 'Wacom CTL-460 [Bamboo Pen (S)]'](https://linux-hardware.org/?id=usb:056a-00d4) - A database of all the hardware that works under linux

11. [Wacom Co., Ltd — USB Vendor 056A](https://devicehunt.com/view/type/usb/vendor/056A) - Type, USB. Vendor ID, 056A. Vendor Name, Wacom Co., Ltd. Device ID, 00D2. Device Name, CTH-461 [Bamb...

12. [I can't map the tablet buttons via bluetooth [INTUOS BT S - CTL-4100WL] · Issue #359 · linuxwacom/libwacom](https://github.com/linuxwacom/libwacom/issues/359) - xsetwacom --list:
```
Wacom Intuos BT S Pen stylus id: 18 type: STYLUS
Wacom Intuos BT S Pen eraser ...

13. [Add Wacom CTL-6100WL Bluetooth support! · Issue #2118 · OpenTabletDriver/OpenTabletDriver](https://github.com/OpenTabletDriver/OpenTabletDriver/issues/2118) - Description Hello, i bought the Wacom Intuos M (Bluetooth model) a few days ago and i found out this...

14. [[PATCH 01/15] Input - wacom: include and use linux/hid.h](https://lkml.iu.edu/1406.3/04755.html)

