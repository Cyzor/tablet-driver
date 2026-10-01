# Switching Wacom tablets into full-data mode

Most Wacom tablets start up as a plain relative mouse or send an idle
report, and only produce pen data after the host writes a feature report.
A host that only listens sees a reduced or empty stream and can wrongly
conclude that the tablet lacks tilt, pressure or buttons. The write never
changes the product ID.

Confidence labels: **observed** · **kernel**, as on the protocol pages.

## The write

A HID SET_REPORT of type Feature: the report ID, then a mode value. For
almost every pen tablet and pen display this is `[0x02, 0x02]`, report 2,
value 2. (observed on the CTL-460, PTH-850, PL-800 and PTK-870)

Before it: the Bamboos and consumer Intuos send 4-byte relative mouse
packets on report `0x01`; the PTK-x70 sends idle report `0x06`; touch
interfaces send zero-filled reports. No delay or second step is needed
afterwards. (observed)

## How the Linux driver picks the report

Three mechanisms, by device generation (`wacom_sys.c`):

1. **Fixed, by family.** Older pen tablets up to the 2009–2011 Bamboo use
   report 2, value 2. Some touch interfaces use their own: multi-touch
   Tablet PCs report 3, value 4; the Cintiq 24HD Touch report 18, value 2;
   the 27QHD Touch report 131, value 2. (kernel)
2. **From the descriptor** (current devices, the kernel's `HID_GENERIC`
   path). Find the feature report containing vendor usage `0xFF0D1002`
   (`WACOM_HID_WD_DATAMODE`) and write value 2 to it. The report ID comes
   from the descriptor; it happens to be 2 on every device we've seen, but
   the kernel doesn't assume it. (kernel)
3. **G9/G11 controllers** (some touchscreens and Tablet PCs) start in a
   vendor format; writing 0 to report `0x0B` (pen) or `0x03`
   (touchscreen) switches them to standard HID. (kernel)

The kernel retries the write up to five times and schedules it about a
second after the device is probed, not at enumeration. Over Bluetooth it
uses a separate query path.

## Send it to the right interface

A tablet can expose several HID interfaces, and more than one may declare
feature reports. The PTK-870's vendor interface (usage page `0xFFD1`,
1-byte reports) enumerates first and declares feature reports, but not
report 2. Writing there fails with `0xE0005000` (endpoint not found), and
the pen interface, which does declare report 2, never gets the write.
Target the interface whose descriptor declares the report, rather than the
first one with any feature report. (observed)

## Reports that resemble the switch

`0xFF0D0980` (`WACOM_HID_WD_MODE_CHANGE`) is an input usage, the device
announcing a mode change. The host does not write it. (kernel)
